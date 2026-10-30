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
    let ends = ["\n    func ", "\n    private func ", "\n    private var ", "\n    static func ", "\n    @discardableResult", "\n    private static func ",
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
// Every category the iPhone sets goes through a plan: in the recorder, only RecordingRoute.prepare and move call
// RecordingRoute.setCategory, each call takes its mode and high-quality option from one plan, and each of those two
// records the plan it set (`lastPlan`, which the iPhone's self-test reads after a real prepare). Elsewhere, only
// lowering other audio changes the category, and it keeps the session's mode and options as the plan left them.
func lines(_ text: String, containing needle: String) -> [String] {
    text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.contains(needle) && !$0.hasPrefix("//") }
}
let planned = try! NSRegularExpression(pattern: #"^(try )?RecordingRoute\.setCategory\(s, mode: mode\((\w+)\.mode\), options: options\(mixWithOthers: \w+, highQuality: \2\.highQuality\)\)$"#)
func throughPlan(_ line: String) -> Bool {
    planned.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}
let move = body(recorder, "static func move(to uid: String")
let routeCalls = lines(recorder, containing: "setCategory(").filter { !$0.contains("func setCategory(") && !$0.hasPrefix("try s.setCategory(.playAndRecord, mode: mode, options: options)") }
check("sources: the recorder sets the category only through a plan's mode and high-quality option (\(routeCalls.count) calls)",
      !routeCalls.isEmpty && routeCalls.allSatisfy(throughPlan), routeCalls.filter { !throughPlan($0) }.joined(separator: "\n    "))
check("sources: only RecordingRoute.prepare and move set the recorder's category, and both record the plan",
      lines(prepare, containing: "RecordingRoute.setCategory(").count + lines(move, containing: "RecordingRoute.setCategory(").count == routeCalls.count
      && prepare.contains("lastPlan = plan") && move.contains("lastPlan = plan") && move.contains("RecordingInputRules.replan("), move)
check("sources: the raw category call is the one inside RecordingRoute.setCategory",
      lines(recorder, containing: "s.setCategory(.playAndRecord").count == 1 && body(recorder, "static func setCategory(").contains("try s.setCategory(.playAndRecord, mode: mode, options: options)"))
let ducker = read("VerbatimPhone/PhoneDucker.swift")
check("sources: lowering other audio keeps the session's mode and options as the plan left them",
      lines(ducker, containing: "setCategory(") == ["try RecordingRoute.setCategory(s, mode: s.mode, options: options)"] && ducker.contains("var options = s.categoryOptions"))
let keyboardSession = read("VerbatimPhone/KeyboardSession.swift")
check("sources: the keyboard session sets its category only through prepare", lines(keyboardSession, containing: "setCategory(").isEmpty)
let restart = body(recorder, "private func restartCapture(")
check("sources: restarting capture keeps the recording's input while it's there (a route change used to move it to the iPhone microphone)",
      restart.contains("pinRecordingInput()") && !recorder.contains("pinBuiltInMic"), restart)
let pinRecording = body(recorder, "private func pinRecordingInput(")
check("sources: the input to restart on comes from the rules",
      pinRecording.contains("RecordingInputRules.afterRouteChange("))
check("sources: when the recording's input goes, the move takes the new input's mode and options (review fix 3)",
      before("guard choice != pinnedInputUID", "RecordingRoute.move(to: choice, soundOnly: soundOnly, s)", in: pinRecording), pinRecording)
let pause = body(recorder, "func togglePause(")
check("sources: Resume restarts capture when you picked a microphone while paused and the route didn't follow (review fix 4)",
      pause.contains("routeOffPinnedInput") && pause.contains("!engine.isRunning || moveOnResume")
      && body(recorder, "private var routeOffPinnedInput").contains("currentRoute.inputs.first?.uid != pinned"), pause)
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
check("sources: the capsule names the route after a move, and keeps its name when the move fails (review fix 4)",
      sheet.contains("if app.recorder.useInput(input.uid) != nil { mic = HomeScreen.currentMic() }") && !sheet.contains("mic = name"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
