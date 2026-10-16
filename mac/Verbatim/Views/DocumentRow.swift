import SwiftUI
import AppKit

// MARK: - Document row

/// One transcript as an index entry: source glyph, title, mono metadata, state, date. Hover tint, keyboard
/// focusable, drag to a project, context menu. No tilt.
struct DocumentRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            sourceGlyph
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if transcript.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.mute).accessibilityLabel("Pinned") }
                    Text(transcript.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(sourceName)
                    Text("·")
                    Text(transcript.duration.timecode).font(Ink.mono(12))
                    if transcript.speakers.count >= 2 { Text("·"); Text("\(transcript.speakers.count) speakers") }
                    if transcript.notes.contains(where: \.isBookmark) { Text("·"); BrandGlyph(art: .bookmark, color: Ink.mute).frame(width: 11, height: 11).accessibilityLabel("Has saved moments") }
                }
                .font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 10)
            state
            Text(dateLine).font(Ink.mono(12)).foregroundStyle(Ink.mute).frame(width: 84, alignment: .trailing).lineLimit(1)
            RowMenuButton(transcript: transcript)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 9)
        .background(hover ? Ink.cardHover : Ink.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? Ink.outlineStrong.opacity(0.7) : Ink.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.16), value: hover)
        .onTapGesture(perform: open)
        .onDrag { NSItemProvider(object: TranscriptDrag.payload([transcript.id]) as NSString) }
        .contextMenu { RowMenu(transcript: transcript) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private var sourceName: String {
        switch transcript.source { case .dictation: return "Dictation"; case .voiceMemo: return "Voice note"; default: return transcript.sourceLabel }
    }

    private var sourceGlyph: some View {
        let (art, tint): (BrandArt?, Color) = {
            switch transcript.source {
            case .voiceMemo, .dictation: return (.capture, Ink.persimmonTint)
            case .link: return (nil, Ink.sageTint)
            case .app: return (nil, Ink.petalTint)
            default: return (.document, Ink.butterTint)
            }
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint)
            if let art { BrandGlyph(art: art, color: Ink.ink, minLineWidth: 1.2).padding(7) }
            else { Image(systemName: transcript.source.symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(Ink.ink) }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var state: some View {
        if transcript.status == .processing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(transcript.stageText).font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            .accessibilityLabel("Processing: \(transcript.stageText)")
        } else if transcript.status == .failed {
            Label("Needs retry", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Ink.danger)
        }
    }

    private var dateLine: String {
        let f = DateFormatter(); let cal = Calendar.current
        if cal.isDateInToday(transcript.createdAt) { return "Today" }
        if cal.isDateInYesterday(transcript.createdAt) { return "Yesterday" }
        f.dateFormat = cal.isDate(transcript.createdAt, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: transcript.createdAt)
    }
}
