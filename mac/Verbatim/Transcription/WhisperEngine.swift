import Foundation
import WhisperKit

/// Whisper via WhisperKit (Argmax OSS). Kept as the alternate engine for benchmarking and languages Parakeet misses.
actor WhisperEngine: TranscriptionEngine {
    static let shared = WhisperEngine()
    nonisolated let id = "whisper"

    private var pipe: WhisperKit?
    private var loadedModel: String?

    private func pipeline(for model: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> WhisperKit {
        if let p = pipe, loadedModel == model { return p }
        pipe = nil
        let name = Engines.displayName(engine: "whisper", model: model)
        progress(.downloading(name, nil))
        Log.note("WhisperKit load model=\(model)")
        // Settings › Privacy. With Local Only on, a model already on this Mac loads from its folder with no download
        // (WhisperKit's download step asks Hugging Face for the file list even when the files are here); one that
        // isn't here is a download, which Local Only refuses unless you allowed it.
        let local = LocalOnly.isOn ? Self.localFolder(model) : nil
        let downloads = local == nil && (LocalOnly.isOn || !LocalOnly.modelReady("whisper-" + model))
        var download: UUID?
        if downloads { download = try NetworkGate.begin(.modelDownload, host: "huggingface.co") }
        let p = try await WhisperKit(
            model: model,
            downloadBase: Paths.models,
            modelFolder: local?.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: local == nil
        )
        LocalOnly.markModelReady("whisper-" + model)
        if downloads, let folder = p.modelFolder { NetworkGate.addBytes(download, ModelFiles.bytes(in: folder)) }
        pipe = p
        loadedModel = model
        return p
    }

    func transcribe(url: URL, model: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> EngineResult {
        let p = try await pipeline(for: model, progress: progress)
        // Whisper hears only the speech Silero finds (the noise report: speech detection removed nearly every
        // "Thank you very much" in silence). No detector, or no speech found at all: the whole file, as before.
        let speech = await SpeechMap.shared.probabilities(url: url)
        let clips = speech.map(UnclearRules.speechClips) ?? []
        if let speech { Log.note("whisper: \(clips.count) speech clips, \(Int(UnclearRules.coverage(clips, duration: speech.duration) * 100))% of the audio") }
        progress(.transcribing(nil))
        let results = try await p.transcribe(audioPath: url.path, decodeOptions: Self.options(clips: clips))
        var scored: [ScoredSegment] = []
        var lang: String?
        for r in results {
            lang = lang ?? r.language
            for s in r.segments {
                let text = Self.clean(s.text)
                guard !text.isEmpty else { continue }
                let words = s.words?.map { WordSpan(text: Self.clean($0.word), start: Double($0.start), end: Double($0.end), confidence: Double($0.probability)) }
                    .filter { !$0.text.isEmpty }
                scored.append(ScoredSegment(segment: Segment(start: Double(s.start), end: Double(s.end), text: text, words: words?.isEmpty == true ? nil : words),
                                            avgLogprob: Double(s.avgLogprob), compressionRatio: Double(s.compressionRatio), noSpeechProb: Double(s.noSpeechProb)))
            }
        }
        scored.sort { $0.segment.start < $1.segment.start }
        // Likely hallucinations go (repeated text, text over silence); long pauses inside a segment split it.
        let cleaned = UnclearRules.clean(scored, speech: speech)
        if !cleaned.dropped.isEmpty { Log.note("whisper: dropped \(cleaned.dropped.map { "\($0.value) \($0.key.rawValue)" }.sorted().joined(separator: ", "))") }
        var result = EngineResult(segments: cleaned.kept, language: lang, engine: "whisper", model: Engines.displayName(engine: "whisper", model: model))
        result.speech = speech
        return result
    }

    /// Word timings and probabilities for each segment, only the speech clips (start and end pairs, in seconds)
    /// when there are any, and VAD chunking inside them so long stretches split at a pause. WhisperKit's other
    /// thresholds are the report's: compression ratio 2.4, log probability −1, no-speech 0.6.
    private static func options(clips: [ClosedRange<Double>]) -> DecodingOptions {
        DecodingOptions(skipSpecialTokens: true, wordTimestamps: true,
                        clipTimestamps: clips.flatMap { [Float($0.lowerBound), Float($0.upperBound)] },
                        compressionRatioThreshold: Float(UnclearRules.compressionLimit), logProbThreshold: Float(UnclearRules.logprobLimit),
                        noSpeechThreshold: Float(UnclearRules.noSpeechLimit), chunkingStrategy: .vad)
    }

    /// A complete WhisperKit model for `model` already in Paths.models (models/argmaxinc/whisperkit-coreml/
    /// openai_whisper-<model>), or nil.
    nonisolated static func localFolder(_ model: String) -> URL? {
        let fm = FileManager.default
        let repo = Paths.models.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: repo.path) else { return nil }
        let match = names.filter { $0 == model || $0.hasSuffix("-" + model) || $0.hasSuffix("_" + model) }.sorted { $0.count < $1.count }
        for n in match {
            let dir = repo.appendingPathComponent(n, isDirectory: true)
            if fm.fileExists(atPath: dir.appendingPathComponent("AudioEncoder.mlmodelc").path),
               fm.fileExists(atPath: dir.appendingPathComponent("TextDecoder.mlmodelc").path) { return dir }
        }
        return nil
    }

    /// Whisper emits control tokens such as <|en|> and <|0.00|> inside segment text; strip them.
    nonisolated static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
