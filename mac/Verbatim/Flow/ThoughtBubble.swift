import SwiftUI
import AppKit

// The floating bubble (mockup "Thoughts", section 01): a small ink disc above every app. Click it and a thought starts
// at once; click again and it's added to today's page. Built like the dictation surfaces (DESIGN.md §12): a fixed-size,
// non-activating panel at `.statusBar` level on every Space and beside full-screen apps, where only the drawn shape
// takes clicks (gestures and `tapArea`, never SwiftUI Buttons), and it never becomes key or activates Verbose. While a
// thought records, the disc turns persimmon and shows the Thoughts icon with its wave following the mic, with "Click to
// stop" and your words on an outlined card beside it (never on glass). Saved shows "Added to Thoughts · 10:42" for two
// seconds. Drag it anywhere; its spot is kept per display. Settings › Features › Thoughts › Show the bubble.
//
// Mark a moment (mockup "Library features", section 3b): while a thought or a voice note records, the card has Mark
// with its hotkey (⌃⌥B); a click marks the time (MarkCenter) and the card says "Marked 4:12 · 3 moments" for two
// seconds. A voice note started anywhere shows here too, "Recording · Voice note", and a click on the disc stops it.

/// The bubble's measured frames and where its card goes.
@MainActor
final class BubbleLayout: ObservableObject {
    /// Everything drawn (the disc plus any card), in the panel's coordinates (top-left origin).
    @Published var contentFrame: CGRect = .zero
    /// The card goes on the side with more room: left of a bubble in the right half of the screen.
    @Published var cardLeading = true
    @Published var dragging = false
    @Published var hover = false
}

@MainActor
final class ThoughtBubble {
    static let shared = ThoughtBubble()
    static let spotsKey = "thoughts.bubble.spots"
    /// Lower right, clear of the Dock's middle and of most windows' controls.
    static let standardSpot = ButtonSpot(x: 0.96, y: 0.32)
    static let disc: CGFloat = 44
    /// Room for the card (up to 330 pt) beside the disc on either side.
    static let panelSize = CGSize(width: 780, height: 180)

    let layout = BubbleLayout()
    private var panel: SurfacePanel?
    private weak var capture: ThoughtCapture?
    private var monitor: Any?
    private var dragOffset: CGPoint = .zero
    private var screenObserver: NSObjectProtocol?

    var isShowing: Bool { panel?.isVisible == true }
    var panelWindow: NSWindow? { panel }

    func attach(_ capture: ThoughtCapture) {
        self.capture = capture
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Shows or hides the bubble to match the setting.
    func refresh() {
        guard capture != nil else { return }
        if Thoughts.showBubble { show() } else { hide() }
    }

    private func show() {
        if panel == nil { build() }
        guard let p = panel, !layout.dragging else { return }
        let screen = p.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        place(center: FloatingGeometry.center(for: spots[key(screen)] ?? Self.standardSpot, in: screen.visibleFrame, size: restSize), on: screen)
        if !p.isVisible { p.orderFrontRegardless() }
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePointer() }
            }
        }
    }

    private func hide() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard let p = panel else { return }
        p.orderOut(nil)
        p.ignoresMouseEvents = true
    }

    private var restSize: CGSize { CGSize(width: Self.disc + 8, height: Self.disc + 8) }

    private var spots: [String: ButtonSpot] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.spotsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: ButtonSpot].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.spotsKey) }
    }

    private func key(_ screen: NSScreen) -> String {
        "\(screen.localizedName)-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    private func build() {
        guard let capture, let app = capture.app else { return }
        let p = SurfacePanel.make(size: Self.panelSize)
        let host = FlowHostingView(rootView: ThoughtBubbleView(capture: capture, layout: layout, owner: self, main: app.recorder, mainWords: app.recordingWords,
                                                               marks: MarkCenter.shared).limitMotionRoot())
        host.onMouseMoved = { [weak self] in self?.updatePointer() }
        host.onRightClick = { ThoughtPadController.shared.open() }
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        p.contentView = host
        panel = p
    }

    private func place(center: CGPoint, on screen: NSScreen) {
        guard let p = panel else { return }
        let s = Self.panelSize
        let frame = NSRect(x: (center.x - s.width / 2).rounded(), y: (center.y - s.height / 2).rounded(), width: s.width, height: s.height)
        if p.frame != frame { p.setFrame(frame, display: true) }
        let leading = center.x > screen.visibleFrame.midX
        if layout.cardLeading != leading { layout.cardLeading = leading }
    }

    /// Clicks reach only what's drawn; everywhere else they pass through to the apps behind.
    func updatePointer(at location: CGPoint = NSEvent.mouseLocation) {
        guard let p = panel else { return }
        if layout.dragging {
            if NSEvent.pressedMouseButtons & 1 == 0 { dragEnded() } else { p.ignoresMouseEvents = false }
            return
        }
        guard p.isVisible, layout.contentFrame.width > 1 else { if !p.ignoresMouseEvents { p.ignoresMouseEvents = true }; return }
        let f = p.frame, c = layout.contentFrame
        let drawn = NSRect(x: f.minX + c.minX, y: f.maxY - c.maxY, width: c.width, height: c.height).insetBy(dx: -4, dy: -4)
        let inside = drawn.contains(location)
        if p.ignoresMouseEvents == inside { p.ignoresMouseEvents = !inside }
        if layout.hover != inside { layout.hover = inside }
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
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? p.screen ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        let center = FloatingGeometry.clamp(CGPoint(x: p.frame.midX, y: p.frame.midY), in: f, size: restSize)
        var all = spots
        all[key(screen)] = FloatingGeometry.spot(for: center, in: f)
        spots = all
        place(center: center, on: screen)
    }

    /// The disc: stops a voice note while one records, otherwise starts or stops a thought.
    func clicked() {
        if let app = capture?.app, capture?.isRecording != true, app.recorder.isRecording {
            app.stopRecording()
            return
        }
        capture?.toggle()
    }

    /// The card's Mark.
    func markClicked() { MarkCenter.shared.mark(.macBubble) }
}

// MARK: - View

struct ThoughtBubbleView: View {
    @ObservedObject var capture: ThoughtCapture
    @ObservedObject var layout: BubbleLayout
    let owner: ThoughtBubble
    /// The app's voice-note recorder and its words: a voice note shows on the bubble too.
    @ObservedObject var main: Recorder
    let mainWords: RecordingWords
    @ObservedObject var marks: MarkCenter
    @Environment(\.limitMotion) private var limitMotion

    private static let space = "thought-bubble-panel"

    var body: some View {
        // In a screen change's or look switch's marks only if the bubble re-renders with it (it shouldn't).
        let _ = LookSwitch.mark("bubble")
        ZStack {
            Color.clear
            disc
                .contentShape(Circle())
                .background(GeometryReader { g in
                    Color.clear.preference(key: SurfaceFrameKey.self, value: g.frame(in: .named(Self.space)))
                })
                // One gesture: a drag moves the bubble, otherwise it's a click.
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in owner.dragChanged() }
                    .onEnded { _ in owner.dragEnded() }
                    .exclusively(before: TapGesture().onEnded { owner.clicked() }))
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(spokenLabel)
                .accessibilityAction { owner.clicked() }
                .uiTarget("thought-bubble")
                .overlay(alignment: layout.cardLeading ? .leading : .trailing) {
                    card
                        .fixedSize()
                        .alignmentGuide(.leading) { d in layout.cardLeading ? d[.trailing] + 12 : d[.leading] }
                        .alignmentGuide(.trailing) { d in layout.cardLeading ? d[.trailing] : d[.leading] - 12 }
                }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(SurfaceFrameKey.self) { f in if layout.contentFrame != f { layout.contentFrame = f } }
        .animation(limitMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22), value: stateKey)
    }

    /// A voice note records (and no thought does): the disc stops it and the card shows it.
    private var voiceNote: Bool { !capture.isRecording && main.isRecording && !main.isStarting }

    private var spokenLabel: String {
        if voiceNote { return "Recording a voice note. Click to stop." }
        return capture.isRecording ? "Recording a thought. Click to stop." : "New thought, " + Keycap.spoken(Thoughts.hotkey)
    }

    /// What animates: a mark's "Marked 4:12" isn't in it, so a mark from ⌃⌥B swaps the card at once (§7).
    private var stateKey: String { "\(capture.phase)-\(voiceNote)-\(layout.hover)-\(capture.notice ?? "")" }

    private var disc: some View {
        let s = ThoughtBubble.disc
        let recording = capture.isRecording || voiceNote
        return ZStack {
            Circle().fill(recording ? Ink.persimmonFixed : Ink.inkFixed)
            if voiceNote {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Ink.inkFixed).frame(width: s * 0.3, height: s * 0.3)
            } else {
                switch capture.phase {
                case .recording:
                    ThoughtMicLevel(live: capture.recorder.live, color: Ink.inkFixed).frame(width: s * 0.55, height: s * 0.55)
                case .saved:
                    BrandGlyph(art: .webCheck, color: Ink.paperFixed, minLineWidth: 1.8).frame(width: s * 0.4, height: s * 0.4)
                case .idle:
                    ThoughtGlyph(color: Ink.paperFixed, lineWidth: 1.4).frame(width: s * 0.55, height: s * 0.55)
                }
            }
        }
        .frame(width: s, height: s)
        .overlay(Circle().strokeBorder(recording ? Ink.inkFixed : Ink.paperFixed.opacity(0.9), lineWidth: 1.5).padding(-1.5))
        .background(Circle().fill(Ink.inkFixed).offset(x: 3, y: 4))
    }

    /// Beside the disc: the hint on hover, the recording card, the saved line, or a notice.
    @ViewBuilder private var card: some View {
        if let notice = capture.notice {
            BubbleCard {
                HStack(spacing: 8) {
                    BrandGlyph(art: .webAttention, color: Ink.inkFixed, minLineWidth: 1.4).frame(width: 15, height: 15)
                    Text(notice).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                        .lineLimit(3).frame(maxWidth: 280, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            .surfaceFrame(in: Self.space)
        } else if let c = marks.confirmation, capture.isRecording || voiceNote {
            BubbleMarkedCard(confirmation: c).surfaceFrame(in: Self.space).uiTarget("thought-bubble-marked")
        } else if voiceNote {
            BubbleRecordingCard(title: "Recording · Voice note", live: main.live, words: mainWords, stopHint: "Click the disc to stop", onMark: owner.markClicked)
                .surfaceFrame(in: Self.space)
                .uiTarget("thought-bubble-voice-note")
        } else {
            switch capture.phase {
            case .recording:
                BubbleRecordingCard(title: "New thought", live: capture.recorder.live, words: capture.words, stopHint: nil, onMark: owner.markClicked)
                    .surfaceFrame(in: Self.space)
            case .saved(let at):
                BubbleCard {
                    HStack(spacing: 8) {
                        BrandGlyph(art: .webCheck, color: Ink.inkFixed, minLineWidth: 1.6).frame(width: 13, height: 13)
                        Text("Added to Thoughts · \(Thoughts.time(at, native: false))").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                    }
                }
                .surfaceFrame(in: Self.space)
                .uiTarget("thought-bubble-saved")
            case .idle:
                if layout.hover && !layout.dragging {
                    BubbleCard(compact: true) {
                        HStack(spacing: 8) {
                            Text("New thought").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                            BubbleKeycap(keys: Thoughts.hotkey)
                        }
                    }
                    .surfaceFrame(in: Self.space)
                }
            }
        }
    }
}

/// An outlined card on the reader white, with the hard ink shadow, so it reads on any wallpaper (never glass).
private struct BubbleCard<Content: View>: View {
    var compact = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
        content()
            .padding(.horizontal, compact ? 10 : 13).padding(.vertical, compact ? 6 : 9)
            .background(Ink.readerFixed, in: shape)
            .overlay(shape.strokeBorder(Ink.inkFixed, lineWidth: 1.5))
            .background(shape.fill(Ink.inkFixed).offset(x: 3, y: 4))
    }
}

private struct BubbleKeycap: View {
    var keys: String
    /// A raised keycap (a 1.5 pt ink floor), as on the Mark pill.
    var floor = false
    var body: some View {
        Text(keys).font(SurfaceFont.mono(12)).foregroundStyle(Ink.inkFixed)
            .padding(.horizontal, floor ? 4 : 5).padding(.vertical, floor ? 1 : 2)
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.inkFixed, lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.readerFixed))
            .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.inkFixed).offset(y: floor ? 1.5 : 0).opacity(floor ? 1 : 0))
            .accessibilityLabel(Keycap.spoken(keys))
    }
}

/// While a thought or a voice note records: persimmon voice bars, "New thought" or "Recording · Voice note", the time
/// in mono, your words, and Mark with its hotkey beside how to stop.
private struct BubbleRecordingCard: View {
    var title: String
    let live: LiveMeter
    @ObservedObject var words: RecordingWords
    /// "Click the disc to stop" (a voice note); nil for a thought, which also stops with ⌃⌥P.
    var stopHint: String?
    var onMark: () -> Void
    var body: some View {
        BubbleCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    BubbleBars(live: live)
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                    Spacer(minLength: 12)
                    BubbleClock(live: live)
                }
                let d = words.shown.tail(70).display
                Group {
                    if words.shown.isEmpty {
                        Text("Listening…").italic().foregroundColor(Ink.inkFixed.opacity(0.55))
                    } else {
                        Text(d.settled).foregroundColor(Ink.inkFixed.opacity(0.6))
                            + Text((d.settled.isEmpty ? "" : " ") + [d.volatile, d.newest].filter { !$0.isEmpty }.joined(separator: " ")).foregroundColor(Ink.inkFixed)
                    }
                }
                .font(SurfaceFont.serif(15))
                .lineLimit(2).truncationMode(.head)
                .frame(width: 250, alignment: .leading)
                .accessibilityHidden(true)
                HStack(spacing: 8) {
                    BubbleMarkPill(action: onMark)
                    Spacer(minLength: 12)
                    if let stopHint {
                        Text(stopHint).font(.system(size: 12)).foregroundStyle(Ink.inkFixed.opacity(0.75))
                    } else {
                        HStack(spacing: 6) {
                            Text("Click to stop ·").font(.system(size: 12)).foregroundStyle(Ink.inkFixed.opacity(0.75))
                            BubbleKeycap(keys: Thoughts.hotkey)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

/// Mark on the recording card: a mini line pill with the Mark icon and its hotkey. A tap area, not a Button (§12).
private struct BubbleMarkPill: View {
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        let keys = MarkHotkeyStore.current().title
        HStack(spacing: 6) {
            BrandGlyph(art: .iconMark, color: Ink.inkFixed, minLineWidth: 1.3).frame(width: 13, height: 13)
            Text("Mark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.inkFixed)
            BubbleKeycap(keys: keys, floor: true)
        }
        .padding(.leading, 9).padding(.trailing, 6)
        .frame(height: 28)
        .background(Capsule().fill(Ink.inkFixed.opacity(hover ? 0.06 : 0)))
        .overlay(Capsule().strokeBorder(Ink.inkFixed, lineWidth: 1.5))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .tapArea(action)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Mark a moment, \(Keycap.spoken(keys))")
        .accessibilityAction { action() }
        .uiTarget("thought-bubble-mark")
    }
}

/// For two seconds after a mark: the Marked icon on a butter square, "Marked 4:12", and the count.
private struct BubbleMarkedCard: View {
    var confirmation: MarkConfirmation
    var body: some View {
        BubbleCard {
            HStack(spacing: 8) {
                BrandGlyph(art: .iconMarked, color: Ink.inkFixed, minLineWidth: 1.3).frame(width: 14, height: 14)
                    .frame(width: 24, height: 24)
                    .background(Ink.butterFixed, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                Text("Marked").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkFixed)
                Text(Marks.clock(confirmation.at)).font(SurfaceFont.mono(13)).foregroundStyle(Ink.inkFixed)
                Text(Marks.count(confirmation.count)).font(SurfaceFont.mono(12)).foregroundStyle(Ink.inkFixed.opacity(0.7))
                    .padding(.leading, 6)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Marks.confirmation(confirmation))
        }
    }
}

private struct BubbleBars: View {
    @ObservedObject var live: LiveMeter
    var body: some View { VoiceBars(levels: VoiceBars.live(live.levels, count: 5), height: 13, barWidth: 2.5, gap: 2) }
}

private struct BubbleClock: View {
    @ObservedObject var live: LiveMeter
    var body: some View {
        Text(SurfaceClock.text(live.elapsed)).font(SurfaceFont.mono(12)).monospacedDigit().foregroundStyle(Ink.inkFixed.opacity(0.75))
    }
}
