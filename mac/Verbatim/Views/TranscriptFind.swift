import SwiftUI
import AppKit

// Find in the open transcript (MAC-22; DESIGN.md §6.9 and §11): ⌘F on a transcript opens a find bar over its Original
// lines, as the iPhone's Find does. Matches are in butter (`ReadingHighlight`), the current one is the selected line
// and scrolls into view, ⌘G and ⇧⌘G (or Return in the field, or the bar's arrows) step through them and wrap,
// and Esc or Done closes. Elsewhere ⌘F opens Search or ask, and ⌘K opens that panel on every screen
// (App/AppCommands.swift). The rules are `PageFind` (App/MacCommandRules.swift).

/// The find bar's state for the transcript on screen. One per app, as the window is.
@MainActor
final class TranscriptFind: ObservableObject {
    static let shared = TranscriptFind()

    @Published private(set) var open = false
    @Published var query = "" { didSet { if query != oldValue { recompute(keepCurrent: false) } } }
    @Published private(set) var matches: [PageFindMatch] = []
    @Published private(set) var current: Int?
    /// Changes each time ⌘F is pressed, so the field takes focus again even while the bar is open.
    @Published private(set) var focusToken = 0
    /// The lines searched, in reading order (set by the transcript as its lines change).
    private var lines: [(id: UUID, text: String)] = []

    /// Find Next and Find Previous have somewhere to go.
    var canStep: Bool { open && !matches.isEmpty }
    /// The line the current match is on.
    var currentLine: UUID? { current.flatMap { c in matches.indices.contains(c) ? lines[safe: matches[c].line]?.id : nil } }
    var countLabel: String { PageFind.countLabel(current: current, count: matches.count, query: query) }
    /// The query the lines mark, while the bar is open.
    var highlight: String? { open && !query.trimmingCharacters(in: .whitespaces).isEmpty ? query : nil }

    func show() {
        if !open { open = true }
        focusToken += 1
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
        let same = new.count == lines.count && zip(new, lines).allSatisfy { $0.id == $1.id && $0.text == $1.text }
        guard !same else { return }
        lines = new
        recompute(keepCurrent: true)
    }

    private func recompute(keepCurrent: Bool) {
        let found = PageFind.matches(in: lines.map(\.text), query: query)
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
            TextField("Find in transcript", text: $find.query)
                .textFieldStyle(.plain)
                .refinedFont(.body)
                .foregroundStyle(Refined.ink)
                .focused($focused)
                .onSubmit { find.next() }
                .accessibilityLabel("Find in transcript")
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
        .accessibilityLabel("Find in transcript")
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
