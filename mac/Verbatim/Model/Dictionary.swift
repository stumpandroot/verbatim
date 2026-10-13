import Foundation

/// A word Verbatim spells your way. "heardAs" lists what the engine tends to produce instead.
struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var preferred: String
    var heardAs: [String]
    var enabled = true
    var learnedFrom: String      // transcript title or "Added by you"
    var createdAt = Date()
}

enum DictionaryApplier {
    /// Applies enabled entries as whole-word, case-insensitive replacements and records each change,
    /// so every fix is visible and reversible. Nothing is replaced unless it matches a listed "heard as" form.
    static func apply(_ entries: [DictionaryEntry], to segments: inout [Segment]) -> [Correction] {
        var out: [Correction] = []
        let active = entries.filter { $0.enabled && !$0.preferred.isEmpty }
        guard !active.isEmpty else { return [] }
        for i in segments.indices {
            for e in active {
                for heard in e.heardAs where !heard.trimmingCharacters(in: .whitespaces).isEmpty {
                    let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
                    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                    let text = segments[i].text
                    let range = NSRange(text.startIndex..., in: text)
                    if re.firstMatch(in: text, range: range) != nil {
                        let fixed = re.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: e.preferred))
                        if fixed != text {
                            segments[i].text = fixed
                            out.append(Correction(segmentId: segments[i].id, from: heard, to: e.preferred, byDictionary: true))
                        }
                    }
                }
            }
        }
        return out
    }
}
