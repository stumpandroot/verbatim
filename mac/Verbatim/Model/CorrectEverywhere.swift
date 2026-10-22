import Foundation

/// "Fix all": after you correct a word or phrase in one line, the same misrecognition elsewhere in the transcript.
/// Matching is whole words, ignoring case; each fix keeps the case of the word it replaces ("teh" → "the", "Teh" →
/// "The", "TEH" → "THE"). Foundation only, so mac/tools/test-privacy.sh tests it. Transcript+Trust.swift applies the
/// plan through the corrections layer, so every fix is undoable and the Original tab's engine words stay untouched.
enum CorrectEverywhere {
    /// Whole-word occurrences of `heard` in `text`, ignoring case (UTF-16 ranges). Spaces inside a phrase match any run
    /// of spaces, so "new york" finds "New  York".
    static func ranges(of heard: String, in text: String) -> [NSRange] {
        let words = heard.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        let body = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+")
        let pattern = "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// The fix in the case of the text it replaces: all capitals stay all capitals, a capital first letter stays one.
    /// A fix is never lowercased, so a name you capitalized ("jon" → "Jon") stays capitalized everywhere.
    static func casePreserved(_ fix: String, for found: String) -> String {
        let letters = found.filter(\.isLetter)
        guard let first = letters.first else { return fix }
        if letters.count > 1, letters == letters.uppercased(), letters != letters.lowercased() { return fix.uppercased() }
        if first.isUppercase, let f = fix.first, f.isLowercase { return f.uppercased() + fix.dropFirst() }
        return fix
    }

    /// One replacement in a text: where, what was there, and what goes in.
    struct Change: Equatable {
        var range: NSRange
        var found: String
        var with: String
    }

    /// The changes for one text. Places that already read the fix (in the right case) are left alone.
    static func changes(heard: String, fix: String, in text: String) -> [Change] {
        let ns = text as NSString
        return ranges(of: heard, in: text).compactMap { r in
            let found = ns.substring(with: r)
            let with = casePreserved(fix, for: found)
            return found == with ? nil : Change(range: r, found: found, with: with)
        }
    }

    /// How many places across `texts` a fix would change.
    static func count(heard: String, fix: String, in texts: [String]) -> Int {
        guard !heard.trimmingCharacters(in: .whitespaces).isEmpty, heard != fix else { return 0 }
        return texts.reduce(0) { $0 + changes(heard: heard, fix: fix, in: $1).count }
    }

    /// The button's title: "Fix all 4", or "Fix 1 more".
    static func buttonTitle(_ n: Int) -> String { n == 1 ? "Fix 1 more" : "Fix all \(n)" }

    /// The banner's line: "“teh” appears 4 more times in this transcript."
    static func bannerText(heard: String, count n: Int) -> String {
        "“\(heard)” appears \(n == 1 ? "once more" : "\(n) more times") in this transcript."
    }
}
