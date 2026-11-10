import Foundation

// The Mac's command and small-window rules (Verbatim/App/MacCommandRules.swift), then the sources that use them.
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

check("find: the field names the tab it finds in", PageFind.prompt(.original) == "Find in transcript"
      && PageFind.prompt(.cleaned) == "Find in Cleaned" && PageFind.prompt(.summary) == "Find in Summary")
let sLines = PageFind.summaryLines(overview: "", keyPoints: ["Fold the wagon.", "Ship on Friday."])
check("find: Summary's lines keep the key points' numbers when there's no overview", sLines.count == 3 && sLines[0].isEmpty
      && PageFind.matches(in: sLines, query: "fold").map(\.line) == [1])
let cleaned = PageFind.matches(in: ["Speaker 1: fold it.\n\nSpeaker 2: Fold twice."], query: "fold")
check("find: Cleaned is one line, so a match's range is its place in the editor's text",
      cleaned.count == 2 && cleaned.allSatisfy { $0.line == 0 } && cleaned[0].range.location == 11 && cleaned[1].range.location == 32, "\(cleaned)")

// MARK: The Search or ask panel from the keyboard (MAC-35)

check("panel: plain ↓, ↑, and Esc are the panel's keys", PanelKeys.key(keyCode: 125, mods: []) == .down
      && PanelKeys.key(keyCode: 126, mods: []) == .up && PanelKeys.key(keyCode: 53, mods: []) == .close)
check("panel: ⇧, ⌘, or ⌥ with an arrow, and other keys, stay in the field", PanelKeys.key(keyCode: 125, mods: [.shift]) == nil
      && PanelKeys.key(keyCode: 126, mods: [.command]) == nil && PanelKeys.key(keyCode: 125, mods: [.option]) == nil
      && PanelKeys.key(keyCode: 36, mods: []) == nil && PanelKeys.key(keyCode: 48, mods: []) == nil && PanelKeys.key(keyCode: 0, mods: []) == nil)
check("panel: ↓ and ↑ move through the results", PanelKeys.step(from: 0, count: 4, down: true) == 1 && PanelKeys.step(from: 2, count: 4, down: false) == 1)
check("panel: the first and last results stay put at the ends", PanelKeys.step(from: 0, count: 4, down: false) == 0
      && PanelKeys.step(from: 3, count: 4, down: true) == 3)
check("panel: a cursor past the results comes back in range", PanelKeys.step(from: 9, count: 3, down: false) == 1
      && PanelKeys.step(from: -2, count: 3, down: true) == 1 && PanelKeys.step(from: 0, count: 0, down: true) == 0)
check("panel: Return opens the chosen result, the first before you move, nothing with none",
      PanelKeys.chosen(0, count: 3) == 0 && PanelKeys.chosen(2, count: 3) == 2 && PanelKeys.chosen(5, count: 3) == 2 && PanelKeys.chosen(0, count: 0) == nil)

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

// MARK: The side column

check("side column: Home's holds This week, Today's thoughts, and Journal (MAC-34)", MacSideColumn.homeSections == ["week", "thoughts", "journal"])
check("side column: Home splits on a wide window with This week shown",
      MacSideColumn.homeSplits(wide: true, editing: false, shown: ["record", "tiles", "recent", "week"]))
check("side column: with nothing for the side shown, Home takes the full width",
      !MacSideColumn.homeSplits(wide: true, editing: false, shown: ["record", "tiles", "recent"])
      && !MacSideColumn.homeSplits(wide: true, editing: false, shown: []))
check("side column: Today's thoughts or Journal alone still split Home",
      MacSideColumn.homeSplits(wide: true, editing: false, shown: ["record", "thoughts"]) && MacSideColumn.homeSplits(wide: true, editing: false, shown: ["journal"]))
check("side column: a narrow window and Edit Home keep one column",
      !MacSideColumn.homeSplits(wide: false, editing: false, shown: ["week"]) && !MacSideColumn.homeSplits(wide: true, editing: true, shown: ["week"]))
check("side column: the Library's shows only while the inspector is closed, in the whole Library, on a wide window",
      MacSideColumn.librarySplits(wide: true, inProject: false, inspectorVisible: false)
      && !MacSideColumn.librarySplits(wide: true, inProject: false, inspectorVisible: true)
      && !MacSideColumn.librarySplits(wide: true, inProject: true, inspectorVisible: false)
      && !MacSideColumn.librarySplits(wide: false, inProject: false, inspectorVisible: false))

// MARK: Visible focus

check("focus: the column with the keyboard marks its selection; the other dims (MAC-25)",
      SelectionLook.of(.library, focus: .library) == .focused && SelectionLook.of(.sidebar, focus: .library) == .dimmed
      && SelectionLook.of(.sidebar, focus: .sidebar) == .focused && SelectionLook.of(.library, focus: .sidebar) == .dimmed)
check("focus: with neither focused, the tint as always", SelectionLook.of(.library, focus: nil) == .tint && SelectionLook.of(.sidebar, focus: nil) == .tint)
check("focus: the bar is 2 pt", SelectionLook.barWidth == 2)

// MARK: Sources

let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func read(_ path: String) -> String { (try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8)) ?? "" }
func recallSource() -> String { read("Verbatim/Flow/Recall.swift") }
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
check("find: ⌘F finds in the open transcript's tab, ⌘G and ⇧⌘G step, ⌘K opens the panel",
      commands.contains("TranscriptFind.shared.show(in: scope)") && commands.contains("if let scope = nav.mode.findScope") && commands.contains(".keyboardShortcut(\"g\", modifiers: .command)")
      && commands.contains(".keyboardShortcut(\"g\", modifiers: [.command, .shift])") && commands.contains(".keyboardShortcut(\"k\", modifiers: .command)"))
let transcriptView = read("Verbatim/Views/TranscriptView.swift")
check("find: the transcript shows the bar and marks its matches", transcriptView.contains("TranscriptFindBar(find: find)")
      && transcriptView.contains(".environment(\\.pageFindQuery, find.highlight)") && read("Verbatim/Views/SegmentLine.swift").contains("query: findQuery ?? app.search"))

let findView = read("Verbatim/Views/TranscriptFind.swift"), summaryBlock = read("Verbatim/Views/SummaryBlock.swift")
check("find: Cleaned and Summary have the same bar; another tab keeps it, Review closes it (MAC-22 follow-up)",
      transcriptView.contains("if find.open, view.findScope == find.scope") && transcriptView.contains("find.retarget(scope)")
      && findView.contains("case .review, .result: return nil") && !transcriptView.contains("if m != .original { find.close() }"))
check("find: the Cleaned editor marks matches without touching its text, and scrolls to the current one",
      read("Verbatim/Document/DocumentView.swift").contains("lm.addTemporaryAttributes([.backgroundColor: fill, .foregroundColor: ink]")
      && read("Verbatim/Document/DocumentView.swift").contains("if let t { find.setTexts([t]) }")
      && read("Verbatim/Document/DocumentView.swift").contains("(tv as? LintTextView)?.reveal(c)"))
check("find: Summary marks matches in butter and underlines the current one",
      summaryBlock.contains("ReadingHighlight.marked(AttributedString(text), query: query, minLength: 1)")
      && summaryBlock.contains("underlineStyle = Text.LineStyle(") && transcriptView.contains("find.setTexts(lines)"))
let panelKeys = read("Verbatim/Views/SearchPanelKeys.swift"), askViews = read("Verbatim/Views/AskViews.swift"), contentView = read("Verbatim/Views/ContentView.swift")
check("panel: the keys act only while the panel shows Search and a search field is typed in (MAC-35)",
      panelKeys.contains("nav.mode == .search, !nav.order.isEmpty") && panelKeys.contains("Self.typingInToolbarSearch(w)")
      && panelKeys.contains("PanelKeys.key(keyCode:") && contentView.contains("SearchPanelKeys.shared.install(app)"))
check("panel: the toolbar's field opens the panel instead of filtering the Library (MAC-35)",
      contentView.contains(".searchable(text: Bindable(app).toolbarQuery") && contentView.contains("AskNav.shared.toolbarChanged(v)")
      && contentView.contains("AskNav.shared.submit(app, fromToolbar: true)") && !contentView.contains(".searchable(text: Bindable(app).search"))
check("panel: Search lists recordings and passages and never writes the Library's search while you type",
      askViews.contains("SearchPanelResults.find(") && !askViews.contains("if nav.mode == .search { app.search = q }")
      && askViews.contains("PanelKeys.chosen(cursor, count: order.count)"))
check("panel: Search's results are kept per query and scope until the library changes, so ↓ and ↑ never search again",
      askViews.contains("app.store.memo(SearchPanelResults.memoKey(q, scope: scope.raw")
      && !askViews.contains("let results = SearchPanelResults.find("))
check("panel: the Ask page shows the same panel inline, with Ask chosen", askViews.contains("AskPanel(inline: true)")
      && askViews.contains("nav.mode = .ask") && !askViews.contains("ask-screen-field"))

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

let sidebar = read("Verbatim/Views/MacSidebar.swift"), library = read("Verbatim/Views/LibraryView.swift")
check("focus: the sidebar and the table keep the blue ring off and draw the bar instead",
      sidebar.contains(".focusEffectDisabled()") && sidebar.contains("columns.set(.sidebar, on)") && sidebar.contains("FocusBar()")
      && library.contains(".focusEffectDisabled()") && library.contains("columns.set(.library, on)") && library.contains("FocusBar()"))
check("keyboard: calendar days and arrows, the pad's arrows and mic take focus and Space (GPT-14)",
      read("Verbatim/Views/ByDayView.swift").components(separatedBy: ".keyActivation").count == 3
      && read("Verbatim/Flow/ThoughtPad.swift").components(separatedBy: ".keyActivation").count >= 3
      && read("Verbatim/Views/Controls.swift").contains(".focusable(enabled, interactions: .activate)"))
check("keyboard: a search result in the panel is a Button (MAC-23, MAC-35)", askViews.contains("struct SearchPanelRow") && askViews.contains("Button(action: open)"))
check("panel: the Library's inline passages are gone", !library.contains("PassageResults") && !library.contains("passageCursor")
      && !FileManager.default.fileExists(atPath: mac.appendingPathComponent("Verbatim/Views/PassageKeys.swift").path))

// Small windows (group 5).
check("small: the Cleaned toolbar fits a row, two rows, or More (MAC-04)",
      doc.contains("ViewThatFits(in: .horizontal)") && doc.contains("RefinedMenuLabel(title: \"More\")"))
check("small: the Library's columns follow LibraryColumnPlan and the kind chip never truncates (MAC-05)",
      library.contains("LibraryColumnPlan(width: width)") && library.contains("columns.shows(.people)")
      && read("Verbatim/Views/RefinedKit.swift").contains("Text(title).refinedFont(.chip, weight: .semibold).lineLimit(1)\n            .fixedSize()"))
let chrome = read("Verbatim/Views/MacChrome.swift")
check("small: the inspector closes on its own without room, and its button can still show it (MAC-05)",
      chrome.contains("InspectorFit.shows(chosen: true, detailWidth: detailWidth") && chrome.contains("Binding(get: { nav.inspectorVisible && app.screen.hasInspector }")
      && chrome.contains("Button { nav.toggleInspector() }"))
check("small: Thoughts times are one line at the widest time's width (MAC-06)",
      read("Verbatim/Flow/ThoughtPad.swift").contains("struct ThoughtTime") && !read("Verbatim/Flow/ThoughtPad.swift").contains(".frame(width: 42, alignment: .leading)"))
let bubble = read("Verbatim/Flow/ThoughtBubble.swift")
check("small: the bubble's card fits its content with one stop phrasing (MAC-16)",
      bubble.contains("static let stopHint = \"Click the disc to stop\"") && !bubble.contains(".frame(width: 278)") && !bubble.contains("Text(\"Click to stop"))
check("small: Mac chips wrap (MAC-19)", read("Verbatim/Views/RefinedKit.swift").contains("FlowRow(spacing: 8, lineSpacing: 8) { content }"))
check("small: Edit Home's tags sit above the outline and Choose tiles keeps its name (MAC-28)",
      read("Verbatim/Views/HomeSectionsMac.swift").contains("if editing { badge.padding(.leading, 8)") && read("Verbatim/Views/EditHome.swift").contains(".fixedSize()"))
check("small: stacked By day keeps the heading and writing first, with a day stepper (MAC-29)",
      !read("Verbatim/Views/ByDayView.swift").contains("sideFirstWhenStacked: true") && read("Verbatim/Views/ByDayView.swift").contains("ByDayStepper(days:"))
let card = read("Verbatim/Views/LinkAddedCard.swift")
check("motion: the link card counts at once and shows at once from ⌘V (MAC-17, MAC-10)",
      card.contains("autoFinish?.cancel(); autoFinish = nil\n        onLanded()") && card.contains("limitMotion || fromKeyboard ? 1 : 0.94"))
check("motion: Search or ask shows at once (MAC-09)", read("Verbatim/Views/AskViews.swift").contains(".animation(.easeOut(duration: KeyMotion.recallFade), value: nav.panelOpen)"))

// Same action, same result (group 6).
check("kinds: the transcript's chip shows refinedKind, as the Library does (MAC-12)",
      transcriptView.contains("KindPickerChip(kind: t.kind, shown: t.refinedKind") && read("Verbatim/Views/MacAudioDetail.swift").contains("shown: t.refinedKind ?? .audio"))
let trash = read("Verbatim/Views/TrashView.swift")
check("danger: Delete now and Empty are danger, never persimmon or the strong button (MAC-15)",
      trash.contains("Text(\"Delete now\")") && trash.contains("foregroundStyle(Refined.danger)") && !trash.contains("Refined.accentText")
      && !trash.contains("RefinedActionStyle(kind: .strong)"))
check("copy: Deleted just now, never in 0 seconds (MAC-38)", trash.contains("\"just now\"") && trash.contains("min(d, now)"))
check("copy: no em dashes in voice setup (MAC-38)", !read("Verbatim/Views/VoiceEnrollment.swift").contains("static let greatLine = \"Great —"))
check("copy: Voice note in onboarding, Settings, and the shortcut, with the old phrase kept for Siri (MAC-30)",
      read("Verbatim/Views/OnboardingView.swift").contains("A voice note or a call") && read("Verbatim/Views/SettingsKit.swift").contains("In voice notes")
      && read("Verbatim/App/VerbatimIntents.swift").contains("Record a voice note with") && read("Verbatim/App/VerbatimIntents.swift").contains("Record a voice memo with"))
let escaped = macFiles.flatMap { f in codeLines(f.1).filter { $0.contains("(text: \"esc\"") }.map { "\(f.0): \($0)" } }
check("copy: Esc keycaps everywhere (MAC-41)", escaped.isEmpty, "\(escaped)")
check("labels: the kind picker starts with its word; the type-apps remove button has a name (MAC-39)",
      read("Verbatim/Views/RefinedKit.swift").contains(".accessibilityLabel(RecordingKind.refinedName(shown ?? kind))")
      && read("Verbatim/Flow/Paster.swift").contains(".accessibilityLabel(\"Remove \\(Self.name(for: id))\")"))
check("glyphs: no SF person or play on the toolbar or inspector (MAC-40)",
      !chrome.contains("person.crop.circle") && !library.contains("systemImage: \"play.fill\""))

// The polish round (November 7, 2026).
check("selection: one card in the inspector and the side column, kit type and the kit's play glyph (MAC-18)",
      library.components(separatedBy: "LibrarySelectionCard(transcript:").count == 3 && !library.contains(".borderedProminent")
      && !library.contains("Button(\"Open Transcript\")") && library.contains("if !nav.inspectorVisible") && !library.contains(".foregroundStyle(.secondary)"))
let kit = read("Verbatim/Views/RefinedKit.swift"), home = read("Verbatim/Views/HomeView.swift"), homeMac = read("Verbatim/Views/HomeSectionsMac.swift")
check("hover: Home's cards and tiles show the pointer, and Recent rows are PaperRowButtons (MAC-20)",
      kit.contains("case fill(radius: CGFloat)") && kit.contains(".fill(Refined.hoverWash)") && home.contains("PaperRowButton(action: { app.go(.transcript(t.id)) })")
      && !home.contains(".buttonStyle(RefinedPress())") && !homeMac.contains(".buttonStyle(RefinedPress())"))
let brand = read("Verbatim/Views/Brand.swift")
check("data: the Ribbon's timer, Recall's times and keys, and the panels' keycaps are 12 pt or larger (MAC-26)",
      read("Verbatim/Flow/FlowBarView.swift").contains("Text(elapsed).font(SurfaceFont.mono(12))") && brand.contains("self.size = max(Self.minSize, size)")
      && !recallSource().contains("size: 11)") && !recallSource().contains("mono(10.5") && !read("Verbatim/Flow/FlowMenu.swift").contains("Keycap(keys: keys, size: 10.5)"))
check("bubble: the disc has a hairline, no ink outline or offset shadow (MAC-27)",
      !bubble.contains(".offset(x: 3, y: 4)") && bubble.contains("Circle().strokeBorder(Refined.separator, lineWidth: 1)"))
let keycapDrawings = macFiles.filter { f in ["struct DarkKeycap", "struct BubbleKeycap"].contains { f.1.contains($0) } }.map(\.0)
check("keycaps: one Keycap with outline, raised, and on-black styles, used for every shortcut (MAC-32)",
      keycapDrawings.isEmpty && brand.contains("enum Style { case outline, raised, onBlack }")
      && read("Verbatim/Views/DictationSurfaceSettings.swift").contains("Keycap(keys: text, size: big ? 15 : 12.5")
      && read("Verbatim/Views/OnboardingView.swift").contains("Keycap(keys: keys).foregroundStyle(ink)")
      && kit.contains("if mac, case .shortcut(let k) = t {") && home.contains("keys: \"⌥⇧R\""), "\(keycapDrawings)")
check("captions: the panel's size is its own, clamped to its text size and the screen (MAC-42)",
      read("Verbatim/Views/LiveCaptionsPanel.swift").contains("host.sizingOptions = []") && read("Verbatim/Views/LiveCaptionsPanel.swift").contains("Self.keepOnScreen(panel)"))
check("onboarding: every step scrolls above a footer that stays (GPT-28)",
      read("Verbatim/Views/OnboardingView.swift").contains("ScrollView(.vertical) {") && read("Verbatim/Views/OnboardingView.swift").contains(".scrollBounceBehavior(.basedOnSize)"))
let serifLiterals = macFiles.filter { !$0.0.hasSuffix("Tokens.swift") && !$0.0.hasSuffix("MacAppearance.swift") }
    .flatMap { f in codeLines(f.1).filter { $0.contains("design: .serif)") }.map { _ in f.0 } }
check("tokens: the serif goes through Refined.serif outside the two shared kit files (MAC-31)",
      Set(serifLiterals).isSubset(of: ["Verbatim/Views/RefinedPlayback.swift", "Verbatim/Views/Celebration.swift"]), "\(serifLiterals)")
check("tokens: the sidebar's reorder and the Settings flash use Motion tokens (MAC-31)",
      !read("Verbatim/Views/MacSidebar.swift").contains(".smooth(duration: 0.3)") && read("Verbatim/Views/SettingsKit.swift").contains(".animation(Motion.flash"))

let recall = read("Verbatim/Flow/Recall.swift")
check("recall: the panel uses RecallKeys and gates hover on a real move",
      recall.contains("RecallKeys.action(keyCode: keyCode, mods: mods)") && recall.contains("model.pointer.hover(at: NSEvent.mouseLocation)")
      && recall.contains("hint(RecallKeys.copyHint, \"Copy\")") && !recall.contains("queryEmpty"))

// The decisions round (Tim, November 8, 2026).
let columnsSource = read("Verbatim/Views/MacColumns.swift")
let trackedLabels = macFiles.flatMap { f in codeLines(f.1).filter { $0.contains("Text(") && $0.contains(".uppercased()") && ($0.contains(".tracking(") || $0.contains(".kerning(")) }.map { "\(f.0): \($0)" } }
check("labels: side cards and the line over a page's title are the meta style in sentence case, no uppercase or tracking (MAC-13)",
      columnsSource.contains("Text(title).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)") && !columnsSource.contains(".uppercased()")
      && kit.contains("Text(line).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)") && !kit.contains("line.uppercased()")
      && trackedLabels.isEmpty, "\(trackedLabels)")

check("side column: no Dictations card on Home and no Collections card in the Library; Selected and Ask's cards stay (MAC-34)",
      !home.contains("HomeSideDictations") && !home.contains("MacSideCard(") && home.contains("MacSideColumn.homeSplits(")
      && !library.contains("MacSideCard(title: \"Collections\")") && !library.contains("sideLink(") && library.contains("MacSideColumn.librarySplits(")
      && library.contains("MacSideCard(title: \"Selected\")") && askViews.contains("MacSideCard(title: \"Recent questions\")"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
