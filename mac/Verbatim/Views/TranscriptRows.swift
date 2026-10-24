import SwiftUI
import AppKit

/// Neutral card surface: opaque reader white, an ink hairline that firms on hover.
struct NoteCardBackground: View {
    var hover: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(hover ? Ink.cardHover : Ink.card)
            .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(hover ? Ink.outlineStrong.opacity(0.7) : Ink.hairline))
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

/// A Library row in the website style (mac/DESIGN.md §11): flat on the paper with a hairline; under the pointer or
/// selected it takes the card fill, the ink outline, and the hard shadow. Never tilts. The kind dot, a serif title
/// (italic after the project's name), a sentence-case meta line, the status as plain mono text ("Cleaned",
/// "Original"), and the length in mono. The ⋯ menu shows under the pointer and sits above the click layer.
struct HistoryRow: View {
    var transcript: Transcript
    /// nil = not selecting; true/false = selection mode with this row's state.
    var selected: Bool? = nil
    /// The project's name, when the row is shown outside it (the meta line names it; the title's italic follows it).
    var project: String? = nil
    /// The row's own project's name, for the title's italic (inside a project too). Passed in rather than looked up,
    /// so a row doesn't watch the whole app state: in a long Library every row re-rendered on every change.
    var projectName: String? = nil
    /// The IDs a drag of this row carries (the whole selection when this row is part of it).
    var dragIDs: (() -> [UUID])? = nil
    var open: () -> Void

    var body: some View {
        FlatRowButton(selected: selected == true, dragPayload: { TranscriptDrag.payload(dragIDs?() ?? [transcript.id]) }, action: open) { _ in
            HStack(spacing: 14) {
                if let sel = selected {
                    Image(systemName: sel ? "checkmark.circle.fill" : "circle").font(.system(size: 19)).foregroundStyle(sel ? Ink.ink : Ink.mute)
                }
                KindDot(transcript: transcript, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if transcript.pinned { IconGlyph(art: .iconPin, size: 12, color: Ink.mute).accessibilityLabel("Pinned") }
                        WebText.serif(title.0, italic: title.1, size: 21).foregroundStyle(Ink.ink).lineLimit(1)
                    }
                    Text(metaLine).font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 10)
                status
                Text(WebFormat.clock(transcript.duration)).font(Ink.mono(12)).foregroundStyle(Ink.dim).lineLimit(1).fixedSize()
                if selected == nil { Color.clear.frame(width: 26, height: 26) }   // room for the ⋯ menu
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        } accessory: { lit in
            // The menu is built only under the pointer: a Menu per row is a real control, and a long Library made
            // hundreds. Its spot always takes the pointer, so moving onto it keeps the row lit.
            if selected == nil {
                Color.clear.frame(width: 30, height: 26).contentShape(Rectangle())
                    .overlay { if lit { RowMenuButton(transcript: transcript) } }
                    .padding(.trailing, 8)
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .identity))
    }

    /// Inside a project the title still italicizes after the project's name.
    private var title: (String, String?) { WebText.split(transcript.title, after: project ?? projectName) }

    @ViewBuilder private var status: some View {
        switch transcript.status {
        case .processing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                StatusText(text: transcript.stageText, tone: .dim, mono: true)
            }
        case .failed:
            StatusText(text: "Needs retry", tone: .danger, mono: true)
        case .ready:
            if transcript.document != nil {
                StatusText(text: "Cleaned", tone: .accent, mono: true)
            } else {
                StatusText(text: "Original", tone: .dim, mono: true)
            }
        }
    }

    /// "Meeting · Tim, Jonathan · Lapp Wagons", "Voice note · Idea", "youtube.com · Kept video", "Journal · 3 moments".
    private var metaLine: String {
        let t = transcript
        var parts: [String] = []
        let link = LibrarySource.isLink(t)
        let source = link ? (t.sourceLabel.isEmpty ? HomeRecentStyle(t).source : t.sourceLabel) : HomeRecentStyle(t).source
        switch t.kind {
        case .meeting?, .journal?: parts.append(t.kind!.label)
        case let k?: parts.append(source); if k != .dictation { parts.append(k.label) }
        case nil: parts.append(source)
        }
        let named = t.speakers.map(\.name).filter { !$0.isEmpty && !$0.hasPrefix("Speaker ") }
        if named.count >= 2 {
            parts.append(named.count > 3 ? named.prefix(3).joined(separator: ", ") + " +\(named.count - 3)" : named.joined(separator: ", "))
        } else if t.speakers.count >= 2 {
            parts.append("\(t.speakers.count) speakers")
        }
        if let project { parts.append(project) }
        let moments = WebStatus.moments(t)
        if moments > 0 { parts.append(HomeCounts.countLabel(moments, "moment", "moments")) }
        if t.keptVideo != nil { parts.append("Kept video") }
        return parts.joined(separator: " · ")
    }
}

/// Keep video (links) and Keep audio, or Show in Finder once kept.
struct KeepMenuItems: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var kept = KeptMedia.shared
    var transcript: Transcript
    var body: some View {
        if let busy = app.keeping[transcript.id] {
            Button(busy) {}.disabled(true)
        } else if let v = transcript.keptVideo, kept.exists(v) {
            Button("Show video in Finder") { app.showKept(v) }
        } else if transcript.linkInfo != nil {
            Button("Keep video (MP4)") { app.keepVideo(transcript.id) }
        }
        if let a = transcript.keptAudio, kept.exists(a) {
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
        Button("Rename…") { RenameCenter.shared.begin(transcript) }
        Button(transcript.pinned ? "Unpin" : "Pin") { app.store.update(transcript.id) { $0.pinned.toggle() } }
        Menu("Add to project") {
            // One project at a time: choosing another moves it there (the current one has a checkmark).
            ForEach(app.store.projects) { p in
                if transcript.projectId == p.id {
                    Button { } label: { Label(p.name, systemImage: "checkmark") }.disabled(true)
                } else {
                    Button(p.name) { app.addToProject([transcript.id], p.id) }
                }
            }
            if let current = transcript.projectId, let name = app.store.projectsByID[current]?.name {
                Divider()
                Button("Remove from \(name)") { app.move([transcript.id], to: nil) }
            }
            if !app.store.projects.isEmpty { Divider() }
            Button("New project…") { app.newProjectFor = [transcript.id] }
        }
        if transcript.status == .ready { Button("Export…") { app.exportRequest = ExportRequest(ids: [transcript.id]) } }
        if transcript.status == .failed { Button("Retry transcription") { app.retry(transcript) } }
        if transcript.status == .processing { Button("Cancel transcription") { app.cancel(transcript.id) } }
        Divider()
        KeepMenuItems(transcript: transcript)
        Divider()
        Button("Delete", role: .destructive) { app.delete([transcript.id]) }
    }
}
