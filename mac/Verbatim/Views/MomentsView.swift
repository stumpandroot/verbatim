import SwiftUI
import AppKit

// brand: web style
//
// Moments in the website style (mac/DESIGN.md §11): a compact title with a mono count, soft filter chips, and a
// three-column board of big cards at their natural height. Bookmarks sit on butter panels with grain and the quote in
// italic serif; notes are card white with an ink outline; a still, when there is one, tops the card. Cards tilt.

/// Every note and bookmark pinned to a moment, across all transcripts: a reference notebook.
/// Stills appear when the video is on this Mac (kept from a link, or the original import).
struct MomentsView: View {
    @EnvironmentObject var app: AppState
    @State private var kind = "All"

    struct Moment: Identifiable {
        let note: Note
        let transcript: Transcript
        var id: UUID { note.id }
    }

    private static let kinds = ["All", "Bookmarks", "Notes", "With stills"]

    private var all: [Moment] {
        app.filtered.flatMap { t in t.notes.filter { $0.at != nil }.map { Moment(note: $0, transcript: t) } }
            .sorted { $0.note.createdAt > $1.note.createdAt }
    }
    private func shown(_ all: [Moment]) -> [Moment] {
        let q = app.search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { m in
            switch kind {
            case "Bookmarks": if !m.note.isBookmark { return false }
            case "Notes": if m.note.isBookmark { return false }
            case "With stills": if m.note.frameFile == nil { return false }
            default: break
            }
            return q.isEmpty || m.note.text.lowercased().contains(q) || m.transcript.title.lowercased().contains(q)
        }
    }

    var body: some View {
        let all = self.all
        let shown = shown(all)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Moments", count: "\(shown.count.formatted()) saved",
                          lede: "Notes and bookmarks with a time, from every transcript. Click one to land on that passage. Press B while a transcript plays to save one.")
                    .staggerIn(0)
                if !all.isEmpty {
                    FlowRow(spacing: 8, lineSpacing: 8) {
                        ForEach(Self.kinds, id: \.self) { k in
                            FilterChip(title: k, count: k == "All" ? all.count : nil, selected: kind == k) { kind = k }
                        }
                    }
                    .padding(.top, 18).staggerIn(1)
                }
                if all.isEmpty {
                    EmptyStateCard(art: .iconMoments, title: "No moments yet",
                                   message: "While a transcript plays, press B to bookmark the moment, or click a line and add a note.",
                                   button: "Open the Library", action: { app.go(.library) })
                        .padding(.top, 22).staggerIn(1)
                } else if shown.isEmpty {
                    Group {
                        if kind != "All" {
                            EmptyStateCard(art: .iconMoments, title: "Nothing here",
                                           message: app.search.isEmpty ? "No moments match \(kind.lowercased())." : "No \(kind.lowercased()) match “\(app.search)”.",
                                           button: "Show all", action: { kind = "All" })
                        } else {
                            EmptyStateCard(art: .search, title: "Nothing found", message: "No moments match “\(app.search)”.")
                        }
                    }
                    .padding(.top, 22)
                } else {
                    MomentsBoard(spacing: 16) {
                        ForEach(shown) { m in MomentCard(note: m.note, transcript: m.transcript) }
                    }
                    .padding(.top, 18)
                    .staggerIn(2)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A masonry board: up to three columns, each card at its natural height, placed in the shortest column (the
/// mockup's CSS columns). Two columns under 760 pt, one under 460.
private struct MomentsBoard: Layout {
    var spacing: CGFloat = 16

    private func columns(_ width: CGFloat) -> Int { width >= 760 ? 3 : width >= 460 ? 2 : 1 }

    private func place(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let n = columns(width)
        let colW = max(1, (width - spacing * CGFloat(n - 1)) / CGFloat(n))
        var heights = [CGFloat](repeating: 0, count: n)
        var frames: [CGRect] = []
        for v in subviews {
            let c = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let h = v.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
            let y = heights[c] == 0 ? 0 : heights[c] + spacing
            frames.append(CGRect(x: CGFloat(c) * (colW + spacing), y: y, width: colW, height: h))
            heights[c] = y + h
        }
        return (frames, heights.max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 900
        return CGSize(width: w, height: place(w, subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = place(bounds.width, subviews)
        for (v, f) in zip(subviews, laid.frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

/// One moment as a big card: the still on top when there is one, then the icon, the timecode, and a play button
/// (links that open at a time), the words, and the transcript's title. Bookmarks without a still sit on a butter panel
/// with the quote in italic serif; notes are card white with an ink outline. Tilts and lifts under the pointer.
struct MomentCard: View {
    @EnvironmentObject var app: AppState
    var note: Note
    var transcript: Transcript
    @State private var down = false
    @State private var playHover = false

    private var at: Double { note.at ?? 0 }
    private static let stillHeight: CGFloat = 130
    private static let pad: CGFloat = 16

    private var stillFile: String? { note.frameFile ?? transcript.linkInfo?.thumbnailFile }
    /// Bookmarks on the butter panel; a bookmark with a still sits on card white so the picture leads.
    private var onButter: Bool { note.isBookmark && stillFile == nil }
    private var playURL: URL? {
        guard let info = transcript.linkInfo, info.supportsTimestamps else { return nil }
        return info.url(at: at)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        let ink = onButter ? Ink.inkFixed : Ink.ink
        HomeCard(tilt: 2, radius: Radius.record, shadow: false, onPress: { down = $0 }, action: open) { hovering in
            VStack(alignment: .leading, spacing: 0) {
                if let f = stillFile { still(f) }
                VStack(alignment: .leading, spacing: 10) {
                    header(ink: ink)
                    words(ink: ink)
                    titleLine.foregroundStyle(ink.opacity(0.7))
                }
                .padding(.horizontal, Self.pad).padding(.bottom, Self.pad)
                .padding(.top, stillFile == nil ? Self.pad : 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { if !onButter { shape.fill(Ink.card) } }
            .modifier(ButterPanel(on: onButter))
            .clipShape(shape)
            .inkEdge(outline: hovering || playHover || !onButter, shadow: InkEdge.card(hover: hovering || playHover, pressed: down), radius: Radius.record)
        }
        // The play button sits above the card's click layer, where the drawn one is (the drawing tilts; this stays flat).
        .overlay(alignment: .topTrailing) {
            if let u = playURL {
                Color.white.opacity(0.001)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .onHover { playHover = $0 }
                    .tapArea { NSWorkspace.shared.open(u) }
                    .help("Open the video at \(at.timecode)")
                    .accessibilityLabel("Open the video at \(at.timecode)")
                    .accessibilityAddTraits(.isButton)
                    .padding(.top, (stillFile == nil ? Self.pad : Self.stillHeight + 14) - 2)
                    .padding(.trailing, Self.pad - 2)
            }
        }
        .accessibilityLabel("\(note.isBookmark ? "Bookmark" : "Note") at \(at.timecode), \(transcript.title)")
        .accessibilityValue(displayText)
        .accessibilityHint("Opens the transcript at this moment.")
        .contextMenu {
            Button("Open transcript at \(at.timecode)") { open() }
            if let u = playURL {
                Button("Open video at \(at.timecode)") { NSWorkspace.shared.open(u) }
                Button("Copy link to this moment") { copy(u.absoluteString) }
            }
            if let v = transcript.videoFile { Button("Show video in Finder") { app.showKept(v.path) } }
            Divider()
            Button("Delete", role: .destructive) { app.deleteNote(transcript: transcript.id, note: note.id) }
        }
    }

    /// The still across the top of the card, flush to its edges; a petal panel with a play glyph if the file is gone.
    private func still(_ file: String) -> some View {
        ZStack {
            if let img = NSImage(contentsOf: Paths.thumbs.appendingPathComponent(file)) {
                Rectangle().fill(Ink.track).overlay { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }.clipped()
            } else {
                Color.clear.colorPanel(Ink.panelPetal, radius: 0)
                    .overlay { SolidPlayGlyph().fill(Ink.inkFixed).frame(width: 11, height: 13).offset(x: 1) }
            }
        }
        .frame(height: Self.stillHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottomTrailing) { StillBadge(text: at.timecode).padding(.trailing, 6).padding(.bottom, 5) }
        .accessibilityHidden(true)
    }

    private func header(ink: Color) -> some View {
        HStack(spacing: 8) {
            ArtIcon(art: note.isBookmark ? .iconPin : .iconNotes, size: 16, lineWidth: 1.3)
            Text(at.timecode).font(Ink.mono(12)).monospacedDigit()
            Spacer(minLength: 0)
            if playURL != nil {
                ZStack {
                    Circle().fill(ink.opacity(playHover ? 0.08 : 0))
                    Circle().strokeBorder(ink, lineWidth: 1.3)
                    ArtIcon(art: .iconPlay, size: 13, lineWidth: 1.3)
                }
                .frame(width: 28, height: 28)
                .animation(Motion.touch, value: playHover)
            } else {
                Color.clear.frame(width: 28, height: 28)
            }
        }
        .frame(height: 28)
        .foregroundStyle(ink)
    }

    @ViewBuilder private func words(ink: Color) -> some View {
        if note.isBookmark {
            Text(displayText).font(Ink.serif(stillFile == nil ? 19 : 17).italic()).foregroundStyle(ink)
                .lineSpacing(2).lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(displayText).font(.system(size: 14.5)).foregroundStyle(ink)
                .lineSpacing(4).lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The transcript's title in the serif, italic after its project's name where it has one.
    private var titleLine: some View {
        let project = transcript.projectId.flatMap { id in app.store.projects.first { $0.id == id }?.name }
        let t = WebText.split(transcript.title, after: project)
        return WebText.serif(t.0, italic: t.1, size: 15).lineLimit(1)
    }

    private var displayText: String { note.text.isEmpty ? quote : note.text }

    /// The passage the moment points at, for bookmarks with no text.
    private var quote: String {
        let seg = transcript.segments.first { $0.id == note.segmentId } ?? transcript.segments.last { $0.start <= at }
        return seg.map { "“\($0.text.trimmingCharacters(in: .whitespaces))”" } ?? "Bookmark"
    }

    private func open() {
        let seg = note.segmentId ?? transcript.segments.last { $0.start <= at }?.id
        app.focusSegment = seg
        app.go(.transcript(transcript.id))
    }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); app.toast = Toast("Copied") }
}

/// The butter color panel with grain, behind a bookmark card.
private struct ButterPanel: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.colorPanel(Ink.panelButter, radius: Radius.record) } else { content }
    }
}
