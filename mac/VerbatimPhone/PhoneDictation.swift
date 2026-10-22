import Foundation

/// Dictation cleanup on the iPhone: the Mac's `FlowCleanup` (Apple's on-device model on iOS 26, then
/// `DictationFormatter`), with the same fallbacks. Without Apple Intelligence (older iPhones, the simulator, the
/// screenshot tour) Clean and Polished are the rules: `CleanupPrepass.clean`, then the formatter.
///
/// The destination comes from the keyboard's format chip (Auto, Email, Message, Note; `KeyboardFormat`), which
/// works Auto out from the host app when the build can read it and otherwise from the text field. Dictation inside
/// Verbatim is everything else. Lists are always plain ("•" and "1."),
/// because iOS text fields show "- " as typed. The level is Settings › Transcription › Cleanup, saved under the
/// Mac's key (`flow.cleanup`) but per device, never synced.
enum PhoneDictation {
    /// The longest the model may take on a keyboard dictation. Past it, the rule-based text goes in.
    static let keyboardBudget: Double = 1.2

    @MainActor static var level: CleanupLevel { FlowSettings.shared.cleanup }

    /// Where the keyboard is typing. In order: Verbatim itself (everything else); the category the keyboard's
    /// format chip picked (`chosen`, an `AppCategory` raw value); the host app's kind when it's known (full builds
    /// only); otherwise work messages, as before the chip.
    static func category(host: String?, chosen: String? = nil, own: String? = Bundle.main.bundleIdentifier) -> AppCategory {
        if let host, let own, host == own { return .other }
        if let chosen, let c = AppCategory(rawValue: chosen) { return c }
        if let kind = KeyboardFormat.classify(host: host)?.kind {
            return AppCategory(rawValue: KeyboardFormat.auto.category(hostKind: kind)) ?? .work
        }
        return .work
    }

    /// The request for a dictation. Style is casual, as on the Mac for work messages and everything else.
    static func request(raw: String, level: CleanupLevel, category: AppCategory, vocabulary: [String], snippets: [Snippet],
                        budget: Double?) -> FlowCleanup.Request {
        FlowCleanup.Request(raw: raw, level: level, style: .casual, category: category, vocabulary: vocabulary,
                            useContext: false, snippets: snippets, format: DictationFormatter.Options(style: .plain),
                            timeBudget: budget)
    }

    /// Cleans one dictation. With a `budget`, the whole cleanup (model included) is held to it: if Apple's model
    /// hasn't answered in time, the rule-based text is returned instead, even if the model ignores cancellation.
    static func clean(_ r: FlowCleanup.Request, budget: Double?) async -> FlowCleanup.Result {
        guard let budget else { return await FlowCleanup.run(r) }
        // FlowCleanup stops the model at the budget itself; this backstop allows a little for the formatter.
        if let out = await FluidEngine.race(seconds: budget + 0.15, { await FlowCleanup.run(r) }) { return out }
        Log.note("keyboard cleanup: over \(Int(budget * 1000)) ms; inserted the rule-based text")
        return FlowCleanup.Result(text: FlowCleanup.rulesOnly(r), cleaned: false, note: "Cleanup took too long; pasted without it")
    }
}
