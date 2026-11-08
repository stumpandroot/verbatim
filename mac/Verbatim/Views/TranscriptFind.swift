import SwiftUI
import AppKit

// Find in the open transcript (MAC-22; DESIGN.md §6.9 and §11): ⌘F on a transcript opens a find bar over the tab you're
// reading, as the iPhone's Find does: Original's lines, the Cleaned text, or the Summary. Matches are in butter
// (`ReadingHighlight` on Original and Summary, the editor's own marks on Cleaned), the current one is the selected line
// on Original and underlined on Cleaned and Summary, and it scrolls into view; ⌘G and ⇧⌘G (or Return in the field, or
// the bar's arrows) step through them and wrap, and Esc or Done closes. Switching tabs keeps the bar and its words and
// finds in the new tab; Review and a template's result have no find, so ⌘F there finds in Original. Elsewhere ⌘F opens
// Search or ask, and ⌘K opens that panel on every screen (App/AppCommands.swift). The rules are `PageFind`
// (App/MacCommandRules.swift).

extension TranscriptView.Mode {
    /// The find bar's scope on this tab, or nil where ⌘F finds in Original instead (Review, a template's result).
    var findScope: FindScope? {
        switch self {
        case .original: return .original
        case .document: return .cleaned
        case .summary: return .summary
        case .review, .result: return nil
        }
    }
}

/// The find bar's state for the transcript on screen. One per app, as the window is.
@MainActor
final class TranscriptFind: ObservableObject {
    static let shared = TranscriptFind()

    @Published private(set) var open = false
    /// The tab the bar finds in.
    @Published private(set) var scope: FindScope = .original
    @Published var query = "" { didSet { if query != oldValue { recompute(keepCurrent: false) } } }
    @Published private(set) var matches: [PageFindMatch] = []
    @Published private(set) var current: Int?
    /// Changes each time ⌘F is pressed, so the field takes focus again even while the bar is open.
    @Published private(set) var focusToken = 0
    /// The text searched, in reading order (set by the tab as its text changes): Original's lines, the Cleaned text as
    /// one line, or the Summary's overview and then each key point.
    private var lines: [String] = []
    /// Original's line IDs, beside `lines`; empty on Cleaned and Summary.
    private var lineIDs: [UUID] = []

    /// Find Next and Find Previous have somewhere to go.
    var canStep: Bool { open && !matches.isEmpty }
    /// The current match: its line in `lines` and its range in that line's text.
    var currentMatch: PageFindMatch? { current.flatMap { c in matches.indices.contains(c) ? matches[c] : nil } }
    /// The Original line the current match is on (nil on Cleaned and Summary).
    var currentLine: UUID? {
        guard scope == .original, let m = currentMatch else { return nil }
        return lineIDs[safe: m.line]
    }
    /// The bar is open on this tab.
    func shows(on scope: FindScope) -> Bool { open && self.scope == scope }
    var countLabel: String { PageFind.countLabel(current: current, count: matches.count, query: query) }
    /// The field's prompt, naming the tab: "Find in transcript", "Find in Cleaned", or "Find in Summary".
    var prompt: String { PageFind.prompt(scope) }
    /// The query the lines mark, while the bar is open.
    var highlight: String? { open && !query.trimmingCharacters(in: .whitespaces).isEmpty ? query : nil }

    /// ⌘F: opens the bar on `scope` (or moves it there), and puts the focus in its field.
    func show(in scope: FindScope = .original) {
        if self.scope != scope { retarget(scope) }
        if !open { open = true }
        focusToken += 1
    }

    /// Another tab: the bar keeps its words and finds in the new tab, which sets its text as it draws.
    func retarget(_ scope: FindScope) {
        guard self.scope != scope else { return }
        self.scope = scope
        lines = []; lineIDs = []
        matches = []
        current = nil
    }

    func close() {
        guard open || !query.isEmpty else { return }
        open = false
        query = ""
        matches = []
        current = nil
    }

    func next() { step(forward: true) }
    func previous() { step(forward: false) }

    private func step(forward: Bool) {
        guard canStep else { NSSound.beep(); return }
        current = PageFind.step(from: current, count: matches.count, forward: forward)
    }

    /// The transcript's lines changed (opened, edited, another tab of words): match again, keeping the current match
    /// where it still exists.
    func setLines(_ new: [(id: UUID, text: String)]) {
        let texts = new.map(\.text), ids = new.map(\.id)
        guard texts != lines || ids != lineIDs else { return }
        lines = texts; lineIDs = ids
        recompute(keepCurrent: true)
    }

    /// The Cleaned text (one line) or the Summary's lines changed: match again, keeping the current match where it
    /// still exists.
    func setTexts(_ texts: [String]) {
        guard texts != lines || !lineIDs.isEmpty else { return }
        lines = texts; lineIDs = []
        recompute(keepCurrent: true)
    }

    private func recompute(keepCurrent: Bool) {
        let found = PageFind.matches(in: lines, query: query)
        let old = keepCurrent ? current : nil
        matches = found
        if found.isEmpty { current = nil }
        else if let old, old < found.count { current = old }
        else { current = 0 }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The find bar: a paper card at the top of the reading column with the field, "3 of 12", the previous and next
/// arrows, and Done. Opaque: text never sits on glass. It appears at once (it opens from ⌘F; keyboard actions don't
/// animate, DESIGN.md §7).
struct TranscriptFindBar: View {
    @ObservedObject var find: TranscriptFind
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Refined.mute)
                .accessibilityHidden(true)
            TextField(find.prompt, text: $find.query)
                .textFieldStyle(.plain)
                .refinedFont(.body)
                .foregroundStyle(Refined.ink)
                .focused($focused)
                .onSubmit { find.next() }
                .accessibilityLabel(find.prompt)
            Text(find.countLabel).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                .lineLimit(1).fixedSize()
                .accessibilityLabel(find.countLabel)
            Button { find.previous() } label: { Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26) }
                .buttonStyle(RefinedPress()).foregroundStyle(Refined.ink)
                .disabled(!find.canStep)
                .help("Previous match (⇧⌘G)")
                .accessibilityLabel("Previous match")
            Button { find.next() } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26) }
                .buttonStyle(RefinedPress()).foregroundStyle(Refined.ink)
                .disabled(!find.canStep)
                .help("Next match (⌘G)")
                .accessibilityLabel("Next match")
            Button("Done") { find.close() }
                .buttonStyle(RefinedActionStyle(kind: .quiet))
                .help("Close (Esc)")
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 40)
        .frame(maxWidth: 520)
        .background(Refined.card, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous).strokeBorder(Refined.separator))
        // Esc closes, from the field or anywhere in the bar.
        .onExitCommand { find.close() }
        .onKeyPress(.escape) { find.close(); return .handled }
        .onAppear { focused = true }
        .onChange(of: find.focusToken) { _, _ in focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(find.prompt)
        .uiTarget("transcript-find")
    }
}

private struct PageFindQueryKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// The open find bar's query, which the transcript's lines mark in butter; nil when the bar is closed.
    var pageFindQuery: String? {
        get { self[PageFindQueryKey.self] }
        set { self[PageFindQueryKey.self] = newValue }
    }
}
