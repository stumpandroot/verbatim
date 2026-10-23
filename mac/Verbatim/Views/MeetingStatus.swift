import SwiftUI
import AppKit

// While a meeting records: a menu bar item with the record dot and a running mono timer, shown only while
// recording (whether or not Settings › General › Show in menu bar is on). Clicking it opens the meeting panel:
// both tracks with real level meters, Pause, Stop and save, and Copy the chat notice again.

/// The two tracks' recent levels and the elapsed time, sampled ten times a second only while the panel is open.
@MainActor
final class MeetingMeters: ObservableObject {
    static let bars = 18
    @Published private(set) var mic: [Float] = Array(repeating: 0, count: bars)
    @Published private(set) var system: [Float] = Array(repeating: 0, count: bars)
    @Published private(set) var elapsed: Double = 0
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        mic = Array(repeating: 0, count: Self.bars); system = mic
    }

    private func sample() {
        let s = MeetingSession.shared
        let l = s.levels()
        mic = Array(mic.dropFirst()) + [min(1, max(0, l.mic))]
        system = Array(system.dropFirst()) + [s.micOnly ? 0 : min(1, max(0, l.system))]
        elapsed = s.elapsed
    }
}

/// The menu bar item and its panel. An NSStatusItem of its own, added when a meeting starts and removed when it
/// stops, so the timer shows even with Verbose's menu bar item turned off.
@MainActor
final class MeetingStatusController: NSObject {
    static let panelWidth: CGFloat = 340
    let meters = MeetingMeters()
    private var item: NSStatusItem?
    private var timer: Timer?
    private var panel: MeetingFloatingPanel?
    private var host: MeetingHostingView<AnyView>?
    private var monitors: [Any] = []
    var copyNotice: (() -> Void)?

    var isShowing: Bool { item != nil }
    var isOpen: Bool { panel?.isVisible == true }

    func show() {
        guard item == nil else { update(); return }
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = i.button {
            b.target = self
            b.action = #selector(clicked)
            b.imagePosition = .imageLeading
        }
        item = i
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        Log.note("meeting: menu bar item shown")
    }

    func hide() {
        close()
        timer?.invalidate(); timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// The dot (persimmon while recording, an outline while paused) and the time. Paused also says so in words,
    /// so the state never depends on color alone.
    func update() {
        guard let b = item?.button else { return }
        let s = MeetingSession.shared
        let paused = s.phase == .paused
        let time = MeetingCopy.clock(s.elapsed)
        b.image = Self.dot(filled: !paused)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        b.attributedTitle = NSAttributedString(string: paused ? " Paused \(time)" : " \(time)", attributes: [.font: font])
        let header = MeetingCopy.recordingHeader(Self.appName(s), paused: paused, micOnly: s.micOnly)
        b.toolTip = "\(header) · \(time)"
        b.setAccessibilityLabel("Verbose: \(header), \(time)")
    }

    @objc private func clicked() { isOpen ? close() : open() }

    func open() {
        guard let button = item?.button, let bw = button.window else { return }
        let p = panel ?? make()
        host?.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.panelWidth, height: max(120, ceil(host?.fittingSize.height ?? 240)))
        let anchor = bw.frame
        let screen = bw.screen ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let f = screen?.visibleFrame { x = min(max(f.minX + 8, x), f.maxX - size.width - 8) }
        p.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        host?.frame = NSRect(origin: .zero, size: size)
        meters.start()
        p.alphaValue = 1
        p.orderFrontRegardless()
        p.invalidateShadow()
        // A click anywhere else closes the panel; the item's own click toggles it.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            MainActor.assumeIsolated { () -> NSEvent? in
                guard let self else { return e }
                if e.window !== self.panel && e.window !== self.item?.button?.window { self.close() }
                return e
            }
        }) { monitors.append(l) }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        meters.stop()
        panel?.orderOut(nil)
    }

    private func make() -> MeetingFloatingPanel {
        let p = MeetingFloatingPanel.make(keyable: false, level: .popUpMenu)
        p.setAccessibilityTitle("Meeting recording")
        let view = MeetingRecordingView(session: MeetingSession.shared, meters: meters,
                                        copyNotice: { [weak self] in self?.copyNotice?() },
                                        stop: { [weak self] in self?.close(); MeetingSession.shared.stop() }).limitMotionRoot()
        let h = MeetingHostingView(rootView: AnyView(view))
        h.sizingOptions = []
        p.contentView = h
        panel = p; host = h
        return p
    }

    /// The system track's name for the panel: the app, or nil for all system audio.
    static func appName(_ s: MeetingSession) -> String? { s.tapsEverything && s.speaker == "Others" ? nil : s.speaker }

    private static var dots: [Bool: NSImage] = [:]
    private static func dot(filled: Bool) -> NSImage {
        if let i = dots[filled] { return i }
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            let path = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            if filled { NSColor(Ink.persimmon).setFill(); path.fill() } else { NSColor(Ink.ink).setStroke(); path.lineWidth = 1.5; path.stroke() }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = filled ? "Recording" : "Paused"
        dots[filled] = img
        return img
    }
}

/// The meeting panel from the menu bar item (the approved mockup's "While recording: menu bar panel").
struct MeetingRecordingView: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var meters: MeetingMeters
    var copyNotice: () -> Void
    var stop: () -> Void
    @State private var copied = false

    var body: some View {
        let paused = session.phase == .paused
        let app = MeetingStatusController.appName(session)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(paused ? Color.clear : Ink.persimmon).overlay(Circle().strokeBorder(paused ? Ink.ink : Color.clear, lineWidth: 1.5))
                    .frame(width: 8, height: 8).accessibilityHidden(true)
                Text(MeetingCopy.recordingHeader(app, paused: paused, micOnly: session.micOnly))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(MeetingCopy.clock(meters.elapsed)).font(Ink.mono(13, weight: .semibold))
                    .accessibilityLabel("Elapsed \(MeetingCopy.clock(meters.elapsed))")
            }
            .accessibilityElement(children: .combine)
            track(icon: .iconAboutMe, name: "You", detail: session.micName, levels: meters.mic)
            track(icon: .iconSpeakers, name: app ?? "Other apps", detail: systemDetail(app), levels: meters.system, off: session.micOnly)
            HStack(spacing: 8) {
                MeetingButton(title: paused ? "Resume" : "Pause", icon: paused ? .iconPlay : .iconPause, enabled: session.canPause, stretch: true,
                              target: "meeting-panel-pause") { session.togglePause() }
                MeetingButton(title: "Stop and save", style: .primary, icon: .iconStop, stretch: true, target: "meeting-panel-stop", action: stop)
            }
            HStack(spacing: 8) {
                ArtIcon(art: .iconCopy, size: 13)
                Text(copied ? "Copied" : "Copy the chat notice again").font(.system(size: 12))
            }
            .foregroundStyle(Ink.mute)
            .tapArea {
                copyNotice()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Copy the chat notice again")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { copyNotice() }
            .modifier(MeetingTarget(id: "meeting-panel-copy"))
        }
        .padding(14)
        .frame(width: MeetingStatusController.panelWidth, alignment: .leading)
        .foregroundStyle(Ink.ink)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline))
    }

    private func systemDetail(_ app: String?) -> String {
        if session.micOnly { return "Not recording" }
        if session.remoteSilent { return "Not hearing anything" }
        return app.map { "Sound from \($0)" } ?? "Everything this Mac plays"
    }

    private func track(icon: BrandArt, name: String, detail: String, levels: [Float], off: Bool = false) -> some View {
        HStack(spacing: 10) {
            IconGlyph(art: icon, size: 20, color: off ? Ink.mute : Ink.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            Spacer(minLength: 8)
            MeetingLevelMeter(levels: levels).frame(width: 82, height: 22)
        }
        .padding(10)
        .background(Ink.paper, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A row of bars for one track's recent levels, newest at the right. A real level, never decoration
/// (mac/DESIGN.md §7). With Limit Motion the bars stand still and only say whether sound is arriving.
struct MeetingLevelMeter: View {
    var levels: [Float]
    @Environment(\.limitMotion) private var limitMotion
    private static let resting: [CGFloat] = [0.35, 0.55, 0.4, 0.7, 0.5, 0.85, 0.45, 0.6, 0.3, 0.65, 0.8, 0.5, 0.4, 0.7, 0.55, 0.9, 0.45, 0.6]

    var body: some View {
        let hearing = (levels.suffix(10).max() ?? 0) > 0.04
        Canvas { ctx, size in
            let n = levels.count
            guard n > 0 else { return }
            let gap: CGFloat = 2
            let w = max(1.5, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for i in 0..<n {
                let v: CGFloat = limitMotion ? Self.resting[i % Self.resting.count] : CGFloat(levels[i])
                let h = max(3, v * size.height)
                let r = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(Ink.ink.opacity(limitMotion && !hearing ? 0.3 : 1)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(hearing ? "Hearing sound" : "Quiet")
    }
}
