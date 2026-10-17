import Foundation
import AVFoundation
import FluidAudio

/// Parakeet (NVIDIA, via FluidAudio Core ML) with real word timings. Models cache under Application Support.
actor FluidEngine: TranscriptionEngine {
    static let shared = FluidEngine()
    nonisolated let id = "fluid"

    private var manager: AsrManager?
    private var loaded: String?

    private static func version(_ model: String) -> AsrModelVersion {
        switch model {
        case "v2": return .v2
        case "redux": return .redux
        case "ultra": return .ultra
        default: return .v3
        }
    }

    /// A load already under way (the iPhone starts loading while you record), so a second caller waits for it
    /// instead of loading the model twice.
    private var loading: (model: String, task: Task<AsrManager, Error>)?

    private func prepared(_ requested: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> AsrManager {
        let model = Engines.fluidModel(requested)
        if let m = manager, loaded == model { return m }
        if let l = loading, l.model == model {
            progress(.loading(Engines.displayName(engine: "fluid", model: model)))
            return try await l.task.value
        }
        let task = Task { try await self.load(model, progress: progress) }
        loading = (model, task)
        defer { if loading?.model == model { loading = nil } }
        return try await task.value
    }

    private func load(_ model: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> AsrManager {
        if let m = manager, loaded == model { return m }
        manager = nil
        warmed = nil
        let name = Engines.displayName(engine: "fluid", model: model)
        let dir = Paths.models.appendingPathComponent("parakeet-\(model)", isDirectory: true)
        progress(.loading(name))
        Log.note("Fluid load \(model)")
        let models = try await AsrModels.downloadAndLoad(to: dir, version: Self.version(model)) { p in
            progress(.downloading(name, p.fractionCompleted))
        }
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
        loaded = model
        return m
    }

    func transcribe(url: URL, model requested: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> EngineResult {
        let model = Engines.fluidModel(requested)
        let m = try await prepared(model, progress: progress)
        progress(.transcribing(nil))
        var state = TdtDecoderState.make()
        let r = try await m.transcribe(url, decoderState: &state)
        let words: [WordSpan] = buildWordTimings(from: r.tokenTimings ?? []).map {
            WordSpan(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.startTime, end: $0.endTime)
        }.filter { !$0.text.isEmpty }
        let segments: [Segment]
        if words.isEmpty {
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            segments = text.isEmpty ? [] : [Segment(start: 0, end: r.duration, text: text)]
        } else {
            segments = Engines.segments(fromWords: words)
        }
        return EngineResult(segments: segments, language: nil, engine: "fluid", model: Engines.displayName(engine: "fluid", model: model))
    }

    /// Loads the model ahead of time so the first dictation doesn't wait for it. Load only; `prewarm` also runs
    /// one inference.
    func warm(model: String) async {
        startDictationHelpers()
        _ = try? await prepared(model, progress: { _ in })
    }

    // MARK: Prewarm

    /// The model whose Core ML graphs have run one real inference since it was loaded.
    private var warmed: String?
    private var prewarming: (model: String, task: Task<Void, Never>)?

    /// About 1 s of near-silence at 16 kHz (a faint tone, so feature normalization never sees all zeros).
    private static let warmupSamples: [Float] = (0..<16_000).map { Float(sin(Double($0) * 0.05) * 0.000_5) }

    /// Loads the model if needed and runs one real inference on a second of silence, so Core ML has compiled and
    /// specialized the encoder and decoder for this device and the first dictation pays none of it. Also starts
    /// loading the speech detector (Mac) and, when the last dictation used Dictionary boosting (or `boostTerms` is
    /// given), the CTC vocabulary model. Idempotent: cheap when already warm, and concurrent calls share one run.
    func prewarm(model requested: String, boostTerms: [(text: String, aliases: [String])]? = nil) async {
        let model = Engines.fluidModel(requested)
        startDictationHelpers()
        if !(warmed == model && loaded == model) {
            if let p = prewarming, p.model == model {
                await p.task.value
            } else {
                let task = Task { await self.runWarmInference(model) }
                prewarming = (model, task)
                await task.value
                if prewarming?.model == model { prewarming = nil }
            }
        }
        if let boostTerms {
            if !boostTerms.isEmpty { _ = await boostSession(BoostVocabulary.rankByPosition(boostTerms)) }
        } else if ctc == nil, !boostBackingOff, UserDefaults.standard.bool(forKey: Self.boostUsedKey) {
            _ = try? await ctcModels()
        }
    }

    private func runWarmInference(_ model: String) async {
        guard let m = try? await prepared(model, progress: { _ in }) else { return }
        guard !(warmed == model && loaded == model) else { return }
        let layers = await m.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        let t0 = Date()
        do {
            _ = try await m.transcribe(Self.warmupSamples, decoderState: &state)
            if loaded == model { warmed = model }
            Log.note("Fluid prewarm \(model) \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        } catch {
            Log.note("Fluid prewarm inference failed: \(error)")
        }
    }

    // MARK: Dictation (speech detection + custom vocabulary)

    /// Transcribes a dictation: reads the audio once, trims leading and trailing silence with Silero VAD (audio
    /// under 2 minutes), returns no segments when there's no speech at all, then rescores against your Dictionary
    /// words with FluidAudio's CTC keyword spotter. `dictionary` is ranked with the active project's words first,
    /// then the newest. VAD and boosting failures fall back to the plain transcript: they must never break dictation.
    func transcribeDictation(url: URL, model: String, dictionary: [DictionaryEntry], project: UUID?) async throws -> EngineResult {
        try await dictation(url: url, model: model, ranked: BoostVocabulary.rank(dictionary, project: project))
    }

    /// Same as `transcribeDictation`, for callers that pass bare terms (oldest first, as the Dictionary stores
    /// them). Empty `terms` is fine: you still get speech detection, just no boosting.
    func transcribeBoosted(url: URL, model: String, terms: [(text: String, aliases: [String])]) async throws -> EngineResult {
        try await dictation(url: url, model: model, ranked: BoostVocabulary.rankByPosition(terms))
    }

    private func dictation(url: URL, model requested: String, ranked: [(text: String, aliases: [String])]) async throws -> EngineResult {
        let model = Engines.fluidModel(requested)
        let m = try await prepared(model, progress: { _ in })
        // Don't interleave with a warm-up inference on the same model; it finishes in about a second.
        if let p = prewarming, p.model == model { await p.task.value }
        UserDefaults.standard.set(!ranked.isEmpty, forKey: Self.boostUsedKey)
        let name = Engines.displayName(engine: "fluid", model: model)
        // One read and resample (16 kHz mono), shared by VAD, the ASR model, and the rescorer.
        let full = try AudioConverter().resampleAudioFile(url)
        let fullDuration = Double(full.count) / 16_000
        // VAD seeing no speech at all still transcribes the full audio (the loudness gate already passed): soft or
        // whispered speech can score low, and Parakeet rarely invents words in silence. An empty result is still empty.
        let trimmed = await trimSilence(full)
        if trimmed == nil { Log.note("VAD: no speech detected; transcribing the full audio anyway") }
        let samples = trimmed?.samples ?? full
        let offset = trimmed?.start ?? 0
        var state = TdtDecoderState.make()
        let r = try await m.transcribe(samples, decoderState: &state)
        var text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ranked.isEmpty, !text.isEmpty, let timings = r.tokenTimings, !timings.isEmpty,
           let session = await boostSession(ranked),
           let out = await session.rescore(text: r.text, tokenTimings: timings, audioSamples: samples) {
            if !out.detectedTerms.isEmpty { Log.note("vocabulary boost heard \(out.detectedTerms.count) term(s)") }
            if out.wasModified {
                Log.note("vocabulary boost changed the transcript")
                text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let segments: [Segment]
        if text.isEmpty {
            segments = []
        } else if text == r.text.trimmingCharacters(in: .whitespacesAndNewlines), let timings = r.tokenTimings, !timings.isEmpty {
            // Unchanged by the boost: keep word timings (shifted back by the trimmed lead-in), as plain transcribe does.
            let words: [WordSpan] = buildWordTimings(from: timings).map {
                WordSpan(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.startTime + offset, end: $0.endTime + offset)
            }.filter { !$0.text.isEmpty }
            segments = words.isEmpty ? [Segment(start: 0, end: fullDuration, text: text)] : Engines.segments(fromWords: words)
        } else {
            segments = [Segment(start: 0, end: fullDuration, text: text)]
        }
        return EngineResult(segments: segments, language: nil, engine: "fluid", model: name)
    }

    // MARK: Speech detection (Silero VAD)

    private var vad: VadManager?
    private var vadLoading = false
    private var vadRetryAt: Date?

    /// VAD runs only on dictation-length audio.
    private static let vadMaxSamples = 120 * 16_000
    /// Moderate "this chunk is speech" threshold (FluidAudio's default is 0.85; VoiceInk uses 0.7).
    private static let vadThreshold: Float = 0.5
    /// Chunks next to speech that are at least this likely to be speech are kept too, so a quiet first word survives.
    private static let vadEdgeThreshold: Float = 0.15
    /// A recording counts as silence only when no chunk gets even this close to speech.
    private static let vadSilencePeak: Float = 0.3
    /// Kept on both sides of the speech: 250 ms at 16 kHz.
    private static let vadPadSamples = 4_000

    /// Starts the background loads dictation needs (the speech detector). Mac only: the iPhone doesn't dictate.
    private func startDictationHelpers() {
        #if os(macOS)
        startVadLoad()
        #endif
    }

    /// Loads the VAD model in the background (a small download the first time). Dictation never waits for it:
    /// until it's ready, dictations skip trimming. A failed load is retried after a minute.
    private func startVadLoad() {
        guard vad == nil, !vadLoading else { return }
        if let r = vadRetryAt, Date() < r { return }
        vadLoading = true
        Task { await self.loadVad() }
    }

    private func loadVad() async {
        do {
            vad = try await VadManager(config: VadConfig(defaultThreshold: Self.vadThreshold))
            vadRetryAt = nil
        } catch {
            vadRetryAt = Date().addingTimeInterval(60)
            Log.note("VAD unavailable (retry in 60 s): \(error)")
        }
        vadLoading = false
    }

    /// Trims leading and trailing silence from a dictation, keeping 250 ms around the speech. Returns nil when the
    /// recording holds no speech at all. Fails open: any VAD problem returns the samples unchanged.
    private func trimSilence(_ samples: [Float]) async -> (samples: [Float], start: Double)? {
        guard samples.count <= Self.vadMaxSamples else { return (samples, 0) }
        guard let v = vad else { startVadLoad(); return (samples, 0) }
        let probs: [Float]
        do {
            probs = try await v.process(samples).map { $0.probability }
        } catch {
            Log.note("VAD failed; using full audio: \(error)")
            return (samples, 0)
        }
        guard !probs.isEmpty else { return (samples, 0) }
        guard var first = probs.firstIndex(where: { $0 >= Self.vadThreshold }),
              var last = probs.lastIndex(where: { $0 >= Self.vadThreshold }) else {
            return (probs.max() ?? 0) < Self.vadSilencePeak ? nil : (samples, 0)
        }
        while first > 0, probs[first - 1] >= Self.vadEdgeThreshold { first -= 1 }
        while last < probs.count - 1, probs[last + 1] >= Self.vadEdgeThreshold { last += 1 }
        let chunk = VadManager.chunkSize   // one probability per 4096 samples (256 ms)
        let start = max(0, first * chunk - Self.vadPadSamples)
        let end = min(samples.count, (last + 1) * chunk + Self.vadPadSamples)
        guard end > start else { return (samples, 0) }
        if start == 0 && end == samples.count { return (samples, 0) }
        var out = Array(samples[start..<end])
        // FluidAudio rejects clips under 0.3 s: pad very short speech with trailing silence.
        if out.count < 16_000 { out += [Float](repeating: 0, count: 16_000 - out.count) }
        return (out, Double(start) / 16_000)
    }

    // MARK: Custom vocabulary

    private var ctc: CtcModels?
    private var ctcLoading: Task<CtcModels, Error>?
    private var boosting: VocabularyBoostingSession?
    private var boostedKey: [String] = []
    private var boostFailures = 0
    private var boostRetryAt: Date?
    private static let boostUsedKey = "fluid.boostUsed"

    private var boostBackingOff: Bool { boostRetryAt.map { Date() < $0 } ?? false }

    /// The CTC keyword-spotting model (parakeet-ctc-110m in FluidAudio's default cache), loaded once and shared by
    /// every vocabulary session.
    private func ctcModels() async throws -> CtcModels {
        if let c = ctc { return c }
        if let t = ctcLoading { return try await t.value }
        let t = Task { try await CtcModels.downloadAndLoad() }
        ctcLoading = t
        defer { ctcLoading = nil }
        let c = try await t.value
        ctc = c
        return c
    }

    /// The boosting session for these terms, rebuilt only when the terms change. A failure (for example no network
    /// for the first CTC download) backs off 1, 2, 4, 8, then 10 minutes and tries again on a later dictation,
    /// instead of turning boosting off until relaunch.
    private func boostSession(_ ranked: [(text: String, aliases: [String])]) async -> VocabularyBoostingSession? {
        let vocab = BoostVocabulary.terms(ranked)
        guard !vocab.terms.isEmpty else { return nil }
        if let b = boosting, vocab.key == boostedKey { return b }
        guard !boostBackingOff else { return nil }
        do {
            let models = try await ctcModels()
            let session = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: vocab.terms),
                                                              ctcModels: models, config: BoostVocabulary.rescorerConfig)
            boosting = session
            boostedKey = vocab.key
            boostFailures = 0
            boostRetryAt = nil
            return session
        } catch {
            boostFailures += 1
            let delay = min(60 * pow(2, Double(min(boostFailures - 1, 4))), 600)
            boostRetryAt = Date().addingTimeInterval(delay)
            Log.note("vocabulary boost unavailable (retry in \(Int(delay)) s): \(error)")
            return nil
        }
    }
}

/// Offline speaker diarization (FluidAudio: Pyannote segmentation, WeSpeaker embeddings, VBx clustering).
actor FluidDiarizer: DiarizationEngine {
    static let shared = FluidDiarizer()
    private var manager: OfflineDiarizerManager?

    /// FluidAudio documents an Apple BNNS bug in macOS 14 that crashes the offline diarizer (1200 of 1200 CI runs;
    /// fixed in macOS 15). A crash can't be caught, so speaker detection runs only on macOS 15 or later. iOS 17 is
    /// not affected (FluidAudio's own check flags macOS 14 only).
    static var isSupported: Bool {
        #if os(macOS)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        #else
        return true
        #endif
    }

    /// Returns no turns where the diarizer could crash; callers already treat that as "no speakers found".
    func diarize(url: URL, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> [(speaker: String, start: Double, end: Double)] {
        guard Self.isSupported else {
            Log.note("diarize skipped: speaker labels need macOS 15")
            return []
        }
        progress(.diarizing)
        let m: OfflineDiarizerManager
        if let existing = manager { m = existing } else {
            let d = OfflineDiarizerManager()
            progress(.downloading("speaker models", nil))
            try await d.prepareModels(directory: Paths.models.appendingPathComponent("diarizer", isDirectory: true))
            manager = d
            m = d
        }
        progress(.diarizing)
        let result = try await m.process(url)
        return result.segments.map { (speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
}

enum SpeakerAssigner {
    /// Gives each segment the speaker who talks for most of its span; builds the speaker list in order of appearance.
    static func assign(_ turns: [(speaker: String, start: Double, end: Double)], to segments: inout [Segment]) -> [Speaker] {
        var order: [String] = []
        for i in segments.indices {
            let s = segments[i]
            var overlap: [String: Double] = [:]
            for t in turns {
                let o = min(s.end, t.end) - max(s.start, t.start)
                if o > 0 { overlap[t.speaker, default: 0] += o }
            }
            if let best = overlap.max(by: { $0.value < $1.value })?.key {
                if !order.contains(best) { order.append(best) }
                segments[i].speaker = "S\(order.firstIndex(of: best)! + 1)"
            }
        }
        return order.indices.map { Speaker(id: "S\($0 + 1)", name: "Speaker \($0 + 1)") }
    }
}
