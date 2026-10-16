import Foundation
import AVFoundation

/// Continue a recording: add new audio to the end of an existing transcript.
///
/// Only the new part is transcribed. Its lines are shifted to start where the old recording ended, the two
/// recordings are joined into one file (so playback and the waveform cover both), and speakers found in the new
/// part keep the names you already gave them when they're the same voices. Shared by the Mac and the iPhone.
enum Continuation {
    struct Outcome {
        var original: [Segment]       // the new part's engine output, shifted
        var fixed: [Segment]          // the same with Dictionary fixes
        var corrections: [Correction]
        var speakers: [Speaker]?      // the whole transcript's speakers, when they were worked out
        var oldSpeakerLabels: [UUID: String]  // existing segments whose speaker changed (only when they had none before)
        var combinedSeconds: Double
        var wave: [Float]
    }

    /// Joins `a` then `b` into one 16 kHz mono WAV at `dest`, reading and writing in chunks. Returns its length.
    static func join(_ a: URL, _ b: URL, to dest: URL) throws -> Double {
        let out = try AVAudioFile(forWriting: dest, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        var frames: AVAudioFramePosition = 0
        for src in [a, b] {
            let file = try AVAudioFile(forReading: src)
            let inFormat = file.processingFormat
            guard let converter = AVAudioConverter(from: inFormat, to: recordingFormat) else {
                throw NSError(domain: "Verbatim", code: 20, userInfo: [NSLocalizedDescriptionKey: "Couldn't read \(src.lastPathComponent)."])
            }
            let chunk: AVAudioFrameCount = 1 << 15
            var done = false
            while !done {
                let ratio = recordingFormat.sampleRate / inFormat.sampleRate
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 64) else { break }
                var err: NSError?
                let status = converter.convert(to: outBuf, error: &err) { _, st in
                    // A fresh buffer per request: the converter may still hold the previous one.
                    guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { st.pointee = .endOfStream; return nil }
                    do {
                        try file.read(into: inBuf, frameCount: chunk)
                    } catch { st.pointee = .endOfStream; return nil }
                    if inBuf.frameLength == 0 { st.pointee = .endOfStream; return nil }
                    st.pointee = .haveData
                    return inBuf
                }
                if let err { throw err }
                if outBuf.frameLength > 0 { try out.write(from: outBuf); frames += AVAudioFramePosition(outBuf.frameLength) }
                if status == .endOfStream || status == .error { done = true }
            }
        }
        return Double(frames) / recordingFormat.sampleRate
    }

    /// Transcribes `part` (recorded after `existing` ended), joins the audio into `combined`, and works out speakers.
    static func run(existing: Transcript, existingAudio: URL, part: URL, combined: URL,
                    engineId: String, model: String, wantSpeakers: Bool, dictionary: [DictionaryEntry],
                    progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> Outcome {
        let offset = existing.duration
        let result = try await Engines.engine(for: engineId).transcribe(url: part, model: model, progress: progress)
        let shifted = result.segments.map { s -> Segment in
            var x = s; x.start += offset; x.end += offset
            x.words = s.words?.map { w in var v = w; v.start += offset; v.end += offset; return v }
            return x
        }
        var fixed = shifted
        let corrections = dictionary.isEmpty ? [] : DictionaryApplier.apply(dictionary, to: &fixed, project: existing.projectId)
        let seconds = try join(existingAudio, part, to: combined)

        var speakers: [Speaker]? = nil
        var relabeled: [UUID: String] = [:]
        let all = existing.segments + fixed
        if wantSpeakers, all.count > 1 {
            do {
                let turns = try await FluidDiarizer.shared.diarize(url: combined, progress: progress)
                if existing.speakers.isEmpty {
                    // No speakers yet: label everything fresh (nothing named to lose).
                    var everything = all
                    let found = SpeakerAssigner.assign(turns, to: &everything)
                    if found.count >= 2 {
                        speakers = found
                        for s in everything.prefix(existing.segments.count) { if let l = s.speaker { relabeled[s.id] = l } }
                        for i in fixed.indices { fixed[i].speaker = everything[existing.segments.count + i].speaker }
                    }
                } else {
                    // Map each voice in the new audio to the existing speaker it overlaps most in the old part.
                    var vote: [String: [String: Double]] = [:]   // diarizer label → existing id → seconds
                    for seg in existing.segments {
                        guard let id = seg.speaker else { continue }
                        for t in turns {
                            let o = min(seg.end, t.end) - max(seg.start, t.start)
                            if o > 0 { vote[t.speaker, default: [:]][id, default: 0] += o }
                        }
                    }
                    var map: [String: String] = vote.compactMapValues { $0.max { $0.value < $1.value }?.key }
                    var list = existing.speakers
                    for i in fixed.indices {
                        var overlap: [String: Double] = [:]
                        for t in turns {
                            let o = min(fixed[i].end, t.end) - max(fixed[i].start, t.start)
                            if o > 0 { overlap[t.speaker, default: 0] += o }
                        }
                        guard let voice = overlap.max(by: { $0.value < $1.value })?.key else { continue }
                        if map[voice] == nil {
                            let id = "S\(list.count + 1)"
                            list.append(Speaker(id: id, name: "Speaker \(list.count + 1)"))
                            map[voice] = id
                        }
                        fixed[i].speaker = map[voice]
                    }
                    speakers = list
                }
            } catch {
                Log.note("continue: diarize failed (kept transcript): \(error)")
            }
        }
        var original = shifted
        for i in original.indices where i < fixed.count { original[i].speaker = fixed[i].speaker }
        return Outcome(original: original, fixed: fixed, corrections: corrections, speakers: speakers, oldSpeakerLabels: relabeled,
                       combinedSeconds: seconds, wave: Waveform.envelope(of: combined))
    }

    /// Applies an outcome to the transcript.
    static func apply(_ out: Outcome, to t: inout Transcript, combinedName: String) {
        if !out.oldSpeakerLabels.isEmpty {
            for i in t.segments.indices { if let l = out.oldSpeakerLabels[t.segments[i].id] { t.segments[i].speaker = l } }
            for i in t.original.indices { if i < t.segments.count { t.original[i].speaker = t.segments[i].speaker } }
        }
        t.original += out.original
        t.segments += out.fixed
        t.corrections += out.corrections
        if let s = out.speakers { t.speakers = s }
        t.duration = out.combinedSeconds
        t.audioFileName = combinedName
        if !out.wave.isEmpty { t.waveform = out.wave }
        // An edited Document keeps your edits; the new words go at the end.
        if let doc = t.document {
            let added = out.fixed.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !added.isEmpty { t.document = doc.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + added }
        }
        t.pendingAppend = nil
        t.stage = nil
        t.processingDevice = nil; t.processingDeviceName = nil
    }
}
