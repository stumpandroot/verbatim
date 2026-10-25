import SwiftUI
import AppKit
import os

// brand: web style
//
// Links in the website style (mac/DESIGN.md §11): a compact title with a mono count, site chips, and flat rows with
// a 128×72 thumbnail, a serif title, a mono meta line, plain status text, and pill actions.

/// Every link you've transcribed: the original page one click away, with its thumbnail, channel, and date.
struct LinksView: View {
    @EnvironmentObject var app: AppState
    @State private var site: String? = nil

    var body: some View {
        // Worked out once per render: each list used to filter the whole library again.
        let all = app.filtered.compactMap { t in t.linkInfo.map { LinkItem(t: t, info: $0) } }
        let sites = Array(Set(all.compactMap { $0.info.site })).sorted()
        let shown = site == nil ? all : all.filter { $0.info.site == site }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Links", count: "\(shown.count.formatted()) transcribed",
                          lede: "The page each transcript came from. Right-click any line in a transcript to open the video at that moment.") {
                    PillButton(title: "Paste a link", kind: .line, trailing: .plus, hint: "Opens the link field on Home.") { pasteLink() }
                }
                .staggerIn(0)
                if sites.count > 1 {
                    FlowRow(spacing: 8, lineSpacing: 8) {
                        FilterChip(title: "All", count: all.count, selected: site == nil) { site = nil }
                        ForEach(sites, id: \.self) { s in FilterChip(title: s, selected: site == s) { site = s } }
                    }
                    .padding(.top, 18).staggerIn(1)
                }
                if shown.isEmpty {
                    Group {
                        if !app.search.isEmpty {
                            EmptyStateCard(art: .search, title: "Nothing found", message: "No links match “\(app.search)”.")
                        } else {
                            EmptyStateCard(art: .iconLinks, title: "No links yet",
                                           message: "Paste a YouTube, Vimeo, or podcast link on Home. Verbose keeps the page and transcribes the audio.",
                                           button: "Paste a link", action: pasteLink)
                        }
                    }
                    .padding(.top, 22).staggerIn(1)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, row in
                            LinkRow(transcript: row.t, info: row.info).staggerIn(2 + min(i, 8))
                        }
                    }
                    .padding(.top, 16)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .animation(Motion.settle, value: shown.map(\.id))
        .onAppear { KeptMedia.shared.refresh() }
    }

    private func pasteLink() { app.goHome(); app.focusLink.toggle() }
}

/// A transcript in Links with its link details.
private struct LinkItem: Identifiable {
    let t: Transcript
    let info: LinkInfo
    var id: UUID { t.id }
}

/// A flat Links row: thumbnail, serif title, channel · site · date · length in mono, the status as plain text, then
/// Open video, Transcript, and the ⋯ menu. Clicking the row opens the transcript; dragging it files it in a project.
struct LinkRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var kept = KeptMedia.shared
    var transcript: Transcript
    /// `transcript.linkInfo`, worked out once by the list.
    var info: LinkInfo
    /// Open video, Transcript, and the ⋯ button, with their gaps.
    private static let actionsWidth: CGFloat = 222
    /// Under the pointer: only then is the right-click menu built, so each row carries one menu (the ⋯ menu),
    /// not two. The ⋯ menu stays a real menu on every row: AppKit draws its label, and a stand-in would look
    /// different.
    @State private var hovering = false

    var body: some View {
        FlatRowButton(dragPayload: { TranscriptDrag.payload([transcript.id]) }, action: { app.go(.transcript(transcript.id)) }) { _ in
            HStack(alignment: .center, spacing: 18) {
                LinkThumb(info: info, duration: transcript.duration, seed: transcript.id)
                VStack(alignment: .leading, spacing: 0) {
                    WebText.serif(title.0, italic: title.1, size: 21).foregroundStyle(Ink.ink)
                        .lineLimit(2).lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(metaLine(info)).font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1).padding(.top, 5)
                    status.padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the controls above the click layer. (A hidden copy of them built a second menu per row.)
                Color.clear.frame(width: Self.actionsWidth, height: 28)
            }
            .padding(12)
        } accessory: { _ in
            actions(info).padding(.trailing, 12)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            // VoiceOver opens it without the pointer.
            if hovering || NSWorkspace.shared.isVoiceOverEnabled {
                Button("Open video") { open(info) }
                Button("Copy link") { copy(info.url) }
                Divider()
                RowMenu(transcript: transcript)
            }
        }
    }

    private var title: (String, String?) {
        WebText.split(transcript.title, after: transcript.projectId.flatMap { app.store.projectsByID[$0]?.name })
    }

    /// "Lapp Wagons · YouTube · Oct 12, 2026 · 06:52".
    private func metaLine(_ info: LinkInfo) -> String {
        [info.channel, info.site, info.uploadDisplay, transcript.duration > 0 ? WebFormat.clock(transcript.duration) : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Plain status text: a thin Record-colored bar while transcribing, failures in danger, and "✓ Video kept".
    @ViewBuilder private var status: some View {
        if transcript.status == .processing {
            // The live progress (StageClock): only this line re-renders on a tick.
            LiveStage(transcript) { transcript in
                HStack(spacing: 10) {
                    if let f = StageFraction.fraction(transcript.stage) {
                        StageProgressBar(value: f).frame(width: 180)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(transcript.stageText).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim)
                        .monospacedDigit().lineLimit(1)
                }
            }
        } else if transcript.status == .failed {
            StatusText(text: "Transcription failed", tone: .danger)
        } else if let busy = app.keeping[transcript.id] {
            StatusText(text: busy, tone: .dim).monospacedDigit()
        } else if kept.exists(transcript.keptVideo) {
            // The row's click layer covers this line; Show video in Finder is in the ⋯ menu and the context menu.
            StatusText(text: "Video kept", tone: .kept, check: true)
        }
    }

    private func actions(_ info: LinkInfo) -> some View {
        HStack(spacing: 8) {
            PillButton(title: "Open video", kind: .line, size: .mini, hint: "Opens the page in your browser.") { open(info) }
            PillButton(title: "Transcript", kind: .dark, size: .mini, enabled: transcript.status == .ready) {
                app.go(.transcript(transcript.id))
            }
            Menu {
                Button("Copy link") { copy(info.url) }
                Button("Copy title and link") { copy("\(transcript.title)\n\(info.url)") }
                Divider()
                RowMenu(transcript: transcript)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.dim).frame(width: 30, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverChip()
            .help("More actions").accessibilityLabel("More actions for \(transcript.title)")
        }
    }

    private func open(_ info: LinkInfo) { if let u = URL(string: info.url) { NSWorkspace.shared.open(u) } }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); app.toast = Toast("Copied") }
}

/// The Links thumbnail (128×72, tile corners): the page's image, or a color panel with grain and a play glyph when
/// there isn't one, with the length in a mono badge in the corner.
private struct LinkThumb: View {
    var info: LinkInfo
    var duration: Double
    var seed: UUID

    /// Decorative fills for links without an image, as project cards cycle them (Record stays the progress color).
    private static let fills: [Color] = [Ink.panelSage, Ink.panelPetal, Ink.panelButter]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
        ZStack {
            if let f = info.thumbnailFile {
                ThumbImage(file: f, maxPixel: 320) { panel }.clipShape(shape)
            } else {
                panel
            }
        }
        .frame(width: 128, height: 72)
        .overlay(alignment: .bottomTrailing) {
            if duration > 0 { StillBadge(text: WebFormat.clock(duration)).padding(.trailing, 6).padding(.bottom, 5) }
        }
        .accessibilityHidden(true)
    }

    private var panel: some View {
        Color.clear
            .colorPanel(Self.fills[Int(seed.uuid.0) % Self.fills.count], radius: Radius.tile)
            .overlay { SolidPlayGlyph().fill(Ink.panelInk).frame(width: 11, height: 13).offset(x: 1) }
    }
}

/// A mono length on a small ink plate, for the corner of a thumbnail or still ("06:52").
struct StillBadge: View {
    var text: String
    var body: some View {
        Text(text).font(Ink.mono(12)).monospacedDigit().foregroundStyle(Ink.paperFixed)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Ink.inkFixed, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .fixedSize()
    }
}

/// The solid play triangle from the mockup's thumbnails (the play glyph as a filled shape).
struct SolidPlayGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A thin progress bar (6 pt, the Record color on a hairline track) for a transcription in progress.
struct StageProgressBar: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.hairline)
                Capsule().fill(Ink.recordFill).frame(width: max(6, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
        .animation(Motion.settle, value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Reads the percentage out of the engine's stage label ("Transcribing 42%").
enum StageFraction {
    static func fraction(_ stage: String?) -> Double? {
        guard let s = stage, let r = s.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        return Double(s[r].dropLast()).map { $0 / 100 }
    }
}

/// A video still saved in Paths.thumbs.
struct FrameImage: View {
    var file: String
    var body: some View {
        // The rectangle sets the size; the still fills it and is clipped, so it never pushes the layout.
        Rectangle().fill(Ink.track)
            .overlay { ThumbImage(file: file, maxPixel: 900) { Rectangle().fill(Ink.track) } }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }
}

struct Thumbnail: View {
    var info: LinkInfo
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.track)
            .overlay {
                if let f = info.thumbnailFile {
                    ThumbImage(file: f, maxPixel: 200) { IconGlyph(art: .iconPlay, size: 22, color: Ink.mute) }
                } else {
                    IconGlyph(art: .iconPlay, size: 22, color: Ink.mute)
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.hairline))
    }
}
