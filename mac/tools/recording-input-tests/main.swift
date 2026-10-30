import Foundation

// Recording input (Verbatim/Model/RecordingInputRules.swift, DESIGN.md §6.10): which microphone an iPhone recording
// uses, the ready chip from a mocked route, the microphone menu, the session's mode and AirPods high-quality option,
// and route changes (RecordingInputChecks, which the iPhone's self-test also runs). Then the sources: the iPhone picks
// and sets the input before the session activates, never pairs the high-quality option with a mode other than the
// default, and a route change keeps the recording on its input. Reads the Swift sources from the mac/ folder given as
// the first argument. Not part of any app target; run mac/tools/test-recording-input.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

RecordingInputChecks.run { check($0, $1) }

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
    let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    @discardableResult", "\n    private static func ",
                "\n    /// "].compactMap { tail.range(of: $0)?.lowerBound }
    return String(ends.min().map { rest[..<$0] } ?? rest)
}
func before(_ a: String, _ b: String, in text: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

let recorder = read("Verbatim/Audio/Recorder.swift")
let options = body(recorder, "static func options(")
check("sources: the high-quality option is asked for only when the plan says so, never by default",
      options.contains("highQuality: Bool = false") && options.contains("if highQuality, #available(iOS 26, *) { o.insert(.bluetoothHighQualityRecording) }"),
      options)
let prepare = body(recorder, "static func prepare(")
check("sources: RecordingRoute.prepare sets the category, then picks the input from what iOS lists, then sets it",
      before("setCategory(", "RecordingInputRules.choose(", in: prepare) && before("RecordingInputRules.choose(", "setPreferredInput(", in: prepare), prepare)
check("sources: prepare follows the plan's mode and option together",
      prepare.contains("RecordingInputRules.plan(") && prepare.contains("plan.mode") && prepare.contains("highQuality: plan.highQuality"), prepare)
let start = body(recorder, "func start(to url: URL) throws {")
check("sources: a recording picks its input before the session activates, and sets it again once it's active",
      before("RecordingRoute.prepare(", "session.setActive(true)", in: start) && before("session.setActive(true)", "RecordingRoute.confirm(", in: start), start)
check("sources: no recording sets the category with spoken audio or measurement and the high-quality option by hand",
      !recorder.contains("mode: soundOnly ? .measurement : .spokenAudio, options: RecordingRoute.options())"))
let restart = body(recorder, "private func restartCapture(")
check("sources: restarting capture keeps the recording's input while it's there (a route change used to move it to the iPhone microphone)",
      restart.contains("pinRecordingInput()") && !recorder.contains("pinBuiltInMic"), restart)
check("sources: the input to restart on comes from the rules",
      body(recorder, "private func pinRecordingInput(").contains("RecordingInputRules.afterRouteChange("))
let changed = body(recorder, "private func configurationChanged(")
check("sources: a route change says the microphone disconnected only when the input really changed",
      changed.contains("self.pinnedInputUID != before"), changed)
let pinCurrent = body(recorder, "private func pinCurrentInput(")
check("sources: the recording pins the input it chose, not whatever the route said a moment after starting",
      pinCurrent.contains("chosenInput"), pinCurrent)
check("sources: the choice in the microphone menu lasts for one recording",
      body(recorder, "private func finishStop(").contains("chosenInputUID = nil"))
let keyboard = read("VerbatimPhone/KeyboardSession.swift")
check("sources: the keyboard session follows the same plan without pinning an input",
      keyboard.contains("RecordingRoute.prepare(s, soundOnly: false, mixWithOthers: true, chosen: nil, pin: false)"))
let home = read("VerbatimPhone/HomeScreen.swift")
check("sources: Home's chip names the input a recording will use, not the route's first input or a fixed name",
      home.contains("RecordingRoute.readyText(") && !home.contains("?? \"iPhone Microphone\""))
let sheet = read("VerbatimPhone/RecorderSheet.swift")
check("sources: the recorder's microphone capsule is a menu of the inputs that sets the recording's input",
      sheet.contains("RecordingInputRules.menu(") && sheet.contains("app.recorder.useInput("))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
