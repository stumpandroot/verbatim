import SwiftUI
import AppKit

// brand: native file
//
// A recording as a row in Native's lists (the Library's List view and Home's Recent recordings), the way Mail lists
// its inbox and Voice Memos its recordings (mockup "Verbose Native Redesign", sections 1 and 2): the title with the
// time on the right, the kind, length, and people on the second line, and up to two lines of what was said. No box,
// no buttons, no color: rows sit in a grouped section with inset separators. In the Library a click selects (the
// system's gray selection), and a double-click, Return, or the inspector's Open Transcript opens; on Home a click
// opens. Right-click has the row's menu (Play, Copy text, Add to project, Delete), and a row drags onto a project.

struct NativeRecordingRow: View {
    enum Style { case library, home }

    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var style: Style = .library
    var selected = false
    /// A click on the row. Nil opens the transcript (Home).
    var onSelect: (() -> Void)? = nil
    var divider = true
    /// Library rows under day headers show the time; listed flat (by length or title), the date too.
    var showsDay = false
    @State private var hover = false

    var body: some View {
        let t = transcript
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if t.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                Text(t.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(style == .library ? (showsDay ? NativeDateCell.text(t.createdAt) : Formats.style(date: .none, time: .short).string(from: t.createdAt))
                     : HomeRecentStyle.length(t.duration))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .opacity(style == .home && WebStatus.isTextOnly(t) ? 0 : 1)
            }
            if style == .library { meta.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            preview.font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if style == .home { meta.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? NativeInk.selection : (hover ? Color.primary.opacity(0.035) : Color.clear))
        .overlay(alignment: .bottom) {
            if divider && !selected { NativeRowSeparator(leading: 14) }
        }
        .allowsHitTesting(false)
        .overlay { hitLayer }
        .contextMenu { RowMenu(transcript: t) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(onSelect == nil ? "Opens the transcript." : "Selects it. Double-click to open.")
        .accessibilityAction { open() }
        .accessibilityAction(named: "Play") { play() }
    }

    /// Library: "Meeting · 38:12 · Anika, Marcus". Home: "Meeting · Today, 9:00 AM". A transcription in progress or one
    /// that needs a retry says so here.
    private var meta: some View {
        LiveStage(transcript) { t in
            let state: Text? = {
                switch t.status {
                case .processing: return Text(t.stageText)
                case .failed: return Text("Needs retry").foregroundStyle(NativeInk.danger)
                case .ready: return nil
                }
            }()
            let base = style == .library
                ? NativeRowMeta.library(kind: NativeLibraryView.kind(t), length: WebStatus.isTextOnly(t) ? nil : NativeLibraryView.length(t.duration),
                                        people: NativeLibraryView.people(t, projects: app.store.projectsByID))
                : NativeRowMeta.home(kind: NativeLibraryView.kind(t), when: NativeDateCell.text(t.createdAt))
            if let state { Text("\(base) · \(state)") } else { Text(base) }
        }
    }

    /// What was said, filler left out; nothing yet while it transcribes.
    @ViewBuilder private var preview: some View {
        let text = PremiumPreview.text(transcript)
        if !text.isEmpty { Text(text) }
    }

    private var hitLayer: some View {
        Rectangle().fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { tapped() }
            .onDrag { NSItemProvider(object: TranscriptDrag.payload([transcript.id]) as NSString) }
    }

    private func tapped() {
        guard let onSelect else { open(); return }
        if NativeNav.shared.isDoubleClick(on: transcript.id) { open() } else { onSelect() }
    }

    private func open() { app.go(.transcript(transcript.id)) }

    private func play() {
        guard transcript.audioFileName != nil, transcript.status == .ready else { open(); return }
        NativeNav.shared.play(transcript, app: app)
    }
}

/// The first lines of what was said, filler left out, remembered per transcript until its words change (lists ask on
/// every render).
@MainActor
enum PremiumPreview {
    private struct Key: Hashable { var id: UUID; var segments: Int; var chars: Int; var cleaned: Bool }
    private static var cache: [Key: String] = [:]

    static func text(_ t: Transcript) -> String {
        guard t.status == .ready else { return "" }
        let key = Key(id: t.id, segments: t.segments.count, chars: t.segments.reduce(0) { $0 + $1.text.utf8.count }, cleaned: t.document != nil)
        if let hit = cache[key] { return hit }
        let text = JournalDays.preview(t)
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = text
        return text
    }
}

/// Day headers for the Library's list: "Today", "Yesterday", then the date, as a grouped section's header.
struct PremiumDayHeader: View {
    var title: String
    var body: some View {
        Text(title).font(.system(size: 13, weight: .semibold))
            .padding(.top, 16).padding(.bottom, 6).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
