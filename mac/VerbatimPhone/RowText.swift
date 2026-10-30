import Foundation

/// The title a recording's row shows. A thought still transcribing or one that failed can have no title, and some
/// recordings keep a placeholder ("Thought", "Voice memo"); those rows show what it is and when instead: "Thought ·
/// 2:09 AM", "Voice note · 4:12 PM". A row never shows an empty title line. `withTime` is off where the row already
/// shows the time beside the title.
enum RecordingRowTitle {
    /// Titles that only say what a recording is, not what's in it.
    static let placeholders: Set<String> = Transcript.defaultTitles.union(["Thought"])

    static func title(_ t: Transcript, withTime: Bool = true) -> String {
        let trimmed = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || placeholders.contains(trimmed) else { return trimmed }
        let what: String
        if t.kind == .idea { what = "Thought" }
        else if trimmed.isEmpty || trimmed == "Voice memo" || trimmed == "Untitled" { what = t.isDictation ? "Dictation" : "Voice note" }
        else { what = trimmed }
        guard withTime else { return what }
        return "\(what) · \(Formats.style(date: .none, time: .short).string(from: t.createdAt))"
    }
}

/// A day's label over a list of recordings: "Today · Fri Oct 23", "Yesterday · Thu Oct 22", or "Mon Oct 19".
enum DayLabel {
    static func title(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Formats.pattern(calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEE MMM d" : "EEE MMM d, yyyy").string(from: day)
        if calendar.isDate(day, inSameDayAs: now) { return "Today · \(date)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday · \(date)" }
        return date
    }

    /// "Today · Fri Oct 23" → "Today"; other days keep their date.
    static func short(_ label: String) -> String {
        label.components(separatedBy: " · ").first ?? label
    }
}

extension Transcript {
    /// The Cleaned text exists: someone (or Clean up) made it.
    var isCleaned: Bool { documentCleanedBy != nil || document != nil }
}
