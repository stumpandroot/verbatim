import SwiftUI
import AppKit

// MARK: - Controller

/// The notch's geometry and measured shape, shared by the controller and the view.
@MainActor
final class NotchLayout: ObservableObject {
    @Published var geometry: NotchGeometry?
    /// Where the black shape really is, in the panel's coordinates (top-left origin), as SwiftUI measured it.
    @Published var contentFrame: CGRect = .zero
}

/// Settings › Dictation › Show dictation in › Notch: dictation grows sideways out of the notch, the app your words
/// go to on the left of the camera and your voice on the right, in a black shape that continues the hardware
/// (rounded bottom corners, small flares into the menu bar). On a display without a notch it hangs from the top
/// center as a pill, or the Ribbon shows instead (Settings › Dictation › On displays without a notch).
///
/// A non-activating panel above the menu bar (`SurfacePanel.aboveMenuBar`), of a fixed size, flush with the top of the screen and centered on
/// the camera; only the black shape takes clicks, and it's kept out of screenshots and screen sharing. It reads the
/// same `FlowBarModel` phases as the Ribbon; `FlowBarController` decides when it shows and on which display.
@MainActor
final class NotchController {
    let model: FlowBarModel
    let layout = NotchLayout()
    private unowned let controller: FlowBarController
    private var panel: SurfacePanel?

    init(model: FlowBarModel, controller: FlowBarController) {
        self.model = model
        self.controller = controller
    }

    var panelWindow: NSWindow? { panel }

    /// Measures a display's notch (or its lack of one).
    static func geometry(for screen: NSScreen) -> NotchGeometry {
        NotchGeometry.measure(frame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                              leftAreaWidth: screen.auxiliaryTopLeftArea?.width, rightAreaWidth: screen.auxiliaryTopRightArea?.width,
                              menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Puts the panel at the top center of `screen` (flush with the top edge, centered on the camera).
    func show(on screen: NSScreen) {
        let g = Self.geometry(for: screen)
        if layout.geometry != g { layout.geometry = g }
        if panel == nil { build() }
        guard let p = panel else { return }
        let f = g.panelFrame
        if p.frame != f { p.setFrame(f, display: true) }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        p.ignoresMouseEvents = true
    }

    /// After sleep or a display change: a fresh panel, measured again on the next show.
    func rebuild() {
        panel?.orderOut(nil); panel?.close(); panel = nil
        layout.geometry = nil
        layout.contentFrame = .zero
    }

    private func build() {
        let p = SurfacePanel.make(size: CGSize(width: 600, height: NotchGeometry.panelHeight), level: SurfacePanel.aboveMenuBar)
        let live = controller.liveMeter ?? LiveMeter()
        let words = controller.liveWords ?? LiveTranscriber()
        let host = FlowHostingView(rootView: NotchView(model: model, layout: layout, controller: controller, live: live, words: words))
        let c = controller
        host.onRightClick = { [weak c] in c?.openMenu() }
        host.onMouseMoved = { [weak c] in c?.pointerMoved() }
        host.sizingOptions = []   // the panel keeps its fixed size, whatever the content asks for
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: p.frame.size)
        p.contentView = host
        panel = p
    }

    /// The black shape on screen (the flares aren't part of it), or nil while nothing's drawn.
    var shapeScreenRect: NSRect? {
        guard let p = panel, p.isVisible else { return nil }
        let c = layout.contentFrame
        guard c.width > 1, c.height > 1 else { return nil }
        let f = p.frame
        return NSRect(x: f.minX + c.minX, y: f.maxY - c.maxY, width: c.width, height: c.height)
    }

    /// The area that takes clicks: the shape, with a margin (wider around a prompt's or a notice's controls), and
    /// 2 pt past the top edge so the pointer pushed against the top of the screen still counts. Idle, only with
    /// Click the notch to dictate on.
    var hitRect: NSRect? {
        if model.phase == .idle && !NotchClick.isOn() { return nil }
        guard var r = shapeScreenRect else { return nil }
        let generous = model.phase == .prompt || (model.phase == .notice && model.noticeAction != nil)
        let m: CGFloat = generous ? 10 : 4
        r = r.insetBy(dx: -m, dy: -m)
        r.size.height += 2
        return r
    }

    /// Whether the pointer is over the shape; the panel takes clicks only then.
    func updatePointer(at location: CGPoint) -> Bool {
        guard let p = panel else { return false }
        guard p.isVisible else {
            if !p.ignoresMouseEvents { p.ignoresMouseEvents = true }
            return false
        }
        let inside = hitRect?.contains(location) ?? false
        if p.ignoresMouseEvents == inside { p.ignoresMouseEvents = !inside }
        return inside
    }
}

// MARK: - Shape

/// The notch's outline: a flat top flush with the screen edge, small concave flares where it meets the menu bar,
/// straight sides, and rounded bottom corners. The rect is the body; the flares reach `flare` past each side.
struct NotchShape: Shape {
    var radius: CGFloat
    var flare: CGFloat = NotchGeometry.flare

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = max(0, min(radius, rect.width / 2, rect.height))
        let f = min(flare, rect.height)
        let l = rect.minX, rt = rect.maxX, top = rect.minY, bottom = rect.maxY
        p.move(to: CGPoint(x: l - f, y: top))
        p.addLine(to: CGPoint(x: rt + f, y: top))
        // Right flare: a quarter circle curving from the menu bar down into the side.
        p.addArc(tangent1End: CGPoint(x: rt, y: top), tangent2End: CGPoint(x: rt, y: top + f), radius: f)
        p.addLine(to: CGPoint(x: rt, y: bottom - r))
        p.addArc(tangent1End: CGPoint(x: rt, y: bottom), tangent2End: CGPoint(x: rt - r, y: bottom), radius: r)
        p.addLine(to: CGPoint(x: l + r, y: bottom))
        p.addArc(tangent1End: CGPoint(x: l, y: bottom), tangent2End: CGPoint(x: l, y: bottom - r), radius: r)
        p.addLine(to: CGPoint(x: l, y: top + f))
        p.addArc(tangent1End: CGPoint(x: l, y: top), tangent2End: CGPoint(x: l - f, y: top), radius: f)
        p.closeSubpath()
        return p
    }
}

// MARK: - View

/// The notch style's states, from the same phases as the Ribbon: idle (pointing at it shows the bars mark and your
/// hotkey), listening (the app on the left, persimmon voice bars and a mono timer on the right), listening and
/// hovered (your words, Cancel with Esc, and Stop), cleaning up, pasted, an error, a notice, and a prompt.
/// The width is fixed per state, so only the contents change; the second row drops below the camera.
struct NotchView: View {
    @ObservedObject var model: FlowBarModel
    @ObservedObject var layout: NotchLayout
    let controller: FlowBarController
    @ObservedObject var live: LiveMeter
    @ObservedObject var words: LiveTranscriber
    @AppStorage(LiveWordsSetting.key) private var showWords = true
    @AppStorage(NotchClick.key) private var clickToDictate = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Settings › General › Limit animation, read directly: the panel is outside the window that injects it.
    @AppStorage(MotionPreference.key) private var motionLimited = false
    private var still: Bool { systemReduceMotion || motionLimited }

    private static let space = "notch-panel"
    private static let black = Ink.notchBlack

    private enum Look: Equatable { case hidden, rest, peek, listening, open, working, pasted, error, notice, prompt }

    private var look: Look {
        guard let g = layout.geometry else { return .hidden }
        switch model.phase {
        case .idle:
            // The pill is gone at rest: there's no hardware shape to shrink back into.
            if !g.hasNotch || !clickToDictate { return .hidden }
            return model.hover ? .peek : .rest
        case .listening: return model.hover ? .open : .listening
        case .working: return .working
        case .prompt: return model.prompt == nil ? .rest : .prompt
        case .notice:
            switch model.noticeTone {
            case .pasted: return .pasted
            case .error: return .error
            case .info: return .notice
            }
        }
    }

    private func width(_ g: NotchGeometry) -> CGFloat {
        switch look {
        case .hidden: return 0
        case .rest: return g.width(.rest)
        case .peek: return g.width(.peek)
        case .listening: return g.width(model.alert != nil || !model.warning.isEmpty ? .wide : .active)
        case .working, .pasted: return g.width(.active)
        case .open, .error, .notice: return g.width(.wide)
        case .prompt: return g.width(.prompt)
        }
    }

    private var morph: Animation { still ? .easeOut(duration: 0.12) : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24) }
    private var stateKey: String {
        "\(look)-\(model.alert?.title ?? "")-\(model.warning)-\(model.notice.count)-\(model.noticeAction ?? "")-\(liveWordsShown)"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let g = layout.geometry, look != .hidden {
                shape(g)
                    .offset(x: g.centerX - g.panelFrame.midX)
                    .transition(.opacity)
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(SurfaceFrameKey.self) { f in if layout.contentFrame != f { layout.contentFrame = f } }
        .animation(morph, value: stateKey)
    }

    private func shape(_ g: NotchGeometry) -> some View {
        let w = width(g)
        return VStack(spacing: 0) {
            firstRow(g, width: w)
            secondRow(g)
        }
        .frame(width: w, alignment: .top)
        .background(GeometryReader { p in
            NotchShape(radius: g.radius(height: p.size.height)).fill(Self.black)
        })
        .contentShape(Rectangle())
        .surfaceFrame(in: Self.space)
        // Clicking the shape: idle starts, listening stops and pastes, a notice runs its action. Its own controls
        // (Stop, Cancel, a prompt's answers) take their clicks first.
        .tapArea { controller.clicked() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction { controller.clicked() }
        .uiTarget("notch-shape")
    }

    // MARK: Rows

    /// The row beside the camera: two wings around the housing, or one continuous row on the pill.
    @ViewBuilder private func firstRow(_ g: NotchGeometry, width: CGFloat) -> some View {
        if g.hasNotch {
            HStack(spacing: 0) {
                HStack(spacing: 7) { leftWing }
                    .padding(.horizontal, 14)
                    .frame(width: g.wingWidth(width), alignment: .leading)
                Color.clear.frame(width: min(g.cameraWidth, width))
                HStack(spacing: 7) { rightWing }
                    .padding(.horizontal, 14)
                    .frame(width: g.wingWidth(width), alignment: .trailing)
            }
            .frame(width: width, height: g.rowHeight)
            .clipped()
        } else if look == .pasted {
            pastedLine.frame(width: width, height: g.rowHeight)
        } else {
            HStack(spacing: 7) {
                leftWing
                Spacer(minLength: 8)
                rightWing
            }
            .padding(.horizontal, 14)
            .frame(width: width, height: g.rowHeight)
        }
    }

    @ViewBuilder private var leftWing: some View {
        switch look {
        case .hidden, .rest:
            EmptyView()
        case .peek, .notice, .prompt:
            BarsMark(color: Ink.persimmonFixed).frame(width: 14, height: 15)
        case .listening, .open, .working, .error:
            appIcon
            Text(model.targetName.isEmpty ? "Dictation" : model.targetName)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.onBlack).lineLimit(1)
        case .pasted:
            appIcon
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch look {
        case .hidden, .rest, .notice, .error:
            EmptyView()
        case .peek:
            DarkKeycap(text: controller.hotkeyKeycap)
        case .listening, .open:
            VoiceBars(levels: VoiceBars.live(live.levels, count: 9), height: 16)
            Text(SurfaceClock.text(live.elapsed)).font(SurfaceFont.mono(12)).foregroundStyle(Ink.onBlackDim).monospacedDigit()
        case .working:
            SurfaceSpinner(size: 13, still: still)
            Text(workingText).font(.system(size: 12.5)).foregroundStyle(Ink.onBlack).lineLimit(1)
        case .pasted:
            if let n = pastedWords {
                Text(n == 1 ? "1 word" : "\(n) words").font(SurfaceFont.mono(12)).foregroundStyle(Ink.onBlackDim)
            }
        case .prompt:
            if let p = model.prompt { closeRing(p) }
        }
    }

    @ViewBuilder private func secondRow(_ g: NotchGeometry) -> some View {
        switch look {
        case .listening:
            if let a = model.alert { problem(title: a.title, detail: a.detail, strong: a.strong, action: nil) }
            else if !model.warning.isEmpty {
                Text(model.warning).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.dangerOnBlack)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
            }
        case .open:
            VStack(alignment: .leading, spacing: 0) {
                if let a = model.alert { problem(title: a.title, detail: a.detail, strong: a.strong, action: nil) }
                if liveWordsShown { wordsLine.padding(.horizontal, 16).padding(.top, 2) }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    RibbonControl(id: "notch-cancel", label: "Cancel", help: "Cancel (Esc)", action: controller.cancel) { pressed in
                        HStack(spacing: 7) {
                            Text("Cancel").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.onBlack)
                            DarkKeycap(text: "esc", color: Ink.onBlackDim)
                        }
                        .padding(.leading, 12).padding(.trailing, 8).frame(height: 28)
                        .overlay(Capsule().strokeBorder(Ink.onBlackHair, lineWidth: 1))
                        .opacity(pressed ? 0.8 : 1)
                    }
                    RibbonControl(id: "notch-stop", label: "Stop", help: "Stop and paste", action: controller.stop) { pressed in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Ink.inkFixed).frame(width: 9, height: 9)
                            Text("Stop").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                        }
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Ink.persimmonFixed, in: Capsule())
                        .opacity(pressed ? 0.85 : 1)
                    }
                }
                .padding(.leading, 16).padding(.trailing, 12).padding(.top, 10).padding(.bottom, 12)
            }
            .transition(.opacity)
        case .pasted:
            if g.hasNotch { pastedLine.frame(height: 30).padding(.bottom, 4) }
        case .error:
            let t = NoticeText.split(model.notice)
            problem(title: t.title, detail: t.detail, strong: true, action: model.noticeAction)
        case .notice:
            HStack(alignment: .center, spacing: 10) {
                Text(model.notice).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.onBlack)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let a = model.noticeAction { actionPill(a) }
            }
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 12)
        case .prompt:
            if let p = model.prompt { promptRow(p) }
        case .hidden, .rest, .peek, .working:
            EmptyView()
        }
    }

    // MARK: Pieces

    private var appIcon: some View {
        AppIconView(bundleID: model.targetBundleID)
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var pastedLine: some View {
        HStack(spacing: 8) {
            BrandGlyph(art: .webCheck, color: Ink.persimmonFixed, minLineWidth: 1.6).frame(width: 14, height: 14)
            Text(model.notice).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.onBlack).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var pastedWords: Int? {
        if case .pasted(let n) = model.noticeTone { return n }
        return nil
    }

    /// "Cleaning up…", or "Writing…" at Literal, or "Editing…" for an edit by voice.
    private var workingText: String {
        if model.command { return "Editing…" }
        return FlowSettings.shared.cleanup == .literal ? "Writing…" : "Cleaning up…"
    }

    /// An error, a muted mic, or nothing heard: the attention icon and a word in the light persimmon, never color
    /// alone, with what to do under it and an optional action.
    private func problem(title: String, detail: String, strong: Bool, action: String?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    BrandGlyph(art: .webAttention, color: Ink.dangerOnBlack, minLineWidth: 1.4).frame(width: 16, height: 16)
                    Text(title).font(.system(size: 13.5, weight: strong ? .semibold : .medium)).foregroundStyle(Ink.dangerOnBlack).lineLimit(2)
                }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Ink.onBlackDim).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action { actionPill(action) }
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 12)
    }

    private func actionPill(_ title: String) -> some View {
        RibbonControl(id: "notch-notice-action", label: title, action: controller.performNoticeAction) { pressed in
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.onBlack)
                .padding(.horizontal, 12).frame(height: 28)
                .overlay(Capsule().strokeBorder(Ink.onBlackHair, lineWidth: 1))
                .opacity(pressed ? 0.8 : 1)
        }
    }

    /// Live words show while hovering when the setting is on and a session is starting or running.
    private var liveWordsShown: Bool { look == .open && showWords && words.state != .off }

    /// Your words so far in the serif, two lines at most, the end showing: earlier words dim, the latest bright.
    /// Hidden from VoiceOver, like the Ribbon's: announcing every word would drown everything else out.
    private var wordsLine: some View {
        let d = words.words.tail(140).display
        let older = Text(d.settled).foregroundColor(Ink.onBlackDim)
        let recent = Text((d.settled.isEmpty ? "" : " ") + ([d.volatile, d.newest].filter { !$0.isEmpty }.joined(separator: " "))).foregroundColor(Ink.onBlack)
        return Group {
            if words.words.isEmpty {
                Text("Listening…").italic().foregroundColor(Ink.onBlackDim)
            } else {
                older + recent
            }
        }
        .font(SurfaceFont.serif(16))
        .lineSpacing(2)
        .lineLimit(2)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    /// The prompt's close button with its countdown ring (it holds while the pointer is over the notch).
    private func closeRing(_ p: FlowBarModel.Prompt) -> some View {
        RibbonControl(id: "notch-prompt-close", label: "Close", help: "Close (keeps it in Dictations)", action: controller.dismissPrompt) { _ in
            NotchCountdownRing(countdown: model.promptCountdown)
                .frame(width: 22, height: 22)
                .padding(3)
        }
    }

    private func promptRow(_ p: FlowBarModel.Prompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.onBlack)
            (Text(p.body) + Text(p.quote.map { "“\($0)”" } ?? "").foregroundColor(Ink.onBlack) + Text(p.after))
                .font(.system(size: 13)).foregroundStyle(Ink.onBlackDim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                RibbonControl(id: "notch-prompt-secondary", label: p.secondary, action: { controller.answer(primary: false) }) { pressed in
                    Text(p.secondary).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.onBlack)
                        .padding(.horizontal, 14).frame(height: 28)
                        .overlay(Capsule().strokeBorder(Ink.onBlackHair, lineWidth: 1))
                        .opacity(pressed ? 0.8 : 1)
                }
                if let primary = p.primary {
                    RibbonControl(id: "notch-prompt-primary", label: primary, action: { controller.answer(primary: true) }) { pressed in
                        Text(primary).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                            .padding(.horizontal, 14).frame(height: 28)
                            .background(Ink.persimmonFixed, in: Capsule())
                            .opacity(pressed ? 0.85 : 1)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(p.title)
    }

    private var accessibilityLabel: String {
        switch model.phase {
        case .idle: return "Verbose dictation: " + DictationTiming.hintLine(model.hint)
        case .listening:
            let base = "Listening for \(model.targetName). Click to stop and paste."
            if let a = model.alert { return "\(base) \(a.title). \(a.detail)." }
            return base
        case .working: return workingText
        case .notice: return model.notice
        case .prompt: return model.prompt?.title ?? ""
        }
    }
}

/// The prompt's countdown on black: a ring that runs down and holds while the pointer is over the notch.
private struct NotchCountdownRing: View {
    let countdown: FlowBarModel.Countdown
    @State private var progress: CGFloat = 1
    var body: some View {
        ZStack {
            Circle().stroke(Ink.onBlackHair, lineWidth: 2)
            Circle().trim(from: 0, to: progress).stroke(Ink.onBlackDim, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.onBlack)
        }
        .onAppear { run(countdown) }
        .onChange(of: countdown) { _, c in run(c) }
    }
    private func run(_ c: FlowBarModel.Countdown) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { progress = c.fraction }
        guard c.running, c.seconds > 0 else { return }
        withAnimation(.linear(duration: c.seconds)) { progress = 0 }
    }
}
