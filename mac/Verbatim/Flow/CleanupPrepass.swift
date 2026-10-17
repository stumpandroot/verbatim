import Foundation

/// Edits made by rules, before the language model sees a dictation, and in place of it at Literal or when
/// Apple's model is unavailable. Foundation only, so the iPhone target can share it later.
///
/// - Spoken line breaks: "new line", "new paragraph".
/// - Spoken punctuation: "comma", "period" or "full stop", "question mark", "exclamation point", "colon",
///   "semicolon". A word is left alone when it reads as a noun ("a comma", "the trial period", "colon cancer"),
///   and "period" becomes a mark only at the end, before a line break, or before a capital.
/// - Clean only: accidental repeats ("the the"), except doubles that carry meaning ("had had", "not not").
enum CleanupPrepass {

    /// Literal: spoken line breaks and punctuation, tidy spacing, and a capital to start. No word changes.
    static func literal(_ s: String) -> String {
        capitalizeFirst(tidy(punctuation(lineBreaks(s))))
    }

    /// Clean: Literal plus collapsed repeats. This is also what Clean and Polished fall back to.
    static func clean(_ s: String) -> String {
        capitalizeFirst(tidy(collapseRepeats(punctuation(lineBreaks(s)))))
    }

    /// Code apps: only "new line" and "new paragraph". "Period" or "comma" may be part of a command.
    static func lineBreaksOnly(_ s: String) -> String {
        lineBreaks(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words with a letter or digit in them.
    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// True when every word is a filler sound (um, uh, hmm).
    static func isOnlyFillers(_ s: String) -> Bool {
        let words = s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty, wordCount(s) == words.count else { return false }
        return words.allSatisfy { fillerSounds.contains($0) }
    }

    static let fillerSounds: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "hm", "mm", "mmm", "mhm", "ah", "eh", "huh"]

    /// Capitalizes the first letter when the text starts with a plain lowercase word. Leaves "iPhone",
    /// "example.com", and "5 people" alone.
    static func capitalizeFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: { !$0.isWhitespace && !"\"“‘'(".contains($0) }), s[i].isLetter, s[i].isLowercase else { return s }
        let end = s[i...].firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
        var core = s[i..<end]
        while let last = core.last, ",.;:!?".contains(last) { core = core.dropLast() }
        if core.contains(where: { $0.isUppercase || $0.isNumber || $0 == "." || $0 == "@" || $0 == "/" }) { return s }
        return s.replacingCharacters(in: i...i, with: String(s[i]).uppercased())
    }

    // MARK: Spoken commands

    private struct Cue {
        let regex: NSRegularExpression
        let mark: String
        let breaksLine: Bool
        /// Capitalizes the next word.
        let endsSentence: Bool
        /// "Period": a mark only at the end, before a line break, or before a capital.
        let needsBoundary: Bool
        let blockedBefore: Set<String>
        let blockedAfter: Set<String>
    }

    private static func cue(_ pattern: String, _ mark: String, breaksLine: Bool = false, endsSentence: Bool = false,
                            needsBoundary: Bool = false, before: Set<String> = [], after: Set<String> = []) -> Cue {
        // The patterns are constants, so a failure here is a programming error caught on first run.
        let regex = try! NSRegularExpression(pattern: "\\b(?:" + pattern + ")\\b", options: [.caseInsensitive])
        return Cue(regex: regex, mark: mark, breaksLine: breaksLine, endsSentence: endsSentence, needsBoundary: needsBoundary,
                   blockedBefore: before, blockedAfter: after)
    }

    /// Words before a cue that make it a noun ("a comma", "the question mark").
    private static let determiners: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "each", "every", "no", "one",
                                                   "any", "some", "another", "your", "my", "his", "her", "their", "our", "its", "what", "which"]

    private static let lineCues: [Cue] = [
        cue("new paragraph", "\n\n", breaksLine: true, endsSentence: true, before: ["a", "an", "the", "another", "whole", "first"]),
        cue("new line|newline", "\n", breaksLine: true, before: ["a", "an", "the", "another", "whole", "first"]),
    ]

    private static let punctuationCues: [Cue] = [
        cue("question mark", "?", endsSentence: true, before: determiners),
        cue("exclamation point|exclamation mark", "!", endsSentence: true, before: determiners),
        cue("full stop|period", ".", endsSentence: true, needsBoundary: true,
            before: ["a", "an", "the", "each", "every", "no", "one", "any", "some", "another", "your", "my", "his", "her", "their", "our", "its",
                     "trial", "grace", "time", "waiting", "billing", "pay", "notice", "cooling", "school", "class", "free", "rental",
                     "holiday", "probation", "probationary", "menstrual", "reporting", "fiscal", "same"]),
        cue("semicolon", ";", before: determiners),
        cue("colon", ":", before: determiners, after: ["cancer", "cleanse", "health", "surgery", "polyp", "polyps", "screening"]),
        cue("comma", ",", before: determiners.union(["oxford", "serial"]), after: ["separated", "delimited", "splice"]),
    ]

    /// "new line" and "new paragraph".
    static func lineBreaks(_ s: String) -> String {
        lineCues.reduce(s) { apply($1, to: $0) }
    }

    /// "comma", "period", "question mark", and the rest.
    static func punctuation(_ s: String) -> String {
        punctuationCues.reduce(s) { apply($1, to: $0) }
    }

    private static func apply(_ c: Cue, to text: String) -> String {
        var s = text
        var from = 0
        while true {
            let ns = s as NSString
            guard from < ns.length, let m = c.regex.firstMatch(in: s, range: NSRange(location: from, length: ns.length - from)) else { break }
            let end = m.range.location + m.range.length
            let left = ns.substring(to: m.range.location)
            let right = ns.substring(from: end)
            guard allows(c, left: left, right: right) else { from = end; continue }
            // The spoken mark replaces whatever punctuation the recognizer put around the word.
            let l = trimEnd(left, c.breaksLine ? " \t," : " \t,.;:!?")
            var r = trimStart(right, ",.;:!? \t")
            if c.endsSentence { r = capitalizeFirst(r) }
            let gap = (c.breaksLine || r.isEmpty || r.hasPrefix("\n")) ? "" : " "
            let head = l + c.mark + gap
            s = head + r
            from = (head as NSString).length
        }
        return s
    }

    private static func allows(_ c: Cue, left: String, right: String) -> Bool {
        let prev = lastWord(left).lowercased()
        if !c.breaksLine && prev.isEmpty { return false }   // nothing to attach the mark to
        if c.blockedBefore.contains(prev) { return false }
        if right.hasPrefix("-") { return false }             // "comma-separated"
        if c.blockedAfter.contains(firstWord(right).lowercased()) { return false }
        if c.needsBoundary {
            let rest = trimStart(right, ",.;:!? \t")
            guard rest.isEmpty || rest.hasPrefix("\n") || rest.first?.isUppercase == true else { return false }
        }
        return true
    }

    private static func lastWord(_ s: String) -> String {
        var t = Substring(s)
        while let ch = t.last, ch == " " || ch == "\t" || ",.;:!?".contains(ch) { t = t.dropLast() }
        var w = ""
        while let ch = t.last, ch.isLetter || ch.isNumber || ch == "'" || ch == "’" { w.insert(ch, at: w.startIndex); t = t.dropLast() }
        return w
    }

    private static func firstWord(_ s: String) -> String {
        var t = Substring(s)
        while let ch = t.first, ch == " " || ch == "\t" || ",.;:!?".contains(ch) { t = t.dropFirst() }
        return String(t.prefix(while: { $0.isLetter || $0.isNumber }))
    }

    private static func trimEnd(_ s: String, _ chars: String) -> String {
        var t = Substring(s)
        while let ch = t.last, chars.contains(ch) { t = t.dropLast() }
        return String(t)
    }

    private static func trimStart(_ s: String, _ chars: String) -> String {
        String(s.drop(while: { chars.contains($0) }))
    }

    // MARK: Repeats

    private static let repeatRegex = try! NSRegularExpression(pattern: "\\b(\\p{L}[\\p{L}'’]*)(?:[ \\t]+\\1\\b)+", options: [.caseInsensitive])

    /// Doubles that are usually meant: "had had", "that that", "very very", "no no", "bye bye".
    static let keepDoubled: Set<String> = ["that", "had", "is", "not", "no", "never", "very", "really", "so", "bye", "ha", "haha", "well",
                                           "now", "there", "knock", "many", "much", "far", "long", "more", "yeah", "yes", "ok", "okay",
                                           "hey", "wait", "go", "come", "blah", "boo", "la", "na", "tut", "chop", "choo", "cha", "do", "dum",
                                           "night", "little", "big", "over", "again", "round", "on", "off", "out", "up", "down", "please"]

    static func collapseRepeats(_ s: String) -> String {
        let ns = NSMutableString(string: s)
        for m in repeatRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range(at: 1))
            if keepDoubled.contains(word.lowercased()) { continue }
            ns.replaceCharacters(in: m.range, with: word)
        }
        return ns as String
    }

    // MARK: Spacing

    static func tidy(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            ("[ \\t]+\\n", "\n"), ("\\n[ \\t]+", "\n"), ("[ \\t]{2,}", " "), ("\\n{3,}", "\n\n"),
            ("[ \\t]+([,.;:!?])(?=\\s|$)", "$1"),
        ]
        for (p, r) in rules { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
