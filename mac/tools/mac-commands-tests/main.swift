import Foundation

// The Mac's command and small-window rules (Verbatim/Model/MacCommandRules.swift), then the sources that use them.
// Reads the Swift sources from the mac/ folder given as the first argument. Not part of any app target; run
// mac/tools/test-mac-commands.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// MARK: Recent dictations

let K = RecallKeys.self
check("recall: plain digits type into search, empty or not (GPT-12)",
      K.action(keyCode: 18, mods: []) == nil && K.action(keyCode: 29, mods: []) == nil && K.action(keyCode: 83, mods: []) == nil)
check("recall: ⇧ and a digit types too (no paste without ⌘)", K.action(keyCode: 18, mods: [.shift]) == nil)
check("recall: ⌘ and a number copies that row, row and keypad", K.action(keyCode: 18, mods: [.command]) == .copy(0)
      && K.action(keyCode: 29, mods: [.command]) == .copy(9) && K.action(keyCode: 92, mods: [.command]) == .copy(8))
check("recall: ⇧⌘ and a number pastes it", K.action(keyCode: 19, mods: [.command, .shift]) == .paste(1))
check("recall: ⌥ or ⌃ with ⌘ and a number does nothing", K.action(keyCode: 18, mods: [.command, .option]) == nil
      && K.action(keyCode: 18, mods: [.command, .control]) == nil)
check("recall: arrows move, Return pastes the selection, Esc closes",
      K.action(keyCode: 125, mods: []) == .move(1) && K.action(keyCode: 126, mods: []) == .move(-1)
      && K.action(keyCode: 36, mods: []) == .pasteSelected && K.action(keyCode: 76, mods: [.shift]) == .pasteSelected
      && K.action(keyCode: 53, mods: []) == .close && K.action(keyCode: 125, mods: [.command]) == nil)
check("recall: letters go to the field", K.action(keyCode: 0, mods: []) == nil && K.action(keyCode: 0, mods: [.command]) == nil)
check("recall: key labels 1–9 then 0", K.keyLabel(0) == "1" && K.keyLabel(8) == "9" && K.keyLabel(9) == "0" && K.keyLabel(10) == nil)
check("recall: the footer names ⌘ and ⇧⌘", K.copyHint == "⌘ 1–0" && K.pasteHint == "⇧⌘ 1–0")

var gate = PointerGate(at: CGPoint(x: 400, y: 300))
let opened = gate.hover(at: CGPoint(x: 400, y: 300))
let scrolled = gate.hover(at: CGPoint(x: 400, y: 300))
let moved = gate.hover(at: CGPoint(x: 400, y: 340))
let movedAgain = gate.hover(at: CGPoint(x: 410, y: 340))
check("recall: a hover where the panel opened, or while it scrolls, keeps the selection (MAC-36)", !opened && !scrolled)
check("recall: a real move takes it", moved && movedAgain)
var fresh = PointerGate()
check("recall: with no start point, the first hover counts", fresh.hover(at: .zero))

// MARK: The Recording menu

var r = RecordingMenuState()
check("recording menu: off while nothing records", !r.canStop && !r.canPause && !r.canMark)
r.recording = true; r.starting = true
check("recording menu: while the mic starts, Stop cancels and Pause and Mark wait",
      r.canStop && r.stopTitle == "Cancel Recording" && !r.canPause && !r.canMark)
r.starting = false
check("recording menu: a voice note stops, pauses, and marks", r.canStop && r.stopTitle == "Stop and Transcribe" && r.canPause
      && r.pauseTitle == "Pause Recording" && r.canMark)
r.paused = true
check("recording menu: paused, it resumes", r.pauseTitle == "Resume Recording")
let capture = RecordingMenuState(capturing: true)
check("recording menu: an app capture stops and marks but doesn't pause", capture.canStop && !capture.canPause && capture.canMark)
let thought = RecordingMenuState(thought: true)
check("recording menu: a thought marks; ⌃⌥P stops it", !thought.canStop && thought.canMark)
check("recording menu: the toolbar's tooltip key", RecordingMenuState.stopKeys == "⌥⇧.")

// MARK: Find in the open transcript

let lines = ["The wagon folds flat.", "Fold it twice, then fold the handle.", "Nothing here.", "Façade and facade."]
let m = PageFind.matches(in: lines, query: "fold")
check("find: every match, in reading order, ignoring case", m.count == 3 && m.map(\.line) == [0, 1, 1]
      && m[1].range == NSRange(location: 0, length: 4) && m[2].range.location == 20, "\(m)")
check("find: accents don't matter", PageFind.matches(in: lines, query: "facade").count == 2)
check("find: an empty or blank query finds nothing", PageFind.matches(in: lines, query: "").isEmpty && PageFind.matches(in: lines, query: "  ").isEmpty)
check("find: one letter finds", PageFind.matches(in: ["a b a"], query: "a").count == 2)
check("find: ⌘G steps forward and wraps", PageFind.step(from: nil, count: 3, forward: true) == 0 && PageFind.step(from: 0, count: 3, forward: true) == 1
      && PageFind.step(from: 2, count: 3, forward: true) == 0)
check("find: ⇧⌘G steps back and wraps", PageFind.step(from: nil, count: 3, forward: false) == 2 && PageFind.step(from: 0, count: 3, forward: false) == 2
      && PageFind.step(from: 2, count: 3, forward: false) == 1)
check("find: nothing to step without matches", PageFind.step(from: 0, count: 0, forward: true) == nil)
check("find: the count reads 3 of 12, No matches, or nothing", PageFind.countLabel(current: 2, count: 12, query: "x") == "3 of 12"
      && PageFind.countLabel(current: nil, count: 0, query: "x") == "No matches" && PageFind.countLabel(current: nil, count: 0, query: " ") == "")

// MARK: The Library at small widths

func total(_ p: LibraryColumnPlan) -> CGFloat {
    let cols = [p.name, LibraryColumnPlan.kind, p.people, p.date, LibraryColumnPlan.length].compactMap { $0 }
    return cols.reduce(0, +) + CGFloat(cols.count - 1) * LibraryColumnPlan.gap + 2 * LibraryColumnPlan.inset
}
let wide = LibraryColumnPlan(width: 900)
check("library: a wide card shows all five columns and fills it", wide.showsPeople && wide.showsDate && abs(total(wide) - 900) < 1, "\(wide) \(total(wide))")
check("library: the shares keep Name the widest", wide.name > (wide.people ?? 0) && (wide.people ?? 0) > (wide.date ?? 0))
let mid = LibraryColumnPlan(width: 600)
check("library: narrower, People goes first", !mid.showsPeople && mid.showsDate && abs(total(mid) - 600) < 1, "\(mid) \(total(mid))")
let narrow = LibraryColumnPlan(width: 430)
check("library: narrower still, Date goes too; Name keeps its least width", !narrow.showsPeople && !narrow.showsDate
      && narrow.name >= LibraryColumnPlan.minName, "\(narrow)")
var last = (people: true, date: true)
var monotonic = true
for w in stride(from: 1200, through: 300, by: -10) {
    let p = LibraryColumnPlan(width: CGFloat(w))
    if p.showsPeople && !last.people { monotonic = false }
    if p.showsDate && !last.date { monotonic = false }
    if p.showsPeople && !p.showsDate { monotonic = false }
    if p.showsPeople && (p.people ?? 0) < LibraryColumnPlan.minPeople { monotonic = false }
    if p.showsDate && (p.date ?? 0) < LibraryColumnPlan.minDate { monotonic = false }
    if p.name < LibraryColumnPlan.minName { monotonic = false }
    last = (p.showsPeople, p.showsDate)
}
check("library: columns only drop as it narrows, People before Date, never under their least widths", monotonic)
check("library: Kind keeps a fixed width for its chip", LibraryColumnPlan.kind >= 100)

// MARK: The inspector

check("inspector: shows beside wide content", InspectorFit.shows(chosen: true, detailWidth: 1100, inspectorWidth: 300))
check("inspector: closes when the content would be under about 560 pt", !InspectorFit.shows(chosen: true, detailWidth: 840, inspectorWidth: 300)
      && InspectorFit.minContent == 560)
check("inspector: stays closed when you closed it", !InspectorFit.shows(chosen: false, detailWidth: 2000, inspectorWidth: 300))

// MARK: Sources

let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func read(_ path: String) -> String { (try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8)) ?? "" }
func codeLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
}
func sources(_ dir: String) -> [(String, String)] {
    var out: [(String, String)] = []
    let root = mac.appendingPathComponent(dir)
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
    for case let u as URL in e where u.pathExtension == "swift" {
        out.append((dir + "/" + u.path.dropFirst(root.path.count + 1), (try? String(contentsOf: u, encoding: .utf8)) ?? ""))
    }
    return out
}
let macFiles = sources("Verbatim")
check("sources: found the Mac app's Swift files", macFiles.count > 100, "\(macFiles.count)")

let app = read("Verbatim/App/VerbatimApp.swift"), commands = read("Verbatim/App/AppCommands.swift")
check("menus: a Recording menu and a Dictation menu", app.contains("CommandMenu(\"Recording\")") && app.contains("CommandMenu(\"Dictation\")"))
check("menus: Stop and Transcribe is ⌥⇧. on every screen, enabled by the recording, not the screen",
      commands.contains(".keyboardShortcut(\".\", modifiers: [.option, .shift])") && commands.contains(".disabled(!s.canStop)")
      && commands.contains("@ObservedObject var recorder: Recorder"))
check("menus: Home's card no longer owns ⌥⇧.", !codeLines(read("Verbatim/Views/HomeView.swift")).contains { $0.contains(".keyboardShortcut(\".\"") })
check("menus: New Thought ⌃⌥P and Recent Dictations follow the setting",
      commands.contains(".keyboardShortcut(\"p\", modifiers: [.control, .option])") && commands.contains("AppCommands.recallShortcut(recall)"))
check("menus: Bigger Text, Smaller Text, Mark This Moment, Copy Text, and Copy for AI are validated AppKit items",
      commands.contains("\"Bigger Text\", \"=\"") && commands.contains("\"Smaller Text\", \"-\"") && commands.contains("\"Mark This Moment\", \"b\"")
      && commands.contains("func validateMenuItem") && read("Verbatim/App/NavTrail.swift").contains("TranscriptMenuItems.shared.install(app)"))
check("menus: File says Record Voice Note (MAC-30)", app.contains("Button(\"Record Voice Note\")") && !app.contains("Voice Memo"))
check("find: ⌘F finds in the open transcript, ⌘G and ⇧⌘G step, ⌘K opens the panel",
      commands.contains("TranscriptFind.shared.show()") && commands.contains(".keyboardShortcut(\"g\", modifiers: .command)")
      && commands.contains(".keyboardShortcut(\"g\", modifiers: [.command, .shift])") && commands.contains(".keyboardShortcut(\"k\", modifiers: .command)"))
let transcriptView = read("Verbatim/Views/TranscriptView.swift")
check("find: the transcript shows the bar and marks its matches", transcriptView.contains("TranscriptFindBar(find: find)")
      && transcriptView.contains(".environment(\\.pageFindQuery, find.highlight)") && read("Verbatim/Views/SegmentLine.swift").contains("query: findQuery ?? app.search"))

// Hidden shortcut buttons: a zero-size Button("") with a shortcut is gone wherever a menu now carries it.
for p in ["Verbatim/Views/TranscriptView.swift", "Verbatim/Document/DocumentView.swift"] {
    let hidden = codeLines(read(p)).filter { $0.contains("Button(\"\")") && $0.contains("keyboardShortcut") }
    check("hidden buttons: none left in \(p)", hidden.isEmpty, "\(hidden)")
}

let doc = read("Verbatim/Document/DocumentView.swift")
check("undo: the Cleaned tab registers its history on the window's UndoManager (MAC-01)",
      doc.contains("@Environment(\\.undoManager) private var undoManager") && doc.contains("um.registerUndo(withTarget: store)")
      && doc.contains("$0.redoDocument(snapshot)"))
check("undo: nothing binds ⇧⌘Z to Undo, and the tooltip says ⌘Z", !doc.contains(".keyboardShortcut(\"z\"") && doc.contains("fix (⌘Z)") && !doc.contains("fix (⇧⌘Z)"))

let recall = read("Verbatim/Flow/Recall.swift")
check("recall: the panel uses RecallKeys and gates hover on a real move",
      recall.contains("RecallKeys.action(keyCode: keyCode, mods: mods)") && recall.contains("model.pointer.hover(at: NSEvent.mouseLocation)")
      && recall.contains("hint(RecallKeys.copyHint, \"Copy\")") && !recall.contains("queryEmpty"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
