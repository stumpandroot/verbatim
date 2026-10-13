import Foundation

/// Model-independent output. Engines fill `words` only when they supply real word timings.
struct EngineResult {
    var segments: [Segment]
    var language: String?
    var engine: String
    var model: String
}

enum EngineProgress {
    case downloading(String, Double?)   // model name, fraction when known
    case loading(String)
    case transcribing(Double?)
    case diarizing
    case applyingDictionary

    var label: String {
        switch self {
        case .downloading(let m, let f): return "Downloading \(m)" + (f.map { String(format: " %.0f%%", $0 * 100) } ?? "")
        case .loading(let m): return "Loading \(m)"
        case .transcribing(let f): return "Transcribing" + (f.map { String(format: " %.0f%%", $0 * 100) } ?? "")
        case .diarizing: return "Finding speakers"
        case .applyingDictionary: return "Applying Dictionary"
        }
    }
}

protocol TranscriptionEngine: Sendable {
    var id: String { get }
    func transcribe(url: URL, model: String, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> EngineResult
}

protocol DiarizationEngine: Sendable {
    func diarize(url: URL, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> [(speaker: String, start: Double, end: Double)]
}

/// What people pick in Settings. Each maps to a tested engine and model; "advanced" exposes the raw choice.
enum QualityPreset: String, CaseIterable, Identifiable, Codable {
    case fast, balanced, accurate, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "High accuracy"
        case .advanced: return "Advanced"
        }
    }
    var note: String {
        switch self {
        case .fast: return "Parakeet Redux · ~220 MB · quick notes"
        case .balanced: return "Parakeet v3 · multilingual · good default"
        case .accurate: return "Parakeet Ultra · slowest, best"
        case .advanced: return "Choose the engine and model yourself"
        }
    }
    /// (engine id, model id)
    var config: (String, String) {
        switch self {
        case .fast: return ("fluid", "redux")
        case .balanced: return ("fluid", "v3")
        case .accurate: return ("fluid", "ultra")
        case .advanced: return ("fluid", "v3")
        }
    }
}

struct EngineOption: Identifiable, Hashable {
    let engine: String, model: String, name: String, note: String
    var id: String { engine + "/" + model }
}

enum Engines {
    static let options: [EngineOption] = [
        EngineOption(engine: "fluid", model: "redux", name: "Parakeet Redux", note: "FluidAudio · smallest download"),
        EngineOption(engine: "fluid", model: "v3", name: "Parakeet TDT v3", note: "FluidAudio · 25 languages"),
        EngineOption(engine: "fluid", model: "v2", name: "Parakeet TDT v2", note: "FluidAudio · English only"),
        EngineOption(engine: "fluid", model: "ultra", name: "Parakeet Ultra", note: "FluidAudio · highest accuracy"),
        EngineOption(engine: "whisper", model: "base", name: "Whisper Base", note: "WhisperKit · small, rough"),
        EngineOption(engine: "whisper", model: "small", name: "Whisper Small", note: "WhisperKit"),
        EngineOption(engine: "whisper", model: "large-v3_turbo", name: "Whisper Large v3 Turbo", note: "WhisperKit · 1.6 GB"),
    ]

    static func engine(for id: String) -> TranscriptionEngine {
        id == "whisper" ? WhisperEngine.shared : FluidEngine.shared
    }

    static func displayName(engine: String, model: String) -> String {
        options.first { $0.engine == engine && $0.model == model }?.name ?? "\(engine)/\(model)"
    }

    /// Splits a flat word list into sentence-ish segments at punctuation or long pauses, keeping word timings.
    static func segments(fromWords words: [WordSpan], maxWords: Int = 28, pause: Double = 1.2) -> [Segment] {
        var out: [Segment] = []
        var cur: [WordSpan] = []
        func flush() {
            guard !cur.isEmpty else { return }
            out.append(Segment(start: cur.first!.start, end: cur.last!.end, text: cur.map(\.text).joined(separator: " "), words: cur))
            cur = []
        }
        for (i, w) in words.enumerated() {
            cur.append(w)
            let endsSentence = w.text.last.map { ".!?".contains($0) } ?? false
            let longPause = i + 1 < words.count && words[i + 1].start - w.end > pause
            if (endsSentence && cur.count >= 6) || longPause || cur.count >= maxWords { flush() }
        }
        flush()
        return out
    }
}
