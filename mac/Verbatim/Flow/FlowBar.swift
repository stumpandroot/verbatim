import AppKit
import SwiftUI
import Combine

/// What the floating button shows.
@MainActor
final class FlowBarModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, working, notice }
    @Published var phase: Phase = .idle
    @Published var hover = false
    @Published var handsFree = false
    @Published var command = false
    @Published var dragging = false
    @Published var notice = ""
    @Published var noticeAction: String? = nil
    var onNoticeAction: (() -> Void)?
    @Published var hint = ""          // "hold ⌥ or click"
    @Published var warning = ""       // "AirPods mic: lower quality"
    @Published var edge: BarEdge = .bottom

    var size: CGSize {
        switch phase {
        case .idle: return hover || dragging ? CGSize(width: 196, height: 30) : CGSize(width: 46, height: 12)
        case .listening: return CGSize(width: handsFree ? 214 : 176, height: warning.isEmpty ? 34 : 50)
        case .working: return CGSize(width: 132, height: 34)
        case .notice: return CGSize(width: min(380, max(150, CGFloat(notice.count) * 6.6 + (noticeAction == nil ? 40 : 100))), height: 34)
        }
    }
}

/// The always-on floating button for dictation (like Wispr Flow's Flow Bar), in Verbatim's ink and persimmon.
///
/// A non-activating panel: clicking it never takes focus from the app you're typing in. It sits at the
/// bottom, left, or right edge of the display under your pointer, remembers where you put it on each
/// display, and keeps clear of the Dock and menu bar (it uses the screen's visible frame). It's rebuilt after
/// sleep and display changes, because a long-lived panel can stop drawing while still reporting visible.
@MainActor
final class FlowBarController {
    let model = FlowBarModel()
    private var panel: FlowPanel?
    private var bag: Set<AnyCancellable> = []
    private weak var dictation: DictationController?
    private var screenKey = ""
    private var noticeTimer: Timer?
    private var followTimer: Timer?
    private var dragOffset: CGPoint = .zero

    init(dictation: DictationController) {
        self.dictation = dictation
        model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.layout(animated: true) } }.store(in: &bag)
        FlowSettings.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in self?.rebuild() }.store(in: &bag)
        ws.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in self?.rebuild() }.store(in: &bag)
        ws.publisher(for: NSWorkspace.activeSpaceDidChangeNotification).sink { [weak self] _ in self?.layout(animated: false) }.store(in: &bag)
        // Follow the display under the pointer, like the Dock does.
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in Task { @MainActor in self?.followPointer() } }
        refresh()
    }

    /// Shows or hides the button to match settings and dictation state.
    func refresh() {
        let s = FlowSettings.shared
        let busy = model.phase != .idle
        let enabled = dictation?.enabled ?? false
        let wanted = enabled && (busy || !s.barHidden)
        if wanted {
            if panel == nil { build() }
            layout(animated: false)
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
        model.hint = dictation.map { "Click, or " + $0.hotkey.shortTitle } ?? "Click to dictate"
    }

    func setPhase(_ p: FlowBarModel.Phase) {
        if p != .notice { noticeTimer?.invalidate(); model.noticeAction = nil; model.onNoticeAction = nil }
        model.phase = p
        if p == .idle { model.warning = "" ; model.command = false }
        refresh()
    }

    /// A short message in the button ("Learned “Lititz”", "Didn't catch that"), with an optional action.
    func flash(_ text: String, action: String? = nil, seconds: Double = 3.5, perform: (() -> Void)? = nil) {
        model.notice = text
        model.noticeAction = action
        model.onNoticeAction = perform
        model.phase = .notice
        refresh()
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in if self?.model.phase == .notice { self?.setPhase(.idle) } }
        }
    }

    // MARK: Panel

    private func build() {
        let p = FlowPanel(contentRect: NSRect(x: 0, y: 0, width: 46, height: 12), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.acceptsMouseMovedEvents = true
        p.isReleasedWhenClosed = false
        let host = FirstMouseHostingView(rootView: FlowBarView(model: model, controller: self))
        host.frame = p.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
    }

    private func rebuild() {
        let visible = panel?.isVisible ?? false
        panel?.orderOut(nil); panel?.close(); panel = nil
        if visible { refresh() }
    }

    // MARK: Position

    private func currentScreen() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func key(for screen: NSScreen) -> String {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return screen.localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func followPointer() {
        guard panel?.isVisible == true, !model.dragging else { return }
        let k = Self.key(for: currentScreen())
        if k != screenKey { layout(animated: false) }
    }

    private func layout(animated: Bool) {
        guard let p = panel, !model.dragging else { return }
        let screen = currentScreen()
        screenKey = Self.key(for: screen)
        let pos = FlowSettings.shared.positions[screenKey] ?? .init(edge: .bottom, along: 0.5)
        if model.edge != pos.edge { model.edge = pos.edge }
        let size = model.size
        let f = screen.visibleFrame
        let inset: CGFloat = 8
        var origin: CGPoint
        switch pos.edge {
        case .bottom:
            let x = f.minX + f.width * pos.along - size.width / 2
            origin = CGPoint(x: min(max(x, f.minX + inset), f.maxX - size.width - inset), y: f.minY + inset)
        case .left:
            let y = f.minY + f.height * pos.along - size.height / 2
            origin = CGPoint(x: f.minX + inset, y: min(max(y, f.minY + inset), f.maxY - size.height - inset))
        case .right:
            let y = f.minY + f.height * pos.along - size.height / 2
            origin = CGPoint(x: f.maxX - size.width - inset, y: min(max(y, f.minY + inset), f.maxY - size.height - inset))
        }
        let frame = NSRect(origin: origin, size: size)
        if p.frame == frame { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(frame, display: true)
            }
        } else {
            p.setFrame(frame, display: true)
        }
    }

    // MARK: Drag to an edge

    func dragChanged() {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        if !model.dragging {
            model.dragging = true
            dragOffset = CGPoint(x: m.x - p.frame.minX, y: m.y - p.frame.minY)
        }
        p.setFrameOrigin(CGPoint(x: m.x - dragOffset.x, y: m.y - dragOffset.y))
    }

    func dragEnded() {
        guard let p = panel else { model.dragging = false; return }
        let screen = currentScreen()
        let f = screen.visibleFrame
        let c = CGPoint(x: p.frame.midX, y: p.frame.midY)
        let dBottom = c.y - f.minY, dLeft = c.x - f.minX, dRight = f.maxX - c.x
        let pos: FlowSettings.BarPosition
        if dBottom <= min(dLeft, dRight) || dBottom < 120 {
            pos = .init(edge: .bottom, along: Double(min(max((c.x - f.minX) / f.width, 0.05), 0.95)))
        } else if dLeft < dRight {
            pos = .init(edge: .left, along: Double(min(max((c.y - f.minY) / f.height, 0.05), 0.95)))
        } else {
            pos = .init(edge: .right, along: Double(min(max((c.y - f.minY) / f.height, 0.05), 0.95)))
        }
        FlowSettings.shared.positions[Self.key(for: screen)] = pos
        model.dragging = false
        layout(animated: true)
    }

    var liveMeter: LiveMeter? { dictation?.liveMeter }
    func pasteLast() { dictation?.pasteLast() }
    func openHistory() { dictation?.openHistory() }
    func clicked() { dictation?.barClicked() }
    func stop() { dictation?.barClicked() }
    func cancel() { dictation?.cancel() }
    func noticeTapped() { model.onNoticeAction?(); setPhase(.idle) }
    func hideForAnHour() { FlowSettings.shared.hiddenUntil = Date().addingTimeInterval(3600); refresh() }
    func startCommand() { dictation?.startFromBar(command: true) }
}

/// Clicks land on the first try even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FlowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

struct FlowBarView: View {
    @ObservedObject var model: FlowBarModel
    let controller: FlowBarController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = Capsule(style: .continuous)
        content
            .frame(width: model.size.width, height: model.size.height)
            .background(Ink.inkFixed.opacity(model.phase == .idle && !model.hover ? 0.78 : 0.96), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(model.phase == .idle && !model.hover ? 0.22 : 0.14), lineWidth: 1))
            .overlay(shape.strokeBorder(Ink.persimmon.opacity(model.command ? 0.9 : 0), lineWidth: 1.5))
            .contentShape(shape)
            .onHover { h in model.hover = h }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in controller.dragChanged() }
                .onEnded { _ in controller.dragEnded() })
            .simultaneousGesture(TapGesture().onEnded {
                switch model.phase {
                case .notice: controller.noticeTapped()
                case .working: break
                default: controller.clicked()
                }
            })
            .contextMenu { FlowBarMenu(controller: controller) }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.phase)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.hover)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            if model.hover || model.dragging {
                HStack(spacing: 7) {
                    RibbonMark(color: Ink.persimmon).frame(width: 11, height: 12)
                    Text(model.dragging ? "Drop at an edge" : model.hint).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                }
                .padding(.horizontal, 12)
            } else {
                HStack(spacing: 3) { ForEach(0..<5, id: \.self) { _ in Capsule().fill(Color.white.opacity(0.55)).frame(width: 3, height: 3) } }
            }
        case .listening:
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Circle().fill(Ink.persimmon).frame(width: 8, height: 8)
                    if let live = controller.liveMeter { FlowBarMeter(live: live).frame(height: 16) }
                    if model.handsFree {
                        Button(action: controller.cancel) { Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.75)).frame(width: 20, height: 20) }
                            .buttonStyle(.plain).help("Cancel (Esc)")
                        Button(action: controller.stop) { RoundedRectangle(cornerRadius: 2.5).fill(Color.white).frame(width: 9, height: 9).frame(width: 22, height: 22).background(Ink.persimmon, in: Circle()) }
                            .buttonStyle(.plain).help("Stop and paste")
                    }
                }
                if !model.warning.isEmpty {
                    Text(model.warning).font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.butter).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
        case .working:
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini).tint(.white)
                Text(model.command ? "Editing…" : "Writing…").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            }
        case .notice:
            HStack(spacing: 10) {
                Text(model.notice).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                if let a = model.noticeAction {
                    Text(a).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.butter)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var accessibilityLabel: String {
        switch model.phase {
        case .idle: return "Verbatim dictation. " + model.hint
        case .listening: return model.handsFree ? "Listening. Click to stop and paste." : "Listening"
        case .working: return "Writing your words"
        case .notice: return model.notice
        }
    }
}

struct FlowBarMeter: View {
    @ObservedObject var live: LiveMeter
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(live.levels.suffix(18).enumerated()), id: \.offset) { _, v in
                Capsule().fill(Color.white).frame(width: 3, height: max(3, CGFloat(v) * 16))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Right-click the floating button.
struct FlowBarMenu: View {
    let controller: FlowBarController
    @ObservedObject private var s = FlowSettings.shared
    var body: some View {
        Button("Dictate") { controller.clicked() }
        Button("Edit selected text by voice") { controller.startCommand() }
        Divider()
        Picker("Cleanup", selection: $s.cleanup) { ForEach(CleanupLevel.allCases) { Text($0.title).tag($0) } }
        Picker("Start and stop", selection: $s.mode) { ForEach(FlowMode.allCases) { Text($0.title).tag($0) } }
        Divider()
        Button("Paste last dictation") { controller.pasteLast() }
        Button("Open dictation history") { controller.openHistory() }
        Divider()
        Button("Hide for 1 hour") { controller.hideForAnHour() }
        Button("Hide floating button") { s.showBar = false }
    }
}
