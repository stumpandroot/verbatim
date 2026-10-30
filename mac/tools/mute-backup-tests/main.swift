import Foundation

// A muted microphone (Verbatim/Model/MuteRules.swift, DESIGN.md §6.10, A muted microphone): the rules, the Mac's backup splice with
// strings for audio, then the sources. Reads the Swift sources from the mac/ folder given as the first argument. Not
// part of any app target; run mac/tools/test-mute-backup.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// MARK: Exact digital silence

check("silence: nothing heard 0.5 s after the start isn't muted yet", !MuteRules.silent(lastSignal: nil, since: 10, now: 10.5))
check("silence: nothing heard 0.6 s after the start is muted", MuteRules.silent(lastSignal: nil, since: 0, now: 0.6))
check("silence: 2.9 s of zeros after sound isn't muted (a noise gate between words)", !MuteRules.silent(lastSignal: 20, since: 10, now: 22.9))
check("silence: 3 s of zeros after sound is muted", MuteRules.silent(lastSignal: 20, since: 10, now: 23))
check("silence: sound from before the input changed still waits the mid window, from the change",
      !MuteRules.silent(lastSignal: 5, since: 10, now: 12) && MuteRules.silent(lastSignal: 5, since: 10, now: 13))

// MARK: Levels and comparing

check("levels: a muted mic's faint noise is quiet; speech isn't", MuteRules.quiet(0.0001) && !MuteRules.quiet(0.03))
check("levels: a working mic's own noise in a quiet room (about -60 dBFS) isn't held", !MuteRules.quiet(0.001))
check("levels: speech into a low-gain mic counts as the mic being back", 0.003 >= MuteRules.backLevel)
check("iPhone: partway through, 5 s of zeros isn't muted, 6 s is (its move doesn't undo itself)",
      !MuteRules.silent(lastSignal: 20, since: 10, now: 25, midWindow: MuteRules.phoneMidWindow)
      && MuteRules.silent(lastSignal: 20, since: 10, now: 26, midWindow: MuteRules.phoneMidWindow))
check("iPhone: the start window is the same 0.6 s", MuteRules.silent(lastSignal: nil, since: 0, now: 0.6, midWindow: MuteRules.phoneMidWindow))
check("levels: the meter is empty for silence and full for loud speech", MuteRules.meterLevel(0) == 0 && MuteRules.meterLevel(0.5) == 1)
check("compare: 4 s quiet with 2 s of speech on the built-in mic is muted", MuteRules.mutedByComparison(heldSeconds: 4, backupSpeechSeconds: 2))
check("compare: a quiet room (no speech on the built-in mic) isn't", !MuteRules.mutedByComparison(heldSeconds: 12, backupSpeechSeconds: 0.5))
check("compare: a short pause isn't, however loud the room", !MuteRules.mutedByComparison(heldSeconds: 3, backupSpeechSeconds: 3))
check("backup: the hold is shorter than the backup, so the backup always covers it", MuteRules.holdLimit < MuteRules.backupSeconds)
check("backup: on unless turned off", MuteRules.backupEnabled(UserDefaults(suiteName: "mute-tests-\(UUID())")!))

// MARK: iPhone inputs

check("iPhone: USB and wired mics are watched for a mute", MuteRules.watchesForMute(.usb) && MuteRules.watchesForMute(.wired))
check("iPhone: AirPods and the iPhone's microphone aren't",
      !MuteRules.watchesForMute(.bluetooth) && !MuteRules.watchesForMute(.builtIn) && !MuteRules.watchesForMute(.car))

// MARK: The splice

/// Feeds 0.1 s buffers: the chosen mic's `p` and the built-in mic's `b` at the same time, and collects what's written.
struct Run {
    var s = MuteSplice<String>()
    var written: [String] = []
    var t = 0.0
    mutating func tick(_ p: String, _ prms: Float, _ b: String = "", _ brms: Float = 0.001) {
        t += 0.1
        if !b.isEmpty { written += s.backup(b, at: t, seconds: 0.1, rms: brms) }
        written += s.primary(p, at: t, seconds: 0.1, rms: prms)
    }
}
let loud: Float = 0.05, faint: Float = 0.0001, zero: Float = 0

var room = Run()
room.tick("p1", loud, "b1"); room.tick("p2", 0.001, "b2"); room.tick("p3", 0.0008, "b3")
check("splice: a working mic's quiet passage is written at once (live words don't wait)", room.written == ["p1", "p2", "p3"], "\(room.written)")

// The backup's buffers don't line up with the chosen mic's: one straddling the start of the held audio isn't written twice.
var offset = MuteSplice<String>()
_ = offset.primary("p0", at: 1.0, seconds: 0.1, rms: 0.05)
_ = offset.backup("b-before", at: 1.02, seconds: 0.1, rms: 0.01)   // mostly before the hold (0.92 to 1.02)
_ = offset.primary("p1", at: 1.1, seconds: 0.1, rms: 0)           // the hold starts at 1.0
_ = offset.backup("b-after", at: 1.12, seconds: 0.1, rms: 0.01)
check("splice: a backup buffer mostly before the held audio isn't written in its place", offset.useBackup() == ["b-after"])

var first = Run()
first.tick("p1", zero, "b1"); first.tick("p2", zero, "b2")
check("splice: the chosen mic's first buffer is written at once, even silent (a meeting's mic track starts its clock on it)",
      first.written == ["p1"] && first.s.held.count == 1, "\(first.written)")

var r = Run()
r.tick("p1", loud, "b1"); r.tick("p2", loud, "b2")
check("splice: the chosen mic's sound is written at once", r.written == ["p1", "p2"], "\(r.written)")
r.tick("p3", zero, "b3"); r.tick("p4", zero, "b4")
check("splice: its quiet audio is held, not written", r.written == ["p1", "p2"] && r.s.held.count == 2, "\(r.written)")
r.tick("p5", loud, "b5")
check("splice: sound again writes what was held, then itself, in order", r.written == ["p1", "p2", "p3", "p4", "p5"], "\(r.written)")
check("splice: nothing is held after that", r.s.held.isEmpty && r.s.heldSeconds == 0)

r = Run()
r.tick("p1", loud, "b1")
for i in 2...8 { r.tick("p\(i)", zero, "b\(i)") }
let w = r.s.useBackup()
check("splice: a mute replaces the held audio with the built-in mic's for the same span", w == (2...8).map { "b\($0)" }, "\(w)")
r.written += w
r.tick("p9", zero, "b9")
check("splice: on the backup, the built-in mic is written live and the chosen mic isn't", r.written.last == "b9" && !r.written.contains("p9"), "\(r.written)")
check("splice: the recording kept its length (one piece per tenth of a second)", r.written.count == 9, "\(r.written)")
r.s.usePrimary()
r.tick("p10", loud, "b10")
check("splice: back on the chosen mic, its sound is written and the built-in mic's isn't", r.written.suffix(1) == ["p10"] && !r.written.contains("b10"), "\(r.written)")

r = Run()
for i in 1...130 { r.tick("p\(i)", zero, "b\(i)") }
check("splice: held audio past 12 s is written, oldest first", r.written.first == "p1" && abs(r.s.heldSeconds - MuteRules.holdLimit) < 0.11, "\(r.written.prefix(3)) held \(r.s.heldSeconds)")
check("splice: the backup keeps only its last 15 s", r.s.ring.count <= 151 && r.s.ring.last?.payload == "b130")

// The built-in mic opened after the recording started: held audio from before the backup's oldest audio stays.
r = Run()
r.tick("p1", zero); r.tick("p2", zero); r.tick("p3", zero, "b3"); r.tick("p4", zero, "b4")
let partial = r.s.useBackup()
check("splice: held audio from before the backup began is kept, then the backup", r.written + partial == ["p1", "p2", "b3", "b4"], "\(r.written) \(partial)")

// Comparing: faint noise on the chosen mic while the built-in mic hears speech.
r = Run()
for i in 1...45 { r.tick("p\(i)", faint, "b\(i)", 0.05) }
check("compare: 4.5 s of faint noise beside speech counts as muted",
      MuteRules.mutedByComparison(heldSeconds: r.s.heldSeconds, backupSpeechSeconds: r.s.backupSpeechSeconds), "held \(r.s.heldSeconds), speech \(r.s.backupSpeechSeconds)")
check("compare: nothing but the first buffer was written while it was held", r.written == ["p1"], "\(r.written)")
r = Run()
for i in 1...45 { r.tick("p\(i)", faint, "b\(i)", 0.002) }
check("compare: faint noise in a quiet room doesn't", !MuteRules.mutedByComparison(heldSeconds: r.s.heldSeconds, backupSpeechSeconds: r.s.backupSpeechSeconds))
r.tick("loud", 0.01)
check("compare: speech into the chosen mic is noticed as its return", r.s.primaryLoudAt == r.t)

r = Run()
r.tick("p1", zero, "b1"); r.tick("p2", zero, "b2")
check("splice: flush hands back everything held (before a pause or stop)", r.written == ["p1"] && r.s.flush() == ["p2"] && r.s.held.isEmpty)
check("splice: a mute with nothing held writes nothing extra", { var s = MuteSplice<String>(); return s.useBackup().isEmpty && s.onBackup }())
check("splice: asking for the backup twice writes it once", { var s = r.s; _ = s.useBackup(); return s.useBackup().isEmpty }())

// MARK: Sources

let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func read(_ path: String) -> String {
    guard let s = try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8) else {
        print("FAIL  can't read \(path)"); exit(1)
    }
    return s
}
/// The text of a declaration, from it to the next declaration at the same indent.
func body(_ text: String, _ decl: String) -> String {
    guard let r = text.range(of: decl) else { return "" }
    let rest = text[r.lowerBound...]
    let tail = rest.dropFirst(decl.count)
    let ends = ["\n    func ", "\n    private func ", "\n    private var ", "\n    static func ", "\n    @discardableResult", "\n    private static func ",
                "\n    nonisolated private static func ", "\n    /// ", "\n    // MARK"].compactMap { tail.range(of: $0)?.lowerBound }
    return String(ends.min().map { rest[..<$0] } ?? rest)
}
func before(_ a: String, _ b: String, in text: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

let recorder = read("Verbatim/Audio/Recorder.swift")
let backupSource = read("Verbatim/Audio/MuteBackup.swift")
let sink = body(recorder, "final class TapSink")
check("sources: a sink writing to a writer again stops forwarding", body(recorder, "    func set(_ writer: RecordingWriter?").contains("forward = nil"))
check("sources: the backup writes through MuteSplice under one lock", backupSource.contains("MuteSplice<AVAudioPCMBuffer>") && backupSource.contains("lock.lock()"))
check("sources: held audio counts as delivered right away, so the silence check sees it", backupSource.contains("writer.notice(heard:") && recorder.contains("func notice(heard: Bool)"))
check("sources: paused, the chosen mic's audio isn't held for after the pause", body(backupSource, "func primary(").contains("writer.paused"))
_ = sink
let startWatch = body(recorder, "private func startMicWatch(")
check("sources: normal Mac recordings start the backup with the mic watch; dictation doesn't", startWatch.contains("if !keepWarm { startBackup(beside: device) }"), startWatch)
let startBackup = body(recorder, "private func startBackup(")
check("sources: the backup is the built-in mic only, and follows the setting",
      startBackup.contains("Self.openBuiltIn(excluding: chosen)") && startBackup.contains("MuteRules.backupEnabled(") && startBackup.contains("!stayOnBuiltIn"), startBackup)
check("sources: a backup that opens after another fallback started is released, not routed",
      startBackup.contains("self.fallback == nil, !self.switchingToFallback"), startBackup)
let stopWatch = body(recorder, "private func stopMicWatch(")
check("sources: stopping the mic watch stops the backup (stop, a mic change)", stopWatch.contains("stopBackup()"), stopWatch)
let stopBackup = body(recorder, "private func stopBackup(")
check("sources: stopping the backup writes what it held before releasing the built-in mic",
      before("b.detach()", "open.release()", in: stopBackup) && stopBackup.contains("primary.sink.set(w, onLevel:"), stopBackup)
check("sources: Pause writes held audio before the pause", before("if isPaused { muteBackup?.flush() }", "writer?.paused = isPaused", in: body(recorder, "func togglePause(")))
check("sources: pausing by itself writes held audio first too", before("muteBackup?.flush()", "writer?.paused = true", in: body(recorder, "private func autoPause(")))
let tick = body(recorder, "private func micTick(")
check("sources: the Mac's mute check uses the shared rules, the backup, and the comparison",
      tick.contains("MuteRules.silent(") && tick.contains("MuteRules.mutedByComparison(") && tick.contains("useBackup(certain: reportedMuted, byCompare: false)")
      && tick.contains("useBackup(certain: false, byCompare: true)") && tick.contains("!backupOpening"), tick)
check("sources: after a comparison, the chosen mic is back when it hears speech, not at its first faint noise",
      tick.contains("fallbackByCompare") && tick.contains("primaryLoudAt"), tick)
check("sources: switching back keeps the backup running", body(recorder, "private func switchBack(").contains("b.usePrimary()"))
check("sources: Stop ends the backup before the file closes", before("stopMicWatch()", "return (w, url)", in: body(recorder, "private func endCapture(")))

// iPhone
let phoneTick = body(recorder, "private func phoneMuteTick(")
check("iPhone sources: only wired and USB mics are watched, with the shared silence rule, never while waiting for AirPods",
      phoneTick.contains("MuteRules.watchesForMute(") && phoneTick.contains("MuteRules.silent(") && phoneTick.contains("awaitingInput == nil") && phoneTick.contains("!isPaused"), phoneTick)
check("iPhone sources: a mute moves the recording to the iPhone microphone and says so",
      phoneTick.contains(".builtInMic") && phoneTick.contains("moveRecording(to: builtIn.uid)") && phoneTick.contains("setMicWarning(.usingBuiltIn("), phoneTick)
check("iPhone sources: a recording starts the watch, and Stop ends it",
      body(recorder, "func start(to url: URL) throws {").contains("startPhoneMuteWatch()") && body(recorder, "private func finishStop(").contains("stopPhoneMuteWatch()"))
check("iPhone sources: picking an input (Switch back included) ends the mute move and restarts the watch",
      body(recorder, "func useInput(").contains("clearPhoneMute(") && body(recorder, "func useInput(").contains("muteSince =")
      && body(recorder, "func switchBackFromMute(").contains("useInput(m.uid)"))
let sheet = read("VerbatimPhone/RecorderSheet.swift")
check("iPhone sources: the recorder shows the mute banner with Switch back", sheet.contains("mutedMic(note)") && sheet.contains("switchBackFromMute()"))
let phone = read("VerbatimPhone/PhoneState.swift")
check("iPhone sources: a mute move plays the warning haptic and posts in the background",
      phone.contains("recorder.onMicWarning") && phone.contains("Haptics.play(.autoPaused)") && phone.contains("RecordingPresence.shared.micMuted("))

// Mac warnings outside the app, and the setting
check("Mac sources: normal and meeting recordings post a notification for a mic warning",
      read("Verbatim/App/AppState.swift").contains("recorder.onMicWarning = { MicWarningNotice.changed($0) }")
      && read("Verbatim/App/MeetingSession.swift").contains("mic.onMicWarning = { MicWarningNotice.changed($0) }"))
check("Mac sources: the comparison is off for a meeting's mic track and Audio only",
      tick.contains("comparesMics, !soundOnly") && read("Verbatim/App/MeetingSession.swift").contains("mic.comparesMics = false"))
check("Mac sources: a built-in mic that sends nothing is released, and one that doesn't open stops being waited for",
      tick.contains("if muteBackup != nil { stopBackup() }") && startBackup.contains("self.backupOpening = false") && startBackup.contains("Self.startLimit"))
check("iPhone sources: a restart or a resume starts the mute watch over (a call isn't counted as silence)",
      body(recorder, "private func restartCapture(").contains("muteSince = ProcessInfo.processInfo.systemUptime")
      && body(recorder, "func togglePause(").contains("if !isPaused { muteSince = ProcessInfo.processInfo.systemUptime }"))
check("iPhone sources: partway through, the iPhone waits its longer window", phoneTick.contains("midWindow: MuteRules.phoneMidWindow"))
check("Mac sources: the notification only posts while Verbose isn't in front", read("Verbatim/App/MicWarningNotice.swift").contains("!NSApp.isActive"))
check("Mac sources: the menu bar mark shows the attention mark while the mic is muted", read("Verbatim/App/VerbatimApp.swift").contains("MenuBarMark(recorder:"))
check("Mac sources: Settings has Back up a muted mic, stored at the rules' key",
      read("Verbatim/Views/SettingsPanes.swift").contains("@AppStorage(MuteRules.backupKey) private var micBackup = true")
      && read("Verbatim/Views/SettingsPanes.swift").contains("SettingsToggleRow(\"speakers.micBackup\""))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
