import Foundation

// What the Home Screen and desktop widgets show (VerbatimWidgets/HomeWidgets.swift), written by the app
// (Verbatim/App/WidgetFeed.swift) to a small JSON file in the App Group container, and read by the widget extensions on
// iPhone and Mac. Privacy: titles (cut to `maxTitle` characters), dates, lengths, a label, and counts. No transcript
// text, no audio, no speakers, with two exceptions: Today's thoughts shows the day's last two thoughts, each cut to
// `maxTitle` characters (the widget marks them `privacySensitive()`, so a locked iPhone hides them; the Lock Screen's
// Thoughts widget shows only the count), and Recent dictations (iPhone) keeps the three newest dictations' words as
// pasted, each cut to `maxDictationText` characters, so its Copy button works without opening Verbose (also
// `privacySensitive()`). Pure Foundation, so the Linux tests compile it (mac/tools/test-widgets.sh).

struct WidgetSnapshot: Codable, Equatable {
    /// One recording or dictation in Recent recordings.
    struct Item: Codable, Equatable, Identifiable {
        /// Where it came from; picks the row's glyph and chip color.
        enum Source: String, Codable {
            case voice, link, file, app, dictation
        }
        var id: UUID
        /// Short: `WidgetSnapshot.shortTitle` cuts it to `maxTitle` characters on one line.
        var title: String
        var date: Date
        /// Seconds; 0 when unknown.
        var duration: Double
        var source: Source
        /// "Podcast", "Meeting", "Voice note", "Dictation".
        var label: String
    }

    /// Today's Thoughts page for the Today's thoughts and Lock Screen Thoughts widgets: when the page runs, how many thoughts it has, how
    /// many are still transcribing, and the last two (oldest first).
    struct TodayThoughts: Codable, Equatable {
        struct Line: Codable, Equatable, Identifiable {
            var id: UUID
            var date: Date
            /// Cut to `maxTitle` characters on one line; empty while it's transcribing.
            var text: String
        }
        var start: Date
        var end: Date
        var count: Int
        var transcribing: Int
        var latest: [Line]
    }

    /// A dictation for the Recent dictations widget (iPhone): its words as pasted, when, and whether the words are
    /// whole. Copy copies only whole words; a longer dictation's row opens it in Verbose instead.
    struct Dictation: Codable, Equatable, Identifiable {
        var id: UUID
        /// Trimmed, line breaks kept (Copy pastes them), at most `maxDictationText` characters.
        var text: String
        var date: Date
        /// False when `text` was cut to fit.
        var whole: Bool
    }

    /// This calendar week's dictated words, one count per day from the week's first day.
    struct Week: Codable, Equatable {
        var start: Date
        var end: Date
        var words: Int
        var days: [Int]
    }

    static let currentVersion = 1
    static let fileName = "widget-snapshot.json"
    /// Longest title the snapshot keeps.
    static let maxTitle = 60
    /// Rows the large widget shows; the medium one shows the first three.
    static let maxRecent = 5
    /// Dictations the Recent dictations widget keeps: the medium size shows three, the small one the newest.
    static let maxDictations = 3
    /// The most of a dictation's words the snapshot keeps. Longer ones are cut and marked not whole.
    static let maxDictationText = 280

    var version = WidgetSnapshot.currentVersion
    /// Newest first, at most `maxRecent`.
    var recent: [Item]
    /// Every recording and dictation in the library (not in Recently deleted).
    var kept: Int
    var week: Week
    /// Nil in files from older builds.
    var today: TodayThoughts? = nil
    /// The newest dictations, newest first, at most `maxDictations` (iPhone). Nil in files from older builds and on
    /// the Mac, whose widgets don't show them.
    var dictations: [Dictation]? = nil
    /// Every dictation kept (not in Recently deleted), for the widget's "12 kept". Nil where `dictations` is.
    var dictationCount: Int? = nil

    // MARK: Building

    /// A snapshot from the app's numbers. `items` in any order; `entries` are each dictation's date and words.
    static func make(items: [Item], kept: Int, entries: [(date: Date, words: Int)],
                     now: Date = Date(), calendar: Calendar = .current) -> WidgetSnapshot {
        let recent = items.sorted { $0.date > $1.date }.prefix(maxRecent).map { item -> Item in
            var i = item
            i.title = shortTitle(item.title)
            i.label = shortTitle(item.label, max: 24)
            i.duration = item.duration.isFinite ? max(0, item.duration) : 0
            return i
        }
        return WidgetSnapshot(recent: Array(recent), kept: max(0, kept),
                              week: week(entries: entries, now: now, calendar: calendar))
    }

    /// Today's page for the widget: the page's span, its count, how many are transcribing, and the last two thoughts.
    static func todayThoughts(start: Date, end: Date, thoughts: [(id: UUID, date: Date, text: String, transcribing: Bool)]) -> TodayThoughts {
        let inPage = thoughts.filter { $0.date >= start && $0.date < end }.sorted { $0.date < $1.date }
        let latest = inPage.suffix(2).map { t in
            TodayThoughts.Line(id: t.id, date: t.date, text: t.transcribing ? "" : (t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : shortTitle(t.text)))
        }
        return TodayThoughts(start: start, end: end, count: inPage.count, transcribing: inPage.filter(\.transcribing).count, latest: Array(latest))
    }

    /// The Recent dictations widget's rows from the app's dictations, in any order: the newest `maxDictations`, each
    /// one's words trimmed and cut to `maxDictationText` characters with an ellipsis (`whole` false). Dictations with
    /// no words (nothing heard, or one that didn't finish) are left out: there's nothing to copy.
    static func dictations(_ items: [(id: UUID, text: String, date: Date)]) -> [Dictation] {
        items.compactMap { item -> Dictation? in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard text.count > maxDictationText else { return Dictation(id: item.id, text: text, date: item.date, whole: true) }
            let cut = text.prefix(maxDictationText - 1).trimmingCharacters(in: .whitespacesAndNewlines)
            return Dictation(id: item.id, text: cut + "…", date: item.date, whole: false)
        }
        .sorted { $0.date > $1.date }
        .prefix(maxDictations)
        .map { $0 }
    }

    /// Today's thoughts as of `now`: the stored page while it lasts, nothing once the next page has started.
    func thoughts(at now: Date) -> TodayThoughts? {
        guard let t = today, now >= t.start, now < t.end else { return nil }
        return t
    }

    /// The calendar week holding `now`: total words and seven daily counts (the same week as Home's This week card).
    static func week(entries: [(date: Date, words: Int)], now: Date, calendar: Calendar = .current) -> Week {
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 86_400)
        var days: [Int] = []
        var starts: [Date] = []
        var d = calendar.startOfDay(for: interval.start)
        while d < interval.end, starts.count < 7 {
            starts.append(d)
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        days = Array(repeating: 0, count: starts.count)
        var total = 0
        for e in entries where e.date >= interval.start && e.date < interval.end && e.words > 0 {
            total += e.words
            let day = calendar.startOfDay(for: e.date)
            if let i = starts.lastIndex(where: { $0 <= day }) { days[i] += e.words }
        }
        return Week(start: interval.start, end: interval.end, words: total, days: days)
    }

    /// One line, trimmed, at most `max` characters with an ellipsis. "Untitled" when nothing is left.
    static func shortTitle(_ s: String, max: Int = maxTitle) -> String {
        let one = s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !one.isEmpty else { return "Untitled" }
        guard one.count > max else { return one }
        let cut = one.prefix(Swift.max(1, max - 1)).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    // MARK: Reading

    /// The week as of `now`: the stored one while it lasts, and an empty week once it's over (until the app writes).
    func week(at now: Date, calendar: Calendar = .current) -> Week {
        if now >= week.start && now < week.end { return week }
        let fresh = WidgetSnapshot.week(entries: [], now: now, calendar: calendar)
        return fresh
    }

    /// Today's place in `week.days`, or nil when today isn't in that week.
    static func todayIndex(in week: Week, now: Date, calendar: Calendar = .current) -> Int? {
        guard now >= week.start, now < week.end else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: week.start), to: calendar.startOfDay(for: now)).day ?? 0
        return (0..<week.days.count).contains(days) ? days : nil
    }

    // MARK: Encoding

    func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }

    /// Nil for a missing, damaged, or newer-format file (the widgets then show their empty state).
    static func decode(_ data: Data) -> WidgetSnapshot? {
        guard let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: data), s.version <= currentVersion else { return nil }
        return s
    }

    // MARK: Labels

    /// "Today", "Yesterday", the weekday within the last week, else "Oct 3".
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        f.setLocalizedDateFormatFromTemplate(age > 0 && age < 7 ? "EEEE" : "MMMd")
        return f.string(from: date)
    }

    /// How long ago a dictation was, for Home's Recent dictations and the widget: "Just now" under a minute, "2 min
    /// ago", "1 hr ago" the same day, "Yesterday", then "Oct 3".
    static func ago(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3_600)) hr ago" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    /// When the `ago` labels of these dates next change after `now`, soonest first, at most `limit`: each minute in a
    /// dictation's first hour, each hour after that until its day ends, and each midnight it turns Yesterday and then
    /// a date. A widget's timeline holds an entry at each, so "2 min ago" moves on without the app.
    static func agoChanges(_ dates: [Date], now: Date, calendar: Calendar = .current, limit: Int = 30) -> [Date] {
        var out = Set<Date>()
        for d in dates where d <= now {
            for m in 1...60 {
                let t = d.addingTimeInterval(Double(m) * 60)
                if t > now { out.insert(t) }
            }
            var t = d.addingTimeInterval(2 * 3_600)
            while calendar.isDate(t, inSameDayAs: d) {
                if t > now { out.insert(t) }
                t = t.addingTimeInterval(3_600)
            }
            let day = calendar.startOfDay(for: d)
            for n in 1...2 {
                if let t = calendar.date(byAdding: .day, value: n, to: day), t > now { out.insert(t) }
            }
        }
        return Array(out.sorted().prefix(max(0, limit)))
    }

    // MARK: Copied (the Recent dictations widget)

    /// The App Group key the widget's Copy writes: "<dictation id> <seconds since 1970>".
    static let copiedKey = "widget.dictations.copied"
    /// How long a copied row reads Copied.
    static let copiedFor: TimeInterval = 2

    static func copiedMarker(_ id: UUID, at date: Date) -> String { "\(id.uuidString) \(date.timeIntervalSince1970)" }

    /// The row that reads Copied as of `now`, and until when; nil when nothing was copied in the last `copiedFor`
    /// seconds (or the marker is damaged).
    static func copied(marker: String?, now: Date) -> (id: UUID, until: Date)? {
        guard let parts = marker?.split(separator: " "), parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let t = Double(parts[1]) else { return nil }
        let at = Date(timeIntervalSince1970: t)
        let until = at.addingTimeInterval(copiedFor)
        guard now >= at.addingTimeInterval(-1), now < until else { return nil }
        return (id, until)
    }

    /// "7:50", "1:04:12"; empty for no length.
    static func lengthLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "" }
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The verbatim:// links the widgets open. iPhone: a transcript (Recent recordings), today's Thoughts page, and the
/// Dictations list (Recent dictations). Mac: also
/// Record, Dictate, and New thought, which the iPhone widgets do with App Intents instead.
enum WidgetLink: Equatable {
    case transcript(UUID)
    case record
    case dictate
    /// Today's Thoughts page.
    case thought
    /// Starts a thought (the desktop widget's fallback when Verbose isn't running).
    case newThought
    /// The Dictations list (the Recent dictations widget's header and its small size; iPhone).
    case dictations
    /// The Library (the Recent recordings widget outside its rows, SF-25).
    case library
    /// This week's words: the You page on iPhone, Home on the Mac (the This week widget, SF-25).
    case week

    static let scheme = "verbatim"

    var url: URL {
        switch self {
        case .transcript(let id): return URL(string: "\(Self.scheme)://transcript/\(id.uuidString)")!
        case .record: return URL(string: "\(Self.scheme)://record?from=widget")!
        case .dictate: return URL(string: "\(Self.scheme)://dictate?from=widget")!
        case .thought: return URL(string: "\(Self.scheme)://thought?from=widget")!
        case .newThought: return URL(string: "\(Self.scheme)://newthought?from=widget")!
        case .dictations: return URL(string: "\(Self.scheme)://dictations?from=widget")!
        case .library: return URL(string: "\(Self.scheme)://library?from=widget")!
        case .week: return URL(string: "\(Self.scheme)://week?from=widget")!
        }
    }

    /// Record, Dictate, and New thought start the microphone, so on the Mac they carry Verbose's link key
    /// (`url(key:)`, `WidgetLinkKey`; security review MC-02, October 31, 2026).
    var startsCapture: Bool {
        switch self {
        case .record, .dictate, .newThought: return true
        case .transcript, .thought, .dictations, .library, .week: return false
        }
    }

    /// The link with Verbose's key (`k=`) on the ones that start the microphone; the others are unchanged.
    func url(key: String?) -> URL {
        guard startsCapture, let key, !key.isEmpty,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "k", value: key)]
        return c.url ?? url
    }

    /// The moment a transcript link opens at (`t=` seconds, as Verbose Tasks' Play sends it), if any.
    static func moment(in url: URL) -> Double? {
        guard let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value,
              let t = Double(v), t.isFinite, t >= 0 else { return nil }
        return t
    }

    /// The key a link carries (`k=`), if any.
    static func key(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "k" }?.value
    }

    /// The link a widget opened, or nil for anything else (`verbatim://session` stays the keyboard's).
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased() else { return nil }
        switch host {
        case "transcript":
            let parts = url.path.split(separator: "/")
            guard parts.count == 1, let id = UUID(uuidString: String(parts[0])) else { return nil }
            self = .transcript(id)
        case "record": self = .record
        case "dictate": self = .dictate
        case "thought": self = .thought
        case "newthought": self = .newThought
        case "dictations": self = .dictations
        case "library": self = .library
        case "week": self = .week
        default: return nil
        }
    }
}

#if canImport(Darwin)
/// Where the snapshot lives: the App Group container shared by the app and its widget extension. iPhone:
/// group.co.stumpandroot.verbatim.ios (`KeyboardBridge.appGroup`). Mac: the team-prefixed group named by the
/// `VerbatimAppGroup` Info.plist key, which both the app and the extension carry (mac/project.yml).
enum WidgetSnapshotStore {
    static var groupID: String? {
        #if os(iOS)
        return "group.co.stumpandroot.verbatim.ios"
        #else
        let id = Bundle.main.object(forInfoDictionaryKey: "VerbatimAppGroup") as? String
        return id.flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
        #endif
    }

    static var url: URL? {
        guard let groupID, let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        return dir.appendingPathComponent(WidgetSnapshot.fileName)
    }

    static func read() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return WidgetSnapshot.decode(data)
    }

    /// Writes `data` when it differs from the file. True when the file changed.
    @discardableResult
    static func write(_ data: Data) -> Bool {
        guard let url else { return false }
        if let old = try? Data(contentsOf: url), old == data { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: url, options: [.atomic]) } catch { return false }
        return true
    }
}

/// A random key that only Verbose and its widgets can read, in their App Group container (security review MC-02,
/// October 31, 2026). The desktop widgets' Record, Dictate, and New thought links carry it (`WidgetLink.url(key:)`), and
/// the widget's New thought writes a fresh request beside it before it asks the running app. Another app or a web page
/// can open verbatim://dictate or post the request, but without the key Verbose only comes forward; it never starts
/// the microphone.
enum WidgetLinkKey {
    static let keyFile = "link-key"
    static let requestFile = "thought-request"
    /// How long the widget's New thought request stays good.
    static let requestLifetime: TimeInterval = 10

    private static func file(_ name: String) -> URL? {
        guard let groupID = WidgetSnapshotStore.groupID,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        return dir.appendingPathComponent(name)
    }

    /// The key, or nil before Verbose has made it.
    static func current() -> String? {
        guard let url = file(keyFile), let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 32 ? key : nil
    }

    /// Makes the key once (Verbose at launch): 256 random bits as hex, from the system's secure generator.
    static func ensure() {
        guard current() == nil, let url = file(keyFile) else { return }
        var rng = SystemRandomNumberGenerator()
        let key = (0..<4).map { _ in String(format: "%016llx", rng.next() as UInt64) }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? key.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Whether a link's key is Verbose's own.
    static func matches(_ given: String?) -> Bool {
        guard let given, let key = current() else { return false }
        return given == key
    }

    /// The widget's New thought, just before it asks the running app.
    static func writeRequest(now: Date = Date()) {
        guard let url = file(requestFile) else { return }
        try? String(now.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
    }

    /// True once for a request the widget wrote in the last few seconds. The request is removed either way.
    static func takeRequest(now: Date = Date()) -> Bool {
        guard let url = file(requestFile) else { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let raw = try? String(contentsOf: url, encoding: .utf8), let t = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let age = now.timeIntervalSince1970 - t
        return age >= -1 && age <= requestLifetime
    }
}
#endif
