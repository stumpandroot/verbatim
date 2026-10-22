import Foundation

/// Checks that a model cleanup kept what the person said, before it's pasted. Foundation only, so the iPhone
/// target can share it later.
///
/// Rejects the output when any of these changed between the raw text and the cleanup:
/// - negations (not, no, never, and every "n't")
/// - numbers, with spelled-out numbers read as digits on both sides ("five hundred" = "500", "eleven thirty" = "11:30")
/// - currency amounts and am/pm
/// - URLs, email addresses, and @handles
/// - capitalized names that aren't at the start of a sentence
///
/// It also rejects output under the level's shrink limit (50%, or 40% for Polished) or over its growth limit of
/// the input's length, and output that
/// looks cut off. A spoken self-correction ("at 2, actually 3", "scratch that") allows the earlier version to
/// be dropped, never a new value to appear. Reasons never include any of the text.
enum MeaningCheck {
    struct Limits {
        /// Longest output allowed, as a multiple of the input's length.
        var maxGrowth: Double
        /// Shortest output allowed, as a multiple of the input's length.
        var minShrink: Double = 0.5
        /// Dictionary spellings the model was told to use; they may replace a name that sounds like them.
        var vocabulary: [String] = []
        /// The style may drop a final period (very casual messages, an email's sign-off line).
        var finalPunctuationOptional = false

        static let clean = Limits(maxGrowth: 1.6)
        /// Polished may shrink to 40%, like `FlowCleanup.guardProblem`'s word limit: rambling speech loses its
        /// filler phrases ("so basically", "kind of", "you know what I mean") and false starts, and a 50% floor
        /// rejected tightening that kept every fact. Facts are still checked one by one below.
        static let polished = Limits(maxGrowth: 2.0, minShrink: 0.4)
    }

    /// Why the output can't be trusted, or nil when it keeps the meaning.
    static func problem(raw: String, output: String, limits: Limits) -> String? {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty else { return "cleanup returned nothing" }
        let cues = Cues(r)
        if r.count >= 24 {
            let ratio = Double(o.count) / Double(r.count)
            // "Scratch that" may legitimately remove most of what was said.
            if ratio < limits.minShrink && !cues.wipes { return "cleanup dropped too much of the text" }
            if ratio > limits.maxGrowth { return "cleanup grew the text past \(Int((limits.maxGrowth * 100).rounded()))%" }
        }
        if looksTruncated(raw: r, output: o, requireFinalPunctuation: !limits.finalPunctuationOptional) { return "cleanup looks cut off" }

        let a = Facts(r), b = Facts(o)
        if b.negations > a.negations { return "a negation was added" }
        if a.negations - b.negations > cues.negationBudget { return "a negation was dropped" }
        if let p = numbersProblem(a, b, budget: cues.budget) { return p }
        if let p = compare(a.currencies, b.currencies, budget: cues.budget) { return "a currency \(p)" }
        if let p = compare(a.meridiems, b.meridiems, budget: cues.budget) { return "am or pm \(p)" }
        if let p = spokenFormProblem(raw: r, a.links, b.links, budget: cues.budget) { return "a link or email \(p)" }
        if let p = spokenFormProblem(raw: r, a.handles, b.handles, budget: cues.budget) { return "an @handle \(p)" }
        if let p = namesProblem(a, b, raw: r, vocabulary: limits.vocabulary, budget: cues.budget) { return p }
        return nil
    }

    /// True when the output seems to stop early: it ends partway through one of the raw text's words, or (when
    /// `requireFinalPunctuation`) the raw text ends a sentence and the output doesn't. A last line that is a
    /// list item may end without punctuation.
    static func looksTruncated(raw: String, output: String, requireFinalPunctuation: Bool = true) -> Bool {
        let r = trimmedTail(raw), o = trimmedTail(output)
        guard let rl = r.last, let ol = o.last else { return false }
        let terminal: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        if requireFinalPunctuation {
            let lastLine = o.components(separatedBy: "\n").last ?? o
            let listLine = lastLine.range(of: #"^\s*(?:\d{1,3}[.)]|[-*•])\s"#, options: .regularExpression) != nil
            if terminal.contains(rl) && !terminal.contains(ol) && !listLine { return true }
            if [",", ":", ";", "-", "—"].contains(ol) && rl != ol { return true }
        }
        guard !terminal.contains(ol) else { return false }
        let rawWords = Set(letterWords(raw))
        let tail = String(o.reversed().prefix(while: { $0.isLetter }).reversed()).lowercased()
        return tail.count >= 2 && !rawWords.contains(tail) && rawWords.contains { $0.count > tail.count && $0.hasPrefix(tail) }
    }

    // MARK: Comparisons

    /// "was added or changed" when `out` has something `raw` doesn't; "was dropped" when more than `budget` went missing.
    private static func compare(_ raw: [String], _ out: [String], budget: Int) -> String? {
        if !subtract(out, raw).isEmpty { return "was added or changed" }
        if subtract(raw, out).count > budget { return "was dropped" }
        return nil
    }

    /// Multiset difference: the items of `a` left after removing one match from `b` for each.
    private static func subtract(_ a: [String], _ b: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for x in b { counts[x, default: 0] += 1 }
        var left: [String] = []
        for x in a {
            if let n = counts[x], n > 0 { counts[x] = n - 1 } else { left.append(x) }
        }
        return left
    }

    private static func numbersProblem(_ a: Facts, _ b: Facts, budget: Int) -> String? {
        let added = subtract(b.numbers, a.numbers)
        // A list the model numbered ("1. The photos") may stand in for spoken "one… two…" or "first… second…".
        let dropped = subtract(subtract(a.numbers, b.numbers), b.listMarkers)
        if added.isEmpty && dropped.count <= budget { return nil }
        // Same digits in the same order, grouped differently: "five oh five" → "5:05", a phone number.
        if !a.digitStream.isEmpty && a.digitStream == b.digitStream { return nil }
        return added.isEmpty ? "a number was dropped" : "a number was added or changed"
    }

    /// Links and handles: each one in the raw text must survive, and each one in the output must come from the
    /// raw text, spoken or written ("tim at example dot com" may become tim@example.com).
    private static func spokenFormProblem(raw: String, _ a: [String], _ b: [String], budget: Int) -> String? {
        let squashed = squash(raw.lowercased().replacingOccurrences(of: #"\b(?:dot|at|slash|colon|dash|hyphen|underscore|period)\b"#, with: "", options: .regularExpression))
        let added = subtract(b, a).filter { link in
            let s = squash(link)
            return s.isEmpty || !squashed.contains(s)
        }
        if !added.isEmpty { return "was added or changed" }
        if subtract(a, b).count > budget { return "was dropped" }
        return nil
    }

    private static func namesProblem(_ a: Facts, _ b: Facts, raw: String, vocabulary: [String], budget: Int) -> String? {
        // Title case, all caps, or a language that capitalizes nouns: capitals don't mark names here.
        guard !a.mostlyCapitalized else { return nil }
        let vocab = Set(vocabulary.flatMap { v in
            v.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        })
        let missing = Set(a.names).filter { name in
            if b.words.contains(name) { return false }
            // A Dictionary spelling that sounds like it ("Kathy" → "Cathy") is the point of the vocabulary list.
            return !vocab.contains { v in b.words.contains(v) && similar(v, name) }
        }
        if missing.count > budget { return "a name was dropped or changed" }
        guard !b.mostlyCapitalized else { return nil }
        let rawSquashed = squash(raw.lowercased())
        let added = Set(b.names).filter { name in
            !a.words.contains(name) && !vocab.contains(name) && !rawSquashed.contains(squash(name))
        }
        if !added.isEmpty { return "a name was added" }
        return nil
    }

    // MARK: Facts

    /// What the check compares, read from one text.
    private struct Facts {
        var negations = 0
        var numbers: [String] = []
        var listMarkers: [String] = []
        var digitStream = ""
        var currencies: [String] = []
        var meridiems: [String] = []
        var links: [String] = []
        var handles: [String] = []
        /// Every word, lowercased, without a possessive 's.
        var words: Set<String> = []
        /// Capitalized words that aren't at the start of a sentence, lowercased.
        var names: [String] = []
        var mostlyCapitalized = false

        init(_ text: String) {
            var t = text.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            links = MeaningCheck.matches(MeaningCheck.linkRegex, in: t).map(MeaningCheck.normalizedLink)
            t = MeaningCheck.linkRegex.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " ")
            handles = MeaningCheck.matches(MeaningCheck.handleRegex, in: t).map { $0.lowercased() }
            t = MeaningCheck.handleRegex.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " ")

            let markers = MeaningCheck.listMarkerRegex.matches(in: t, range: NSRange(location: 0, length: (t as NSString).length))
            listMarkers = markers.map { MeaningCheck.normalizedNumber((t as NSString).substring(with: $0.range(at: 1))) }
            t = MeaningCheck.listMarkerRegex.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")

            let lower = t.lowercased()
            let withoutCues = lower.replacingOccurrences(of: MeaningCheck.negationCuePattern, with: " ", options: .regularExpression)
            negations = MeaningCheck.tokens(withoutCues).filter { MeaningCheck.negationWords.contains($0) || $0.hasSuffix("n't") }.count

            let parsed = NumberWords.extract(lower)
            numbers = parsed.values
            digitStream = parsed.stream
            currencies = MeaningCheck.currencies(in: lower)
            meridiems = MeaningCheck.meridiems(in: lower)

            let ns = t as NSString
            var total = 0, capitalized = 0
            for m in MeaningCheck.wordRegex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let w = ns.substring(with: m.range)
                let key = MeaningCheck.withoutPossessive(w.lowercased())
                words.insert(key)
                total += 1
                guard let first = w.first, first.isUppercase else { continue }
                capitalized += 1
                if MeaningCheck.startsSentence(ns, at: m.range.location) { continue }
                if key == "i" || key.hasPrefix("i'") || MeaningCheck.fillers.contains(key) { continue }
                names.append(key)
            }
            mostlyCapitalized = total >= 4 && Double(capitalized) / Double(total) > 0.6
        }
    }

    /// Delete and start-over cues (`SpokenCorrections`): anything said before them may go. Lowercase text.
    static let wipePattern = #"\b(?:scratch (?:all )?that|never ?mind|forget that|strike that|delete (?:all )?that|skip that|cancel that|undo that|remove that|erase (?:all )?that|delete everything|erase everything|clear that|start over|start again|delete the (?:last|previous) (?:\w+ )?(?:sentences?|words?|paragraphs?)|remove the (?:last|previous) (?:\w+ )?(?:sentences?|words?|paragraphs?)|erase the (?:last|previous) (?:\w+ )?(?:sentences?|words?|paragraphs?))\b"#

    /// Correction phrases. Each one lets one earlier value of a kind be dropped; "scratch that" lets any go.
    private struct Cues {
        var budget = 0
        /// Negations are stricter: "actually" alone never excuses a dropped "not".
        var negationBudget = 0
        /// "Scratch that", "never mind": anything said before may go.
        var wipes = false

        init(_ raw: String) {
            // Settings › Understand spoken corrections off: nothing said excuses a dropped value.
            guard SpokenCorrections.enabled else { return }
            let l = raw.lowercased()
            func count(_ pattern: String) -> Int {
                guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
                return re.numberOfMatches(in: l, range: NSRange(location: 0, length: (l as NSString).length))
            }
            if count(MeaningCheck.wipePattern) > 0 {
                budget = .max; negationBudget = .max; wipes = true; return
            }
            let strong = count(#"\b(?:no,? wait|wait,? no|no,? sorry|actually,? no|actually,? wait|i mean|or rather|let me rephrase|let me fix that|correction)\b"#)
            let soft = count(#"\b(?:actually|make that|make it|sorry|wait|instead)\b"#)
            budget = strong + soft
            negationBudget = strong
        }
    }

    // MARK: Pieces

    fileprivate static let negationWords: Set<String> = ["not", "no", "never", "nobody", "nothing", "none", "nor", "neither", "nowhere", "cannot", "nope", "nah"]
    /// Correction phrases that contain a negation word without negating anything ("no wait", "never mind").
    fileprivate static let negationCuePattern = #"\b(?:no,?\s+(?:wait|sorry|actually|i mean|make that|scratch that)|(?:wait|actually|sorry),?\s+no|never\s?mind)\b"#
    fileprivate static let fillers: Set<String> = ["um", "uh", "like", "so", "well", "okay", "ok", "yeah", "basically", "actually", "right", "hmm", "er", "ah", "oh"]

    fileprivate static let linkRegex = try! NSRegularExpression(pattern:
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|\b(?:https?://|www\.)[^\s<>"]+|\b[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:com|org|net|io|co|ai|app|dev|edu|gov|me|us|uk|ca|de|fr|ly|so|xyz|tv|fm)\b(?:/[^\s<>"]*)?"#)
    fileprivate static let handleRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9._%+-])@[A-Za-z0-9_]{2,}"#)
    fileprivate static let listMarkerRegex = try! NSRegularExpression(pattern: #"^[ \t]*(\d{1,3})[.)][ \t]+"#, options: [.anchorsMatchLines])
    fileprivate static let wordRegex = try! NSRegularExpression(pattern: #"\p{L}[\p{L}\p{M}'\-]*"#)
    private static let tokenRegex = try! NSRegularExpression(pattern: #"\p{L}+(?:'\p{L}+)*|\d+"#)

    fileprivate static func matches(_ re: NSRegularExpression, in s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    fileprivate static func tokens(_ s: String) -> [String] { matches(tokenRegex, in: s) }

    private static func letterWords(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    private static func squash(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber }) }

    fileprivate static func withoutPossessive(_ w: String) -> String {
        w.hasSuffix("'s") && w.count > 2 ? String(w.dropLast(2)) : w
    }

    fileprivate static func normalizedLink(_ s: String) -> String {
        var t = s.lowercased()
        while let last = t.last, ".,;:!?)]'\"".contains(last) { t.removeLast() }
        for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        if t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// "20,000" → "20000", "05" → "5", "3.50" → "3.5".
    fileprivate static func normalizedNumber(_ s: String) -> String {
        let digits = s.replacingOccurrences(of: ",", with: "")
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        var whole = String(parts.first ?? "").drop(while: { $0 == "0" })
        if whole.isEmpty { whole = "0" }
        guard parts.count > 1 else { return String(whole) }
        var frac = String(parts[1])
        while frac.hasSuffix("0") { frac.removeLast() }
        return frac.isEmpty ? String(whole) : "\(whole).\(frac)"
    }

    /// True when the word at `location` starts a sentence, a line, or a list item.
    fileprivate static func startsSentence(_ ns: NSString, at location: Int) -> Bool {
        var i = location - 1
        while i >= 0 {
            guard let scalar = Unicode.Scalar(ns.character(at: i)) else { return false }
            let ch = Character(scalar)
            if ch == "\n" { return true }
            if ch == " " || ch == "\t" || "\"“”'‘’([*•-".contains(ch) { i -= 1; continue }
            return ".!?:".contains(ch)
        }
        return true
    }

    private static let currencyPatterns: [(String, String)] = [
        (#"\$|\b(?:dollars?|bucks?|usd)\b"#, "usd"),
        (#"€|\b(?:euros?|eur)\b"#, "eur"),
        // "Pounds" may be money or weight, so £ and lb count as the same kind.
        (#"£|\b(?:pounds?|quid|gbp|sterling|lbs?)\b"#, "gbp"),
        (#"¥|\b(?:yen|jpy)\b"#, "jpy"),
        (#"₹|\b(?:rupees?|inr)\b"#, "inr"),
        (#"¢|\bcents?\b"#, "cent"),
    ]

    fileprivate static func currencies(in lower: String) -> [String] {
        var out: [String] = []
        let range = NSRange(location: 0, length: (lower as NSString).length)
        for (pattern, kind) in currencyPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out += Array(repeating: kind, count: re.numberOfMatches(in: lower, range: range))
        }
        return out
    }

    /// "am" and "pm" after a number ("3 pm", "three p.m.", "5:30pm"); never the "am" in "I am".
    fileprivate static func meridiems(in lower: String) -> [String] {
        var t = lower.replacingOccurrences(of: #"\b([ap])\.\s?m\b\.?"#, with: "$1m", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\d)\s?([ap])\s?m\b"#, with: "$1 $2m", options: .regularExpression)
        let toks = tokens(t)
        var out: [String] = []
        for (i, tok) in toks.enumerated() where (tok == "am" || tok == "pm") && i > 0 {
            let prev = toks[i - 1]
            if prev.first?.isNumber == true || NumberWords.isNumberWord(prev) || prev == "o'clock" || prev == "oclock" { out.append(tok) }
        }
        return out
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count] <= max(1, min(x.count, y.count) / 3)
    }

    private static func trimmedTail(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.last, last.isWhitespace || "\"')]}”’»*_`".contains(last) { t = t.dropLast() }
        return String(t)
    }
}

/// Reads English number words as digits, so "twenty thousand" and "20,000" compare equal.
enum NumberWords {
    private static let units: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    private static let teens: [String: Int] = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                                               "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    private static let ordinals: [String: Int] = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
                                                  "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
                                                  "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
                                                  "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
                                                  "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    /// "the one I like": "one" as a pronoun, not a count.
    private static let pronounBefore: Set<String> = ["the", "no", "any", "some", "every", "each", "this", "that", "which"]
    private static let tokenRegex = try! NSRegularExpression(pattern: #"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|[a-z]+(?:'[a-z]+)?"#)

    static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil || w == "hundred" || scales[w] != nil
    }

    /// Every number in `lower` (lowercased text) as normalized digits, plus all their digits in order.
    static func extract(_ lower: String) -> (values: [String], stream: String) {
        let text = lower.replacingOccurrences(of: #"(?<=[a-z])-(?=[a-z])"#, with: " ", options: .regularExpression)
        let ns = text as NSString
        let toks = tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        var values: [String] = []
        var stream = ""
        var total = 0, small = 0, active = false

        func emit(_ digits: String) {
            values.append(MeaningCheck.normalizedNumber(digits))
            stream += digits.filter { $0.isNumber }
        }
        func flush() {
            if active { emit(String(total + small)) }
            total = 0; small = 0; active = false
        }
        /// Whether `v` (1–90) continues the number being read ("twenty" + "five") or starts a new one ("eleven" | "thirty").
        func canTake(_ v: Int) -> Bool {
            guard active else { return true }
            let last2 = small % 100
            let hasHigher = small >= 100 || total > 0
            if v < 10 { return (last2 == 0 && hasHigher) || (last2 >= 20 && last2 % 10 == 0) }
            return last2 == 0 && hasHigher
        }
        func add(_ v: Int) {
            if !canTake(v) { flush() }
            small += v; active = true
        }

        var i = 0
        while i < toks.count {
            let w = toks[i]
            let next = i + 1 < toks.count ? toks[i + 1] : ""
            let prev = i > 0 ? toks[i - 1] : ""
            if w.first?.isNumber == true {
                flush(); emit(w.replacingOccurrences(of: ",", with: ""))
            } else if let v = units[w] {
                if v == 0 { flush(); emit("0") }
                else if v == 1 && !active && pronounBefore.contains(prev) { flush() }
                else { add(v) }
            } else if let v = teens[w] ?? tens[w] {
                add(v)
            } else if w == "hundred" {
                small = max(small, 1) * 100; active = true
            } else if let m = scales[w] {
                total += max(small, 1) * m; small = 0; active = true
            } else if let v = ordinals[w] {
                add(v); flush()
            } else if w == "hundredth" {
                small = max(small, 1) * 100; active = true; flush()
            } else if w == "thousandth" {
                total += max(small, 1) * 1_000; small = 0; active = true; flush()
            } else if (w == "oh" || w == "o") && active && small < 100, let u = units[next], u > 0 {
                flush(); emit("0")   // "five oh five"
            } else if w == "point" && active && units[next] != nil {
                var digits = ""
                var j = i + 1
                while j < toks.count, let u = units[toks[j]] { digits += String(u); j += 1 }
                let whole = total + small
                total = 0; small = 0; active = false
                emit("\(whole).\(digits)")
                i = j
                continue
            } else if w == "and" && active && (units[next] != nil || teens[next] != nil || tens[next] != nil) {
                // "one hundred and five": keep reading.
            } else if w == "a" && (next == "hundred" || scales[next] != nil) {
                // "a hundred", "a thousand": the scale word counts as one of it.
            } else {
                flush()
            }
            i += 1
        }
        flush()
        return (values, stream)
    }
}
