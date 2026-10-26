import Foundation

/// Everyday mix-ups that are always wrong where they're fixed: "could of been", "for all intensive purposes",
/// "sneak peak", "me an you". The fixes live in Resources/EverydayFixes.json, which mac/tools/vocab_check.py checks
/// (each fix's examples and must-stay sentences, and a file of ordinary sentences no fix may change).
///
/// Runs on dictation only, right before Harper's grammar pass (`FlowCleanup.grammar`), so a misheard "an" for "and"
/// is fixed before Harper's a/an rule sees it. The Built-in vocabulary switch turns these off too.
/// Each pattern is case-insensitive; the first group that matched is replaced (the whole match without one), and a
/// capital first letter stays capital.
enum EverydayFixes {
    struct Fix {
        let id: String
        let re: NSRegularExpression
        let replace: String
    }

    private struct File: Codable {
        var version: Int
        var fixes: [Entry]
    }

    private struct Entry: Codable {
        var id: String
        var pattern: String
        var replace: String
        var examples: [[String]]
        var keep: [String]
    }

    /// Compiled once; NSRegularExpression is safe to share across threads.
    static let fixes: [Fix] = load(Bundle.main.url(forResource: "EverydayFixes", withExtension: "json"))

    /// The examples and must-stay sentences from the file, for the self-test.
    static let samples: (examples: [(String, String)], keep: [String]) = loadSamples(Bundle.main.url(forResource: "EverydayFixes", withExtension: "json"))

    static func load(_ url: URL?) -> [Fix] {
        guard let url, let data = try? Data(contentsOf: url) else { Log.note("everyday fixes: file missing"); return [] }
        do {
            return try JSONDecoder().decode(File.self, from: data).fixes.compactMap { e in
                guard let re = try? NSRegularExpression(pattern: e.pattern, options: [.caseInsensitive, .anchorsMatchLines]) else {
                    Log.note("everyday fixes: \(e.id) doesn't compile"); return nil
                }
                return Fix(id: e.id, re: re, replace: e.replace)
            }
        } catch { Log.note("everyday fixes: unreadable (\(error))"); return [] }
    }

    private static func loadSamples(_ url: URL?) -> (examples: [(String, String)], keep: [String]) {
        guard let url, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return ([], []) }
        let examples = file.fixes.flatMap { $0.examples.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil } }
        return (examples, file.fixes.flatMap(\.keep))
    }

    /// On with Settings › Built-in vocabulary.
    static var isOn: Bool { BuiltInVocabulary.isOn }

    /// `text` with every fix applied, when the switch is on.
    static func apply(_ text: String) -> String {
        guard isOn else { return text }
        return apply(text, fixes: fixes)
    }

    /// The pass itself, with the fixes given (the self-test passes the bundled ones whatever the switch says).
    static func apply(_ text: String, fixes: [Fix]) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for f in fixes {
            // Curly apostrophes match as straight ones. Both are one UTF-16 unit, so the ranges line up.
            let plain = out.replacingOccurrences(of: "\u{2019}", with: "'")
            let matches = f.re.matches(in: plain, range: NSRange(location: 0, length: (plain as NSString).length))
            guard !matches.isEmpty else { continue }
            let ns = NSMutableString(string: out)
            for m in matches.reversed() {
                let r = span(m)
                ns.replaceCharacters(in: r, with: matchCase(ns.substring(with: r), f.replace))
            }
            out = ns as String
        }
        return out
    }

    /// The first group that took part, or the whole match.
    private static func span(_ m: NSTextCheckingResult) -> NSRange {
        var i = 1
        while i < m.numberOfRanges {
            let r = m.range(at: i)
            if r.location != NSNotFound { return r }
            i += 1
        }
        return m.range
    }

    /// All capitals stay all capitals; a capital first letter stays capital.
    static func matchCase(_ found: String, _ replacement: String) -> String {
        if found.count > 1, found == found.uppercased(), found != found.lowercased() { return replacement.uppercased() }
        if found.first?.isUppercase == true { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        return replacement
    }
}
