import AppKit
import SwiftUI
import Combine

/// What the floating Ribbon shows.
@MainActor
final class FlowBarModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, working, notice, prompt }

    struct Prompt {
        var title: String
        var body: String
        var quote: String?
        var after: String = ""
        var primary: String?
        var secondary: String
        var seconds: Double
        var onPrimary: () -> Void = {}
        var onSecondary: () -> Void = {}
        var onTimeout: () -> Void = {}
    }

    @Published var phase: Phase = .idle
    @Published var hover = false
    @Published var handsFree = false
    @Published var command = false
    @Published var dragging = false
    @Published var notice = ""
    @Published var noticeAction: String? = nil
    var onNoticeAction: (() -> Void)?
    @Published var prompt: Prompt? = nil
    @Published var hint = ""          // "hold ⌥ or click"
    @Published var warning = ""       // "AirPods mic: lower quality"
    @Published var appLabel = ""      // "MAIL" while writing
    @Published var edge: BarEdge = .bottom
    /// The drawn content's real size, measured by SwiftUI; clicks inside it reach the Ribbon, clicks outside pass through.
    @Published var contentSize: CGSize = .zero
}

/// The always-on floating Ribbon for dictation, in Verbatim's ink, persimmon, and paper.
///
/// - Closed, only a sliver of the ink pill shows at the screen edge. On hover it slides out and the ribbon
///   (the logo's three bars) appears. Listening, the bars follow your voice. Writing, a bar sweeps and the
///   app's name shows.
/// - A non-activating panel of a fixed size: the window never moves or resizes while it animates (resizing
///   the window on every state change is what made the first version flicker). Only the drawn Ribbon takes
///   clicks; the rest of the panel lets clicks through to the apps behind it.
/// - It sits flush with the bottom, left, or right edge of the display under your pointer, remembers its spot
///   per display, and stays clear of the Dock and menu bar. It's rebuilt after sleep and display changes.
@MainActor
final class FlowBarController {
    let model = FlowBarModel()
    private var panel: FlowPanel?
    private let menu = FlowMenuController()
    private var bag: Set<AnyCancellable> = []
    private weak var dictation: DictationController?
    private var screenKey = ""
    private var lockedKey: String?
    private var lastDragEnd = Date.distantPast
    private var noticeTimer: Timer?
    private var promptTimer: Timer?
    private var pollTimer: Timer?
    private var monitors: [Any] = []
    private var dragOffset: CGPoint = .zero

    private static let sideSize = CGSize(width: 440, height: 220)
    private static let bottomSize = CGSize(width: 460, height: 170)

    init(dictation: DictationController) {
        self.dictation = dictation
        FlowSettings.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in self?.rebuild() }.store(in: &bag)
        ws.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in self?.rebuild() }.store(in: &bag)
        // Track the pointer: decides hover, whether clicks reach the Ribbon, and which display it's on.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in Task { @MainActor in self?.pointerMoved() } }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in Task { @MainActor in self?.pointerMoved() }; return e }) { monitors.append(l) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // "Hide for 1 hour" ends on its own.
                if let h = FlowSettings.shared.hiddenUntil, h <= Date() { FlowSettings.shared.hiddenUntil = nil }
                self?.pointerMoved(); self?.followPointer()
            }
        }
        // Next turn of the run loop: this runs while SwiftUI is still building the app's state, and sizing a
        // panel's hosting view inside that update aborts in AttributeGraph ("value_set" during update).
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// Shows or hides the Ribbon to match settings and dictation state.
    func refresh() {
        let s = FlowSettings.shared
        let busy = model.phase != .idle
        let enabled = dictation?.enabled ?? false
        if enabled && (busy || !s.barHidden) {
            if panel == nil { build() }
            place()
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
            menu.close()
        }
        model.hint = dictation.map { "\($0.hotkey.shortTitle) or click" } ?? "click to dictate"
    }

    func setPhase(_ p: FlowBarModel.Phase) {
        if p != .notice { noticeTimer?.invalidate(); model.noticeAction = nil; model.onNoticeAction = nil }
        if p != .prompt { promptTimer?.invalidate(); model.prompt = nil }
        // While busy the Ribbon stays on the display it started on, even if the pointer wanders.
        lockedKey = (p == .idle) ? nil : (lockedKey ?? currentScreen().map { Self.key(for: $0) })
        model.phase = p
        if p == .idle { model.warning = ""; model.command = false; model.handsFree = false; model.appLabel = "" }
        if p != .idle { menu.close() }
        refresh()
        pointerMoved()
    }

    /// A short message in the Ribbon ("Learned “Lititz”", "Copied. Click a text field…"), with an optional action.
    func flash(_ text: String, action: String? = nil, seconds: Double = 3.5, perform: (() -> Void)? = nil) {
        setPhase(.notice)
        model.notice = text
        model.noticeAction = action
        model.onNoticeAction = perform
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in if self?.model.phase == .notice { self?.setPhase(.idle) } }
        }
    }

    /// A question with two choices ("Started by mistake?"). It answers itself with `onTimeout` after `seconds`.
    func ask(_ prompt: FlowBarModel.Prompt) {
        setPhase(.prompt)
        model.prompt = prompt
        promptTimer?.invalidate()
        promptTimer = Timer.scheduledTimer(withTimeInterval: prompt.seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.phase == .prompt else { return }
                let p = self.model.prompt
                self.setPhase(.idle)
                p?.onTimeout()
            }
        }
    }

    /// The X on a prompt: same as letting it time out (the dictation stays in Dictations).
    func dismissPrompt() {
        guard let p = model.prompt else { return }
        setPhase(.idle)
        p.onTimeout()
    }

    func answer(primary: Bool) {
        guard let p = model.prompt else { return }
        setPhase(.idle)
        if primary { p.onPrimary() } else { p.onSecondary() }
    }

    // MARK: Panel

    private func build() {
        let p = FlowPanel(contentRect: NSRect(origin: .zero, size: Self.sideSize), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        let host = FlowHostingView(rootView: FlowBarView(model: model, controller: self, live: dictation?.liveMeter ?? LiveMeter()))
        host.onRightClick = { [weak self] in self?.openMenu() }
        host.onMouseMoved = { [weak self] in self?.pointerMoved() }
        host.sizingOptions = []   // the panel keeps its fixed size, whatever the content asks for
        host.frame = NSRect(origin: .zero, size: Self.sideSize)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
    }

    private func rebuild() {
        let visible = panel?.isVisible ?? false
        menu.close()
        panel?.orderOut(nil); panel?.close(); panel = nil
        model.dragging = false
        if visible { refresh() }
    }

    // MARK: Position

    /// The display the Ribbon belongs on: the one it's locked to while busy, else the one under the pointer.
    /// Nil only for a moment while displays are reconfiguring.
    private func currentScreen() -> NSScreen? {
        if let k = lockedKey, let s = NSScreen.screens.first(where: { Self.key(for: $0) == k }) { return s }
        return screenUnderPointer()
    }

    private func screenUnderPointer() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func key(for screen: NSScreen) -> String {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return screen.localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func followPointer() {
        guard panel?.isVisible == true, !model.dragging, model.phase == .idle, !menu.isOpen else { return }
        guard let screen = currentScreen() else { return }
        if Self.key(for: screen) != screenKey { place() }
    }

    private func position(for screen: NSScreen) -> FlowSettings.BarPosition {
        FlowSettings.shared.positions[Self.key(for: screen)] ?? .init(edge: .bottom, along: 0.5)
    }

    /// Puts the fixed-size panel flush against its edge. The Ribbon inside aligns to that edge.
    private func place() {
        guard let p = panel, !model.dragging, let screen = currentScreen() else { return }
        screenKey = Self.key(for: screen)
        let pos = position(for: screen)
        if model.edge != pos.edge { model.edge = pos.edge }
        let f = screen.visibleFrame
        let size = pos.edge == .bottom ? Self.bottomSize : Self.sideSize
        var origin: CGPoint
        switch pos.edge {
        case .bottom:
            let x = f.minX + f.width * pos.along - size.width / 2
            origin = CGPoint(x: min(max(x, f.minX), f.maxX - size.width), y: f.minY)
        case .left:
            let y = f.minY + f.height * pos.along - size.height / 2
            origin = CGPoint(x: f.minX, y: min(max(y, f.minY), f.maxY - size.height))
        case .right:
            let y = f.minY + f.height * pos.along - size.height / 2
            origin = CGPoint(x: f.maxX - size.width, y: min(max(y, f.minY), f.maxY - size.height))
        }
        let frame = NSRect(origin: origin, size: size)
        if p.frame != frame { p.setFrame(frame, display: true) }
    }

    /// The Ribbon's drawn area on screen, in screen coordinates.
    private func ribbonRect() -> NSRect? {
        guard let p = panel, p.isVisible else { return nil }
        var s = model.contentSize
        // Closed, the sliver is thin; give the pointer a fair target.
        s.width = max(s.width, model.edge == .bottom ? 64 : 14)
        s.height = max(s.height, model.edge == .bottom ? 14 : 64)
        let f = p.frame
        switch model.edge {
        case .left: return NSRect(x: f.minX, y: f.midY - s.height / 2, width: s.width, height: s.height)
        case .right: return NSRect(x: f.maxX - s.width, y: f.midY - s.height / 2, width: s.width, height: s.height)
        case .bottom: return NSRect(x: f.midX - s.width / 2, y: f.minY, width: s.width, height: s.height)
        }
    }

    private func pointerMoved() {
        guard let p = panel else { return }
        if model.dragging {
            // A drag whose end never arrived (the view was rebuilt mid-drag) must not leave the panel catching clicks.
            if NSEvent.pressedMouseButtons & 1 == 0 { dragEnded() } else { p.ignoresMouseEvents = false }
            return
        }
        let inside = ribbonRect()?.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) ?? false
        if p.ignoresMouseEvents == inside { p.ignoresMouseEvents = !inside }
        let hover = inside || menu.isOpen
        if model.hover != hover { model.hover = hover }
    }

    // MARK: Drag to an edge

    func dragChanged() {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        if !model.dragging {
            menu.close()
            model.dragging = true
            dragOffset = CGPoint(x: m.x - p.frame.minX, y: m.y - p.frame.minY)
        }
        p.setFrameOrigin(CGPoint(x: m.x - dragOffset.x, y: m.y - dragOffset.y))
    }

    func dragEnded() {
        guard model.dragging else { return }
        lastDragEnd = Date()
        guard let screen = screenUnderPointer() else { model.dragging = false; return }
        if lockedKey != nil { lockedKey = Self.key(for: screen) }
        let f = screen.visibleFrame
        let m = NSEvent.mouseLocation
        let dBottom = m.y - f.minY, dLeft = m.x - f.minX, dRight = f.maxX - m.x
        let pos: FlowSettings.BarPosition
        if dBottom <= min(dLeft, dRight) {
            pos = .init(edge: .bottom, along: Double(min(max((m.x - f.minX) / f.width, 0.05), 0.95)))
        } else if dLeft <= dRight {
            pos = .init(edge: .left, along: Double(min(max((m.y - f.minY) / f.height, 0.08), 0.92)))
        } else {
            pos = .init(edge: .right, along: Double(min(max((m.y - f.minY) / f.height, 0.08), 0.92)))
        }
        FlowSettings.shared.positions[Self.key(for: screen)] = pos
        model.dragging = false
        place()
        pointerMoved()
    }

    // MARK: Actions

    var liveMeter: LiveMeter? { dictation?.liveMeter }
    func clicked() {
        guard !model.dragging, Date().timeIntervalSince(lastDragEnd) > 0.3 else { return }
        if menu.isOpen { menu.close(); return }
        if Date().timeIntervalSince(menu.closedAt) < 0.35 { return }
        switch model.phase {
        case .notice: model.onNoticeAction?(); setPhase(.idle)
        case .working, .prompt: break
        default: dictation?.barClicked()
        }
    }
    func stop() { dictation?.barClicked() }
    func cancel() { dictation?.cancel() }

    func openMenu() {
        guard Date().timeIntervalSince(menu.closedAt) > 0.35 else { return }   // the right-click that closed it
        guard model.phase == .idle || model.phase == .notice, let rect = ribbonRect(), let dictation, let screen = currentScreen() else { return }
        if model.phase == .notice { setPhase(.idle) }
        menu.open(next: rect, edge: model.edge, screen: screen, actions: .init(
            hide: { FlowSettings.shared.hiddenUntil = Date().addingTimeInterval(3600) },
            settings: { [weak dictation] in dictation?.openSettings() },
            history: { [weak dictation] in dictation?.openHistory() },
            pasteLast: { [weak dictation] in dictation?.pasteLast() },
            editByVoice: { [weak dictation] in dictation?.startFromBar(command: true) },
            run: { [weak dictation] a in dictation?.apply(a) },
            editActions: { [weak dictation] in dictation?.openSettings(tab: .actions) }
        )) { [weak self] in self?.pointerMoved() }
    }
}

/// Clicks land on the first try even though the panel never becomes key, and right-click opens the menu.
final class FlowHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: (() -> Void)?
    var onMouseMoved: (() -> Void)?
    private var tracking: NSTrackingArea?
    // Hover updates as soon as the pointer moves over the panel, not on the next poll.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); onMouseMoved?() }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onMouseMoved?() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onMouseMoved?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onRightClick?(); return }
        super.mouseDown(with: event)
    }
}

final class FlowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The Ribbon

private enum RibbonInk {
    static let ink = Color(hex: 0x26352E)
    static let inkRaised = Color(hex: 0x34453C)
    static let track = Color(hex: 0x3B4A42)
    static let persimmon = Color(hex: 0xFA6B47)
    static let butter = Color(hex: 0xF4C76B)
    static let paper = Color(hex: 0xF5F0E6)
    static let muted = Color(hex: 0xC9C2B3)
}

struct FlowBarView: View {
    @ObservedObject var model: FlowBarModel
    let controller: FlowBarController
    @ObservedObject var live: LiveMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var alignment: Alignment {
        switch model.edge { case .left: return .leading; case .right: return .trailing; case .bottom: return .bottom }
    }

    @State private var shown = false

    /// Every state shares one ink shape. Between states the shape morphs to its new size while the contents
    /// cross-fade, so the Ribbon never jumps. Reduce Motion turns the morph into a quick fade.
    private var morph: Animation? { reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.3) }

    private var closed: Bool { model.phase == .idle && !(model.hover || model.dragging) }

    /// Changes to any of these animate the shape.
    private var stateKey: String {
        "\(model.phase)-\(closed)-\(model.dragging)-\(model.handsFree)-\(model.warning.isEmpty)-\(model.command)-\(model.edge)-\(model.noticeAction ?? "")-\(model.notice.count)"
    }

    private var screenEdge: Edge { switch model.edge { case .left: return .leading; case .right: return .trailing; case .bottom: return .bottom } }

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            Group {
                if model.phase == .prompt, let p = model.prompt {
                    PromptCard(prompt: p, controller: controller)
                        .padding(model.edge == .bottom ? .bottom : (model.edge == .left ? .leading : .trailing), 10)
                        .transition(.asymmetric(insertion: .move(edge: screenEdge).combined(with: .opacity), removal: .opacity))
                } else {
                    tabbed.transition(.opacity)
                }
            }
            .background(GeometryReader { g in Color.clear.preference(key: RibbonSizeKey.self, value: g.size) })
            .contentShape(Rectangle())
            // One gesture: a drag moves the Ribbon, otherwise it's a click. Buttons inside (Stop, Cancel,
            // Discard, Paste anyway) take their own clicks and don't also trigger the Ribbon's.
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in controller.dragChanged() }
                .onEnded { _ in controller.dragEnded() }
                .exclusively(before: TapGesture().onEnded { controller.clicked() }))
            .accessibilityElement(children: model.phase == .listening || model.phase == .prompt ? .contain : .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            // Slides in from the edge when it first appears (and after sleep or a display change).
            .offset(x: shown ? 0 : (model.edge == .left ? -14 : model.edge == .right ? 14 : 0), y: shown || model.edge != .bottom ? 0 : 14)
            .opacity(shown ? 1 : 0)
        }
        .onPreferenceChange(RibbonSizeKey.self) { s in if model.contentSize != s { model.contentSize = s } }
        .animation(morph, value: stateKey)
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.4)) { shown = true } }
    }

    /// The tab's rounded side faces into the screen; the edge side is square, flush with the screen edge.
    private func tab(_ r: CGFloat) -> UnevenRoundedRectangle {
        switch model.edge {
        case .left: return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .right: return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        case .bottom: return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: r, style: .continuous)
        }
    }

    /// The one ink shape, sized by whatever it holds; closed, it's the thin sliver at the edge.
    private var tabbed: some View {
        let r: CGFloat = closed ? 4 : 15
        return inner
            .padding(.vertical, closed ? 0 : (model.phase == .notice ? 10 : 11))
            .padding(.horizontal, closed ? 0 : 12)
            .frame(width: closed ? (model.edge == .bottom ? 50 : 6) : nil, height: closed ? (model.edge == .bottom ? 6 : 50) : nil)
            .background(tab(r).fill(RibbonInk.ink))
            .overlay(tab(r).strokeBorder(RibbonInk.persimmon.opacity(model.command && model.phase == .listening ? 0.9 : 0), lineWidth: 1.5))
            .clipShape(tab(r))
    }

    /// What's inside the shape for each state. Each fades in and out as the shape morphs.
    @ViewBuilder private var inner: some View {
        switch model.phase {
        case .idle where closed:
            Color.clear.frame(width: 0, height: 0)
        case .idle:
            edgeRow(spacing: 9) {
                RibbonBars(edge: model.edge, levels: [0.8, 0.55, 0.95], thickness: 5, length: 18)
            } rest: {
                VStack(alignment: model.edge == .right ? .trailing : .leading, spacing: 1) {
                    Text(model.dragging ? "Drop at an edge" : "Dictate").font(.system(size: 12, weight: .medium)).foregroundStyle(RibbonInk.paper)
                    if !model.dragging { Text(model.hint).font(.system(size: 11, design: .monospaced)).foregroundStyle(RibbonInk.muted) }
                }
                .fixedSize()
            }
            .transition(.opacity)
        case .listening:
            VStack(spacing: 4) {
                edgeRow(spacing: 10) {
                    RibbonBars(edge: model.edge, levels: liveLevels, thickness: 6, length: 46)
                } rest: {
                    VStack(spacing: 3) {
                        Button(action: controller.stop) {
                            ZStack { Circle().fill(RibbonInk.persimmon); RoundedRectangle(cornerRadius: 1.5).fill(RibbonInk.paper).frame(width: 7, height: 7) }
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain).help("Stop and paste")
                        Text(elapsed).font(.system(size: 11, design: .monospaced)).foregroundStyle(RibbonInk.muted).monospacedDigit()
                    }
                    if model.handsFree {
                        Button(action: controller.cancel) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(RibbonInk.muted).frame(width: 18, height: 18) }
                            .buttonStyle(.plain).help("Cancel (Esc)")
                    }
                }
                if !model.warning.isEmpty {
                    Text(model.warning).font(.system(size: 10.5, weight: .medium)).foregroundStyle(RibbonInk.butter).lineLimit(1).fixedSize()
                }
            }
            .transition(.opacity)
        case .working:
            edgeRow(spacing: 9) {
                SweepBar(edge: model.edge, reduceMotion: reduceMotion)
            } rest: {
                Text(model.appLabel.isEmpty ? (model.command ? "EDITING" : "WRITING") : model.appLabel)
                    .font(.system(size: 11, design: .monospaced)).tracking(0.6).foregroundStyle(RibbonInk.paper).fixedSize()
            }
            .transition(.opacity)
        case .notice:
            edgeRow(spacing: 10) {
                RibbonBars(edge: model.edge, levels: [0.7, 0.5, 0.85], thickness: 3.5, length: 12)
            } rest: {
                Text(model.notice).font(.system(size: 12, weight: .medium)).foregroundStyle(RibbonInk.paper).lineLimit(2).frame(maxWidth: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if let a = model.noticeAction { Text(a).font(.system(size: 12, weight: .semibold)).foregroundStyle(RibbonInk.butter).fixedSize() }
            }
            .transition(.opacity)
        case .prompt:
            EmptyView()
        }
    }

    /// Lays out the bars against the screen edge and the rest beside them, toward the middle of the screen.
    @ViewBuilder private func edgeRow<A: View, B: View>(spacing: CGFloat, @ViewBuilder bars: () -> A, @ViewBuilder rest: () -> B) -> some View {
        if model.edge == .right {
            HStack(spacing: spacing) { rest(); bars() }
        } else {
            HStack(spacing: spacing) { bars(); rest() }
        }
    }

    /// Three bars from your real mic level: the loudest recent moment, the average, and a beat behind.
    private var liveLevels: [Double] {
        let l = live.levels.map(Double.init)
        guard l.count >= 8 else { return [0.2, 0.2, 0.2] }
        let last3 = l.suffix(3), last8 = l.suffix(8)
        return [last3.max() ?? 0, last8.reduce(0, +) / Double(last8.count), l[l.count - 5]].map { min(1, max(0.14, $0)) }
    }

    private var elapsed: String {
        let s = Int(live.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var accessibilityLabel: String {
        switch model.phase {
        case .idle: return "Verbatim dictation: " + model.hint
        case .listening: return model.handsFree ? "Listening. Click to stop and paste." : "Listening"
        case .working: return "Writing your words"
        case .notice: return model.notice
        case .prompt: return model.prompt?.title ?? ""
        }
    }
}

private struct RibbonSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The logo's three bars. On the sides they run horizontally from the edge; at the bottom they stand up.
struct RibbonBars: View {
    var edge: BarEdge
    var levels: [Double]
    var thickness: CGFloat
    var length: CGFloat
    var color: Color = Color(hex: 0xFA6B47)

    var body: some View {
        if edge == .bottom {
            HStack(alignment: .bottom, spacing: thickness * 0.65) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(color).frame(width: thickness, height: max(thickness, length * levels[i]))
                }
            }
            .frame(height: length, alignment: .bottom)
            .animation(.linear(duration: 0.08), value: levels)
        } else {
            VStack(alignment: edge == .right ? .trailing : .leading, spacing: thickness * 0.65) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(color).frame(width: max(thickness, length * levels[i]), height: thickness)
                }
            }
            .frame(width: length, alignment: edge == .right ? .trailing : .leading)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}

/// While writing: a persimmon segment sweeping along a dark track.
struct SweepBar: View {
    var edge: BarEdge
    var reduceMotion: Bool
    @State private var forward = false
    var body: some View {
        let vertical = edge == .bottom
        ZStack(alignment: vertical ? .top : .leading) {
            Capsule().fill(Color(hex: 0x3B4A42))
            Capsule().fill(Color(hex: 0xFA6B47))
                .frame(width: vertical ? 6 : 14, height: vertical ? 10 : 6)
                .offset(x: vertical ? 0 : (forward ? 24 : 0), y: vertical ? (forward ? 18 : 0) : 0)
        }
        .frame(width: vertical ? 6 : 38, height: vertical ? 28 : 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { forward = true }
        }
    }
}

/// "Started by mistake?" and other two-choice questions, with a countdown ring on the close button.
struct PromptCard: View {
    let prompt: FlowBarModel.Prompt
    let controller: FlowBarController
    @State private var progress: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                RibbonBars(edge: .left, levels: [0.8, 0.55, 0.95], thickness: 3.5, length: 12, color: RibbonInk.butter)
                Text(prompt.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(RibbonInk.paper)
                Spacer(minLength: 12)
                Button { controller.dismissPrompt() } label: {
                    ZStack {
                        Circle().stroke(RibbonInk.track, lineWidth: 2)
                        Circle().trim(from: 0, to: progress).stroke(RibbonInk.muted, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(RibbonInk.paper)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).help("Close (keeps it in Dictations)")
            }
            (Text(prompt.body) + Text(prompt.quote.map { "“\($0)”" } ?? "").foregroundColor(RibbonInk.paper) + Text(prompt.after))
                .font(.system(size: 13)).foregroundStyle(RibbonInk.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(prompt.secondary) { controller.answer(primary: false) }
                    .buttonStyle(PromptButton(filled: false))
                if let p = prompt.primary {
                    Button(p) { controller.answer(primary: true) }.buttonStyle(PromptButton(filled: true))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 360)
        .background(RibbonInk.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { withAnimation(.linear(duration: prompt.seconds)) { progress = 0 } }
    }
}

private struct PromptButton: ButtonStyle {
    var filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: filled ? .semibold : .regular))
            .foregroundStyle(filled ? RibbonInk.ink : RibbonInk.paper)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(filled ? RibbonInk.paper : RibbonInk.inkRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
