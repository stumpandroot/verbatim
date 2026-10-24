import Foundation

/// Spoken self-corrections, applied by rules so they work whether or not a language model runs: "meet at 2,
/// actually 3" → "meet at 3", "We should go. Scratch that." → "", "delete the last sentence", "let me start over".
///
/// Pure string work, Foundation only. Shared by the Mac, the iPhone app, and the iPhone keyboard (which runs it on
/// the live words to strike out what a correction removes). Runs at Clean and Polished as the first word-changing
/// step of `CleanupPrepass.clean`, never at Literal.
///
/// Delete cues remove the sentence before them, or the clause since the last comma when the cue follows a comma:
/// "scratch that", "delete that", "forget that", "strike that", "skip that", "never mind", "cancel that",
/// "undo that", "remove that", "erase that". Explicit commands: "delete the last sentence", "delete the last two
/// sentences", "delete the last word", "delete the last 3 words", "delete the last paragraph" ("remove" and
/// "erase" work too). Start-over cues clear everything before them: "start over", "let me start over", "let's
/// start over", "start again", "scratch all that", "delete all that", "delete everything", "erase everything",
/// "clear that". All of these count only when they end a clause (end of text, punctuation, or a line break follows)
/// and aren't the object of a verb ("don't delete that.", "we need to start over.").
///
/// Replace cues ("actually", "no wait", "I mean", "or rather", "sorry", and the rest) keep the version after the
/// cue. Rules, most specific first:
/// 1. A value after the cue (number, time, money, percent, day, month) replaces the last value of the same kind
///    before it: "at 2, actually 3" → "at 3".
/// 2. A first word that also appears before the cue anchors the replacement: "send it to Sarah, no wait, send it to
///    Jake" → "send it to Jake".
/// 3. A capitalized name replaces the last name: "tell Sarah, I mean Jake" → "tell Jake".
/// 4. Strong cues ("no wait", "or rather", "correction", "let me fix that", "actually no", "wait no", "no sorry")
///    replace the clause before them. Weak cues ("actually", "I mean", "sorry", "make that") with no match above
///    leave the text as spoken.
enum SpokenCorrections {

    // MARK: Setting

    /// Settings › Understand spoken corrections. On unless turned off.
    static let enabledKey = "flow.spokenCorrections"
    /// How many small-correction notices were shown (the first few teach the feature, then they stop).
    static let noticeCountKey = "flow.spokenCorrections.notices"
    static let smallNoticeLimit = 5

    /// The App Group on iPhone, so the app, where cleanup runs, and the keyboard, which shows the live words,
    /// read the same switch. Standard defaults on the Mac.
    static var store: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: "group.co.stumpandroot.verbatim.ios") ?? .standard
        #else
        return .standard
        #endif
    }

    static var enabled: Bool {
        get { store.object(forKey: enabledKey) as? Bool ?? true }
        set { store.set(newValue, forKey: enabledKey) }
    }

    // MARK: Output

    struct Correction: Equatable {
        enum Kind: Equatable { case delete, startOver, replace }
        var kind: Kind
        /// The cue as spoken ("scratch that", "no wait").
        var cue: String
        /// The words taken out, not counting the cue.
        var removed: String
        /// The words that took their place, for a replacement; nil for a deletion.
        var replacement: String?
        /// Whole sentences removed (a deletion or start over).
        var sentences: Int
    }

    /// A piece of the original text and how a correction treats it, for the live words.
    struct Span: Equatable {
        enum Style: Equatable { case kept, removed, inserted }
        var text: String
        var style: Style
    }

    struct Result: Equatable {
        var text: String
        var corrections: [Correction]
        /// The original text in order: kept, removed (struck out), and inserted pieces.
        var spans: [Span]
        var changed: Bool { !corrections.isEmpty || spans.contains { $0.style != .kept } }
    }

    /// Applies every spoken correction in `s`. Returns `s` unchanged (and no corrections) when there are none.
    static func apply(_ s: String) -> Result {
        var e = Engine(s)
        e.run()
        return Result(text: e.render(), corrections: e.corrections, spans: e.spans())
    }

    /// The corrected text only.
    static func text(_ s: String) -> String { apply(s).text }

    // MARK: Notices

    /// True when a correction is big enough that it should always be announced: a start over, or a deletion of
    /// two or more sentences.
    static func isBig(_ corrections: [Correction]) -> Bool {
        corrections.contains { $0.kind == .startOver }
            || corrections.filter { $0.kind == .delete }.reduce(0) { $0 + $1.sentences } >= 2
    }

    /// Whether to announce these corrections, counting small ones: big corrections always, small ones the first
    /// `smallNoticeLimit` times. Corrections that removed nothing visible aren't announced.
    static func takeNotice(for corrections: [Correction]) -> Bool {
        let visible = corrections.filter { !$0.removed.isEmpty }
        guard !visible.isEmpty else { return false }
        if isBig(visible) { return true }
        let shown = store.integer(forKey: noticeCountKey)
        guard shown < smallNoticeLimit else { return false }
        store.set(shown + 1, forKey: noticeCountKey)
        return true
    }

    /// One line that says what changed: "Removed “meet at 2.”", "Changed “2” to “3.”", "Started over."
    static func summary(_ corrections: [Correction]) -> String {
        let visible = corrections.filter { !$0.removed.isEmpty }
        guard let c = visible.first else { return "" }
        if visible.count > 1 {
            if visible.contains(where: { $0.kind == .startOver }) { return "You started over, and Verbose kept only what came after." }
            return "Verbose made \(visible.count) spoken corrections."
        }
        switch c.kind {
        case .startOver: return "You started over. Removed “\(short(c.removed))”"
        case .delete: return "Removed “\(short(c.removed))”"
        case .replace:
            if let r = c.replacement, !r.isEmpty { return "Changed “\(short(c.removed, 28))” to “\(short(r, 28))”" }
            return "Removed “\(short(c.removed))”"
        }
    }

    static func short(_ s: String, _ limit: Int = 40) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:")))
            .replacingOccurrences(of: "\n", with: " ")
        guard t.count > limit else { return t }
        return String(t.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Live words

    /// Live words split for display: kept pieces in ink, removed pieces struck out, inserted pieces in ink. Only
    /// the last `limit` characters, cut at a word.
    ///
    /// With a limit, the rules run on the last few sentences (`liveTail`), not the whole text, so an update costs
    /// the same however long the dictation gets. The result is the same as running them on the whole text
    /// (`SpokenCorrectionsChecks`).
    static func liveSpans(_ text: String, limit: Int = 0) -> [Span] {
        guard limit > 0 else { return apply(text).spans }
        return lastCharacters(liveTail(text, limit: limit).spans, limit: limit)
    }

    /// The spans `liveSpans` cuts its last `limit` characters from, and where in `text` the rules started.
    ///
    /// The window starts at a sentence start, more than `limit` characters and at least three sentences from the
    /// end. Corrections reach back a sentence or a clause, so the window's spans match a run on the whole text
    /// when its first sentence comes through untouched (no cue in it, nothing in it removed): no rule reached past
    /// it. When one did, the window grows. A start over removes everything before it whatever came earlier, so a
    /// window whose first cue is a start over stands alone too; when an earlier cue in the window gets in the way,
    /// the whole text is searched for the start-over cue only, and the rules run from that sentence.
    static func liveTail(_ text: String, limit: Int) -> (spans: [Span], from: String.Index) {
        var sentences = 3
        while true {
            let start = sentenceStart(in: text, keeping: limit, sentences: sentences)
            if start == text.startIndex { return (apply(text).spans, start) }
            var e = Engine(String(text[start...]))
            e.run()
            if e.standsAlone { return (e.spans(), start) }
            if let over = lastStartOver(in: text), over > start {
                var o = Engine(String(text[over...]))
                o.run()
                if o.startsWithStartOver { return (joined(startedOver(text, before: over, limit: limit), o.spans()), over) }
            }
            sentences *= 3
        }
    }

    /// The last `limit` characters of `spans`, cut at a word. The piece that's cut is the first one shown: nothing
    /// from before it, so no stray word ends from older pieces.
    static func lastCharacters(_ spans: [Span], limit: Int) -> [Span] {
        guard limit > 0 else { return spans }
        var total = 0
        var out: [Span] = []
        for sp in spans.reversed() {
            if total >= limit { break }
            var piece = sp.text
            if total + piece.count > limit {
                piece = String(piece.suffix(limit - total))
                if let space = piece.firstIndex(of: " ") { piece = String(piece[piece.index(after: space)...]) }
                if !piece.isEmpty { out.insert(Span(text: piece, style: sp.style), at: 0) }
                break
            }
            total += piece.count
            out.insert(Span(text: piece, style: sp.style), at: 0)
        }
        return out
    }

    /// Where a window over the end of `text` (or the part before `end`) starts: the first character of a sentence
    /// (after ".", "!", "?", or "…" and a space) with more than `limit` characters after it, `sentences` sentence
    /// starts back. The start of `text` when there aren't that many. A period that ends an abbreviation ("Dr.",
    /// "a.m.") doesn't end a sentence, as the rules read it.
    static func sentenceStart(in text: String, before end: String.Index? = nil, keeping limit: Int, sentences: Int) -> String.Index {
        var i = end ?? text.endIndex
        var count = 0                       // characters from `i` to the end
        var firstSolid: String.Index?       // the first non-space character after `i`
        var solidCount = 0                  // characters from `firstSolid` to the end
        var found = 0
        var afterSpace = false              // the character after `i` is a space
        while i > text.startIndex {
            let j = text.index(before: i)
            let c = text[j]
            if afterSpace, ".!?…".contains(c), let s = firstSolid, solidCount > limit, !endsAbbreviation(text, period: j) {
                found += 1
                if found >= sentences { return s }
            }
            afterSpace = c.isWhitespace
            count += 1
            if !c.isWhitespace { firstSolid = j; solidCount = count }
            i = j
        }
        return text.startIndex
    }

    /// True when the "." at `period` belongs to an abbreviation the tokenizer keeps it on ("Dr.", "e.g.").
    private static func endsAbbreviation(_ text: String, period: String.Index) -> Bool {
        guard text[period] == "." else { return false }
        var k = period
        while k > text.startIndex {
            let p = text.index(before: k)
            if text[p].isWhitespace { break }
            k = p
        }
        let word = text[k..<period].drop { !($0.isLetter || $0.isNumber) }
        return abbreviations.contains(word.lowercased())
    }

    /// Start-over cues by a word they all contain, for the search over the whole text.
    private static let startOverKeys = ["start over", "start again", "all that", "everything", "clear that"]

    /// The start of the sentence holding the last start-over cue in `text`, found by searching for the cue's words
    /// only (no rules run). Nil without one.
    static func lastStartOver(in text: String) -> String.Index? {
        guard let cue = startOverKeys.compactMap({ text.range(of: $0, options: [.caseInsensitive, .backwards])?.lowerBound }).max()
        else { return nil }
        return sentenceStart(in: text, before: cue, keeping: 0, sentences: 1)
    }

    /// How the text before `start` reads after a start over that comes later: all removed (spaces at the very start
    /// of the text stay kept, as `Engine.spans` treats them). Only the last `limit` and one characters, which is
    /// all `lastCharacters` reads.
    private static func startedOver(_ text: String, before start: String.Index, limit: Int) -> [Span] {
        let from = text.index(start, offsetBy: -(limit + 1), limitedBy: text.startIndex) ?? text.startIndex
        var head = text[from..<start]
        var out: [Span] = []
        if from == text.startIndex {
            let lead = head.prefix { $0.isWhitespace }
            if !lead.isEmpty { out.append(Span(text: String(lead), style: .kept)) }
            head = head.dropFirst(lead.count)
        }
        if !head.isEmpty { out.append(Span(text: String(head), style: .removed)) }
        return out
    }

    /// `a` then `b`, with the two pieces where they meet joined when they have the same style (as `Engine.spans`
    /// joins them).
    private static func joined(_ a: [Span], _ b: [Span]) -> [Span] {
        guard let last = a.last, let first = b.first, last.style == first.style else { return a + b }
        return a.dropLast() + [Span(text: last.text + first.text, style: last.style)] + b.dropFirst()
    }

    // MARK: Vocabulary

    fileprivate enum CueType: Equatable {
        case delete
        case startOver
        /// Replace, strong or weak.
        case replace(strong: Bool)
    }

    fileprivate struct Cue {
        let words: [String]
        let type: CueType
        /// Must be set off by punctuation (before the cue or right after it) to count.
        var needsSetOff = false
        /// May follow any word (not only a clause start) for start-over cues.
        var anywhere = true
    }

    /// Longest first, so "let me start over" wins over "start over".
    fileprivate static let cues: [Cue] = {
        var c: [Cue] = [
            Cue(words: ["let", "me", "start", "over"], type: .startOver),
            Cue(words: ["let", "me", "start", "again"], type: .startOver),
            Cue(words: ["let's", "start", "over"], type: .startOver),
            Cue(words: ["let’s", "start", "over"], type: .startOver),
            Cue(words: ["let's", "start", "again"], type: .startOver),
            Cue(words: ["let’s", "start", "again"], type: .startOver),
            Cue(words: ["scratch", "all", "that"], type: .startOver),
            Cue(words: ["delete", "all", "that"], type: .startOver),
            Cue(words: ["erase", "all", "that"], type: .startOver),
            Cue(words: ["delete", "everything"], type: .startOver),
            Cue(words: ["erase", "everything"], type: .startOver),
            Cue(words: ["clear", "that"], type: .startOver),
            Cue(words: ["start", "over"], type: .startOver),
            Cue(words: ["start", "again"], type: .startOver),
            Cue(words: ["let", "me", "fix", "that"], type: .replace(strong: true)),
            Cue(words: ["actually", "no"], type: .replace(strong: true), needsSetOff: true),
            Cue(words: ["actually", "wait"], type: .replace(strong: true), needsSetOff: true),
            Cue(words: ["wait", "actually"], type: .replace(strong: true), needsSetOff: true),
            Cue(words: ["no", "wait"], type: .replace(strong: true), needsSetOff: true),
            Cue(words: ["wait", "no"], type: .replace(strong: true), needsSetOff: true),
            Cue(words: ["no", "sorry"], type: .replace(strong: true), needsSetOff: true),
            Cue(words: ["sorry", "no"], type: .replace(strong: true), needsSetOff: true),
            Cue(words: ["or", "rather"], type: .replace(strong: true)),
            Cue(words: ["correction"], type: .replace(strong: true), needsSetOff: true),
            Cue(words: ["make", "that"], type: .replace(strong: false)),
            Cue(words: ["i", "mean"], type: .replace(strong: false)),
            Cue(words: ["actually"], type: .replace(strong: false)),
            Cue(words: ["sorry"], type: .replace(strong: false)),
        ]
        for verb in ["scratch", "delete", "forget", "strike", "skip", "cancel", "undo", "remove", "erase"] {
            c.append(Cue(words: [verb, "that"], type: .delete))
        }
        c.append(Cue(words: ["never", "mind"], type: .delete))
        c.append(Cue(words: ["nevermind"], type: .delete))
        return c.sorted { $0.words.count > $1.words.count }
    }()

    /// Words before a command that make it the object of a sentence ("don't delete that", "we need to start
    /// over", "can you scratch that"), not a command to Verbatim.
    fileprivate static let blockedBefore: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "i'll", "you'll", "we'll", "they'll", "he'll", "she'll", "i'd",
        "you'd", "we'd", "they'd", "can", "can't", "cannot", "could", "couldn't", "will", "won't", "would", "wouldn't",
        "should", "shouldn't", "must", "might", "may", "do", "don't", "did", "didn't", "does", "doesn't", "to", "please",
        "not", "never", "let's", "gonna", "wanna", "and", "or", "but", "then", "just", "also", "i’ll", "don’t", "can’t",
        "won’t", "didn’t", "let’s", "pls", "lets", "dont", "cant", "wont", "didnt",
    ]

    /// Words before "sorry" that make it an apology ("I'm sorry", "so sorry").
    fileprivate static let apologyBefore: Set<String> = ["i'm", "i’m", "im", "am", "so", "very", "really", "feel", "be", "was", "were", "are",
                                                         "is", "not", "too", "terribly", "truly", "awfully", "say", "said", "sincerely", "deeply"]
    /// Words before "I mean" that make it literal ("what I mean", "you know what I mean").
    fileprivate static let iMeanBefore: Set<String> = ["what", "if", "do", "does", "did", "that's", "that’s", "thats", "that", "which", "how", "see", "know"]
    /// Words after "I mean" that make it literal ("I mean it", "I mean to say").
    fileprivate static let iMeanAfter: Set<String> = ["it", "that", "to", "what", "business", "well", "every", "no"]
    /// Words before "actually" that make it an adverb ("I actually like it", "it's actually fine").
    fileprivate static let adverbBefore: Set<String> = [
        "i", "we", "you", "they", "he", "she", "it", "it's", "it’s", "that's", "that’s", "is", "was", "are", "were", "do", "did",
        "does", "don't", "didn't", "not", "can", "could", "would", "will", "should", "really", "might", "what", "who", "had",
        "have", "has", "i'm", "i’m", "we're", "they're", "you're", "be", "been", "am", "there's", "there’s", "there", "which", "this",
    ]
    /// Words before "no" that make "no wait" a noun phrase ("there was no wait").
    fileprivate static let determinerBefore: Set<String> = ["was", "is", "are", "were", "there's", "there’s", "there", "had", "have", "has",
                                                            "with", "it's", "it’s", "be", "means", "with", "got"]

    /// Words a clause can begin with that don't count as content ("so", "okay").
    fileprivate static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "so", "okay", "ok", "oh", "well", "alright"]

    /// Function words: as an anchor, the replacement must be about as long as what it replaces.
    fileprivate static let functionWords: Set<String> = [
        "the", "a", "an", "to", "in", "on", "at", "of", "for", "with", "from", "by", "my", "your", "our", "their", "his", "her", "its",
        "this", "that", "these", "those", "it", "i", "we", "you", "they", "he", "she", "is", "was", "are", "were", "and", "or", "but",
    ]

    fileprivate static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
        "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "half", "dozen",
    ]
    fileprivate static let ordinalWords: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
        "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth", "thirtieth",
    ]
    fileprivate static let dayWords: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                                                    "today", "tomorrow", "tonight", "yesterday"]
    fileprivate static let monthWords: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august",
                                                      "september", "october", "november", "december"]
    fileprivate static let dayParts: Set<String> = ["morning", "afternoon", "evening", "night"]
    fileprivate static let timeUnits: Set<String> = ["am", "pm", "a.m", "p.m", "a.m.", "p.m.", "o'clock", "o’clock"]
    fileprivate static let moneyUnits: Set<String> = ["dollars", "dollar", "bucks", "cents", "euros", "pounds", "k"]
    fileprivate static let percentUnits: Set<String> = ["percent", "per"]
    /// Words after a number that a weak cue's replacement may end with ("6 people" is a fact, not a fix, but
    /// "3 pm" and "$600 total" are fixes).
    fileprivate static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "etc", "jr", "sr", "a.m", "p.m", "e.g", "i.e"]
}

// MARK: - Engine

private struct Token {
    enum Kind { case word, space, punct }
    var text: String
    var kind: Kind
    var alive = true
    /// Text shown in place of this token (a replaced value or name); the token itself counts as removed.
    var replacement: String? = nil
    /// The next word starts a sentence after a deletion: capitalize it.
    var capitalize = false
    var lower: String { text.lowercased() }
}

private struct ValueSpan {
    enum Kind { case number, time, money, percent, ordinal, day, month }
    var kind: Kind
    var start: Int
    var end: Int          // last token of the value, units included
    var numberEnd: Int    // last token of the number part
    var hasUnit: Bool
}

private struct Engine {
    typealias SC = SpokenCorrections
    var t: [Token] = []
    var corrections: [SpokenCorrections.Correction] = []

    init(_ s: String) {
        t = Engine.tokenize(s)
    }

    // MARK: Tokens

    static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                var j = i
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                out.append(Token(text: String(chars[i..<j]), kind: .space)); i = j; continue
            }
            let currency = "$£€".contains(c) && i + 1 < chars.count && chars[i + 1].isNumber
            if isWordChar(c) || currency {
                var j = i + 1
                while j < chars.count {
                    let d = chars[j]
                    if isWordChar(d) { j += 1; continue }
                    // Joiners inside a word: "it's", "11:30", "1,000", "2.5", "e-mail", "a.m".
                    if "'’:.,-".contains(d), j + 1 < chars.count, isWordChar(chars[j + 1]) {
                        if d == "," || d == ":" || d == "." {
                            // Only between digits ("1,000", "11:30", "2.5"), or "a.m"/"p.m"/"e.g".
                            let prevDigit = chars[j - 1].isNumber, nextDigit = chars[j + 1].isNumber
                            let shortLetters = d == "." && j - i <= 2 && chars[j - 1].isLetter && chars[j + 1].isLetter
                            if !(prevDigit && nextDigit) && !shortLetters { break }
                        }
                        j += 1; continue
                    }
                    break
                }
                if j < chars.count, chars[j] == "%" { j += 1 }
                var word = String(chars[i..<j])
                // "a.m." / "Dr." keep their period, so it isn't read as a sentence end.
                if j < chars.count, chars[j] == ".", SC.abbreviations.contains(word.lowercased()) {
                    word += "."; j += 1
                }
                out.append(Token(text: word, kind: .word)); i = j; continue
            }
            out.append(Token(text: String(c), kind: .punct)); i += 1
        }
        return out
    }

    static func isSentenceEnd(_ tok: Token) -> Bool {
        switch tok.kind {
        case .punct: return ".!?…".contains(tok.text)
        case .space: return tok.text.contains("\n")
        case .word: return false
        }
    }

    static func isClauseEnd(_ tok: Token) -> Bool {
        if isSentenceEnd(tok) { return true }
        return tok.kind == .punct && ",;:—–".contains(tok.text)
    }

    /// The previous alive token before `i` that isn't a space (a newline counts: it ends a sentence).
    func prevSolid(_ i: Int) -> Int? {
        var j = i - 1
        while j >= 0 {
            if t[j].alive && (t[j].kind != .space || t[j].text.contains("\n")) { return j }
            j -= 1
        }
        return nil
    }

    func nextSolid(_ i: Int) -> Int? {
        var j = i + 1
        while j < t.count {
            if t[j].alive && (t[j].kind != .space || t[j].text.contains("\n")) { return j }
            j += 1
        }
        return nil
    }

    func prevWord(_ i: Int) -> Int? {
        var j = i - 1
        while j >= 0 { if t[j].alive && t[j].kind == .word { return j }; j -= 1 }
        return nil
    }

    func nextWord(_ i: Int) -> Int? {
        var j = i + 1
        while j < t.count { if t[j].alive && t[j].kind == .word { return j }; j += 1 }
        return nil
    }

    /// The first token of the sentence that contains `i` (the token after the last sentence end before it).
    func sentenceStart(before i: Int) -> Int {
        var j = i - 1
        while j >= 0 {
            if t[j].alive && Engine.isSentenceEnd(t[j]) { return firstAlive(from: j + 1) }
            j -= 1
        }
        return firstAlive(from: 0)
    }

    /// The first token of the clause that contains `i`.
    func clauseStart(before i: Int) -> Int {
        var j = i - 1
        while j >= 0 {
            if t[j].alive && Engine.isClauseEnd(t[j]) { return firstAlive(from: j + 1) }
            j -= 1
        }
        return firstAlive(from: 0)
    }

    /// The first alive token that isn't a space, at or after `i`.
    func firstAlive(from i: Int) -> Int {
        var j = i
        while j < t.count, !(t[j].alive && t[j].kind != .space) { j += 1 }
        return j
    }

    func words(_ from: Int, _ to: Int) -> [Int] {
        guard from < to else { return [] }
        return (from..<min(to, t.count)).filter { t[$0].alive && t[$0].kind == .word }
    }

    func text(_ from: Int, _ through: Int) -> String {
        guard from <= through, from < t.count else { return "" }
        var s = ""
        for k in from...min(through, t.count - 1) where t[k].alive { s += t[k].replacement ?? t[k].text }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func kill(_ from: Int, _ through: Int) {
        guard from <= through else { return }
        for k in from...min(through, t.count - 1) { t[k].alive = false }
    }

    /// After a deletion that started a sentence, the next word starts it.
    mutating func capitalizeNext(after i: Int) {
        if let w = nextWord(i) { t[w].capitalize = true }
    }

    func isSentenceInitial(_ i: Int) -> Bool {
        guard let p = prevSolid(i) else { return true }
        return Engine.isSentenceEnd(t[p])
    }

    // MARK: Run

    mutating func run() {
        var i = 0
        while i < t.count {
            guard t[i].alive, t[i].kind == .word, let match = matchCue(at: i) else { i += 1; continue }
            let applied = apply(match)
            if firstCue == nil { firstCue = (match.start, match.type == .startOver && applied) }
            i = match.end + 1
        }
    }

    /// Where the first cue started, and whether it was a start over that took effect.
    private(set) var firstCue: (start: Int, startOver: Bool)?

    /// The first cue is a start over: everything before it goes, whatever text came before this, and nothing
    /// before it could change what it matched (`SpokenCorrections.liveTail`).
    var startsWithStartOver: Bool { firstCue?.startOver == true }

    /// True when these tokens, the end of a longer text, come out as they would in the whole text
    /// (`SpokenCorrections.liveTail`). Either the first cue is a start over, or the first sentence has a word, no
    /// cue, and nothing removed or replaced: every rule that looks back from a later cue stops at that sentence
    /// (a sentence end, or a word for the rules that look for one) before it reaches the start of the tokens.
    var standsAlone: Bool {
        if startsWithStartOver { return true }
        guard let end = t.firstIndex(where: Engine.isSentenceEnd) else { return false }
        if let f = firstCue, f.start <= end { return false }
        return t[...end].contains { $0.kind == .word } && t[...end].allSatisfy { $0.alive && $0.replacement == nil }
    }

    struct Match {
        var start: Int
        var end: Int
        var type: SpokenCorrections.CueType
        var phrase: String
        /// Explicit "delete the last N sentences/words/paragraph".
        var unit: String? = nil
        var count = 1
    }

    /// The cue that starts at word token `i`, if any. Cue words may be separated by spaces and commas ("no, wait").
    func matchCue(at i: Int) -> Match? {
        if let m = matchDeleteLast(at: i) { return m }
        for cue in SC.cues {
            guard let end = matchWords(cue.words, at: i) else { continue }
            var m = Match(start: i, end: end, type: cue.type, phrase: cue.words.joined(separator: " "))
            if case .replace = cue.type {
                guard replaceCueAllowed(cue, m) else { continue }
                // A cue right after a cue joins it: "actually, make that Friday".
                var j = m.end
                while let n = nextWord(j), onlySpacesOrCommas(j + 1, n), let next = SC.cues.first(where: { c in
                    if case .replace = c.type { return matchWords(c.words, at: n) != nil } else { return false }
                }), let e = matchWords(next.words, at: n) {
                    if case .replace(let strong) = next.type, strong { m.type = .replace(strong: true) }
                    m.phrase += " " + next.words.joined(separator: " ")
                    m.end = e; j = e
                }
                return m
            }
            guard commandAllowed(m) else { continue }
            return m
        }
        return nil
    }

    func onlySpacesOrCommas(_ from: Int, _ to: Int) -> Bool {
        guard from < to else { return true }
        return (from..<to).allSatisfy { !t[$0].alive || t[$0].kind == .space || t[$0].text == "," }
    }

    /// The last token of `words` matched at `i`, or nil.
    func matchWords(_ ws: [String], at i: Int) -> Int? {
        var k = i
        for (n, w) in ws.enumerated() {
            guard k < t.count, t[k].alive, t[k].kind == .word, t[k].lower == w else { return nil }
            if n == ws.count - 1 { return k }
            guard let next = nextWord(k), onlySpacesOrCommas(k + 1, next) else { return nil }
            k = next
        }
        return nil
    }

    /// "delete the last sentence", "remove the last two sentences", "erase the last 3 words", "delete the last
    /// paragraph", also with "previous".
    func matchDeleteLast(at i: Int) -> Match? {
        guard ["delete", "remove", "erase"].contains(t[i].lower) else { return nil }
        var k = i
        func next() -> Int? { guard let n = nextWord(k), onlySpacesOrCommas(k + 1, n) else { return nil }; k = n; return n }
        guard let a = next(), t[a].lower == "the" else { return nil }
        guard let b = next(), ["last", "previous"].contains(t[b].lower) else { return nil }
        guard var c = next() else { return nil }
        var count = 1
        let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5]
        if let n = numbers[t[c].lower] {
            count = n
            guard let d = next() else { return nil }
            c = d
        }
        let unit: String
        switch t[c].lower {
        case "sentence", "sentences": unit = "sentence"
        case "word", "words": unit = "word"
        case "paragraph", "paragraphs": unit = "paragraph"
        default: return nil
        }
        let m = Match(start: i, end: c, type: .delete, phrase: text(i, c).lowercased(), unit: unit, count: count)
        return commandAllowed(m) ? m : nil
    }

    /// Delete and start-over commands: they must end a clause, and must not be the object of a sentence.
    func commandAllowed(_ m: Match) -> Bool {
        if let n = nextSolid(m.end), !(t[n].kind == .punct && ".,;:!?…".contains(t[n].text)) && !Engine.isSentenceEnd(t[n]) { return false }
        if let p = prevSolid(m.start), t[p].kind == .word, SC.blockedBefore.contains(t[p].lower) { return false }
        return true
    }

    func replaceCueAllowed(_ cue: SpokenCorrections.Cue, _ m: Match) -> Bool {
        let prev = prevSolid(m.start)
        let prevLower = prev.map { t[$0].kind == .word ? t[$0].lower : "" } ?? ""
        let afterIdx = nextSolid(m.end)
        if cue.needsSetOff {
            let before = prev.map { Engine.isClauseEnd(t[$0]) } ?? true
            let after = afterIdx.map { t[$0].kind == .punct && ",:—–".contains(t[$0].text) } ?? false
            guard before || after else { return false }
        }
        let next = nextWord(m.end).map { t[$0].lower } ?? ""
        switch cue.words {
        case ["sorry"]: if SC.apologyBefore.contains(prevLower) { return false }
        case ["i", "mean"]:
            if SC.iMeanBefore.contains(prevLower) { return false }
            if SC.iMeanAfter.contains(next), afterIdx.map({ t[$0].kind == .word }) ?? false { return false }
        case ["actually"]: if SC.adverbBefore.contains(prevLower) { return false }
        case ["make", "that"]: if SC.blockedBefore.contains(prevLower) { return false }
        case ["no", "wait"], ["no", "sorry"]: if SC.determinerBefore.contains(prevLower) { return false }
        case ["wait", "no"]: if SC.blockedBefore.contains(prevLower) { return false }
        default: break
        }
        return true
    }

    // MARK: Apply

    mutating func apply(_ m: Match) -> Bool {
        switch m.type {
        case .startOver: return startOver(m)
        case .delete:
            if let unit = m.unit { return deleteLast(m, unit: unit) }
            return delete(m)
        case .replace(let strong): return replace(m, strong: strong)
        }
    }

    /// The last token to remove after a command: its punctuation and spaces. A sentence end stays when
    /// `keepEnd` (it ends the sentence that's left).
    func commandTail(_ m: Match, keepEnd: Bool) -> (last: Int, keptEnd: Bool) {
        var last = m.end
        guard let n = nextSolid(m.end) else { return (t.count - 1, false) }
        if t[n].kind == .punct {
            if keepEnd && Engine.isSentenceEnd(t[n]) { return (n - 1, true) }
            last = n
        }
        var j = last + 1
        while j < t.count, t[j].kind == .space || !t[j].alive {
            if t[j].alive && t[j].text.contains("\n") { break }   // a line break stays
            j += 1
        }
        return (j - 1, false)
    }

    mutating func startOver(_ m: Match) -> Bool {
        let first = firstAlive(from: 0)
        let removed = first < m.start ? text(first, m.start - 1) : ""
        let sentences = countSentences(first, m.start)
        let tail = commandTail(m, keepEnd: false)
        kill(0, tail.last)
        capitalizeNext(after: tail.last)
        record(.startOver, m, removed: removed, sentences: sentences)
        return true
    }

    mutating func delete(_ m: Match) -> Bool {
        var before = prevSolid(m.start)
        // "Oh, never mind": a clause of only filler words goes with the cue, and the scope is what came before it.
        while let q = before, t[q].kind == .punct, ",;:—–".contains(t[q].text) {
            let cs = clauseStart(before: q)
            let ws = words(cs, q)
            guard !ws.isEmpty, ws.allSatisfy({ SC.fillerWords.contains(t[$0].lower) }) else { break }
            before = prevSolid(cs)
        }
        guard let p = before else {
            // Nothing before but filler words: only the cue (and those words) go.
            let tail = commandTail(m, keepEnd: false)
            kill(min(m.start, firstAlive(from: 0)), tail.last); capitalizeNext(after: tail.last)
            return true
        }
        let start: Int
        var midSentence = false
        if Engine.isSentenceEnd(t[p]) {
            start = sentenceStart(before: p)                       // the previous sentence
        } else if t[p].kind == .punct, ",;:—–".contains(t[p].text) {
            start = clauseStart(before: p); midSentence = true      // the clause since the last comma
        } else {
            start = sentenceStart(before: m.start)                 // the sentence so far
        }
        return deleteRange(m, from: start, midSentence: midSentence, sentences: Engine.isSentenceEnd(t[p]) ? 1 : 0)
    }

    /// Removes from `from` through the command. A comma left dangling before the range goes, and the command's
    /// sentence end then ends what's left.
    mutating func deleteRange(_ m: Match, from start: Int, midSentence: Bool, sentences: Int) -> Bool {
        let removed = start < m.start ? text(start, m.start - 1) : ""
        let before = prevSolid(start)
        let danglingComma = before.flatMap { b in t[b].kind == .punct && ",;:—–".contains(t[b].text) ? b : nil }
        let startsSentence = before.map { Engine.isSentenceEnd(t[$0]) } ?? true
        let tail = commandTail(m, keepEnd: danglingComma != nil)
        kill(start, tail.last)
        if let c = danglingComma, tail.keptEnd || nextSolid(tail.last) == nil || nextSolid(tail.last).map({ Engine.isSentenceEnd(t[$0]) }) == true {
            kill(c, c)
        }
        if startsSentence { capitalizeNext(after: tail.last) }
        if !removed.isEmpty { record(.delete, m, removed: removed, sentences: sentences) }
        return true
    }

    mutating func deleteLast(_ m: Match, unit: String) -> Bool {
        let first = firstAlive(from: 0)
        guard first < m.start else {
            let tail = commandTail(m, keepEnd: false)
            kill(m.start, tail.last); capitalizeNext(after: tail.last)
            return true
        }
        var start = first
        var sentences = 0
        switch unit {
        case "word":
            let ws = words(first, m.start)
            guard !ws.isEmpty else { return false }
            start = ws[max(0, ws.count - m.count)]
            let removed = text(start, m.start - 1)
            // A sentence end after the command stays: the sentence goes on without those words.
            let tail = commandTail(m, keepEnd: true)
            kill(start, tail.last)
            record(.delete, m, removed: removed, sentences: 0)
            return true
        case "paragraph":
            var j = m.start - 1
            while j >= first {
                if t[j].alive, t[j].kind == .space, t[j].text.filter({ $0 == "\n" }).count >= 2 { start = firstAlive(from: j + 1); break }
                j -= 1
            }
            if start == m.start {
                // The command started a paragraph: remove the one before it.
                var k = j - 1
                start = first
                while k >= first {
                    if t[k].alive, t[k].kind == .space, t[k].text.filter({ $0 == "\n" }).count >= 2 { start = firstAlive(from: k + 1); break }
                    k -= 1
                }
            }
            sentences = max(1, countSentences(start, m.start))
        default:
            // Sentences: the unfinished one before the command counts as one.
            var starts: [Int] = []
            var k = first
            var inSentence = false
            while k < m.start {
                if t[k].alive {
                    if t[k].kind == .word && !inSentence { starts.append(k); inSentence = true }
                    if Engine.isSentenceEnd(t[k]) { inSentence = false }
                }
                k += 1
            }
            guard !starts.isEmpty else { return false }
            start = starts[max(0, starts.count - m.count)]
            sentences = min(m.count, starts.count)
        }
        return deleteRange(m, from: start, midSentence: false, sentences: sentences)
    }

    func countSentences(_ from: Int, _ to: Int) -> Int {
        var n = 0, inSentence = false
        var k = from
        while k < to {
            if t[k].alive {
                if t[k].kind == .word && !inSentence { n += 1; inSentence = true }
                if Engine.isSentenceEnd(t[k]) { inSentence = false }
            }
            k += 1
        }
        return n
    }

    mutating func record(_ kind: SpokenCorrections.Correction.Kind, _ m: Match, removed: String, replacement: String? = nil, sentences: Int = 0) {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:—–"))
        corrections.append(.init(kind: kind, cue: m.phrase, removed: removed.trimmingCharacters(in: trim),
                                 replacement: replacement?.trimmingCharacters(in: trim), sentences: sentences))
    }

    // MARK: Replace

    mutating func replace(_ m: Match, strong: Bool) -> Bool {
        // The replacement: the first word after the cue, past spaces, commas, and colons.
        guard let r0 = nextWord(m.end), (m.end + 1..<r0).allSatisfy({ !t[$0].alive || t[$0].kind == .space || ",:—–".contains(t[$0].text) }) else { return false }
        // Where to look: the sentence before the cue, or the previous sentence when the cue starts one.
        var scopeStart = sentenceStart(before: m.start)
        var scopeEnd = m.start
        let content = words(scopeStart, m.start).filter { !SC.fillerWords.contains(t[$0].lower) }
        let initial = content.isEmpty
        if initial {
            // The cue starts a sentence: it corrects the previous one.
            guard let p = prevSolid(min(scopeStart, m.start)) else { return false }
            // An answer to a question ("Are you coming? No, sorry, I can't.") isn't a correction.
            if t[p].text == "?" { return false }
            if t[p].kind == .space, let q = prevSolid(p), t[q].text == "?" { return false }
            scopeEnd = p      // the previous sentence, without its end mark
            scopeStart = sentenceStart(before: p)
            if words(scopeStart, scopeEnd).isEmpty { return false }
        }
        let cueLead = (prevWord(m.start).map { $0 + 1 }) ?? m.start   // the commas and spaces before the cue

        // Rule 1: a value replaces the last value of its kind.
        if let new = value(at: r0) {
            let endsClause = nextSolid(new.end).map { Engine.isClauseEnd(t[$0]) } ?? true
            let olds = values(scopeStart, scopeEnd).filter { compatible(new.kind, $0.kind) }
            if let old = olds.last {
                let direct = gapIsEmpty(old.end + 1, m.start)
                let allowed = strong || endsClause || (direct && !initial)
                if allowed && !sameText(old.start, old.end, new.start, new.end) {
                    let oldText = text(old.start, old.end)
                    if old.hasUnit && !new.hasUnit {
                        // "at 2 pm, actually 3" → "at 3 pm": only the number changes.
                        let newNumber = text(new.start, new.numberEnd)
                        setReplacement(old.start, old.numberEnd, newNumber)
                        kill(cueLead, new.numberEnd)
                        record(.replace, m, removed: oldText, replacement: newNumber + " " + rawText(old.numberEnd + 1, old.end))
                    } else if direct {
                        kill(old.start, r0 - 1)
                        record(.replace, m, removed: oldText, replacement: text(new.start, new.end))
                    } else {
                        let newText = text(new.start, new.end)
                        setReplacement(old.start, old.end, newText)
                        kill(cueLead, new.end)
                        record(.replace, m, removed: oldText, replacement: newText)
                    }
                    return true
                }
            }
        }
        // Weak cues that start a sentence ("Actually, I think…") are usually just words.
        if initial && !strong { return false }

        let replacementWords = wordsToClauseEnd(from: r0)

        // Rule 2: the replacement's first word appears before the cue.
        let anchor = t[r0].lower
        // The nearest occurrence that fits ("at 10, no wait, at the cafe at 11" anchors on the first "at").
        for a in words(scopeStart, scopeEnd).filter({ t[$0].lower == anchor }).reversed() {
            let oldLen = words(a, m.start).count
            let newLen = replacementWords.count
            var fits = oldLen >= 1 && oldLen <= 12
            if SC.functionWords.contains(anchor) { fits = fits && abs(newLen - oldLen) <= 1 && oldLen <= 6 }
            if fits && !sameWords(words(a, m.start), replacementWords) {
                let removed = text(a, m.start - 1)
                let startsSentence = isSentenceInitial(a)
                kill(a, r0 - 1)
                if startsSentence { t[r0].capitalize = true }
                record(.replace, m, removed: removed, replacement: text(r0, replacementWords.last ?? r0))
                return true
            }
        }

        // Rule 3: a capitalized name replaces the last name.
        if isName(r0) {
            var newEnd = r0
            while let n = nextWord(newEnd), n == newEnd + 2, t[newEnd + 1].kind == .space, isName(n) { newEnd = n }
            let names = words(scopeStart, scopeEnd).filter { isName($0) && !isSentenceInitial($0) }
            if let last = names.last {
                var oldStart = last
                while let p = prevWord(oldStart), p == oldStart - 2, t[oldStart - 1].kind == .space, isName(p), !isSentenceInitial(p), p >= scopeStart { oldStart = p }
                let direct = gapIsEmpty(last + 1, m.start)
                let endsClause = nextSolid(newEnd).map { Engine.isClauseEnd(t[$0]) } ?? true
                if (strong || endsClause || direct) && !sameText(oldStart, last, r0, newEnd) {
                    let oldText = text(oldStart, last), newText = text(r0, newEnd)
                    if direct { kill(oldStart, r0 - 1) } else { setReplacement(oldStart, last, newText); kill(cueLead, newEnd) }
                    record(.replace, m, removed: oldText, replacement: newText)
                    return true
                }
            }
        }

        // Rule 4: strong cues replace the clause before them, when punctuation sets the cue off from what follows
        // ("no, wait until Friday" is an answer and a verb, not a correction).
        guard strong, let after = nextSolid(m.end), t[after].kind == .punct, ",:—–".contains(t[after].text) else { return false }
        let start: Int
        if initial {
            start = scopeStart
        } else {
            var p = prevSolid(m.start)
            if let q = p, t[q].kind == .punct, ",;:—–".contains(t[q].text) { p = q }
            start = clauseStart(before: p ?? m.start)
        }
        guard start < m.start else { return false }
        let removed = text(start, (initial ? scopeEnd : cueLead - 1))
        guard !removed.isEmpty else { return false }
        let startsSentence = isSentenceInitial(start)
        kill(start, r0 - 1)
        if startsSentence { t[r0].capitalize = true }
        record(.replace, m, removed: removed, replacement: text(r0, replacementWords.last ?? r0))
        return true
    }

    /// The original text of tokens, ignoring replacements.
    func rawText(_ from: Int, _ through: Int) -> String {
        guard from <= through else { return "" }
        return (from...through).filter { t[$0].alive }.map { t[$0].text }.joined().trimmingCharacters(in: .whitespaces)
    }

    mutating func setReplacement(_ from: Int, _ through: Int, _ s: String) {
        t[from].replacement = s
        if through > from { kill(from + 1, through) }
    }

    /// Only spaces, punctuation, and filler sounds between `from` and `to`.
    func gapIsEmpty(_ from: Int, _ to: Int) -> Bool {
        guard from < to else { return true }
        return (from..<to).allSatisfy { k in !t[k].alive || t[k].kind != .word || SC.fillerWords.contains(t[k].lower) }
    }

    func wordsToClauseEnd(from i: Int) -> [Int] {
        var out: [Int] = []
        var k = i
        while k < t.count {
            if t[k].alive {
                if Engine.isClauseEnd(t[k]) { break }
                if t[k].kind == .word { out.append(k) }
            }
            k += 1
        }
        return out
    }

    func sameText(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Bool {
        text(a0, a1).lowercased() == text(b0, b1).lowercased()
    }

    func sameWords(_ a: [Int], _ b: [Int]) -> Bool {
        a.map { t[$0].lower } == b.map { t[$0].lower }
    }

    func isName(_ i: Int) -> Bool {
        let w = t[i].text
        guard let f = w.first, f.isUppercase, w.contains(where: { $0.isLowercase }) || w.count == 1 else { return false }
        let l = w.lowercased()
        if l == "i" || l.hasPrefix("i'") || l.hasPrefix("i’") { return false }
        if SC.dayWords.contains(l) || SC.monthWords.contains(l) { return false }
        return !SC.functionWords.contains(l) && !SC.fillerWords.contains(l)
    }

    // MARK: Values

    func values(_ from: Int, _ to: Int) -> [ValueSpan] {
        var out: [ValueSpan] = []
        var k = from
        while k < to {
            if t[k].alive, t[k].kind == .word, let v = value(at: k), v.end < to {
                out.append(v); k = v.end + 1; continue
            }
            k += 1
        }
        return out
    }

    func isNumber(_ w: String) -> Bool {
        let l = w.lowercased()
        if SC.numberWords.contains(l) { return true }
        let digits = l.filter { $0 != "," && $0 != "." }
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    /// The value that starts at word `i`: "3", "3 pm", "eleven thirty", "$500", "50 dollars", "20%", "May 4",
    /// "Tuesday morning", "the 4th" is read from "4th".
    func value(at i: Int) -> ValueSpan? {
        let w = t[i].text, l = t[i].lower
        func following(_ k: Int) -> Int? { guard let n = nextWord(k), (k + 1..<n).allSatisfy({ t[$0].kind == .space }) else { return nil }; return n }
        if let f = w.first, "$£€".contains(f) { return ValueSpan(kind: .money, start: i, end: i, numberEnd: i, hasUnit: true) }
        if l.hasSuffix("%") { return ValueSpan(kind: .percent, start: i, end: i, numberEnd: i, hasUnit: true) }
        if l.contains(":"), l.first?.isNumber == true {
            var end = i
            if let n = following(i), SC.timeUnits.contains(t[n].lower) { end = n }
            return ValueSpan(kind: .time, start: i, end: end, numberEnd: i, hasUnit: end != i)
        }
        if l == "noon" || l == "midnight" { return ValueSpan(kind: .time, start: i, end: i, numberEnd: i, hasUnit: true) }
        if SC.dayWords.contains(l) {
            var end = i
            if let n = following(i), SC.dayParts.contains(t[n].lower) { end = n }
            return ValueSpan(kind: .day, start: i, end: end, numberEnd: end, hasUnit: false)
        }
        if SC.monthWords.contains(l), l != "may" || w.first?.isUppercase == true {
            var end = i
            if let n = following(i), isNumber(t[n].text) || isOrdinal(t[n].lower) { end = n }
            return ValueSpan(kind: .month, start: i, end: end, numberEnd: end, hasUnit: false)
        }
        if isOrdinal(l) && l.first?.isNumber == true { return ValueSpan(kind: .ordinal, start: i, end: i, numberEnd: i, hasUnit: false) }
        guard isNumber(w) else { return nil }
        var end = i
        // "eleven thirty", "five hundred", "two and a half"
        while let n = following(end), isNumber(t[n].text) { end = n }
        let numberEnd = end
        if let n = following(end) {
            let u = t[n].lower
            if SC.timeUnits.contains(u) { return ValueSpan(kind: .time, start: i, end: n, numberEnd: numberEnd, hasUnit: true) }
            if SC.moneyUnits.contains(u) { return ValueSpan(kind: .money, start: i, end: n, numberEnd: numberEnd, hasUnit: true) }
            if SC.percentUnits.contains(u) {
                var e = n
                if u == "per", let c = following(n), t[c].lower == "cent" { e = c } else if u == "per" { return ValueSpan(kind: .number, start: i, end: numberEnd, numberEnd: numberEnd, hasUnit: false) }
                return ValueSpan(kind: .percent, start: i, end: e, numberEnd: numberEnd, hasUnit: true)
            }
        }
        return ValueSpan(kind: .number, start: i, end: numberEnd, numberEnd: numberEnd, hasUnit: false)
    }

    func isOrdinal(_ l: String) -> Bool {
        if SC.ordinalWords.contains(l) { return false }   // "first", "second": too often not a date
        guard let f = l.first, f.isNumber else { return false }
        return ["st", "nd", "rd", "th"].contains(where: { l.hasSuffix($0) }) && l.dropLast(2).allSatisfy { $0.isNumber }
    }

    func compatible(_ new: ValueSpan.Kind, _ old: ValueSpan.Kind) -> Bool {
        if new == old { return true }
        let numeric: Set<ValueSpan.Kind> = [.number, .time, .money, .percent, .ordinal]
        if new == .number { return numeric.contains(old) }
        if old == .number { return numeric.contains(new) }
        return false
    }

    // MARK: Render

    func render() -> String {
        var s = ""
        var pendingCap = false
        for tok in t {
            if !tok.alive { if tok.capitalize { pendingCap = true }; continue }
            var piece = tok.replacement ?? tok.text
            if (tok.capitalize || pendingCap) && tok.kind == .word {
                piece = Engine.capitalized(piece); pendingCap = false
            }
            s += piece
        }
        return Engine.tidy(s)
    }

    static func capitalized(_ w: String) -> String {
        guard let f = w.first, f.isLowercase else { return w }
        return String(f).uppercased() + w.dropFirst()
    }

    /// Spacing and punctuation a removal leaves behind.
    static func tidy(_ s: String) -> String {
        var out = s
        let rules: [(String, String)] = [
            ("[ \\t]{2,}", " "), ("[ \\t]+([,.;:!?])", "$1"), (",[ \\t]*,", ","), (",[ \\t]*([.?!])", "$1"),
            ("([.?!])[ \\t]*[.,;:]+", "$1"), ("(?m)^[ \\t]*[,;:.][ \\t]*", ""), ("[ \\t]+\\n", "\n"), ("\\n[ \\t]+", "\n"), ("\\n{3,}", "\n\n"),
        ]
        for (p, r) in rules { out = out.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = out.first, ",;:".contains(f) { out = String(out.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if out.hasSuffix(",") || out.hasSuffix(";") { out = String(out.dropLast()) }
        return out
    }

    /// The original text in pieces: kept, removed, and inserted.
    func spans() -> [SpokenCorrections.Span] {
        var out: [SpokenCorrections.Span] = []
        func add(_ s: String, _ style: SpokenCorrections.Span.Style) {
            guard !s.isEmpty else { return }
            if let last = out.last, last.style == style { out[out.count - 1].text += s } else { out.append(.init(text: s, style: style)) }
        }
        for tok in t {
            if tok.alive && tok.replacement == nil {
                add(tok.text, .kept)
            } else if tok.alive, let r = tok.replacement {
                add(tok.text, .removed); add(" ", .kept); add(r, .inserted)
            } else {
                add(tok.text, tok.kind == .space && out.last?.style != .removed ? .kept : .removed)
            }
        }
        // Spaces between two removed pieces read as part of them.
        return out
    }
}
