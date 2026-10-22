import Foundation

/// A word Verbatim spells your way. "heardAs" lists what the engine tends to produce instead.
struct DictionaryEntry: Codable, Identifiable, Equatable, SyncEntry {
    var id = UUID()
    var preferred: String
    var heardAs: [String]
    var enabled = true
    var learnedFrom: String      // transcript title or "Added by you"
    var projectId: UUID? = nil   // nil = every transcript; otherwise only that project's
    var createdAt = Date()
    /// When this entry last changed on any device (SyncMerge). Nil in files from older builds.
    var updatedAt: Date? = nil
}

enum DictionaryApplier {
    /// Applies enabled entries as whole-word, case-insensitive replacements and records each change,
    /// so every fix is visible and reversible. Nothing is replaced unless it matches a listed "heard as" form.
    /// Then the built-in vocabulary runs (when it's on and `builtIn` is true); your entries win over it.
    static func apply(_ entries: [DictionaryEntry], to segments: inout [Segment], project: UUID? = nil, builtIn: Bool = true) -> [Correction] {
        var out = applyOwn(entries, to: &segments, project: project)
        // The built-in pass records into the same list, so fixes it makes move your entries' spans with the text.
        if builtIn { BuiltInVocabulary.apply(to: &segments, respecting: entries, into: &out) }
        return out
    }

    private static func applyOwn(_ entries: [DictionaryEntry], to segments: inout [Segment], project: UUID?) -> [Correction] {
        var out: [Correction] = []
        let active = entries.filter { $0.enabled && !$0.preferred.isEmpty && ($0.projectId == nil || $0.projectId == project) }
        guard !active.isEmpty else { return [] }
        // Each pattern is compiled once per call, not once per segment, in the same entry × heard-as order.
        var rules: [(re: NSRegularExpression, heard: String, preferred: String)] = []
        for e in active {
            for heard in e.heardAs where !heard.trimmingCharacters(in: .whitespaces).isEmpty {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                rules.append((re, heard, e.preferred))
            }
        }
        for i in segments.indices {
            for r in rules {
                let text = segments[i].text
                let ranges = r.re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
                guard !ranges.isEmpty else { continue }
                // Each match is recorded with where it went, so Undo restores exactly those words.
                CorrectionEdits.apply(ranges, in: &segments, at: i, to: r.preferred, label: r.heard, byDictionary: true, corrections: &out)
            }
        }
        return out
    }
}
