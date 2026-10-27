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
        /// When the transcript had no speakers: the full list, worked out over both recordings.
        var freshSpeakers: [Speaker]?
        var oldSpeakerLabels: [UUID: String]  // existing segments' labels under `freshSpeakers`
        /// When it had speakers: voices new in this part (existing names are never touched).
        var addedSpeakers: [Speaker]
        var combinedSeconds: Double
        var wave: [Float]
    }

    /// Joins `a` then `b` into one mono WAV at `dest`, reading and writing in chunks: 16 kHz, or `a`'s own rate in
    /// 24-bit when `a` is above 16 kHz (Audio only transcribed later, `SoundFormat`), so continuing never dulls it.
    /// Returns the total length and the length of `a` as written (the offset for `b`'s lines).
    /// Throws if either file can't be read to the end, so a partial join is never kept.
    static func join(_ a: URL, _ b: URL, to dest: URL) throws -> (total: Double, first: Double) {
        let firstRate = try AVAudioFile(forReading: a).processingFormat.sampleRate
        let sound = SoundFormat.isSoundFile(a, rate: firstRate)
        let target = sound ? SoundFormat.processing(rate: SoundFormat.rate(for: firstRate)) : recordingFormat
        let out: AVAudioFile
        if sound {
            out = try AVAudioFile(forWriting: dest, settings: SoundFormat.settings(rate: target.sampleRate), commonFormat: .pcmFormatFloat32, interleaved: false)
        } else {
            out = try AVAudioFile(forWriting: dest, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        }
        var frames: AVAudioFramePosition = 0
        var firstFrames: AVAudioFramePosition = 0
        var expected: Double = 0
        for (index, src) in [a, b].enumerated() {
            let file = try AVAudioFile(forReading: src)
            let inFormat = file.processingFormat
            expected += Double(file.length) / inFormat.sampleRate
            guard let converter = AVAudioConverter(from: inFormat, to: target) else {
                throw NSError(domain: "Verbatim", code: 20, userInfo: [NSLocalizedDescriptionKey: "Couldn't read \(src.lastPathComponent)."])
            }
            let chunk: AVAudioFrameCount = 1 << 15
            var readError: Error? = nil
            var done = false
            while !done {
                let ratio = target.sampleRate / inFormat.sampleRate
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 64) else { break }
                var err: NSError?
                let status = converter.convert(to: outBuf, error: &err) { _, st in
                    // A fresh buffer per request: the converter may still hold the previous one.
                    guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { st.pointee = .endOfStream; return nil }
                    if file.framePosition >= file.length { st.pointee = .endOfStream; return nil }
                    do { try file.read(into: inBuf, frameCount: chunk) }
                    catch { readError = error; st.pointee = .endOfStream; return nil }
                    if inBuf.frameLength == 0 { st.pointee = .endOfStream; return nil }
                    st.pointee = .haveData
                    return inBuf
                }
                if let err { throw err }
                if let readError { throw readError }
                if outBuf.frameLength > 0 { try out.write(from: outBuf); frames += AVAudioFramePosition(outBuf.frameLength) }
                if status == .endOfStream || status == .error { done = true }
            }
            if index == 0 { firstFrames = frames }
        }
        let total = Double(frames) / target.sampleRate
        guard abs(total - expected) < 0.25 else {
            throw NSError(domain: "Verbatim", code: 21, userInfo: [NSLocalizedDescriptionKey: "The recordings didn't join cleanly (\(Int(total)) of \(Int(expected)) seconds)."])
        }
        return (total, Double(firstFrames) / target.sampleRate)
    }

    /// Transcribes `part` (recorded after `existing` ended), joins the audio into `combined`, and works out speakers.
    static func run(existing: Transcript, existingAudio: URL, part: URL, combined: URL,
                    engineId: String, model: String, wantSpeakers: Bool, dictionary: [DictionaryEntry],
                    progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> Outcome {
        let joined = try join(existingAudio, part, to: combined)
        let offset = joined.first > 0 ? joined.first : existing.duration
        let result = try await Engines.engine(for: engineId).transcribe(url: part, model: model, progress: progress)
        let shifted = result.segments.map { s -> Segment in
            var x = s; x.start += offset; x.end += offset
            x.words = s.words?.map { w in var v = w; v.start += offset; v.end += offset; return v }
            return x
        }
        var fixed = shifted
        let corrections = dictionary.isEmpty && !BuiltInVocabulary.isActive ? [] : DictionaryApplier.apply(dictionary, to: &fixed, project: existing.projectId)
        var fresh: [Speaker]? = nil
        var added: [Speaker] = []
        var relabeled: [UUID: String] = [:]
        let all = existing.segments + fixed
        if wantSpeakers, all.count > 1 {
            do {
                // A sound file (Audio only transcribed later, then continued) is heard through a 16 kHz copy.
                let heard = try TranscriptionInput.prepare(combined)
                defer { TranscriptionInput.finish(heard, original: combined) }
                let turns = try await FluidDiarizer.shared.diarize(url: heard, progress: progress)
                if existing.speakers.isEmpty {
                    // No speakers yet: label everything fresh (nothing named to lose).
                    var everything = all
                    let found = SpeakerAssigner.assign(turns, to: &everything)
                    if found.count >= 2 {
                        fresh = found
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
                            let sp = Speaker(id: id, name: "Speaker \(list.count + 1)")
                            list.append(sp); added.append(sp)
                            map[voice] = id
                        }
                        fixed[i].speaker = map[voice]
                    }
                }
            } catch {
                Log.note("continue: diarize failed (kept transcript): \(error)")
            }
        }
        var original = shifted
        for i in original.indices where i < fixed.count { original[i].speaker = fixed[i].speaker }
        return Outcome(original: original, fixed: fixed, corrections: corrections, freshSpeakers: fresh, oldSpeakerLabels: relabeled,
                       addedSpeakers: added, combinedSeconds: joined.total, wave: Waveform.envelope(of: combined))
    }

    /// Applies an outcome to the transcript as it is now (you may have renamed or reassigned speakers meanwhile).
    static func apply(_ out: Outcome, to t: inout Transcript, combinedName: String) {
        var added = out.fixed, addedOriginal = out.original
        if let fresh = out.freshSpeakers {
            if t.speakers.isEmpty {
                for i in t.segments.indices { if let l = out.oldSpeakerLabels[t.segments[i].id] { t.segments[i].speaker = l } }
                for i in t.original.indices where i < t.segments.count { t.original[i].speaker = t.segments[i].speaker }
                t.speakers = fresh
            } else {
                // You assigned speakers by hand while this ran: keep yours, leave the new lines unassigned.
                for i in added.indices { added[i].speaker = nil }
                for i in addedOriginal.indices { addedOriginal[i].speaker = nil }
            }
        }
        for sp in out.addedSpeakers where !t.speakers.contains(where: { $0.id == sp.id }) { t.speakers.append(sp) }
        t.original += addedOriginal
        t.segments += added
        t.corrections += out.corrections
        t.duration = out.combinedSeconds
        t.audioFileName = combinedName
        if !out.wave.isEmpty { t.waveform = out.wave }
        // An edited Document keeps your edits; the new words go at the end.
        if let doc = t.document {
            let text = out.fixed.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { t.document = doc.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + text }
        }
        t.status = .ready; t.error = nil
        t.pendingAppend = nil
        t.stage = nil
        t.processingDevice = nil; t.processingDeviceName = nil
    }

    /// A place to build the joined file before it moves into the synced folder.
    static func scratchURL() -> URL {
        try? FileManager.default.createDirectory(at: Paths.recordings, withIntermediateDirectories: true)
        return Paths.recordings.appendingPathComponent("\(Formats.fileStamp.string(from: Date())) joined \(UUID().uuidString.prefix(4)).wav")
    }
}
