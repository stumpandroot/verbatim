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

    private func prepared(_ model: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> AsrManager {
        if let m = manager, loaded == model { return m }
        manager = nil
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

    func transcribe(url: URL, model: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> EngineResult {
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

    /// Loads the model ahead of time so the first dictation doesn't wait for it.
    func warm(model: String) async {
        _ = try? await prepared(model, progress: { _ in })
    }

    // MARK: Custom vocabulary (dictation)

    private var boosting: VocabularyBoostingSession?
    private var boostedTerms: [String] = []
    private var boostUnavailable = false

    /// Transcribes a short dictation and rescores it against your Dictionary words with FluidAudio's CTC
    /// keyword spotter (a second small model that listens for those exact terms). Best under 100 terms.
    /// Any failure falls back to the plain transcript: boosting must never break dictation.
    func transcribeBoosted(url: URL, model: String, terms: [(text: String, aliases: [String])]) async throws -> EngineResult {
        let m = try await prepared(model, progress: { _ in })
        var state = TdtDecoderState.make()
        let r = try await m.transcribe(url, decoderState: &state)
        var text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty, !boostUnavailable, let session = await boostSession(terms), let timings = r.tokenTimings, !timings.isEmpty,
           let samples = Self.samples(url) {
            if session.hasCTCRescoringCandidates(text: r.text, tokenTimings: timings),
               let out = await session.rescore(text: r.text, tokenTimings: timings, audioSamples: samples), out.wasModified {
                Log.note("vocabulary boost changed the transcript")
                text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let segments = text.isEmpty ? [] : [Segment(start: 0, end: r.duration, text: text)]
        return EngineResult(segments: segments, language: nil, engine: "fluid", model: Engines.displayName(engine: "fluid", model: model))
    }

    private func boostSession(_ terms: [(text: String, aliases: [String])]) async -> VocabularyBoostingSession? {
        let key = terms.map { $0.text + "|" + $0.aliases.joined(separator: ",") }.sorted()
        if let b = boosting, key == boostedTerms { return b }
        do {
            let ctc = try await CtcModels.downloadAndLoad()
            let vocab = CustomVocabularyContext(terms: terms.prefix(100).map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) })
            let session = try await VocabularyBoostingSession(vocabulary: vocab, ctcModels: ctc)
            boosting = session; boostedTerms = key
            return session
        } catch {
            Log.note("vocabulary boost unavailable: \(error)")
            boostUnavailable = true
            return nil
        }
    }

    /// 16 kHz mono float samples of a recording (dictations are short, so reading it whole is fine).
    private static func samples(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let inCap = AVAudioFrameCount(file.length)
        guard inCap > 0, let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCap), (try? file.read(into: input)) != nil else { return nil }
        let outCap = AVAudioFrameCount(Double(inCap) * 16_000 / file.processingFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCap) else { return nil }
        var fed = false
        var err: NSError?
        _ = converter.convert(to: output, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        guard err == nil, let ch = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(output.frameLength)))
    }
}

/// Offline speaker diarization (FluidAudio: Pyannote segmentation, WeSpeaker embeddings, VBx clustering).
actor FluidDiarizer: DiarizationEngine {
    static let shared = FluidDiarizer()
    private var manager: OfflineDiarizerManager?

    func diarize(url: URL, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> [(speaker: String, start: Double, end: Double)] {
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
