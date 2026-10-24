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
        // Settings › Privacy: a model that isn't on this device yet is a download, which Local Only refuses.
        let downloads = !AsrModels.modelsExist(at: dir, version: Self.version(model))
        var download: UUID?
        if downloads { download = try NetworkGate.begin(.modelDownload, host: "huggingface.co") }
        let models = try await AsrModels.downloadAndLoad(to: dir, version: Self.version(model)) { p in
            progress(.downloading(name, p.fractionCompleted))
        }
        if downloads { NetworkGate.addBytes(download, ModelFiles.bytes(in: dir)) }
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
        loaded = model
        return m
    }

    func transcribe(url: URL, model requested: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> EngineResult {
        try await transcribe(url: url, model: requested, language: nil, progress: progress)
    }

    /// `language` (an ISO 639-1 code) keeps v3-family models to that language's alphabet; v2 ignores it.
    func transcribe(url: URL, model requested: String, language: String?, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> EngineResult {
        let model = Engines.fluidModel(requested)
        let m = try await prepared(model, progress: progress)
        progress(.transcribing(nil))
        var state = TdtDecoderState.make()
        let r = try await m.transcribe(url, decoderState: &state, language: Self.hint(language, model: model))
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
        return EngineResult(segments: segments, language: language, engine: "fluid", model: Engines.displayName(engine: "fluid", model: model))
    }

    /// FluidAudio's language hint: v3-family models only, and only for languages it lists.
    private static func hint(_ language: String?, model: String) -> Language? {
        guard let language, LanguageRules.isMultilingual(model) else { return nil }
        return Language(rawValue: LanguageRules.base(language))
    }

    /// Whether a Parakeet model's files are already on this device (no download needed to use it).
    nonisolated static func isDownloaded(_ model: String) -> Bool {
        let model = Engines.fluidModel(model)
        let dir = Paths.models.appendingPathComponent("parakeet-\(model)", isDirectory: true)
        return AsrModels.modelsExist(at: dir, version: version(model))
    }

    /// One section of a long recording (or the first seconds, for the language check): 16 kHz mono samples in
    /// memory, words timed from the samples' start. Downloads and loads the model when needed.
    func sectionWords(samples: [Float], model requested: String, language: String?,
                      progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }) async throws -> [SectionWord] {
        try await clipWords(samples: samples, model: requested, language: language, progress: progress).words
    }

    /// `sectionWords` with the model's average token confidence (0.1…1), for the language check.
    func clipWords(samples: [Float], model requested: String, language: String?,
                   progress: @escaping @Sendable (EngineProgress) -> Void = { _ in }) async throws -> (words: [SectionWord], confidence: Double) {
        let model = Engines.fluidModel(requested)
        let m = try await prepared(model, progress: progress)
        if let p = prewarming, p.model == model { await p.task.value }
        var input = samples
        // FluidAudio rejects clips under 0.3 s: pad very short audio with trailing silence.
        if input.count < 16_000 { input += [Float](repeating: 0, count: 16_000 - input.count) }
        var state = TdtDecoderState.make()
        let r = try await m.transcribe(input, decoderState: &state, language: Self.hint(language, model: model))
        let words = buildWordTimings(from: r.tokenTimings ?? []).compactMap { w -> SectionWord? in
            let text = w.word.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : SectionWord(text: text, start: w.startTime, end: w.endTime)
        }
        return (words, Double(r.confidence))
    }

    /// Transcribes 16 kHz mono samples already in memory, with nothing else: no file read, no speech detection,
    /// no vocabulary boosting. `transcribeSession` is the keyboard's path, with both.
    func transcribe(samples: [Float], model requested: String) async throws -> EngineResult {
        let model = Engines.fluidModel(requested)
        let m = try await prepared(model, progress: { _ in })
        // Don't interleave with a warm-up inference on the same model; it finishes in about a second.
        if let p = prewarming, p.model == model { await p.task.value }
        var input = samples
        // FluidAudio rejects clips under 0.3 s: pad very short speech with trailing silence.
        if input.count < 16_000 { input += [Float](repeating: 0, count: 16_000 - input.count) }
        var state = TdtDecoderState.make()
        let r = try await m.transcribe(input, decoderState: &state)
        let words: [WordSpan] = buildWordTimings(from: r.tokenTimings ?? []).map {
            WordSpan(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.startTime, end: $0.endTime)
        }.filter { !$0.text.isEmpty }
        let duration = Double(samples.count) / 16_000
        let segments: [Segment]
        if words.isEmpty {
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            segments = text.isEmpty ? [] : [Segment(start: 0, end: duration, text: text)]
        } else {
            segments = Engines.segments(fromWords: words)
        }
        return EngineResult(segments: segments, language: nil, engine: "fluid", model: Engines.displayName(engine: "fluid", model: model))
    }

    /// The iPhone keyboard session's hot path: 16 kHz mono samples already in memory. Like `transcribeDictation`, it
    /// trims leading and trailing silence (Silero VAD) and boosts your Dictionary words, but it never waits for
    /// either to load and caps the boost at `boostBudget` seconds, so the dictation stays near its 1.5 s target:
    /// - Speech detection is used once it's loaded (`prewarm(dictation: true)` starts it); until then (or when it
    ///   fails) `fallbackTrim` trims instead, when given (the iPhone passes a loudness-based trim).
    /// - Boosting runs only with a session already built for these terms; otherwise one is built in the background
    ///   for the next dictation. A rescore that takes longer than `boostBudget` is dropped (the plain text is used)
    ///   and logged. Either failure falls back to the plain transcript.
    /// `ranked` comes from `BoostVocabulary.rank`. Word timings are kept when the boost changed nothing.
    func transcribeSession(samples: [Float], model requested: String, ranked: [(text: String, aliases: [String])],
                           boostBudget: Double = 0.3,
                           fallbackTrim: (([Float]) -> (samples: [Float], start: Double))? = nil) async throws -> EngineResult {
        let model = Engines.fluidModel(requested)
        let m = try await prepared(model, progress: { _ in })
        if let p = prewarming, p.model == model { await p.task.value }
        let name = Engines.displayName(engine: "fluid", model: model)
        let fullDuration = Double(samples.count) / 16_000
        let t0 = Date()
        var trimmed: (samples: [Float], start: Double)?
        if vad != nil, samples.count <= Self.vadMaxSamples {
            trimmed = await trimSilence(samples)
            if trimmed == nil { Log.note("VAD: no speech detected; transcribing the full audio anyway") }
        } else {
            startVadLoad()
            trimmed = fallbackTrim.map { $0(samples) } ?? (samples: samples, start: 0)
        }
        var input = trimmed?.samples ?? samples
        let offset = trimmed?.start ?? 0
        let trimTime = Date().timeIntervalSince(t0)
        if input.count < samples.count {
            Log.note("keyboard trim: \(String(format: "%.1f", fullDuration)) s → \(String(format: "%.1f", Double(input.count) / 16_000)) s in \(Int(trimTime * 1000)) ms")
        }
        // FluidAudio rejects clips under 0.3 s: pad very short speech with trailing silence.
        if input.count < 16_000 { input += [Float](repeating: 0, count: 16_000 - input.count) }
        var state = TdtDecoderState.make()
        let r = try await m.transcribe(input, decoderState: &state)
        let plain = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = plain
        if !ranked.isEmpty, !plain.isEmpty, let timings = r.tokenTimings, !timings.isEmpty {
            if let session = readyBoostSession(ranked) {
                let t1 = Date()
                let audio = input
                let raw = r.text
                let box = BoostBox(session)
                let out = await Self.race(seconds: boostBudget) {
                    await box.session.rescore(text: raw, tokenTimings: timings, audioSamples: audio)
                }
                let took = Date().timeIntervalSince(t1)
                switch out {
                case .none:
                    Log.note("keyboard boost: skipped, took over \(Int(boostBudget * 1000)) ms")
                case .some(.none):
                    break
                case .some(.some(let o)):
                    if !o.detectedTerms.isEmpty { Log.note("keyboard boost heard \(o.detectedTerms.count) term(s) in \(Int(took * 1000)) ms") }
                    if o.wasModified {
                        let guarded = BoostGuard.filter(original: r.text, boosted: o.text, terms: ranked)
                        if guarded.reverted > 0 { Log.note("vocabulary boost: kept \(guarded.kept), reverted \(guarded.reverted) unlikely swap(s)") }
                        text = guarded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } else {
                Log.note("keyboard boost: skipped, vocabulary model not ready yet")
            }
        }
        let segments: [Segment]
        if text.isEmpty {
            segments = []
        } else if text == plain, let timings = r.tokenTimings, !timings.isEmpty {
            let words: [WordSpan] = buildWordTimings(from: timings).map {
                WordSpan(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.startTime + offset, end: $0.endTime + offset)
            }.filter { !$0.text.isEmpty }
            segments = words.isEmpty ? [Segment(start: 0, end: fullDuration, text: text)] : Engines.segments(fromWords: words)
        } else {
            segments = [Segment(start: 0, end: fullDuration, text: text)]
        }
        return EngineResult(segments: segments, language: nil, engine: "fluid", model: name)
    }

    /// Carries the boosting session into the race's task.
    private final class BoostBox: @unchecked Sendable {
        let session: VocabularyBoostingSession
        init(_ s: VocabularyBoostingSession) { session = s }
    }

    /// The boosting session when one is already built for these terms. Otherwise starts building it in the
    /// background (unless boosting is backing off after a failure) and returns nil, so this dictation doesn't wait.
    /// Terms that changed while a build was running go here and are built right after it.
    private func readyBoostSession(_ ranked: [(text: String, aliases: [String])]) -> VocabularyBoostingSession? {
        let vocab = BoostVocabulary.terms(ranked)
        guard !vocab.terms.isEmpty else { return nil }
        let d = BoostReadiness.decide(hasSession: boosting != nil, keyMatches: vocab.key == boostedKey,
                                      backingOff: boostBackingOff, building: boostBuilding)
        if d.use { return boosting }
        if d.queue { boostPending = ranked }
        if d.build {
            boostBuilding = true
            Task {
                var next: [(text: String, aliases: [String])]? = ranked
                while let terms = next {
                    _ = await self.boostSession(terms)
                    next = self.boostPending
                    self.boostPending = nil
                }
                self.boostBuilding = false
            }
        }
        return nil
    }

    private var boostBuilding = false
    private var boostPending: [(text: String, aliases: [String])]?

    /// Builds the boosting session for your Dictionary in the background, so the next dictation can use it without
    /// waiting. The Mac calls this at launch and whenever the Dictionary, the built-in vocabulary, or the active
    /// project changes. Returns at once; does nothing when the session already matches.
    func prepareBoost(dictionary: [DictionaryEntry], project: UUID?) {
        _ = readyBoostSession(BoostVocabulary.rank(dictionary, project: project))
    }

    /// Returns the work's result, or nil when `seconds` pass first. Unlike a task group, it doesn't wait for work
    /// that ignores cancellation: that work finishes in the background and its result is dropped.
    nonisolated static func race<T>(seconds: Double, _ work: @escaping () async -> T) async -> T? {
        let once = RaceOnce()
        let job = RaceJob(work)
        let box: RaceBox<T>? = await withCheckedContinuation { (cont: CheckedContinuation<RaceBox<T>?, Never>) in
            let worker = Task.detached(priority: .userInitiated) {
                let v = RaceBox(await job.work())
                if once.claim() { cont.resume(returning: v) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.claim() { worker.cancel(); cont.resume(returning: nil) }
            }
        }
        return box?.value
    }

    /// `race` with a limit, or the work's result whenever it comes with none.
    private nonisolated static func race<T>(limit: Double?, _ work: @escaping () async -> T) async -> T? {
        guard let limit else { return await work() }
        return await race(seconds: limit, work)
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
    func prewarm(model requested: String, boostTerms: [(text: String, aliases: [String])]? = nil, dictation: Bool = false) async {
        let model = Engines.fluidModel(requested)
        startDictationHelpers()
        // The iPhone keyboard session dictates too: load the speech detector for its silence trimming.
        if dictation { startVadLoad() }
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
    /// The boost never makes the dictation wait (see `dictation`).
    func transcribeDictation(url: URL, model: String, dictionary: [DictionaryEntry], project: UUID?) async throws -> EngineResult {
        try await dictation(url: url, model: model, ranked: BoostVocabulary.rank(dictionary, project: project), waitForBoost: false)
    }

    /// Same as `transcribeDictation`, for callers that pass bare terms (oldest first, as the Dictionary stores
    /// them). Empty `terms` is fine: you still get speech detection, just no boosting. Waits for the boost to be
    /// built and to finish rescoring, so the speech bench always measures it.
    func transcribeBoosted(url: URL, model: String, terms: [(text: String, aliases: [String])]) async throws -> EngineResult {
        try await dictation(url: url, model: model, ranked: BoostVocabulary.rankByPosition(terms), waitForBoost: true)
    }

    private func dictation(url: URL, model requested: String, ranked: [(text: String, aliases: [String])], waitForBoost: Bool) async throws -> EngineResult {
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
        // The boost never holds up a dictation: it runs only with a session already built for these terms (one is
        // built in the background otherwise, for the next dictation), and a rescore past its budget is dropped.
        // The bench (`waitForBoost`) builds the session and lets the rescore finish.
        if !ranked.isEmpty, !text.isEmpty, let timings = r.tokenTimings, !timings.isEmpty {
            let ready: VocabularyBoostingSession?
            if waitForBoost { ready = await boostSession(ranked) } else { ready = readyBoostSession(ranked) }
            if let session = ready {
                let budget = DictationTiming.boostBudget(audioSeconds: Double(samples.count) / 16_000)
                let t1 = Date()
                let audio = samples
                let raw = r.text
                let box = BoostBox(session)
                let out = await Self.race(limit: waitForBoost ? nil : budget) {
                    await box.session.rescore(text: raw, tokenTimings: timings, audioSamples: audio)
                }
                switch out {
                case .none:
                    Log.note("vocabulary boost: skipped, took over \(Int(budget * 1000)) ms")
                case .some(.none):
                    break
                case .some(.some(let o)):
                    if !o.detectedTerms.isEmpty { Log.note("vocabulary boost heard \(o.detectedTerms.count) term(s) in \(Int(Date().timeIntervalSince(t1) * 1000)) ms") }
                    if o.wasModified {
                        // Keep only swaps that sound like the Dictionary word they bring in (bench 121–123: the rescorer
                        // turned "it to" into "Lititz" and "at all" / "last year." into "Castwell").
                        let guarded = BoostGuard.filter(original: r.text, boosted: o.text, terms: ranked)
                        if guarded.reverted > 0 { Log.note("vocabulary boost: kept \(guarded.kept), reverted \(guarded.reverted) unlikely swap(s)") }
                        text = guarded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } else {
                Log.note("vocabulary boost: skipped, vocabulary model not ready yet")
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

    /// Starts the background loads dictation needs (the speech detector). Mac only here: the iPhone loads it only
    /// for a keyboard session (`prewarm(dictation: true)`), not for every voice memo.
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
            // The first load downloads the model: logged, and refused while Local Only is on (Settings › Privacy).
            if !LocalOnly.modelReady("vad") { try NetworkGate.begin(.modelDownload, host: "huggingface.co") }
            vad = try await VadManager(config: VadConfig(defaultThreshold: Self.vadThreshold))
            LocalOnly.markModelReady("vad")
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
        // The first load downloads the model: logged, and refused while Local Only is on (Settings › Privacy).
        if !LocalOnly.modelReady("ctc") { try NetworkGate.begin(.modelDownload, host: "huggingface.co") }
        let t = Task { try await CtcModels.downloadAndLoad() }
        ctcLoading = t
        defer { ctcLoading = nil }
        let c = try await t.value
        LocalOnly.markModelReady("ctc")
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

/// `FluidEngine.race` helpers: the first of the work and the timer to finish claims the result.
private final class RaceOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
private final class RaceBox<V>: @unchecked Sendable {
    let value: V
    init(_ v: V) { value = v }
}
private final class RaceJob<V>: @unchecked Sendable {
    let work: () async -> V
    init(_ w: @escaping () async -> V) { work = w }
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
        try await diarizeDetailed(url: url, progress: progress).turns
    }

    /// Turns plus one voice embedding per speaker (VoiceProfile compares them with yours). Empty where the diarizer
    /// could crash.
    func diarizeDetailed(url: URL, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> DiarizationOutput {
        guard Self.isSupported else {
            Log.note("diarize skipped: speaker labels need macOS 15")
            return DiarizationOutput(turns: [], embeddings: [:])
        }
        progress(.diarizing)
        await acquire()
        defer { release() }
        let m = try await prepared(progress)
        progress(.diarizing)
        return Self.output(try await m.process(url))
    }

    /// The same analysis on 16 kHz mono samples already in memory (voice profile enrollment, dictation).
    func diarize(samples: [Float]) async throws -> DiarizationOutput {
        guard Self.isSupported else { return DiarizationOutput(turns: [], embeddings: [:]) }
        guard !samples.isEmpty else { throw VoiceProfile.Failure.noSpeech }
        await acquire()
        defer { release() }
        let m = try await prepared({ _ in })
        return Self.output(try await m.process(audio: samples))
    }

    // One analysis at a time. An actor runs other calls while one awaits, so without this a voice enrollment and
    // a transcript's speaker detection could download, compile, or run the same models at once.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    private func prepared(_ progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> OfflineDiarizerManager {
        if let existing = manager { return existing }
        // Per-chunk embeddings on: they're how VoiceProfile recognizes your voice (about 1–2 MB per hour of audio).
        var config = OfflineDiarizerConfig.default
        config.exposeChunkEmbeddings = true
        let d = OfflineDiarizerManager(config: config)
        progress(.downloading("speaker models", nil))
        let dir = Paths.models.appendingPathComponent("diarizer", isDirectory: true)
        // The first run downloads the speaker models: logged, and refused while Local Only is on (Settings › Privacy).
        let downloads = !LocalOnly.modelReady("diarizer")
        var download: UUID?
        if downloads { download = try NetworkGate.begin(.modelDownload, host: "huggingface.co") }
        try await d.prepareModels(directory: dir)
        LocalOnly.markModelReady("diarizer")
        if downloads { NetworkGate.addBytes(download, ModelFiles.bytes(in: dir)) }
        manager = d
        return d
    }

    /// Turns from the segments; each speaker's embedding is the mean of its chunks' L2-normalized 256-dimension
    /// WeSpeaker embeddings (`ChunkEmbedding.embedding256`), normalized again.
    private static func output(_ result: DiarizationResult) -> DiarizationOutput {
        let turns = result.segments.map { (speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        let speakers = Set(turns.map(\.speaker))
        var grouped: [String: [[Float]]] = [:]
        for c in result.chunkEmbeddings ?? [] where speakers.contains(c.speakerId) && !c.embedding256.isEmpty {
            grouped[c.speakerId, default: []].append(c.embedding256)
        }
        var embeddings: [String: [Float]] = [:]
        for (id, list) in grouped { if let mean = VoiceMath.mean(list) { embeddings[id] = mean } }
        return DiarizationOutput(turns: turns, embeddings: embeddings, chunks: grouped)
    }
}

/// What the diarizer found: who spoke when, and each speaker's voice embedding (keyed like `turns`' speaker).
struct DiarizationOutput: Sendable {
    var turns: [(speaker: String, start: Double, end: Double)]
    var embeddings: [String: [Float]]
    /// Every chunk embedding per speaker, for enrollment quality.
    var chunks: [String: [[Float]]] = [:]

    /// Seconds each speaker talks.
    var seconds: [String: Double] {
        var out: [String: Double] = [:]
        for t in turns { out[t.speaker, default: 0] += max(0, t.end - t.start) }
        return out
    }
}

/// Speaker labels from a diarization (SpeakerTurns does the word-by-word work, shared with the Linux tests).
enum SpeakerAssigner {
    /// Gives each line the speaker its words belong to, without cutting any line (Continue keeps lines matched by
    /// index); builds the speaker list in order of appearance.
    static func assign(_ turns: [(speaker: String, start: Double, end: Double)], to segments: inout [Segment]) -> [Speaker] {
        var none: [Segment]? = nil
        return assignMapped(turns, to: &segments, parallel: &none, split: false).speakers
    }

    /// Like `assign`, also returning which diarizer label became which speaker id ("S3" → "S1"). With `split`, a
    /// line whose words change speaker is cut at the sentence boundary nearest the change (`parallel`, matched by
    /// index, gets the same cuts).
    static func assignMapped(_ turns: [(speaker: String, start: Double, end: Double)], to segments: inout [Segment],
                             parallel: inout [Segment]?, split: Bool, keepWhole: Set<UUID> = []) -> (speakers: [Speaker], map: [String: String]) {
        let order = SpeakerTurns.assign(turns, to: &segments, parallel: &parallel, split: split, keepWhole: keepWhole)
        var map: [String: String] = [:]
        for (i, label) in order.enumerated() { map[label] = "S\(i + 1)" }
        return (order.indices.map { Speaker(id: "S\($0 + 1)", name: "Speaker \($0 + 1)") }, map)
    }

    /// Speakers from a diarization, with the one who sounds like you named "You" (VoiceProfile, once enrolled).
    /// Lines are cut where the speaker changes.
    static func assign(_ out: DiarizationOutput, to segments: inout [Segment]) -> [Speaker] {
        var none: [Segment]? = nil
        return assign(out, to: &segments, parallel: &none)
    }

    /// The same for a finished transcript: `parallel` is its original lines (cut alongside), and lines with
    /// corrections (`keepWhole`) stay whole.
    static func assign(_ out: DiarizationOutput, to segments: inout [Segment], parallel: inout [Segment]?, keepWhole: Set<UUID> = []) -> [Speaker] {
        let mapped = assignMapped(out.turns, to: &segments, parallel: &parallel, split: true, keepWhole: keepWhole)
        var speakers = mapped.speakers
        VoiceProfile.labelYou(&speakers, embeddings: out.embeddings, map: mapped.map)
        return speakers
    }
}
