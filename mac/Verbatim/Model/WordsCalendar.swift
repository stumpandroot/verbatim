import Foundation

// Your words calendar (DESIGN.md §13, Your words calendar; approved mockup "Verbose words calendar", November 1, 2026): a month of days
// shaded by the words you dictated, a day opened from it, a year of small months with the bookshelf, and the cards
// under the month (filler words taken out, talking versus typing, pace by week, the longest dictation, the time of day
// you talk, what you recorded, and a milestone shown once). Foundation only, so the rules run in the self-tests and in
// mac/tools/test-words-calendar.sh. Nothing here leaves the device.
//
// Words are dictation words (what was pasted), the same count as This week. Recordings don't add words; each one is a
// dot on its day and a row when you open it. There's no streak to lose: the month counts the days you talked and its
// longest run.

/// A recording on the calendar: what it is, for its dot and its row.
struct WordsRecording: Equatable, Sendable {
    /// The four kind colors (DESIGN.md §1): persimmon, butter, sage, petal.
    enum Tone: String, Equatable, Sendable { case persimmon, butter, sage, petal }
    var id: UUID
    var title: String
    /// "Brain dump", "Meeting", "Voice note".
    var kind: String
    var tone: Tone
    var duration: Double
}

/// One thing said on a day: a dictation (with words) or a recording (with none).
struct WordsEntry: Equatable, Sendable {
    var date: Date
    /// Words pasted; 0 for a recording.
    var words: Int = 0
    /// Time spent talking.
    var seconds: Double = 0
    /// A dictation's text before cleanup, for the filler words it took out.
    var raw: String = ""
    /// What you said: a dictation's pasted text, or the words of a recording only you speak in. For Words you said most.
    var said: String = ""
    /// Where a dictation went ("Mail", "Email"), when known.
    var place: String? = nil
    var recording: WordsRecording? = nil

    var isDictation: Bool { recording == nil }
}

enum WordsCalendar {
    // MARK: Shading

    /// A day's shade: 0 for no words, then 1–249, 250–749, 750–1,499, and 1,500 or more.
    static func level(_ words: Int) -> Int {
        switch words {
        case ..<1: return 0
        case ..<250: return 1
        case ..<750: return 2
        case ..<1500: return 3
        default: return 4
        }
    }

    /// The short count in a day's square: "420", "1.2k", "12k", or nothing.
    static func short(_ words: Int) -> String {
        guard words > 0 else { return "" }
        if words < 1000 { return String(words) }
        if words < 10_000 {
            let tenths = Int((Double(words) / 100).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10)k" : "\(tenths / 10).\(tenths % 10)k"
        }
        return "\(Int((Double(words) / 1000).rounded()))k"
    }

    // MARK: Days and months

    struct Day: Equatable {
        var start: Date
        var words = 0
        var seconds = 0.0
        var dictations = 0
        var recordings: [WordsRecording] = []
        var isToday = false
        var isFuture = false
        var level: Int { WordsCalendar.level(words) }
        /// Talked: dictated or recorded.
        var talked: Bool { words > 0 || !recordings.isEmpty }
    }

    struct Run: Equatable {
        var days: Int
        var from: Date
        var to: Date
    }

    struct Month: Equatable {
        var start: Date
        /// Blank squares before the 1st, so it lands under its weekday.
        var leading: Int
        var days: [Day]
        var words = 0
        var seconds = 0.0
        /// Days so far (today included); the whole month for one that's over.
        var daysSoFar = 0
        var daysTalked = 0
        var best: Day? = nil
        var longestRun: Run? = nil
        /// Average words on each weekday so far, in the calendar's order (Sunday first in the US).
        var weekdayAverages: [Int] = []
        /// The weekdays' initials, in the same order.
        var weekdayInitials: [String] = []
        /// Index into `weekdayAverages` of the busiest weekday, when there's enough to say.
        var busiestWeekday: Int? = nil
        /// The hour (0–23) with the most words, when there's enough to say.
        var busiestHour: Int? = nil
    }

    /// Whether `date` falls in `interval`, its end left out (midnight on the 1st belongs to the new month).
    static func within(_ interval: DateInterval, _ date: Date) -> Bool { date >= interval.start && date < interval.end }

    /// The month holding `date`, its end left out.
    static func monthInterval(_ date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    /// Entries by the start of their day.
    static func byDay(_ entries: [WordsEntry], calendar: Calendar) -> [Date: [WordsEntry]] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
    }

    static func day(_ start: Date, _ list: [WordsEntry], now: Date, calendar: Calendar) -> Day {
        var d = Day(start: start)
        for e in list {
            if let r = e.recording { d.recordings.append(r) } else { d.words += e.words; d.seconds += e.seconds; d.dictations += 1 }
        }
        let today = calendar.startOfDay(for: now)
        d.isToday = start == today
        d.isFuture = start > today
        return d
    }

    /// The month holding `date`: its days, totals, best day, longest run of days talked, and your rhythm.
    static func month(containing date: Date, entries: [WordsEntry], now: Date = Date(), calendar: Calendar = .current) -> Month {
        let interval = monthInterval(date, calendar: calendar)
        let inMonth = entries.filter { within(interval, $0.date) }
        let grouped = byDay(inMonth, calendar: calendar)
        var days: [Day] = []
        var d = calendar.startOfDay(for: interval.start)
        while d < interval.end {
            days.append(day(d, grouped[d] ?? [], now: now, calendar: calendar))
            // Back to the start of the day each time: where a clock change skips midnight, adding a day to 1:00 AM
            // would land on 1:00 AM every day after.
            guard let next = calendar.date(byAdding: .day, value: 1, to: d).map(calendar.startOfDay) else { break }
            d = next
        }
        let first = calendar.component(.weekday, from: interval.start)
        var m = Month(start: interval.start, leading: (first - calendar.firstWeekday + 7) % 7, days: days)
        let soFar = days.filter { !$0.isFuture }
        m.daysSoFar = soFar.count
        for day in soFar {
            m.words += day.words; m.seconds += day.seconds
            if day.talked { m.daysTalked += 1 }
        }
        m.best = soFar.filter { $0.words > 0 }.max { a, b in a.words < b.words || (a.words == b.words && a.start > b.start) }
        m.longestRun = longestRun(soFar)
        // Weekdays in the calendar's order: index 0 is its first weekday.
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        m.weekdayInitials = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        var sums = [Int](repeating: 0, count: 7), counts = [Int](repeating: 0, count: 7)
        for day in soFar {
            let i = (calendar.component(.weekday, from: day.start) - calendar.firstWeekday + 7) % 7
            sums[i] += day.words; counts[i] += 1
        }
        m.weekdayAverages = (0..<7).map { counts[$0] == 0 ? 0 : Int((Double(sums[$0]) / Double(counts[$0])).rounded()) }
        // Enough to say: three days talked and some words.
        if m.daysTalked >= 3, m.words > 0, let top = m.weekdayAverages.max(), top > 0 {
            m.busiestWeekday = m.weekdayAverages.firstIndex(of: top)
            var hours = [Int](repeating: 0, count: 24)
            for e in inMonth where e.isDictation && e.date <= now { hours[calendar.component(.hour, from: e.date)] += e.words }
            if let h = hours.max(), h > 0 { m.busiestHour = hours.firstIndex(of: h) }
        }
        return m
    }

    /// The longest run of days talked in a row.
    static func longestRun(_ days: [Day]) -> Run? {
        var best: Run? = nil
        var current: Run? = nil
        for d in days {
            if d.talked {
                current = current.map { Run(days: $0.days + 1, from: $0.from, to: d.start) } ?? Run(days: 1, from: d.start, to: d.start)
                if let c = current, c.days > (best?.days ?? 0) { best = c }
            } else {
                current = nil
            }
        }
        return best
    }

    // MARK: A day opened

    struct DayDetail: Equatable {
        struct Mark: Equatable {
            /// Hours since midnight (9.5 is 9:30 AM).
            var hour: Double
            var words: Int
            /// nil for a dictation.
            var tone: WordsRecording.Tone?
        }
        struct Place: Equatable { var name: String; var words: Int }
        struct Recording: Equatable { var recording: WordsRecording; var at: Date }
        var day: Day
        var marks: [Mark] = []
        /// The timeline's ends, in hours: 6 AM to 10 PM unless something falls outside.
        var fromHour = 6
        var toHour = 22
        var recordings: [Recording] = []
        var places: [Place] = []
        var topWords: [(word: String, count: Int)] = []

        static func == (a: DayDetail, b: DayDetail) -> Bool {
            a.day == b.day && a.marks == b.marks && a.fromHour == b.fromHour && a.toHour == b.toHour && a.recordings == b.recordings
                && a.places == b.places && a.topWords.map(\.word) == b.topWords.map(\.word) && a.topWords.map(\.count) == b.topWords.map(\.count)
        }
    }

    static func detail(_ start: Date, entries: [WordsEntry], now: Date = Date(), calendar: Calendar = .current) -> DayDetail {
        let list = entries.filter { calendar.isDate($0.date, inSameDayAs: start) }.sorted { $0.date < $1.date }
        var out = DayDetail(day: day(calendar.startOfDay(for: start), list, now: now, calendar: calendar))
        var places: [String: Int] = [:]
        for e in list {
            let c = calendar.dateComponents([.hour, .minute], from: e.date)
            let hour = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
            out.marks.append(.init(hour: hour, words: e.words, tone: e.recording?.tone))
            if let r = e.recording { out.recordings.append(.init(recording: r, at: e.date)) }
            if e.isDictation, let p = e.place, e.words > 0 { places[p, default: 0] += e.words }
        }
        if let lo = out.marks.map(\.hour).min() { out.fromHour = min(6, Int(lo.rounded(.down))) }
        if let hi = out.marks.map(\.hour).max() { out.toHour = max(22, min(24, Int(hi.rounded(.up)))) }
        out.places = places.map { DayDetail.Place(name: $0.key, words: $0.value) }.sorted { $0.words > $1.words || ($0.words == $1.words && $0.name < $1.name) }
        out.topWords = topWords(list.map(\.said))
        return out
    }

    /// Words that aren't worth counting in Words you said most.
    static let smallWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "if", "then", "than", "to", "of", "in", "on", "at", "for", "with",
        "from", "by", "about", "as", "into", "up", "out", "over", "it", "its", "it's", "is", "are", "was", "were", "be",
        "been", "being", "am", "i", "i'm", "i'll", "i've", "i'd", "me", "my", "we", "we're", "our", "us", "you", "your",
        "you're", "he", "she", "they", "them", "their", "his", "her", "this", "that", "these", "those", "there", "here",
        "what", "which", "who", "when", "where", "why", "how", "do", "does", "did", "done", "have", "has", "had", "get",
        "got", "go", "going", "gonna", "want", "wanna", "need", "just", "like", "really", "very", "also", "too", "not",
        "no", "yes", "yeah", "okay", "ok", "um", "uh", "can", "could", "would", "should", "will", "all", "some", "any",
        "one", "two", "know", "think", "make", "sure", "thing", "things", "something", "maybe", "well", "now", "let",
        "let's", "kind", "sort", "lot", "don't", "dont", "that's", "thats", "there's", "can't", "didn't", "won't", "more",
        "much", "back", "still", "even", "because", "said", "say", "see", "way", "time", "today", "tomorrow"
    ]

    /// The six words you said most (twice or more), leaving out small words and numbers.
    static func topWords(_ texts: [String], limit: Int = 6) -> [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        var shown: [String: String] = [:]
        for text in texts {
            for raw in text.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "\u{2019}") }) {
                let w = raw.replacingOccurrences(of: "\u{2019}", with: "'").trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                let key = w.lowercased()
                guard key.count >= 3, !smallWords.contains(key) else { continue }
                counts[key, default: 0] += 1
                // A name keeps its capital ("Thursday"); a word said both ways shows in lowercase.
                if let s = shown[key] { if s != w { shown[key] = key } } else { shown[key] = w }
            }
        }
        return counts.filter { $0.value >= 2 }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit).map { (shown[$0.key] ?? $0.key, $0.value) }
    }

    // MARK: A year

    struct Year: Equatable {
        var start: Date
        var months: [Month]
        var words: Int { months.reduce(0) { $0 + $1.words } }
        /// Index of the month with the most words.
        var bestMonth: Int? {
            guard let top = months.map(\.words).max(), top > 0 else { return nil }
            return months.firstIndex { $0.words == top }
        }
    }

    static func year(containing date: Date, entries: [WordsEntry], now: Date = Date(), calendar: Calendar = .current) -> Year {
        let start = calendar.dateInterval(of: .year, for: date)?.start ?? calendar.startOfDay(for: date)
        let months = (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: start) }
            .map { month(containing: $0, entries: entries, now: now, calendar: calendar) }
        return Year(start: start, months: months)
    }

    // MARK: Lengths and the bookshelf

    struct Book: Equatable {
        var name: String
        var words: Int
        /// "a novella", "an epic".
        var withArticle: String { (name.first.map { "aeiou".contains($0.lowercased()) } ?? false ? "an " : "a ") + name.lowercased() }
    }

    /// The shelf: the lengths a year (or a milestone) is measured in.
    static let shelf: [Book] = [
        Book(name: "Short story", words: 7_500), Book(name: "Novella", words: 20_000), Book(name: "Novel", words: 50_000),
        Book(name: "Long novel", words: 100_000), Book(name: "Epic", words: 200_000), Book(name: "Trilogy", words: 300_000)
    ]
    static let wordsPerPage = 250

    /// How many books on the shelf `words` fills, and the next one with what's left to reach it.
    static func shelfProgress(_ words: Int) -> (filled: Int, next: Book?, remaining: Int) {
        let filled = shelf.filter { words >= $0.words }.count
        let next = filled < shelf.count ? shelf[filled] : nil
        return (filled, next, next.map { $0.words - words } ?? 0)
    }

    private static let numberWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    static func spelled(_ n: Int) -> String { n >= 0 && n < numberWords.count ? numberWords[n] : n.formatted() }

    /// What `words` is about as long as: "about 12 pages", "about a novella", "about two novels". nil under a page.
    static func equivalent(_ words: Int) -> String? {
        guard words >= wordsPerPage else { return nil }
        if words < shelf[0].words {
            let pages = max(1, Int((Double(words) / Double(wordsPerPage)).rounded()))
            return pages == 1 ? "about a page" : "about \(pages) pages"
        }
        if words < 100_000 { return "about " + (shelf.last { words >= $0.words } ?? shelf[0]).withArticle }
        let novels = Int((Double(words) / 50_000).rounded())
        return "about \(spelled(novels)) novels"
    }

    /// The card at the foot of a month: "October is a novella." and "18,770 more words make a novel." nil under a page.
    static func lengthLine(_ words: Int, monthName: String) -> (title: String, detail: String?)? {
        guard words >= wordsPerPage else { return nil }
        let p = shelfProgress(words)
        let title: String
        if p.filled == 0 {
            let pages = max(1, Int((Double(words) / Double(wordsPerPage)).rounded()))
            title = "\(monthName) is \(pages == 1 ? "a page" : "\(pages) pages") long."
        } else {
            title = "\(monthName) is \(shelf[p.filled - 1].withArticle)."
        }
        guard let next = p.next else { return (title, nil) }
        return (title, "\(p.remaining.formatted()) more words make \(next.withArticle).")
    }

    // MARK: The cards under the month

    /// The filler words cleanup took out, most first: each one's count in what you said less its count in what was
    /// pasted, across dictations.
    static let fillers = ["um", "uh", "erm", "hmm", "like", "you know", "i mean", "sort of", "kind of", "basically"]

    static func fillersRemoved(_ entries: [WordsEntry]) -> [(word: String, count: Int)] {
        var totals: [String: Int] = [:]
        for e in entries where e.isDictation && !e.raw.isEmpty {
            let before = normalized(e.raw), after = normalized(e.said)
            for f in fillers {
                let n = occurrences(of: f, in: before) - occurrences(of: f, in: after)
                if n > 0 { totals[f, default: 0] += n }
            }
        }
        return totals.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { ($0.key, $0.value) }
    }

    /// Lowercased words separated by single spaces, punctuation gone: " um so you know ".
    static func normalized(_ s: String) -> String {
        let words = s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        return " " + words.joined(separator: " ") + " "
    }

    static func occurrences(of phrase: String, in normalizedText: String) -> Int {
        let needle = " \(phrase) "
        var count = 0
        var range = normalizedText.startIndex..<normalizedText.endIndex
        while let r = normalizedText.range(of: needle, range: range) {
            count += 1
            // Step back over the trailing space, so "um um" counts twice.
            range = normalizedText.index(before: r.upperBound)..<normalizedText.endIndex
        }
        return count
    }

    /// Talking versus typing: how long typing the words would take at `typingWPM`, and how long you talked.
    static func typingVersusTalking(words: Int, seconds: Double, typingWPM: Int) -> (typing: Double, talking: Double, saved: Double) {
        let typing = Double(words) / Double(max(typingWPM, 1)) * 60
        return (typing, seconds, max(0, typing - seconds))
    }

    /// Words per minute, pauses included, once there are 20 seconds to go on.
    static func pace(words: Int, seconds: Double) -> Int? {
        seconds >= 20 ? Int((Double(words) / (seconds / 60)).rounded()) : nil
    }

    /// Pace for each of the last `weeks` calendar weeks up to `now`, oldest first; nil for a week with too little.
    static func weeklyPace(_ entries: [WordsEntry], now: Date = Date(), weeks: Int = 5, calendar: Calendar = .current) -> [Int?] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        return (0..<weeks).reversed().map { back -> Int? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek.start),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let list = entries.filter { $0.isDictation && $0.date >= start && $0.date < end }
            return pace(words: list.reduce(0) { $0 + $1.words }, seconds: list.reduce(0) { $0 + $1.seconds })
        }
    }

    /// The longest dictation, by time talking (10 seconds or more).
    static func longest(_ entries: [WordsEntry]) -> WordsEntry? {
        entries.filter { $0.isDictation && $0.seconds >= 10 }.max { $0.seconds < $1.seconds || ($0.seconds == $1.seconds && $0.date > $1.date) }
    }

    enum TalkTime: String { case morning, afternoon, evening }

    /// When in the day your words come: the share before noon, words in two-hour bins from 6 AM to midnight (earlier
    /// words go in the first), and which part of the day leads. nil under 200 words.
    static func timeOfDay(_ entries: [WordsEntry], calendar: Calendar = .current) -> (share: Double, bins: [Int], leader: TalkTime, leaderShare: Double)? {
        var bins = [Int](repeating: 0, count: 9)
        var parts: [TalkTime: Int] = [:]
        var total = 0
        for e in entries where e.isDictation && e.words > 0 {
            let h = calendar.component(.hour, from: e.date)
            bins[max(0, min(8, (h - 6) / 2))] += e.words
            parts[h < 12 ? .morning : h < 18 ? .afternoon : .evening, default: 0] += e.words
            total += e.words
        }
        guard total >= 200 else { return nil }
        let order: [TalkTime] = [.morning, .afternoon, .evening]
        let leader = order.max { (parts[$0] ?? 0) < (parts[$1] ?? 0) } ?? .morning
        return (Double(parts[.morning] ?? 0) / Double(total), bins, leader, Double(parts[leader] ?? 0) / Double(total))
    }

    /// The card's title and line for the time of day: "Morning talker" and "62% of your words come before noon".
    static func talkTimeText(leader: TalkTime, share: Double) -> (title: String, line: String) {
        let pct = "\(Int((share * 100).rounded()))%"
        switch leader {
        case .morning: return ("Morning talker", "\(pct) of your words come before noon")
        case .afternoon: return ("Afternoon talker", "\(pct) of your words come between noon and 6 PM")
        case .evening: return ("Evening talker", "\(pct) of your words come after 6 PM")
        }
    }

    /// What you recorded: each kind with how many, most first.
    static func kindCounts(_ entries: [WordsEntry]) -> [(kind: String, tone: WordsRecording.Tone, count: Int)] {
        var counts: [String: (WordsRecording.Tone, Int)] = [:]
        for e in entries { if let r = e.recording { counts[r.kind] = (r.tone, (counts[r.kind]?.1 ?? 0) + 1) } }
        return counts.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.2 > $1.2 || ($0.2 == $1.2 && $0.0 < $1.0) }
    }

    // MARK: Milestones

    static let milestoneSeenKey = "words.milestoneSeen"
    /// You › Show milestones (iPhone): the milestone card on the words calendar. Off by default (critique, build 283).
    static let showMilestonesKey = "words.showMilestones"

    /// The newest length on the shelf your words passed that you haven't seen yet, and the day you passed it. Shown
    /// once (`milestoneSeenKey` keeps the words of the last one shown).
    static func milestone(_ entries: [WordsEntry], seen: Int) -> (book: Book, on: Date)? {
        let dictations = entries.filter(\.isDictation).sorted { $0.date < $1.date }
        let total = dictations.reduce(0) { $0 + $1.words }
        guard let book = shelf.last(where: { total >= $0.words }), book.words > seen else { return nil }
        var running = 0
        for e in dictations {
            running += e.words
            if running >= book.words { return (book, e.date) }
        }
        return nil
    }

    /// The milestone card's title: "200,000 words. That's an epic."
    static func milestoneTitle(_ book: Book) -> String {
        "\(book.words.formatted()) words. That\u{2019}s \(book.withArticle)."
    }

    // MARK: Words

    /// Words in a piece of text: runs with a letter or a digit (the same rule as This week).
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}
