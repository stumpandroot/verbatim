import Foundation

// Meeting capture (proof of concept, App/MeetingSession.swift): the pure parts. The session's sidecar, the clock
// each track keeps, silence detection, the check for a tap that delivers only zeros, and lining the two tracks up.
// Foundation only, so mac/tools/test-meeting-align.sh compiles it on Linux with no Xcode.

/// One track of a meeting session as the sidecar records it.
struct MeetingTrack: Codable, Equatable {
    enum Role: String, Codable { case mic, system }
    var role: Role
    /// The track's file inside the session folder ("<stem> mic.wav"); segments sit beside it.
    var fileName: String
    /// "You" for the mic; the meeting app's name for the system track.
    var speaker: String
    var sampleRate: Double = 16_000
    /// Host time (seconds, the Core Audio host clock) of the track's first sample. nil until audio arrives.
    var startHostTime: Double? = nil
    /// Host time just after the track's last sample. nil while recording and after a crash.
    var endHostTime: Double? = nil
    /// Frames on disk at `sampleRate`, once the track stopped.
    var framesWritten: Int64? = nil
    /// Anything but exact digital silence arrived. nil when unknown (a crash).
    var heardSignal: Bool? = nil
}

/// A pause, in host seconds. Both tracks pause together, so the same span comes off each track's clock.
struct MeetingPause: Codable, Equatable {
    var start: Double
    var end: Double? = nil
}

/// `session.json` in a meeting session folder ("<stem>.meeting"): enough to line the tracks up and to recover the
/// session as one two-track transcript after a crash.
struct MeetingSidecar: Codable, Equatable {
    static let fileName = "session.json"
    var version = 1
    var id = UUID()
    var createdAt = Date()
    /// What was tapped, for the title and the log ("Zoom", "All system audio").
    var targetName: String
    var targetBundleID: String? = nil
    /// "tap" (Core Audio process tap), "screenCapture" (the ScreenCaptureKit fallback), or "none" (mic only).
    var capturePath: String
    var tracks: [MeetingTrack]
    var pauses: [MeetingPause] = []
    /// Short events for the log and for later analysis ("tap silent 10 s; switched to ScreenCaptureKit").
    var events: [String] = []
    /// The transcript the session became. Recovery skips a session that already has one.
    var transcriptID: UUID? = nil
    var stoppedCleanly = false

    func track(_ role: MeetingTrack.Role) -> MeetingTrack? { tracks.first { $0.role == role } }

    mutating func update(_ role: MeetingTrack.Role, _ change: (inout MeetingTrack) -> Void) {
        guard let i = tracks.firstIndex(where: { $0.role == role }) else { return }
        change(&tracks[i])
    }

    /// Seconds spent paused (pauses still open don't count).
    var pausedSeconds: Double {
        pauses.reduce(0) { total, p in total + max(0, (p.end ?? p.start) - p.start) }
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    static func decode(_ data: Data) throws -> MeetingSidecar { try JSONDecoder().decode(MeetingSidecar.self, from: data) }

    func write(in folder: URL) throws {
        try encoded().write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func read(in folder: URL) -> MeetingSidecar? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? decode(data)
    }
}

/// The host-time clock of one track: when its first sample was heard and when its last one ended. Written on the
/// audio side, read by the session. Thread-safe.
final class TrackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    private var last: Double?
    private var frames: Int64 = 0

    /// One buffer of `count` frames at `sampleRate` whose first sample was heard at `bufferStart` (host seconds).
    func mark(bufferStart: Double, frames count: Int, sampleRate: Double) {
        guard count > 0, sampleRate > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = bufferStart }
        last = bufferStart + Double(count) / sampleRate
        frames += Int64(count)
    }

    func reset() { lock.lock(); first = nil; last = nil; frames = 0; lock.unlock() }

    var start: Double? { lock.lock(); defer { lock.unlock() }; return first }
    var end: Double? { lock.lock(); defer { lock.unlock() }; return last }
    var framesSeen: Int64 { lock.lock(); defer { lock.unlock() }; return frames }
}

/// Silence on one track: how long since anything audible, and whether anything but exact zeros ever arrived.
/// A Core Audio tap without permission delivers buffers of zeros, with no error.
struct SilenceTracker: Equatable {
    /// Below this peak (about -80 dBFS) a buffer counts as silent.
    static let audibleFloor: Float = 0.0001
    private(set) var startedAt: Double?
    private(set) var lastAudibleAt: Double?
    private(set) var everNonZero = false
    private(set) var buffers = 0

    /// One buffer's peak (0…1), heard at `time` (any clock, seconds).
    mutating func feed(peak: Float, at time: Double) {
        if startedAt == nil { startedAt = time }
        buffers += 1
        if peak > 0 { everNonZero = true }
        if peak >= Self.audibleFloor { lastAudibleAt = time }
    }

    /// Seconds since the last audible buffer (or since the first buffer, if none was audible).
    func silentFor(now: Double) -> Double {
        guard let since = lastAudibleAt ?? startedAt else { return 0 }
        return max(0, now - since)
    }

    /// Buffers have arrived for at least `seconds`, and every one was exact digital silence.
    func onlyZeros(for seconds: Double, now: Double) -> Bool {
        guard let s = startedAt, buffers > 0 else { return false }
        return !everNonZero && now - s >= seconds
    }
}

/// What the session does about the system track a few seconds in.
enum TapVerdict: Equatable {
    /// Real audio arrived.
    case ok
    /// Too early to tell, or quiet in a way that can be a meeting where nobody is talking yet.
    case waiting
    /// No buffers at all: the tap or its aggregate device isn't running.
    case noBuffers
    /// Only zeros, while the tapped app says it's playing sound (or long enough that it can't be a pause): almost
    /// always the System Audio Recording permission. Fall back to ScreenCaptureKit when possible.
    case onlyZeros
}

enum MeetingAlign {
    /// How long a tap may deliver only zeros before the session gives up on it when the app is playing sound.
    static let zeroGrace: Double = 5
    /// How long it may deliver only zeros when the app isn't known to be playing (people may just be quiet).
    static let zeroLimit: Double = 20
    /// A drift ratio outside this (5%) is a clock that stopped (sleep) or bad timing, not crystal drift.
    static let maxDrift = 0.05
    /// A constant offset leaves up to this much misalignment at the ends before resampling is worth it.
    static let residualLimit = 0.05

    static func tapVerdict(elapsed: Double, buffersArrived: Bool, silence: SilenceTracker, now: Double, targetPlaying: Bool?) -> TapVerdict {
        if silence.everNonZero { return .ok }
        if !buffersArrived { return elapsed >= zeroGrace ? .noBuffers : .waiting }
        if targetPlaying == true, silence.onlyZeros(for: zeroGrace, now: now) { return .onlyZeros }
        if silence.onlyZeros(for: zeroLimit, now: now) { return .onlyZeros }
        return .waiting
    }

    /// How one track lines up with track 1 (the mic).
    struct TrackPlan: Equatable {
        /// Seconds this track starts after track 1 on the transcript's timeline (negative: before), drift
        /// included: `AudioTrack.offset`.
        var offset: Double
        /// The offset from start times alone.
        var startOffset: Double
        /// How fast this track's clock ran against host time, in parts per million (positive: more frames than
        /// seconds went by).
        var driftPPM: Double
        /// The most a constant offset leaves this track off from track 1 (at its start and end), in seconds.
        var residual: Double
        /// Stretch this track by this factor to match track 1's clock exactly (1: no drift).
        var stretch: Double
        /// Both start and end times were known and plausible.
        var reliable: Bool
    }

    struct Plan: Equatable {
        var tracks: [TrackPlan]
        var offsets: [Double] { tracks.map(\.offset) }
        var maxResidual: Double { tracks.map(\.residual).max() ?? 0 }
        /// A constant offset isn't enough: the tracks drift apart by more than `residualLimit` at the ends.
        var needsResample: Bool { maxResidual > residualLimit }
    }

    /// Frames over host-time span (pauses taken off): 1 for a clock that matches host time exactly. nil when the
    /// span isn't known or isn't plausible.
    static func clockRatio(_ t: MeetingTrack, paused: Double) -> Double? {
        guard let s = t.startHostTime, let e = t.endHostTime, let frames = t.framesWritten, frames > 0, t.sampleRate > 0 else { return nil }
        let span = e - s - paused
        guard span > 1 else { return nil }
        let r = Double(frames) / t.sampleRate / span
        return abs(r - 1) <= maxDrift ? r : nil
    }

    /// Lines every track up with track 1 from the sidecar's host times. A track's sample `u` was heard at host
    /// time `start + u / k` (k: its clock ratio), so on track 1's timeline it belongs at
    /// `(start - start1) * k1 + u * k1 / k`. The multi-track job takes one constant offset per track, so this
    /// uses the one that's right at the middle of the track: off by `residual` at each end, which stays under
    /// 50 ms for an hour at the drift two decent clocks have. Tracks without a start time line up at 0.
    /// The mix pads whichever track starts later (MultitrackInfo.timeline puts the earliest at 0), so no audio is
    /// trimmed or rewritten.
    static func plan(_ s: MeetingSidecar) -> Plan {
        guard let ref = s.tracks.first else { return Plan(tracks: []) }
        let paused = s.pausedSeconds
        let k0 = clockRatio(ref, paused: paused)
        var out: [TrackPlan] = []
        for (i, t) in s.tracks.enumerated() {
            if i == 0 {
                out.append(TrackPlan(offset: 0, startOffset: 0, driftPPM: k0.map { ($0 - 1) * 1e6 } ?? 0, residual: 0, stretch: 1, reliable: k0 != nil))
                continue
            }
            guard let h0 = ref.startHostTime, let h = t.startHostTime else {
                out.append(TrackPlan(offset: 0, startOffset: 0, driftPPM: 0, residual: 0, stretch: 1, reliable: false))
                continue
            }
            let k = clockRatio(t, paused: paused)
            let refRate = k0 ?? 1
            let startOffset = (h - h0) * refRate
            guard let k else {
                out.append(TrackPlan(offset: startOffset, startOffset: startOffset, driftPPM: 0, residual: 0, stretch: 1, reliable: false))
                continue
            }
            let stretch = refRate / k
            let duration = Double(t.framesWritten ?? 0) / t.sampleRate
            let mid = duration / 2 * (stretch - 1)
            out.append(TrackPlan(offset: startOffset + mid, startOffset: startOffset, driftPPM: (k - 1) * 1e6,
                                 residual: abs(mid), stretch: stretch, reliable: k0 != nil))
        }
        return Plan(tracks: out)
    }

    /// One line for native.log.
    static func describe(_ p: Plan) -> String {
        p.tracks.enumerated().map { i, t in
            String(format: "track %d offset %.3fs (start %.3fs) drift %.0f ppm residual %.3fs", i + 1, t.offset, t.startOffset,
                   t.driftPPM, t.residual) + (t.reliable ? "" : " (start only)")
        }.joined(separator: "; ") + (p.needsResample ? "; needs resampling" : "")
    }
}
