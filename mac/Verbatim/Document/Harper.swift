import Foundation

/// Harper's offline grammar and spelling rules (Apache-2.0, bundled as a static library). Offsets come back as
/// Unicode-scalar indices; `Lint.range` converts them for the Swift string.
enum Harper {
    struct Suggestion: Codable, Hashable {
        let kind: String        // replace | insert_after | remove
        let text: String
    }
    struct RawLint: Codable {
        let start: Int, end: Int
        let kind: String, message: String
        let priority: Int
        let suggestions: [Suggestion]
    }
    struct Lint: Identifiable, Hashable {
        let id: Int
        /// UTF-16 range in `source`. Plain integers, so a lint can never index into a different string.
        let nsRange: NSRange
        let source: String
        let original: String
        let kind: String          // Spelling, Grammar, Capitalization, Punctuation, Redundancy, …
        let message: String
        let priority: Int
        let suggestions: [Suggestion]
        var isSpelling: Bool { kind == "Spelling" }
        var fix: String? {
            guard let s = suggestions.first else { return nil }
            switch s.kind {
            case "replace": return s.text
            case "insert_after": return original + s.text
            case "remove": return ""
            default: return nil
            }
        }
    }

    static var available: Bool { harper_version() >= 1 }

    /// Lints `text`. Words in `ignore` (speaker names, Dictionary entries) never produce spelling lints.
    static func lint(_ text: String, ignore: Set<String> = []) -> [Lint] {
        guard let p = text.withCString({ harper_lint($0, 0) }) else { return [] }
        defer { harper_free(p) }
        let json = String(cString: p)
        guard let data = json.data(using: .utf8), let raw = try? JSONDecoder().decode([RawLint].self, from: data) else { return [] }
        let scalars = text.unicodeScalars
        // Ignore whole phrases and each word in them, so "Tim Medina" or "Tim_Medina" covers "Medina" too.
        let wordBreaks = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "_-"))
        var lower = Set(ignore.map { $0.lowercased() })
        for phrase in ignore { for w in phrase.lowercased().components(separatedBy: wordBreaks) where !w.isEmpty { lower.insert(w) } }
        // Speaker labels at the start of a paragraph ("Tim Medina: …") are names, not prose: no lints at all.
        var protected: [Range<String.Index>] = []
        var cursor = text.startIndex
        for para in text.components(separatedBy: "\n\n") {
            let start = cursor
            if let colon = para.range(of: ": ") {
                let label = String(para[para.startIndex..<colon.lowerBound]).lowercased()
                if ignore.contains(where: { $0.lowercased() == label }) {
                    let end = text.index(start, offsetBy: para.distance(from: para.startIndex, to: colon.upperBound))
                    protected.append(start..<end)
                }
            }
            cursor = text.index(start, offsetBy: para.count, limitedBy: text.endIndex) ?? text.endIndex
            cursor = text.index(cursor, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
        }
        var out: [Lint] = []
        for (i, r) in raw.enumerated() {
            guard r.start >= 0, r.end <= scalars.count, r.start < r.end else { continue }
            let a = scalars.index(scalars.startIndex, offsetBy: r.start)
            let b = scalars.index(scalars.startIndex, offsetBy: r.end)
            let original = String(text[a..<b])
            if protected.contains(where: { $0.overlaps(a..<b) }) { continue }
            if r.kind == "Spelling" {
                let words = original.lowercased().trimmingCharacters(in: .punctuationCharacters).components(separatedBy: wordBreaks).filter { !$0.isEmpty }
                if lower.contains(original.lowercased().trimmingCharacters(in: .punctuationCharacters)) || (!words.isEmpty && words.allSatisfy(lower.contains)) { continue }
            }
            out.append(Lint(id: i, nsRange: NSRange(a..<b, in: text), source: text, original: original, kind: r.kind, message: r.message, priority: r.priority, suggestions: r.suggestions))
        }
        return out
    }
}
