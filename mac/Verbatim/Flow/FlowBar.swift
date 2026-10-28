import AppKit
import SwiftUI
import Combine

/// What dictation shows on screen: the Ribbon and the notch both draw these phases.
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

    struct ListeningAlert: Equatable {
        var title: String
        var detail: String
        /// Certain (the device says it's muted) rather than a guess from silence.
        var strong: Bool
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
    /// A problem to fix while listening ("Your mic is muted"), shown in the listening tab until it clears.
    @Published var alert: ListeningAlert? = nil
    @Published var appLabel = ""      // "MAIL" while writing
    /// The app the words go to, for the notch's left wing (its name and icon).
    @Published var targetName = ""
    @Published var targetBundleID: String? = nil
    /// How a notice reads in the notch. The Ribbon shows every notice the same way.
    enum NoticeTone: Equatable {
        case info
        /// "Pasted into Notes", with the word count.
        case pasted(words: Int)
        /// A problem to act on: the attention icon and the light persimmon; it stays until you act or press Esc.
        case error
    }
    @Published var noticeTone: NoticeTone = .info
    @Published var edge: BarEdge = .bottom
    /// Where the drawn content really is, measured by SwiftUI in the panel's own coordinates (top-left origin).
    /// Clicks inside it reach the Ribbon; clicks outside pass through to the apps behind.
    @Published var contentFrame: CGRect = .zero
    /// The prompt's countdown ring: the share of time left, the seconds it takes to run out from there, and
    /// whether it's running (it holds while the pointer is over the card).
    struct Countdown: Equatable {
        var fraction: CGFloat = 1
        var seconds: Double = 0
        var running = false
    }
    @Published var promptCountdown = Countdown()
}

/// Dictation on screen. It keeps the phases, notices, prompts, and their timers, and draws them in the style chosen
/// in Settings › Ribbon and notch › Show dictation in: the Ribbon (this file and FlowBarView) or the notch
/// (`NotchController`). The Ribbon:
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
    /// Time left on the notice's countdown, and when it last started running (nil while paused by hover).
    private var noticeRemaining: TimeInterval = 0
    private var noticeRunningSince: Date?
    private var promptTimer: Timer?
    /// Time left on the prompt's countdown, and when it last started running (nil while held by hover).
    private var promptRemaining: TimeInterval = 0
    private var promptRunningSince: Date?
    /// Leaving the Ribbon restarts a held notice or prompt with at least this long to go, so it never vanishes
    /// just as you reach for it again.
    static let resumeSeconds: TimeInterval = 4
    private var pollTimer: Timer?
    private var monitors: [Any] = []
    private var dragOffset: CGPoint = .zero
    /// Display keys by display number. Making one creates a CFUUID, and the pointer checks it several times a
    /// second, so each is made once; cleared when displays change or the Mac wakes.
    private var displayKeys: [UInt32: String] = [:]
    /// The notch style, made the first time it's needed.
    private lazy var notch = NotchController(model: model, controller: self)
    /// What shows on the current display (the notch style shows as a pill, or the Ribbon, where there's no notch).
    private(set) var shown: DictationSurface.Shown = .ribbon
    /// An error notice the notch holds until you act or press Esc.
    private var sticky = false

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
        // A new state or a card that grew moves the clickable area while the pointer may be standing still:
        // check again at once, after the change lands (these fire before the value is set).
        model.$contentFrame.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.pointerMoved() } }.store(in: &bag)
        model.$phase.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.pointerMoved() } }.store(in: &bag)
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
        let screen = currentScreen()
        let was = shown
        shown = screen.map(shownSurface(on:)) ?? .ribbon
        if shown != was { menu.close() }
        if let screen { screenKey = key(for: screen) }
        // "Hide for 1 hour" hides every style; Show the Ribbon only the Ribbon.
        let hiddenForAnHour = s.hiddenUntil.map { $0 > Date() } ?? false
        switch shown {
        case .ribbon:
            notch.hide()
        case .notch, .pill:
            if enabled, (busy || !hiddenForAnHour), let screen { notch.show(on: screen) } else { notch.hide() }
        }
        if shown == .ribbon && enabled && (busy || !s.barHidden) {
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
                    withAnimation(.smooth(duration: 0.3)) { self?.model.shown = true }
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
        pointerMoved()
        if let d = dictation, !d.accessibilityTrusted { model.hint = "click to set up" }
        else { model.hint = dictation.map { "\($0.hotkey.shortTitle) or click" } ?? "click to dictate" }
        // Secure input (a password field, Terminal) blocks keyed shortcuts the Carbon fallback couldn't take over.
        if let secure = dictation?.secureInputHint { model.hint = secure }
    }

    func setPhase(_ p: FlowBarModel.Phase) {
        if p != .notice { noticeTimer?.invalidate(); model.noticeAction = nil; model.onNoticeAction = nil; sticky = false; model.noticeTone = .info }
        if p != .prompt { promptTimer?.invalidate(); promptTimer = nil; promptRunningSince = nil; model.prompt = nil }
        // While busy the Ribbon stays on the display it started on, even if the pointer wanders.
        lockedKey = (p == .idle) ? nil : (lockedKey ?? currentScreen().map { self.key(for: $0) })
        model.phase = p
        if p == .idle { model.warning = ""; model.alert = nil; model.command = false; model.handsFree = false; model.appLabel = "" }
        if p != .idle { menu.close() }
        refresh()
        pointerMoved()
        if p == .idle { DispatchQueue.main.async { [weak self] in self?.dictation?.showPendingLearn(); self?.dictation?.prepareLiveWords() } }
    }

    /// A short message in the Ribbon ("Learned “Lititz”", "Copied. Click a text field…"), with an optional action.
    ///
    /// Long enough to read: at least 6 s, plus 0.05 s per character, up to 12 s (never shorter than `seconds`).
    /// A notice with an action stays 12 s. The countdown pauses while the pointer is over the Ribbon, and a
    /// click dismisses it (running the action, if it has one). `exact` keeps a short confirmation ("Cancelled")
    /// to `seconds`.
    ///
    /// `tone` changes only how the notch draws it: an error there stays until you act or
    /// press Esc. The Ribbon times every notice the same way.
    func flash(_ text: String, action: String? = nil, seconds: Double = 3.5, exact: Bool = false, tone: FlowBarModel.NoticeTone = .info, perform: (() -> Void)? = nil) {
        setPhase(.notice)
        model.notice = text
        model.noticeAction = action
        model.onNoticeAction = perform
        model.noticeTone = tone
        noticeRemaining = Self.noticeSeconds(text, hasAction: action != nil, requested: seconds, exact: exact)
        noticeTimer?.invalidate(); noticeTimer = nil
        noticeRunningSince = nil
        sticky = tone == .error && shown != .ribbon
        if sticky { return }
        if !model.hover { runNoticeCountdown() }
    }

    /// Esc on an error the notch is holding. True when it closed one.
    func dismissStickyNotice() -> Bool {
        guard model.phase == .notice, sticky else { return false }
        setPhase(.idle)
        return true
    }

    /// A dictation landed. The Ribbon just closes; the notch says where the words went for
    /// 1.6 seconds ("Pasted into Notes", with the word count).
    func confirmPaste(app: String, words: Int) {
        guard shown != .ribbon else { setPhase(.idle); return }
        flash("Pasted into \(app)", seconds: 1.6, exact: true, tone: .pasted(words: words))
    }

    static func noticeSeconds(_ text: String, hasAction: Bool, requested: Double, exact: Bool = false) -> TimeInterval {
        if hasAction { return 12 }
        if exact { return requested }
        return max(requested, min(12, 6 + 0.05 * Double(text.count)))
    }

    private func runNoticeCountdown() {
        noticeTimer?.invalidate()
        noticeRunningSince = Date()
        // Main-run-loop timer: runs right here, so a hover that paused it can't race a queued task.
        noticeTimer = Timer.scheduledTimer(withTimeInterval: noticeRemaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .notice, self.noticeRunningSince != nil else { return }
                self.setPhase(.idle)
            }
        }
    }

    /// Hovering the Ribbon holds a notice or a prompt; leaving starts the rest of its countdown (at least
    /// `resumeSeconds` more).
    private func hoverChanged(_ hovering: Bool) {
        switch model.phase {
        case .notice:
            if sticky { return }
            if hovering {
                guard let since = noticeRunningSince else { return }
                noticeRemaining -= Date().timeIntervalSince(since)
                noticeRunningSince = nil
                noticeTimer?.invalidate(); noticeTimer = nil
            } else if noticeRunningSince == nil {
                noticeRemaining = max(noticeRemaining, Self.resumeSeconds)
                runNoticeCountdown()
            }
        case .prompt:
            if hovering {
                guard let since = promptRunningSince else { return }
                promptRemaining = max(0, promptRemaining - Date().timeIntervalSince(since))
                promptRunningSince = nil
                promptTimer?.invalidate(); promptTimer = nil
                model.promptCountdown = .init(fraction: promptFraction, seconds: promptRemaining, running: false)
            } else if promptRunningSince == nil, model.prompt != nil {
                promptRemaining = max(promptRemaining, Self.resumeSeconds)
                runPromptCountdown()
            }
        default: break
        }
    }

    /// A question with two choices ("Started by mistake?"). It answers itself with `onTimeout` after `seconds`;
    /// the countdown holds while the pointer is over the card.
    func ask(_ prompt: FlowBarModel.Prompt) {
        setPhase(.prompt)
        model.prompt = prompt
        promptTimer?.invalidate(); promptTimer = nil
        promptRemaining = prompt.seconds
        promptRunningSince = nil
        model.promptCountdown = .init(fraction: 1, seconds: prompt.seconds, running: false)
        if model.hover { return }   // already over the Ribbon: it starts when the pointer leaves
        runPromptCountdown()
    }

    /// The share of the prompt's time that's left, for the ring.
    private var promptFraction: CGFloat {
        guard let total = model.prompt?.seconds, total > 0 else { return 0 }
        return CGFloat(min(1, max(0, promptRemaining / total)))
    }

    private func runPromptCountdown() {
        promptTimer?.invalidate()
        promptRunningSince = Date()
        model.promptCountdown = .init(fraction: promptFraction, seconds: promptRemaining, running: true)
        promptTimer = Timer.scheduledTimer(withTimeInterval: promptRemaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .prompt, self.promptRunningSince != nil else { return }
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

    /// The action on a notice ("Open", "Settings"): runs it and clears the notice.
    func performNoticeAction() {
        guard model.phase == .notice else { return }
        let action = model.onNoticeAction
        setPhase(.idle)
        action?()
    }

    /// The panel dictation draws in right now (the Ribbon's or the notch's), for the UI self-test.
    var panelWindow: NSWindow? {
        switch shown {
        case .ribbon: return panel
        case .notch, .pill: return notch.panelWindow
        }
    }

    /// Which style shows on a display.
    private func shownSurface(on screen: NSScreen) -> DictationSurface.Shown {
        let chosen = DictationSurface.stored()
        guard chosen == .notch else { return .ribbon }
        return DictationSurface.shown(chosen: .notch, hasNotch: NotchController.geometry(for: screen).hasNotch, fallback: NotchFallback.stored())
    }

    /// The words preview, for the notch.
    var liveWords: LiveTranscriber? { dictation?.liveWords }
    /// The hotkey as a keycap reads ("right ⌥"), for the notch.
    var hotkeyKeycap: String { dictation?.hotkey.keycap ?? "right ⌥" }

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
        let host = FlowHostingView(rootView: FlowBarView(model: model, controller: self, live: dictation?.liveMeter ?? LiveMeter(), words: dictation?.liveWords ?? LiveTranscriber()))
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
        notch.rebuild()
        model.dragging = false
        if visible || shown != .ribbon { refresh() }
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

    /// At idle, dictation follows the pointer to another display (and may change style there: the notch style is a
    /// pill or the Ribbon on a display without a notch).
    private func followPointer() {
        guard !model.dragging, model.phase == .idle, !menu.isOpen else { return }
        guard let screen = currentScreen(), key(for: screen) != screenKey else { return }
        if shown == .ribbon, DictationSurface.stored() == .ribbon {
            if panel?.isVisible == true { place() }
        } else {
            refresh()
        }
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

    /// The Ribbon's drawn area on screen, in screen coordinates: the frame SwiftUI measured for what it really
    /// drew (the tab, or the prompt card with its edge padding), so the clickable area follows the card wherever
    /// it's laid out.
    private func ribbonRect() -> NSRect? {
        guard let p = panel, p.isVisible else { return nil }
        let f = p.frame
        let c = model.contentFrame
        // Closed, the sliver is thin; give the pointer a fair target.
        let minW: CGFloat = model.edge == .bottom ? 64 : 14, minH: CGFloat = model.edge == .bottom ? 14 : 64
        guard c.width > 0, c.height > 0 else {
            // Not measured yet: centered on the edge, as the layout aligns it.
            switch model.edge {
            case .left: return NSRect(x: f.minX, y: f.midY - minH / 2, width: minW, height: minH)
            case .right: return NSRect(x: f.maxX - minW, y: f.midY - minH / 2, width: minW, height: minH)
            case .bottom: return NSRect(x: f.midX - minW / 2, y: f.minY, width: minW, height: minH)
            }
        }
        // Panel coordinates (top-left origin) to screen coordinates (bottom-left origin).
        var r = NSRect(x: f.minX + c.minX, y: f.maxY - c.maxY, width: c.width, height: c.height)
        if r.width < minW {
            switch model.edge {
            case .left: break
            case .right: r.origin.x = r.maxX - minW
            case .bottom: r.origin.x = r.midX - minW / 2
            }
            r.size.width = minW
        }
        if r.height < minH {
            if model.edge != .bottom { r.origin.y = r.midY - minH / 2 }
            r.size.height = minH
        }
        return r
    }

    /// The area that takes clicks right now, with its margin (the self-test logs it).
    var hitRect: NSRect? {
        switch shown {
        case .notch, .pill: return notch.hitRect
        case .ribbon: break
        }
        // A prompt or a notice with an action holds controls near its edges: a wider margin, so a click that
        // lands just off a button still reaches the card instead of the app behind.
        let generous = model.phase == .prompt || (model.phase == .notice && model.noticeAction != nil)
        let m: CGFloat = generous ? 10 : 4
        return ribbonRect()?.insetBy(dx: -m, dy: -m)
    }

    func pointerMoved() { updatePointer(at: NSEvent.mouseLocation) }

    /// Decides whether the panel takes clicks (only over the drawn Ribbon) and whether the Ribbon is hovered,
    /// for the pointer at `location` on screen.
    func updatePointer(at location: CGPoint) {
        // `ignoresMouseEvents` is set only when it differs, as the Ribbon does below: this runs on every mouse move
        // anywhere on screen, and each set is a window-server call.
        switch shown {
        case .notch, .pill:
            if let p = panel, !p.ignoresMouseEvents { p.ignoresMouseEvents = true }
            setHover(notch.updatePointer(at: location) || menu.isOpen)
            return
        case .ribbon:
            break
        }
        guard let p = panel else { return }
        if model.dragging {
            // A drag whose end never arrived (the view was rebuilt mid-drag) must not leave the panel catching clicks.
            if NSEvent.pressedMouseButtons & 1 == 0 { dragEnded() } else { p.ignoresMouseEvents = false }
            return
        }
        // Off screen there's nothing to hit or hover: the same result as below, without reading the pointer.
        guard p.isVisible else {
            if !p.ignoresMouseEvents { p.ignoresMouseEvents = true }
            setHover(menu.isOpen)
            return
        }
        let inside = hitRect?.contains(location) ?? false
        if p.ignoresMouseEvents == inside { p.ignoresMouseEvents = !inside }
        setHover(inside || menu.isOpen)
    }

    private func setHover(_ hover: Bool) {
        let h = holdHover ?? hover
        if model.hover != h { model.hover = h; hoverChanged(h) }
    }

    /// The UI self-test holds hover on or off for its screenshots (the pointer isn't over the surface on the runner).
    var holdHover: Bool? = nil {
        didSet { if let h = holdHover { setHover(h) } }
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
        case .notice: performNoticeAction()
        case .working, .prompt: break
        default: dictation?.barClicked()
        }
    }
    func stop() { dictation?.barClicked() }
    func cancel() { dictation?.cancel() }

    func openMenu() {
        guard Date().timeIntervalSince(menu.closedAt) > 0.35 else { return }   // the right-click that closed it
        let anchor: NSRect?, edge: BarEdge
        switch shown {
        case .ribbon: anchor = ribbonRect(); edge = model.edge
        // From the notch the menu opens below and to the right, like a menu bar menu.
        case .notch, .pill: anchor = notch.shapeScreenRect; edge = .left
        }
        guard model.phase == .idle || model.phase == .notice, let rect = anchor, let dictation, let screen = currentScreen() else { return }
        if model.phase == .notice { setPhase(.idle) }
        menu.open(next: rect, edge: edge, screen: screen, actions: .init(
            hide: { FlowSettings.shared.hiddenUntil = Date().addingTimeInterval(3600) },
            settings: { [weak dictation] in dictation?.openSettings() },
            pasteLast: { [weak dictation] in dictation?.pasteLast() },
            copyLast: { [weak dictation] in dictation?.copyLast() },
            editByVoice: { [weak dictation] in dictation?.startFromBar(command: true) },
            run: { [weak dictation] a in dictation?.apply(a) },
            editActions: { [weak dictation] in dictation?.openTemplates(text: true) },
            projects: dictation.projects,
            newThought: { ThoughtCapture.shared.toggle() }
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
