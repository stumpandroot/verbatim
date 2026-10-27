import Foundation

// Thoughts and Journal pages from the library, shared by the Mac and the iPhone (DESIGN.md §14). A thought is a
// recording of the Thoughts kind (raw value `idea`); a day's page is every one that started that day, in time order
// (DayPages.swift). Nothing here is stored: pages come from the library each time it changes.

/// The words a thought shows, and where it was recorded.
enum ThoughtText {
    /// A thought's words: what you edited or the cleaned text when there is one, else what was heard.
    static func words(_ t: Transcript) -> String {
        if let d = t.document?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        return t.segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Mac", "iPhone", or "Apple Watch": where it was recorded, in the sans meta line under a thought. A thought from
    /// the watch is transcribed on the iPhone, so its label decides before the device that transcribed it.
    static func origin(_ t: Transcript) -> String {
        if t.sourceLabel.lowercased().contains("apple watch") { return WatchImport.origin }
        let s = (t.sourceLabel + " " + (t.processingDeviceName ?? "")).lowercased()
        return s.contains("iphone") ? "iPhone" : "Mac"
    }

    /// The page's words for Copy and Send, a blank line between thoughts.
    static func joined(_ page: [Transcript]) -> String { DayPages.joined(page.map(words)) }

    /// A thought that finished transcribing with no words ("Nothing heard"). A page folds these into one row.
    static func isEmpty(_ t: Transcript) -> Bool { t.status == .ready && words(t).isEmpty }

    /// Shorter than this with nothing heard, a recorded thought is a stray press: it goes to Recently Deleted with its
    /// audio instead of onto the page.
    static let strayPressSeconds: Double = 1.4

    /// True for a recorded thought that finished with no words and lasts under `strayPressSeconds`.
    static func isStrayPress(_ t: Transcript) -> Bool {
        t.kind == .idea && t.audioFileName != nil && isEmpty(t) && t.duration < strayPressSeconds
    }

    /// The thought a day list shows for its day: the first with words, else the first.
    static func firstWithWords(_ page: [Transcript]) -> Transcript? { page.first { !words($0).isEmpty } ?? page.first }

    /// "9:40" in Verbose (mono, like a transcript's timecode), "9:40 AM" in Native.
    static func time(_ date: Date, native: Bool) -> String {
        if native { return Formats.style(date: .none, time: .short).string(from: date) }
        let f = Formats.pattern(DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current)?
            .replacingOccurrences(of: "a", with: "").trimmingCharacters(in: .whitespaces) ?? "h:mm")
        return f.string(from: date)
    }

    /// The iPhone's Verbose time beside a thought: "10:00a" and "3:00p" in a 12-hour English locale, so a page never
    /// reads "10:00" then "3:00" with no way to tell morning from afternoon; "15:00" in a 24-hour locale; and the
    /// locale's own short time ("下午3:00") in other 12-hour languages, where a trailing "a" or "p" means nothing.
    static func compactTime(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "h:mm a"
        guard pattern.contains("a") else { return Formats.pattern(pattern).string(from: date) }
        guard locale.language.languageCode?.identifier == "en" else { return Formats.style(date: .none, time: .short).string(from: date) }
        let base = pattern.replacingOccurrences(of: "a", with: "").trimmingCharacters(in: .whitespaces)
        let f: DateFormatter
        if locale.identifier == Locale.current.identifier && calendar.timeZone == TimeZone.current {
            f = Formats.pattern(base)
        } else {
            f = DateFormatter(); f.locale = locale; f.timeZone = calendar.timeZone; f.dateFormat = base
        }
        return f.string(from: date) + (calendar.component(.hour, from: date) < 12 ? "a" : "p")
    }
}

extension Store {
    /// Every live recording of `kind` (Thoughts or Journal), grouped into pages, newest page first. Kept until the
    /// library changes.
    func dayPages(_ kind: RecordingKind, hour: Int) -> [(day: Date, items: [Transcript])] {
        memo("dayPages-\(kind.rawValue)-\(hour)") {
            DayPages.group(live.filter { $0.kind == kind && !$0.isDictation }, date: \.createdAt, hour: hour)
        }
    }

    /// One page's recordings, in the order they started.
    func page(_ kind: RecordingKind, day: Date, hour: Int) -> [Transcript] {
        let want = Calendar.current.startOfDay(for: day)
        return dayPages(kind, hour: hour).first { $0.day == want }?.items ?? []
    }

    /// Today's thoughts, with the New page each day at setting.
    func todaysThoughts(now: Date = Date()) -> [Transcript] {
        let hour = DayPages.storedHour()
        return page(.idea, day: DayPages.today(now: now, hour: hour), hour: hour)
    }

    /// Journal entries started in the last seven pages (today and the six days before), for the sidebar's badge.
    func journalThisWeek(now: Date = Date()) -> Int {
        let hour = DayPages.storedHour()
        let today = DayPages.today(now: now, hour: hour)
        let first = DayPages.day(today, moved: -6)
        return dayPages(.journal, hour: hour).filter { $0.day >= first && $0.day <= today }.reduce(0) { $0 + $1.items.count }
    }
}
