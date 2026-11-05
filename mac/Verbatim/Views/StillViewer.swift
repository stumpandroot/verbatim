import SwiftUI
import AppKit
import VisionKit

/// Which still the stills viewer shows (`WindowNav.stillViewer`): the transcript, and the still's place among its
/// stills in time order (`StillViewerRules.ordered`).
struct StillViewerTarget: Equatable {
    var transcript: UUID
    var index: Int
}

extension WindowNav {
    /// Opens the stills viewer over the open transcript on its `index`th still. A click opens it on `Motion.page`, a
    /// crossfade under Limit animation.
    @MainActor func openStill(_ index: Int, of transcript: UUID, limited: Bool) {
        withAnimation(limited ? Motion.crossfade : Motion.page) { stillViewer = StillViewerTarget(transcript: transcript, index: index) }
    }

    /// Closes it: with the motion from a click, at once from Esc (keyboard actions don't animate, DESIGN.md §7).
    @MainActor func closeStill(animated: Bool, limited: Bool) {
        if animated {
            withAnimation(limited ? Motion.crossfade : Motion.page) { stillViewer = nil }
        } else {
            stillViewer = nil
        }
    }
}

/// The stills viewer (DESIGN.md §6.9, Stills viewer; research "Verbose sounds and stills", Part 2): a transcript's
/// stills (an imported video's, and a call's shared screens) over its reading column, on opaque paper with no glass
/// behind the picture. The still fits the space and zooms with a pinch or trackpad magnify and ⌘+, ⌘−, and ⌘0 (fit);
/// zoomed in, it pans with a scroll. ← and → step through the stills, Esc closes, and ⌘C copies the picture (or the
/// slide text you selected with Live Text). Its caption is the still's time and place ("12:04", "3 of 9"), and Play
/// from here plays the recording from that moment with the viewer still open (it turns into Pause while it plays).
/// Opened by a click on a still in the margin (`SegmentLine`).
struct StillViewer: View {
    @Environment(AppState.self) var app
    @EnvironmentObject private var nav: WindowNav
    /// Watched directly: Play from here turns into Pause while the recording plays.
    @EnvironmentObject private var player: Player
    @Environment(\.limitMotion) private var limited
    var transcript: Transcript
    var index: Int
    /// Decoded stills by file, at up to 4,096 pixels on the longest side.
    @State private var images: [String: NSImage] = [:]
    @State private var missing: Set<String> = []
    /// Talks to the zooming view (zoom, fit, selected Live Text).
    @State private var zoom = StillZoomControl()

    /// How many viewers are on screen (the self-test checks it opens and closes), and the still the last one showed.
    static var onScreen = 0
    static var shownIndex: Int?

    private var stills: [VideoStill] { StillViewerRules.ordered(transcript.stills ?? [], at: \.at) }

    var body: some View {
        let stills = self.stills
        let count = stills.count
        let i = StillViewerRules.clamp(index, count: count)
        let still = stills.isEmpty ? nil : stills[i]
        VStack(spacing: 14) {
            topBar(still)
            picture(still, index: i, count: count)
            bottomBar(still, index: i, count: count)
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque: nothing of the transcript shows through, and no glass sits behind the picture.
        .background(Refined.paper.ignoresSafeArea())
        .contentShape(Rectangle())
        .background { shortcuts(index: i, count: count) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .uiTarget("still-viewer")
        .task(id: still?.file) {
            Self.shownIndex = i
            await load(stills, around: i)
        }
        .onAppear { Self.onScreen += 1 }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
    }

    // MARK: Parts

    /// The transcript's title, then Play from here, Copy image, and Close.
    private func topBar(_ still: VideoStill?) -> some View {
        HStack(spacing: 10) {
            Text(transcript.title).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
            Spacer(minLength: 12)
            if let still {
                if player.isPlaying {
                    Button("Pause") { app.player.toggle() }
                        .buttonStyle(RefinedActionStyle())
                        .help("Pause (Space)")
                } else {
                    Button { play(still) } label: {
                        HStack(spacing: 6) {
                            IconGlyph(art: .iconPlay, size: 12, color: Refined.ink)
                            Text("Play from here")
                        }
                    }
                    .buttonStyle(RefinedActionStyle())
                    .disabled(transcript.audioFileName == nil)
                    .help("Play from \(StillViewerRules.caption(still.at))")
                }
                Button("Copy image") { copy(still) }
                    .buttonStyle(RefinedActionStyle())
                    .disabled(images[still.file] == nil)
                    .help("Copy image (⌘C)")
            }
            RefinedCircleButton(symbol: "xmark", label: "Close") { nav.closeStill(animated: true, limited: limited) }
                .help("Close (Esc)")
                .uiTarget("still-viewer-close")
        }
    }

    /// The still, fitted to the space, or a line while it loads or when it isn't on this Mac.
    @ViewBuilder private func picture(_ still: VideoStill?, index: Int, count: Int) -> some View {
        ZStack {
            if let still, let image = images[still.file] {
                StillZoomView(image: image, control: zoom) { key in handle(key, index: index, count: count) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(StillViewerRules.spokenLabel(at: still.at, index: index, count: count))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: step(1, from: index, count: count)
                        case .decrement: step(-1, from: index, count: count)
                        @unknown default: break
                        }
                    }
                    .accessibilityActions {
                        Button("Play from here") { play(still) }
                        Button("Copy image") { copy(still) }
                    }
            } else if let still, missing.contains(still.file) {
                Text("This still isn't on this Mac yet.").refinedFont(.body).foregroundStyle(Refined.mute)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Previous, the caption ("12:04" over "3 of 9"), and Next.
    private func bottomBar(_ still: VideoStill?, index: Int, count: Int) -> some View {
        HStack(spacing: 16) {
            RefinedCircleButton(symbol: "chevron.left", label: "Previous still") { step(-1, from: index, count: count) }
                .disabled(!StillViewerRules.hasPrevious(index, count: count))
                .opacity(StillViewerRules.hasPrevious(index, count: count) ? 1 : 0.4)
                .help("Previous still (←)")
            VStack(spacing: 2) {
                if let still {
                    Text(StillViewerRules.caption(still.at)).refinedFont(.rowTitle, weight: .semibold).monospacedDigit().foregroundStyle(Refined.ink)
                }
                Text(StillViewerRules.position(index, count: count)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
            }
            .frame(minWidth: 72)
            .accessibilityElement(children: .combine)
            RefinedCircleButton(symbol: "chevron.right", label: "Next still") { step(1, from: index, count: count) }
                .disabled(!StillViewerRules.hasNext(index, count: count))
                .opacity(StillViewerRules.hasNext(index, count: count) ? 1 : 0.4)
                .help("Next still (→)")
                .uiTarget("still-viewer-next")
        }
    }

    /// The keys, as hidden buttons so they work wherever focus is in the window: ← and →, Esc, ⌘+ (and ⌘=), ⌘−, ⌘0,
    /// and ⌘C. None of them animates.
    private func shortcuts(index: Int, count: Int) -> some View {
        ZStack {
            Button("") { step(-1, from: index, count: count) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1, from: index, count: count) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { nav.closeStill(animated: false, limited: limited) }.keyboardShortcut(.cancelAction)
            Button("") { zoom.zoomIn() }.keyboardShortcut("=", modifiers: .command)
            Button("") { zoom.zoomIn() }.keyboardShortcut("+", modifiers: .command)
            Button("") { zoom.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("") { zoom.fit() }.keyboardShortcut("0", modifiers: .command)
            Button("") { if let s = stills.isEmpty ? nil : stills[index] { copy(s) } }.keyboardShortcut("c", modifiers: .command)
        }
        .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Actions

    private func step(_ delta: Int, from index: Int, count: Int) {
        let next = StillViewerRules.step(index, by: delta, count: count)
        guard next != index, nav.stillViewer != nil else { return }
        nav.stillViewer?.index = next
    }

    private func handle(_ key: StillZoomKey, index: Int, count: Int) -> Bool {
        switch key {
        case .previous: step(-1, from: index, count: count)
        case .next: step(1, from: index, count: count)
        case .close: nav.closeStill(animated: false, limited: limited)
        }
        return true
    }

    private func play(_ still: VideoStill) {
        app.player.play(from: still.at)
    }

    /// ⌘C: the slide text selected with Live Text when there is some, else the picture.
    private func copy(_ still: VideoStill) {
        let pb = NSPasteboard.general
        if let text = zoom.selectedText(), !text.isEmpty {
            pb.clearContents(); pb.setString(text, forType: .string)
            app.toast = Toast("Text copied")
            return
        }
        guard let image = images[still.file] else { return }
        pb.clearContents(); pb.writeObjects([image])
        app.toast = Toast("Image copied")
    }

    /// The still on screen first, then its neighbors, so a step shows at once.
    private func load(_ stills: [VideoStill], around i: Int) async {
        for j in [i, i + 1, i - 1] where stills.indices.contains(j) {
            let file = stills[j].file
            guard images[file] == nil, !missing.contains(file) else { continue }
            if let image = await ThumbCache.load(file, maxPixel: 4096) { images[file] = image } else { missing.insert(file) }
        }
    }
}

// MARK: - Zooming

/// The keys the zooming view passes back when it has focus (Live Text can take it).
enum StillZoomKey { case previous, next, close }

/// Lets the SwiftUI viewer drive its AppKit zooming view: ⌘+, ⌘−, ⌘0, and the Live Text selection for ⌘C.
@MainActor final class StillZoomControl {
    weak var view: StillScrollView?
    func zoomIn() { view?.zoom(in: true) }
    func zoomOut() { view?.zoom(in: false) }
    func fit() { view?.fitToSpace() }
    func selectedText() -> String? { view?.selectedText() }
}

/// The still in a magnifying scroll view: pinch or trackpad magnify zooms around the pointer, a scroll pans when
/// zoomed in, and Live Text lies over it so slide text can be selected.
private struct StillZoomView: NSViewRepresentable {
    var image: NSImage
    var control: StillZoomControl
    var onKey: (StillZoomKey) -> Bool

    func makeNSView(context: Context) -> StillScrollView {
        let view = StillScrollView()
        view.onKey = onKey
        view.show(image)
        control.view = view
        return view
    }

    func updateNSView(_ view: StillScrollView, context: Context) {
        view.onKey = onKey
        control.view = view
        if view.image !== image { view.show(image) }
    }
}

/// Centers the still while it's smaller than the space, instead of pinning it to a corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// The scroll view behind `StillZoomView`. Magnification 1 draws the still at its own pixel size; the smallest is the
/// size that fits (`StillZoom.fit`) and the largest `StillZoom.maxScale`. While the still fits, a resize fits it
/// again; zoomed in, a resize keeps the scale.
final class StillScrollView: NSScrollView {
    private let imageView = NSImageView()
    private(set) var image: NSImage?
    var onKey: ((StillZoomKey) -> Bool)?
    /// The still fits the space (not zoomed in).
    private var fitted = true
    private var refitting = false
    /// The space the last fit was worked out for: a layout pass with the same space changes nothing.
    private var laidOut: NSSize = .zero
    private var overlay: ImageAnalysisOverlayView?
    private var analysis: Task<Void, Never>?
    private static let analyzer = ImageAnalyzer()

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        imageView.setAccessibilityElement(false)
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(magnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { analysis?.cancel() }

    func show(_ image: NSImage) {
        self.image = image
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        fitted = true
        laidOut = contentSize
        refit()
        startLiveText(image)
    }

    private var fitScale: Double {
        StillZoom.fit(imageWidth: Double(imageView.frame.width), imageHeight: Double(imageView.frame.height),
                      viewportWidth: Double(contentSize.width), viewportHeight: Double(contentSize.height))
    }

    /// Sets the limits from the space there is, and fits the still when it isn't zoomed in.
    private func refit() {
        guard !refitting, contentSize.width > 0, contentSize.height > 0 else { return }
        refitting = true
        defer { refitting = false }
        let fit = fitScale
        minMagnification = CGFloat(fit)
        maxMagnification = CGFloat(StillZoom.maxScale(fit: fit))
        if fitted || !StillZoom.isZoomed(Double(magnification), fit: fit) {
            fitted = true
            magnification = CGFloat(fit)
        }
    }

    override func layout() {
        super.layout()
        guard contentSize != laidOut else { return }
        laidOut = contentSize
        refit()
    }

    /// ⌘+ and ⌘−: one step around the middle of what's showing, at once.
    func zoom(in zoomIn: Bool) {
        let fit = fitScale
        let now = Double(magnification)
        let to = zoomIn ? StillZoom.zoomIn(now, fit: fit) : StillZoom.zoomOut(now, fit: fit)
        let visible = contentView.documentVisibleRect
        setMagnification(CGFloat(to), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        fitted = !StillZoom.isZoomed(to, fit: fit)
    }

    /// ⌘0: the whole still.
    func fitToSpace() {
        fitted = true
        refit()
    }

    @objc private func magnifyEnded(_ note: Notification) {
        fitted = !StillZoom.isZoomed(Double(magnification), fit: fitScale)
    }

    // ← → and Esc reach here when the still (or its Live Text) has focus.
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        var key: StillZoomKey?
        switch event.keyCode {
        case 123: key = .previous
        case 124: key = .next
        case 53: key = .close
        default: key = nil
        }
        if let key, event.modifierFlags.intersection([.command, .option, .control]).isEmpty, onKey?(key) == true { return }
        super.keyDown(with: event)
    }

    // MARK: Live Text

    /// Lays Live Text over the still once Apple's image analysis has found its text (macOS 13 and later, on Macs
    /// that support it), so slide text can be selected and copied.
    private func startLiveText(_ image: NSImage) {
        analysis?.cancel()
        overlay?.removeFromSuperview()
        overlay = nil
        guard ImageAnalyzer.isSupported else { return }
        let view = ImageAnalysisOverlayView()
        view.frame = imageView.bounds
        view.autoresizingMask = [.width, .height]
        view.trackingImageView = imageView
        view.preferredInteractionTypes = .textSelection
        imageView.addSubview(view)
        overlay = view
        analysis = Task { @MainActor [weak view] in
            let configuration = ImageAnalyzer.Configuration([.text])
            guard let result = try? await Self.analyzer.analyze(image, orientation: .up, configuration: configuration),
                  !Task.isCancelled else { return }
            view?.analysis = result
        }
    }

    /// The text selected with Live Text, if any.
    func selectedText() -> String? {
        guard let overlay, overlay.hasActiveTextSelection else { return nil }
        return overlay.selectedText
    }
}
