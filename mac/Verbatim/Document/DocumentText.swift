import Foundation

/// The Document view's text: paragraphs built from the transcript, then edited by the person or by the polish
/// tools. Speaker labels appear only when there are two or more speakers. Timecodes never appear here; the
/// Transcript view keeps them.
enum DocumentText {
    /// Builds paragraphs from segments. Consecutive segments by the same speaker merge; a single speaker's
    /// text breaks into paragraphs at pauses over 2 s or every ~5 segments.
    static func build(from t: Transcript) -> String {
        let multi = t.speakers.count >= 2
        var paras: [String] = []
        var cur: [String] = []
        var curSpeaker: String? = nil
        var count = 0
        func flush() {
            guard !cur.isEmpty else { return }
            let text = cur.joined(separator: " ")
            if multi, let s = curSpeaker, let name = t.speakerName(s) { paras.append("\(name): \(text)") } else { paras.append(text) }
            cur = []; count = 0
        }
        var lastEnd: Double = 0
        for s in t.segments {
            let text = s.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let speakerChanged = multi && s.speaker != curSpeaker
            let longPause = s.start - lastEnd > 2.0
            if speakerChanged || (!multi && (longPause || count >= 5) && !cur.isEmpty) { flush() }
            curSpeaker = s.speaker
            cur.append(text); count += 1
            lastEnd = s.end
        }
        flush()
        return paras.joined(separator: "\n\n")
    }

    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Splits "Name: text" when the document carries speaker labels.
    static func split(_ paragraph: String, speakers: [String]) -> (speaker: String?, text: String) {
        CleanupGuard.splitLabel(paragraph, speakers: speakers)
    }

    /// The names paragraphs can start with: every speaker's name when there are two or more (as `build` writes
    /// them), none otherwise.
    static func labelNames(_ t: Transcript) -> [String] {
        t.speakers.count >= 2 ? t.speakers.map(\.label) : []
    }

    /// Saved Cleaned text as it's shown: a literal "Name: " left by builds up to 184 at a paragraph start is hidden
    /// when no speaker is called "Name" (`CleanupGuard.hidePlaceholderLabels`). Typing in the Cleaned text saves
    /// the text as shown, so the stored copy is fixed by the next edit.
    static func shown(_ document: String, in t: Transcript) -> String {
        CleanupGuard.hidePlaceholderLabels(document, speakers: t.speakers.map(\.label))
    }
}
