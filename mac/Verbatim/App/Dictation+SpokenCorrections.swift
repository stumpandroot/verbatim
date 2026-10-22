import AppKit

/// What the Ribbon says after a paste that a spoken correction changed ("Removed “meet at 2”"), and the text as
/// you said it, for Copy as spoken.
struct SpokenCorrectionNotice: Sendable {
    var summary: String
    var asSpoken: String
}

extension DictationController {
    /// The notice for a dictation whose words a spoken correction changed, or nil. Big corrections (start over,
    /// two or more sentences) always get one; small ones only the first few times (`SpokenCorrections.takeNotice`).
    /// Pure string work plus the rules text, so it runs on the dictation's background task.
    nonisolated static func correctionNotice(raw: String, request: FlowCleanup.Request) -> SpokenCorrectionNotice? {
        guard request.spokenCorrections, request.level != .literal, request.category != .code else { return nil }
        let found = CleanupPrepass.spokenCorrections(in: raw)
        guard SpokenCorrections.takeNotice(for: found) else { return nil }
        var spoken = request
        spoken.spokenCorrections = false
        return SpokenCorrectionNotice(summary: SpokenCorrections.summary(found), asSpoken: FlowCleanup.rulesOnly(spoken))
    }

    /// The Ribbon card after the paste: what changed, Copy as spoken, and Turn off.
    func showCorrectionNotice(_ n: SpokenCorrectionNotice) {
        bar?.ask(.init(
            title: "You corrected yourself",
            body: n.summary + ".",
            quote: nil,
            primary: "Copy as spoken",
            secondary: "Turn off",
            seconds: 8,
            onPrimary: { [weak self] in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(n.asSpoken, forType: .string)
                self?.bar?.flash("Copied as spoken. Press ⌘Z, then ⌘V, to use it instead.", seconds: 4)
            },
            onSecondary: { [weak self] in
                SpokenCorrections.enabled = false
                self?.bar?.flash("Spoken corrections are off. Turn them back on in Settings.", seconds: 4)
            }
        ))
    }
}
