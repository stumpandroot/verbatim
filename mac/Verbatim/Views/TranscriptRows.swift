import SwiftUI
import AppKit

/// Neutral card surface: opaque reader white, an ink hairline that firms on hover.
struct NoteCardBackground: View {
    var hover: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Ink.cardHover : Ink.card)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hover ? Ink.outlineStrong.opacity(0.7) : Ink.hairline))
    }
}

struct RowMenuButton: View {
    var transcript: Transcript
    var body: some View {
        Menu { RowMenu(transcript: transcript) } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.dim).frame(width: 30, height: 26)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverChip()
        .help("More actions").accessibilityLabel("More actions for \(transcript.title)")
    }
}

func meta(_ t: Transcript, short: Bool = false) -> String {
    let cal = Calendar.current
    let day: String
    if cal.isDateInToday(t.createdAt) { day = "Today" }
    else if cal.isDateInYesterday(t.createdAt) { day = "Yesterday" }
    else if let d = cal.dateComponents([.day], from: t.createdAt, to: Date()).day, d < 7 { day = Formats.pattern("EEEE").string(from: t.createdAt) }
    else { day = Formats.pattern("MMM d").string(from: t.createdAt) }
    var parts = [day]
    if !short { parts.append(t.source == .dictation ? "Dictation" : t.source == .voiceMemo ? "Voice note" : t.sourceLabel) }
    parts.append(t.duration.timecode)
    if !short, t.speakers.count >= 2 { parts.append("\(t.speakers.count) speakers") }
    return parts.joined(separator: " · ")
}

/// Static waveform thumbnail from the stored envelope. A Shape, so it costs nothing after layout.
struct WaveformThumb: Shape {
    var values: [Float]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard !values.isEmpty else { return p }
        let n = values.count
        let step = r.width / CGFloat(n)
        let bw = max(1.5, step * 0.55)
        for (i, v) in values.enumerated() {
            let h = max(2, CGFloat(v) * r.height)
            let x = r.minX + CGFloat(i) * step + (step - bw) / 2
            p.addRoundedRect(in: CGRect(x: x, y: r.midY - h / 2, width: bw, height: h), cornerSize: CGSize(width: bw / 2, height: bw / 2))
        }
        return p
    }
}

struct HistoryRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    /// nil = not selecting; true/false = selection mode with this row's state.
    var selected: Bool? = nil
    /// The IDs a drag of this row carries (the whole selection when this row is part of it).
    var dragIDs: (() -> [UUID])? = nil
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        CardButton(tilt: 2, lift: 2, radius: 14, dragPayload: { TranscriptDrag.payload(dragIDs?() ?? [transcript.id]) }, action: open) {
            HStack(spacing: 14) {
                if let sel = selected {
                    Image(systemName: sel ? "checkmark.circle.fill" : "circle").font(.system(size: 19)).foregroundStyle(sel ? Ink.iris : Ink.mute)
                }
                if let k = transcript.kind, k != .dictation {
                    KindTile(kind: k, size: 48)
                } else {
                    Image(systemName: transcript.source.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(tileFg)
                        .frame(width: 48, height: 48).background(tileBg, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if transcript.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.mute) }
                        Text(transcript.title).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1).layoutPriority(1)
                    }
                    HStack(spacing: 6) {
                        Text(transcript.sourceLabel)
                        Text("·"); Text(transcript.duration.timecode)
                        if !transcript.speakers.isEmpty { Text("·"); Text("\(transcript.speakers.count) speakers") }
                        if let k = transcript.kind, k != .dictation { Text("·"); Text(k.label) }
                        if transcript.status == .processing { Text("·"); Text(transcript.stageText).foregroundStyle(Ink.iris); ProgressView().controlSize(.mini) }
                        if transcript.status == .failed { Text("·"); Text("Needs retry").foregroundStyle(Ink.coral) }
                    }
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 10)
                WaveformThumb(values: transcript.waveform.isEmpty ? placeholder : Waveform.resample(transcript.waveform, to: 32))
                    .fill(waveColor).frame(width: 120, height: 24)
                Text(dateLine).font(.system(size: 13)).foregroundStyle(Ink.mute).frame(width: 96, alignment: .trailing).lineLimit(1)
                Color.clear.frame(width: 30, height: 28)   // room for the ⋯ menu, which sits above the click layer
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(selected == true ? Ink.irisTint.opacity(0.6) : hover ? Ink.cardHover : Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected == true ? Ink.iris.opacity(0.5) : Ink.ink.opacity(hover ? 0.14 : 0.07)))
        }
        .overlay(alignment: .trailing) {
            if selected == nil { RowMenuButton(transcript: transcript).padding(.trailing, 12) }
        }
        .onHover { hover = $0 }
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .identity))
    }

    private var placeholder: [Float] { (0..<48).map { _ in Float.random(in: 0.08...0.25) } }
    private var tileBg: Color { switch transcript.source { case .voiceMemo, .dictation: return Ink.coralTint; case .app: return Ink.limeTint; default: return Ink.irisTint } }
    private var tileFg: Color { switch transcript.source { case .voiceMemo, .dictation: return Ink.coral; case .app: return Ink.limeText; default: return Ink.iris } }
    private var waveColor: Color { transcript.source == .voiceMemo || transcript.source == .dictation ? Ink.coral.opacity(0.85) : Ink.iris.opacity(0.75) }
    private var dateLine: String {
        let cal = Calendar.current
        if cal.isDateInToday(transcript.createdAt) { return "Today" }
        else if cal.isDateInYesterday(transcript.createdAt) { return "Yesterday" }
        let pattern = cal.isDate(transcript.createdAt, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return Formats.pattern(pattern).string(from: transcript.createdAt)
    }
}

/// Keep video (links) and Keep audio, or Show in Finder once kept.
struct KeepMenuItems: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var body: some View {
        if let busy = app.keeping[transcript.id] {
            Button(busy) {}.disabled(true)
        } else if let v = transcript.keptVideo, FileManager.default.fileExists(atPath: v) {
            Button("Show video in Finder") { app.showKept(v) }
        } else if transcript.linkInfo != nil {
            Button("Keep video (MP4)") { app.keepVideo(transcript.id) }
        }
        if let a = transcript.keptAudio, FileManager.default.fileExists(atPath: a) {
            Button("Show audio in Finder") { app.showKept(a) }
        } else if transcript.audioFileName != nil {
            Button("Keep audio (\((transcript.audioFileName.map { URL(fileURLWithPath: $0).pathExtension.uppercased() }) ?? "M4A"))") { app.keepAudio(transcript.id) }
        }
    }
}

struct RowMenu: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var body: some View {
        Button("Open") { app.go(.transcript(transcript.id)) }
        Button(transcript.pinned ? "Unpin" : "Pin") { app.store.update(transcript.id) { $0.pinned.toggle() } }
        if !app.store.projects.isEmpty {
            Menu("Move to project") {
                Button("No project") { app.store.update(transcript.id) { $0.projectId = nil } }
                ForEach(app.store.projects) { p in Button(p.name) { app.store.update(transcript.id) { $0.projectId = p.id } } }
            }
        }
        if transcript.status == .failed { Button("Retry transcription") { app.retry(transcript) } }
        if transcript.status == .processing { Button("Cancel transcription") { app.cancel(transcript.id) } }
        Divider()
        KeepMenuItems(transcript: transcript)
        Divider()
        Button("Delete", role: .destructive) { app.delete([transcript.id]) }
    }
}
