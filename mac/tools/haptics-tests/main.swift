import Foundation

// Haptics (Verbatim/Model/HapticPolicy.swift, DESIGN.md §7): which event plays which haptic, the switch turning them
// all off, once-per-recording success, and the keyboard's typing taps off by default (HapticChecks.swift, which the
// iPhone's self-test also runs). Then the sources: every recording session allows haptics before it activates, every
// haptic goes through the policy, and start and stop play at the right moment. Reads the Swift sources from the mac/
// folder given as the first argument. Not part of any app target; run mac/tools/test-haptics.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

HapticChecks.run { check($0, $1) }

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
    let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    @MainActor func "].compactMap { tail.range(of: $0)?.lowerBound }
    return String(ends.min().map { rest[..<$0] } ?? rest)
}

/// True when `a` appears in `text` and before `b`.
func before(_ a: String, _ b: String, in text: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

let iPhoneDirs = ["Verbatim", "VerbatimPhone", "VerbatimKeyboard", "VerbatimWidgets", "VerbatimShare", "VerbatimBroadcast"]
let all = sources(iPhoneDirs)
let code = all.filter { !$0.0.hasPrefix("Verbatim/Model/HapticChecks") }

// Haptics while recording: iOS turns haptics off when recording begins unless the session allows them before it
// activates. Every recording category goes through RecordingRoute.setCategory, which allows them.
let rawCategory = code.flatMap { file in
    file.1.components(separatedBy: "\n").filter { $0.contains("setCategory(") && !$0.contains("RecordingRoute.setCategory(") && !$0.contains("func setCategory(")
        && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.map { "\(file.0): \($0.trimmingCharacters(in: .whitespaces))" }
}
check("sessions: every recording category is set through RecordingRoute.setCategory (one raw call, inside it)",
      rawCategory.count == 1 && rawCategory[0].hasPrefix("Verbatim/Audio/Recorder.swift"), "\(rawCategory)")
let recorder = read("Verbatim/Audio/Recorder.swift")
let route = body(recorder, "static func setCategory(")
check("sessions: RecordingRoute.setCategory allows haptics after the category",
      before("s.setCategory(.playAndRecord", "allowHaptics(s)", in: route), route)
check("sessions: RecordingRoute.allowHaptics sets allowHapticsAndSystemSoundsDuringRecording",
      body(recorder, "static func allowHaptics(").contains("setAllowHapticsAndSystemSoundsDuringRecording(true)"))
// Home's meter (HomeKit.swift) retired with the refined Home, and its microphone session with it.
let setUps = ["Verbatim/Audio/Recorder.swift", "VerbatimPhone/KeyboardSession.swift", "VerbatimPhone/PhoneDucker.swift"]
// The keyboard session and voice notes set it through RecordingRoute.prepare, which calls RecordingRoute.setCategory.
let missing = setUps.filter { !read($0).contains("RecordingRoute.setCategory(") && !read($0).contains("RecordingRoute.prepare(") }
check("sessions: voice notes, thoughts, Live captions, the keyboard session, and lowering audio all use it",
      missing.isEmpty, "\(missing)")
check("sessions: reactivations after a route change or a call allow haptics again",
      read("VerbatimPhone/SessionCapture.swift").contains("RecordingRoute.allowHaptics()") && body(recorder, "private func restartCapture(").contains("RecordingRoute.allowHaptics()"))
let watch = read("VerbatimWatch/WatchRecorder.swift")
let watchBegin = body(watch, "private func begin(")
check("sessions: the watch allows haptics before its session activates",
      before("setAllowHapticsAndSystemSoundsDuringRecording(true)", "session.setActive(true)", in: watchBegin))

// One wrapper: no feedback generator or watch haptic outside the policy, except the prepared generators that play
// through it (the Record as tray through Haptics, the typing keys through HapticPolicy's typing tap).
let allowedGenerators: Set<String> = ["Verbatim/Model/HapticPolicy.swift", "VerbatimPhone/Haptics.swift", "VerbatimPhone/RecordTray.swift", "VerbatimKeyboard/TypingKeys.swift"]
let strayGenerators = code.filter { $0.1.contains("FeedbackGenerator(") && !allowedGenerators.contains($0.0) }.map(\.0)
check("wrapper: no feedback generator outside Haptics and the policy", strayGenerators.isEmpty, "\(strayGenerators)")
let sensory = code.flatMap { file in
    file.1.components(separatedBy: "\n").filter { $0.contains(".sensoryFeedback(") && !$0.contains("Haptics.feedback(") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .map { "\(file.0): \($0)" }
}
check("wrapper: every .sensoryFeedback asks Haptics", sensory.isEmpty, "\(sensory)")
check("wrapper: the watch plays only what the policy picks", !watch.contains("play(.start)") && !watch.contains("play(.click)") && !watch.contains("play(.stop)")
      && watch.contains("HapticPolicy(enabled: link.context?.haptics ?? true, platform: .watch)"))
let keyboard = read("VerbatimKeyboard/KeyboardModel.swift")
check("wrapper: the keyboard reads Haptics and Typing haptics from the App Group, only with Full Access",
      keyboard.contains("HapticSettings.enabled(in: d)") && keyboard.contains("let d = hasFullAccess ? KeyboardBridge.defaults : nil"))
check("wrapper: the keyboard's start and Done are the app's start and stop",
      keyboard.contains("haptic(.recordStart)") && keyboard.contains("haptic(.recordStop)") && !keyboard.contains("haptic(.medium)"))

// The moments: start before the microphone, stop at the tap, nothing after saving.
let phone = read("VerbatimPhone/PhoneState.swift")
check("moments: Record's start tap plays before the recorder starts",
      before("Haptics.play(.recordStart)", "try recorder.start(to: url)", in: body(phone, "func startRecording()")))
let finish = body(phone, "private func finishRecording(")
check("moments: Stop and Discard tap before saving", before("Haptics.play(.recordStop)", "await recorder.stopAndSave()", in: finish))
let afterSave = finish.components(separatedBy: "await recorder.stopAndSave()").dropFirst().joined()
let afterSavePlays = afterSave.components(separatedBy: "Haptics.play(").dropFirst().map { String($0.prefix(while: { $0 != ")" })) }
check("moments: nothing plays after saving but an error", afterSavePlays.allSatisfy { $0 == ".failed" }, "\(afterSavePlays)")
check("moments: Live captions tap before their microphone opens",
      before("Haptics.play(.recordStart)", "try recorder.start(to: url)", in: read("VerbatimPhone/LiveCaptionsScreen.swift")))
check("moments: the keyboard session taps before its microphone opens",
      before("Haptics.play(.recordStart)", "try startAudio()", in: read("VerbatimPhone/KeyboardSession.swift")))
let pause = body(phone, "func togglePause()")
check("moments: Resume taps before writing starts again, Pause after it stops",
      before("Haptics.play(.resume)", "recorder.togglePause()", in: pause) && before("recorder.togglePause()", "Haptics.play(.pause)", in: pause))
check("moments: transcript ready plays once per recording, in front", phone.contains("readyOnce.ready(id, foreground: front, queueEmpty: queueEmpty)"))
check("moments: the watch taps start before its microphone opens", before("play(.recordStart)", "session.setActive(true)", in: watchBegin))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
