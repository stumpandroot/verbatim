import Foundation

// The widgets' snapshot (VerbatimWidgets/WidgetSnapshot.swift): what the app writes for the Home Screen and desktop
// widgets, its encoding, the week's counts, and the links the widgets open. Not part of any app target; run
// mac/tools/test-widgets.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!
cal.firstWeekday = 1   // Sunday, as in the US
func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
let now = day(2026, 10, 22, 15)   // Thursday

func item(_ title: String, _ date: Date, _ duration: Double = 60, _ source: WidgetSnapshot.Item.Source = .voice, _ label: String = "Voice note") -> WidgetSnapshot.Item {
    WidgetSnapshot.Item(id: UUID(), title: title, date: date, duration: duration, source: source, label: label)
}

// MARK: Recent recordings

let items = (0..<8).map { item("Recording \($0)", now.addingTimeInterval(Double(-$0) * 3600)) }.shuffled()
let snap = WidgetSnapshot.make(items: items, kept: 46, entries: [], now: now, calendar: cal)
check("keeps at most five recent rows", snap.recent.count == WidgetSnapshot.maxRecent, "\(snap.recent.count)")
check("newest first", snap.recent.map(\.title) == (0..<5).map { "Recording \($0)" }, "\(snap.recent.map(\.title))")
check("kept count carried", snap.kept == 46)
check("a negative count reads as 0", WidgetSnapshot.make(items: [], kept: -3, entries: [], now: now, calendar: cal).kept == 0)
check("an infinite length reads as 0",
      WidgetSnapshot.make(items: [item("x", now, .infinity)], kept: 1, entries: [], now: now, calendar: cal).recent[0].duration == 0)

// MARK: Privacy: short titles, nothing else

let long = String(repeating: "word ", count: 80) + "secret ending"
let cut = WidgetSnapshot.shortTitle(long)
check("a long title is cut to maxTitle", cut.count <= WidgetSnapshot.maxTitle, "\(cut.count)")
check("a cut title ends with an ellipsis", cut.hasSuffix("…"))
check("the end of a long title never reaches the snapshot", !cut.contains("secret"))
check("a title is one line", WidgetSnapshot.shortTitle("First line\nSecond\tline") == "First line Second line")
check("spaces collapse", WidgetSnapshot.shortTitle("  Lots   of   space  ") == "Lots of space")
check("an empty title reads Untitled", WidgetSnapshot.shortTitle(" \n ") == "Untitled")
check("a short title stays as it is", WidgetSnapshot.shortTitle("App feature ideas") == "App feature ideas")
let titled = WidgetSnapshot.make(items: [item(long, now)], kept: 1, entries: [], now: now, calendar: cal)
check("make cuts titles too", titled.recent[0].title == cut)
let json = String(data: titled.encoded()!, encoding: .utf8)!
check("the file holds no long text", !json.contains("secret"))
let keys = Set(["date", "duration", "id", "label", "source", "title"])
if let obj = try? JSONSerialization.jsonObject(with: titled.encoded()!) as? [String: Any],
   let first = (obj["recent"] as? [[String: Any]])?.first {
    check("a row holds only title, date, length, label, source, and ID", Set(first.keys) == keys, "\(first.keys.sorted())")
    check("the snapshot's top-level fields", Set(obj.keys) == ["kept", "recent", "version", "week"], "\(obj.keys.sorted())")
} else {
    check("the snapshot is a JSON object", false)
}

// MARK: Encoding

let round = WidgetSnapshot.decode(snap.encoded()!)
check("encodes and decodes to the same snapshot", round == snap)
check("encoding is stable (sorted keys), so an unchanged snapshot isn't rewritten", snap.encoded() == round?.encoded())
check("damaged data decodes to nil", WidgetSnapshot.decode(Data("{".utf8)) == nil)
check("empty data decodes to nil", WidgetSnapshot.decode(Data()) == nil)
var newer = snap
newer.version = WidgetSnapshot.currentVersion + 1
check("a newer format decodes to nil", WidgetSnapshot.decode(newer.encoded()!) == nil)
check("the version is written", (try? JSONSerialization.jsonObject(with: snap.encoded()!) as? [String: Any])?["version"] as? Int == 1)

// MARK: This week

let entries: [(date: Date, words: Int)] = [
    (day(2026, 10, 18, 9), 100),    // Sunday: first day of the week
    (day(2026, 10, 20, 9), 250),    // Tuesday
    (day(2026, 10, 20, 20), 50),    // Tuesday evening
    (day(2026, 10, 22, 8), 400),    // Thursday (today)
    (day(2026, 10, 17, 23), 999),   // last Saturday: not this week
    (day(2026, 10, 25, 9), 777),    // next Sunday: not this week
    (day(2026, 10, 21, 9), -5),     // nonsense
]
let week = WidgetSnapshot.week(entries: entries, now: now, calendar: cal)
check("week total", week.words == 800, "\(week.words)")
check("seven days", week.days.count == 7)
check("words per day", week.days == [100, 0, 300, 0, 400, 0, 0], "\(week.days)")
check("week starts on Sunday", cal.isDate(week.start, inSameDayAs: day(2026, 10, 18)))
check("today's index", WidgetSnapshot.todayIndex(in: week, now: now, calendar: cal) == 4)
let later = day(2026, 10, 26, 9)
check("no today in a week that's over", WidgetSnapshot.todayIndex(in: week, now: later, calendar: cal) == nil)
let ws = WidgetSnapshot.make(items: [], kept: 0, entries: entries, now: now, calendar: cal)
check("the stored week shows while it lasts", ws.week(at: now, calendar: cal).words == 800)
check("a week that's over reads as 0 until the app writes", ws.week(at: later, calendar: cal).words == 0)
check("…with seven empty days", ws.week(at: later, calendar: cal).days == Array(repeating: 0, count: 7))

// MARK: Labels

check("today", WidgetSnapshot.dayLabel(day(2026, 10, 22, 9), now: now, calendar: cal) == "Today")
check("yesterday", WidgetSnapshot.dayLabel(day(2026, 10, 21, 23), now: now, calendar: cal) == "Yesterday")
let en = Locale(identifier: "en_US")
check("this week's weekday", WidgetSnapshot.dayLabel(day(2026, 10, 19), now: now, calendar: cal, locale: en) == "Monday",
      WidgetSnapshot.dayLabel(day(2026, 10, 19), now: now, calendar: cal, locale: en))
check("older: month and day", WidgetSnapshot.dayLabel(day(2026, 10, 3), now: now, calendar: cal, locale: en) == "Oct 3",
      WidgetSnapshot.dayLabel(day(2026, 10, 3), now: now, calendar: cal, locale: en))
check("length under an hour", WidgetSnapshot.lengthLabel(470) == "7:50")
check("length over an hour", WidgetSnapshot.lengthLabel(3852) == "1:04:12")
check("no length", WidgetSnapshot.lengthLabel(0) == "" && WidgetSnapshot.lengthLabel(.nan) == "")

// MARK: Links

let id = UUID()
check("transcript link round-trips", WidgetLink(url: WidgetLink.transcript(id).url) == .transcript(id))
for l in [WidgetLink.record, .dictate, .thought, .newThought] {
    check("\(l) round-trips", WidgetLink(url: l.url) == l)
}
// Capture links carry Verbose's link key on the Mac (security review MC-02).
check("Record, Dictate, and New thought start capture; the others don't",
      [WidgetLink.record, .dictate, .newThought].allSatisfy(\.startsCapture) && !WidgetLink.thought.startsCapture && !WidgetLink.transcript(id).startsCapture)
let keyed = WidgetLink.dictate.url(key: "abc123")
check("a capture link carries the key and still parses", WidgetLink(url: keyed) == .dictate && WidgetLink.key(in: keyed) == "abc123")
check("a link without a key has none", WidgetLink.key(in: WidgetLink.dictate.url) == nil && WidgetLink.key(in: WidgetLink.dictate.url(key: nil)) == nil)
check("a transcript link never carries the key", WidgetLink.transcript(id).url(key: "abc123") == WidgetLink.transcript(id).url)
check("the keyboard's session link isn't a widget link", WidgetLink(url: URL(string: "verbatim://session?start=1&from=widget")!) == nil)
check("another scheme isn't a widget link", WidgetLink(url: URL(string: "https://transcript/\(id.uuidString)")!) == nil)
check("a transcript link needs a real ID", WidgetLink(url: URL(string: "verbatim://transcript/../../etc")!) == nil)
check("a transcript link needs exactly one ID", WidgetLink(url: URL(string: "verbatim://transcript/\(id.uuidString)/more")!) == nil)
check("a transcript link without an ID", WidgetLink(url: URL(string: "verbatim://transcript")!) == nil)

// Today's thoughts (the Mac's medium widget).
let pageStart = day(2026, 10, 22, 0), pageEnd = day(2026, 10, 23, 0)
let t1 = UUID(), t2 = UUID(), t3 = UUID(), t4 = UUID()
let today = WidgetSnapshot.todayThoughts(start: pageStart, end: pageEnd, thoughts: [
    (t3, day(2026, 10, 22, 10, 42), "Day headers could use the mono date, like the website.", false),
    (t1, day(2026, 10, 22, 9, 14), "Move the export button into the toolbar.", false),
    (t4, day(2026, 10, 22, 11, 3), "", true),
    (t2, day(2026, 10, 21, 23, 0), "Yesterday's thought", false),
])
check("today's thoughts count only the page's", today.count == 3 && today.transcribing == 1)
check("today's thoughts keep the last two, oldest first", today.latest.map(\.id) == [t3, t4])
check("a transcribing thought has no words yet", today.latest.last?.text == "")
let longPage = WidgetSnapshot.todayThoughts(start: pageStart, end: pageEnd, thoughts: [(t1, day(2026, 10, 22, 9), String(repeating: "word ", count: 40), false)])
check("a long thought is cut to the title length", longPage.latest.first.map { $0.text.count <= WidgetSnapshot.maxTitle && $0.text.hasSuffix("…") } == true)
var withToday = WidgetSnapshot.make(items: [], kept: 0, entries: [], now: now, calendar: cal)
withToday.today = today
check("today's thoughts show while the page lasts", withToday.thoughts(at: day(2026, 10, 22, 15))?.count == 3)
check("and not once the next page has started", withToday.thoughts(at: day(2026, 10, 23, 1)) == nil)
check("a snapshot with today's thoughts round-trips", withToday.encoded().flatMap(WidgetSnapshot.decode) == withToday)
let older = #"{"version":1,"look":"verbose","recent":[],"kept":0,"week":{"start":0,"end":604800,"words":0,"days":[0,0,0,0,0,0,0]}}"#
check("a snapshot from an older build reads without today's thoughts", WidgetSnapshot.decode(Data(older.utf8)).map { $0.today == nil } == true)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
