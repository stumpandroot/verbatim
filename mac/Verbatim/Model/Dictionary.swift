import Foundation

/// A word Verbatim spells your way. "heardAs" lists what the engine tends to produce instead.
struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var preferred: String
    var heardAs: [String]
    var enabled = true
    var learnedFrom: String      // transcript title or "Added by you"
    var projectId: UUID? = nil   // nil = every transcript; otherwise only that project's
    var createdAt = Date()
}

enum DictionaryApplier {
    /// Applies enabled entries as whole-word, case-insensitive replacements and records each change,
    /// so every fix is visible and reversible. Nothing is replaced unless it matches a listed "heard as" form.
    static func apply(_ entries: [DictionaryEntry], to segments: inout [Segment], project: UUID? = nil) -> [Correction] {
        var out: [Correction] = []
        let active = entries.filter { $0.enabled && !$0.preferred.isEmpty && ($0.projectId == nil || $0.projectId == project) }
        guard !active.isEmpty else { return [] }
        // Each pattern is compiled once per call, not once per segment, in the same entry × heard-as order.
        var rules: [(re: NSRegularExpression, heard: String, preferred: String, template: String)] = []
        for e in active {
            for heard in e.heardAs where !heard.trimmingCharacters(in: .whitespaces).isEmpty {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                rules.append((re, heard, e.preferred, NSRegularExpression.escapedTemplate(for: e.preferred)))
            }
        }
        for i in segments.indices {
            for r in rules {
                let text = segments[i].text
                let range = NSRange(text.startIndex..., in: text)
                if r.re.firstMatch(in: text, range: range) != nil {
                    let fixed = r.re.stringByReplacingMatches(in: text, range: range, withTemplate: r.template)
                    if fixed != text {
                        segments[i].text = fixed
                        out.append(Correction(segmentId: segments[i].id, from: r.heard, to: r.preferred, byDictionary: true))
                    }
                }
            }
        }
        return out
    }
}
