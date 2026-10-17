import Foundation

/// Cached date formatters. Creating a DateFormatter is slow, and many rows and saves used to make one per call.
/// Each follows the current locale and time zone as they change (`autoupdatingCurrent`), same as a fresh
/// `DateFormatter()` would. DateFormatter is safe to use from any thread for formatting.
enum Formats {
    private static let lock = NSLock()
    private static var patterns: [String: DateFormatter] = [:]
    private static var styles: [String: DateFormatter] = [:]

    /// A formatter for a fixed pattern such as "MMM d" or "yyyy-MM-dd HH.mm.ss".
    static func pattern(_ p: String) -> DateFormatter {
        lock.lock(); defer { lock.unlock() }
        if let f = patterns[p] { return f }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent; f.timeZone = .autoupdatingCurrent
        f.dateFormat = p
        patterns[p] = f
        return f
    }

    /// A formatter for a date and time style, such as `.medium` date with no time.
    static func style(date: DateFormatter.Style, time: DateFormatter.Style, relative: Bool = false) -> DateFormatter {
        let key = "\(date.rawValue)-\(time.rawValue)-\(relative)"
        lock.lock(); defer { lock.unlock() }
        if let f = styles[key] { return f }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent; f.timeZone = .autoupdatingCurrent
        f.dateStyle = date; f.timeStyle = time
        f.doesRelativeDateFormatting = relative
        styles[key] = f
        return f
    }

    /// File-name stamp used for recordings and joined audio.
    static var fileStamp: DateFormatter { pattern("yyyy-MM-dd HH.mm.ss") }
}
