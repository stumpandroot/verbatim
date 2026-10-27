import SwiftUI

// The "link added" moment, shared by the Mac and iPhone apps (approved web prototype, link-modal.html, October 2026).
//
// Pasting a link shows a centered card over a light scrim: the thumbnail as soon as it's known, the title (a
// shimmering placeholder until then), and the download as it happens. When the audio is in the queue, or when you
// choose Keep in background (Done once it's queued), the card folds in place into a small sage video tile, which then flies to the Queue item (Mac
// sidebar) or the Library tab (iPhone) and the count there goes up. Downloading keeps going either way.
//
// Motion (from the prototype): enter spring(0.38, bounce 0.22) from scale 0.94, y +14, opacity 0; fold
// spring(0.42, 0.18); hold 0.14 s; fly spring(0.48, 0.08) to scale 0.3, opacity 0.35. Cancel fades down (y +12,
// scale 0.96, 0.22 s, no bounce). With Reduce Motion or Limit animation it all becomes crossfades and nothing flies.

/// Card sizes per platform.
struct LinkCardMetrics {
    var width: CGFloat
    var padding: CGFloat
    var thumbHeight: CGFloat
    var titleSize: CGFloat
    var glyph: CGFloat
    var tile: CGFloat
    var miniIcon: CGFloat
    var buttonHeight: CGFloat
    /// How far above center the card sits (the iPhone keeps it clear of the tab bar and the home indicator).
    var lift: CGFloat
    /// Wait before the card enters (the iPhone's link sheet is still sliding away).
    var appearDelay: Double

    static let mac = LinkCardMetrics(width: 360, padding: 14, thumbHeight: 150, titleSize: 22, glyph: 56, tile: 68,
                                     miniIcon: 30, buttonHeight: 38, lift: 0, appearDelay: 0)
    static let phone = LinkCardMetrics(width: 280, padding: 12, thumbHeight: 116, titleSize: 19, glyph: 44, tile: 58,
                                       miniIcon: 26, buttonHeight: 44, lift: 40, appearDelay: 0.3)
}

/// The card, the scrim, and the fold-and-fly. Lay it over the whole window (Mac: ContentView; iPhone: above the
/// TabView) so the tile can cross from the content into the sidebar or tab bar.
struct LinkCardOverlay: View {
    @ObservedObject var imp: LinkImport
    var metrics: LinkCardMetrics
    /// Where the tile lands, in this view's coordinate space. Nil: the card folds and fades where it is.
    var target: CGPoint?
    /// The region the scrim darkens, in this view's coordinate space; nil darkens all of it.
    var scrimRect: CGRect? = nil
    /// Cancel: stop the download and remove the transcript. Called at once; the card then fades away.
    var onCancel: () -> Void
    var onRetry: () -> Void
    /// The tile arrived (or, with motion limited, the card faded): the count goes up now.
    var onLanded: () -> Void
    /// The card is gone; the host can let go of it.
    var onClosed: () -> Void

    @Environment(\.limitMotion) private var limitMotion
    private enum Stage { case entering, shown, folded, flying, faded, leaving }
    @State private var stage: Stage = .entering
    @State private var finishing = false
    @State private var autoFinish: DispatchWorkItem?

    var body: some View {
        GeometryReader { g in
            let center = CGPoint(x: g.size.width / 2, y: max(metrics.tile, g.size.height / 2 - metrics.lift))
            ZStack(alignment: .topLeading) {
                scrim(in: g.size)
                card
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .offset(offset(from: center))
                    .position(center)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .onAppear(perform: enter)
        .onChange(of: imp.phase) { _, phase in react(to: phase) }
        .onDisappear { autoFinish?.cancel() }
    }

    // MARK: Pieces

    private var folded: Bool { stage == .folded || stage == .flying }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: folded ? 17 : 18, style: .continuous)
        return ZStack {
            LinkAddedCard(imp: imp, metrics: metrics, onCancel: cancel, onDone: finish, onRetry: retry)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(folded ? 0 : 1)
                .animation(.easeOut(duration: 0.11), value: folded)
                .allowsHitTesting(!folded && !finishing)
            VideoTileIcon()
                .frame(width: metrics.miniIcon, height: metrics.miniIcon)
                .opacity(folded ? 1 : 0)
                .animation(.easeOut(duration: 0.14).delay(0.06), value: folded)
                .accessibilityHidden(true)
        }
        .frame(width: folded ? metrics.tile : nil, height: folded ? metrics.tile : nil)
        // Sage: a link is an import (persimmon means Record).
        .background(folded ? Ink.sage : Ink.card, in: shape)
        .overlay(shape.strokeBorder(Ink.hairline).opacity(folded ? 0 : 1))
        .clipShape(shape)
        .shadow(color: Ink.inkFixed.opacity(folded ? 0.1 : 0.12), radius: folded ? 3 : 4, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link added")
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private func scrim(in size: CGSize) -> some View {
        let r = scrimRect ?? CGRect(origin: .zero, size: size)
        Ink.inkFixed.opacity(0.18)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .opacity(stage == .shown && !finishing ? 1 : 0)
            .animation(.easeOut(duration: 0.18), value: stage == .shown && !finishing)
            .contentShape(Rectangle())
            // Clicking outside the card is Done: the card goes, the download keeps going.
            .onTapGesture { if stage == .shown { finish() } }
            .allowsHitTesting(stage == .shown && !finishing)
            .accessibilityHidden(true)
    }

    // MARK: Geometry per stage

    private var scale: CGFloat {
        switch stage {
        case .entering: return limitMotion ? 1 : 0.94
        case .flying: return 0.3
        case .leaving: return limitMotion ? 1 : 0.96
        case .shown, .folded, .faded: return 1
        }
    }

    private var opacity: Double {
        switch stage {
        case .entering, .faded, .leaving: return 0
        case .flying: return 0.35
        case .shown, .folded: return 1
        }
    }

    private func offset(from center: CGPoint) -> CGSize {
        switch stage {
        case .entering: return CGSize(width: 0, height: limitMotion ? 0 : 14)
        case .leaving: return CGSize(width: 0, height: limitMotion ? 0 : 12)
        case .flying:
            guard let t = target else { return .zero }
            return CGSize(width: t.x - center.x, height: t.y - center.y)
        case .shown, .folded, .faded: return .zero
        }
    }

    // MARK: Flow

    private func enter() {
        DispatchQueue.main.asyncAfter(deadline: .now() + metrics.appearDelay) {
            guard stage == .entering else { return }
            withAnimation(limitMotion ? Motion.fade : .smooth(duration: 0.3)) { stage = .shown }
            react(to: imp.phase)
        }
    }

    /// The audio is in the queue (or handed to the Mac): say so, hold a beat, then fold away.
    private func react(to phase: LinkImport.Phase) {
        switch phase {
        case .queued, .waitingForMac:
            guard !finishing, autoFinish == nil else { return }
            let title = imp.title ?? imp.site ?? "link"
            AccessibilityNotification.Announcement(phase == .queued ? "Added to Queue: \(title)" : "Sent to your Mac: \(title)").post()
            let work = DispatchWorkItem { finish() }
            autoFinish = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        case .resolving, .downloading:
            autoFinish?.cancel(); autoFinish = nil
        case .failed:
            autoFinish?.cancel(); autoFinish = nil
            AccessibilityNotification.Announcement("Couldn't download the link").post()
        }
    }

    /// Done, the scrim, or the download finishing: fold into the tile, then fly it to the target.
    private func finish() {
        guard !finishing, stage == .shown || stage == .entering else { return }
        finishing = true
        autoFinish?.cancel(); autoFinish = nil
        if limitMotion {
            withAnimation(Motion.fade, completionCriteria: .logicallyComplete) { stage = .faded } completion: {
                onLanded(); onClosed()
            }
            return
        }
        withAnimation(.smooth(duration: 0.4), completionCriteria: .logicallyComplete) { stage = .folded } completion: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                if target == nil {
                    withAnimation(Motion.fade, completionCriteria: .logicallyComplete) { stage = .faded } completion: { onLanded(); onClosed() }
                } else {
                    withAnimation(.smooth(duration: 0.45), completionCriteria: .logicallyComplete) { stage = .flying } completion: {
                        onLanded(); onClosed()
                    }
                }
            }
        }
    }

    private func cancel() {
        guard !finishing else { return }
        finishing = true
        autoFinish?.cancel(); autoFinish = nil
        onCancel()
        withAnimation(limitMotion ? Motion.fade : .spring(duration: 0.22, bounce: 0), completionCriteria: .logicallyComplete) { stage = .leaving } completion: {
            onClosed()
        }
    }

    private func retry() {
        autoFinish?.cancel(); autoFinish = nil
        onRetry()
    }
}

/// The card's contents: thumbnail, title, status, and buttons. Sized by `LinkCardMetrics`.
struct LinkAddedCard: View {
    @ObservedObject var imp: LinkImport
    var metrics: LinkCardMetrics
    var onCancel: () -> Void
    var onDone: () -> Void
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            thumbnail
            title
            status
            if case .failed(let reason) = imp.phase {
                Text(reason)
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button(action: onCancel) { label(Self.cancelTitle(imp.phase)) }
                    .buttonStyle(LinkCardButtonStyle(fill: Ink.ink.opacity(0.08), text: Ink.ink))
                if failed {
                    Button(action: onRetry) { label("Retry") }
                        .buttonStyle(LinkCardButtonStyle(fill: Ink.interactive, text: Ink.onInteractive))
                        .keyboardShortcut(.defaultAction)
                } else {
                    // Escape is Done, not Cancel: closing the card never throws a download away.
                    Button(action: onDone) { label(Self.doneTitle(imp.phase)) }
                        .buttonStyle(LinkCardButtonStyle(fill: Ink.interactive, text: Ink.onInteractive))
                        .keyboardShortcut(.cancelAction)
                        .help("Close this card (Esc). The download keeps going and the link joins the queue.")
                }
            }
        }
        .padding(metrics.padding)
        .frame(width: metrics.width)
        .animation(Motion.fade, value: imp.title)
        .animation(Motion.fade, value: failed)
    }

    private var failed: Bool { if case .failed = imp.phase { return true }; return false }

    /// While the audio is still coming: "Cancel download" and "Keep in background", so neither reads as stop or hide
    /// by guesswork. Once it's queued or sent: "Cancel" and "Done".
    static func cancelTitle(_ phase: LinkImport.Phase) -> String { downloading(phase) ? "Cancel download" : "Cancel" }
    static func doneTitle(_ phase: LinkImport.Phase) -> String { downloading(phase) ? "Keep in background" : "Done" }
    private static func downloading(_ phase: LinkImport.Phase) -> Bool {
        switch phase {
        case .resolving, .downloading: return true
        default: return false
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: metrics.buttonHeight)
            .contentShape(Rectangle())
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        return ZStack {
            StripedPaper()
            BrandGlyph(art: .diagramCapture, color: Ink.ink, minLineWidth: 1)
                .frame(width: metrics.glyph, height: metrics.glyph)
            if let url = imp.thumbnailURL {
                AsyncImage(url: url, transaction: Transaction(animation: Motion.fade)) { phase in
                    if case .success(let image) = phase {
                        Color.clear.overlay { image.resizable().scaledToFill() }.clipped().transition(.opacity)
                    } else {
                        Color.clear
                    }
                }
                .id(url)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: metrics.thumbHeight)
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            if let site = imp.site, !site.isEmpty {
                Text(site)
                    .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(Color(hex: Ink.paperHex))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Ink.inkFixed, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let d = imp.duration, d > 0 {
                Text(Self.clock(d))
                    .font(Ink.mono(11)).foregroundStyle(Color(hex: Ink.paperHex))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Ink.inkFixed.opacity(0.82), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
    }

    static func clock(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Title

    @ViewBuilder private var title: some View {
        if let t = imp.title, !t.isEmpty {
            Text(t)
                .font(Ink.serif(metrics.titleSize)).foregroundStyle(Ink.ink)
                .lineLimit(3).lineSpacing(0)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else {
            ShimmerBar()
                .frame(height: (metrics.titleSize * 1.15).rounded())
                .accessibilityLabel("Loading the title")
        }
    }

    // MARK: Status

    private var status: some View {
        HStack(spacing: 10) {
            Text(phaseText)
                .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                .foregroundStyle(failed ? Ink.danger : Ink.mute)
                .fixedSize()
            if !failed {
                ProgressRail(value: fraction)
                Text(percentText)
                    .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Ink.mute)
                    .frame(minWidth: 34, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failed ? "Couldn't download" : "\(phaseText), \(percentText)")
    }

    private var phaseText: String {
        switch imp.phase {
        case .resolving: return "Finding the audio"
        case .downloading: return "Downloading"
        case .queued: return "Added to the queue"
        case .waitingForMac: return "Sent to your Mac"
        case .failed: return "Couldn't download"
        }
    }

    private var fraction: Double {
        switch imp.phase {
        case .queued, .waitingForMac: return 1
        default: return min(1, max(0, imp.progress ?? 0))
        }
    }

    private var percentText: String { "\(Int((fraction * 100).rounded()))%" }
}

/// The card's two buttons, pills like every Verbose button (DESIGN.md §11.5): the ink-text one is the line pill
/// (a 1.5 pt ink outline), the other the dark pill in its fill.
struct LinkCardButtonStyle: ButtonStyle {
    var fill: Color
    var text: Color
    func makeBody(configuration: Configuration) -> some View {
        let line = text == Ink.ink
        return configuration.label
            .foregroundStyle(text)
            .background(line ? Color.clear : fill, in: Capsule())
            .overlay { if line { Capsule().strokeBorder(Ink.ink, lineWidth: 1.5) } }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A 4 pt sage bar on a faint ink rail (links are imports).
struct ProgressRail: View {
    var value: Double
    var body: some View {
        Capsule().fill(Ink.ink.opacity(0.1))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(Ink.sageText).frame(width: g.size.width * value)
                }
            }
            .animation(.linear(duration: 0.16), value: value)
            .accessibilityHidden(true)
    }
}

/// The title's placeholder: a still, soft bar (nothing loops, DESIGN.md §7; the status line and progress rail
/// below show that the link is loading).
struct ShimmerBar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.placeholder)
    }
}

/// The thumbnail's stand-in: diagonal paper stripes, 10 pt each way.
struct StripedPaper: View {
    private static let a = Ink.stripeA
    private static let b = Ink.stripeB
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.a))
            let reach = size.width + size.height
            var c = ctx
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: .degrees(45))
            var p = Path()
            var x = -reach
            while x < reach {
                p.addRect(CGRect(x: x + 10, y: -reach, width: 10, height: reach * 2))
                x += 20
            }
            c.fill(p, with: .color(Self.b))
        }
        .accessibilityHidden(true)
    }
}

/// The folded tile's icon: a fine-line video frame with a filled play triangle, in ink (24-unit grid).
struct VideoTileIcon: View {
    var color: Color = Ink.inkFixed
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            let t = CGAffineTransform(translationX: (size.width - 24 * s) / 2, y: (size.height - 24 * s) / 2).scaledBy(x: s, y: s)
            let frame = Path(roundedRect: CGRect(x: 3, y: 5.5, width: 18, height: 13), cornerRadius: 2.5).applying(t)
            var play = Path()
            play.move(to: CGPoint(x: 10, y: 9.2)); play.addLine(to: CGPoint(x: 10, y: 14.8)); play.addLine(to: CGPoint(x: 14.6, y: 12)); play.closeSubpath()
            let style = StrokeStyle(lineWidth: max(1.2, 1.5 * s), lineCap: .round, lineJoin: .round)
            ctx.stroke(frame, with: .color(color), style: style)
            ctx.fill(play.applying(t), with: .color(color))
            ctx.stroke(play.applying(t), with: .color(color), style: style)
        }
    }
}

/// A count badge: a neutral pill (counts never borrow an action hue). `pops` going up plays a short landing pop
/// with no bounce; with motion limited the number just changes.
struct CountPill: View {
    var text: String
    var pops: Int
    @Environment(\.limitMotion) private var limitMotion
    @State private var scale: CGFloat = 1
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Ink.dim)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Ink.neutralChip, in: Capsule())
            .scaleEffect(scale)
            .onChange(of: pops) { _, _ in pop() }
    }

    private func pop() {
        guard !limitMotion else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { scale = 1.3 }
        DispatchQueue.main.async { withAnimation(.smooth(duration: 0.3)) { scale = 1 } }
    }
}
