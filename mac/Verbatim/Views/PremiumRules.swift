import Foundation

// Pure rules behind Premium Native on the Mac (DESIGN.md §13.2), Foundation only, so mac/tools/test-premium.sh runs
// them on Linux: the gradient cards' stop positions and where white text may sit on them, the recordings' date line,
// speakers' shares, This week's bars, whether the Library's scope fits as a segmented control, and the toolbar's
// back and forward history.

// MARK: - Gradient cards

/// The three gradient cards. Colors are in Tokens.swift (`PremiumHex`); positions and text placement are here.
enum PremiumCard: String, CaseIterable {
    case persimmon, ink, sage

    /// Where each color stop sits, top (0) to bottom (1), matching `PremiumHex`'s arrays.
    var locations: [Double] {
        switch self {
        case .persimmon: return [0, 0.4, 1]
        case .ink: return [0, 0.58, 1]
        case .sage: return [0, 1]
        }
    }
}

/// A piece of white text on a gradient card: where it sits (a band from the card's top, 0, to its bottom, 1) and
/// whether it's large text by WCAG (18 pt and up, or 14 pt bold and up), which needs 3:1 instead of 4.5:1.
struct PremiumCardText: Equatable {
    var card: PremiumCard
    var name: String
    var from: Double
    var to: Double
    var large: Bool

    /// Every white text the Mac's gradient cards carry. Small text sits low, where the gradient is deepest.
    static let all: [PremiumCardText] = [
        // This week (Home): "This week ›" (15 pt bold) at the top, the big number, "words dictated", the day letters.
        PremiumCardText(card: .persimmon, name: "This week label", from: 0.06, to: 0.2, large: true),
        PremiumCardText(card: .persimmon, name: "This week number", from: 0.5, to: 0.82, large: true),
        PremiumCardText(card: .persimmon, name: "words dictated", from: 0.82, to: 0.93, large: false),
        PremiumCardText(card: .persimmon, name: "day letters", from: 0.86, to: 0.94, large: false),
        // Summary (transcript and Library preview): "Summary" (14 pt bold), the overview (17 pt bold), key points,
        // and "Made by Apple Intelligence" at the foot.
        PremiumCardText(card: .persimmon, name: "Summary label", from: 0.04, to: 0.16, large: true),
        PremiumCardText(card: .persimmon, name: "summary overview", from: 0.16, to: 0.42, large: true),
        PremiumCardText(card: .persimmon, name: "key points", from: 0.42, to: 0.9, large: false),
        PremiumCardText(card: .persimmon, name: "Apple Intelligence note", from: 0.9, to: 0.97, large: false),
        // Stat cards (Home): the number (40 pt) and its two-line label (14 pt bold), centered.
        PremiumCardText(card: .ink, name: "recordings number", from: 0.25, to: 0.75, large: true),
        PremiumCardText(card: .ink, name: "recordings label", from: 0.3, to: 0.7, large: false),
        PremiumCardText(card: .sage, name: "saved number", from: 0.25, to: 0.75, large: true),
        PremiumCardText(card: .sage, name: "saved label", from: 0.3, to: 0.7, large: true),
    ]
}

/// WCAG contrast on a gradient, in sRGB.
enum PremiumContrast {
    static func luminance(_ hex: UInt32) -> Double {
        func c(_ v: UInt32) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * c((hex >> 16) & 0xFF) + 0.7152 * c((hex >> 8) & 0xFF) + 0.0722 * c(hex & 0xFF)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The gradient's color at `t` (0 at the top, 1 at the bottom), mixed in sRGB between the stops around it.
    static func color(at t: Double, stops: [UInt32], locations: [Double]) -> UInt32 {
        guard let first = stops.first, stops.count == locations.count else { return 0 }
        let x = min(1, max(0, t))
        guard let i = locations.firstIndex(where: { $0 >= x }) else { return stops[stops.count - 1] }
        if i == 0 { return first }
        let a = locations[i - 1], b = locations[i]
        let f = b > a ? (x - a) / (b - a) : 0
        func mix(_ shift: UInt32) -> UInt32 {
            let p = Double((stops[i - 1] >> shift) & 0xFF), q = Double((stops[i] >> shift) & 0xFF)
            return UInt32((p + (q - p) * f).rounded()) << shift
        }
        return mix(16) | mix(8) | mix(0)
    }

    /// The lowest contrast white text gets anywhere in the band from `from` to `to`.
    static func worstWhite(from: Double, to: Double, stops: [UInt32], locations: [Double]) -> Double {
        var worst = Double.infinity
        for k in 0...20 {
            let t = from + (to - from) * Double(k) / 20
            worst = min(worst, ratio(color(at: t, stops: stops, locations: locations), 0xFFFFFF))
        }
        return worst
    }
}

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

/// This week's mini chart on the gradient card: one bar per day.
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

// MARK: - Toolbar

enum ScopeBarStyle {
    /// About how wide a segmented control with these labels draws at 12.5 pt (6.6 pt a character, 24 pt of padding
    /// per segment, and the track's 4 pt).
    static func segmentedWidth(_ labels: [String]) -> Double {
        labels.reduce(4) { $0 + Double($1.count) * 6.6 + 24 }
    }

    /// The Library's scope shows as a segmented control when it fits in `available` points; otherwise a pop-up menu.
    static func segmented(_ labels: [String], available: Double) -> Bool {
        labels.count <= 7 && segmentedWidth(labels) <= available
    }
}

/// Back and forward through the screens you visited (the transcript's toolbar), like a browser's history.
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
