import Foundation

/// One transcription, start to finish, shared by the Mac and the iPhone: engine, optional speakers,
/// Dictionary fixes, and the waveform. No UI and no Store access, so it runs off the main thread.
struct JobOutcome {
    var original: [Segment]
    var fixed: [Segment]
    var speakers: [Speaker]
    var corrections: [Correction]
    var wave: [Float]
    var engine: String
    var model: String
    var language: String?
}

enum TranscriptionJob {
    static func run(url: URL, engineId: String, model: String, wantSpeakers: Bool, dictionary: [DictionaryEntry],
                    project: UUID?, needWave: Bool, progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> JobOutcome {
        let engine = Engines.engine(for: engineId)
        var result = try await engine.transcribe(url: url, model: model, progress: progress)
        Log.note("transcribe done segments=\(result.segments.count)")
        var speakers: [Speaker] = []
        if wantSpeakers, result.segments.count > 1 {
            do {
                let turns = try await FluidDiarizer.shared.diarize(url: url, progress: progress)
                speakers = SpeakerAssigner.assign(turns, to: &result.segments)
                Log.note("diarize done speakers=\(speakers.count)")
            } catch {
                Log.note("diarize failed (kept transcript): \(error)")
            }
        }
        let original = result.segments
        var fixed = result.segments
        var corrections: [Correction] = []
        if !dictionary.isEmpty {
            progress(.applyingDictionary)
            corrections = DictionaryApplier.apply(dictionary, to: &fixed, project: project)
        }
        let wave = needWave ? Waveform.envelope(of: url) : []
        return JobOutcome(original: original, fixed: fixed, speakers: speakers, corrections: corrections, wave: wave,
                          engine: result.engine, model: result.model, language: result.language)
    }
}
