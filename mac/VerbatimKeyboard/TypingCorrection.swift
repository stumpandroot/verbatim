import Foundation

// Typing help's decisions, as pure rules (approved mockup "Corrections, suggestions, and accents", November 7, 2026):
// which field gets corrections, which word is at the cursor, which words are left alone, when space corrects a word and
// to what, how Delete or a tap puts it back, what the three-slot suggestion strip shows, the long-press row's geometry,
// and the space-bar cursor drag's steps. Foundation only (no UIKit), so mac/tools/test-typing-correction.sh compiles and
// checks it on Linux. `TypingAssist` (TypingAssist.swift) asks Apple's spell checker (`UITextChecker`) and applies these
// to the text through the text document proxy. Nothing here animates (DESIGN.md §7).

// MARK: - The field

/// A field's `autocorrectionType` or `spellCheckingType`.
enum FieldTrait: Equatable {
    case `default`, yes, no
}

/// What a field allows, from its traits. The keyboard follows each app's field settings: a field that turns off
/// autocorrection (a code field, a search for a username) gets no corrections, no suggestions, and no text replacements.
struct TypingFieldPolicy: Equatable {
    var kind: FieldKind
    var autocorrection: FieldTrait = .default
    var spellChecking: FieldTrait = .default
    /// The field's `textContentType` raw value.
    var contentType: String? = nil

    /// Content types for names, addresses, codes, and numbers, which are never words to correct.
    static let identifierContentTypes: Set<String> = [
        "username", "emailAddress", "URL", "password", "newPassword", "oneTimeCode", "telephoneNumber", "creditCardNumber",
        "postalCode", "flightNumber", "shipmentTrackingNumber", "creditCardSecurityCode", "creditCardExpiration",
    ]

    /// Plain text: a standard field that isn't for an identifier.
    var isPlainText: Bool {
        kind == .standard && !(contentType.map(Self.identifierContentTypes.contains) ?? false)
    }
    /// Space corrects misspelled words (Settings › Autocorrect also has to be on).
    var corrects: Bool { isPlainText && autocorrection != .no && spellChecking != .no }
    /// The strip shows (Settings › Suggestions also has to be on).
    var suggests: Bool { isPlainText && autocorrection != .no }
    /// Text replacements expand on space.
    var expandsReplacements: Bool { isPlainText && autocorrection != .no }
}

// MARK: - The word at the cursor

/// The word just before the cursor, and the run of text it ends (everything back to the last space), which shows when the
/// word is part of a link, an address, a path, or a number.
struct WordAtCursor: Equatable {
    var word: String
    var token: String

    static let empty = WordAtCursor(word: "", token: "")

    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" || c.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark }
    }

    /// From the text before the cursor (nil when the field doesn't say). A word that ends in an apostrophe isn't one
    /// (the apostrophe may be a closing quote); leading apostrophes are opening quotes, not part of it.
    static func before(_ text: String?) -> WordAtCursor {
        guard let text, let last = text.last, !last.isWhitespace else { return .empty }
        var token = Substring(text)
        if let i = text.lastIndex(where: { $0.isWhitespace }) { token = text[text.index(after: i)...] }
        var start = token.endIndex
        while start > token.startIndex, isWordCharacter(token[token.index(before: start)]) { start = token.index(before: start) }
        var word = token[start...]
        while let f = word.first, f == "'" || f == "\u{2019}" { word = word.dropFirst() }
        if let l = word.last, l == "'" || l == "\u{2019}" { return WordAtCursor(word: "", token: String(token)) }
        return WordAtCursor(word: String(word), token: String(token))
    }
}

// MARK: - Corrections

/// A correction or text replacement space just made: what you typed, what replaced it, and the space or punctuation
/// after it. The next Delete puts `original` back (and deletes `trailing`, as Delete would); a tap on the quoted word puts
/// it back and keeps `trailing`. Either way the word is left alone for the rest of the session.
struct AppliedCorrection: Equatable {
    var original: String
    var replacement: String
    var trailing: String
}

enum TypingCorrection {
    /// What ends a word and lets space, return, or punctuation correct it.
    static let boundaries: Set<String> = [" ", "\n", ".", ",", "!", "?", ";", ":", ")", "\u{201D}", "\""]

    static func isBoundary(_ text: String) -> Bool { boundaries.contains(text) }

    /// Characters that can open a word without making it something else: quotes, brackets, and inverted marks.
    static let openers: Set<Character> = ["\"", "'", "(", "[", "{", "\u{201C}", "\u{2018}", "\u{2019}", "\u{00BF}", "\u{00A1}", "\u{00AB}"]

    static func hasInnerCapital(_ w: String) -> Bool { w.dropFirst().contains { $0.isUppercase } }

    /// True when space never corrects this word: shorter than 2 letters, with a number in it, with a capital after its
    /// first letter (iPhone, NASA), part of a link, an email address, a path, or a tag, a word in Verbose's Dictionary,
    /// your text replacements and contacts, or one you've put back this session. `skip` holds lowercased words.
    static func leavesAlone(_ w: WordAtCursor, skip: Set<String>) -> Bool {
        let word = w.word
        if word.count < 2 { return true }
        if word.contains(where: { $0.isNumber }) { return true }
        if hasInnerCapital(word) { return true }
        if !tokenIsPlain(w) { return true }
        return skip.contains(word.lowercased())
    }

    /// The text before the word in its run is only opening punctuation, or the first half of a hyphenated word
    /// ("well-knwon"). Anything else (example.com, name@mail, a/b, #tag, 3.5x) makes it not a plain word.
    static func tokenIsPlain(_ w: WordAtCursor) -> Bool {
        let lower = w.token.lowercased()
        if lower.contains("@") || lower.contains("://") || lower.hasPrefix("www.") { return false }
        guard w.token.hasSuffix(w.word) else { return false }
        var prefix = Substring(w.token.dropLast(w.word.count))
        // Leading apostrophes the word dropped belong to the prefix too.
        while let f = prefix.first, openers.contains(f) { prefix = prefix.dropFirst() }
        if prefix.isEmpty { return true }
        guard prefix.last == "-" else { return false }
        return prefix.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "\u{2019}" }
    }

    /// How far a guess may be from what you typed (edits, with a swap of two letters counting once): 1 for words up to 4
    /// letters, 2 up to 8, 3 for longer. A guess further off is left in the strip but never applied by space.
    static func editLimit(_ length: Int) -> Int { length <= 4 ? 1 : (length <= 8 ? 2 : 3) }

    /// Edits between two strings, compared lowercased (optimal string alignment distance).
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[x.count][y.count]
    }

    static func closeEnough(_ typed: String, _ guess: String) -> Bool {
        distance(typed, guess) <= editLimit(typed.count)
    }

    /// A guess in the case you typed: "Teh" gives "The"; "teh" keeps the guess as it is, so "monday" gives "Monday".
    static func matchCase(_ guess: String, to typed: String) -> String {
        guard let f = typed.first, f.isUppercase, !hasInnerCapital(typed), let g = guess.first else { return guess }
        return g.uppercased() + guess.dropFirst()
    }

    /// English's lone "i" and its contractions take a capital (i → I, i'm → I'm), as on the system keyboard.
    static func fixedCorrection(_ word: String, language: String) -> String? {
        guard TypingLanguages.code(language) == "en", word.first == "i" else { return nil }
        if word == "i" { return "I" }
        let rest = word.dropFirst()
        guard let a = rest.first, a == "'" || a == "\u{2019}", ["m", "ll", "ve", "d"].contains(rest.dropFirst().lowercased()) else { return nil }
        return "I" + rest
    }

    /// What space turns the word into, or nil to leave it. `misspelled` and `guesses` come from Apple's spell checker for
    /// the current language. The first guess close enough to what you typed wins.
    static func correction(for w: WordAtCursor, misspelled: Bool, guesses: [String], skip: Set<String>, language: String) -> String? {
        if let fixed = fixedCorrection(w.word, language: language), tokenIsPlain(w), !skip.contains(w.word.lowercased()) { return fixed }
        guard misspelled, !leavesAlone(w, skip: skip) else { return nil }
        for g in guesses {
            let cased = matchCase(g, to: w.word)
            guard cased != w.word, closeEnough(w.word, g) else { continue }
            return cased
        }
        return nil
    }

    /// Your text replacement for the run before the cursor ("omw" → "On my way!"), matched without regard to case: the
    /// whole run first, then the word. `shortcuts` is keyed by the lowercased shortcut. Returns what to replace and with what.
    static func replacement(for w: WordAtCursor, shortcuts: [String: String]) -> (typed: String, phrase: String)? {
        guard !w.token.isEmpty else { return nil }
        if let p = shortcuts[w.token.lowercased()], p != w.token { return (w.token, p) }
        if !w.word.isEmpty, let p = shortcuts[w.word.lowercased()], p != w.word, tokenIsPlain(w) { return (w.word, p) }
        return nil
    }

    /// The edit that puts a correction back, when the text before the cursor still ends with it: how many characters to
    /// delete and what to insert. Nil when the text changed (the cursor moved, or the host edited it).
    static func revert(_ c: AppliedCorrection, before: String?, keepTrailing: Bool) -> (delete: Int, insert: String)? {
        let tail = c.replacement + c.trailing
        guard let before, before.hasSuffix(tail) else { return nil }
        return (tail.count, c.original + (keepTrailing ? c.trailing : ""))
    }
}

// MARK: - Text replacements and contacts

/// The supplementary lexicon (`requestSupplementaryLexicon`): your text replacements, which expand on space, and every
/// word in it (contact names, replacement shortcuts and phrases), which autocorrect leaves alone.
struct TextReplacements: Equatable {
    var shortcuts: [String: String] = [:]
    var words: Set<String> = []

    /// From the lexicon's entries. An entry whose input and text differ is a text replacement; one whose input is its text
    /// (a contact's name) only adds words. Shortcuts with a space in them can't be typed as one run, so they don't expand.
    static func build(_ entries: [(userInput: String, documentText: String)]) -> TextReplacements {
        var out = TextReplacements()
        for e in entries {
            let input = e.userInput.trimmingCharacters(in: .whitespaces)
            if !input.isEmpty, input != e.documentText, !input.contains(where: { $0.isWhitespace }), !e.documentText.isEmpty {
                out.shortcuts[input.lowercased()] = e.documentText
            }
            for w in TypingHelp.skipWords([e.userInput, e.documentText], cap: .max) { out.words.insert(w) }
        }
        return out
    }
}

// MARK: - The suggestion strip

/// The three slots between the menu and the dictate button: what you typed, in quotes (tap to keep it); the correction
/// space will apply, in bold; and a completion. Right after a correction, the quoted word you typed (tap to put it back).
struct SuggestionStrip: Equatable {
    enum Action: Equatable {
        /// Keep the word as typed: a space goes in, and the word is left alone for the session.
        case keep(String)
        /// Replace the word at the cursor with this, then a space.
        case use(String)
        /// Put back the correction space just made, keeping its space or punctuation.
        case revert
    }

    struct Slot: Equatable {
        var text: String
        var quoted = false
        var bold = false
        var action: Action
    }

    /// Always three: left, middle, right. A nil slot is blank.
    var slots: [Slot?] = [nil, nil, nil]

    static let empty = SuggestionStrip()
    var isEmpty: Bool { slots.allSatisfy { $0 == nil } }

    /// The slots for one side of a centered dictate button: the left side shows the first two, the right side the third.
    enum Part: Equatable { case all, leading, trailing }
    func slots(_ part: Part) -> [Slot?] {
        switch part {
        case .all: return slots
        case .leading: return Array(slots.prefix(2))
        case .trailing: return Array(slots.suffix(1))
        }
    }

    /// The strip for the word at the cursor. `correction` is what space would apply (nil when nothing would); `guesses`
    /// and `completions` come from the spell checker. With no word: the quoted word just corrected, if Delete could still
    /// put it back (`pending`), else nothing. A one-letter word shows nothing unless it has a correction.
    static func make(word: String, correction: String?, misspelled: Bool, guesses: [String], completions: [String],
                     pending: AppliedCorrection?) -> SuggestionStrip {
        guard !word.isEmpty else {
            guard let p = pending else { return .empty }
            return SuggestionStrip(slots: [Slot(text: p.original, quoted: true, action: .revert), nil, nil])
        }
        if word.count < 2 && correction == nil { return .empty }
        var candidates: [String] = []
        if let correction { candidates.append(correction) }
        if misspelled { candidates += guesses }
        candidates += completions
        var picked: [String] = []
        for c in candidates {
            let isCorrection = c == correction
            let cased = isCorrection ? c : TypingCorrection.matchCase(c, to: word)
            // Never the word itself; a change of case only when it's the correction (monday → Monday).
            if cased.isEmpty || cased == word { continue }
            if !isCorrection && cased.lowercased() == word.lowercased() { continue }
            if picked.contains(where: { $0.lowercased() == cased.lowercased() }) { continue }
            picked.append(cased)
            if picked.count == 2 { break }
        }
        var s = SuggestionStrip()
        s.slots[0] = Slot(text: word, quoted: true, action: .keep(word))
        if picked.count > 0 { s.slots[1] = Slot(text: picked[0], bold: correction != nil && picked[0] == correction, action: .use(picked[0])) }
        if picked.count > 1 { s.slots[2] = Slot(text: picked[1], action: .use(picked[1])) }
        return s
    }
}

// MARK: - Long-press row

/// Where the long-press row sits over a held key, and which letter a finger at `x` picks. Each slot is a key wide; the row
/// starts over the key and runs right, shifted left as far as it must to stay on the keyboard.
struct AccentRow: Equatable {
    var originX: CGFloat
    var slot: CGFloat
    var count: Int

    static let holdDelay: TimeInterval = 0.4
    /// A finger moves this far from where the row opened before it picks a different letter.
    static let pickSlop: CGFloat = 4

    var width: CGFloat { slot * CGFloat(count) }

    static func layout(keyMinX: CGFloat, keyWidth: CGFloat, count: Int, areaWidth: CGFloat, margin: CGFloat = 3) -> AccentRow {
        let slot = max(28, keyWidth)
        let width = slot * CGFloat(count)
        let maxOrigin = max(margin, areaWidth - margin - width)
        return AccentRow(originX: min(max(margin, keyMinX), maxOrigin), slot: slot, count: count)
    }

    func index(at x: CGFloat) -> Int {
        guard count > 0, slot > 0 else { return 0 }
        let i = Int(((x - originX) / slot).rounded(.down))
        return min(max(0, i), count - 1)
    }
}

// MARK: - Space-bar cursor drag

/// Hold the space bar for about 0.3 s and the key labels clear; dragging left or right then moves the cursor one character
/// per 8 points. One haptic when it starts, none while you drag.
struct CursorDrag: Equatable {
    static let holdDelay: TimeInterval = 0.3
    static let step: CGFloat = 8

    var startX: CGFloat
    /// Characters moved so far (negative is left).
    private(set) var moved = 0

    init(startX: CGFloat) { self.startX = startX }

    /// The finger is at `x`: how many characters to move the cursor now (the change since the last call).
    mutating func move(to x: CGFloat) -> Int {
        let target = Int(((x - startX) / Self.step).rounded(.towardZero))
        let delta = target - moved
        moved = target
        return delta
    }
}
