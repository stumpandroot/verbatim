import SwiftUI
import UIKit

/// The stills viewer on iPhone (DESIGN.md §6.9, Stills viewer; research "Verbose sounds and stills", Part 2): a
/// full-screen cover over the transcript, on opaque paper. Swipe between a transcript's stills (an imported video's, and
/// a call's shared screens, synced from the Mac); pinch or double-tap to zoom, and drag to pan while zoomed in (the
/// pages stop swiping until you zoom back out). The caption is the still's time and place ("12:04", "3 of 9"); Share
/// sends the picture, and Play from here plays the recording from that moment (Pause while it plays). It zooms in from
/// the thumbnail on iOS 18 and later (`stillZoomTransition`); under Limit animation it appears at once. No haptics and
/// no sound: paging is a frequent action.
struct StillViewerScreen: View {
    @Environment(PhoneState.self) var app
    /// Watched directly: Play from here turns into Pause while the recording plays.
    @EnvironmentObject private var player: Player
    @Environment(\.limitMotion) private var limitMotion
    var transcriptID: UUID
    /// The still on screen, in time order (`StillViewerRules.ordered`); the transcript zooms back to its thumbnail.
    @Binding var index: Int
    /// Close: the transcript takes the cover away (at once under Limit animation).
    var close: () -> Void
    @State private var images: [String: UIImage] = [:]
    @State private var missing: Set<String> = []

    /// How many viewers are on screen (the self-test checks it opens and closes), and the still the last one showed.
    static var onScreen = 0
    static var shownIndex: Int?

    private var transcript: Transcript? { app.store.transcript(transcriptID) }

    var body: some View {
        let t = transcript
        let stills = StillViewerRules.ordered(t?.stills ?? [], at: \.at)
        let count = stills.count
        let i = StillViewerRules.clamp(index, count: count)
        let still = stills.isEmpty ? nil : stills[i]
        VStack(spacing: 0) {
            topBar(still, index: i, count: count)
            TabView(selection: $index) {
                ForEach(Array(stills.enumerated()), id: \.element.file) { j, s in
                    page(s, index: j, count: count, active: j == i).tag(j)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            bottomBar(still, audio: t?.audioFileName != nil)
        }
        .background(Refined.paper.ignoresSafeArea())
        .task(id: i) {
            Self.shownIndex = i
            await load(stills, around: i)
        }
        .onAppear { Self.onScreen += 1 }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
    }

    // MARK: Parts

    /// Close, the caption ("12:04" over "3 of 9"), and Share.
    private func topBar(_ still: VideoStill?, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Button { close() } label: {
                TitleCircle { Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Refined.ink) }
            }
            .buttonStyle(RefinedPress())
            .accessibilityLabel("Close")
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                if let still {
                    Text(StillViewerRules.caption(still.at)).refinedFont(.rowTitle, weight: .semibold).monospacedDigit().foregroundStyle(Refined.ink)
                }
                Text(StillViewerRules.position(index, count: count)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let still, let image = images[still.file] {
                let caption = "Still at \(StillViewerRules.caption(still.at))"
                ShareLink(item: Image(uiImage: image), preview: SharePreview(caption, image: Image(uiImage: image))) {
                    TitleCircle { Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(Refined.ink) }
                }
                .buttonStyle(RefinedPress())
                .accessibilityLabel("Share")
            } else {
                // Holds the caption in the middle while the picture loads.
                Color.clear.frame(width: CGFloat(RefinedRules.minTapTarget), height: CGFloat(RefinedRules.minTapTarget)).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    /// One still, fitted to the page and zoomable, or a line while it loads or when it hasn't synced yet.
    @ViewBuilder private func page(_ still: VideoStill, index j: Int, count: Int, active: Bool) -> some View {
        Group {
            if let image = images[still.file] {
                StillZoomPage(image: image, active: active, limitMotion: limitMotion)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(StillViewerRules.spokenLabel(at: still.at, index: j, count: count))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: index = StillViewerRules.step(j, by: 1, count: count)
                        case .decrement: index = StillViewerRules.step(j, by: -1, count: count)
                        @unknown default: break
                        }
                    }
            } else if missing.contains(still.file) {
                Text("This still isn't on this iPhone yet.")
                    .refinedFont(.body).foregroundStyle(Refined.mute).multilineTextAlignment(.center).padding(24)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Play from here (Pause while the recording plays).
    private func bottomBar(_ still: VideoStill?, audio: Bool) -> some View {
        HStack {
            if player.isPlaying {
                Button("Pause") { app.player.toggle() }
                    .buttonStyle(RefinedActionStyle())
            } else if let still {
                Button { app.player.play(from: still.at) } label: {
                    HStack(spacing: 6) {
                        IconGlyph(art: .iconPlay, size: 14, color: Refined.ink)
                        Text("Play from here")
                    }
                }
                .buttonStyle(RefinedActionStyle())
                .disabled(!audio)
                .accessibilityHint("Plays the recording from \(StillViewerRules.caption(still.at)).")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8).padding(.bottom, 12)
    }

    /// The still on screen first, then its neighbors, so a swipe shows at once.
    private func load(_ stills: [VideoStill], around i: Int) async {
        for j in [i, i + 1, i - 1] where stills.indices.contains(j) {
            let file = stills[j].file
            guard images[file] == nil, !missing.contains(file) else { continue }
            if let image = await ThumbCache.load(file, maxPixel: 4096) { images[file] = image } else { missing.insert(file) }
        }
    }
}

extension View {
    /// The thumbnail the stills viewer zooms from (iOS 18 and later).
    @ViewBuilder func stillZoomSource(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// The viewer's zoom from its thumbnail (iOS 18 and later), with the system's swipe down to close. Off under
    /// Limit animation, where the cover appears at once.
    @ViewBuilder func stillZoomTransition(_ id: String, in namespace: Namespace.ID, enabled: Bool) -> some View {
        if #available(iOS 18, *), enabled {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

// MARK: - Zooming

/// One still in a zooming scroll view: pinch to zoom, drag to pan while zoomed in, and double-tap to zoom in or back
/// to fitting (`StillZoom`). A page that's swiped away fits again.
private struct StillZoomPage: UIViewRepresentable {
    var image: UIImage
    var active: Bool
    var limitMotion: Bool

    func makeUIView(context: Context) -> PhoneStillScrollView {
        let view = PhoneStillScrollView()
        view.limitMotion = limitMotion
        view.show(image)
        return view
    }

    func updateUIView(_ view: PhoneStillScrollView, context: Context) {
        view.limitMotion = limitMotion
        if view.image !== image { view.show(image) }
        if !active { view.fitToSpace() }
    }
}

/// The scroll view behind `StillZoomPage`. Zoom scale 1 draws the still at its own pixel size; the smallest is the
/// size that fits and the largest `StillZoom.maxScale`. While fitted, it can't scroll sideways, so the page swipes.
final class PhoneStillScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private(set) var image: UIImage?
    var limitMotion = false
    private var fitted = true
    private var laidOut: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        bouncesZoom = true
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        imageView.isAccessibilityElement = false
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: UIImage) {
        self.image = image
        minimumZoomScale = 0.01
        maximumZoomScale = 100
        zoomScale = 1
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        fitted = true
        laidOut = .zero
        setNeedsLayout()
    }

    private var fitScale: Double {
        guard let image else { return 1 }
        return StillZoom.fit(imageWidth: Double(image.size.width), imageHeight: Double(image.size.height),
                             viewportWidth: Double(bounds.width), viewportHeight: Double(bounds.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard image != nil, bounds.width > 0, bounds.height > 0, bounds.size != laidOut else { return }
        laidOut = bounds.size
        let fit = fitScale
        minimumZoomScale = CGFloat(fit)
        maximumZoomScale = CGFloat(StillZoom.maxScale(fit: fit))
        if fitted || !StillZoom.isZoomed(Double(zoomScale), fit: fit) {
            fitted = true
            zoomScale = CGFloat(fit)
        }
        center()
    }

    /// Back to the whole still (a page swiped away).
    func fitToSpace() {
        guard image != nil, StillZoom.isZoomed(Double(zoomScale), fit: fitScale) else { return }
        fitted = true
        setZoomScale(minimumZoomScale, animated: false)
        center()
    }

    /// Keeps the still in the middle while it's smaller than the page.
    private func center() {
        let x = max(0, (bounds.width - imageView.frame.width) / 2)
        let y = max(0, (bounds.height - imageView.frame.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        fitted = !StillZoom.isZoomed(Double(scale), fit: fitScale)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        let fit = fitScale
        let target = StillZoom.doubleTap(Double(zoomScale), fit: fit)
        let p = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / CGFloat(target), height: bounds.height / CGFloat(target))
        zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: !limitMotion)
        fitted = !StillZoom.isZoomed(target, fit: fit)
    }
}
