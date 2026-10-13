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
        let p = try await WhisperKit(
            model: model,
            downloadBase: Paths.models,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
        pipe = p
        loadedModel = model
        return p
    }

    func transcribe(url: URL, model: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> EngineResult {
        let p = try await pipeline(for: model, progress: progress)
        progress(.transcribing(nil))
        let results = try await p.transcribe(audioPath: url.path)
        var out: [Segment] = []
        var lang: String?
        for r in results {
            lang = lang ?? r.language
            for s in r.segments {
                let text = Self.clean(s.text)
                guard !text.isEmpty else { continue }
                let words = s.words?.map { WordSpan(text: $0.word.trimmingCharacters(in: .whitespaces), start: Double($0.start), end: Double($0.end)) }
                out.append(Segment(start: Double(s.start), end: Double(s.end), text: text, words: words))
            }
        }
        return EngineResult(segments: out, language: lang, engine: "whisper", model: Engines.displayName(engine: "whisper", model: model))
    }

    /// Whisper emits control tokens such as <|en|> and <|0.00|> inside segment text; strip them.
    nonisolated static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
