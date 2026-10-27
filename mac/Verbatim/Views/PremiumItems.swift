import SwiftUI
import AppKit

// brand: native file
//
// A recording in Premium Native's lists (Home's Recent recordings and the Library), in the Voicenotes item style: the
// date line, a bold title on up to two lines, two lines of what was said (or the kind and state when there's no text
// yet), and a footer with the play pill and its length, the status, and ⋯. No box: items sit on the window with a
// hairline between them. Click selects (the Library), double-click or Return opens, the play pill opens the
// transcript and plays, and the row drags onto a project. The footer's buttons sit above the row's hit layer, never
// inside it (macOS 26 click safety).

struct PremiumRecordingItem: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var selected = false
    /// A click on the row. Nil opens the transcript (Home).
    var onSelect: (() -> Void)? = nil
    var divider = true
    @State private var hover = false

    var body: some View {
        let t = transcript
        VStack(alignment: .leading, spacing: 0) {
            Text(PremiumDateLine.line(t.createdAt)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 5) {
                if t.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                Text(t.title).font(.system(size: 15.5, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 3)
            secondLine.font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            // Room for the footer, which floats above the hit layer.
            Color.clear.frame(height: 30).padding(.top, 9)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, selected ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? PremiumInk.accentSoft : (hover ? PremiumInk.fill.opacity(0.6) : Color.clear))
                .padding(.horizontal, selected || hover ? 0 : -10)
        }
        .overlay(alignment: .bottom) {
            if divider && !selected { Rectangle().fill(PremiumInk.separator).frame(height: 0.5) }
        }
        .allowsHitTesting(false)
        .overlay { hitLayer }
        .overlay(alignment: .bottomLeading) { footer.padding(.horizontal, selected ? 14 : 0).padding(.bottom, 12) }
        .contextMenu { RowMenu(transcript: t) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(onSelect == nil ? "Opens the transcript." : "Selects it. Double-click to open.")
        .accessibilityAction { open() }
    }

    /// What was said, or the kind and state when there's no text yet.
    /// With the live progress (StageClock): only this line re-renders on a tick.
    private var secondLine: some View {
        LiveStage(transcript) { transcript in
            let preview = PremiumPreview.text(transcript)
            if !preview.isEmpty {
                Text(preview)
            } else {
                // No day: the date line above already says it ("Today · 2:17 AM").
                let parts = HomeRecentStyle.metaParts(transcript, style: HomeRecentStyle(transcript), compact: false, day: false)
                parts.enumerated().reduce(Text(verbatim: "")) { out, p in
                    let piece = p.element.failed ? Text(p.element.text).foregroundStyle(NativeInk.danger) : Text(p.element.text)
                    return Text("\(out)\(p.offset > 0 ? " · " : "")\(piece)")
                }
            }
        }
    }

    private var hitLayer: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape.fill(Color.white.opacity(0.001))
            .contentShape(shape)
            .onHover { hover = $0 }
            .onTapGesture { tapped() }
            .onDrag { NSItemProvider(object: TranscriptDrag.payload([transcript.id]) as NSString) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if transcript.audioFileName != nil && transcript.status == .ready {
                Button { NativeNav.shared.play(transcript, app: app) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill").font(.system(size: 10.5, weight: .bold))
                        Text(HomeRecentStyle.length(transcript.duration)).font(.system(size: 13.5, weight: .semibold)).monospacedDigit()
                    }
                    .padding(.leading, 11).padding(.trailing, 13).frame(height: 30)
                    .background {
                        Capsule().fill(PremiumInk.card)
                            .shadow(color: PremiumInk.shadow.opacity(0.6), radius: 4, y: 2)
                            .overlay(Capsule().strokeBorder(PremiumInk.separator, lineWidth: 0.5))
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open and play")
                .accessibilityLabel("Play, \(HomeRecentStyle.length(transcript.duration))")
            }
            status
            Spacer(minLength: 8)
            Menu { RowMenu(transcript: transcript) } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More for \(transcript.title)")
        }
    }

    @ViewBuilder private var status: some View {
        switch transcript.status {
        case .processing:
            LiveStage(transcript) { transcript in
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text(transcript.stageText).lineLimit(1) }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .failed:
            Label("Needs retry", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(NativeInk.danger).lineLimit(1)
        case .ready:
            if transcript.document != nil {
                Text("Cleaned").font(.system(size: 12)).foregroundStyle(PremiumInk.accentText)
            } else if WebStatus.isTextOnly(transcript) {
                Text("Text").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("Original").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func tapped() {
        guard let onSelect else { open(); return }
        if NativeNav.shared.isDoubleClick(on: transcript.id) { open() } else { onSelect() }
    }

    private func open() { app.go(.transcript(transcript.id)) }
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

/// Day headers for the Library's list: "Today", "Yesterday", then the date.
struct PremiumDayHeader: View {
    var title: String
    var body: some View {
        Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, 14).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
