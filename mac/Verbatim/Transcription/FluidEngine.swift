import Foundation
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
