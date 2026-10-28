import Foundation

// The Mac Native look's pure rules (PremiumRules.swift): no brand color in Native's files, the recordings' date line,
// the Library table's date cell, sort, and row meta, speakers' shares, This week's bars, the Settings window's colored
// squares, and back and forward. Not part of any app target; run mac/tools/test-premium.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// MARK: No brand color in Native's chrome (the Mac's Native files)

// The approved redesign (DESIGN.md §13.2) takes persimmon, glows, gradient cards, tinted circles, custom shadows, and
// SF Pro Rounded out of the Mac's Native look. The Views folder is the first argument.
let args = CommandLine.arguments
let views = args.count > 1 ? args[1] : ""
let nativeFiles = ["NativeChrome", "NativeSidebar",
                   "NativeSettings", "PremiumLook", "PremiumItems"]
let banned = ["nativeAccent", "persimmon", "Persimmon", "PremiumInk.accentSoft", "PremiumInk.onAccent", "PremiumInk.shadow",
              "gradientCard", "RadialGradient", "LinearGradient", ".shadow(", "design: .rounded", "glow"]
var read = 0
for name in nativeFiles {
    guard let text = try? String(contentsOfFile: "\(views)/\(name).swift", encoding: .utf8) else { continue }
    read += 1
    // Comments may name what went; code may not.
    let code = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let l = String(line)
        if let r = l.range(of: "//") { return String(l[..<r.lowerBound]) }
        return l
    }
    let hits = banned.flatMap { word in code.enumerated().filter { $0.element.contains(word) }.map { "\(name).swift:\($0.offset + 1) \(word)" } }
    check("\(name).swift draws no brand color, glow, gradient, or custom shadow", hits.isEmpty, hits.joined(separator: ", "))
}
check("the Native files were read (pass the Views folder)", read == nativeFiles.count, "read \(read) of \(nativeFiles.count)")
// NativeLook.swift draws both looks' thumbnails (Verbose's keeps its persimmon); its Native parts use the system accent.
if let look = try? String(contentsOfFile: "\(views)/NativeLook.swift", encoding: .utf8) {
    check("NativeLook.swift uses the system accent, not Ink.nativeAccent", !look.contains("Ink.nativeAccent") && look.contains("Color.accentColor"))
    check("Native switches and buttons take no tint of their own (the system accent)", look.contains("tint(look == .native ? nil"))
}

// MARK: Date line

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!
let posix = Locale(identifier: "en_US")
func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}
let now = date(2026, 10, 23, 16, 0)
func normalized(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
check("today's recording", normalized(PremiumDateLine.line(date(2026, 10, 23, 9, 12), now: now, calendar: cal, locale: posix)) == "Today · 9:12 AM",
      PremiumDateLine.line(date(2026, 10, 23, 9, 12), now: now, calendar: cal, locale: posix))
check("yesterday's recording", normalized(PremiumDateLine.line(date(2026, 10, 22, 18, 20), now: now, calendar: cal, locale: posix)) == "Yesterday · 6:20 PM")
let older = normalized(PremiumDateLine.line(date(2026, 10, 20, 14, 5), now: now, calendar: cal, locale: posix))
check("an older recording names the day", older.hasPrefix("Tue, Oct 20") || older.hasPrefix("Tue Oct 20"), older)
let lastYear = normalized(PremiumDateLine.line(date(2025, 3, 2, 8, 0), now: now, calendar: cal, locale: posix))
check("last year's recording has the year", lastYear.contains("2025") && lastYear.hasSuffix("8:00 AM"), lastYear)

// MARK: Speakers

let shares = SpeakerShares.compute([("Ginna", 40), ("Allie", 10), ("Ginna", 28), ("Allie", 22)])
check("speakers rank by talk time", shares.map(\.id) == ["Ginna", "Allie"])
check("68% and 32%", shares.map(\.percent) == [68, 32], "\(shares.map(\.percent))")
let thirds = SpeakerShares.compute([("A", 1), ("B", 1), ("C", 1)])
check("percents always add up to 100", thirds.map(\.percent).reduce(0, +) == 100, "\(thirds.map(\.percent))")
check("ties keep the order they first spoke in", thirds.map(\.id) == ["A", "B", "C"])
check("no talk time, no speakers", SpeakerShares.compute([("A", 0)]).isEmpty && SpeakerShares.compute([]).isEmpty)

// MARK: This week's bars

let bars = WeekBars.bars(words: [180, 60, 130, 320, 220, 0, 0], future: [false, false, false, false, false, true, true], maxHeight: 70)
check("the busiest day is full height", bars[3].height == 70 && !bars[3].stub)
check("bars scale by words", abs(bars[0].height - 70 * 180 / 320) < 0.001)
check("days to come are stubs", bars[5].stub && bars[6].stub && bars[5].height == 4)
let quiet = WeekBars.bars(words: [0, 1, 1000], future: [false, false, false], maxHeight: 70)
check("a day with any words is never a stub", !quiet[1].stub && quiet[1].height == 8)
check("a past day without words is a stub", quiet[0].stub)
check("an empty week is all stubs", WeekBars.bars(words: [0, 0, 0], future: [], maxHeight: 70).allSatisfy(\.stub))

// MARK: Library table

let today9 = normalized(NativeDateCell.text(date(2026, 10, 23, 9, 0), now: now, calendar: cal, locale: posix))
check("the table's date: today", today9 == "Today, 9:00 AM", today9)
let monday = normalized(NativeDateCell.text(date(2026, 10, 19, 16, 10), now: now, calendar: cal, locale: posix))
check("the table's date: this week names the weekday", monday == "Mon, 4:10 PM", monday)
let october = normalized(NativeDateCell.text(date(2026, 10, 2, 14, 0), now: now, calendar: cal, locale: posix))
check("the table's date: earlier this year has the month and day", october == "Oct 2, 2:00 PM", october)
let older2025 = normalized(NativeDateCell.text(date(2025, 3, 2, 8, 0), now: now, calendar: cal, locale: posix))
check("the table's date: another year has the year and no time", older2025.contains("2025") && !older2025.contains("AM"), older2025)
check("a row's meta: kind, length, and people", NativeRowMeta.library(kind: "Meeting", length: "38:12", people: "Anika, Marcus") == "Meeting · 38:12 · Anika, Marcus")
check("a row's meta: a text-only thought has no length", NativeRowMeta.library(kind: "Thought", length: nil, people: "") == "Thought")
check("Home's meta: kind and when", NativeRowMeta.home(kind: "Meeting", when: "Today, 9:00 AM") == "Meeting · Today, 9:00 AM")
typealias Cells = (name: String, kind: String, people: String, date: Date, length: Double)
let rows: [Cells] = [("Catalog call", "Meeting", "Anika", date(2026, 10, 23, 9, 0), 2292),
                     ("apple notes", "Thought", "", date(2026, 10, 22, 9, 0), 160),
                     ("Budget", "Journal", "Ben", date(2026, 10, 21, 9, 0), 372)]
func sorted(_ c: NativeTableSort, _ d: Bool) -> [String] { rows.sorted { NativeTableSort.ordered($0, $1, by: c, descending: d) }.map(\.name) }
check("sort by name, A to Z, ignoring case", sorted(.name, false) == ["apple notes", "Budget", "Catalog call"], "\(sorted(.name, false))")
check("sort by date, newest first", sorted(.date, true) == ["Catalog call", "apple notes", "Budget"])
check("sort by length, longest first", sorted(.length, true) == ["Catalog call", "Budget", "apple notes"])
check("rows with no people sort last either way", sorted(.people, false).last == "apple notes" && sorted(.people, true).last == "apple notes")
check("dates and lengths start newest and longest", NativeTableSort.date.startsDescending && NativeTableSort.length.startsDescending && !NativeTableSort.name.startsDescending)
check("only the date sort keeps day headers", NativeTableSort.allCases.filter(\.grouped) == [.date])
check("the table and the Library's sort agree", NativeTableSort.librarySort(.date, descending: true) == "newest" && NativeTableSort.librarySort(.name, descending: false) == "title"
      && NativeTableSort.librarySort(.kind, descending: false) == nil)
check("a stored sort starts the table on its column", NativeTableSort.column(forLibrarySort: "longest") == (.length, true) && NativeTableSort.column(forLibrarySort: "newest") == (.date, true))
check("the refined Library's sort menu says Newest first, as the mockup", NativeTableSort.date.title(descending: true) == "Newest first"
      && NativeTableSort.date.title(descending: false) == "Oldest first" && NativeTableSort.length.title(descending: false) == "Shortest first"
      && NativeTableSort.name.title(descending: false) == "Title A–Z")
check("every column and direction has its own sort title", Set(NativeTableSort.allCases.flatMap { [$0.title(descending: true), $0.title(descending: false)] }).count == 10)
check("the table's columns are the mockup's", NativeTableSort.allCases.map(\.header) == ["Name", "Kind", "People or source", "Date", "Length"])

// MARK: Settings squares

let panes = ["general", "transcription", "dictate", "floatingButton", "actions", "meetings", "watched", "storage", "privacy", "account", "about", "features", "whatsNew"]
check("Settings squares never use red", !NativeSettingsSquare.Tint.allCases.map(\.rawValue).contains("red"))
check("Settings squares follow the mockup", NativeSettingsSquare.tint("general") == .blue && NativeSettingsSquare.tint("transcription") == .orange
      && NativeSettingsSquare.tint("dictate") == .gray && NativeSettingsSquare.tint("privacy") == .blue && NativeSettingsSquare.tint("about") == .green)
check("every Settings pane has a square", panes.allSatisfy { NativeSettingsSquare.tint($0).rawValue.count > 0 })

// MARK: Back and forward

var h = NavHistory<String>()
h.visit("library"); h.visit("t1")
check("back goes where you were", h.canGoBack && h.goBack() == "library" && h.current == "library")
check("forward returns", h.canGoForward && h.goForward() == "t1" && !h.canGoForward)
_ = h.goBack(); h.visit("home")
check("a new place clears forward", !h.canGoForward && h.current == "home")
h.visit("home")
check("visiting where you are changes nothing", h.back == ["library"])
var g = NavHistory<String>()
for s in ["home", "t1", "library", "t1", "t2"] { g.visit(s) }
g.removeAll { $0 == "t1" }
check("a deleted transcript leaves the history", !g.back.contains("t1") && g.back == ["home", "library"], "\(g.back)")
var long = NavHistory<Int>(); long.limit = 3
for i in 0..<10 { long.visit(i) }
check("history keeps a limit", long.back == [6, 7, 8])
check("nothing to go back to", NavHistory<Int>().canGoBack == false && { var e = NavHistory<Int>(); return e.goBack() == nil }())
var r = NavHistory<String>()
r.replaceCurrent("library")
check("replacing with nothing there starts the trail", r.current == "library" && !r.canGoBack)
r.visit("t1"); _ = r.goBack(); r.replaceCurrent("library:A")
check("a place changed in place keeps Forward", r.current == "library:A" && r.canGoForward && r.previous == nil)
r.visit("home"); r.visit("library:B"); r.replaceCurrent("home")
check("a replacement that meets Back's last entry collapses", r.back == ["library:A"] && r.current == "home", "\(r.back)")
check("previous names where Back goes", r.previous == "library:A")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
