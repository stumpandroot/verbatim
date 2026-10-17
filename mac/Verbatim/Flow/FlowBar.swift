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
    /// False while the panel is off screen; set true just after it's shown, so the Ribbon slides in from the edge.
    @Published var shown = false
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
    /// Display keys by display number. Making one creates a CFUUID, and the pointer checks it several times a
    /// second, so each is made once; cleared when displays change or the Mac wakes.
    private var displayKeys: [UInt32: String] = [:]

    private static let sideSize = CGSize(width: 440, height: 220)
    private static let bottomSize = CGSize(width: 460, height: 170)

    init(dictation: DictationController) {
        self.dictation = dictation
        FlowSettings.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in self?.displayKeys = [:]; self?.rebuild() }.store(in: &bag)
        ws.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in self?.displayKeys = [:]; self?.rebuild() }.store(in: &bag)
        // Track the pointer: decides hover, whether clicks reach the Ribbon, and which display it's on.
        // Event monitors and main-run-loop timers call back on the main thread, so the work runs right there
        // instead of scheduling a Task per mouse event.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in MainActor.assumeIsolated { self?.pointerMoved() }; return e }) { monitors.append(l) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // "Hide for 1 hour" ends on its own.
                if let h = FlowSettings.shared.hiddenUntil, h <= Date() { FlowSettings.shared.hiddenUntil = nil }
                self?.pointerMoved(); self?.followPointer()
            }
        }
        pollTimer?.tolerance = 0.05   // lets macOS batch the wakeups; still about 4 times a second
        // Next turn of the run loop: this runs while SwiftUI is still building the app's state, and sizing a
        // panel's hosting view inside that update aborts in AttributeGraph ("value_set" during update).
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// Shows or hides the Ribbon to match settings and dictation state.
    /// True while the Ribbon is sliding away before its window closes.
    private var hiding = false

    func refresh() {
        let s = FlowSettings.shared
        let busy = model.phase != .idle
        let enabled = dictation?.enabled ?? false
        if enabled && (busy || !s.barHidden) {
            if panel == nil { build() }
            place()
            if let p = panel, !p.isVisible || hiding {
                hiding = false
                // Start tucked into the edge, put the window up, then slide out on the next frame. Without the
                // wait, the slide happens before the window is on screen and all you see is a fade.
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { model.shown = false }
                p.orderFrontRegardless()
                DispatchQueue.main.async { [weak self] in
                    withAnimation(.smooth(duration: 0.4)) { self?.model.shown = true }
                }
            }
        } else if let p = panel, p.isVisible, !hiding {
            menu.close()
            hiding = true
            withAnimation(.smooth(duration: 0.25)) { model.shown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                guard let self, self.hiding else { return }
                self.hiding = false
                self.panel?.orderOut(nil)
            }
        }
        if let d = dictation, !d.accessibilityTrusted { model.hint = "click to set up" }
        else { model.hint = dictation.map { "\($0.hotkey.shortTitle) or click" } ?? "click to dictate" }
        // Secure input (a password field, Terminal) blocks keyed shortcuts the Carbon fallback couldn't take over.
        if let secure = dictation?.secureInputHint { model.hint = secure }
    }

    func setPhase(_ p: FlowBarModel.Phase) {
        if p != .notice { noticeTimer?.invalidate(); model.noticeAction = nil; model.onNoticeAction = nil }
        if p != .prompt { promptTimer?.invalidate(); model.prompt = nil }
        // While busy the Ribbon stays on the display it started on, even if the pointer wanders.
        lockedKey = (p == .idle) ? nil : (lockedKey ?? currentScreen().map { self.key(for: $0) })
        model.phase = p
        if p == .idle { model.warning = ""; model.command = false; model.handsFree = false; model.appLabel = "" }
        if p != .idle { menu.close() }
        refresh()
        pointerMoved()
        if p == .idle { DispatchQueue.main.async { [weak self] in self?.dictation?.showPendingLearn() } }
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
        p.animationBehavior = .none   // the Ribbon animates itself; no system fade
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
        if let k = lockedKey, let s = NSScreen.screens.first(where: { self.key(for: $0) == k }) { return s }
        return screenUnderPointer()
    }

    private func screenUnderPointer() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func key(for screen: NSScreen) -> String {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return screen.localizedName }
        let display = n.uint32Value
        if let k = displayKeys[display] { return k }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return screen.localizedName }
        let k = CFUUIDCreateString(nil, uuid) as String
        displayKeys[display] = k
        return k
    }

    private func followPointer() {
        guard panel?.isVisible == true, !model.dragging, model.phase == .idle, !menu.isOpen else { return }
        guard let screen = currentScreen() else { return }
        if key(for: screen) != screenKey { place() }
    }

    private func position(for screen: NSScreen) -> FlowSettings.BarPosition {
        FlowSettings.shared.positions[key(for: screen)] ?? .init(edge: .bottom, along: 0.5)
    }

    /// Puts the fixed-size panel flush against its edge. The Ribbon inside aligns to that edge.
    private func place() {
        guard let p = panel, !model.dragging, let screen = currentScreen() else { return }
        screenKey = key(for: screen)
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
        // Off screen there's nothing to hit or hover: the same result as below, without reading the pointer.
        guard p.isVisible else {
            if !p.ignoresMouseEvents { p.ignoresMouseEvents = true }
            if model.hover != menu.isOpen { model.hover = menu.isOpen }
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
        if lockedKey != nil { lockedKey = key(for: screen) }
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
        FlowSettings.shared.positions[key(for: screen)] = pos
        model.dragging = false
        place()
        pointerMoved()
    }

    /// Moves the Ribbon to an edge of the display it's on (the welcome tour's "Where should it live?").
    func moveTo(edge: BarEdge) {
        guard let screen = currentScreen() else { return }
        FlowSettings.shared.positions[key(for: screen)] = .init(edge: edge, along: 0.5)
        refresh()
        place()
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
            editActions: { [weak dictation] in dictation?.openSettings(tab: .actions) },
            projects: dictation.projects,
            thoughtPad: { ThoughtPadController.shared.toggle() }
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
