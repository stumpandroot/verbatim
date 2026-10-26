import Foundation

// What the Home Screen and desktop widgets show (VerbatimWidgets/HomeWidgets.swift), written by the app
// (Verbatim/App/WidgetFeed.swift) to a small JSON file in the App Group container, and read by the widget extensions on
// iPhone and Mac. Privacy: titles (cut to `maxTitle` characters), dates, lengths, a label, and counts. No transcript
// text, no audio, no speakers, with one exception on the Mac: Today's thoughts shows the day's last two thoughts, each
// cut to `maxTitle` characters (the widget marks them `privacySensitive()`). The iPhone never writes them. Pure Foundation, so the Linux tests compile it (mac/tools/test-widgets.sh).

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

    /// Today's Thoughts page for the Mac's Today's thoughts widget: when the page runs, how many thoughts it has, how
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

    var version = WidgetSnapshot.currentVersion
    /// The app's look (`AppLook.rawValue`): "verbose" or "native". iPhone widgets read the App Group's live value;
    /// the Mac's is only here, because the Mac app keeps its look in its own defaults.
    var look: String
    /// Newest first, at most `maxRecent`.
    var recent: [Item]
    /// Every recording and dictation in the library (not in Recently deleted).
    var kept: Int
    var week: Week
    /// Mac only; nil in files from older builds and on iPhone.
    var today: TodayThoughts? = nil

    // MARK: Building

    /// A snapshot from the app's numbers. `items` in any order; `entries` are each dictation's date and words.
    static func make(items: [Item], kept: Int, entries: [(date: Date, words: Int)], look: String,
                     now: Date = Date(), calendar: Calendar = .current) -> WidgetSnapshot {
        let recent = items.sorted { $0.date > $1.date }.prefix(maxRecent).map { item -> Item in
            var i = item
            i.title = shortTitle(item.title)
            i.label = shortTitle(item.label, max: 24)
            i.duration = item.duration.isFinite ? max(0, item.duration) : 0
            return i
        }
        return WidgetSnapshot(look: look, recent: Array(recent), kept: max(0, kept),
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

    /// "7:50", "1:04:12"; empty for no length.
    static func lengthLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "" }
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The verbatim:// links the widgets open. iPhone: a transcript (Recent recordings). Mac: also Record, Dictate, and
/// the Thought pad, which the iPhone widgets do with App Intents instead.
enum WidgetLink: Equatable {
    case transcript(UUID)
    case record
    case dictate
    /// Today's Thoughts page.
    case thought
    /// Starts a thought (the desktop widget's fallback when Verbose isn't running).
    case newThought

    static let scheme = "verbatim"

    var url: URL {
        switch self {
        case .transcript(let id): return URL(string: "\(Self.scheme)://transcript/\(id.uuidString)")!
        case .record: return URL(string: "\(Self.scheme)://record?from=widget")!
        case .dictate: return URL(string: "\(Self.scheme)://dictate?from=widget")!
        case .thought: return URL(string: "\(Self.scheme)://thought?from=widget")!
        case .newThought: return URL(string: "\(Self.scheme)://newthought?from=widget")!
        }
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
#endif
