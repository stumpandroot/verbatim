import Foundation

// Pure rules behind the iPhone's Premium Native look (DESIGN.md §13): the week chart, the days you used Verbose, the
// year's month bars, the month calendar's dots, the recorder's clock and waveform, a recording's preview, and the
// gradients' contrast. Foundation only, so mac/tools/test-premium.sh runs them on Linux.

enum PremiumRules {
    // MARK: Home's This week chart

    /// Bar heights for the seven-day mini chart, scaled to the week's busiest day. A day with words is at least
    /// `minHeight`; a day without words, or one still to come, is nil (drawn as a short stub).
    static func barHeights(_ words: [Int], future: [Bool], maxHeight: Double, minHeight: Double = 4) -> [Double?] {
        let peak = Double(max(1, words.max() ?? 0))
        return words.enumerated().map { i, w in
            let ahead = i < future.count ? future[i] : false
            guard !ahead, w > 0 else { return nil }
            return max(minHeight, maxHeight * Double(w) / peak)
        }
    }

    // MARK: You's week card

    /// Which of the last `count` days (oldest first, today last) have something recorded or dictated.
    static func daysUsed(_ dates: [Date], now: Date, count: Int = 7, calendar: Calendar = .current) -> [Bool] {
        let today = calendar.startOfDay(for: now)
        let days: [Date] = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0 - (count - 1), to: today) }
        let used = Set(dates.map { calendar.startOfDay(for: $0) })
        return days.map { used.contains($0) }
    }

    /// The single letter for each of the last `count` days, oldest first ("S", "M", …), from the calendar's own names.
    static func dayLetters(now: Date, count: Int = 7, calendar: Calendar = .current) -> [String] {
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        let today = calendar.startOfDay(for: now)
        return (0..<count).map { i in
            let d = calendar.date(byAdding: .day, value: i - (count - 1), to: today) ?? today
            return letters[(calendar.component(.weekday, from: d) - 1) % letters.count]
        }
    }

    /// "5 days", "1 day".
    static func daysLabel(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    /// The week card's line. No streak, no pressure (the calm rule): it says what happened and nothing else.
    static func daysSentence(_ n: Int, of total: Int = 7) -> String {
        if n == 0 { return "Nothing recorded in the last \(total) days. No streak to keep; it's here when you are." }
        return "You used Verbose on \(n) of the last \(total) days. No streak to keep; this is just your week."
    }

    // MARK: You's year card

    /// How many dates fall in each month of `year`, January first (12 counts).
    static func monthCounts(_ dates: [Date], year: Int, calendar: Calendar = .current) -> [Int] {
        var out = [Int](repeating: 0, count: 12)
        for d in dates {
            let c = calendar.dateComponents([.year, .month], from: d)
            guard c.year == year, let m = c.month, (1...12).contains(m) else { continue }
            out[m - 1] += 1
        }
        return out
    }

    // MARK: You's month calendar

    struct MonthGrid: Equatable {
        /// Empty cells before the 1st, so it falls under its weekday (the calendar's first weekday leads).
        var leadingBlanks: Int
        var days: Int
        /// Today's day number when this is the current month.
        var today: Int?
        /// Day numbers with something recorded or dictated: each gets a dot.
        var recorded: Set<Int>
        /// The month's first day.
        var start: Date
    }

    /// The month holding `month`, with a dot on each day that has one of `dates`.
    static func month(_ month: Date, recorded dates: [Date], now: Date, calendar: Calendar = .current) -> MonthGrid {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let weekday = calendar.component(.weekday, from: start)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        var recorded = Set<Int>()
        for d in dates where calendar.isDate(d, equalTo: start, toGranularity: .month) {
            recorded.insert(calendar.component(.day, from: d))
        }
        let today = calendar.isDate(now, equalTo: start, toGranularity: .month) ? calendar.component(.day, from: now) : nil
        return MonthGrid(leadingBlanks: blanks, days: days, today: today, recorded: recorded, start: start)
    }

    /// The weekday headers in the calendar's order ("SUN", "MON", …).
    static func weekdayHeaders(calendar: Calendar = .current) -> [String] {
        let s = calendar.shortStandaloneWeekdaySymbols.map { $0.uppercased() }
        let first = calendar.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    /// The month `by` months from `month`, at its first day.
    static func shiftMonth(_ month: Date, by: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        return calendar.date(byAdding: .month, value: by, to: start) ?? start
    }

    // MARK: The recorder

    /// The recorder's big clock: "00:42", "02:14", "1:02:05".
    static func recorderClock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    struct WaveBar: Equatable { var height: Double; var past: Bool }

    /// The live waveform with the playhead in the middle: the newest `count / 2` levels to its left (heard, the
    /// newest at the playhead), quiet stubs to its right (still to come). Heights are 0…1, never below `floor`.
    static func waveBars(_ levels: [Float], count: Int, floor: Double = 0.06) -> [WaveBar] {
        guard count > 0 else { return [] }
        let half = count / 2
        let recent = Array(levels.suffix(half))
        let pad = half - recent.count
        var out: [WaveBar] = []
        out.reserveCapacity(count)
        for i in 0..<half {
            let v = i < pad ? 0 : Double(recent[i - pad])
            out.append(WaveBar(height: max(floor, min(1, v)), past: true))
        }
        for _ in half..<count { out.append(WaveBar(height: floor, past: false)) }
        return out
    }

    /// "Voice note · 2:14 · Today, 4:12 PM · 2 moments" under Saved to Library.
    static func savedLine(kind: String, length: String, when: String, moments: Int) -> String {
        var parts = [kind, length, when]
        if moments > 0 { parts.append(moments == 1 ? "1 moment" : "\(moments) moments") }
        return parts.joined(separator: " · ")
    }

    /// The share done from an engine stage label ("Transcribing 42%" → 0.42), or nil without a percentage.
    static func stageFraction(_ stage: String?) -> Double? {
        guard let s = stage, let r = s.range(of: #"(\d{1,3})%"#, options: .regularExpression),
              let n = Double(s[r].dropLast()) else { return nil }
        return min(1, max(0, n / 100))
    }

    // MARK: A recording's preview

    /// The first lines of a recording as one short paragraph: whitespace folded, cut at a word near `limit`.
    static func preview(_ lines: [String], limit: Int = 180) -> String {
        var out = ""
        for l in lines {
            let t = l.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            if t.isEmpty { continue }
            out += out.isEmpty ? t : " " + t
            if out.count >= limit { break }
        }
        guard out.count > limit else { return out }
        let cut = out.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }

    // MARK: Contrast

    /// WCAG relative luminance of an sRGB color.
    static func luminance(_ hex: UInt32) -> Double {
        func c(_ v: UInt32) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * c((hex >> 16) & 0xFF) + 0.7152 * c((hex >> 8) & 0xFF) + 0.0722 * c(hex & 0xFF)
    }

    /// WCAG contrast ratio between two colors.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `a` moved toward `b` by `t` (0…1), per channel.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        var out: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            out |= UInt32(max(0, min(255, (x + (y - x) * t).rounded()))) << shift
        }
        return out
    }

    /// The color at `position` (0 top, 1 bottom) of evenly spaced stops.
    static func gradientColor(_ stops: [UInt32], at position: Double) -> UInt32 {
        guard let first = stops.first else { return 0 }
        guard stops.count > 1 else { return first }
        let p = max(0, min(1, position)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(p.rounded(.down)))
        return mix(stops[i], stops[i + 1], p - Double(i))
    }

    /// The highlight laid over a gradient card's top: white at this strength, gone by a third of the way down.
    static let highlight = 0.10

    /// The lowest contrast white text gets on a gradient from `from` to the bottom, sampled every 2%.
    static func minWhiteContrast(_ stops: [UInt32], from: Double) -> Double {
        stride(from: from, through: 1.0, by: 0.02).map { contrast(0xFFFFFF, gradientColor(stops, at: $0)) }.min() ?? 0
    }
}
