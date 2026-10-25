import SwiftUI
import AppKit

// MARK: - Controller

/// The floating button's measured frames and where its extras go, shared by the controller and the view.
@MainActor
final class FloatingLayout: ObservableObject {
    /// Everything drawn (the button's hit area plus any card beside it), in the panel's coordinates (top-left origin).
    @Published var contentFrame: CGRect = .zero
    /// Just the button's hit area, in the panel's coordinates.
    @Published var buttonFrame: CGRect = .zero
    /// Words, controls, and cards go on the side with more room: left of a button in the right half of the screen.
    @Published var extrasLeading = true
    @Published var dragging = false
}

/// Settings › Dictation › Show dictation in › Floating button: a button you drop anywhere, in four looks (Ink disc,
/// Bars pill, Quiet dot, Labeled pill) and three sizes, with rest, listening, and writing states. Click it to start,
/// click again to stop and paste (the Ribbon's click); right-click it for the Ribbon's menu; drag it anywhere.
///
/// A non-activating panel at the Ribbon's level, of a fixed size, centered on the button: the button never moves while
/// it changes state, and only what's drawn takes clicks (never less than 28 pt). Its spot is saved per display as
/// fractions of the screen and clamped back on after a display change; Snap to the screen edge slides it to the
/// nearest edge after a drag.
@MainActor
final class FloatingButtonController {
    let model: FlowBarModel
    let layout = FloatingLayout()
    private unowned let controller: FlowBarController
    private var panel: SurfacePanel?
    private var dragOffset: CGPoint = .zero
    private var screenKey = ""

    /// Room for a prompt card (360 pt) beside a large button on either side.
    static let panelSize = CGSize(width: 860, height: 320)

    init(model: FlowBarModel, controller: FlowBarController) {
        self.model = model
        self.controller = controller
    }

    var panelWindow: NSWindow? { panel }
    var dragging: Bool { layout.dragging }

    private var spots: [String: ButtonSpot] {
        get {
            guard let data = UserDefaults.standard.data(forKey: FloatingButtonKeys.positions) else { return [:] }
            return (try? JSONDecoder().decode([String: ButtonSpot].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: FloatingButtonKeys.positions) }
    }

    private var restHit: CGSize {
        FloatingGeometry.hitSize(FloatingGeometry.restSize(look: FloatingLook.stored(), size: FloatingSize.stored()))
    }

    /// Puts the button at its spot on `screen` (clamped onto it).
    func show(on screen: NSScreen) {
        if panel == nil { build() }
        guard let p = panel, !layout.dragging else { return }
        let key = controller.displayKey(for: screen)
        let f = screen.visibleFrame
        let center = FloatingGeometry.center(for: spots[key], in: f, size: restHit)
        place(center: center, on: screen)
        screenKey = key
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() {
        guard let p = panel, p.isVisible, !layout.dragging else { return }
        p.orderOut(nil)
        p.ignoresMouseEvents = true
    }

    func rebuild() {
        layout.dragging = false
        panel?.orderOut(nil); panel?.close(); panel = nil
        layout.contentFrame = .zero
        layout.buttonFrame = .zero
    }

    private func place(center: CGPoint, on screen: NSScreen) {
        guard let p = panel else { return }
        let s = Self.panelSize
        let frame = NSRect(x: (center.x - s.width / 2).rounded(), y: (center.y - s.height / 2).rounded(), width: s.width, height: s.height)
        if p.frame != frame { p.setFrame(frame, display: true) }
        let leading = center.x > screen.visibleFrame.midX
        if layout.extrasLeading != leading { layout.extrasLeading = leading }
    }

    private func build() {
        let p = SurfacePanel.make(size: Self.panelSize)
        let live = controller.liveMeter ?? LiveMeter()
        let words = controller.liveWords ?? LiveTranscriber()
        let host = FlowHostingView(rootView: FloatingButtonView(model: model, layout: layout, controller: controller, owner: self, live: live, words: words))
        let c = controller
        host.onRightClick = { [weak c] in c?.openMenu() }
        host.onMouseMoved = { [weak c] in c?.pointerMoved() }
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        p.contentView = host
        panel = p
    }

    private func screenRect(_ c: CGRect) -> NSRect? {
        guard let p = panel, p.isVisible, c.width > 1, c.height > 1 else { return nil }
        let f = p.frame
        return NSRect(x: f.minX + c.minX, y: f.maxY - c.maxY, width: c.width, height: c.height)
    }

    /// The button on screen, for the menu.
    var buttonScreenRect: NSRect? { screenRect(layout.buttonFrame) }

    /// The menu opens away from the nearer side edge, or upward from a button low on the screen.
    var menuEdge: BarEdge {
        guard let r = buttonScreenRect, let screen = panel?.screen else { return .bottom }
        let f = screen.visibleFrame
        if r.midY < f.minY + f.height * 0.3 { return .bottom }
        return r.midX > f.midX ? .right : .left
    }

    var hitRect: NSRect? {
        let generous = model.phase == .prompt || (model.phase == .notice && model.noticeAction != nil)
        let m: CGFloat = generous ? 10 : 4
        return screenRect(layout.contentFrame)?.insetBy(dx: -m, dy: -m)
    }

    func updatePointer(at location: CGPoint) -> Bool {
        guard let p = panel else { return false }
        if layout.dragging {
            // A drag whose end never arrived must not leave the panel catching clicks.
            if NSEvent.pressedMouseButtons & 1 == 0 { dragEnded() } else { p.ignoresMouseEvents = false }
            return true
        }
        guard p.isVisible else {
            if !p.ignoresMouseEvents { p.ignoresMouseEvents = true }
            return false
        }
        let inside = hitRect?.contains(location) ?? false
        if p.ignoresMouseEvents == inside { p.ignoresMouseEvents = !inside }
        return inside
    }

    // MARK: Drag

    func dragChanged() {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        if !layout.dragging {
            layout.dragging = true
            dragOffset = CGPoint(x: m.x - p.frame.minX, y: m.y - p.frame.minY)
        }
        p.setFrameOrigin(CGPoint(x: m.x - dragOffset.x, y: m.y - dragOffset.y))
    }

    func dragEnded() {
        guard layout.dragging, let p = panel else { layout.dragging = false; return }
        layout.dragging = false
        controller.dragFinished()
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? p.screen ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        let dropped = CGPoint(x: p.frame.midX, y: p.frame.midY)
        let snap = UserDefaults.standard.bool(forKey: FloatingButtonKeys.snap)
        let center = snap ? FloatingGeometry.snap(dropped, in: f, size: restHit) : FloatingGeometry.clamp(dropped, in: f, size: restHit)
        let key = controller.displayKey(for: screen)
        var all = spots
        all[key] = FloatingGeometry.spot(for: center, in: f)
        spots = all
        screenKey = key
        if snap && !(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: MotionPreference.key)) {
            // Slides to the edge, like the Ribbon.
            let s = Self.panelSize
            let target = NSRect(x: (center.x - s.width / 2).rounded(), y: (center.y - s.height / 2).rounded(), width: s.width, height: s.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(target, display: true)
            }
            layout.extrasLeading = center.x > f.midX
        } else {
            place(center: center, on: screen)
        }
    }

    func clicked() { controller.clicked() }
}

// MARK: - View

/// The button in its look and size, centered in the panel, with its extras beside it: the timer (Ink disc), your
/// words (Show words as you speak), Stop and Cancel while hovered, a notice, or a prompt.
struct FloatingButtonView: View {
    @ObservedObject var model: FlowBarModel
    @ObservedObject var layout: FloatingLayout
    let controller: FlowBarController
    let owner: FloatingButtonController
    @ObservedObject var live: LiveMeter
    @ObservedObject var words: LiveTranscriber
    @AppStorage(FloatingLook.key) private var lookRaw = FloatingLook.disc.rawValue
    @AppStorage(FloatingSize.key) private var sizeRaw = FloatingSize.medium.rawValue
    @AppStorage(FloatingButtonKeys.mark) private var mark = RibbonMark.bars.rawValue
    @AppStorage(LiveWordsSetting.key) private var showWords = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(MotionPreference.key) private var motionLimited = false
    private var still: Bool { systemReduceMotion || motionLimited }

    private static let space = "floating-button-panel"
    private var look: FloatingLook { FloatingLook(rawValue: lookRaw) ?? .disc }
    private var size: FloatingSize { FloatingSize(rawValue: sizeRaw) ?? .medium }

    private var state: FloatingButtonFace.Phase {
        switch model.phase {
        case .listening: return .listening
        case .working: return .writing
        default: return .rest
        }
    }

    private var morph: Animation { still ? .easeOut(duration: 0.12) : .smooth(duration: 0.24) }

    var body: some View {
        ZStack {
            Color.clear
            FloatingButtonFace(look: look, size: size, phase: state, levels: levels, elapsed: live.elapsed,
                               keycap: controller.hotkeyKeycap, rings: mark == RibbonMark.rings.rawValue, still: still)
                .frame(minWidth: FloatingGeometry.minHit, minHeight: FloatingGeometry.minHit)
                .contentShape(Rectangle())
                .background(GeometryReader { g in
                    Color.clear
                        .preference(key: SurfaceFrameKey.self, value: g.frame(in: .named(Self.space)))
                        .onAppear { layout.buttonFrame = g.frame(in: .named(Self.space)) }
                        .onChange(of: g.frame(in: .named(Self.space))) { _, f in layout.buttonFrame = f }
                })
                // One gesture: a drag moves the button, otherwise it's a click. The extras beside it take their own.
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in owner.dragChanged() }
                    .onEnded { _ in owner.dragEnded() }
                    .exclusively(before: TapGesture().onEnded { owner.clicked() }))
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAction { owner.clicked() }
                .uiTarget("floating-button")
                .overlay(alignment: layout.extrasLeading ? .leading : .trailing) {
                    extras
                        .fixedSize()
                        .alignmentGuide(.leading) { d in layout.extrasLeading ? d[.trailing] + 10 : d[.leading] }
                        .alignmentGuide(.trailing) { d in layout.extrasLeading ? d[.trailing] : d[.leading] - 10 }
                }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(SurfaceFrameKey.self) { f in if layout.contentFrame != f { layout.contentFrame = f } }
        .animation(morph, value: "\(state)-\(model.phase)-\(model.hover)-\(lookRaw)-\(sizeRaw)")
    }

    private var levels: [Double] {
        let n: Int
        switch look {
        case .disc: n = 5
        case .bars: n = state == .listening ? 9 : 5
        case .dot, .label: n = state == .listening ? 7 : 5
        }
        return state == .listening ? VoiceBars.live(live.levels, count: n) : VoiceBars.still(n)
    }

    /// Words, controls, notices, and prompts beside the button, toward the middle of the screen.
    @ViewBuilder private var extras: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: 8) {
                if layout.extrasLeading { listeningExtras.reversed } else { listeningExtras.forward }
            }
            .surfaceFrame(in: Self.space)
        case .notice:
            FloatingNotice(model: model, controller: controller).surfaceFrame(in: Self.space)
        case .prompt:
            if let p = model.prompt {
                PromptCard(prompt: p, controller: controller, countdown: model.promptCountdown, idPrefix: "button")
                    .surfaceFrame(in: Self.space)
            }
        case .idle, .working:
            EmptyView()
        }
    }

    private var listeningExtras: ListeningExtras {
        ListeningExtras(showTimer: look == .disc, elapsed: live.elapsed, words: showWords && words.state != .off ? words : nil,
                        hovered: model.hover, controller: controller)
    }

    private var accessibilityLabel: String {
        switch model.phase {
        case .idle: return "Verbose dictation: " + DictationTiming.hintLine(model.hint)
        case .listening: return "Listening. Click to stop and paste."
        case .working: return "Writing your words"
        case .notice: return model.notice
        case .prompt: return model.prompt?.title ?? ""
        }
    }
}

/// The listening extras in reading order from the button outward: the disc's timer, your words, Cancel, Stop.
private struct ListeningExtras {
    var showTimer: Bool
    var elapsed: TimeInterval
    var words: LiveTranscriber?
    var hovered: Bool
    let controller: FlowBarController

    @ViewBuilder var forward: some View { timer; wordsBubble; controls }
    @ViewBuilder var reversed: some View { controls; wordsBubble; timer }

    @ViewBuilder private var timer: some View {
        if showTimer {
            Text(SurfaceClock.text(elapsed)).font(SurfaceFont.mono(12)).monospacedDigit().foregroundStyle(Ink.paperFixed)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Ink.inkFixed, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.paperFixed.opacity(0.9), lineWidth: 1))
        }
    }

    @ViewBuilder private var wordsBubble: some View {
        if let words {
            FloatingWords(words: words)
        }
    }

    @ViewBuilder private var controls: some View {
        if hovered {
            HStack(spacing: 6) {
                RibbonControl(id: "button-cancel", label: "Cancel", help: "Cancel (Esc)", action: controller.cancel) { pressed in
                    Text("Cancel").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.paperFixed)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Ink.inkFixed, in: Capsule())
                        .overlay(Capsule().strokeBorder(Ink.paperFixed.opacity(0.9), lineWidth: 1))
                        .opacity(pressed ? 0.85 : 1)
                }
                RibbonControl(id: "button-stop", label: "Stop", help: "Stop and paste", action: controller.stop) { pressed in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Ink.inkFixed).frame(width: 9, height: 9)
                        Text("Stop").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Ink.persimmonFixed, in: Capsule())
                    .overlay(Capsule().strokeBorder(Ink.inkFixed, lineWidth: 1.5))
                    .opacity(pressed ? 0.85 : 1)
                }
            }
        }
    }
}

/// Your words beside the button: one serif line in an ink bubble, the end showing. Hidden from VoiceOver.
private struct FloatingWords: View {
    @ObservedObject var words: LiveTranscriber
    var body: some View {
        let d = words.words.tail(60).display
        Group {
            if words.words.isEmpty {
                Text("Listening…").italic().foregroundColor(Ink.paperFixed.opacity(0.62))
            } else {
                Text(d.settled).foregroundColor(Ink.paperFixed.opacity(0.62))
                    + Text((d.settled.isEmpty ? "" : " ") + [d.volatile, d.newest].filter { !$0.isEmpty }.joined(separator: " ")).foregroundColor(Ink.paperFixed)
            }
        }
        .font(SurfaceFont.serif(15))
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: 280, alignment: .trailing)
        .padding(.horizontal, 12).frame(height: 30)
        .background(Ink.inkFixed, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.paperFixed.opacity(0.9), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// A notice beside the button: an ink card with paper type. Pasted gets a check; an error the attention icon and
/// the light persimmon, with a word, never color alone.
private struct FloatingNotice: View {
    @ObservedObject var model: FlowBarModel
    let controller: FlowBarController
    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            switch model.noticeTone {
            case .pasted:
                BrandGlyph(art: .webCheck, color: Ink.persimmonFixed, minLineWidth: 1.6).frame(width: 14, height: 14)
            case .error:
                BrandGlyph(art: .webAttention, color: Ink.accentTextOnInk, minLineWidth: 1.4).frame(width: 16, height: 16)
            case .info:
                BarsMark(color: Ink.persimmonFixed).frame(width: 12, height: 13)
            }
            Text(model.notice).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(model.noticeTone == .error ? Ink.accentTextOnInk : Ink.paperFixed)
                .lineLimit(3).frame(maxWidth: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if let a = model.noticeAction {
                RibbonControl(id: "button-notice-action", label: a, action: controller.performNoticeAction) { pressed in
                    Text(a).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.accentTextOnInk).opacity(pressed ? 0.8 : 1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Ink.inkFixed, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.paperFixed.opacity(0.9), lineWidth: 1))
        .tapArea { controller.clicked() }
    }
}

/// The button itself, in one of four looks and three sizes, at rest, listening, or writing. Ink bodies wear a paper
/// hairline so they read on any wallpaper; persimmon marks your live voice. The labeled pill is butter with grain
/// and ink marks (no persimmon on butter). Also drawn small in Settings' look picker.
struct FloatingButtonFace: View {
    enum Phase { case rest, listening, writing }
    var look: FloatingLook
    var size: FloatingSize
    var phase: Phase
    var levels: [Double]
    var elapsed: TimeInterval
    var keycap: String
    var rings = false
    var still = false

    private var s: CGFloat { size.points }
    private var hairline: Color { Ink.paperFixed.opacity(0.9) }

    var body: some View {
        switch look {
        case .disc: disc
        case .bars: inkPill(height: (s * 30 / 44).rounded(), bars: phase == .listening ? 9 : 5)
        case .dot: if phase == .rest { dot } else { inkPill(height: (s * 26 / 44).rounded(), bars: 7, compactWriting: true) }
        case .label: label
        }
    }

    // Ink disc: the bars mark at rest, live bars (or rings) in a persimmon ring while listening, a spinner writing.
    private var disc: some View {
        ZStack {
            Circle().fill(Ink.inkFixed)
            switch phase {
            case .rest: BarsMark(color: Ink.paperFixed).frame(width: s * 0.41, height: s * 0.43)
            case .listening: voice(height: s * 0.41, barWidth: max(2, s * 0.068), gap: max(2, s * 0.057))
            case .writing: SurfaceSpinner(size: s * 0.41, track: Ink.paperFixed.opacity(0.2), still: still)
            }
        }
        .frame(width: s, height: s)
        .overlay(Circle().strokeBorder(hairline, lineWidth: 1.5).padding(-1.5))
        .overlay { if phase == .listening { Circle().stroke(Ink.persimmonFixed, lineWidth: 2.5).padding(-2.75) } }
        .background(Circle().fill(Ink.inkFixed).offset(x: 3, y: 4))
    }

    // Bars pill (and the quiet dot while it's dictating): five still bars at rest, live bars and the time
    // listening, a spinner and "Writing…" writing.
    private func inkPill(height h: CGFloat, bars: Int, compactWriting: Bool = false) -> some View {
        HStack(spacing: 8) {
            switch phase {
            case .rest:
                VoiceBars(levels: levels, height: h * 0.47, barWidth: 2.5, gap: 2, color: Ink.paperFixed)
            case .listening:
                voice(height: h * 0.53, barWidth: 2.5, gap: 2)
                Text(SurfaceClock.text(elapsed)).font(SurfaceFont.mono(12)).monospacedDigit().foregroundStyle(Ink.paperFixed.opacity(0.75))
            case .writing:
                SurfaceSpinner(size: max(12, h * 0.43), track: Ink.paperFixed.opacity(0.2), still: still)
                if !compactWriting { Text("Writing…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.paperFixed) }
            }
        }
        .padding(.horizontal, (h * 0.4).rounded())
        .frame(height: h)
        .background(Capsule().fill(Ink.inkFixed))
        .overlay(Capsule().strokeBorder(hairline, lineWidth: 1.5).padding(-1.5))
        .background(Capsule().fill(Ink.inkFixed).offset(x: 2, y: 3))
        .fixedSize()
    }

    // Quiet dot: a paper dot with an ink ring and a persimmon center.
    private var dot: some View {
        let d = (s * 16 / 44).rounded()
        return ZStack {
            Circle().fill(Ink.paperFixed)
            Circle().strokeBorder(Ink.inkFixed, lineWidth: 2)
            Circle().fill(Ink.persimmonFixed).frame(width: d * 0.4, height: d * 0.4)
        }
        .frame(width: d, height: d)
    }

    // Labeled pill: butter with grain, ink marks, the word, and the hotkey as a keycap.
    private var label: some View {
        let h = (s * 34 / 44).rounded()
        let font = max(12, min(16, 13.5 * s / 44))
        return HStack(spacing: 9) {
            switch phase {
            case .rest:
                VoiceBars(levels: levels, height: h * 0.41, color: Ink.inkFixed)
                Text("Dictate").font(.system(size: font, weight: .bold)).foregroundStyle(Ink.inkFixed)
                Text(keycap).font(SurfaceFont.mono(12)).foregroundStyle(Ink.inkFixed)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Ink.readerFixed.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.inkFixed, lineWidth: 1))
            case .listening:
                voice(height: h * 0.44, barWidth: 2.5, gap: 2, color: Ink.inkFixed)
                Text("Listening").font(.system(size: font, weight: .bold)).foregroundStyle(Ink.inkFixed)
                Text(SurfaceClock.text(elapsed)).font(SurfaceFont.mono(12)).monospacedDigit().foregroundStyle(Ink.inkFixed).padding(.trailing, 8)
            case .writing:
                SurfaceSpinner(size: 13, color: Ink.inkFixed, track: Ink.inkFixed.opacity(0.2), still: still)
                Text("Writing…").font(.system(size: font, weight: .bold)).foregroundStyle(Ink.inkFixed).padding(.trailing, 8)
            }
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(height: h)
        .background(Capsule().fill(Ink.butterFixed))
        .overlay(GrainOverlay().clipShape(Capsule()))
        .overlay(Capsule().strokeBorder(Ink.inkFixed, lineWidth: 1.5))
        .background(Capsule().fill(Ink.inkFixed).offset(x: 2, y: 3))
        .fixedSize()
    }

    /// Your voice: the bars, or the colophon's rings when chosen.
    @ViewBuilder private func voice(height: CGFloat, barWidth: CGFloat, gap: CGFloat, color: Color = Ink.persimmonFixed) -> some View {
        if rings {
            RibbonRings(levels: levels.count >= 3 ? Array(levels.suffix(3)) : [0.5, 0.5, 0.5], size: height, color: color)
        } else {
            VoiceBars(levels: levels, height: height, barWidth: barWidth, gap: gap, color: color)
        }
    }
}
