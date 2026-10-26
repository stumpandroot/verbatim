import Foundation

// Thoughts and Journal by day (Verbatim/Model/DayPages.swift): which page a recording lands on, with the New page each
// day at setting and thoughts after midnight, the page order and each page's order, the dated titles, Copy's joined
// text, the month grid, the Thought pad's one-time move into Thoughts (PadMigration), and the iPhone's rules
// (VerbatimWidgets/ThoughtRules.swift: starting in place, the day arrows, and the words on the system surfaces). Not
// part of any app target; run mac/tools/test-thoughts.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!
cal.firstWeekday = 1   // Sunday, as in the US
let en = Locale(identifier: "en_US")
func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
func midnight(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.startOfDay(for: at(y, m, d)) }

// MARK: Which page

check("midnight: a thought at 10:42 is on its own day", DayPages.pageDay(for: at(2026, 10, 26, 10, 42), hour: 0, calendar: cal) == midnight(2026, 10, 26))
check("midnight: 12:05 AM starts the next page", DayPages.pageDay(for: at(2026, 10, 27, 0, 5), hour: 0, calendar: cal) == midnight(2026, 10, 27))
check("midnight: 11:59 PM stays on its day", DayPages.pageDay(for: at(2026, 10, 26, 23, 59), hour: 0, calendar: cal) == midnight(2026, 10, 26))
check("4 AM: a thought at 1:30 AM belongs to the page before", DayPages.pageDay(for: at(2026, 10, 27, 1, 30), hour: 4, calendar: cal) == midnight(2026, 10, 26))
check("4 AM: 3:59 AM is still the page before", DayPages.pageDay(for: at(2026, 10, 27, 3, 59), hour: 4, calendar: cal) == midnight(2026, 10, 26))
check("4 AM: 4:00 AM starts the new page", DayPages.pageDay(for: at(2026, 10, 27, 4, 0), hour: 4, calendar: cal) == midnight(2026, 10, 27))
check("4 AM: the page before the first of the month is the last of the month before", DayPages.pageDay(for: at(2026, 11, 1, 2), hour: 4, calendar: cal) == midnight(2026, 10, 31))
check("4 AM: the page before New Year's Day is New Year's Eve", DayPages.pageDay(for: at(2027, 1, 1, 0, 30), hour: 4, calendar: cal) == midnight(2026, 12, 31))
check("an hour out of range is clamped to 6 AM", DayPages.pageDay(for: at(2026, 10, 27, 5, 30), hour: 23, calendar: cal) == midnight(2026, 10, 26))
check("a negative hour is midnight", DayPages.pageDay(for: at(2026, 10, 27, 0, 30), hour: -3, calendar: cal) == midnight(2026, 10, 27))
// Daylight saving ends on Sunday, November 1, 2026 in New York (1 AM happens twice).
check("4 AM across the end of daylight saving: 1:30 AM is the page before", DayPages.pageDay(for: at(2026, 11, 1, 1, 30), hour: 4, calendar: cal) == midnight(2026, 10, 31))
check("today's page at 2 AM with a 3 AM boundary is yesterday", DayPages.today(now: at(2026, 10, 27, 2), hour: 3, calendar: cal) == midnight(2026, 10, 26))

// A thought belongs to the day it started: the page is chosen by when it started, never when it stopped.
let startedLate = at(2026, 10, 26, 23, 58)
let stoppedAfterMidnight = startedLate.addingTimeInterval(5 * 60)
check("a thought started at 11:58 PM and stopped after midnight stays on the day it started",
      DayPages.pageDay(for: startedLate, hour: 0, calendar: cal) == midnight(2026, 10, 26)
      && DayPages.pageDay(for: stoppedAfterMidnight, hour: 0, calendar: cal) == midnight(2026, 10, 27))

let interval = DayPages.pageInterval(midnight(2026, 10, 26), hour: 4, calendar: cal)
check("4 AM: the page runs from 4 AM to 4 AM the next day", interval.start == at(2026, 10, 26, 4, 0) && interval.end == at(2026, 10, 27, 4, 0))
check("the day before and after", DayPages.day(midnight(2026, 10, 26), moved: -1, calendar: cal) == midnight(2026, 10, 25)
      && DayPages.day(midnight(2026, 10, 31), moved: 1, calendar: cal) == midnight(2026, 11, 1))

// MARK: Grouping

struct T { var id: String; var date: Date }
let items = [
    T(id: "c", date: at(2026, 10, 26, 10, 42)),
    T(id: "a", date: at(2026, 10, 26, 9, 14)),
    T(id: "late", date: at(2026, 10, 27, 1, 10)),     // after midnight
    T(id: "b", date: at(2026, 10, 26, 9, 40)),
    T(id: "old", date: at(2026, 10, 24, 18, 0)),
    T(id: "b2", date: at(2026, 10, 26, 9, 40)),       // the same minute as b, added after it
]
let byMidnight = DayPages.group(items, date: \.date, hour: 0, calendar: cal)
check("midnight: pages newest first", byMidnight.map(\.day) == [midnight(2026, 10, 27), midnight(2026, 10, 26), midnight(2026, 10, 24)],
      "\(byMidnight.map(\.day))")
check("midnight: each page in time order, ties in the order they came",
      byMidnight.first { $0.day == midnight(2026, 10, 26) }?.items.map(\.id) == ["a", "b", "b2", "c"])
let byFour = DayPages.group(items, date: \.date, hour: 4, calendar: cal)
check("4 AM: the after-midnight thought joins the evening's page, last", byFour.map(\.day) == [midnight(2026, 10, 26), midnight(2026, 10, 24)]
      && byFour.first?.items.map(\.id) == ["a", "b", "b2", "c", "late"], "\(byFour.map { $0.items.map(\.id) })")
check("one page's items, in order", DayPages.items(items, on: midnight(2026, 10, 26), date: \.date, hour: 4, calendar: cal).map(\.id) == ["a", "b", "b2", "c", "late"])
check("a page with nothing on it is empty", DayPages.items(items, on: midnight(2026, 10, 25), date: \.date, hour: 0, calendar: cal).isEmpty)
check("no items, no pages", DayPages.group([T](), date: \.date, hour: 0, calendar: cal).isEmpty)

// MARK: Words

check("Copy joins with blank lines and leaves out empty thoughts",
      DayPages.joined(["  Move the export button.\n", "", "   ", "Pick up printer paper."]) == "Move the export button.\n\nPick up printer paper.")
check("the dated title", DayPages.title("Thoughts", day: midnight(2026, 10, 26), calendar: cal, locale: en) == "Thoughts · Mon, Oct 26",
      DayPages.title("Thoughts", day: midnight(2026, 10, 26), calendar: cal, locale: en))
check("Journal's title", DayPages.title("Journal", day: midnight(2026, 10, 24), calendar: cal, locale: en) == "Journal · Sat, Oct 24")
check("the day list's day", DayPages.listDay(midnight(2026, 10, 26), calendar: cal, locale: en) == "Mon 26")
check("the eyebrow's day", DayPages.eyebrowDay(midnight(2026, 10, 26), calendar: cal, locale: en) == "Mon Oct 26")
check("the month title", DayPages.monthTitle(midnight(2026, 10, 26), calendar: cal, locale: en) == "October 2026")
check("counts", DayPages.count(1, "thought", "thoughts") == "1 thought" && DayPages.count(6, "thought", "thoughts") == "6 thoughts")
check("hour labels", DayPages.hourLabel(0) == "Midnight" && DayPages.hourLabel(4) == "4 AM" && DayPages.hours == [0, 1, 2, 3, 4, 5, 6])

// MARK: Month grid

let october = DayPages.monthGrid(at(2026, 10, 15), calendar: cal)
check("October 2026: five whole weeks from Sunday", october.count == 35, "\(october.count)")
check("October 2026: starts on Sunday, September 27", october.first?.day == midnight(2026, 9, 27) && october.first?.inMonth == false)
check("October 2026: the 1st is a Thursday in the first week", october[4].day == midnight(2026, 10, 1) && october[4].inMonth)
check("October 2026: ends on Saturday the 31st", october.last?.day == midnight(2026, 10, 31) && october.last?.inMonth == true)
check("October 2026: 31 days in the month", october.filter(\.inMonth).count == 31)
var monday = cal; monday.firstWeekday = 2
let mondayGrid = DayPages.monthGrid(at(2026, 10, 15), calendar: monday)
check("a Monday-first calendar starts the grid on Monday, September 28", mondayGrid.first?.day == midnight(2026, 9, 28) && mondayGrid.count % 7 == 0)
check("weekday letters follow the first weekday", DayPages.weekdayLetters(calendar: cal).first == "S" && DayPages.weekdayLetters(calendar: monday).first == "M")
check("months move", DayPages.month(at(2026, 10, 26), moved: 1, calendar: cal) == midnight(2026, 11, 1)
      && DayPages.month(at(2026, 1, 10), moved: -1, calendar: cal) == midnight(2025, 12, 1))

// MARK: The Thought pad's move into Thoughts

let a = UUID(), b = UUID(), c = UUID()
// The pad's file as the pad wrote it: JSONEncoder's default dates (seconds since 2001).
let padJSON = """
{"title":"Catalog shoot email","pieces":[
 {"id":"\(a.uuidString)","text":"Shoot the wheels on white first.","seconds":14,"missed":false,"createdAt":\(at(2026, 10, 24, 9, 5).timeIntervalSinceReferenceDate)},
 {"id":"\(b.uuidString)","text":"   ","seconds":0,"missed":false,"createdAt":\(at(2026, 10, 24, 9, 6).timeIntervalSinceReferenceDate)},
 {"id":"\(c.uuidString)","text":"  The Lititz dealer wants a one-page sheet too.\\n","seconds":9,"missed":true,"createdAt":\(at(2026, 10, 26, 8, 1).timeIntervalSinceReferenceDate)}
]}
"""
let read = PadMigration.read(Data(padJSON.utf8))
check("the pad's file reads", read != nil)
check("the pad's title is kept", read?.title == "Catalog shoot email")
check("blank pieces are left out, the rest keep their order", read?.pieces.map(\.id) == [a, c])
check("each piece keeps its words, trimmed", read?.pieces.last?.text == "The Lititz dealer wants a one-page sheet too.")
check("each piece keeps when it was made, so it lands on that day",
      read.map { r in r.pieces.map { DayPages.pageDay(for: $0.createdAt, hour: 0, calendar: cal) } } == [midnight(2026, 10, 24), midnight(2026, 10, 26)])
check("a missed paste stays marked", read?.pieces.last?.missed == true && read?.pieces.last?.seconds == 9)
let minimal = PadMigration.read(Data(#"{"pieces":[{"text":"Only words"}]}"#.utf8))
check("a piece missing its other fields still reads", minimal?.pieces.count == 1 && minimal?.pieces.first?.text == "Only words" && minimal?.title == "")
check("an empty pad has nothing to move", PadMigration.read(Data(#"{"title":"","pieces":[]}"#.utf8))?.pieces.isEmpty == true)
check("a file that isn't the pad's isn't read", PadMigration.read(Data("not json".utf8)) == nil && PadMigration.read(Data(#"{"title":"x"}"#.utf8)) == nil)
let pieces = read?.pieces ?? []
check("once only: pieces already moved aren't moved again", PadMigration.pending(pieces, existing: [a]).map(\.id) == [c])
check("once only: a second run adds nothing", PadMigration.pending(pieces, existing: [a, c]).isEmpty)
let dup = pieces + pieces
check("once only: a piece listed twice moves once", PadMigration.pending(dup, existing: []).map(\.id) == [a, c])
check("the file is kept, renamed", PadMigration.doneName("thoughtpad.json") == "thoughtpad-migrated.json")

// MARK: The iPhone (VerbatimWidgets/ThoughtRules.swift)

// Starting a thought from outside the app: in place only when nothing needs asking and nothing holds the microphone.
func start(recording: Bool = false, setting: Bool = true, system: Bool = true, notice: Bool = true, mic: Bool = true, busy: Bool = false) -> ThoughtRules.Start {
    ThoughtRules.start(recordingThought: recording, inPlaceSetting: setting, systemAllows: system, noticeSeen: notice, micAllowed: mic, micBusy: busy)
}
check("in place when everything allows it", start() == .inPlace)
check("a second press stops the thought that's recording", start(recording: true) == .stop && start(recording: true, setting: false) == .stop)
check("Record without opening Verbose off opens Verbose", { if case .openVerbose = start(setting: false) { return true }; return false }())
check("iOS 17 opens Verbose", { if case .openVerbose = start(system: false) { return true }; return false }())
check("the recording notice not yet seen opens Verbose, which asks", { if case .openVerbose = start(notice: false) { return true }; return false }())
check("the microphone not yet allowed opens Verbose, which asks", { if case .openVerbose = start(mic: false) { return true }; return false }())
check("another recording holding the microphone opens Verbose, where it shows", { if case .openVerbose = start(busy: true) { return true }; return false }())
let td = UserDefaults(suiteName: "thoughts-tests-\(UUID().uuidString)")!
check("both switches are on unless turned off", ThoughtRules.inPlace(td) && ThoughtRules.islandWords(td))
td.set(false, forKey: ThoughtRules.inPlaceKey); td.set(false, forKey: ThoughtRules.islandWordsKey)
check("both switches remember off", !ThoughtRules.inPlace(td) && !ThoughtRules.islandWords(td))
check("the settings' keys are Thoughts'", ThoughtRules.inPlaceKey == "thoughts.inPlace" && ThoughtRules.islandWordsKey == "thoughts.islandWords")

// The day arrows: the nearest pages with something on them; Next is off on today, and today is always reachable.
let pagesWith = [midnight(2026, 10, 26), midnight(2026, 10, 24), midnight(2026, 10, 23), midnight(2026, 10, 19)]
let onToday = ThoughtRules.neighbors(pages: pagesWith, current: midnight(2026, 10, 26), today: midnight(2026, 10, 26), calendar: cal)
check("today: back goes to the last day with thoughts, skipping an empty one", onToday.previous == midnight(2026, 10, 24))
check("today: Next is off", onToday.next == nil)
let onSat = ThoughtRules.neighbors(pages: pagesWith, current: midnight(2026, 10, 24), today: midnight(2026, 10, 26), calendar: cal)
check("an earlier day: back and forward go to its neighbors", onSat.previous == midnight(2026, 10, 23) && onSat.next == midnight(2026, 10, 26))
let onFirst = ThoughtRules.neighbors(pages: pagesWith, current: midnight(2026, 10, 19), today: midnight(2026, 10, 26), calendar: cal)
check("the first day: back is off", onFirst.previous == nil && onFirst.next == midnight(2026, 10, 23))
let emptyToday = ThoughtRules.neighbors(pages: [midnight(2026, 10, 20)], current: midnight(2026, 10, 20), today: midnight(2026, 10, 26), calendar: cal)
check("forward reaches an empty today", emptyToday.next == midnight(2026, 10, 26))
let noPages = ThoughtRules.neighbors(pages: [], current: midnight(2026, 10, 26), today: midnight(2026, 10, 26), calendar: cal)
check("no thoughts at all: both arrows off", noPages.previous == nil && noPages.next == nil)
check("arrows take any time of day", ThoughtRules.neighbors(pages: [at(2026, 10, 24, 15)], current: at(2026, 10, 26, 9), today: at(2026, 10, 26, 18), calendar: cal).previous == midnight(2026, 10, 24))

// Words on the pages and system surfaces.
check("the eyebrow says today and the count", ThoughtRules.eyebrow(dayLabel: "Mon Oct 26", isToday: true, count: 6) == "Today · 6 thoughts")
check("the eyebrow on another day names it, one thought singular", ThoughtRules.eyebrow(dayLabel: "Sat Oct 24", isToday: false, count: 1) == "Sat Oct 24 · 1 thought")
check("the Live Activity names the page", ThoughtRules.intoLine(DayPages.title("Thoughts", day: midnight(2026, 10, 26), calendar: cal, locale: en)) == "Into Thoughts · Mon, Oct 26")
check("the Lock Screen widget shows a count, never words", ThoughtRules.lockCount(6) == "6 today" && ThoughtRules.lockCount(0) == "None yet today")
check("a thought that's transcribing says its audio is saved", ThoughtRules.transcribing == "Saved as audio. Transcribing…")
check("a failed thought keeps its audio and offers Transcribe again", ThoughtRules.failed.contains("audio is saved") && ThoughtRules.transcribeAgain == "Transcribe again")
check("Added to Thoughts shows for two seconds", ThoughtRules.savedTitle == "Added to Thoughts" && ThoughtRules.savedSeconds == 2)
check("ways in: widgets count", ThoughtRules.widgetStatus(0) == "Not added" && ThoughtRules.widgetStatus(2) == "2 added")
check("ways in: the control", ThoughtRules.controlStatus(true) == "Added" && ThoughtRules.controlStatus(false) == "Not added" && ThoughtRules.controlStatus(nil) == "Needs iOS 18")
check("ways in: what iOS can't tell offers setup, Siri is ready", ThoughtRules.undetectable == "Set up" && ThoughtRules.siriStatus == "Ready")
check("Siri's phrase", ThoughtRules.siriPhrase == "New thought in Verbose")
let allCopy = [ThoughtRules.transcribing, ThoughtRules.failed, ThoughtRules.emptyPage, ThoughtRules.emptyToday, ThoughtRules.activityTitle,
               ThoughtRules.lockTitle, ThoughtRules.savedTitle]
check("the copy is timeless and has no filler", allCopy.allSatisfy { c in ["currently", "soon", "latest", "just ", "simply", "easily"].allSatisfy { !c.lowercased().contains($0) } })

// The widgets and control the Settings page counts are the ones the extension declares.
let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let widgetSource = ((try? String(contentsOf: mac.appendingPathComponent("VerbatimWidgets/HomeWidgets.swift"), encoding: .utf8)) ?? "")
    + ((try? String(contentsOf: mac.appendingPathComponent("VerbatimWidgets/StartSessionWidgets.swift"), encoding: .utf8)) ?? "")
check("the widget sources were read", widgetSource.contains("TodayThoughtsWidget"))
check("every thought widget kind is a real widget's", ThoughtRules.widgetKinds.allSatisfy { widgetSource.contains("\"\($0)\"") })
check("the control's kind is the control's", widgetSource.contains("static let kind = ThoughtRules.controlKind"))

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
