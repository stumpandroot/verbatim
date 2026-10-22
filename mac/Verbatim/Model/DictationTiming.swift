import Foundation

/// Timing and small decisions for Mac dictation, kept free of AppKit so the self-tests (`DictationTimingChecks`, run
/// by the Mac self-test and `mac/tools/test-formatter.sh`) can check them anywhere.
enum DictationTiming {
    // MARK: Release

    /// How long the mic keeps running after you let go of the hotkey, so the last syllable isn't clipped.
    static let tail: Double = 0.2

    /// Why listening ends.
    enum Stop { case release, cancel, interrupted, timeLimit }

    /// Only letting go (or clicking stop) keeps the mic on for the tail. Esc, a mic change, and the time limit stop
    /// at once.
    static func tailDelay(for stop: Stop) -> Double { stop == .release ? tail : 0 }

    /// Speech shorter than this, not counting the tail, is a stray tap and is discarded.
    static let minimumSpeech: Double = 0.4

    static func isStrayTap(duration: Double, tail: Double) -> Bool { duration - tail < minimumSpeech }

    // MARK: Budgets

    /// The most time cleanup's model step may take on the Mac, cloud and Apple's model together: 4 seconds, plus 1 second
    /// for every 600 characters past the first 600, up to 8 seconds. Past it, the rule-based text is pasted.
    static func cleanupBudget(characters: Int) -> Double {
        min(8, 4 + Double(max(0, characters - 600)) / 600)
    }

    /// Extra time allowed past the cleanup budget for the rules, the grammar pass, and the layout before dictation
    /// stops waiting and pastes the rule-based text.
    static let cleanupBackstop: Double = 0.5

    /// The longest the Dictionary boost may rescore: 0.3 seconds for up to a minute of speech, growing with longer
    /// hands-free dictations to at most 1 second. Past it, the plain transcript is used.
    static func boostBudget(audioSeconds: Double) -> Double {
        min(1.0, max(0.3, audioSeconds / 200))
    }

    // MARK: Paste

    /// The wait after bringing the target app forward before pressing ⌘V. None when it's already in front.
    static func activationWait(alreadyFront: Bool) -> Double { alreadyFront ? 0 : 0.12 }

    /// Dictation never pastes into a password field. The field focused at paste time decides; when it can't be read,
    /// the field that was focused when dictation started does.
    static func blocksPaste(secureAtStart: Bool, secureNow: Bool?) -> Bool { secureNow ?? secureAtStart }

    static let securePasteNotice = "Verbatim doesn't paste into password fields. Copied instead."

    // MARK: Ribbon

    /// The idle Ribbon's line from its hint: "hold right ⌥ or click" → "Click or hold right ⌥ to dictate". Other
    /// hints (setup, secure input) get a capital first letter.
    static func hintLine(_ hint: String) -> String {
        let suffix = " or click"
        if hint.hasSuffix(suffix) {
            var key = String(hint.dropLast(suffix.count))
            if key.hasPrefix("hold ") { key.removeFirst("hold ".count) }
            return "Click or hold \(key) to dictate"
        }
        return hint.prefix(1).uppercased() + hint.dropFirst()
    }

    // MARK: Log

    /// One line per dictation: the time from letting go to the paste, and where it went.
    static func timingLine(total: Double, tail: Double, transcribe: Double, cleanup: Double, paste: Double, cleaned: Bool, note: String?) -> String {
        func s(_ v: Double) -> String { String(format: "%.2f", v) }
        return "dictation timing: release → paste \(s(total)) s (tail \(s(tail)), transcribe \(s(transcribe)), cleanup \(s(cleanup)), paste \(s(paste)); "
            + (cleaned ? "model" : "rules") + (note.map { ": " + $0 } ?? "") + ")"
    }
}

/// Whether a dictation can use the Dictionary boost now, without waiting for its model.
enum BoostReadiness {
    struct Decision: Equatable {
        /// Use the session that's already built for these terms.
        var use: Bool
        /// Start building a session for these terms in the background.
        var build: Bool
        /// A build is already running: build these terms after it.
        var queue: Bool
    }

    static func decide(hasSession: Bool, keyMatches: Bool, backingOff: Bool, building: Bool) -> Decision {
        if hasSession && keyMatches { return Decision(use: true, build: false, queue: false) }
        if backingOff { return Decision(use: false, build: false, queue: false) }
        if building { return Decision(use: false, build: false, queue: true) }
        return Decision(use: false, build: true, queue: false)
    }
}

/// Pauses as hints for the rules and the model. Speech segments split at pauses over 1.2 seconds
/// (`Engines.segments`); dictation joins them here instead of with plain spaces:
/// - A pause of 1.2 seconds or more after words with no closing punctuation ends the sentence ("." and a capital),
///   unless the next word plainly continues it ("of", "to", "and"…).
/// - Hands-free, a pause of 3 seconds or more starts a new paragraph.
enum PauseBreaks {
    static let sentenceGap: Double = 1.2
    static let paragraphGap: Double = 3.0

    /// Words that continue a sentence after a pause rather than start a new one.
    /// Kept short: words like "the", "in", or "is" start sentences too often to count.
    static let continuing: Set<String> = ["of", "to", "and", "or", "nor", "than", "whom", "whose", "into", "onto", "been"]

    static func join(_ parts: [(text: String, start: Double, end: Double)], handsFree: Bool) -> String {
        var out = ""
        var lastEnd = 0.0
        for p in parts {
            let t = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            defer { lastEnd = p.end }
            if out.isEmpty { out = t; continue }
            let gap = p.start - lastEnd
            let ended = endsSentence(out)
            let continues = continuing.contains(firstWord(t))
            if handsFree && gap >= paragraphGap && (ended || !continues) {
                out = closeSentence(out) + "\n\n" + capitalized(t)
            } else if gap >= sentenceGap && !endsWithMark(out) && !continues {
                out += ". " + capitalized(t)
            } else {
                out += " " + t
            }
        }
        return out
    }

    private static func endsSentence(_ s: String) -> Bool { s.last.map { ".!?".contains($0) } ?? false }

    /// Any closing punctuation, including a comma or colon the speaker or the engine already put there.
    private static func endsWithMark(_ s: String) -> Bool { s.last.map { ".!?,;:…—-".contains($0) } ?? false }

    private static func closeSentence(_ s: String) -> String {
        if endsSentence(s) { return s }
        var t = s
        while let l = t.last, ",;:".contains(l) { t.removeLast() }
        return t + "."
    }

    private static func firstWord(_ s: String) -> String {
        String(s.prefix { $0.isLetter || $0 == "'" || $0 == "’" }).lowercased()
    }

    /// A capital first letter, except for words that already mix cases ("iPhone", "eBay").
    private static func capitalized(_ s: String) -> String {
        guard let f = s.first, f.isLowercase else { return s }
        let word = s.prefix { !$0.isWhitespace }
        if word.dropFirst().contains(where: { $0.isUppercase }) { return s }
        return f.uppercased() + s.dropFirst()
    }
}

/// Self-tests for dictation timing, pause hints, and the paste decisions. Foundation plus `DictationFormatter`. The
/// Mac self-test (`UITest`) and `mac/tools/test-formatter.sh` run them.
enum DictationTimingChecks {
    struct Result {
        let name: String
        let ok: Bool
        let detail: String
    }

    static func run() -> [Result] {
        var out: [Result] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            out.append(Result(name: name, ok: ok, detail: ok ? "" : detail()))
        }
        func expect(_ name: String, _ got: String, _ want: String) {
            check(name, got == want, "expected: \(want)\ngot: \(got)")
        }

        // The tail
        check("tail: letting go keeps the mic on 200 ms; Esc, a mic change, and the time limit don't",
              DictationTiming.tailDelay(for: .release) == 0.2 && DictationTiming.tailDelay(for: .cancel) == 0
                && DictationTiming.tailDelay(for: .interrupted) == 0 && DictationTiming.tailDelay(for: .timeLimit) == 0)
        check("tail: a stray tap is still a stray tap with the tail added",
              DictationTiming.isStrayTap(duration: 0.55, tail: 0.2) && !DictationTiming.isStrayTap(duration: 0.65, tail: 0.2)
                && DictationTiming.isStrayTap(duration: 0.35, tail: 0) && !DictationTiming.isStrayTap(duration: 0.45, tail: 0))

        // Budgets
        check("cleanup budget: 4 s for a normal dictation, more for long ones, never over 8 s",
              DictationTiming.cleanupBudget(characters: 80) == 4 && DictationTiming.cleanupBudget(characters: 600) == 4
                && DictationTiming.cleanupBudget(characters: 1_200) == 5 && DictationTiming.cleanupBudget(characters: 50_000) == 8)
        check("boost budget: 0.3 s up to a minute of speech, at most 1 s",
              DictationTiming.boostBudget(audioSeconds: 5) == 0.3 && DictationTiming.boostBudget(audioSeconds: 60) == 0.3
                && DictationTiming.boostBudget(audioSeconds: 120) == 0.6 && DictationTiming.boostBudget(audioSeconds: 900) == 1.0)

        // Boost readiness never waits
        check("boost: a session built for these terms is used",
              BoostReadiness.decide(hasSession: true, keyMatches: true, backingOff: false, building: false) == .init(use: true, build: false, queue: false))
        check("boost: new terms build in the background and this dictation doesn't wait",
              BoostReadiness.decide(hasSession: true, keyMatches: false, backingOff: false, building: false) == .init(use: false, build: true, queue: false)
                && BoostReadiness.decide(hasSession: false, keyMatches: false, backingOff: false, building: false) == .init(use: false, build: true, queue: false))
        check("boost: terms that change during a build are built next",
              BoostReadiness.decide(hasSession: false, keyMatches: false, backingOff: false, building: true) == .init(use: false, build: false, queue: true))
        check("boost: no build while backing off after a failure",
              BoostReadiness.decide(hasSession: false, keyMatches: false, backingOff: true, building: false) == .init(use: false, build: false, queue: false))

        // Paste
        check("paste: no activation wait when the app is already in front",
              DictationTiming.activationWait(alreadyFront: true) == 0 && DictationTiming.activationWait(alreadyFront: false) == 0.12)
        check("paste: never into a password field",
              DictationTiming.blocksPaste(secureAtStart: false, secureNow: true) && DictationTiming.blocksPaste(secureAtStart: true, secureNow: nil)
                && !DictationTiming.blocksPaste(secureAtStart: true, secureNow: false) && !DictationTiming.blocksPaste(secureAtStart: false, secureNow: nil))
        expect("paste: the password field notice", DictationTiming.securePasteNotice, "Verbatim doesn't paste into password fields. Copied instead.")

        // Ribbon hint line
        expect("hint line: right option", DictationTiming.hintLine("hold right ⌥ or click"), "Click or hold right ⌥ to dictate")
        expect("hint line: control option space", DictationTiming.hintLine("hold ⌃⌥ Space or click"), "Click or hold ⌃⌥ Space to dictate")
        expect("hint line: other hints get a capital", DictationTiming.hintLine("click to set up"), "Click to set up")

        // Pauses
        expect("pauses: a long pause with no punctuation ends the sentence",
               PauseBreaks.join([("I sent the draft", 0, 1.5), ("the client loved it", 2.9, 4)], handsFree: false),
               "I sent the draft. The client loved it")
        expect("pauses: a short pause joins with a space",
               PauseBreaks.join([("I sent the draft", 0, 1.5), ("the client loved it", 2.5, 4)], handsFree: false),
               "I sent the draft the client loved it")
        expect("pauses: existing punctuation is kept as is",
               PauseBreaks.join([("I sent the draft.", 0, 1.5), ("The client loved it.", 3, 4), ("So, next,", 5.5, 6), ("the budget", 8, 9)], handsFree: false),
               "I sent the draft. The client loved it. So, next, the budget")
        expect("pauses: a word that continues the sentence isn't split off",
               PauseBreaks.join([("I need a copy", 0, 1.5), ("of the contract", 3, 4)], handsFree: false),
               "I need a copy of the contract")
        expect("pauses: hands-free, 3 seconds or more starts a paragraph",
               PauseBreaks.join([("The edit is done", 0, 2), ("anyway lunch on Friday", 5.5, 7)], handsFree: true),
               "The edit is done.\n\nAnyway lunch on Friday")
        expect("pauses: holding the key, a long pause is only a sentence break",
               PauseBreaks.join([("The edit is done", 0, 2), ("anyway lunch on Friday", 5.5, 7)], handsFree: false),
               "The edit is done. Anyway lunch on Friday")
        expect("pauses: mixed-case words keep their case",
               PauseBreaks.join([("Ship the build", 0, 1), ("iPhone first", 2.5, 3)], handsFree: false),
               "Ship the build. iPhone first")
        let hinted = PauseBreaks.join([("The edit is done", 0, 2), ("anyway lunch on Friday", 5.5, 7)], handsFree: true)
        let laid = DictationFormatter.format(hinted, for: .work)
        check("pauses: the rules keep a paragraph break from a pause", laid.contains("\n\n") && laid.hasPrefix("The edit is done."), "got: \(laid)")
        return out
    }
}
