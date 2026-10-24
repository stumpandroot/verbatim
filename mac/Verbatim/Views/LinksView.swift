import SwiftUI
import AppKit
import ImageIO

// brand: web style
//
// Links in the website style (mac/DESIGN.md §11): a compact title with a mono count, site chips, and flat rows with
// a 128×72 thumbnail, a serif title, a mono meta line, plain status text, and pill actions.

/// Every link you've transcribed: the original page one click away, with its thumbnail, channel, and date.
struct LinksView: View {
    @EnvironmentObject var app: AppState
    @State private var site: String? = nil

    private var all: [Transcript] { app.filtered.filter { $0.linkInfo != nil } }
    private var sites: [String] { Array(Set(all.compactMap { $0.linkInfo?.site })).sorted() }
    private var shown: [Transcript] { all.filter { site == nil || $0.linkInfo?.site == site } }

    var body: some View {
        let all = self.all, shown = self.shown, sites = self.sites
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
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                            LinkRow(transcript: t).staggerIn(2 + min(i, 8))
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
    }

    private func pasteLink() { app.goHome(); app.focusLink.toggle() }
}

/// The older capsule chip, still used by screens that haven't moved to the website style (Dictionary, Dictations).
struct SiteChip: View {
    var label: String; var on: Bool; var action: () -> Void
    var body: some View {
        Text(label).font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(on ? Ink.iris : Ink.track, in: Capsule())
            .foregroundStyle(on ? Ink.onInteractive : Ink.ink)
            .tapArea(action)
    }
}

/// A flat Links row: thumbnail, serif title, channel · site · date · length in mono, the status as plain text, then
/// Open video, Transcript, and the ⋯ menu. Clicking the row opens the transcript; dragging it files it in a project.
struct LinkRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    /// Open video, Transcript, and the ⋯ button, with their gaps.
    private static let actionsWidth: CGFloat = 222

    var body: some View {
        let info = transcript.linkInfo!
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
        .contextMenu {
            Button("Open video") { open(info) }
            Button("Copy link") { copy(info.url) }
            Divider()
            RowMenu(transcript: transcript)
        }
    }

    private var title: (String, String?) {
        WebText.split(transcript.title, after: transcript.projectId.flatMap { id in app.store.projects.first { $0.id == id }?.name })
    }

    /// "Lapp Wagons · YouTube · Oct 12, 2026 · 06:52".
    private func metaLine(_ info: LinkInfo) -> String {
        [info.channel, info.site, info.uploadDisplay, transcript.duration > 0 ? WebFormat.clock(transcript.duration) : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Plain status text: a thin Record-colored bar while transcribing, failures in danger, and "✓ Video kept".
    @ViewBuilder private var status: some View {
        if transcript.status == .processing {
            HStack(spacing: 10) {
                if let f = StageFraction.fraction(transcript.stage) {
                    StageProgressBar(value: f).frame(width: 180)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(transcript.stageText).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim)
                    .monospacedDigit().lineLimit(1)
            }
        } else if transcript.status == .failed {
            StatusText(text: "Transcription failed", tone: .danger)
        } else if let busy = app.keeping[transcript.id] {
            StatusText(text: busy, tone: .dim).monospacedDigit()
        } else if let v = transcript.keptVideo, !v.isEmpty, FileManager.default.fileExists(atPath: v) {
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
            .overlay { SolidPlayGlyph().fill(Ink.inkFixed).frame(width: 11, height: 13).offset(x: 1) }
    }
}

/// A still from `Paths.thumbs`, read and scaled down off the main thread once, then kept in memory (`ThumbCache`).
/// A plain track shows while it loads; `missing` shows when there's no readable file. (Reading the file in `body`
/// decoded every thumbnail on the main thread on every render.)
struct ThumbImage<Missing: View>: View {
    var file: String
    /// The longest side to decode, in pixels: about twice the largest size it's drawn at.
    var maxPixel: Int
    @ViewBuilder var missing: () -> Missing
    @State private var loaded: NSImage?
    @State private var failed = false

    var body: some View {
        let image = loaded ?? ThumbCache.cached(file, maxPixel: maxPixel)
        ZStack {
            if let image {
                Rectangle().fill(Ink.track)
                    .overlay { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    .clipped()
            } else if failed {
                missing()
            } else {
                Rectangle().fill(Ink.track)
            }
        }
        .task(id: file) {
            guard ThumbCache.cached(file, maxPixel: maxPixel) == nil else { return }
            if let img = await ThumbCache.load(file, maxPixel: maxPixel) { loaded = img; failed = false } else { failed = true }
        }
    }
}

/// Decoded stills by file and size. Missing files aren't remembered, so a still that arrives later (iCloud) shows
/// the next time its view appears.
@MainActor
enum ThumbCache {
    private static let images: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    private static func key(_ file: String, _ maxPixel: Int) -> NSString { "\(file)@\(maxPixel)" as NSString }

    static func cached(_ file: String, maxPixel: Int) -> NSImage? { images.object(forKey: key(file, maxPixel)) }

    static func load(_ file: String, maxPixel: Int) async -> NSImage? {
        if let hit = cached(file, maxPixel: maxPixel) { return hit }
        guard let url = LibraryFile.url(file, in: Paths.thumbs, field: "thumbnail") else { return nil }
        let cg: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        images.setObject(image, forKey: key(file, maxPixel))
        return image
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
