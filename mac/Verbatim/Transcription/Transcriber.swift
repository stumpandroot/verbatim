import Foundation
import WhisperKit

/// One WhisperKit pipeline, loaded on first use and kept warm. Models download once into
/// ~/Library/Application Support/Verbatim/models and run on this Mac.
actor Transcriber {
    static let shared = Transcriber()

    static let models: [(id: String, name: String, note: String)] = [
        ("tiny", "Tiny", "Fastest, rough"),
        ("base", "Base", "Quick notes"),
        ("small", "Small", "Good balance"),
        ("large-v3_turbo", "Large v3 Turbo", "Best quality, 1.6 GB"),
    ]

    static func displayName(_ id: String) -> String {
        models.first { $0.id == id }?.name ?? id
    }

    private var pipe: WhisperKit?
    private var loadedModel: String?

    private func pipeline(for model: String) async throws -> WhisperKit {
        if let p = pipe, loadedModel == model { return p }
        pipe = nil
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

    func transcribe(url: URL, model: String) async throws -> [Segment] {
        let p = try await pipeline(for: model)
        let results = try await p.transcribe(audioPath: url.path)
        var out: [Segment] = []
        for r in results {
            for s in r.segments {
                let text = Self.clean(s.text)
                guard !text.isEmpty else { continue }
                out.append(Segment(start: Double(s.start), end: Double(s.end), text: text))
            }
        }
        return out
    }

    /// Whisper emits control tokens such as <|en|> and <|0.00|> inside segment text; strip them.
    nonisolated static func clean(_ s: String) -> String {
        let stripped = s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
