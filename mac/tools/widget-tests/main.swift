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
let atMoment = URL(string: "verbatim://transcript/\(id.uuidString)?t=258")!
check("Verbose Tasks' Play link opens the transcript at its moment", WidgetLink(url: atMoment) == .transcript(id) && WidgetLink.moment(in: atMoment) == 258
      && WidgetLink.moment(in: WidgetLink.transcript(id).url) == nil && WidgetLink.moment(in: URL(string: "verbatim://transcript/\(id.uuidString)?t=-4")!) == nil)
for l in [WidgetLink.record, .dictate, .thought, .newThought, .dictations, .library, .week] {
    check("\(l) round-trips", WidgetLink(url: l.url) == l)
}
// Capture links carry Verbose's link key on the Mac (security review MC-02).
check("Record, Dictate, and New thought start capture; the others don't",
      [WidgetLink.record, .dictate, .newThought].allSatisfy(\.startsCapture) && !WidgetLink.thought.startsCapture && !WidgetLink.transcript(id).startsCapture
      && !WidgetLink.dictations.startsCapture && !WidgetLink.library.startsCapture && !WidgetLink.week.startsCapture)
let homeWidgetsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../VerbatimWidgets/HomeWidgets.swift").standardizedFileURL
let homeWidgets = (try? String(contentsOf: homeWidgetsURL, encoding: .utf8)) ?? ""
check("Recent recordings and This week open their place outside a row (SF-25)",
      homeWidgets.contains(".widgetURL(WidgetLink.library.url)") && homeWidgets.contains(".widgetURL(WidgetLink.week.url)"), homeWidgetsURL.path)
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


// MARK: Recent dictations (iPhone)

let dIDs = (0..<5).map { _ in UUID() }
let dRows = WidgetSnapshot.dictations([
    (dIDs[0], "  Running ten minutes late, save me a seat.\n", now.addingTimeInterval(-120)),
    (dIDs[1], "Thanks for the draft.\nI'll read it tonight.", now.addingTimeInterval(-3_600)),
    (dIDs[2], "Can you pick up milk and coffee filters on the way home?", now.addingTimeInterval(-1_080)),
    (dIDs[3], "An older one that doesn't fit.", now.addingTimeInterval(-86_400)),
    (dIDs[4], "   ", now),
])
check("dictations: the newest three, newest first", dRows.map(\.id) == [dIDs[0], dIDs[2], dIDs[1]], "\(dRows.map(\.text))")
check("dictations: words trimmed, line breaks kept for Copy", dRows[0].text == "Running ten minutes late, save me a seat."
      && dRows[2].text == "Thanks for the draft.\nI'll read it tonight.")
check("dictations: one with no words is left out", !dRows.contains { $0.id == dIDs[4] })
check("dictations: short ones are whole", dRows.allSatisfy(\.whole))
let longWords = String(repeating: "word ", count: 100) + "private ending"
let longRow = WidgetSnapshot.dictations([(UUID(), longWords, now)])[0]
check("dictations: a long one is cut to the limit with an ellipsis", longRow.text.count <= WidgetSnapshot.maxDictationText && longRow.text.hasSuffix("…"))
check("dictations: and marked not whole, so Copy never copies part of it", !longRow.whole && !longRow.text.contains("private"))
let exact = String(repeating: "a", count: WidgetSnapshot.maxDictationText)
check("dictations: exactly at the limit stays whole", WidgetSnapshot.dictations([(UUID(), exact, now)]).first.map { $0.whole && $0.text == exact } == true)
check("dictations: the limits are three and 280", WidgetSnapshot.maxDictations == 3 && WidgetSnapshot.maxDictationText == 280)
var withDictations = WidgetSnapshot.make(items: [], kept: 3, entries: [], now: now, calendar: cal)
withDictations.dictations = dRows
withDictations.dictationCount = 12
let dRound = withDictations.encoded().flatMap(WidgetSnapshot.decode)
check("dictations: round-trip through the file", dRound == withDictations && dRound?.dictationCount == 12)
check("dictations: a file without them still decodes (older builds, the Mac)", WidgetSnapshot.decode(titled.encoded()!)?.dictations == nil)
if let obj = try? JSONSerialization.jsonObject(with: withDictations.encoded()!) as? [String: Any],
   let first = (obj["dictations"] as? [[String: Any]])?.first {
    check("dictations: a row holds only its ID, words, date, and whether they're whole", Set(first.keys) == ["date", "id", "text", "whole"], "\(first.keys.sorted())")
} else {
    check("dictations: stored as a list", false)
}

// How long ago, as Home's Recent dictations and the widget say it.
check("ago: under a minute is Just now", WidgetSnapshot.ago(now.addingTimeInterval(-20), now: now, calendar: cal) == "Just now")
check("ago: minutes", WidgetSnapshot.ago(now.addingTimeInterval(-120), now: now, calendar: cal) == "2 min ago"
      && WidgetSnapshot.ago(now.addingTimeInterval(-1_080), now: now, calendar: cal) == "18 min ago"
      && WidgetSnapshot.ago(now.addingTimeInterval(-3_599), now: now, calendar: cal) == "59 min ago")
check("ago: hours the same day", WidgetSnapshot.ago(now.addingTimeInterval(-3_600), now: now, calendar: cal) == "1 hr ago"
      && WidgetSnapshot.ago(now.addingTimeInterval(-3 * 3_600 - 59), now: now, calendar: cal) == "3 hr ago")
check("ago: yesterday", WidgetSnapshot.ago(day(2026, 10, 21, 23), now: now, calendar: cal) == "Yesterday")
check("ago: minutes win just after midnight", WidgetSnapshot.ago(day(2026, 10, 21, 23, 50), now: day(2026, 10, 22, 0, 10), calendar: cal) == "20 min ago")
check("ago: older is the date", WidgetSnapshot.ago(day(2026, 10, 3), now: now, calendar: cal, locale: Locale(identifier: "en_US")) == "Oct 3")
check("ago: a date to come reads Just now, never a negative count", WidgetSnapshot.ago(now.addingTimeInterval(30), now: now, calendar: cal) == "Just now")
let changes = WidgetSnapshot.agoChanges([now.addingTimeInterval(-120)], now: now, calendar: cal)
check("ago changes: next each minute while it's minutes", changes.prefix(3) == [now.addingTimeInterval(-120 + 180), now.addingTimeInterval(-120 + 240), now.addingTimeInterval(-120 + 300)],
      "\(changes.prefix(3))")
check("ago changes: soonest first, all after now, at most the limit", changes == changes.sorted() && changes.allSatisfy { $0 > now } && changes.count <= 30)
let hourOld = WidgetSnapshot.agoChanges([now.addingTimeInterval(-2.5 * 3_600)], now: now, calendar: cal)
check("ago changes: each hour once it's hours, then midnight", hourOld.first == now.addingTimeInterval(-2.5 * 3_600 + 3 * 3_600)
      && hourOld.contains(day(2026, 10, 23, 0, 0)) && hourOld.contains(day(2026, 10, 24, 0, 0)), "\(hourOld)")
check("ago changes: none for nothing", WidgetSnapshot.agoChanges([], now: now, calendar: cal).isEmpty)
check("ago changes: each label holds between changes", changes.isEmpty == false && zip([now] + changes, changes).allSatisfy { a, b in
    WidgetSnapshot.ago(now.addingTimeInterval(-120), now: a, calendar: cal) == WidgetSnapshot.ago(now.addingTimeInterval(-120), now: b.addingTimeInterval(-1), calendar: cal) })

// Copied: the row the widget's Copy just copied reads Copied for two seconds.
let copiedID = UUID()
let marker = WidgetSnapshot.copiedMarker(copiedID, at: now)
check("copied: right after, that row", WidgetSnapshot.copied(marker: marker, now: now.addingTimeInterval(0.5)).map { $0.id == copiedID && $0.until == now.addingTimeInterval(2) } == true)
check("copied: gone after two seconds", WidgetSnapshot.copied(marker: marker, now: now.addingTimeInterval(2)) == nil)
check("copied: nothing without a marker, or with a damaged one", WidgetSnapshot.copied(marker: nil, now: now) == nil
      && WidgetSnapshot.copied(marker: "nonsense", now: now) == nil && WidgetSnapshot.copied(marker: "\(copiedID.uuidString) soon", now: now) == nil)
check("copied: a marker from the future (a clock change) is ignored", WidgetSnapshot.copied(marker: marker, now: now.addingTimeInterval(-60)) == nil)

// MARK: The running recording's mirror (SF-16, SF-18)

do {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    let m = RecordingMirror.make(elapsed: 134, paused: false, thought: false, label: "Voice note", now: t)
    check("mirror: the timer's start is the write's time minus the seconds recorded", m.since == t.addingTimeInterval(-134) && m.pausedAt == nil && m.heartbeat == t)
    let p = RecordingMirror.make(elapsed: 134, paused: true, thought: false, label: "Voice note", now: t)
    check("mirror: paused, the timer holds at the write", p.pausedAt == t && p.since == t.addingTimeInterval(-134))
    check("mirror: a bad elapsed reads as 0", RecordingMirror.make(elapsed: .nan, paused: false, thought: false, label: "x", now: t).since == t
          && RecordingMirror.make(elapsed: -5, paused: false, thought: false, label: "x", now: t).since == t)
    check("mirror: live while the heartbeat is recent", m.live(at: t.addingTimeInterval(RecordingMirror.heartbeatEvery + 30)))
    check("mirror: stale once the app stops writing", !m.live(at: t.addingTimeInterval(RecordingMirror.staleAfter)))
    check("mirror: a heartbeat from the future (a clock change) isn't live", !m.live(at: t.addingTimeInterval(-120)))
    check("mirror: the heartbeat refresh comes well inside the stale window", RecordingMirror.heartbeatEvery * 2 < RecordingMirror.staleAfter)
    check("mirror: a running recording turns the Record switch on, not New thought's", RecordingMirror.recordingOn(m, now: t) && !RecordingMirror.thoughtOn(m, now: t))
    let th = RecordingMirror.make(elapsed: 12, paused: false, thought: true, label: "Thought", now: t)
    check("mirror: a thought turns New thought's switch on, not Record's", RecordingMirror.thoughtOn(th, now: t) && !RecordingMirror.recordingOn(th, now: t))
    check("mirror: nothing mirrored, or stale, reads as off", !RecordingMirror.recordingOn(nil) && !RecordingMirror.thoughtOn(nil)
          && !RecordingMirror.recordingOn(m, now: t.addingTimeInterval(3600)))
    check("mirror: round trip", RecordingMirror.decode(m.encoded() ?? Data()) == m && RecordingMirror.decode(p.encoded() ?? Data()) == p)
    check("mirror: no words travel, only times, a kind's name, and the thought flag",
          Set((try? JSONSerialization.jsonObject(with: m.encoded() ?? Data()) as? [String: Any])?.keys.map { $0 } ?? []) == ["since", "thought", "label", "heartbeat"])
    let later = RecordingMirror.make(elapsed: 194, paused: false, thought: false, label: "Voice note", now: t.addingTimeInterval(60))
    check("mirror: a heartbeat refresh shows the same thing (no reload)", later.sameShown(as: m))
    check("mirror: a pause, a kind change, or a thought shows something new", !p.sameShown(as: m)
          && !RecordingMirror.make(elapsed: 134, paused: false, thought: false, label: "Meeting", now: t).sameShown(as: m) && !th.sameShown(as: m) && !m.sameShown(as: nil))
    check("switch: acts only when asked for something other than what's running", RecordingMirror.switchActs(on: true, running: false)
          && RecordingMirror.switchActs(on: false, running: true) && !RecordingMirror.switchActs(on: true, running: true) && !RecordingMirror.switchActs(on: false, running: false))
    let d = UserDefaults(suiteName: "widget-tests-\(UUID().uuidString)")!
    RecordingMirror.write(m, to: d)
    check("mirror: written and read back from the App Group", RecordingMirror.read(d) == m)
    RecordingMirror.write(nil, to: d)
    check("mirror: cleared", RecordingMirror.read(d) == nil)
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
