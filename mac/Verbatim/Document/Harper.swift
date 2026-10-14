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
        let range: Range<String.Index>
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
        let lower = Set(ignore.map { $0.lowercased() })
        var out: [Lint] = []
        for (i, r) in raw.enumerated() {
            guard r.start >= 0, r.end <= scalars.count, r.start < r.end else { continue }
            let a = scalars.index(scalars.startIndex, offsetBy: r.start)
            let b = scalars.index(scalars.startIndex, offsetBy: r.end)
            let original = String(text[a..<b])
            if r.kind == "Spelling", lower.contains(original.lowercased().trimmingCharacters(in: .punctuationCharacters)) { continue }
            out.append(Lint(id: i, range: a..<b, original: original, kind: r.kind, message: r.message, priority: r.priority, suggestions: r.suggestions))
        }
        return out
    }
}
