import Foundation

// Motion (Verbatim/Model/MotionRules.swift, DESIGN.md §7): the rules (MotionChecks.swift, which both self-tests also
// run), then the sources that use them. Reads the Swift sources from the mac/ folder given as the first argument. Not
// part of any app target; run mac/tools/test-motion.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

MotionChecks.run { check($0, $1) }

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

/// A type's text, from `start` to the closing brace at the start of a line.
func typeBody(_ text: String, from start: String) -> String {
    guard let r = text.range(of: start) else { return "" }
    let rest = text[r.lowerBound...]
    return String(rest.range(of: "\n}\n").map { rest[..<$0.lowerBound] } ?? rest)
}

/// The lines of code (not comments) in `text`.
func codeLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
}

/// The text from `start` to the next line that starts a declaration at the same or a lower indent.
func block(_ text: String, from start: String) -> String {
    guard let r = text.range(of: start) else { return "" }
    let rest = text[r.lowerBound...]
    let ends = ["\n    private var ", "\n    var ", "\n    private func ", "\n    func ", "\n}\n"].compactMap { rest.dropFirst(start.count).range(of: $0)?.lowerBound }
    return String(ends.min().map { rest[..<$0] } ?? rest)
}

let appDirs = ["Verbatim", "VerbatimPhone", "VerbatimKeyboard", "VerbatimWatch", "VerbatimWidgets", "VerbatimMacWidgets"]
let all = sources(appDirs)
check("sources: found the app's Swift files", all.count > 100, "\(all.count)")

// Loops and scope.
let repeating = all.flatMap { f in codeLines(f.1).filter { $0.contains("repeatForever") }.map { "\(f.0): \($0.trimmingCharacters(in: .whitespaces))" } }
check("loops: nothing repeats forever; loops draw from the time (LoopTimeline)", repeating.isEmpty, "\(repeating)")
let unscoped = all.flatMap { f in codeLines(f.1).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".animation(") && !$0.contains("value:") }.map { "\(f.0): \($0)" } }
check("scope: every .animation modifier names its value", unscoped.isEmpty, "\(unscoped)")
let swipe = typeBody(read("VerbatimPhone/KeyboardSessionScreens.swift"), from: "private struct SwipeHint")
check("loops: the keyboard session's swipe hint is a LoopTimeline drawn from SwipeHintLoop, still under Limit animation",
      swipe.contains("LoopTimeline(running: !limitMotion)") && swipe.contains("SwipeHintLoop.progress(at:") && !swipe.contains("withAnimation"), swipe)

// Toasts.
let phoneApp = read("VerbatimPhone/PhoneApp.swift")
check("toasts: the iPhone toast only fades under Limit animation",
      phoneApp.contains(".transition(limitMotion ? .opacity : .move(edge: .top).combined(with: .opacity))")
      && phoneApp.contains(".animation(limitMotion ? Motion.fade : Motion.settle, value: app.toast)"))
check("toasts: a finger on the iPhone toast holds it", phoneApp.contains("app.holdToast(true)") && phoneApp.contains("app.holdToast(false)"))
let phone = read("VerbatimPhone/PhoneState.swift")
check("toasts: the iPhone times its toasts with ToastTiming (3 s alone)",
      phone.contains("ToastTiming.remaining(") && phone.contains("plain: ToastTiming.phonePlain") && !phone.contains("3_000_000_000); if self.toast"))
let delete = block(phone, from: "    func delete(_ ids: [UUID])")
check("toasts: Delete on iPhone offers Undo, which restores through the Store",
      delete.contains("action: ToastUndo.title") && delete.contains("store.restore($0)"), delete)
let macToast = read("Verbatim/App/Toast.swift")
check("toasts: the Mac times its toasts with ToastTiming (4.5 s alone) and holds one under the pointer",
      macToast.contains("plain: ToastTiming.macPlain") && macToast.contains(".onHover") && !macToast.contains("4_500_000_000"))
check("toasts: ⌘Z on the Mac runs the toast's Undo through ToastUndo, never while editing text",
      macToast.contains("ToastUndo.commandZRuns(") && macToast.contains("firstResponder is NSText")
      && read("Verbatim/Views/ContentView.swift").contains("ToastUndoKey.shared.install(app)"))
check("toasts: Delete on the Mac offers the same Undo", read("Verbatim/App/AppState+Library.swift").contains("action: \"Undo\") { [weak self] in\n            ids.forEach { self?.store.restore($0) }"))

// Keyboard actions don't animate.
let recall = typeBody(read("Verbatim/Flow/Recall.swift"), from: "struct RecallPanelView")
check("keys: Recall appears at once from its shortcut: a 0.1 s fade, no drop or spring",
      recall.contains(".animation(.easeOut(duration: KeyMotion.recallFade), value: model.shown)") && !recall.contains(".offset(y:") && !recall.contains(".spring("), recall)
let ribbon = read("Verbatim/Flow/FlowBarView.swift")
let listening = block(ribbon, from: "    private var listeningTransition")
check("keys: the Ribbon's listening contents fade in over 0.1 s, with no delay and no scale",
      listening.contains("KeyMotion.listeningFade") && !listening.contains(".delay(") && !listening.contains(".scale(")
      && block(ribbon, from: "        case .listening:\n            VStack(spacing: 4)").contains(".transition(listeningTransition)"), listening)
check("surfaces: the Ribbon and the notch morph on one token, Motion.surfaceMorph (MAC-33)",
      !ribbon.contains("0.38 s, a little bounce") && ribbon.contains("Motion.surfaceMorph") && read("Verbatim/Flow/Notch.swift").contains("Motion.surfaceMorph")
      && !read("Verbatim/Flow/Notch.swift").contains(".timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)")
      && read("Verbatim/Views/Tokens.swift").contains("static let surfaceMorph = Animation.smooth(duration: \(SurfaceMotion.morphDuration))")
      && read("Verbatim/Views/Tokens.swift").contains("static let surfaceStillFade = AnyTransition.opacity.animation(.easeOut(duration: \(SurfaceMotion.stillFade)))"))
check("surfaces: held still, the shape changes at once and the contents crossfade (GPT-09)",
      ribbon.contains("private var morph: Animation? { SurfaceMotion.morphs(still: reduceMotion) ? Motion.surfaceMorph : nil }")
      && ribbon.contains("private var liveMorph: Animation? { SurfaceMotion.morphs(still: reduceMotion) ? Motion.surfaceMorph : nil }")
      && read("Verbatim/Flow/Notch.swift").contains("private var morph: Animation? { SurfaceMotion.morphs(still: still) ? Motion.surfaceMorph : nil }")
      && !ribbon.contains(".easeOut(duration: 0.12) : .smooth") && ribbon.contains("SurfaceMotion.shownOffset(shown: model.shown, still: reduceMotion)"))
check("surfaces: the prompt card slides in only with motion on (MAC-11)",
      ribbon.contains(".transition(reduceMotion ? Motion.surfaceStillFade\n                                    : .asymmetric(insertion: .move(edge: screenEdge)"))
check("surfaces: the controller shows and hides the Ribbon on the same rule",
      read("Verbatim/Flow/FlowBar.swift").contains("withAnimation(Self.showAnimation) { self?.model.shown = true }")
      && read("Verbatim/Flow/FlowBar.swift").contains("still ? .easeOut(duration: SurfaceMotion.stillFade) : Motion.surfaceMorph"))
check("surfaces: other contents fade without a scale", !block(ribbon, from: "    private var contentTransition").contains(".scale("))
let notch = read("Verbatim/Flow/Notch.swift")
check("keys: the notch's listening wings fade in over 0.1 s, no delay or scale",
      notch.contains("KeyMotion.listeningFade") && notch.components(separatedBy: ".transition(listeningFade)").count == 3
      && !block(notch, from: "    private var listeningFade").contains(".scale("))
let content = read("Verbatim/Views/ContentView.swift")
check("keys: a navigation from the keyboard doesn't slide (ScreenEntrance through NavEntrance)",
      content.contains("NavEntrance.of(launch: app.navCount == 0, keyboard: app.nav.keyboard, limited: limitMotion)")
      && content.contains("if entrance != .slide { return .zero }") && content.contains("limited: entrance == .fade"))
let state = read("Verbatim/App/AppState.swift")
check("keys: go records where the navigation came from", state.contains("keyboard: navFromKeyboard)") && state.contains("func fromKeyboard<T>("))
let keyPaths: [(String, String)] = [
    ("Verbatim/App/NavTrail.swift", "app.fromKeyboard(AppState.handlingKeyPress) { NavTrail.shared.goBack(app) }"),
    ("Verbatim/App/NavTrail.swift", "app.fromKeyboard(AppState.handlingKeyPress) { NavTrail.shared.goForward(app) }"),
    ("Verbatim/Views/LibraryView.swift", ".onKeyPress(.return) { app.fromKeyboard { openSelected() }"),
    ("Verbatim/Views/LibraryView.swift", ".onKeyPress(.space) { app.fromKeyboard { playSelected() }"),
    ("Verbatim/Views/MacSidebar.swift", ".onKeyPress(.upArrow) { app.fromKeyboard { step(-1) } }"),
    ("Verbatim/Views/MacSidebar.swift", ".onKeyPress(.downArrow) { app.fromKeyboard { step(1) } }"),
    ("Verbatim/Views/AskViews.swift", ".onSubmit { app.fromKeyboard { submit() } }"),
    ("Verbatim/App/VerbatimApp.swift", "Button(\"New Transcript\") { app.fromKeyboard(AppState.handlingKeyPress) { app.openImport() } }"),
    ("Verbatim/App/VerbatimApp.swift", "Button(\"Import…\") { app.fromKeyboard(AppState.handlingKeyPress) { app.openImport() } }"),
]
let missingKeys = keyPaths.filter { !read($0.0).contains($0.1) }.map { "\($0.0): \($0.1)" }
check("keys: ⌘[ and ⌘], Return and Space on a row, the sidebar's arrows, Return in Search, ⌘N and ⌘O navigate as keyboard actions",
      missingKeys.isEmpty, "\(missingKeys)")

// Follow playback jumps under Limit animation.
let follows = all.flatMap { f in codeLines(f.1).filter { $0.contains("proxy.scrollTo(s.id") && $0.contains("withAnimation") }.map { (f.0, $0) } }
check("follow: Follow playback scrolls without animation under Limit animation (iPhone and Mac)",
      follows.count == 3 && follows.allSatisfy { $0.1.contains("withAnimation(limitMotion ? nil : Motion.settle)") }, "\(follows)")

// Counts change in place.
let tokens = read("Verbatim/Views/Tokens.swift")
let countChange = typeBody(tokens, from: "struct CountChange")
check("counts: CountChange rolls digits on snap, crossfades under Limit animation",
      countChange.contains(".contentTransition(limited ? .opacity : .numericText(value: Double(value)))")
      && countChange.contains(".animation(limited ? Motion.crossfade : Motion.snap, value: value)"), countChange)
let counts: [(String, String)] = [
    ("Verbatim/Views/RefinedKit.swift", ".countChange(words)"),
    ("Verbatim/Views/RefinedKit.swift", ".countChange(countValue)"),
    ("VerbatimPhone/LibraryScreen.swift", "countValue: countNumber(items)"),
    ("VerbatimPhone/RecorderSheet.swift", ".countChange(list.count)"),
    ("Verbatim/Views/ActionsView.swift", ".countChange(partIndex)"),
]
let missingCounts = counts.filter { !read($0.0).contains($0.1) }.map { "\($0.0): \($0.1)" }
check("counts: This week's words, the Library's count, the recorder's moments, and a run's part change in place", missingCounts.isEmpty, "\(missingCounts)")
let bareNumeric = all.flatMap { f in codeLines(f.1).filter { $0.contains(".numericText()") }.map { "\(f.0): \($0)" } }
check("counts: every numericText has a value", bareNumeric.isEmpty, "\(bareNumeric)")
let clocks = all.flatMap { f in codeLines(f.1).filter { ($0.contains("countChange(") || $0.contains("numericText(")) && ($0.contains("elapsed") || $0.contains("Clock")) }.map { "\(f.0): \($0)" } }
check("counts: never on a running clock", clocks.isEmpty, "\(clocks)")

// Onboarding.
for p in ["Verbatim/Views/OnboardingView.swift", "VerbatimPhone/PhoneOnboarding.swift"] {
    let s = read(p)
    check("onboarding: \(p) slides by direction (slideSwitch), so Back slides the other way",
          s.contains(".slideSwitch(on: step, order: step)") && !s.contains(".move(edge: .trailing)"))
}

// Limit animation reaches the keyboard.
check("keyboard: MotionMirror's key is Limit animation's key", tokens.contains("static let key = \"motion.limited\"") && read("Verbatim/Model/MotionRules.swift").contains("static let key = \"motion.limited\""))
check("keyboard: the iPhone copies Limit animation into the App Group at launch and on change",
      phone.contains("MotionMirror.mirror(UserDefaults.standard.bool(forKey: MotionPreference.key), into: KeyboardBridge.defaults)")
      && phone.contains("UserDefaults.didChangeNotification"))
let kbModel = read("VerbatimKeyboard/KeyboardModel.swift"), kbView = read("VerbatimKeyboard/KeyboardView.swift"), bars = read("VerbatimKeyboard/VoiceBars.swift")
check("keyboard: it reads Limit animation from the App Group only with Full Access, and stills its bars with it or Reduce Motion",
      kbModel.contains("MotionMirror.limited(in: defaults)") && kbModel.contains("private var defaults: UserDefaults? { hasFullAccess ? KeyboardBridge.defaults : nil }")
      && kbView.contains(".environment(\\.limitMotion, systemReduceMotion || model.motionLimited)")
      && !kbView.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion") && bars.contains("@Environment(\\.limitMotion)"))
check("keyboard: MotionRules is in the keyboard's target", read("project.yml").contains("      - Verbatim/Model/MotionRules.swift"))

// The springs Tim kept (November 7, 2026).
check("kept: page and glide springs unchanged",
      tokens.contains("static let glide = Animation.spring(duration: 0.34, bounce: 0.22)") && tokens.contains("static let page = Animation.spring(duration: 0.44, bounce: 0.16)"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
