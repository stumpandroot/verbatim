import Foundation

// Pure rules behind the Native look on the Mac (DESIGN.md §13.2), Foundation only, so mac/tools/test-premium.sh runs
// them on Linux: the recordings' date line and the Library table's date cell, a row's meta line, speakers' shares and
// talk time, This week's bars, the Settings window's colored squares, the Library table's sort, and the toolbar's back
// and forward history.

// MARK: - Recordings

enum PremiumDateLine {
    /// "Today · 9:12 AM", "Yesterday · 6:20 PM", "Thu Oct 22 · 2:05 PM", or with the year when it isn't this year.
    static func line(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale; time.timeZone = calendar.timeZone
        time.dateStyle = .none; time.timeStyle = .short
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            day = "Yesterday"
        } else {
            let f = DateFormatter()
            f.locale = locale; f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "EEE MMM d" : "MMM d yyyy")
            day = f.string(from: date)
        }
        return "\(day) · \(time.string(from: date))"
    }
}

/// Who talked how much, for the transcript's Speakers box.
enum SpeakerShares {
    struct Share: Equatable { var id: String; var seconds: Double; var percent: Int }

    /// Talk time per speaker, most first (ties keep first-seen order), with whole percents that add up to 100
    /// (largest remainder). Speakers with no time are left out.
    static func compute(_ turns: [(speaker: String, seconds: Double)]) -> [Share] {
        var order: [String] = []
        var total: [String: Double] = [:]
        for t in turns where t.seconds > 0 {
            if total[t.speaker] == nil { order.append(t.speaker) }
            total[t.speaker, default: 0] += t.seconds
        }
        let sum = total.values.reduce(0, +)
        guard sum > 0 else { return [] }
        let ranked = order.enumerated().sorted { a, b in
            let x = total[a.element]!, y = total[b.element]!
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        let exact = ranked.map { total[$0]! / sum * 100 }
        var whole = exact.map { Int($0.rounded(.down)) }
        var left = 100 - whole.reduce(0, +)
        let byRemainder = exact.indices.sorted { (exact[$0] - Double(whole[$0])) > (exact[$1] - Double(whole[$1])) }
        for i in byRemainder where left > 0 { whole[i] += 1; left -= 1 }
        return ranked.indices.map { Share(id: ranked[$0], seconds: total[ranked[$0]]!, percent: whole[$0]) }
    }
}

/// This week's mini chart in the stat cell: one bar per day.
enum WeekBars {
    struct Bar: Equatable { var height: Double; var stub: Bool }

    /// Bars up to `maxHeight` tall by words, the busiest day full height. Days to come and days without words are
    /// short stubs (`stubHeight`); a day with any words is at least `minHeight`, so it never reads as empty.
    static func bars(words: [Int], future: [Bool], maxHeight: Double, minHeight: Double = 8, stubHeight: Double = 4) -> [Bar] {
        let peak = max(1, words.max() ?? 0)
        return words.indices.map { i in
            let isFuture = i < future.count && future[i]
            if isFuture || words[i] <= 0 { return Bar(height: stubHeight, stub: true) }
            return Bar(height: max(minHeight, maxHeight * Double(words[i]) / Double(peak)), stub: false)
        }
    }
}

// MARK: - Library table

/// The Library table's date column (mockup section 8): "Today, 9:00 AM", the weekday for the last week ("Mon, 4:10 PM"),
/// the month and day for this year ("Oct 12, 2:00 PM"), and the date with its year before that ("Oct 12, 2025").
enum NativeDateCell {
    static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale; time.timeZone = calendar.timeZone
        time.dateStyle = .none; time.timeStyle = .short
        func day(_ template: String) -> String {
            let f = DateFormatter()
            f.locale = locale; f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time.string(from: date))" }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < startOfToday {
            return "\(day("EEE")), \(time.string(from: date))"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return "\(day("MMM d")), \(time.string(from: date))" }
        return day("MMM d yyyy")
    }
}

/// A row's second line in Native's lists.
enum NativeRowMeta {
    /// Library: "Meeting · 38:12 · Anika, Marcus" (a text-only thought has no length; no people, no third part).
    static func library(kind: String, length: String?, people: String) -> String {
        ([kind, length ?? ""] + [people]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Home: "Meeting · Today, 9:00 AM".
    static func home(kind: String, when: String) -> String {
        [kind, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The Library table's columns and how each one sorts. Sorting by date keeps the day headers (Today, Yesterday);
/// any other column lists the recordings flat, as Finder does.
enum NativeTableSort: String, CaseIterable {
    case name, kind, people, date, length

    /// Each column's first click: dates and lengths newest and longest first, words A to Z.
    var startsDescending: Bool { self == .date || self == .length }

    /// The Library's sort (LibrarySort's raw value: newest, oldest, longest, title) for a column and direction, when
    /// there is one, so the List view and the table agree.
    static func librarySort(_ column: NativeTableSort, descending: Bool) -> String? {
        switch (column, descending) {
        case (.date, true): return "newest"
        case (.date, false): return "oldest"
        case (.length, true): return "longest"
        case (.name, false): return "title"
        default: return nil
        }
    }

    /// The column and direction a stored Library sort starts the table on.
    static func column(forLibrarySort raw: String) -> (NativeTableSort, Bool) {
        switch raw {
        case "oldest": return (.date, false)
        case "longest": return (.length, true)
        case "title": return (.name, false)
        default: return (.date, true)
        }
    }

    /// Whether the table shows day headers: only while it's sorted by date.
    var grouped: Bool { self == .date }

    /// Orders two rows by this column's values; ties keep the newest first.
    static func ordered(_ a: (name: String, kind: String, people: String, date: Date, length: Double),
                        _ b: (name: String, kind: String, people: String, date: Date, length: Double),
                        by column: NativeTableSort, descending: Bool) -> Bool {
        func cmp(_ x: String, _ y: String) -> ComparisonResult { x.localizedStandardCompare(y) }
        let r: ComparisonResult
        switch column {
        case .name: r = cmp(a.name, b.name)
        case .kind: r = cmp(a.kind, b.kind)
        case .people:
            // Rows with no people sort after the rest either way.
            if a.people.isEmpty != b.people.isEmpty { return !a.people.isEmpty }
            r = cmp(a.people, b.people)
        case .date: r = a.date == b.date ? .orderedSame : (a.date < b.date ? .orderedAscending : .orderedDescending)
        case .length: r = a.length == b.length ? .orderedSame : (a.length < b.length ? .orderedAscending : .orderedDescending)
        }
        if r == .orderedSame { return a.date > b.date }
        return descending ? r == .orderedDescending : r == .orderedAscending
    }
}

// MARK: - Settings

/// The Settings window's colored squares (mockup sections 6 and 10), in system colors by name, as System Settings
/// draws them: Apple's own meanings where one exists (blue for Personalization and Privacy, gray for the keyboard and
/// the account) and never red, which stays with recording.
enum NativeSettingsSquare {
    enum Tint: String, CaseIterable { case blue, orange, gray, indigo, purple, teal, cyan, green, pink, brown, mint, yellow }

    /// The square's color for a Settings pane, by `SettingsTab` raw value.
    static func tint(_ raw: String) -> Tint {
        switch raw {
        case "general": return .blue
        case "transcription": return .orange
        case "dictate": return .gray
        case "floatingButton": return .indigo
        case "actions": return .purple
        case "meetings": return .teal
        case "watched": return .blue
        case "storage": return .cyan
        case "privacy": return .blue
        case "account": return .gray
        case "about": return .green
        case "features": return .pink
        case "whatsNew": return .yellow
        default: return .gray
        }
    }
}

// MARK: - Toolbar

/// Back and forward through the screens you visited (both looks' Back and Forward, App/NavTrail.swift), like a
/// browser's history: going somewhere new starts a new trail from here (Forward clears), and Back and Forward walk it.
struct NavHistory<Element: Equatable> {
    private(set) var back: [Element] = []
    private(set) var forward: [Element] = []
    private(set) var current: Element?
    var limit = 50

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// You went somewhere new: the place you left goes on the back list and the forward list clears. Going to the
    /// place you're on changes nothing.
    mutating func visit(_ e: Element) {
        guard e != current else { return }
        if let c = current { back.append(c); if back.count > limit { back.removeFirst(back.count - limit) } }
        forward.removeAll()
        current = e
    }

    /// Where Back goes, without going.
    var previous: Element? { back.last }

    /// The place you're on changed in place (the Library showing another project): the trail keeps its shape.
    mutating func replaceCurrent(_ e: Element) {
        guard current != nil else { current = e; return }
        current = e
        if back.last == e { back.removeLast() }
    }

    /// Steps back: returns where to go, and keeps the place you left for Forward.
    mutating func goBack() -> Element? {
        guard let prev = back.popLast() else { return nil }
        if let c = current { forward.append(c) }
        current = prev
        return prev
    }

    /// Steps forward again after Back.
    mutating func goForward() -> Element? {
        guard let next = forward.popLast() else { return nil }
        if let c = current { back.append(c) }
        current = next
        return next
    }

    /// Drops every entry that no longer exists (a deleted transcript), so Back never lands on nothing.
    mutating func removeAll(where gone: (Element) -> Bool) {
        back.removeAll(where: gone)
        forward.removeAll(where: gone)
        // Two entries that met after a removal collapse into one.
        let b = back
        back = b.enumerated().filter { i, e in i == 0 || b[i - 1] != e }.map(\.element)
        if let c = current, back.last == c { back.removeLast() }
    }
}
