import UIKit

/// Typing help in the keyboard (approved mockup "Corrections, suggestions, and accents", November 7, 2026): autocorrect on
/// space, return, and punctuation; Delete or a tap on the quoted word to put a correction back; your text replacements;
/// and the three-slot suggestion strip. The decisions are pure (TypingCorrection.swift, TypingHelp.swift, checked on Linux
/// by mac/tools/test-typing-correction.sh); this class only asks Apple's on-device spell checker (`UITextChecker`, which
/// needs no Full Access) and edits the field through the text document proxy.
///
/// Kept light for the keyboard's memory limit: one checker, made on first use; the last word's answers cached; at most four
/// guesses and four completions kept; the Dictionary's words capped (`TypingHelp.wordCap`). The strip is published here,
/// apart from `TypingModel`, so a new suggestion redraws only the strip, never the keys.
@MainActor
final class TypingAssist: ObservableObject {
    @Published private(set) var strip = SuggestionStrip.empty

    private(set) var help = TypingHelp.standard
    private(set) var policy = TypingFieldPolicy(kind: .standard)
    /// The spell checker's language now ("en_US"), and the ones you type in (from the keyboards in the Settings app).
    private(set) var language = "en_US"
    private(set) var languages: [String] = []
    /// The correction space just made, which the next key may put back; nil after any other key.
    private(set) var applied: AppliedCorrection?

    weak var controller: UIInputViewController?
    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    /// Verbose's Dictionary (lowercased words, from the App Group), your text replacements and contacts, and the words you
    /// put back. The last stays in memory only, for as long as the keyboard runs, and is never saved.
    private var dictionary: Set<String> = []
    private var lexicon = TextReplacements()
    private var leftAlone: Set<String> = []
    private static let leftAloneCap = 500

    private var checker: UITextChecker?
    private struct Analysis {
        var misspelled: Bool
        var guesses: [String]
        var completions: [String]?
    }
    private var cache: (word: String, language: String, analysis: Analysis)?
    private var refreshQueued = false

    /// The languages Apple's spell checker has on this iPhone, read once.
    static let availableLanguages: [String] = UITextChecker.availableLanguages
    private var checkerReady: Bool { Self.availableLanguages.contains(language) }

    // MARK: Setup

    /// Settings, the Dictionary's words, and your languages, read when the keyboard appears (`KeyboardModel.resume`).
    func configure(help: TypingHelp, dictionary: Set<String>, chosen: [String], document: String?, picked: String?) {
        self.help = help
        self.dictionary = dictionary
        languages = chosen
        setLanguage(TypingLanguages.current(chosen: chosen, document: document, picked: picked, available: Self.availableLanguages))
        setNeedsRefresh()
    }

    func setLanguage(_ l: String) {
        guard l != language else { return }
        language = l
        cache = nil
        setNeedsRefresh()
    }

    func setPolicy(_ p: TypingFieldPolicy) {
        guard p != policy else { return }
        policy = p
        applied = nil
        setNeedsRefresh()
    }

    /// Your text replacements and contact names (`requestSupplementaryLexicon`, no Full Access needed). Asked for on each
    /// appearance, so a replacement added in the Settings app works the next time the keyboard opens.
    func loadLexicon() {
        controller?.requestSupplementaryLexicon { [weak self] lex in
            let entries = lex.entries.map { (userInput: $0.userInput, documentText: $0.documentText) }
            let built = TextReplacements.build(entries)
            Task { @MainActor in self?.lexicon = built }
        }
    }

    // MARK: Keys

    /// A key that isn't space, return, punctuation, or Delete: a correction can't be put back anymore.
    func keyTyped() { applied = nil }

    /// The cursor moved or the host changed the text: the same.
    func forget() {
        applied = nil
        setNeedsRefresh()
    }

    /// Space, return, or punctuation is about to go in (`trailing`): expand a text replacement, or correct the word before
    /// the cursor, first. The caller inserts `trailing` right after.
    func boundary(trailing: String) {
        applied = nil
        guard let proxy, policy.isPlainText else { return }
        let before = proxy.documentContextBeforeInput
        let w = WordAtCursor.before(before)
        guard !w.token.isEmpty else { return }
        // Inside a word (letters after the cursor): leave it, so splitting a word never changes it.
        if let next = proxy.documentContextAfterInput?.first, WordAtCursor.isWordCharacter(next) { return }
        if policy.expandsReplacements, let r = TypingCorrection.replacement(for: w, shortcuts: lexicon.shortcuts) {
            replace(r.typed, with: r.phrase, trailing: trailing)
            return
        }
        guard help.autocorrect, policy.corrects, !w.word.isEmpty else { return }
        let a = checkerReady ? analyze(w.word, completions: false) : Analysis(misspelled: false, guesses: [], completions: nil)
        if let c = TypingCorrection.correction(for: w, misspelled: a.misspelled, guesses: a.guesses, skip: skip(w.word), language: language) {
            replace(w.word, with: c, trailing: trailing)
        }
    }

    /// Delete: puts the correction space just made back (removing the space or punctuation after it, as Delete would) and
    /// leaves the word alone for the rest of the session. False when there's nothing to put back; Delete then deletes.
    func handleDelete() -> Bool {
        guard let a = applied else { return false }
        applied = nil
        guard let proxy, let r = TypingCorrection.revert(a, before: proxy.documentContextBeforeInput, keepTrailing: false) else { return false }
        for _ in 0..<r.delete { proxy.deleteBackward() }
        proxy.insertText(r.insert)
        leaveAlone(a.original)
        return true
    }

    /// A tap on a slot in the strip. Returns what went in last: a space after keeping or using a word, nothing after putting
    /// a correction back (its space or punctuation stays where it was).
    @discardableResult
    func tap(_ action: SuggestionStrip.Action) -> Bool {
        guard let proxy else { return false }
        switch action {
        case .keep(let word):
            applied = nil
            leaveAlone(word)
            proxy.insertText(" ")
            return true
        case .use(let s):
            applied = nil
            let w = WordAtCursor.before(proxy.documentContextBeforeInput)
            guard !w.word.isEmpty else { return false }
            replace(w.word, with: s, trailing: " ")
            proxy.insertText(" ")
            return true
        case .revert:
            guard let a = applied, let r = TypingCorrection.revert(a, before: proxy.documentContextBeforeInput, keepTrailing: true) else { return false }
            applied = nil
            for _ in 0..<r.delete { proxy.deleteBackward() }
            proxy.insertText(r.insert)
            leaveAlone(a.original)
            return false
        }
    }

    private func replace(_ typed: String, with new: String, trailing: String) {
        guard let proxy else { return }
        for _ in 0..<typed.count { proxy.deleteBackward() }
        proxy.insertText(new)
        applied = AppliedCorrection(original: typed, replacement: new, trailing: trailing)
    }

    private func leaveAlone(_ word: String) {
        if leftAlone.count >= Self.leftAloneCap { leftAlone.removeAll() }
        leftAlone.insert(word.lowercased())
    }

    /// The skip set for one word: that word when any of the three lists has it, else nothing (so the lists are never
    /// merged on each key).
    private func skip(_ word: String) -> Set<String> {
        let k = word.lowercased()
        return dictionary.contains(k) || lexicon.words.contains(k) || leftAlone.contains(k) ? [k] : []
    }

    // MARK: The strip

    /// Works out the strip once the current key's edit has landed (coalesced, so fast typing asks the checker once).
    func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refreshNow()
        }
    }

    private func refreshNow() {
        guard help.suggestions, policy.suggests, let proxy else { publish(.empty); return }
        let before = proxy.documentContextBeforeInput
        let w = WordAtCursor.before(before)
        if let next = proxy.documentContextAfterInput?.first, WordAtCursor.isWordCharacter(next) { publish(.empty); return }
        if w.word.isEmpty {
            let pending = applied.flatMap { TypingCorrection.revert($0, before: before, keepTrailing: true) != nil ? $0 : nil }
            publish(SuggestionStrip.make(word: "", correction: nil, misspelled: false, guesses: [], completions: [], pending: pending))
            return
        }
        guard TypingCorrection.tokenIsPlain(w) else { publish(.empty); return }
        let skipped = skip(w.word)
        let a = checkerReady ? analyze(w.word, completions: true) : Analysis(misspelled: false, guesses: [], completions: [])
        let correction = help.autocorrect && policy.corrects
            ? TypingCorrection.correction(for: w, misspelled: a.misspelled, guesses: a.guesses, skip: skipped, language: language) : nil
        let showsGuesses = a.misspelled && policy.corrects && !TypingCorrection.leavesAlone(w, skip: skipped)
        publish(SuggestionStrip.make(word: w.word, correction: correction, misspelled: showsGuesses, guesses: a.guesses,
                                     completions: a.completions ?? [], pending: nil))
    }

    private func publish(_ s: SuggestionStrip) { if s != strip { strip = s } }

    /// The spell checker's answers for one word, cached for the last word (space usually asks about the word the strip just
    /// showed). Completions only for the strip, and only from two letters.
    private func analyze(_ word: String, completions wantCompletions: Bool) -> Analysis {
        if let c = cache, c.word == word, c.language == language, !wantCompletions || c.analysis.completions != nil {
            return c.analysis
        }
        let checker = self.checker ?? UITextChecker()
        self.checker = checker
        let range = NSRange(location: 0, length: (word as NSString).length)
        var a: Analysis
        if let c = cache, c.word == word, c.language == language {
            a = c.analysis
        } else {
            let miss = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
            let misspelled = miss.location != NSNotFound
            let guesses = misspelled ? Array((checker.guesses(forWordRange: range, in: word, language: language) ?? []).prefix(4)) : []
            a = Analysis(misspelled: misspelled, guesses: guesses, completions: nil)
        }
        if wantCompletions && a.completions == nil {
            a.completions = word.count >= 2
                ? Array((checker.completions(forPartialWordRange: range, in: word, language: language) ?? []).prefix(4)) : []
        }
        cache = (word, language, a)
        return a
    }

    /// Drops the checker and the cache when iOS warns about memory; the next word makes a new checker.
    func trim() {
        checker = nil
        cache = nil
    }
}
