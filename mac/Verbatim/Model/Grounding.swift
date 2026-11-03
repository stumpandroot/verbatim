import Foundation

// AI output checks (design critique, November 3, 2026): Apple Intelligence's summaries, template results, Ask answers,
// and plans can state a number, a name, a quote, or a day with confidence when the source never said it. These checks
// compare what the model wrote with what it was given, deterministically, so they run the same on every device and in
// CI (where the model can't run). They never change or hide the output: they find terms to check, and the result's
// note names them ("Check this: 32% and “Harrisburg” aren't in the transcript.").
//
// Precision over recall: a note on a correct result teaches people to ignore the note, so every rule leans toward
// staying quiet. Small counts ("three issues") aren't checked, a word at the start of a sentence isn't taken for a name,
// spelled-out and written numbers match each other ("twelve hundred dollars" and "$1,200"), names match across
// possessives, plurals, and one-letter spelling differences, and a quote matches when most of its words appear in order.
//
// Pure Foundation, no app types: mac/tools/test-grounding.sh runs it on Linux. Grounding+Results.swift connects it to
// summaries, template results, Ask answers, and plans.

/// One thing in the output the source doesn't support.
struct GroundingFinding: Equatable, Hashable {
    enum Kind: String {
        /// A number, amount, percentage, or time the source doesn't have.
        case number
        /// A capitalized name the source doesn't have.
        case name
        /// Quoted words the source doesn't have.
        case quote
        /// A weekday, month, "tomorrow", or "yesterday" the source doesn't say.
        case date
        /// "Urgent", "ASAP", "high priority" on a task when the source never says it.
        case priority
        /// An Ask citation whose passage doesn't mention what its sentence says.
        case citation
        /// A citation or a line's time past the end of its recording.
        case timeRange
        /// A plan's task under Tomorrow or This week when the line it came from names no day.
        case dayNotSaid
        /// A plan's Top three when the source never says what matters most.
        case topNotNamed
    }

    var kind: Kind
    /// As the output wrote it: "32%", "Harrisburg", "Call Rob", "45:10".
    var text: String
    /// The citation's number, for `.citation` and `.timeRange` on an Ask answer.
    var number: Int? = nil
}

/// A line of the source with its time span, so a plan's task can be checked against the lines around its [mm:ss].
struct GroundingLine: Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// What the model was given, indexed once: its words, numbers, times, weekdays, and months.
struct GroundingSource {
    let lines: [GroundingLine]
    /// Each line stands alone (a day's thoughts, a note's paragraphs): a task's window is its own line only.
    var separateLines = false
    /// The recording's length in seconds, when there is one: a time past it is a finding.
    let duration: Double?
    /// Every word, normalized (lowercase, no accents, no possessive).
    private(set) var words: Set<String> = []
    /// Two neighboring words run together ("mc" + "allister"), for names written as one word.
    private(set) var joined: Set<String> = []
    /// Words by their first five letters, for the fuzzy name match.
    private(set) var byPrefix: [String: [String]] = [:]
    /// Words by first letter and length, for the one-letter spelling match.
    private(set) var byShape: [String: [String]] = [:]
    /// Every number the source says, written or spelled out, with the forms it can take (see `GroundingNumbers`).
    private(set) var numbers: Set<Int64> = []
    private(set) var numberList: [Double] = []
    /// Times of day, as minutes past 12 on a 12-hour clock (3:30 and 15:30 are both 210).
    private(set) var times: Set<Int> = []
    /// Weekdays (1 Sunday … 7 Saturday) and months (1…12) the source names.
    private(set) var weekdays: Set<Int> = []
    private(set) var months: Set<Int> = []
    /// Words the source capitalizes mid-sentence: names it uses ("Dana"), so a run like "Dana Whitman" at the start
    /// of a sentence shows whole in the note.
    private(set) var proper: Set<String> = []
    /// The words in order, for quotes.
    private(set) var sequence: [String] = []
    /// False when the source is in another language: numbers and days aren't checked then (see `englishMarkers`).
    var isEnglish: Bool {
        guard sequence.count >= 30 else { return true }
        let markers = sequence.reduce(0) { $0 + (GroundingText.englishMarkers.contains($1) ? 1 : 0) }
        return Double(markers) / Double(sequence.count) >= 0.08
    }
    private var counts: [String: Int] = [:]

    /// `known` is text the model also saw or that names people (speaker names, the title, About me, the question):
    /// it supports names and days, never numbers.
    init(lines: [GroundingLine], known: [String] = [], duration: Double? = nil) {
        self.lines = lines
        self.duration = duration
        var nums: [Double] = []
        for l in lines {
            let toks = GroundingText.tokenize(l.text)
            addWords(toks, ordered: true)
            nums += GroundingNumbers.sourceValues(l.text, tokens: toks, times: &times)
        }
        for k in known where !k.isEmpty {
            addWords(GroundingText.tokenize(k), ordered: false)
        }
        if let d = duration, d > 0 {
            let m = d / 60
            nums += [m.rounded(.down), m.rounded(.up), m.rounded()]
        }
        for v in nums where v.isFinite { numbers.insert(GroundingNumbers.key(v)) }
        numberList = Array(Set(nums.filter(\.isFinite)))
    }

    init(text: String, known: [String] = [], duration: Double? = nil) {
        self.init(lines: [GroundingLine(start: 0, end: 0, text: text)], known: known, duration: duration)
    }

    private mutating func addWords(_ toks: [GroundingText.Token], ordered: Bool) {
        var prev: String? = nil
        for t in toks {
            let w = t.norm
            guard !w.isEmpty else { prev = nil; continue }
            if ordered { sequence.append(w); counts[w, default: 0] += 1 }
            if words.insert(w).inserted {
                if w.count >= 5 { byPrefix[String(w.prefix(5)), default: []].append(w) }
                if let f = w.first { byShape["\(f)\(w.count)", default: []].append(w) }
            }
            if let p = prev, !t.gapPunct { joined.insert(p + w) }
            if t.capitalized, !t.atStart { proper.insert(w) }
            if let d = GroundingText.weekday(w, capitalized: true) { weekdays.insert(d) }
            if let m = GroundingText.month(w, capitalized: true, nextIsNumber: true) { months.insert(m) }
            prev = w
        }
    }

    /// The line a time names (the last one starting by then) with the line before and after it, since a sentence
    /// often runs across a recording's lines; only that line when lines stand alone.
    func window(around t: Double) -> [GroundingLine] {
        guard !lines.isEmpty else { return [] }
        let k = lines.lastIndex { $0.start <= t + 1 } ?? 0
        if separateLines { return [lines[k]] }
        return Array(lines[max(0, k - 1)...min(lines.count - 1, k + 1)])
    }

    func count(_ w: String) -> Int { counts[w] ?? 0 }

    // MARK: Lookups

    func has(_ w: String) -> Bool { words.contains(w) }

    /// A name's word is in the source: as written, singular or plural, run together from two words, sharing most of
    /// its start ("Canadian", "Canada"), or one letter off ("Katherine", "Kathrine").
    func supportsName(_ w: String) -> Bool {
        if words.contains(w) || joined.contains(w) { return true }
        if w.hasSuffix("s"), words.contains(String(w.dropLast())) { return true }
        if words.contains(w + "s") || words.contains(w + "es") { return true }
        if w.count >= 5 {
            for s in byPrefix[String(w.prefix(5))] ?? [] {
                let common = GroundingText.commonPrefix(w, s)
                if common >= max(5, Int((0.75 * Double(min(w.count, s.count))).rounded(.up))) { return true }
            }
        }
        if w.count >= 6, let f = w.first {
            for n in (w.count - 1)...(w.count + 1) {
                for s in byShape["\(f)\(n)"] ?? [] where GroundingText.withinOneEdit(w, s) { return true }
            }
        }
        return false
    }

    func supportsNumber(_ v: Double, approximate: Bool) -> Bool {
        if numbers.contains(GroundingNumbers.key(v)) { return true }
        guard approximate else { return false }
        return numberList.contains { abs($0 - v) <= max(0.5, abs(v) * 0.1) }
    }

    /// A time of day: the same hour and minute on a 12-hour clock; an hour alone ("3 PM") also matches the number 3
    /// or 15 anywhere, or 3.30 written as a decimal for 3:30.
    func supportsTime(hour: Int, minute: Int) -> Bool {
        let key = (hour % 12) * 60 + minute
        if times.contains(key) { return true }
        if minute == 0 {
            let h12 = hour % 12 == 0 ? 12 : hour % 12
            return numbers.contains(GroundingNumbers.key(Double(h12))) || numbers.contains(GroundingNumbers.key(Double(h12 + 12)))
        }
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return numbers.contains(GroundingNumbers.key(Double(h12) + Double(minute) / 100))
    }
}

// MARK: - Text

enum GroundingText {
    struct Token: Equatable {
        /// As written, with a trailing possessive.
        var raw: String
        /// Lowercase, no accents, no possessive, no apostrophes.
        var norm: String
        /// First word of a sentence, a line, a clause after a colon, or a quote.
        var atStart: Bool
        /// Starts with a capital and has a lowercase letter ("Dana", "McAllister"; not "NASA" or "iPhone").
        var capitalized: Bool
        var possessive: Bool
        /// Only digits.
        var isNumber: Bool
        /// Something other than a space or a hyphen separates it from the word before.
        var gapPunct: Bool
    }

    /// Short forms whose period doesn't end a sentence.
    static let shortForms: Set<String> = ["dr", "mr", "mrs", "ms", "mx", "st", "jr", "sr", "prof", "vs", "etc", "eg", "ie", "mt", "no", "inc", "co", "ltd", "gen", "capt", "sgt", "rev", "fr", "ave", "rd", "approx"]

    static func tokenize(_ text: String) -> [Token] {
        var out: [Token] = []
        var cur = ""
        var boundary = true
        var pendingEnd = false
        var gap = false
        func flush() {
            guard !cur.isEmpty else { return }
            let raw = cur
            cur = ""
            let possessive = raw.hasSuffix("'s") || raw.hasSuffix("s'")
            let norm = normalize(raw)
            let first = raw.first!
            let cap = first.isUppercase && raw.contains(where: { $0.isLowercase })
            let isNum = raw.allSatisfy(\.isNumber)
            out.append(Token(raw: raw, norm: norm, atStart: boundary, capitalized: cap, possessive: possessive, isNumber: isNum, gapPunct: gap))
            boundary = false
            gap = false
        }
        for ch in text {
            if ch.isLetter || ch.isNumber {
                pendingEnd = false
                cur.append(ch)
                continue
            }
            if ch == "'" || ch == "\u{2019}" {
                if !cur.isEmpty { cur.append("'"); continue }
                gap = true
                continue
            }
            let last = cur
            flush()
            switch ch {
            case "\n", "\r":
                boundary = true; pendingEnd = false; gap = true
            case ".", "!", "?":
                let n = normalize(last)
                let short = ch == "." && (shortForms.contains(n) || (n.count == 1 && !n.allSatisfy(\.isNumber)))
                if !short { pendingEnd = true }
                gap = true
            case ":", "(", "\"", "\u{201C}", "\u{2014}", "\u{2013}", "\u{2022}", ";", "|":
                boundary = true; gap = true
            case "-", "\u{2010}", "\u{2011}":
                break
            default:
                if ch.isWhitespace {
                    if pendingEnd { boundary = true; pendingEnd = false }
                } else {
                    gap = true
                    pendingEnd = false
                }
            }
        }
        flush()
        return out
    }

    /// Lowercase, no accents, no possessive, no apostrophes: "Dana's" → "dana", "O'Brien" → "obrien".
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if s.hasSuffix("'s") { s.removeLast(2) } else if s.hasSuffix("'") { s.removeLast() }
        s = s.replacingOccurrences(of: "'", with: "")
        if s.unicodeScalars.contains(where: { $0.value > 127 }) {
            s = s.folding(options: [.diacriticInsensitive], locale: nil)
        }
        return s
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) { if x == y { n += 1 } else { break } }
        return n
    }

    /// One substitution, insertion, deletion, or swap of neighbors apart.
    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        if x.count == y.count {
            let diff = (0..<x.count).filter { x[$0] != y[$0] }
            if diff.count == 1 { return true }
            if diff.count == 2, diff[1] == diff[0] + 1, x[diff[0]] == y[diff[1]], x[diff[1]] == y[diff[0]] { return true }
            return false
        }
        let (s, l) = x.count < y.count ? (x, y) : (y, x)
        var i = 0, j = 0, skipped = false
        while i < s.count, j < l.count {
            if s[i] == l[j] { i += 1; j += 1 } else { if skipped { return false }; skipped = true; j += 1 }
        }
        return true
    }

    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let weekdayShort: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "weds": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7]
    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let monthShort: [String: Int] = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12]

    /// A weekday's number (1 Sunday … 7 Saturday). Short forms ("Fri") only when capitalized.
    static func weekday(_ norm: String, capitalized: Bool) -> Int? {
        if let i = weekdayNames.firstIndex(of: norm) { return i + 1 }
        if norm.hasSuffix("s"), let i = weekdayNames.firstIndex(of: String(norm.dropLast())) { return i + 1 }
        return capitalized ? weekdayShort[norm] : nil
    }

    /// A month's number. "May" only before a number (it's usually the verb); short forms only when capitalized.
    static func month(_ norm: String, capitalized: Bool, nextIsNumber: Bool) -> Int? {
        if norm == "may" { return capitalized && nextIsNumber ? 5 : nil }
        if let i = monthNames.firstIndex(of: norm) { return capitalized ? i + 1 : nil }
        return capitalized ? monthShort[norm] : nil
    }

    /// Words that are never taken for names: the app's own words and section titles, titles of address, and "I".
    static let notNames: Set<String> = [
        "i", "im", "ill", "ive", "id", "ok", "okay", "mr", "mrs", "ms", "mx", "dr", "prof", "sir", "madam",
        "speaker", "speakers", "person", "verbose", "verbatim", "apple", "intelligence", "siri", "reminders",
        "transcript", "recording", "summary", "overview", "key", "points", "point", "action", "actions", "items", "item",
        "decisions", "decision", "next", "steps", "step", "questions", "question", "notes", "note", "today", "tomorrow",
        "tonight", "yesterday", "someday", "ideas", "idea", "top", "three", "none", "stated", "plan", "meeting", "journal",
        "thoughts", "thought", "brain", "dump", "template", "results", "result", "owner", "owners", "deadline", "deadlines",
        "follow", "followup", "up", "topics", "topic", "highlights", "takeaways", "risks", "blockers", "agenda", "attendees",
        "english", "internet", "email", "ai", "the", "a", "an", "and", "of", "for", "to", "in", "on", "at", "with",
    ]

    /// Ordinary words a model capitalizes in Title Case ("the Marketing Team", "Budget Review", "| Owner | Due |"): never
    /// taken for names. Words that are also first names (Mark, Will, Grace) aren't here.
    static let common: Set<String> = Set("""
        team teams group groups department committee board staff crew project projects program programs plan plans review reviews
        meeting meetings report reports budget budgets sales marketing design engineering product products launch strategy update
        updates process policy office offices center centre school schools church club house hall building room street road avenue
        park lake river city county state country north south east west central new old general annual final quarterly weekly daily
        monthly client clients customer customers partner partners vendor vendors account accounts finance financial operations
        support service services research development training safety quality health community event events conference workshop
        session sessions summit day night week month year season spring summer fall autumn winter holiday holidays morning afternoon
        evening weekend task tasks due owner status priority priorities goal goals risk risks issue issues item items action next
        steps follow check sign set call calls email emails phone text message letter note notes list draft drafts proposal
        contract invoice invoices payment payments order orders delivery shipping supplies inventory store shop market price prices
        cost costs revenue profit growth plan timeline schedule deadline milestone phase stage version release feature features
        app website site page pages content social media video videos photo photos podcast episode episodes show book books chapter
        class classes course lesson homework test exam grade student students teacher teachers parent parents family kids home
        kitchen garden yard car truck trip travel flight hotel dinner lunch breakfast party birthday wedding doctor appointment
        insurance bank tax taxes rent mortgage loan grant grants fund funding donation donations volunteer volunteers member members
        leadership management manager managers director executive president chair council government public private local national
        international global regional digital online remote virtual live open closed full part time first second third last main
        key big small major minor high low top bottom front back left right up down in out on off over under about overview summary
        decisions decision questions question answer answers ideas idea thoughts notes takeaways highlights background context
        introduction conclusion agenda attendees discussion topics topic points point recap minutes outcome outcomes result results
        feedback approval approved pending done complete completed open closed yes no tbd n/a na misc other general details detail
        study guide notes terms definitions vocabulary example examples summary host hosts guest guests interviewer interviewee
        narrator moderator panelist panel audience listener listeners viewer viewers caller callers participant participants
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    /// Words that are common in English and rare elsewhere: a source with few of them is in another language, where
    /// spelled-out numbers and month names won't match the output's digits and English names.
    static let englishMarkers: Set<String> = ["the", "and", "to", "of", "is", "a", "in", "that", "it", "you", "i", "we", "was", "for", "this", "so", "but", "with", "have", "are"]

    /// Words a sentence uses for structure, never for what it claims (Ask's citation check).
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "so", "of", "to", "in", "on", "at", "for", "with", "by", "from",
        "about", "as", "into", "over", "after", "before", "this", "that", "these", "those", "there", "here", "it", "its",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did", "will", "would",
        "could", "should", "can", "may", "might", "must", "shall", "not", "no", "yes", "they", "them", "their", "he",
        "she", "his", "her", "him", "we", "our", "us", "you", "your", "i", "me", "my", "who", "whom", "what", "which",
        "when", "where", "why", "how", "also", "said", "says", "say", "told", "mentioned", "mention", "noted", "talked",
        "discussed", "discuss", "speaker", "speakers", "recording", "transcript", "passage", "passages", "according",
        "some", "any", "all", "more", "most", "very", "just", "only", "than", "too", "out", "up", "down", "one", "two",
        "three", "like", "going", "want", "wants", "wanted", "need", "needs", "needed", "think", "thinks", "thought",
        "get", "gets", "got", "make", "makes", "made", "thing", "things", "really", "well", "still", "even", "back",
        "time", "way", "lot", "because", "while", "during", "between", "both", "each", "other", "such", "own", "same",
        "being", "next", "last", "week", "today", "tomorrow", "yesterday", "will", "plan", "plans", "planned",
        "decided", "decide", "agreed", "agree", "asked", "ask", "suggested", "suggest", "explained", "described", "shared",
        "felt", "feel", "feels", "believe", "believes", "seem", "seems", "until", "since", "around", "without", "within",
        "through", "again", "already", "soon", "later", "maybe", "perhaps", "probably", "actually",
    ]

    /// A word's stem for matching claims with passages: plural, past, and -ing endings off.
    static func stem(_ w: String) -> String {
        var s = w
        for (suf, rep) in [("ies", "y"), ("ing", ""), ("ed", ""), ("es", ""), ("s", ""), ("ly", "")] where s.count > suf.count + 3 && s.hasSuffix(suf) {
            s = String(s.dropLast(suf.count)) + rep
            break
        }
        return s
    }
}

// MARK: - Numbers

enum GroundingNumbers {
    /// A number as a set key, to four decimals.
    static func key(_ v: Double) -> Int64 { Int64((v * 10_000).rounded()) }

    enum Kind: Equatable { case plain, money, percent, ordinal, time(Int, Int), date, year, scaled }

    /// A number in generated text.
    struct Mention: Equatable {
        var text: String
        var value: Double
        var kind: Kind
        var approximate: Bool
        /// Whether to check it: small bare counts ("3 issues", "two options") aren't checked.
        var checked: Bool
    }

    static let units: [String: Int] = ["zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    static let teens: [String: Int] = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
        "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]
    static let scales: [String: Double] = ["hundred": 100, "thousand": 1_000, "grand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    /// A run of spelled-out number words: its value, where it sits, and whether it's an ordinal ("twenty-seventh").
    struct Spelled { var value: Double; var range: Range<Int>; var ordinal: Bool; var digits: [Int] }

    /// Reads spelled-out numbers from tokens. "three thirty" is two numbers (3 and 30), "twenty five" one (25), "two
    /// hundred and fifty" one (250), "a hundred" 100, "a dozen" 12.
    static func spelled(_ toks: [GroundingText.Token]) -> [Spelled] {
        enum Cat { case none, unit, teen, ten, scale }
        var out: [Spelled] = []
        var i = 0
        while i < toks.count {
            let w = toks[i].norm
            let aStart = (w == "a" || w == "an") && i + 1 < toks.count && ["hundred", "thousand", "million", "billion", "dozen"].contains(toks[i + 1].norm)
            guard aStart || (units[w] != nil && w != "oh") || teens[w] != nil || tens[w] != nil || ordinals[w] != nil || w == "dozen" else { i += 1; continue }
            var total = 0.0, current = 0.0
            var last = Cat.none
            var ordinal = false
            var run: [Int] = []
            var j = i
            if aStart { current = 1; last = .unit; j += 1 }
            scan: while j < toks.count {
                // Punctuation between words ends the number ("five, six").
                if j > i, toks[j].gapPunct, !(aStart && j == i + 1) { break }
                let t = toks[j].norm
                if !run.isEmpty {
                    // "five five five", "three oh five": a run of digits.
                    guard let u = units[t] else { break }
                    run.append(u); j += 1; continue
                }
                if let u = units[t] {
                    switch last {
                    case .none, .scale:
                        if t == "oh" { break scan }
                        current += Double(u)
                    case .ten:
                        current += Double(u)
                    case .unit:
                        guard j == i + 1, !aStart, let first = units[toks[i].norm] else { break scan }
                        run = [first, u]; j += 1; continue
                    case .teen:
                        break scan
                    }
                    last = .unit
                } else if let tn = teens[t] {
                    guard last == .none || last == .scale else { break }
                    current += Double(tn); last = .teen
                } else if let tn = tens[t] {
                    guard last == .none || last == .scale else { break }
                    current += Double(tn); last = .ten
                } else if let o = ordinals[t] {
                    guard last == .none || last == .scale || (last == .ten && o < 10) else { break }
                    current += Double(o); ordinal = true; j += 1
                    break
                } else if t == "dozen" {
                    current = max(current, 1) * 12; last = .scale
                } else if let s = scales[t] {
                    guard last != .none else { break }
                    if s >= 1_000 { total += max(current, 1) * s; current = 0 } else { current = max(current, 1) * s }
                    last = .scale
                } else if t == "and", last == .scale, j + 1 < toks.count, isNumberWord(toks[j + 1].norm) {
                    // "two hundred and fifty"
                } else {
                    break
                }
                j += 1
            }
            if j == i { i += 1; continue }
            if !run.isEmpty {
                out.append(Spelled(value: Double(run.reduce(0) { $0 * 10 + $1 }), range: i..<j, ordinal: false, digits: run))
            } else {
                out.append(Spelled(value: total + current, range: i..<j, ordinal: ordinal, digits: []))
            }
            i = j
        }
        return out
    }

    static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil || scales[w] != nil || ordinals[w] != nil
    }

    // "$1,200", "1,200.50", "3:30", "45%", "5k", "27th", "3 PM", "1.2 million". Group 1 currency, 2 integer, 3 decimals,
    // 4 minutes, 5 seconds, 6 suffix.
    private static let pattern = try! NSRegularExpression(pattern:
        #"(?<![\w.:,/])([$£€])?\s?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(?::(\d{2}))?(?::(\d{2}))?(?:\s?(%|percent\b|per cent\b|[kKmM]\b|bn\b|million\b|thousand\b|billion\b|hundred\b|grand\b|st\b|nd\b|rd\b|th\b|[aApP]\.?[mM]\b\.?|o'clock\b|o’clock\b))?"#)

    struct Digits { var range: NSRange; var text: String; var currency: Bool; var base: Double; var decimals: String?; var minute: Int?; var second: Int?; var suffix: String? }

    static func digits(_ text: String) -> [Digits] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let intPart = g(2) else { return nil }
            let dec = g(3)
            let base = Double(intPart.replacingOccurrences(of: ",", with: "") + (dec.map { "." + $0 } ?? "")) ?? .nan
            var suffix = g(6)?.lowercased()
            // "5 m" is a distance or minutes: k and m multiply only right after the number, after a currency sign or
            // as a capital ("$5k", "5M").
            if let s = suffix, ["k", "m"].contains(s) {
                let raw = g(6)!
                let attached = m.range(at: 6).location == m.range(at: dec == nil ? 2 : 3).location + m.range(at: dec == nil ? 2 : 3).length
                if !(attached && (g(1) != nil || raw == "K" || raw == "M")) { suffix = nil }
            }
            var r = m.range
            if g(6) != nil, suffix == nil {
                // Drop the suffix from what's shown.
                let end = m.range(at: 5).location != NSNotFound ? m.range(at: 5) : m.range(at: 4).location != NSNotFound ? m.range(at: 4) : m.range(at: 3).location != NSNotFound ? m.range(at: 3) : m.range(at: 2)
                r = NSRange(location: m.range.location, length: end.location + end.length - m.range.location)
            }
            var shown = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
            // "4:15 PM." ends a sentence; "4:15 p.m." keeps its period.
            if shown.hasSuffix("."), !shown.lowercased().hasSuffix(".m.") { shown.removeLast() }
            return Digits(range: r, text: shown, currency: g(1) != nil, base: base, decimals: dec, minute: g(4).flatMap { Int($0) }, second: g(5).flatMap { Int($0) }, suffix: suffix)
        }
    }

    static func multiplier(_ suffix: String?) -> Double? {
        switch suffix {
        case "k", "thousand", "grand": return 1_000
        case "m", "million": return 1_000_000
        case "bn", "billion": return 1_000_000_000
        case "hundred": return 100
        default: return nil
        }
    }

    static func isPM(_ s: String?) -> Bool? {
        guard let s, let f = s.first, s.contains("m"), f == "a" || f == "p" else { return nil }
        return f == "p"
    }

    // MARK: Source

    /// Every value the source's text supports, and its times of day (into `times`).
    static func sourceValues(_ text: String, tokens toks: [GroundingText.Token], times: inout Set<Int>) -> [Double] {
        var out: [Double] = []
        for d in digits(text) {
            guard d.base.isFinite else { continue }
            out.append(d.base)
            if let mult = multiplier(d.suffix) { out.append(d.base * mult) }
            if let m = d.minute, d.second == nil, m < 60, d.base <= 24, d.decimals == nil {
                var h = Int(d.base)
                if isPM(d.suffix) == true, h < 12 { h += 12 }
                times.insert((h % 12) * 60 + m)
            }
            // The minutes count as a number too ("30 minutes past" against "3:30").
            if let m = d.minute { out.append(Double(m)) }
            if d.minute == nil, let pm = isPM(d.suffix), d.base <= 12, d.decimals == nil {
                var h = Int(d.base); if pm, h < 12 { h += 12 }
                times.insert((h % 12) * 60)
            }
            if d.suffix == "o'clock" || d.suffix == "o’clock", d.base <= 12 { times.insert((Int(d.base) % 12) * 60) }
            // "3.30" is how some transcripts write half past three.
            if let dec = d.decimals, dec.count == 2, let m = Int(dec), m < 60, d.base <= 24 { times.insert((Int(d.base) % 12) * 60 + m) }
        }
        // Spelled out, and neighbors that make one number or a time: "twelve fifty" (1250), "nineteen ninety" (1990),
        // "three thirty" (3:30), "five five five" (555 and its pieces).
        let spelled = self.spelled(toks)
        var lastEnd = -1
        var lastValue: Double? = nil
        for s in spelled {
            out.append(s.value)
            if s.digits.count >= 2 {
                let ds = s.digits
                for a in 0..<ds.count { for b in (a + 1)..<min(ds.count, a + 10) + 1 where b - a >= 2 {
                    out.append(Double(ds[a..<b].reduce(0) { $0 * 10 + $1 }))
                } }
            }
            if let lv = lastValue, s.range.lowerBound == lastEnd {
                if lv >= 1, lv <= 99, s.value >= 0, s.value <= 99, s.value == s.value.rounded() { out.append(lv * 100 + s.value) }
                if lv >= 1, lv <= 12, s.value >= 0, s.value < 60 { times.insert((Int(lv) % 12) * 60 + Int(s.value)) }
            }
            lastEnd = s.range.upperBound
            lastValue = s.value
            // "five o'clock", "three p.m."
            if s.value >= 1, s.value <= 12, s.range.upperBound < toks.count {
                let n = toks[s.range.upperBound].norm
                if n == "oclock" || n == "pm" || n == "am" || (n == "o" && s.range.upperBound + 1 < toks.count && toks[s.range.upperBound + 1].norm == "clock") {
                    times.insert((Int(s.value) % 12) * 60)
                } else if n == "p" || n == "a", s.range.upperBound + 1 < toks.count, toks[s.range.upperBound + 1].norm == "m" {
                    times.insert((Int(s.value) % 12) * 60)
                }
            }
        }
        // Digit tokens next to each other ("3 30") and next to spelled numbers.
        for i in 1..<max(1, toks.count) where toks[i].isNumber && toks[i - 1].isNumber && !toks[i].gapPunct {
            if let a = Int(toks[i - 1].raw), let b = Int(toks[i].raw), a >= 1, a <= 12, b < 60, toks[i].raw.count == 2 { times.insert((a % 12) * 60 + b) }
        }
        // "half past three", "quarter to four", "noon", "midnight", and fractions for percentages.
        for (i, t) in toks.enumerated() {
            let n = t.norm
            func valueAt(_ k: Int) -> Int? {
                guard k < toks.count else { return nil }
                if let u = units[toks[k].norm] { return u }
                if let tn = teens[toks[k].norm] { return tn }
                return Int(toks[k].raw)
            }
            if (n == "half" || n == "quarter"), i + 2 < toks.count, ["past", "after", "to", "till", "til"].contains(toks[i + 1].norm), let h = valueAt(i + 2), h >= 1, h <= 12 {
                let past = toks[i + 1].norm == "past" || toks[i + 1].norm == "after"
                let m = n == "half" ? 30 : 15
                times.insert(past ? (h % 12) * 60 + m : ((h + 11) % 12) * 60 + (60 - m))
            }
            switch n {
            case "noon", "midday": times.insert(0)
            case "midnight": times.insert(0)
            case "half": out += [0.5, 50]
            case "quarter", "quarters": out += [0.25, 25, 75]
            case "third", "thirds": out += [33, 33.3, 33.33, 66, 67, 66.7]
            case "dozen": out.append(12)
            default: break
            }
        }
        return out
    }

    // MARK: Output

    static let approximators: Set<String> = ["about", "around", "roughly", "nearly", "almost", "approximately", "approx", "over", "under", "some", "maybe", "perhaps", "least", "most", "than", "upwards", "close", "ish"]

    /// The numbers generated text states, with whether each needs checking.
    static func mentions(_ text: String) -> [Mention] {
        let toks = GroundingText.tokenize(text)
        var out: [Mention] = []
        let ns = text as NSString
        for d in digits(text) {
            guard d.base.isFinite, d.second == nil else { continue }
            let before = ns.substring(to: d.range.location)
            let prevWords = GroundingText.tokenize(String(before.suffix(40))).suffix(2).map(\.norm)
            // "about 30%", "more than 40", "at least 12": the word right before, or two when it's "than" or "least".
            let qualifier = prevWords.last.map { ["than", "least", "to"].contains($0) ? prevWords : [$0] } ?? []
            let after = ns.substring(from: d.range.location + d.range.length)
            let nextWord = GroundingText.tokenize(String(after.prefix(20))).first?.norm ?? ""
            let approx = qualifier.contains { approximators.contains($0) } || before.hasSuffix("~")
            let prevMonth = prevWords.last.flatMap { GroundingText.month($0, capitalized: true, nextIsNumber: true) } != nil
            var kind: Kind = .plain
            var value = d.base
            if d.suffix == "%" || d.suffix == "percent" || d.suffix == "per cent" || nextWord == "percent" { kind = .percent }
            else if d.currency || ["dollars", "dollar", "bucks", "euros", "pounds"].contains(nextWord) { kind = .money; value = d.base * (multiplier(d.suffix) ?? 1) }
            else if let m = d.minute, m < 60, d.base <= 24, d.decimals == nil {
                var h = Int(d.base); if isPM(d.suffix) == true, h < 12 { h += 12 }
                kind = .time(h, m)
            } else if let pm = isPM(d.suffix), d.base <= 12, d.decimals == nil {
                var h = Int(d.base); if pm, h < 12 { h += 12 }
                kind = .time(h, 0)
            } else if d.suffix == "o'clock" || d.suffix == "o’clock" { kind = .time(Int(d.base), 0) }
            else if let mult = multiplier(d.suffix) { kind = .scaled; value = d.base * mult }
            else if ["st", "nd", "rd", "th"].contains(d.suffix ?? "") { kind = prevMonth || ["of"].contains(nextWord) ? .date : .ordinal }
            else if prevMonth { kind = .date }
            else if d.decimals == nil, d.base >= 1900, d.base <= 2100, !d.text.contains(",") { kind = .year }
            let small = d.decimals == nil && d.base <= 10
            let checked: Bool
            switch kind {
            case .plain, .ordinal: checked = !small
            // "100% agree" is a way of speaking.
            case .percent: checked = value != 100
            default: checked = true
            }
            out.append(Mention(text: d.text, value: value, kind: kind, approximate: approx, checked: checked))
        }
        let runs = spelled(toks)
        var skip = -1
        for (k, s) in runs.enumerated() where k != skip {
            // Two numbers in a row: "three thirty" is a time, "twelve fifty dollars" an amount, "nineteen ninety" a year.
            if k + 1 < runs.count, runs[k + 1].range.lowerBound == s.range.upperBound, !s.ordinal, !runs[k + 1].ordinal,
               s.value >= 1, s.value <= 99, runs[k + 1].value >= 10, runs[k + 1].value <= 99, s.digits.isEmpty, runs[k + 1].digits.isEmpty {
                let b = runs[k + 1]
                let after = b.range.upperBound < toks.count ? toks[b.range.upperBound].norm : ""
                let words = toks[s.range.lowerBound..<b.range.upperBound].map(\.raw).joined(separator: " ")
                let combined = s.value * 100 + b.value
                if ["dollars", "dollar", "bucks"].contains(after) || s.value > 12 || b.value >= 60 {
                    out.append(Mention(text: words, value: combined, kind: ["dollars", "dollar", "bucks"].contains(after) ? .money : .plain, approximate: false, checked: true))
                } else {
                    out.append(Mention(text: words, value: combined, kind: .time(Int(s.value), Int(b.value)), approximate: false, checked: true))
                }
                skip = k + 1
                continue
            }
            let next = s.range.upperBound < toks.count ? toks[s.range.upperBound].norm : ""
            let prev = s.range.lowerBound > 0 ? toks[s.range.lowerBound - 1].norm : ""
            let prev2 = s.range.lowerBound > 1 ? toks[s.range.lowerBound - 2].norm : ""
            let words = toks[s.range].map(\.raw).joined(separator: " ")
            // "hundreds of", "thousands": not a number anyone said.
            if ["hundreds", "thousands", "millions", "dozens"].contains(next) { continue }
            var kind: Kind = s.ordinal ? .ordinal : .plain
            if next == "percent" { kind = .percent }
            else if ["dollars", "dollar", "bucks", "euros", "pounds", "grand"].contains(next) { kind = .money }
            else if GroundingText.month(prev, capitalized: true, nextIsNumber: true) != nil || (prev == "the" && GroundingText.month(prev2, capitalized: true, nextIsNumber: true) != nil) { kind = .date }
            let approx = approximators.contains(prev) || approximators.contains(prev2)
            let checked: Bool
            switch kind {
            case .plain, .ordinal: checked = s.value > 10 && s.value != 100 && s.value != 1_000 || s.value > 1_000
            default: checked = true
            }
            out.append(Mention(text: words, value: s.value, kind: kind, approximate: approx, checked: checked))
        }
        return out
    }
}

// MARK: - Checks

enum Grounding {
    /// Checks generated text against its source: numbers, names, quotes, days, and [mm:ss] times past the end.
    static func check(_ output: String, against source: GroundingSource) -> [GroundingFinding] {
        let prepared = prepare(output)
        var found: [GroundingFinding] = []
        if source.isEnglish {
            found += numbers(prepared.text, source)
            found += dates(prepared.text, source)
        }
        found += names(prepared.text, source)
        found += quotes(prepared.text, source)
        if let d = source.duration, d > 0 {
            for a in prepared.anchors where a.seconds > d + 5 { found.append(GroundingFinding(kind: .timeRange, text: a.text)) }
        }
        return unique(found)
    }

    /// The output as prose to check: headings, list marks, checkboxes, bold, and labels ("Next steps:") off; [mm:ss]
    /// times collected and taken out.
    static func prepare(_ output: String) -> (text: String, anchors: [(text: String, seconds: Double)]) {
        var lines: [String] = []
        var anchors: [(String, Double)] = []
        for raw in output.components(separatedBy: .newlines) {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l.hasPrefix("#") { continue }
            if l.hasPrefix("**"), l.hasSuffix("**"), l.count > 4, !String(l.dropFirst(2).dropLast(2)).contains("**") { continue }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            if let r = l.range(of: #"^([-*•–]\s+)?(\[[ xX]\]\s+)?(\d{1,2}[.)]\s+)?"#, options: .regularExpression) { l.removeSubrange(r) }
            // A heading written as a line that ends with a colon.
            if l.hasSuffix(":"), l.split(separator: " ").count <= 6 { continue }
            // A label at the front: "Next steps: …", "Decision: …".
            if let r = l.range(of: #"^[A-Z][A-Za-z]*(\s[A-Za-z]+){0,3}:\s"#, options: .regularExpression) { l.removeSubrange(r) }
            while let r = l.range(of: #"\s*[\[(]\s*(\d{1,2}:)?\d{1,3}:\d{2}\s*[\])]"#, options: .regularExpression) {
                let inside = l[r].trimmingCharacters(in: CharacterSet(charactersIn: "[]() "))
                let parts = inside.split(separator: ":").compactMap { Double($0) }
                let secs = parts.reduce(0) { $0 * 60 + $1 }
                anchors.append((inside, secs))
                l.removeSubrange(r)
            }
            lines.append(l)
        }
        return (lines.joined(separator: "\n"), anchors)
    }

    static func numbers(_ text: String, _ source: GroundingSource) -> [GroundingFinding] {
        var out: [GroundingFinding] = []
        for m in GroundingNumbers.mentions(text) where m.checked {
            let ok: Bool
            switch m.kind {
            // "twelve fifty" can be a time or $1,250.
            case .time(let h, let min): ok = source.supportsTime(hour: h, minute: min) || (m.text.first?.isLetter == true && source.supportsNumber(m.value, approximate: false))
            case .year: ok = source.supportsNumber(m.value, approximate: false)
            default: ok = source.supportsNumber(m.value, approximate: m.approximate)
            }
            if !ok { out.append(GroundingFinding(kind: .number, text: m.text)) }
        }
        return out
    }

    static func dates(_ text: String, _ source: GroundingSource) -> [GroundingFinding] {
        let toks = GroundingText.tokenize(text)
        var out: [GroundingFinding] = []
        for (i, t) in toks.enumerated() {
            let nextIsNumber = i + 1 < toks.count && (toks[i + 1].isNumber || GroundingNumbers.ordinals[toks[i + 1].norm] != nil || toks[i + 1].raw.first?.isNumber == true)
            if let d = GroundingText.weekday(t.norm, capitalized: t.capitalized) {
                if !source.weekdays.contains(d) { out.append(GroundingFinding(kind: .date, text: display(t))) }
            } else if let m = GroundingText.month(t.norm, capitalized: t.capitalized, nextIsNumber: nextIsNumber) {
                if !source.months.contains(m) { out.append(GroundingFinding(kind: .date, text: display(t))) }
            } else if t.norm == "tomorrow" || t.norm == "yesterday" {
                if !source.has(t.norm) { out.append(GroundingFinding(kind: .date, text: t.raw.lowercased())) }
            }
        }
        return out
    }

    private static func display(_ t: GroundingText.Token) -> String {
        t.possessive ? String(t.raw.dropLast(2)) : t.raw.hasSuffix("'") ? String(t.raw.dropLast()) : t.raw
    }

    static func names(_ text: String, _ source: GroundingSource) -> [GroundingFinding] {
        let toks = GroundingText.tokenize(text)
        var out: [GroundingFinding] = []
        var i = 0
        while i < toks.count {
            guard toks[i].capitalized, !toks[i].isNumber else { i += 1; continue }
            var j = i
            while j + 1 < toks.count, toks[j + 1].capitalized, !toks[j + 1].atStart, !toks[j + 1].gapPunct { j += 1 }
            var candidates = Array(toks[i...j])
            // The first word of a sentence is only a name when it's possessive ("Dana's"): "Schedule", "Overall",
            // and "The" start sentences all the time. It still shows with the rest of a name the source uses it in.
            var lead: GroundingText.Token? = nil
            if candidates[0].atStart, !candidates[0].possessive {
                let first = candidates.removeFirst()
                if source.proper.contains(first.norm) { lead = first }
            }
            candidates = candidates.filter { c in
                c.norm.count >= 2 && !GroundingText.notNames.contains(c.norm) && !GroundingText.common.contains(c.norm)
                    && GroundingText.weekday(c.norm, capitalized: true) == nil
                    && GroundingText.monthNames.firstIndex(of: c.norm) == nil && GroundingText.monthShort[c.norm] == nil
                    && !c.raw.contains(where: \.isNumber)
            }
            if !candidates.isEmpty, candidates.contains(where: { !source.supportsName($0.norm) }) {
                out.append(GroundingFinding(kind: .name, text: ((lead.map { [$0] } ?? []) + candidates).map(display).joined(separator: " ")))
            }
            i = j + 1
        }
        return out
    }

    /// Fillers a transcript keeps and a quote drops.
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "hm", "mm", "mmm", "like", "you", "know"]

    static func quotes(_ text: String, _ source: GroundingSource) -> [GroundingFinding] {
        var out: [GroundingFinding] = []
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: #""([^"\n]{2,400})"|“([^”\n]{2,400})”"#)
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let inner = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
            // Numbers are checked on their own; fillers and number words don't decide a quote.
            let words = GroundingText.tokenize(inner).map(\.norm).filter { !$0.isEmpty && !fillers.contains($0) && !$0.allSatisfy(\.isNumber) && !GroundingNumbers.isNumberWord($0) }
            guard !words.isEmpty, !quoteSupported(words, source) else { continue }
            let shown = inner.split(separator: " ")
            let text = shown.count > 8 ? shown.prefix(7).joined(separator: " ") + "\u{2026}" : inner
            out.append(GroundingFinding(kind: .quote, text: text.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:"))))
        }
        return out
    }

    /// A quote of one or two words needs each word in the source; a longer one needs 80% of its words in order
    /// within a stretch of the source about its length.
    static func quoteSupported(_ q: [String], _ source: GroundingSource) -> Bool {
        if q.count <= 2 { return q.allSatisfy { source.has($0) || source.supportsName($0) } }
        let seq = source.sequence
        guard !seq.isEmpty else { return false }
        // Anchor on the rarest word the source has.
        let ranked = q.enumerated().filter { source.count($0.element) > 0 }.sorted { source.count($0.element) < source.count($1.element) }
        guard let anchor = ranked.first else { return false }
        let need = Int((Double(q.count) * 0.8).rounded(.up))
        var tries = 0
        for (pos, w) in seq.enumerated() where w == anchor.element {
            tries += 1
            if tries > 300 { break }
            let lo = max(0, pos - anchor.offset - 3), hi = min(seq.count, pos - anchor.offset + q.count + 3)
            guard lo < hi else { continue }
            var k = 0, matched = 0
            for s in seq[lo..<hi] where k < q.count {
                if s == q[k] { matched += 1; k += 1 }
                else if k + 1 < q.count, s == q[k + 1] { matched += 1; k += 2 }
            }
            if matched >= need { return true }
        }
        return false
    }

    static func unique(_ f: [GroundingFinding]) -> [GroundingFinding] {
        var seen: Set<String> = []
        return f.filter { seen.insert("\($0.kind.rawValue)|\($0.text.lowercased())|\($0.number ?? -1)").inserted }
    }

    // MARK: Ask answers

    struct CitedSentence { var text: String; var cites: [Int] }
    struct Citation { var number: Int; var text: String; var start: Double; var recordingDuration: Double? }

    /// Checks an Ask answer: its numbers, names, quotes, and days against the passages it cites (and the question
    /// and recording titles, for names); each sentence against its own passages' key words; each citation's time
    /// against its recording's length.
    static func checkAnswer(_ sentences: [CitedSentence], citations: [Citation], context: [String] = []) -> [GroundingFinding] {
        let all = GroundingSource(lines: citations.map { GroundingLine(start: $0.start, end: $0.start, text: $0.text) }, known: context)
        var found: [GroundingFinding] = []
        let text = sentences.map(\.text).joined(separator: " ")
        if all.isEnglish { found += numbers(text, all) + dates(text, all) }
        found += names(text, all) + quotes(text, all)
        let byNumber = Dictionary(citations.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        for s in sentences {
            let passages = s.cites.compactMap { byNumber[$0]?.text }
            guard !passages.isEmpty, let first = s.cites.first else { continue }
            if !claimSupported(s.text, by: passages) { found.append(GroundingFinding(kind: .citation, text: s.text, number: first)) }
        }
        for c in citations {
            if c.start < 0 || (c.recordingDuration.map { $0 > 0 && c.start > $0 + 2 } ?? false) {
                found.append(GroundingFinding(kind: .timeRange, text: "[\(c.number)]", number: c.number))
            }
        }
        return unique(found)
    }

    /// A sentence's key words (not structure words or numbers, four letters or more) against its passages: it fails
    /// only when it has four or more and none appear, or seven or more and only one does.
    static func claimSupported(_ sentence: String, by passages: [String]) -> Bool {
        let key = Set(GroundingText.tokenize(sentence).map(\.norm).filter { $0.count >= 4 && !GroundingText.stopwords.contains($0) && !$0.allSatisfy(\.isNumber) })
        guard key.count >= 4 else { return true }
        var stems: Set<String> = [], prefixes: Set<String> = []
        for p in passages {
            for t in GroundingText.tokenize(p) {
                stems.insert(GroundingText.stem(t.norm))
                if t.norm.count >= 5 { prefixes.insert(String(t.norm.prefix(5))) }
            }
        }
        let matched = key.filter { stems.contains(GroundingText.stem($0)) || ($0.count >= 5 && prefixes.contains(String($0.prefix(5)))) }.count
        if matched == 0 { return false }
        if key.count >= 7, matched <= 1 { return false }
        return true
    }
}

// MARK: - The note

/// The quiet line under generated text when a check found something: "Check this: 32% and “Harrisburg” aren't in the
/// transcript." nil when there's nothing to check.
enum GroundingNote {
    /// The most terms a note lists before "and 2 more".
    static let maxTerms = 3

    /// `source` finishes "aren't in …": "the transcript", "the passages it cites", "what you said", "your note".
    static func text(_ findings: [GroundingFinding], source: String = "the transcript") -> String? {
        guard !findings.isEmpty else { return nil }
        var sentences: [String] = []
        let terms = findings.filter { [.number, .name, .quote, .date, .priority].contains($0.kind) }.map { f -> String in
            switch f.kind {
            case .name, .quote, .priority: return "\u{201C}\(f.text)\u{201D}"
            default: return f.text
            }
        }
        if !terms.isEmpty {
            let shown = Array(terms.prefix(maxTerms))
            let more = terms.count - shown.count
            let list = more > 0 ? series(shown + ["\(more) more"]) : series(shown)
            let one = terms.count == 1
            sentences.append("\(list) \(one ? "isn\u{2019}t" : "aren\u{2019}t") in \(source).")
        }
        let cites = findings.filter { $0.kind == .citation }.compactMap(\.number)
        if !cites.isEmpty {
            let list = series(Array(Set(cites)).sorted().map { "[\($0)]" })
            sentences.append(cites.count == 1 ? "\(list) doesn\u{2019}t mention what its sentence says." : "\(list) don\u{2019}t mention what their sentences say.")
        }
        let ranges = findings.filter { $0.kind == .timeRange }
        if !ranges.isEmpty {
            let cited = ranges.filter { $0.number != nil }.map(\.text)
            let anchors = ranges.filter { $0.number == nil }.map(\.text)
            if !cited.isEmpty { sentences.append("\(series(cited)) \(cited.count == 1 ? "points" : "point") past the end of \(cited.count == 1 ? "its recording" : "their recordings").") }
            if !anchors.isEmpty { sentences.append("\(series(anchors)) \(anchors.count == 1 ? "is" : "are") past the end of the recording.") }
        }
        let days = findings.filter { $0.kind == .dayNotSaid }.map { "\u{201C}\($0.text)\u{201D}" }
        if !days.isEmpty {
            let shown = Array(days.prefix(2))
            let list = days.count > 2 ? shown.joined(separator: ", ") + ", and \(days.count - 2) more" : shown.joined(separator: " or ")
            sentences.append("You didn\u{2019}t say a day for \(list).")
        }
        if findings.contains(where: { $0.kind == .topNotNamed }) { sentences.append("You didn\u{2019}t name a top three.") }
        guard var first = sentences.first else { return nil }
        if first.hasPrefix("You ") { first = "you " + first.dropFirst(4) }
        sentences[0] = first
        return "Check this: " + sentences.joined(separator: " ")
    }

    /// "A", "A and B", "A, B, and C".
    static func series(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}

/// Results checked once per text: a view redraws often, and a long transcript's index takes a few milliseconds.
final class GroundingMemo: @unchecked Sendable {
    static let shared = GroundingMemo()
    private var cache: [Int: [GroundingFinding]] = [:]
    private let lock = NSLock()

    func findings(_ key: Int, _ compute: () -> [GroundingFinding]) -> [GroundingFinding] {
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let value = compute()
        lock.lock()
        if cache.count > 128 { cache.removeAll() }
        cache[key] = value
        lock.unlock()
        return value
    }
}
