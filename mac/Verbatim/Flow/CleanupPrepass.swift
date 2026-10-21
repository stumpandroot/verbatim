import Foundation

/// Edits made by rules, before the language model sees a dictation, and in place of it at Literal or when
/// Apple's model is unavailable. Foundation only, so the iPhone target can share it later.
///
/// - Spoken line breaks: "new line", "new paragraph".
/// - Spoken punctuation: "comma", "period" or "full stop", "question mark", "exclamation point", "colon",
///   "semicolon". A word is left alone when it reads as a noun ("a comma", "the trial period", "colon cancer"),
///   and "period" becomes a mark only at the end, before a line break, or before a capital.
/// - Clean and Polished: filler sounds (um, uh, er, hmm), "you know", "I mean", and "like" where they are
///   clearly filler, stutters ("I-I-I", "th- the"), accidental repeats ("the the", "I think I think"), and a
///   false start cut off by a dash ("we should — we need to"). Doubles that carry meaning stay ("had had",
///   "not not"), and so do "I like it", "you know the answer?", and "I mean it". When unsure, the words stay.
enum CleanupPrepass {

    /// Literal: spoken line breaks and punctuation, tidy spacing, and a capital to start. No word changes.
    static func literal(_ s: String) -> String {
        capitalizeFirst(tidy(punctuation(lineBreaks(s))))
    }

    /// Clean: Literal plus fillers, stutters, repeats, and simple false starts removed. This is also what Clean
    /// and Polished fall back to when Apple's model is missing, slow, or its output fails a guard.
    static func clean(_ s: String) -> String {
        let marked = punctuation(lineBreaks(s))
        let trimmed = falseStarts(collapseRepeats(stutters(removeFillers(marked))))
        return capitalizeFirst(tidy(trimmed))
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

    // MARK: Fillers

    /// Filler sounds, removed wherever they stand alone as a word. Not "huh" or "mhm", which can be answers.
    static let removableSounds: [String] = ["ummm", "umm", "um", "uhhh", "uhh", "uhm", "uh", "erm", "er", "ahh", "ah",
                                            "hmmm", "hmm", "hm", "mmm", "mm", "eh"]

    private static func wordRegex(_ alternatives: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’\-])(?:"# + alternatives + #")(?![\p{L}\p{N}'’\-])"#, options: [.caseInsensitive])
    }
    private static let soundRegex = wordRegex(removableSounds.joined(separator: "|"))
    private static let youKnowRegex = wordRegex(#"you know"#)
    private static let iMeanRegex = wordRegex(#"I mean"#)
    private static let likeRegex = wordRegex(#"like"#)

    /// Words a clause rarely ends on, so a comma after them came from the pause: "and, um, then" → "and then".
    private static let noCommaAfter: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "to", "of", "in", "on", "at", "for", "with", "from", "by", "about",
        "into", "than", "that", "this", "these", "those", "my", "your", "our", "their", "his", "her", "its", "is", "was",
        "are", "were", "be", "been", "am", "i'm", "it's", "have", "has", "had", "do", "does", "did", "will", "would",
        "can", "could", "should", "might", "must", "very", "really", "just", "kind", "sort", "i", "we", "you", "they",
        "he", "she", "it", "get", "got", "go", "going", "went", "need", "want", "think", "thought", "because", "if",
        "like", "love", "see", "make", "take", "give", "send", "call", "ask", "tell", "said", "say", "put", "bring",
    ]

    /// Words before ", like," that make it "such as": "a few things, like, the photos".
    private static let likeMeansSuchAs: Set<String> = ["things", "stuff", "something", "anything", "everything", "ones", "items",
                                                       "options", "places", "people", "examples", "tools", "ideas", "words"]

    /// Removes filler sounds everywhere, and "you know", "I mean", and "like" only where punctuation shows they
    /// are filler. Keeps "I like it", "you know the answer?", "as you know,", "I mean it", "like 5 people", and
    /// a sentence-initial "I mean," that may be correcting a name or number ("I mean, Wednesday").
    static func removeFillers(_ s: String) -> String {
        // Phrases first, so the commas around them are still there to read; then sounds; then phrases again for
        // one that a sound was hiding ("um you know, I think").
        var t = removeFillerPhrases(s)
        t = strip(soundRegex, in: t) { left, word, right in
            // UM, ER: all capitals may be an abbreviation. "5 mm", "two hm": a unit after a number.
            if word.count > 1, word == word.uppercased() { return false }
            let lw = word.lowercased()
            // "Uh huh" and "mm hmm" mean yes.
            if ["huh", "hmm"].contains(firstWord(right).lowercased()) && ["uh", "um", "mm", "mmm"].contains(lw) { return false }
            if lw.hasPrefix("hm") && ["uh", "um", "mm", "mmm"].contains(lastWord(left).lowercased()) { return false }
            if lw == "mm" || lw == "hm" || lw == "mmm" {
                let prev = lastWord(left).lowercased()
                if prev.first?.isNumber == true || NumberWords.isNumberWord(prev) { return false }
            }
            return true
        }
        return removeFillerPhrases(t)
    }

    private static func removeFillerPhrases(_ s: String) -> String {
        var t = strip(youKnowRegex, in: s) { left, _, right in
            let r = afterSpaces(right)
            if r.hasPrefix("?") { return false }                     // "…, you know?" asks something
            if endsWithComma(left) { return r.hasPrefix(",") || r.hasPrefix(".") || r.hasPrefix("!") || r.isEmpty }
            return startsSentence(left) && r.hasPrefix(",")          // "You know, I think…"
        }
        t = strip(iMeanRegex, in: t) { left, _, right in
            guard startsSentence(left) else { return false }       // mid-sentence it may correct something
            let r = afterSpaces(right)
            guard r.hasPrefix(",") else { return false }             // "I mean it"
            return !mentionsFact(sentence(after: r.dropFirst()))
        }
        t = strip(likeRegex, in: t) { left, _, right in
            let r = afterSpaces(right)
            guard r.hasPrefix(","), endsWithComma(left) || startsSentence(left) else { return false }
            let next = firstWord(String(r.dropFirst())).lowercased()
            if next.first?.isNumber == true || NumberWords.isNumberWord(next) { return false }   // "like, 50 people"
            if endsWithComma(left), likeMeansSuchAs.contains(lastWord(left).lowercased()) { return false }
            return true
        }
        return t
    }

    /// Removes each match `allow` agrees to (it gets the text before, the match, and the text after), with the
    /// commas around it, and capitalizes the next word when the match started a sentence.
    private static func strip(_ re: NSRegularExpression, in text: String, allow: (String, String, String) -> Bool) -> String {
        var s = text
        var from = 0
        while true {
            let ns = s as NSString
            guard from < ns.length, let m = re.firstMatch(in: s, range: NSRange(location: from, length: ns.length - from)) else { break }
            let end = m.range.location + m.range.length
            let left = ns.substring(to: m.range.location)
            let right = ns.substring(from: end)
            guard allow(left, ns.substring(with: m.range), right) else { from = end; continue }
            let joined = join(left, right)
            s = joined.text
            from = joined.cursor
        }
        return s
    }

    /// Joins the text around a removed filler: its trailing commas or ellipsis go with it, a comma before it
    /// stays unless it came from the pause ("and, um, then"), and a sentence it started gets a capital.
    private static func join(_ left: String, _ right: String) -> (text: String, cursor: Int) {
        var r = Substring(right)
        while true {
            if r.hasPrefix("...") { r = r.dropFirst(3); continue }
            guard let ch = r.first, ch == " " || ch == "\t" || ch == "," || ch == "…" else { break }
            r = r.dropFirst()
        }
        var l = Substring(left)
        while let ch = l.last, ch == " " || ch == "\t" { l = l.dropLast() }
        if let mark = r.first, ".?!".contains(mark) {
            // "We should, um." → "We should." A filler alone in its sentence takes its mark with it.
            while let ch = l.last, ",;".contains(ch) { l = l.dropLast() }
            if startsSentence(String(l)) {
                r = r.dropFirst()
                while let ch = r.first, ch == " " || ch == "\t" || ".?!".contains(ch) { r = r.dropFirst() }
                let rest = capitalizeFirst(String(r))
                let gap = (l.isEmpty || l.last == "\n" || rest.isEmpty || rest.hasPrefix("\n")) ? "" : " "
                let head = String(l) + gap
                return (head + rest, (head as NSString).length)
            }
            let head = String(l)
            return (head + r, (head as NSString).length)
        }
        if l.last == ",", noCommaAfter.contains(lastWord(String(l)).lowercased()) { l = l.dropLast() }
        var rest = String(r)
        if startsSentence(String(l)) { rest = capitalizeFirst(rest) }
        let gap = (l.isEmpty || l.last == "\n" || rest.isEmpty || rest.hasPrefix("\n")) ? "" : " "
        let head = String(l) + gap
        return (head + rest, (head as NSString).length)
    }

    /// True when the next word starts a sentence: nothing before it, or a sentence end or line break.
    private static func startsSentence(_ left: String) -> Bool {
        var t = Substring(left)
        while let ch = t.last, ch == " " || ch == "\t" || "\"“‘'(".contains(ch) { t = t.dropLast() }
        guard let last = t.last else { return true }
        return ".?!\n".contains(last)
    }

    private static func endsWithComma(_ left: String) -> Bool {
        left.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).hasSuffix(",")
    }

    private static func afterSpaces(_ s: String) -> Substring {
        Substring(s).drop(while: { $0 == " " || $0 == "\t" })
    }

    /// The rest of the sentence that starts `s`.
    private static func sentence(after s: Substring) -> Substring {
        s.prefix(while: { !".?!\n".contains($0) })
    }

    /// Digits, number words, or a capitalized word other than "I": a fact the words before may be correcting.
    private static func mentionsFact(_ s: Substring) -> Bool {
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
        return words.contains { w in
            if w.contains(where: { $0.isNumber }) || NumberWords.isNumberWord(w.lowercased()) { return true }
            guard let f = w.first, f.isUppercase else { return false }
            let lw = w.lowercased()
            return !(lw == "i" || lw.hasPrefix("i'") || lw.hasPrefix("i’"))
        }
    }

    // MARK: Stutters and false starts

    /// "I-I-I", "we-we": a short word joined to itself by hyphens. Real doubles stay ("so-so", "bye-bye").
    private static let hyphenStutterRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’\-])(\p{L}{1,3})(?:-\1)+(?![\p{L}\p{N}'’\-])"#, options: [.caseInsensitive])
    private static let hyphenDoubles: Set<String> = ["so", "yo", "ha", "tut", "pom", "tom", "no", "bye", "boo", "cha", "dum", "can",
                                                     "aye", "bon", "goo", "ga", "la", "na", "ta", "tsk", "pee", "wee", "poo", "bo", "do"]
    /// "th- the", "w- we", "I- I think": a cut-off start right before the word it was starting.
    private static let cutStutterRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’\-])(\p{L}{1,4})[-—–][ \t]+(?=\1)"#, options: [.caseInsensitive])

    static func stutters(_ s: String) -> String {
        let ns = NSMutableString(string: s)
        for m in hyphenStutterRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range(at: 1))
            if hyphenDoubles.contains(word.lowercased()) { continue }
            ns.replaceCharacters(in: m.range, with: word)
        }
        let t = ns as String
        let out = NSMutableString(string: t)
        for m in cutStutterRegex.matches(in: t, range: NSRange(location: 0, length: out.length)).reversed() {
            let fragment = out.substring(with: m.range(at: 1))
            out.replaceCharacters(in: m.range, with: "")
            // "Th- the" at a sentence start keeps its capital.
            if fragment.first?.isUppercase == true, m.range.location < out.length {
                let first = NSRange(location: m.range.location, length: 1)
                out.replaceCharacters(in: first, with: out.substring(with: first).uppercased())
            }
        }
        return out as String
    }

    /// "We should — we need to finish": up to four words cut off by a dash, then a restart with the same first
    /// word. A dash before anything else is punctuation and stays.
    private static let dashRestartRegex = try! NSRegularExpression(
        pattern: #"(^|[.!?][ \t]+)((i|we|you|they|he|she|it|so|and|but|there|this|what|how|when|where|why|can|could|would|should|will|do|did|let's|let’s)(?:[ \t]+\p{L}[\p{L}'’]*){0,3})[ \t]*(?:—|–|--|[ \t]-)[ \t]*(?=\3(?!\p{L}))(?![^.!?\n]*(?:—|–|--| - ))"#,
        options: [.caseInsensitive, .anchorsMatchLines])

    static func falseStarts(_ s: String) -> String {
        let out = NSMutableString(string: s)
        for m in dashRestartRegex.matches(in: s, range: NSRange(location: 0, length: out.length)).reversed() {
            let lead = out.substring(with: m.range(at: 1))
            out.replaceCharacters(in: m.range, with: lead)
            let at = m.range.location + (lead as NSString).length
            if at < out.length {
                let first = NSRange(location: at, length: 1)
                out.replaceCharacters(in: first, with: out.substring(with: first).uppercased())
            }
        }
        return out as String
    }

    // MARK: Repeats

    private static let repeatRegex = try! NSRegularExpression(pattern: "\\b(\\p{L}[\\p{L}'’]*)(?:[ \\t]+\\1\\b)+", options: [.caseInsensitive])
    /// "I think I think", "in the, in the": a repeated two- or three-word phrase.
    private static let phraseRepeatRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}'’])((?:\p{L}[\p{L}'’]*[ \t]+){1,2}\p{L}[\p{L}'’]*),?[ \t]+\1(?![\p{L}'’])"#, options: [.caseInsensitive])

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
            // "Bora Bora", "Walla Walla": a capitalized double is a name.
            let whole = ns.substring(with: m.range)
            let capitals = whole.split(separator: " ").filter { $0.first?.isUppercase == true }.count
            if capitals > 1 && word.lowercased() != "i" { continue }
            ns.replaceCharacters(in: m.range, with: word)
        }
        let t = ns as String
        let out = NSMutableString(string: t)
        for m in phraseRepeatRegex.matches(in: t, range: NSRange(location: 0, length: out.length)).reversed() {
            let phrase = out.substring(with: m.range(at: 1))
            out.replaceCharacters(in: m.range, with: phrase)
        }
        return out as String
    }

    // MARK: Spacing

    static func tidy(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            ("[ \\t]+\\n", "\n"), ("\\n[ \\t]+", "\n"), ("[ \\t]{2,}", " "), ("\\n{3,}", "\n\n"),
            ("[ \\t]+([,.;:!?])(?=\\s|$)", "$1"),
            // Left behind by a removed filler: ", ," and ",." and a comma that starts a line.
            (",[ \\t]*,", ","), (",[ \\t]*([.?!])", "$1"), ("(?m)^[ \\t]*[,;][ \\t]*", ""),
        ]
        for (p, r) in rules { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
