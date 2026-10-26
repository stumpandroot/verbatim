import Foundation

// Thoughts and Journal, one page a day (approved mockup "Thoughts", October 26, 2026). A page isn't stored: it's every
// recording of the kind that started that day, in time order. A day starts at the hour set in Settings › Features ›
// Thoughts › New page each day at (Midnight by default), so a thought at 1:30 AM with a 4 AM boundary belongs to the
// page before. A thought belongs to the day it started, however long it ran. Pure Foundation, so the Linux tests
// compile it (mac/tools/test-thoughts.sh).

enum DayPages {
    /// Settings › Features › Thoughts › New page each day at: the hour (0 is midnight) a new page starts.
    static let newPageHourKey = "thoughts.newPageHour"
    /// The hours offered: Midnight to 6 AM.
    static let hours = Array(0...6)

    /// "Midnight", "1 AM", … "6 AM".
    static func hourLabel(_ h: Int) -> String { h == 0 ? "Midnight" : "\(h) AM" }

    /// The saved hour, clamped to what's offered.
    static func storedHour(_ d: UserDefaults = .standard) -> Int { clampHour(d.integer(forKey: newPageHourKey)) }

    static func clampHour(_ h: Int) -> Int { min(max(h, hours.first ?? 0), hours.last ?? 0) }

    /// The page `date` belongs to, as the start of that calendar day (midnight). Earlier than `hour` in the morning
    /// means the page before.
    static func pageDay(for date: Date, hour: Int, calendar: Calendar = .current) -> Date {
        let h = clampHour(hour)
        let day = calendar.startOfDay(for: date)
        guard h > 0, let boundary = calendar.date(byAdding: .hour, value: h, to: day), date < boundary else { return day }
        return calendar.date(byAdding: .day, value: -1, to: day).map { calendar.startOfDay(for: $0) } ?? day
    }

    /// When the page for `day` (a calendar day's start) begins and ends.
    static func pageInterval(_ day: Date, hour: Int, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(byAdding: .hour, value: clampHour(hour), to: calendar.startOfDay(for: day)) ?? day
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day.addingTimeInterval(86_400)
        let end = calendar.date(byAdding: .hour, value: clampHour(hour), to: nextDay) ?? nextDay
        return DateInterval(start: start, end: max(start, end))
    }

    /// Today's page.
    static func today(now: Date = Date(), hour: Int, calendar: Calendar = .current) -> Date {
        pageDay(for: now, hour: hour, calendar: calendar)
    }

    /// The page `step` days from `day` (−1 the day before).
    static func day(_ day: Date, moved step: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: step, to: calendar.startOfDay(for: day)).map { calendar.startOfDay(for: $0) } ?? day
    }

    /// Items grouped into pages: newest page first, each page's items in the order they started.
    static func group<T>(_ items: [T], date: (T) -> Date, hour: Int, calendar: Calendar = .current) -> [(day: Date, items: [T])] {
        var pages: [Date: [(Date, T)]] = [:]
        for item in items {
            let d = date(item)
            pages[pageDay(for: d, hour: hour, calendar: calendar), default: []].append((d, item))
        }
        return pages.keys.sorted(by: >).map { day in
            (day, pages[day]!.enumerated().sorted { a, b in
                a.element.0 == b.element.0 ? a.offset < b.offset : a.element.0 < b.element.0
            }.map(\.element.1))
        }
    }

    /// Just the items on one page, in the order they started.
    static func items<T>(_ items: [T], on day: Date, date: (T) -> Date, hour: Int, calendar: Calendar = .current) -> [T] {
        let want = calendar.startOfDay(for: day)
        return items.enumerated()
            .filter { pageDay(for: date($0.element), hour: hour, calendar: calendar) == want }
            .sorted { a, b in
                let da = date(a.element), db = date(b.element)
                return da == db ? a.offset < b.offset : da < db
            }
            .map(\.element)
    }

    /// The page's words for Copy and Send: each piece trimmed, empty ones left out, a blank line between them.
    static func joined(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: Labels

    private static func formatter(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// "Mon, Oct 26": the page's date as the title shows it.
    static func dateTitle(_ day: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        formatter("EEEMMMd", calendar: calendar, locale: locale).string(from: day)
    }

    /// "Thoughts · Mon, Oct 26".
    static func title(_ kind: String, day: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "\(kind) · \(dateTitle(day, calendar: calendar, locale: locale))"
    }

    /// "Mon 26": a day in the day list.
    static func listDay(_ day: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let weekday = formatter("EEE", calendar: calendar, locale: locale).string(from: day)
        return "\(weekday) \(calendar.component(.day, from: day))"
    }

    /// "Mon Oct 26": the eyebrow over a page.
    static func eyebrowDay(_ day: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        dateTitle(day, calendar: calendar, locale: locale).replacingOccurrences(of: ",", with: "")
    }

    /// "October 2026".
    static func monthTitle(_ month: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        formatter("MMMMyyyy", calendar: calendar, locale: locale).string(from: month)
    }

    /// "1 thought", "6 thoughts".
    static func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

    // MARK: Calendar

    /// One month's grid, whole weeks from the calendar's first weekday: the days before and after the month fill the
    /// first and last weeks (`inMonth` false).
    static func monthGrid(_ month: Date, calendar: Calendar = .current) -> [(day: Date, inMonth: Bool)] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let first = calendar.startOfDay(for: interval.start)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let daysInMonth = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let cells = Int(((Double(lead + daysInMonth)) / 7).rounded(.up)) * 7
        return (0..<cells).compactMap { i -> (day: Date, inMonth: Bool)? in
            guard let d = calendar.date(byAdding: .day, value: i - lead, to: first) else { return nil }
            return (calendar.startOfDay(for: d), i >= lead && i < lead + daysInMonth)
        }
    }

    /// The first of `month`, moved by `step` months.
    static func month(_ month: Date, moved step: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        return calendar.date(byAdding: .month, value: step, to: start) ?? start
    }

    /// The weekday letters over the grid, from the calendar's first weekday ("S", "M", "T", …).
    static func weekdayLetters(calendar: Calendar = .current) -> [String] {
        let s = calendar.veryShortStandaloneWeekdaySymbols
        guard s.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        return (0..<7).map { s[(calendar.firstWeekday - 1 + $0) % 7] }
    }
}

/// The Thought pad's saved pieces (thoughtpad.json, before Thoughts), read once at launch to become text-only Thoughts
/// recordings dated by each piece's `createdAt`. Each recording takes its piece's ID, so a second run can never add a
/// piece twice, and the file is renamed once it's done.
enum PadMigration {
    struct Piece: Equatable {
        var id: UUID
        var text: String
        var seconds: Double
        var missed: Bool
        var createdAt: Date
    }

    /// The pad's title (it becomes each recording's title, so it isn't lost) and its pieces with words in them, in the
    /// pad's order. Nil for a file that isn't the pad's.
    static func read(_ data: Data) -> (title: String, pieces: [Piece])? {
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        let pieces = saved.pieces.compactMap { p -> Piece? in
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Piece(id: p.id, text: text, seconds: p.seconds, missed: p.missed, createdAt: p.createdAt)
        }
        return (saved.title.trimmingCharacters(in: .whitespacesAndNewlines), pieces)
    }

    /// The pieces still to add: those whose ID isn't a recording yet.
    static func pending(_ pieces: [Piece], existing: Set<UUID>) -> [Piece] {
        var seen = existing
        return pieces.filter { seen.insert($0.id).inserted }
    }

    /// Where the file goes once it's read: beside it, renamed, so nothing is ever deleted.
    static func doneName(_ name: String) -> String {
        (name as NSString).deletingPathExtension + "-migrated.json"
    }

    // The pad's own format (PadPiece in Flow/ThoughtPad.swift before Thoughts), read tolerantly: a field that's
    // missing takes the pad's default.
    private struct Saved: Decodable {
        var title: String
        var pieces: [SavedPiece]
        init(from d: Decoder) throws {
            enum K: String, CodingKey { case title, pieces }
            let c = try d.container(keyedBy: K.self)
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            pieces = try c.decode([SavedPiece].self, forKey: .pieces)
        }
    }

    private struct SavedPiece: Decodable {
        var id: UUID
        var text: String
        var seconds: Double
        var missed: Bool
        var createdAt: Date
        init(from d: Decoder) throws {
            enum K: String, CodingKey { case id, text, seconds, missed, createdAt }
            let c = try d.container(keyedBy: K.self)
            id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
            seconds = (try? c.decodeIfPresent(Double.self, forKey: .seconds)) ?? 0
            missed = (try? c.decodeIfPresent(Bool.self, forKey: .missed)) ?? false
            createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        }
    }
}
