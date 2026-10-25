import AppKit
import ApplicationServices

/// Learns names and terms from the fixes you make right after a dictation pastes.
///
/// After a paste into a field Verbatim can read, it looks at that field again when you start the next
/// dictation or after 20 seconds, whichever comes first. Where you replaced a dictated word with a different
/// one that looks like a name or term (the Mac's spell checker doesn't know it, it isn't a number or a link,
/// and it sounds similar), the Ribbon (or the notch, or the floating button) asks whether to remember it. Nothing is learned without a yes.
/// Only the pasted span is compared; nothing else in the field is kept.
@MainActor
final class AutoLearn {
    private struct Watch { let element: AXUIElement; let pasted: String; let cursor: Int; let app: String; let at: Date }
    private var watch: Watch?
    private var timer: Timer?
    /// A "Remember?" question waiting for the Ribbon to be free (it found the fix as a dictation started).
    private var pending: (prompt: FlowBarModel.Prompt, at: Date)?
    weak var app: AppState?

    /// Asks a waiting "Remember?" question once the Ribbon is free again. A question older than a
    /// minute is dropped; it would arrive out of context.
    func showPending() {
        guard let p = pending, let d = app?.dictation, let bar = d.bar else { return }
        guard Date().timeIntervalSince(p.at) < 60 else { pending = nil; return }
        guard !d.isListening, !d.isWorking, bar.model.phase == .idle else { return }
        pending = nil
        bar.ask(p.prompt)
    }

    func watch(element: AXUIElement?, cursor: Int?, pasted: String, appName: String) {
        check()
        guard FlowSettings.shared.autoLearn, let element, let cursor, pasted.split(separator: " ").count >= 1 else { return }
        watch = Watch(element: element, pasted: pasted, cursor: cursor, app: appName, at: Date())
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in Task { @MainActor in self?.check() } }
    }

    /// Compares the field with what was pasted and learns from word swaps.
    func check() {
        timer?.invalidate(); timer = nil
        guard let w = watch else { return }
        watch = nil
        guard let now = AppContext.value(of: w.element) else { return }
        let ns = now as NSString
        guard w.cursor <= ns.length else { return }
        // The pasted words, and the field's words from the paste point on (a little extra for words you added).
        let window = ns.substring(from: w.cursor).prefix(w.pasted.count + 80)
        let a = Self.tokens(w.pasted), b = Self.tokens(String(window))
        let pairs = Self.substitutions(a, b)
        guard !pairs.isEmpty, let app else { return }
        let settings = FlowSettings.shared
        // Every fix is counted too: one made again becomes a Dictionary suggestion, unless you declined it here.
        EditLearner.record(pairs.filter { !settings.declinedFixes.contains("\($0.0.lowercased())→\($0.1.lowercased())") }
            .map { (heard: $0.0, fixed: $0.1) })
        var ask: [(heard: String, fixed: String)] = []
        // Changed on a copy and assigned once: every change to the Dictionary rewrites its whole file.
        var dictionary = app.store.dictionary, added = false
        for (heard, fixed) in pairs where Self.looksLearnable(heard: heard, fixed: fixed) {
            let key = "\(heard.lowercased())→\(fixed.lowercased())"
            if settings.declinedFixes.contains(key) { continue }
            // Already known: quietly add the new way it was heard.
            if let i = dictionary.firstIndex(where: { $0.preferred.caseInsensitiveCompare(fixed) == .orderedSame }) {
                if !dictionary[i].heardAs.contains(where: { $0.caseInsensitiveCompare(heard) == .orderedSame }) { dictionary[i].heardAs.append(heard); added = true }
                continue
            }
            ask.append((heard, fixed))
        }
        if added { app.store.dictionary = dictionary }
        guard !ask.isEmpty, let bar = app.dictation.bar else { return }
        Log.note("auto-learn: asking about \(ask.count) word(s)")
        // Ask in the Ribbon, where you are. Nothing is learned unless you say so.
        let names = ask.map { "“\($0.fixed)”" }.joined(separator: ", ")
        let project = settings.activeProject.flatMap { id in app.store.projects.first { $0.id == id } }
        let source = "Learned from your edit in \(w.app)"
        func remember(_ projectId: UUID?) {
            // Fresh check: the word may have been added meanwhile (another prompt, the Dictionary page).
            let ask = ask.filter { a in !app.store.dictionary.contains { $0.preferred.caseInsensitiveCompare(a.fixed) == .orderedSame } }
            // One assignment, so one write for all the words.
            var dictionary = app.store.dictionary
            for (heard, fixed) in ask {
                dictionary.append(DictionaryEntry(preferred: fixed, heardAs: [heard], learnedFrom: source, projectId: projectId))
            }
            if !ask.isEmpty { app.store.dictionary = dictionary }
            bar.flash(projectId == nil ? "Remembered \(names)" : "Remembered \(names) in \(project?.name ?? "the project")", seconds: 2.5)
        }
        let first = ask[0]
        let prompt = FlowBarModel.Prompt(
            title: ask.count == 1 ? "Remember “\(first.fixed)”?" : "Remember \(ask.count) words?",
            body: ask.count == 1 ? "You changed " : "You changed ",
            quote: ask.count == 1 ? "\(first.heard) → \(first.fixed)" : ask.map { "\($0.heard) → \($0.fixed)" }.joined(separator: ", "),
            after: ". Next time it's spelled your way.",
            // With a project picked, the word goes into that project (Dictionary › Use In changes it later).
            primary: project.map { "Remember in \($0.name)" } ?? "Remember",
            secondary: "Not now",
            seconds: 12,
            onPrimary: { remember(project?.id) },
            onSecondary: { settings.declinedFixes += ask.map { "\($0.heard.lowercased())→\($0.fixed.lowercased())" } },
            onTimeout: { }   // ignored or closed: not learned, and it may ask again next time
        )
        // Usually found as the next dictation starts: then it waits until that one has pasted.
        if !app.dictation.isListening, !app.dictation.isWorking, bar.model.phase == .idle { bar.ask(prompt) }
        else { pending = (prompt, Date()) }
    }

    // MARK: Matching

    static func tokens(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.whitespacesAndNewlines).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// One-for-one word replacements between `a` (pasted) and `b` (now), aligned by longest common subsequence.
    static func substitutions(_ a: [String], _ b: [String]) -> [(String, String)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0, n <= 400, m <= 500 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i].lowercased() == b[j].lowercased() ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0, out: [(String, String)] = []
        var delA: [String] = [], insB: [String] = []
        func flush() {
            if delA.count == 1, insB.count == 1, delA[0].lowercased() != insB[0].lowercased() { out.append((delA[0], insB[0])) }
            else if delA.count == 2, insB.count == 1 { out.append((delA.joined(separator: " "), insB[0])) }   // "lit itz" → "Lititz"
            delA = []; insB = []
        }
        while i < n && j < m {
            if a[i].lowercased() == b[j].lowercased() { flush(); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { delA.append(a[i]); i += 1 }
            else { insB.append(b[j]); j += 1 }
        }
        // Only swaps inside the pasted span count; words typed after it are new writing, not fixes.
        if i < n { flush() }
        return out
    }

    /// A fix worth remembering: a real word swap into something that looks like a name or term.
    static func looksLearnable(heard: String, fixed: String) -> Bool {
        guard fixed.count >= 3, fixed.count <= 40, heard.lowercased() != fixed.lowercased() else { return false }
        if fixed.rangeOfCharacter(from: .decimalDigits) != nil || fixed.contains("/") || fixed.contains("@") || fixed.contains(".") { return false }
        // A case-only change, or a common word, is grammar, not vocabulary.
        let checker = NSSpellChecker.shared
        let misspelled = checker.checkSpelling(of: fixed, startingAt: 0).location != NSNotFound
        let capitalizedName = fixed.first?.isUppercase == true && fixed.dropFirst().contains { $0.isLowercase }
        guard misspelled || capitalizedName else { return false }
        // It should sound like what was heard: similar letters (a mishearing), not a different word altogether.
        return similarity(heard.lowercased().replacingOccurrences(of: " ", with: ""), fixed.lowercased()) >= 0.45
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count), cur = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}
