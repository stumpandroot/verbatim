import Foundation

// Interface sounds (Verbatim/Model/SoundRules.swift, DESIGN.md §7, Sounds): the moments, the 150 ms rule, and the
// start sound before the microphone (MicArm) (SoundChecks.swift, which both apps' self-tests also run). Then the files, the project, and the
// sources. Reads them from the mac/ folder given as the first argument. Not part of any app target; run
// mac/tools/test-sounds.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

SoundChecks.run { check($0, $1) }

let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func read(_ path: String) -> String { (try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8)) ?? "" }

/// Every Swift file under the given folders: (path relative to mac/, text).
func sources(_ dirs: [String]) -> [(String, String)] {
    var out: [(String, String)] = []
    for d in dirs {
        let root = mac.appendingPathComponent(d)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
        for case let u as URL in e where u.pathExtension == "swift" {
            let rel = d + "/" + u.path.dropFirst(root.path.count + 1)
            out.append((rel, (try? String(contentsOf: u, encoding: .utf8)) ?? ""))
        }
    }
    return out
}

/// The text of a function, from its declaration to the next declaration at the same indent.
func body(_ text: String, _ decl: String) -> String {
    guard let r = text.range(of: decl) else { return "" }
    let rest = text[r.lowerBound...]
    let tail = rest.dropFirst(decl.count)
    let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    @discardableResult", "\n    private static func "]
        .compactMap { tail.range(of: $0)?.lowerBound }
    return String(ends.min().map { rest[..<$0] } ?? rest)
}

/// True when `a` appears in `text` and before `b`.
func before(_ a: String, _ b: String, in text: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

// MARK: The files

let folder = "Verbatim/Resources/Sounds"
let names = ((try? FileManager.default.contentsOfDirectory(atPath: mac.appendingPathComponent(folder).path)) ?? []).sorted()
let cafs = Set(names.filter { $0.hasSuffix(".caf") })
let wanted = Set(SoundMoment.allCases.map { "\($0.fileName).\(SoundMoment.fileExtension)" })
check("files: one CAF for every moment, and no other", cafs == wanted, "missing \(wanted.subtracting(cafs).sorted()), extra \(cafs.subtracting(wanted).sorted())")

/// A CAF file's format and length: (sample rate, format ID, channels, bits, seconds), or nil when it isn't one.
func caf(_ data: Data) -> (rate: Double, format: String, channels: UInt32, bits: UInt32, seconds: Double)? {
    let b = [UInt8](data)
    guard b.count > 8, String(bytes: b[0..<4], encoding: .ascii) == "caff" else { return nil }
    func u32(_ i: Int) -> UInt32 { b[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    func i64(_ i: Int) -> Int64 { Int64(bitPattern: b[i..<i + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }) }
    var i = 8
    var desc: (Double, String, UInt32, UInt32, UInt32)?
    var dataBytes: Int64?
    while i + 12 <= b.count {
        let type = String(bytes: b[i..<i + 4], encoding: .ascii) ?? ""
        let size = i64(i + 4)
        let start = i + 12
        if type == "desc", start + 32 <= b.count {
            let rate = Double(bitPattern: b[start..<start + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            let fmt = String(bytes: b[start + 8..<start + 12], encoding: .ascii) ?? ""
            desc = (rate, fmt, u32(start + 24), u32(start + 28), u32(start + 16))
        }
        if type == "data" { dataBytes = (size < 0 ? Int64(b.count - start) : size) - 4 }   // 4 bytes of edit count
        guard size >= 0 else { break }
        i = start + Int(size)
    }
    guard let d = desc, let n = dataBytes, d.4 > 0, d.0 > 0 else { return nil }
    return (d.0, d.1, d.2, d.3, Double(n) / Double(d.4) / d.0)
}

var formatProblems: [String] = []
var lengthProblems: [String] = []
for m in SoundMoment.allCases {
    let path = "\(folder)/\(m.fileName).\(SoundMoment.fileExtension)"
    guard let data = try? Data(contentsOf: mac.appendingPathComponent(path)), let f = caf(data) else { formatProblems.append("\(m.fileName): not a CAF"); continue }
    if f.rate != 48_000 || f.format != "lpcm" || f.channels != 1 || f.bits != 16 { formatProblems.append("\(m.fileName): \(f)") }
    if abs(f.seconds - m.seconds) > 0.002 { lengthProblems.append("\(m.fileName): file \(String(format: "%.3f", f.seconds)) s, rules \(m.seconds) s") }
}
check("files: every sound is 48 kHz mono 16-bit linear PCM in a CAF", formatProblems.isEmpty, "\(formatProblems)")
check("files: every file is as long as SoundMoment.seconds says (the keep-out window depends on it)", lengthProblems.isEmpty, "\(lengthProblems)")

let readme = read("\(folder)/README.md")
let unlisted = SoundMoment.allCases.filter { m in !readme.components(separatedBy: "\n").contains { $0.hasPrefix("| `\(m.fileName).caf`") } }
check("files: the README has a row for every sound", !readme.isEmpty && unlisted.isEmpty, "\(unlisted)")
let rows = readme.components(separatedBy: "\n").filter { $0.hasPrefix("| `") }
check("files: every row names its source and a license that needs no credit (CC0 or original)",
      rows.count == SoundMoment.allCases.count && rows.allSatisfy { ($0.contains("CC0 1.0") && $0.contains("https://github.com/wyzowl/sfx-kit/blob/")) || $0.contains("Original") },
      "\(rows)")

// MARK: The project

let project = read("project.yml")
check("project: the iPhone app has the player and the files, without the README",
      project.contains("- Verbatim/Audio/SoundPlayer.swift") && project.contains("- path: Verbatim/Resources/Sounds\n        excludes: [\"README.md\"]"))
check("project: the Mac app leaves the README out of the app", project.contains("\"Resources/Sounds/README.md\"]"))

// MARK: The sources

let code = sources(["Verbatim", "VerbatimPhone"])
let systemSounds = code.filter { $0.1.contains("NSSound(named") || $0.1.contains("NSSound.Name(") }.map(\.0)
check("sources: no system sounds by name are left (Pop, Tink, Bottle, Purr)", systemSounds.isEmpty, "\(systemSounds)")
let oldCalls = code.filter { f in ["Sounds.start()", "Sounds.done()", "Sounds.cancel()", "Sounds.queued()", "Sounds.play(\""].contains { f.1.contains($0) } }.map(\.0)
check("sources: nothing calls the old Sounds names", oldCalls.isEmpty, "\(oldCalls)")
let player = read("Verbatim/Audio/SoundPlayer.swift")
check("player: the Mac plays prepared players at volume 1, the iPhone system sounds made from the files",
      player.contains("p.prepareToPlay()") && player.contains("p.volume = 1") && player.contains("AudioServicesCreateSystemSoundID")
      && player.contains("AudioServicesPlaySystemSound(id)") && !player.contains("volume = 0"))
check("player: every sound passes the 150 ms rule and the switch", player.contains("spacing.allows(at:") && player.contains("guard enabled else { return nil }"))
check("player: the iPhone plays only in front and follows its own Sounds switch, apart from Haptics",
      player.contains("SoundRules.phonePlays(foreground: UIApplication.shared.applicationState == .active)")
      && player.contains("static var enabled: Bool { SoundSettings.enabled(in: Haptics.store) }") && !player.contains("{ Haptics.enabled }"))
let settingsScreen = read("VerbatimPhone/SettingsScreen.swift")
check("iPhone Settings: Sounds and Haptics are two rows, each searchable",
      settingsScreen.contains("SettingsToggleRow(title: \"Sounds\"") && settingsScreen.contains("SettingsToggleRow(title: \"Haptics\"")
      && settingsScreen.contains("@AppStorage(SoundSettings.enabledKey, store: Haptics.store)")
      && read("VerbatimPhone/SettingsSearch.swift").contains(".init(id: \"sounds\", section: personalization, label: \"Sounds\""))
check("iPhone: the old combined switch carries over to Sounds once, at the store", read("VerbatimPhone/Haptics.swift").contains("SoundSettings.migrate(group)"))
check("the keyboard and the watch keep following Haptics", read("VerbatimKeyboard/KeyboardModel.swift").contains("HapticSettings.enabled(in: d)")
      && read("VerbatimPhone/PhoneWatch.swift").contains("haptics: Haptics.enabled)") && !read("VerbatimKeyboard/KeyboardModel.swift").contains("SoundSettings"))
check("player: both apps load every sound at launch",
      read("Verbatim/App/AppState.swift").contains("Sounds.preload()") && read("VerbatimPhone/PhoneState.swift").contains("Sounds.preload()"))
check("player: the Mac follows Settings › General › Sounds", read("Verbatim/App/AppState.swift").contains("didSet { Sounds.enabled = sounds }"))

// Never for frequent actions: copy, export's copy, Copy for AI, a move to a project, Accept all, Clean up.
let quiet = ["Verbatim/Views/ExportMenu.swift", "Verbatim/Views/ExportSheet.swift", "Verbatim/Views/TrustViews.swift",
             "Verbatim/App/AppState+Library.swift", "Verbatim/Document/DocumentView.swift"]
let noisy = quiet.filter { read($0).contains("Sounds.") }
check("sources: copies, moves, and edits play no sound", noisy.isEmpty, "\(noisy)")
let phoneNoisy = code.filter { $0.0.hasPrefix("VerbatimPhone/") && $0.1.contains("Sounds.play(") }.map(\.0).sorted()
check("sources: on the iPhone only recording, results, and errors play (PhoneState)", phoneNoisy == ["VerbatimPhone/PhoneState.swift"], "\(phoneNoisy)")

// The moments, in place.
let dictation = read("Verbatim/App/Dictation.swift")
let begin = body(dictation, "    private func begin(handsFree: Bool, command wantCommand: Bool)")
check("dictation: the start tick plays before the mic opens, arming the recording, and before Accessibility is read",
      before("Sounds.playBeforeMic(.dictationStart, arming: recorder)", "try recorder.start(to:", in: begin)
      && before("Sounds.playBeforeMic(.dictationStart, arming: recorder)", "AppContext.capture(", in: begin))
let finishNow = body(dictation, "    private func finishNow(tail: Double)")
check("dictation: the stop plays after the mic is off (the tail included), not for a thought",
      before("recorder.stop()", "Sounds.play(.dictationStop)", in: finishNow) && finishNow.contains("if !(toPad && !command) { Sounds.play(.dictationStop) }"))
check("dictation: a queued dictation plays nothing until its mic opens", !body(dictation, "    private func queueStart(").contains("Sounds."))
check("dictation: Esc plays the cancel", body(dictation, "    func cancel(quiet: Bool = false)").contains("Sounds.play(.dictationCancel)")
      && body(dictation, "    private func cancelWriting()").contains("Sounds.play(.dictationCancel)"))
check("dictation: the paste's outcome picks pasted or the error", dictation.contains("Sounds.play(SoundRules.afterPaste(Self.pasteResult(outcome)))"))
check("dictation: a mic that can't start or be heard plays the error", body(dictation, "    private func showMicProblem(").contains("Sounds.play(.error)"))

let capture = read("Verbatim/App/AppState+Capture.swift")
check("Mac recording: the start plays before the mic opens, arming the recording; the stop plays once capture ends",
      before("Sounds.playBeforeMic(SoundRules.start(), arming: recorder)", "recorder.begin(to: url)", in: body(capture, "    func startRecording()"))
      && capture.contains("await recorder.stopAndSave(captureEnded: { Sounds.play(SoundRules.stop(thought: false)) })"))
let thoughts = read("Verbatim/Flow/Thoughts.swift")
check("Mac thought: dictation's tick before the mic opens, arming the recording; Thought saved once it's filed",
      before("Sounds.playBeforeMic(SoundRules.start(thought: true), arming: recorder)", "recorder.begin(to: url)", in: thoughts) && body(thoughts, "    func file(").contains("Sounds.play(SoundRules.stop(thought: true))"))
let session = read("Verbatim/App/MeetingSession.swift")
check("meeting: the start (or the automatic call's) before the mic track opens, arming it; the stop after the mic is off",
      before("Sounds.playBeforeMic(SoundRules.start(automatic: startedAutomatically), arming: recorder)", "recorder.begin(to: micURL)", in: session)
      && session.contains("await mic.stopAndSave(captureEnded: { Sounds.play(SoundRules.stop(thought: false)) })"))
check("meeting: a call the wait started is automatic", read("Verbatim/App/MeetingCoordinator.swift").contains("automatic: announce)"))
let pipeline = read("Verbatim/App/AppState+Pipeline.swift")
check("Mac results: transcription done for recordings only, the error when transcription fails",
      pipeline.contains("SoundRules.transcriptDone(isDictation:") && body(pipeline, "    func jobFailed(").contains("Sounds.play(.error)"))
check("summary ready: once a batch's last summary is written", read("Verbatim/Transcription/Summarizer.swift").contains("if queue.isEmpty { Sounds.play(.summaryReady) }"))
let phone = read("VerbatimPhone/PhoneState.swift")
let startRecording = body(phone, "    func startRecording()")
check("iPhone recording: the start before the mic opens, arming the recording; the stop once capture ends",
      before("Sounds.playBeforeMic(SoundRules.start(thought: thought), arming: recorder)", "try recorder.start(to: url)", in: startRecording)
      && phone.contains("await recorder.stopAndSave(captureEnded: { Sounds.play(stopSound) })"))
check("iPhone results: transcription done with the ready haptic, for recordings only",
      body(phone, "    private func playReady(").contains("SoundRules.transcriptDone(isDictation:"))

// The microphone and the system track never keep Verbose's own sounds.
let recorder = read("Verbatim/Audio/Recorder.swift")
let write = body(recorder, "    private func write(_ buffer: AVAudioPCMBuffer, tapped:")
check("arm: the writer drops what came before the arm before the live words and the file get the buffer",
      before("MicArm.kept(", "if liveTap != nil { tapped = out; tap = liveTap }", in: write) && before("MicArm.kept(", "append(out, to: file", in: write))
check("arm: nothing is ever replaced with silence (no keep-out, no silencing)",
      !recorder.contains("MicKeepOut") && !recorder.contains("Self.silence(") && !read("Verbatim/Audio/SoundPlayer.swift").contains("keepingOutOf"))
check("arm: the recorder arms from the sound's start and every new writer takes it before its first buffer",
      body(recorder, "    func armAfterSound(seconds: Double?)").contains("MicArm.at(playedAt: ProcessInfo.processInfo.systemUptime")
      && recorder.components(separatedBy: "if let a = takeArm() { w.arm(at: a) }").count == 3
      && recorder.contains("if let arm { w.arm(at: arm) }") && recorder.contains("let arm = takeArm()"))
// App audio has no microphone (its capture leaves Verbose's own audio out), so its start plays as it begins.
let plainStarts = code.filter { $0.1.contains("Sounds.play(SoundRules.start(") || $0.1.contains("Sounds.play(.dictationStart") }.map(\.0)
check("arm: every start sound that opens a mic plays through playBeforeMic",
      plainStarts == ["Verbatim/App/AppState+Capture.swift"] && body(capture, "    func startCapture(").contains("Sounds.play(SoundRules.start())")
      && capture.components(separatedBy: "Sounds.play(SoundRules.start(").count == 2
      && code.filter { $0.1.contains("Sounds.playBeforeMic(") }.count == 5, "\(plainStarts)")
check("keep out: stopAndSave's captureEnded runs after the mic is off and before the join",
      before("finishStop()\n        captureEnded?()", "RecordingSegments.join(parts)", in: body(recorder, "    func stopAndSave(captureEnded:")))
let tap = read("Verbatim/Audio/ProcessTapCapture.swift")
check("system track: a global tap leaves Verbose's own process out",
      tap.contains("Self.processObject(pid: getpid())") && tap.components(separatedBy: "CATapDescription(monoGlobalTapButExcludeProcesses: exclude)").count == 3)
check("system track: ScreenCaptureKit leaves Verbose's own audio out", read("Verbatim/Audio/AppAudioCapture.swift").contains("cfg.excludesCurrentProcessAudio = true"))
check("iPhone: recording sessions let system sounds play while recording",
      body(recorder, "    static func allowHaptics(").contains("setAllowHapticsAndSystemSoundsDuringRecording(true)"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
