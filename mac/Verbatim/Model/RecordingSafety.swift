import Foundation
import AVFoundation

/// No lost recordings (Build A), shared by the Mac and the iPhone: a discarded recording goes to Recently Deleted
/// instead of away, recovered recordings are transcribed on their own (or added to the transcript they were
/// continuing), unreadable audio is noted on the transcript, and the disk is checked before recording.
extension Store {
    // MARK: Messages

    static let nothingRecordedNotice = "Nothing was recorded."
    static let joinFailedNotice = "Couldn't finish saving. Verbose recovers the recording the next time it opens."
    #if os(iOS)
    static let lowSpaceNotice = "Your iPhone is low on space. Recording may stop early."
    static let discardedError = "Not transcribed. Restore it, then tap Retry."
    #else
    static let lowSpaceNotice = "Your Mac is low on space. Recording may stop early."
    static let discardedError = "Not transcribed. Restore it, then choose Retry."
    #endif

    // MARK: Free space

    /// Below this much free space, starting a recording warns that it may stop early (it still starts).
    static let lowSpaceBytes: Int64 = 500 * 1_000_000

    /// Free space for new recordings, or nil when the system won't say.
    nonisolated static func freeSpace(at folder: URL = Paths.recordings) -> Int64? {
        let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let n = v?.volumeAvailableCapacityForImportantUsage, n > 0 { return n }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    /// The warning to show when a recording starts, or nil when there's room.
    static func lowSpaceWarning(free: Int64? = Store.freeSpace()) -> String? {
        guard let free, free < lowSpaceBytes else { return nil }
        Log.note("recording: \(free / 1_000_000) MB free")
        return lowSpaceNotice
    }

    // MARK: Unreadable audio

    /// "Some audio couldn't be read: 10:00–15:00", one note per range, at the moment it starts. `offset` moves
    /// them along (a continued recording's ranges start where the transcript ended).
    static func skippedNotes(_ ranges: [ClosedRange<Double>], offset: Double = 0) -> [Note] {
        ranges.map { r in
            Note(text: "Some audio couldn't be read: \((r.lowerBound + offset).timecode)–\((r.upperBound + offset).timecode)", at: r.lowerBound + offset)
        }
    }

    // MARK: Discard

    /// Discard on the record screen: the recording goes to Recently Deleted, not transcribed, restorable for 30
    /// days (restore it, then Retry transcribes it). Returns its ID, or nil when there was nothing to keep or it
    /// couldn't be moved (the file then stays in the recordings folder for launch recovery).
    @discardableResult
    func keepDiscarded(_ r: StoppedRecording, at date: Date = Date()) -> UUID? {
        guard r.framesWritten > 0, !r.joinFailed else { return nil }
        guard let name = adoptRecording(r.url) else { return nil }
        var t = Transcript(title: "Discarded recording · \(Self.stamp(date))", source: .voiceMemo, sourceLabel: "Voice memo",
                           duration: r.duration, audioFileName: name, model: "")
        t.createdAt = date
        t.waveform = r.envelope
        t.status = .failed
        t.error = Self.discardedError
        t.notes = Self.skippedNotes(r.skipped)
        t.deletedAt = date
        add(t)
        Log.note("recording discarded to Recently Deleted (\(String(format: "%.1f", r.duration)) s)")
        return t.id
    }

    /// "Oct 21, 2026 at 2:14 PM".
    static func stamp(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    // MARK: Recovery

    /// A recovered recording, queued to transcribe on this device.
    static func recoveredTranscript(audioFileName: String, duration: Double, recordedAt when: Date, skipped: [ClosedRange<Double>] = []) -> Transcript {
        var t = Transcript(title: "Recovered recording · \(stamp(when))", source: .voiceMemo, sourceLabel: "Recovered",
                           duration: duration, audioFileName: audioFileName, model: "")
        t.createdAt = when
        t.status = .processing
        t.stage = "Queued"
        t.processingDevice = Device.id; t.processingDeviceName = Device.name
        t.notes = skippedNotes(skipped)
        return t
    }

    /// An orphan of a second or less is a stray tap, not a recording: kept for a week (in case), then deleted.
    /// Larger files that won't play are never deleted this way.
    static func isStaleTinyOrphan(duration: Double, bytes: Int64, modified: Date, now: Date = Date()) -> Bool {
        duration <= 1 && bytes <= 256 * 1024 && now.timeIntervalSince(modified) > 7 * 86_400
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    // MARK: Continue recording, across a crash

    /// Beside a recording that continues a transcript: ".<stem>.continues", holding the transcript's ID. If the
    /// app dies mid-recording, recovery adds the recording to that transcript instead of making a new one.
    static func continuationMarker(for recording: URL) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent(".\(recording.deletingPathExtension().lastPathComponent).continues")
    }

    static func markContinuation(_ recording: URL, to id: UUID) {
        try? Data(id.uuidString.utf8).write(to: continuationMarker(for: recording), options: .atomic)
    }

    static func clearContinuation(_ recording: URL) {
        try? FileManager.default.removeItem(at: continuationMarker(for: recording))
    }

    // MARK: Thoughts, across a crash

    /// Beside a thought's recording: ".<stem>.thought". If the app dies mid-thought, recovery makes it a Thoughts
    /// recording on the day it started instead of a plain recovered recording (Flow/Thoughts.swift).
    static func thoughtMarker(for recording: URL) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent(".\(recording.deletingPathExtension().lastPathComponent).thought")
    }

    static func markThought(_ recording: URL) {
        try? Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: thoughtMarker(for: recording), options: .atomic)
    }

    static func clearThoughtMark(_ recording: URL) {
        try? FileManager.default.removeItem(at: thoughtMarker(for: recording))
    }

    // MARK: Audio only and Brain dump, across a crash

    /// Beside an Audio only or Brain dump recording: ".<stem>.kind", holding the kind's raw value. If the app dies mid-
    /// recording, recovery files it as that kind: Audio only is kept as sound and never queued to transcribe.
    static func kindMarker(for recording: URL) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent(".\(recording.deletingPathExtension().lastPathComponent).kind")
    }

    static func markKind(_ recording: URL, _ kind: RecordingKind?) {
        guard let kind, kind == .audio || kind == .brainDump else { return }
        try? Data(kind.rawValue.utf8).write(to: kindMarker(for: recording), options: .atomic)
    }

    static func clearKindMark(_ recording: URL) {
        try? FileManager.default.removeItem(at: kindMarker(for: recording))
    }

    /// The kind a recovered recording was started as, when it was Audio only or a Brain dump.
    static func recordedKind(for recording: URL) -> RecordingKind? {
        guard let data = try? Data(contentsOf: kindMarker(for: recording)) else { return nil }
        return RecordingKind(rawValue: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// When a recovered recording started as a thought, or nil when it wasn't one.
    static func thoughtStart(for recording: URL) -> Date? {
        guard let data = try? Data(contentsOf: thoughtMarker(for: recording)) else { return nil }
        return ISO8601DateFormatter().date(from: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date.distantPast
    }

    /// The transcript a recovered recording was continuing, when it can still take it right now.
    func continuationTarget(for recording: URL) -> UUID? {
        guard let data = try? Data(contentsOf: Self.continuationMarker(for: recording)),
              let id = UUID(uuidString: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              let t = transcript(id), t.deletedAt == nil, t.status == .ready, t.pendingAppend == nil,
              let audio = audioURL(for: t), FileManager.default.fileExists(atPath: audio.path) else { return nil }
        return id
    }

    /// Adds a recovered recording to the transcript it was continuing (queued like Stop & add). Returns the
    /// transcript's ID, or nil when it should be recovered as its own recording instead.
    func recoverContinuation(_ recording: URL) -> UUID? {
        guard let id = continuationTarget(for: recording) else { Self.clearContinuation(recording); return nil }
        guard let name = adoptRecording(recording) else { return nil }
        Self.clearContinuation(recording)
        update(id) { $0.pendingAppend = name; $0.stage = "Queued"; $0.processingDevice = Device.id; $0.processingDeviceName = Device.name }
        Log.note("recovery: added \(name) to the transcript it was continuing")
        return id
    }
}

/// Self-tests for Build A, run by the Mac's UITest and the iPhone's PhoneUITest. `check` logs PASS or FAIL.
@MainActor
enum RecordingSafetyChecks {
    static func run(store: Store?, _ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("verbatim-safety-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // A write failure (a full disk): only frames that reached the file count, and the writer stops taking audio.
        let url = dir.appendingPathComponent("fail.wav")
        if let input = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
           let w = try? RecordingWriter(url: url, inputFormat: input, segmented: true) {
            let calls = FailureCount()
            w.setOnFailure { calls.bump() }
            w.failWritesAfterFrames = 4_000
            for _ in 0..<6 {
                guard let b = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1_600) else { break }
                b.frameLength = 1_600
                if let ch = b.floatChannelData?[0] { for i in 0..<1_600 { ch[i] = Float(i % 50) / 100 } }
                _ = w.write(b)
            }
            _ = w.close()
            let onDisk = (try? AVAudioFile(forReading: url))?.length ?? -1
            Log.note("UITEST writer failure frames=\(w.framesWritten) onDisk=\(onDisk) failed=\(w.writeFailed) calls=\(calls.value)")
            check("writer counts only frames written when a write fails",
                  w.writeFailed && w.framesWritten <= 4_000 && w.framesWritten > 0 && Int64(onDisk) == w.framesWritten && calls.value == 1)
        } else {
            check("writer counts only frames written when a write fails", false)
        }

        // A corrupt middle segment: the parts on either side are joined, silence stands in for it, and it's set aside.
        let base = dir.appendingPathComponent("2026-01-01 at 11.00.00.wav")
        func write(_ u: URL, seconds: Double) {
            guard let f = try? AVAudioFile(forWriting: u, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true),
                  let b = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: AVAudioFrameCount(16_000 * seconds)) else { return }
            b.frameLength = b.frameCapacity
            if let ch = b.int16ChannelData?[0] { for i in 0..<Int(b.frameLength) { ch[i] = Int16(truncatingIfNeeded: (i % 64) * 200) } }
            try? f.write(from: b)
            if #available(macOS 15, iOS 18, *) { f.close() }
        }
        write(base, seconds: 1)
        let seg2 = RecordingSegments.url(for: base, index: 2), seg3 = RecordingSegments.url(for: base, index: 3)
        try? Data(repeating: 0x5A, count: 32_044).write(to: seg2)   // garbage the size of 1 s of audio
        write(seg3, seconds: 1)
        let joined = RecordingSegments.join([base, seg2, seg3])
        let frames = (try? AVAudioFile(forReading: base))?.length ?? -1
        let left = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains("11.00.00") && $0 != base.lastPathComponent }
        Log.note("UITEST join around corrupt segment frames=\(frames) skipped=\(joined?.skipped ?? []) left=\(left)")
        let range = joined?.skipped.first
        check("join skips a corrupt middle segment and keeps the rest",
              joined?.url == base && abs(Int(frames) - 48_000) <= 400 && joined?.skipped.count == 1
              && abs((range?.lowerBound ?? -1) - 1) < 0.05 && abs((range?.upperBound ?? -1) - 2) < 0.05
              && left.count == 1 && left[0].hasPrefix("Unreadable ") && !fm.fileExists(atPath: seg2.path) && !fm.fileExists(atPath: seg3.path))
        check("unreadable audio gets a note", Store.skippedNotes([600...900]).first?.text == "Some audio couldn't be read: 10:00–15:00")

        // Tiny orphans: kept for a week, then deleted; larger files that won't play stay.
        let now = Date()
        check("tiny orphan cleanup waits 7 days",
              !Store.isStaleTinyOrphan(duration: 0.4, bytes: 12_000, modified: now.addingTimeInterval(-6 * 86_400), now: now)
              && Store.isStaleTinyOrphan(duration: 0.4, bytes: 12_000, modified: now.addingTimeInterval(-8 * 86_400), now: now)
              && !Store.isStaleTinyOrphan(duration: 0, bytes: 9_000_000, modified: now.addingTimeInterval(-30 * 86_400), now: now)
              && !Store.isStaleTinyOrphan(duration: 3, bytes: 96_000, modified: now.addingTimeInterval(-30 * 86_400), now: now))

        // Recovery queues the recording on this device, under a dated title.
        let rec = Store.recoveredTranscript(audioFileName: "x.wav", duration: 12, recordedAt: now, skipped: [5...10])
        check("recovered recordings are queued to transcribe",
              rec.status == .processing && rec.processingDevice == Device.id && rec.title.hasPrefix("Recovered recording · ") && rec.notes.count == 1)
        check("low space warns below 500 MB", Store.lowSpaceWarning(free: 100_000_000) == Store.lowSpaceNotice && Store.lowSpaceWarning(free: 2_000_000_000) == nil)

        // Discard keeps the recording in Recently Deleted, not transcribed.
        guard let store else { return }
        try? fm.createDirectory(at: Paths.recordings, withIntermediateDirectories: true)
        let memo = Paths.recordings.appendingPathComponent("selftest-discard-\(UUID().uuidString.prefix(6)).wav")
        write(memo, seconds: 1)
        let id = store.keepDiscarded(StoppedRecording(url: memo, duration: 1, envelope: [], framesWritten: 16_000))
        let t = id.flatMap { store.transcript($0) }
        check("discard creates a Recently Deleted item",
              t != nil && t?.deletedAt != nil && t?.status == .failed && t?.error == Store.discardedError
              && (t?.title.hasPrefix("Discarded recording · ") ?? false) && store.trash.contains { $0.id == id })
        check("discard with nothing recorded keeps nothing",
              store.keepDiscarded(StoppedRecording(url: memo, duration: 0, envelope: [], framesWritten: 0)) == nil)
        if let t { store.delete(t) }
    }
}

/// Counts calls from the audio thread (the writer's failure callback).
private final class FailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
