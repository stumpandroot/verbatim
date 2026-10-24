import Foundation

/// Guards around Clean up and Tone (Polish), shared by Mac and iPhone. Foundation only, so the Linux logic tests
/// (mac/tools/test-cleanup.sh) run the same code.
///
/// - The model never sees a speaker label. A paragraph's real label (one of the transcript's speaker names, as
///   `DocumentText.build` writes it) comes off before the model and goes back on after.
/// - A label the model invents ("Name:", "Speaker:", "Tim:") is dropped when its input paragraph didn't start
///   with it. Apple's small on-device model copies example labels from its instructions into paragraphs that had none.
/// - At levels that remove fillers, the rule-based filler pass (`CleanupPrepass.removeFillers`, the same rules as
///   "Cleaned with rules") runs on the model's answer too, so a stray "um" or "uh" never survives.
/// - Cleaned text saved before this fix can hold literal "Name: " labels; `hidePlaceholderLabels` hides them.
enum CleanupGuard {

    // MARK: Speaker labels

    /// Splits "Name: text" when `name` is one of `speakers`. The longest matching name wins, so "Sam Lee" beats "Sam".
    static func splitLabel(_ paragraph: String, speakers: [String]) -> (speaker: String?, text: String) {
        for name in speakers.sorted(by: { $0.count > $1.count }) where !name.isEmpty && paragraph.hasPrefix(name + ": ") {
            return (name, String(paragraph.dropFirst(name.count + 2)))
        }
        return (nil, paragraph)
    }

    /// Puts a label back in front of a paragraph's text.
    static func attach(_ label: String?, _ text: String) -> String {
        guard let label, !text.isEmpty else { return text }
        return "\(label): \(text)"
    }

    /// Words a model writes as a label when it copies a template. Never kept unless they are a real speaker name.
    static let placeholderWords: Set<String> = ["name", "speaker", "speaker name", "speaker label", "label", "paragraph",
                                                "transcript", "text", "edited paragraph", "output", "answer", "result"]

    /// A label at the start of a line: one to three capitalized words (or "Speaker 2"), optionally bold or in
    /// brackets, then a colon. "Name:", "**Tim:**", "[Speaker 1]:", "Paragraph:".
    private static let labelRegex = try! NSRegularExpression(pattern:
        "^[ \\t]*(?:\\*\\*)?[\\[<]?((?:\\p{Lu}[\\p{L}'’.\\-]*)(?:[ ](?:\\p{Lu}[\\p{L}'’.\\-]*|\\d+)){0,2})[\\]>]?(?:\\*\\*)?[ \\t]*:(?:\\*\\*)?[ \\t]*(?:\\n[ \\t]*)?")

    /// The label at the start of `s` and the length it takes (label, colon, and the space or line break after), or nil.
    static func leadingLabel(_ s: String) -> (label: String, length: Int)? {
        let ns = s as NSString
        guard let m = labelRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let label = ns.substring(with: m.range(at: 1))
        // A URL ("Https://") or a time ("At 10:30") isn't a label.
        let after = m.range.location + m.range.length
        if after < ns.length, let next = ns.substring(from: after).first, next == "/" || (label.last?.isNumber == true && next.isNumber) {
            return nil
        }
        return (label, m.range.length)
    }

    /// Drops a label the model put in front of its answer when `input` didn't start with that label. Keeps a real
    /// speaker name only when the input had it (labels are detached before the model, so it never should).
    static func dropInventedLabel(_ output: String, input: String, speakers: [String] = []) -> String {
        var out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // At most twice: "Paragraph: Name: text".
        for _ in 0..<2 {
            guard let (label, length) = leadingLabel(out) else { break }
            if inputHasLabel(input, label) { break }
            let lower = label.lowercased()
            // The model kept the input's own first words and only added a colon ("Okay: so" from "Okay so"). Keep
            // the words; drop only the colon. Never for a placeholder ("Name").
            if !placeholderWords.contains(lower), !speakers.contains(label), startsWithWords(input, label) {
                let ns = out as NSString
                let colon = ns.range(of: ":", range: NSRange(location: 0, length: length))
                if colon.location != NSNotFound {
                    out = (ns.replacingCharacters(in: colon, with: "") as String).replacingOccurrences(of: "**", with: "")
                }
                break
            }
            out = String((out as NSString).substring(from: length)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A placeholder label at the start of a later line ("…\nName: more") goes too.
        if out.contains(":") {
            out = out.components(separatedBy: "\n").enumerated().map { i, line in
                guard i > 0, let (label, length) = leadingLabel(line), placeholderWords.contains(label.lowercased()),
                      !speakers.contains(label), !inputHasLabel(input, label) else { return line }
                return (line as NSString).substring(from: length)
            }.joined(separator: "\n")
        }
        return out
    }

    private static func inputHasLabel(_ input: String, _ label: String) -> Bool {
        guard let (l, _) = leadingLabel(input.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return l.caseInsensitiveCompare(label) == .orderedSame
    }

    private static func startsWithWords(_ input: String, _ label: String) -> Bool {
        let words = { (s: String) in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }) }
        let l = words(label), i = words(input)
        return !l.isEmpty && i.count >= l.count && Array(i.prefix(l.count)) == l
    }

    // MARK: Fillers

    /// Filler sounds (um, uh) and filler phrases ("you know," "I mean,") removed by rules, the same rules as dictation's
    /// "Cleaned with rules". Spacing tidied and the first letter capitalized. Empty when the text was only fillers.
    static func removeFillers(_ s: String) -> String {
        let t = CleanupPrepass.tidy(CleanupPrepass.removeFillers(s))
        // What's left of "Um." or "Uh, um…": only punctuation.
        if !t.contains(where: { $0.isLetter || $0.isNumber }) { return "" }
        return CleanupPrepass.capitalizeFirst(t)
    }

    // MARK: One paragraph

    /// A paragraph's text before the model: its real speaker label off.
    static func prepare(_ paragraph: String, speakers: [String]) -> (label: String?, text: String) {
        let (label, text) = splitLabel(paragraph, speakers: speakers)
        return (label, text)
    }

    /// A paragraph after the model: an invented label dropped, fillers removed when the level does that, and the
    /// real label back on. `output` is the model's answer (or the input itself when the model was skipped).
    /// Empty when nothing but fillers was left.
    static func finish(_ output: String, input: String, label: String?, speakers: [String], removeFillers fillers: Bool) -> String {
        var text = dropInventedLabel(output, input: input, speakers: speakers)
        if fillers { text = removeFillers(text) }
        return attach(label, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Saved text

    /// Hides a literal "Name: " (or "**Name:**") at the start of a paragraph when no speaker is called "Name".
    /// Cleaned text saved by builds up to 184 can hold these. Everything else, separators included, is unchanged.
    static func hidePlaceholderLabels(_ text: String, speakers: [String]) -> String {
        guard text.contains("Name:"), !speakers.contains(where: { $0.caseInsensitiveCompare("Name") == .orderedSame }) else { return text }
        let paragraphs = text.components(separatedBy: "\n\n")
        var changed = false
        let fixed = paragraphs.map { p -> String in
            let lead = p.prefix(while: { $0 == " " || $0 == "\n" || $0 == "\t" })
            let rest = p.dropFirst(lead.count)
            for prefix in ["**Name:**", "**Name**:", "Name:"] where rest.hasPrefix(prefix) {
                changed = true
                return String(lead) + String(rest.dropFirst(prefix.count).drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
            }
            return p
        }
        // A paragraph that was only "Name:" goes away.
        return changed ? fixed.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n") : text
    }
}
