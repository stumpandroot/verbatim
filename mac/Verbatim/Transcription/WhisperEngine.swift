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
        progress(.transcribing(nil))
        let results = try await p.transcribe(audioPath: url.path, decodeOptions: Self.options)
        var out: [Segment] = []
        var lang: String?
        for r in results {
            lang = lang ?? r.language
            for s in r.segments {
                let text = Self.clean(s.text)
                guard !text.isEmpty else { continue }
                let words = s.words?.map { WordSpan(text: Self.clean($0.word), start: Double($0.start), end: Double($0.end)) }.filter { !$0.text.isEmpty }
                out.append(Segment(start: Double(s.start), end: Double(s.end), text: text, words: words?.isEmpty == true ? nil : words))
            }
        }
        return EngineResult(segments: out, language: lang, engine: "whisper", model: Engines.displayName(engine: "whisper", model: model))
    }

    /// Word timings for each segment, and energy-VAD chunking so long silences are skipped instead of filled
    /// with invented words. Other thresholds stay at WhisperKit's defaults.
    private static var options: DecodingOptions {
        DecodingOptions(skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
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
