import Foundation

// Test cases for MeetingAlign (meeting capture). Not part of any app target; run mac/tools/test-meeting-align.sh.

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name) \(detail())") }
}
func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

let rate = 16_000.0

/// A two-track session: each track's start and end host times and the seconds of audio it wrote.
func session(micStart: Double, micEnd: Double?, micSeconds: Double,
             sysStart: Double?, sysEnd: Double?, sysSeconds: Double, pauses: [MeetingPause] = []) -> MeetingSidecar {
    MeetingSidecar(targetName: "Zoom", targetBundleID: "us.zoom.xos", capturePath: "tap", tracks: [
        MeetingTrack(role: .mic, fileName: "a mic.wav", speaker: "You", startHostTime: micStart, endHostTime: micEnd,
                     framesWritten: Int64(micSeconds * rate), heardSignal: true),
        MeetingTrack(role: .system, fileName: "a system.wav", speaker: "Zoom", startHostTime: sysStart, endHostTime: sysEnd,
                     framesWritten: Int64(sysSeconds * rate), heardSignal: true),
    ], pauses: pauses)
}

// MARK: Equal durations

do {
    let p = MeetingAlign.plan(session(micStart: 1000, micEnd: 1600, micSeconds: 600, sysStart: 1000, sysEnd: 1600, sysSeconds: 600))
    check("equal: two tracks planned", p.tracks.count == 2)
    check("equal: mic offset 0", p.offsets.first == 0)
    check("equal: system offset 0", near(p.offsets[1], 0, 1e-9), "\(p.offsets)")
    check("equal: no drift", near(p.tracks[1].driftPPM, 0, 1e-6), "\(p.tracks[1].driftPPM)")
    check("equal: stretch 1", near(p.tracks[1].stretch, 1, 1e-12))
    check("equal: reliable", p.tracks[1].reliable && p.tracks[0].reliable)
    check("equal: no resampling", !p.needsResample)
}

// MARK: 1% drift (the system clock wrote 1% more frames than host time allows)

do {
    let p = MeetingAlign.plan(session(micStart: 1000, micEnd: 1600, micSeconds: 600, sysStart: 1000, sysEnd: 1600, sysSeconds: 606))
    let t = p.tracks[1]
    check("drift: 10,000 ppm", near(t.driftPPM, 10_000, 1), "\(t.driftPPM)")
    check("drift: stretch 1/1.01", near(t.stretch, 1 / 1.01, 1e-9), "\(t.stretch)")
    check("drift: start offset 0", near(t.startOffset, 0, 1e-9))
    // Right at the middle: system sample 303 s was heard at host 1300, which is mic 300 s.
    check("drift: offset centers the middle", near(t.offset, -3.0, 0.001), "\(t.offset)")
    check("drift: middle sample lands on the mic's timeline", near(303 + t.offset, 300, 0.001))
    check("drift: residual 3 s at the ends", near(t.residual, 3.0, 0.001), "\(t.residual)")
    check("drift: needs resampling", p.needsResample)
    // 20 ppm over an hour (two decent clocks): 72 ms apart at the end, so 36 ms at each end of a centered offset.
    let small = MeetingAlign.plan(session(micStart: 0, micEnd: 3600, micSeconds: 3600, sysStart: 0, sysEnd: 3600, sysSeconds: 3600 * 1.00002))
    check("drift: 20 ppm for an hour stays under 50 ms", small.maxResidual < 0.05 && !small.needsResample, "\(small.maxResidual)")
    // A clock that stopped (the Mac slept) isn't drift: start offset only.
    let slept = MeetingAlign.plan(session(micStart: 0, micEnd: 600, micSeconds: 600, sysStart: 0, sysEnd: 600, sysSeconds: 400))
    check("drift: implausible ratio falls back to the start offset", !slept.tracks[1].reliable && slept.offsets[1] == 0)
}

// MARK: The system track started 300 ms late

do {
    let p = MeetingAlign.plan(session(micStart: 50.0, micEnd: 650.0, micSeconds: 600, sysStart: 50.3, sysEnd: 650.0, sysSeconds: 599.7))
    check("late: offset +0.3 s", near(p.offsets[1], 0.3, 1e-6), "\(p.offsets)")
    check("late: no drift", near(p.tracks[1].driftPPM, 0, 0.5), "\(p.tracks[1].driftPPM)")
    check("late: residual 0", near(p.maxResidual, 0, 1e-6))
    // And 300 ms early: negative.
    let early = MeetingAlign.plan(session(micStart: 50.3, micEnd: 650.0, micSeconds: 599.7, sysStart: 50.0, sysEnd: 650.0, sysSeconds: 600))
    check("early: offset -0.3 s", near(early.offsets[1], -0.3, 1e-6), "\(early.offsets)")
    // After a crash there's no end time: start offset only, still 300 ms.
    let crashed = MeetingAlign.plan(session(micStart: 50.0, micEnd: nil, micSeconds: 600, sysStart: 50.3, sysEnd: nil, sysSeconds: 599.7))
    check("crash: start offset without end times", near(crashed.offsets[1], 0.3, 1e-6) && !crashed.tracks[1].reliable)
    // No system start at all (it never delivered): lines up at 0.
    let none = MeetingAlign.plan(session(micStart: 50, micEnd: 650, micSeconds: 600, sysStart: nil, sysEnd: nil, sysSeconds: 0))
    check("none: no system start lines up at 0", none.offsets == [0, 0])
    // A 2-minute pause comes off both spans, so it isn't read as drift.
    let paused = MeetingAlign.plan(session(micStart: 0, micEnd: 720, micSeconds: 600, sysStart: 0.3, sysEnd: 720, sysSeconds: 599.7,
                                           pauses: [MeetingPause(start: 100, end: 220)]))
    check("pause: not drift", paused.tracks[1].reliable && near(paused.tracks[1].driftPPM, 0, 0.5), "\(paused.tracks[1].driftPPM)")
    check("pause: offset still 0.3 s", near(paused.offsets[1], 0.3, 1e-6))
}

// MARK: Silence and a tap that delivers only zeros

do {
    var s = SilenceTracker()
    check("silence: nothing yet", s.silentFor(now: 10) == 0 && !s.onlyZeros(for: 1, now: 10))
    for i in 0..<300 { s.feed(peak: 0, at: Double(i) * 0.1) }   // 30 s of exact zeros
    check("silence: fully silent track is silent for its whole length", near(s.silentFor(now: 29.9), 29.9, 1e-9))
    check("silence: only zeros", s.onlyZeros(for: 20, now: 29.9) && !s.everNonZero)
    let playing = MeetingAlign.tapVerdict(elapsed: 6, buffersArrived: true, silence: s, now: 6, targetPlaying: true)
    check("verdict: zeros while the app plays sound means permission", playing == .onlyZeros)
    var early = SilenceTracker()
    for i in 0..<30 { early.feed(peak: 0, at: Double(i) * 0.1) }
    check("verdict: 3 s of zeros is too early", MeetingAlign.tapVerdict(elapsed: 3, buffersArrived: true, silence: early, now: 2.9, targetPlaying: true) == .waiting)
    var quiet = SilenceTracker()
    for i in 0..<100 { quiet.feed(peak: 0, at: Double(i) * 0.1) }
    check("verdict: 10 s of zeros with the app quiet keeps waiting",
          MeetingAlign.tapVerdict(elapsed: 10, buffersArrived: true, silence: quiet, now: 9.9, targetPlaying: false) == .waiting)
    check("verdict: 30 s of zeros fails even when the app is quiet",
          MeetingAlign.tapVerdict(elapsed: 30, buffersArrived: true, silence: s, now: 29.9, targetPlaying: false) == .onlyZeros)
    check("verdict: no buffers after 5 s", MeetingAlign.tapVerdict(elapsed: 5, buffersArrived: false, silence: SilenceTracker(), now: 5, targetPlaying: nil) == .noBuffers)

    // Real audio: a quiet room's noise floor is nonzero, so it's not "only zeros", but below the audible floor it's silent.
    var room = SilenceTracker()
    room.feed(peak: 0.3, at: 0)
    for i in 1...50 { room.feed(peak: 0.00002, at: Double(i) * 0.1) }
    check("silence: noise floor isn't only zeros", room.everNonZero && !room.onlyZeros(for: 1, now: 5))
    check("silence: silent since the last audible buffer", near(room.silentFor(now: 5), 5, 1e-9))
    check("verdict: any nonzero sample is ok", MeetingAlign.tapVerdict(elapsed: 30, buffersArrived: true, silence: room, now: 5, targetPlaying: true) == .ok)
    room.feed(peak: 0.2, at: 6)
    check("silence: audible again resets", room.silentFor(now: 6.5) == 0.5)
}

// MARK: Track clock

do {
    let c = TrackClock()
    check("clock: empty", c.start == nil && c.end == nil && c.framesSeen == 0)
    c.mark(bufferStart: 10, frames: 480, sampleRate: 48_000)
    c.mark(bufferStart: 10.01, frames: 480, sampleRate: 48_000)
    check("clock: first sample", c.start == 10)
    check("clock: end after the last buffer", near(c.end ?? 0, 10.02, 1e-9))
    check("clock: frames", c.framesSeen == 960)
    c.mark(bufferStart: 11, frames: 0, sampleRate: 48_000)
    check("clock: empty buffers ignored", c.framesSeen == 960)
    c.reset()
    check("clock: reset", c.start == nil)
}

// MARK: Sidecar round trip

do {
    var s = session(micStart: 123.456789, micEnd: 723.5, micSeconds: 600, sysStart: 123.75, sysEnd: nil, sysSeconds: 599.5,
                    pauses: [MeetingPause(start: 200, end: 230), MeetingPause(start: 400)])
    s.createdAt = Date(timeIntervalSinceReferenceDate: 783_000_000.25)
    s.events = ["tap started", "tap silent 5 s; switched to ScreenCaptureKit"]
    s.transcriptID = UUID()
    s.update(.system) { $0.heardSignal = false }
    let data = try s.encoded()
    let back = try MeetingSidecar.decode(data)
    check("sidecar: round trip is identical", back == s)
    check("sidecar: track lookup", back.track(.system)?.heardSignal == false && back.track(.mic)?.speaker == "You")
    check("sidecar: paused seconds skip the open pause", back.pausedSeconds == 30)
    let text = String(decoding: data, as: UTF8.self)
    check("sidecar: readable keys", text.contains("\"startHostTime\"") && text.contains("\"capturePath\" : \"tap\""), text)

    // Through a folder, as the session and launch recovery use it.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-align-\(UUID().uuidString).meeting")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try s.write(in: dir)
    check("sidecar: write and read in a folder", MeetingSidecar.read(in: dir) == s)
    try Data("{ not json".utf8).write(to: dir.appendingPathComponent(MeetingSidecar.fileName))
    check("sidecar: damaged file reads as nil", MeetingSidecar.read(in: dir) == nil)
    // A sidecar from a newer build with fields this one doesn't know still reads.
    let newer = #"{"version":2,"id":"\#(UUID().uuidString)","createdAt":1,"targetName":"Teams","capturePath":"tap","tracks":[],"pauses":[],"events":[],"stoppedCleanly":true,"future":42}"#
    check("sidecar: unknown fields are ignored", (try? MeetingSidecar.decode(Data(newer.utf8)))?.targetName == "Teams")
}

// MARK: Log line

do {
    let p = MeetingAlign.plan(session(micStart: 0, micEnd: 600, micSeconds: 600, sysStart: 0.3, sysEnd: 600, sysSeconds: 599.7))
    let line = MeetingAlign.describe(p)
    check("describe: names each track", line.contains("track 1") && line.contains("track 2 offset 0.300s"), line)
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
