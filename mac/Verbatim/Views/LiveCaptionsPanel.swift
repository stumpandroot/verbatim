import SwiftUI
import AppKit

// MARK: - Panel

/// The floating captions panel: never activates Verbatim or takes keyboard focus, floats above other windows
/// (and full-screen apps, by default), joins every Space, and remembers where you put it. Width is yours to
/// change; height follows the text size.
@MainActor
final class LiveCaptionsPanel {
    private let panel: CaptionsWindow
    private var defaultsObserver: NSObjectProtocol?
    private var lastSize = CaptionSize.saved
    private var lastAbove = CaptionPrefs.aboveFullScreen
    private static let autosave = "VerbatimLiveCaptions"

    init(controller: LiveCaptions) {
        let height = Self.height(CaptionSize.saved)
        let p = CaptionsWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: height),
                               styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.backgroundColor = NSColor(Refined.paper)
        p.title = "Live captions"
        let host = CaptionsHostingView(rootView: LiveCaptionsView(controller: controller, feed: controller.feed).limitMotionRoot())
        p.contentView = host
        panel = p
        Self.applyBehavior(p, above: lastAbove)
        Self.applyHeight(p, height: height)
        let hasSaved = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.autosave)") != nil
        p.setFrameAutosaveName(Self.autosave)
        if !hasSaved, let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            let w = min(880, f.width - 80)
            p.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 40, width: w, height: height), display: false)
        }
        Self.applyHeight(p, height: height)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.preferencesChanged() }
        }
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    private func preferencesChanged() {
        let size = CaptionSize.saved, above = CaptionPrefs.aboveFullScreen
        if size != lastSize { lastSize = size; Self.applyHeight(panel, height: Self.height(size)) }
        if above != lastAbove { lastAbove = above; Self.applyBehavior(panel, above: above) }
    }

    /// Room for two older lines and a current line of up to two lines at each size.
    static func height(_ size: CaptionSize) -> CGFloat {
        switch size { case .small: return 214; case .medium: return 248; case .large: return 300 }
    }

    private static func applyHeight(_ p: NSPanel, height: CGFloat) {
        // Frame sizes: the content fills the whole frame (full-size content view).
        p.minSize = NSSize(width: 520, height: height)
        p.maxSize = NSSize(width: 2400, height: height)
        var f = p.frame
        guard abs(f.height - height) > 0.5 else { return }
        f.size.height = height   // the bottom edge stays where it is
        p.setFrame(f, display: true, animate: false)
    }

    private static func applyBehavior(_ p: NSPanel, above: Bool) {
        p.level = above ? .statusBar : .floating
        p.collectionBehavior = above ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.canJoinAllSpaces, .ignoresCycle]
    }
}

/// Never key, never main: clicks work, typing stays in the app you're using.
final class CaptionsWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The first click on a control lands even though the panel is never key.
final class CaptionsHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Dragging here moves the panel.
struct CaptionsDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// A pop-up menu at the pointer, for the panel's chips. Works in a panel that's never key.
@MainActor
enum CaptionsMenu {
    struct Item {
        var title: String
        var checked = false
        var enabled = true
        var action: (() -> Void)? = nil
        static let separator = Item(title: "-")
        static func label(_ t: String) -> Item { Item(title: t, enabled: false) }
    }

    private final class Target: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire(_ sender: Any?) { run() }
    }

    /// Captures the click now; `items` may be built after an await.
    static func anchor() -> (NSView, NSPoint)? {
        guard let e = NSApp.currentEvent, let view = e.window?.contentView else { return nil }
        return (view, view.convert(e.locationInWindow, from: nil))
    }

    static func show(_ items: [Item], at anchor: (NSView, NSPoint)?) {
        guard let (view, point) = anchor else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for it in items {
            if it.title == "-" { menu.addItem(.separator()); continue }
            let mi = NSMenuItem(title: it.title, action: nil, keyEquivalent: "")
            if let action = it.action {
                let t = Target(action)
                mi.target = t
                mi.action = #selector(Target.fire(_:))
                mi.representedObject = t
            }
            mi.isEnabled = it.enabled && it.action != nil
            mi.state = it.checked ? .on : .off
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

// MARK: - View

/// The panel's content on the refined kit (DESIGN.md §6.10): the paper page, a
/// header with the captions glyph, the source, and the elapsed time (SF Pro with tabular digits); caption lines in the
/// serif, the newest word in the accent; and a row of quiet chips with Save as transcript as the strong action.
struct LiveCaptionsView: View {
    @ObservedObject var controller: LiveCaptions
    @ObservedObject var feed: CaptionFeed
    @AppStorage(CaptionSize.key) private var sizeRaw = CaptionSize.medium.rawValue
    @AppStorage(CaptionPrefs.timecodeKey) private var showTimecode = true
    /// Read once per source change, not on every word (Core Audio can be slow to answer).
    @State private var micName: String? = nil

    private var size: CaptionSize { CaptionSize(rawValue: sizeRaw) ?? .medium }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            lines
            controls
        }
        .onAppear { micName = AudioDevices.current()?.name }
        .onChange(of: controller.source) { _, _ in micName = AudioDevices.current()?.name }
        .padding(EdgeInsets(top: 18, leading: 22, bottom: 14, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Refined.paper)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live captions")
    }

    /// "Listening to Zoom and your mic. Words appear here as they're said." Before captions start: how to start them.
    static func waitingLine(_ source: LiveCaptions.Source, open: Bool) -> String {
        guard open else { return "Not listening. Pick a source to start live captions." }
        let what: String
        switch source {
        case .mic: what = "your mic"
        case .app(_, let name): what = name
        case .both(_, let name): what = "\(name) and your mic"
        }
        return "Listening to \(what). Words appear here as they're said."
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconGlyph(art: .iconCaptions, size: 16, color: Refined.mute)
            Text("Live captions · \(controller.source.title)")
                .refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute).lineLimit(1)
            Spacer(minLength: 8)
            if showTimecode {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(captionClock(controller.elapsed)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                }
                .accessibilityLabel("Elapsed time")
            }
        }
        .frame(height: 16)
        .background(CaptionsDragArea())
    }

    private var lines: some View {
        ZStack(alignment: .bottomLeading) {
            CaptionsDragArea()
            if feed.history.isEmpty && feed.current.isEmpty {
                // Never a blank panel: what it's listening to and where the words will go, or why it isn't listening.
                Text(controller.status ?? Self.waitingLine(controller.source, open: controller.isOpen))
                    .font(.system(size: size.mac * 0.77, design: .serif)).foregroundStyle(Refined.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .uiTarget("captions-waiting")
            } else {
                // Older lines in `mute` (the line before) and `dim`: never lighter than 4.5:1 on paper.
                CaptionLinesView(feed: feed, size: size.mac,
                                 older: [(size.mac * 0.77, Refined.dim), (size.mac * 0.7, Refined.mute)],
                                 showSpeakers: controller.showsSpeakers, spacing: 6, currentLimit: 220, refined: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22), .init(color: .black, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .clipped()
        .overlay(alignment: .topTrailing) {
            if let status = controller.status, !(feed.history.isEmpty && feed.current.isEmpty) {
                Text(status).refinedFont(.caption).foregroundStyle(Refined.mute).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Refined.paper, in: Capsule())
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            if controller.confirmingClose {
                Text("Close without saving the recording?").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink)
                Spacer(minLength: 8)
                CaptionsChip(title: "Keep captioning") { controller.confirmingClose = false }
                CaptionsChip(title: "Discard") { controller.close(force: true) }
                savePill
            } else {
                Button { controller.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Refined.ink)
                        .frame(width: 30, height: 30).background(Refined.neutral, in: Circle())
                }
                .buttonStyle(.plain).help("Close captions").accessibilityLabel("Close captions")
                CaptionsChip(title: "Source: \(sourceChip)") { sourceMenu() }
                    .accessibilityLabel("Source, \(sourceChip)")
                CaptionsChip(title: CaptionLanguage.shortName(controller.language)) { languageMenu() }
                    .accessibilityLabel("Language, \(CaptionLanguage.fullName(controller.language))")
                CaptionsChip(title: "Aa Size") { sizeMenu() }
                    .accessibilityLabel("Text size, \(size.title)")
                Spacer(minLength: 8)
                savePill
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Refined.separator).frame(height: 1) }
    }

    /// "Shure MV7", "Zoom", "Zoom + Shure MV7": the microphone by name, as in Record's tile.
    private var sourceChip: String {
        let mic = micName ?? "Microphone"
        switch controller.source {
        case .mic: return mic
        case .app(_, let n): return n
        case .both(_, let n): return "\(n) + \(mic)"
        }
    }

    private var savePill: some View {
        Button { controller.save() } label: {
            HStack(spacing: 7) {
                Circle().fill(Refined.persimmon).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(controller.saving ? "Saving…" : "Save as transcript")
            }
        }
        .buttonStyle(RefinedActionStyle(kind: .strong))
        .disabled(controller.saving || !controller.isOpen)
        .help("Saves the recording and transcribes it with your main engine")
    }

    // MARK: Menus

    private func sourceMenu() {
        let anchor = CaptionsMenu.anchor()
        Task { @MainActor in
            await controller.refreshApps()
            let current = controller.source
            var items: [CaptionsMenu.Item] = [
                .init(title: "Microphone", checked: current == .mic, action: { controller.choose(.mic) }),
                .separator, .label("App audio"),
            ]
            if controller.runningApps.isEmpty { items.append(.label("No apps found")) }
            for a in controller.runningApps {
                let picked = current.appID == a.id
                items.append(.init(title: a.name, checked: picked, action: {
                    controller.choose(current.usesMic && current.appID != nil ? .both(id: a.id, name: a.name) : .app(id: a.id, name: a.name))
                }))
            }
            items.append(.separator)
            items.append(.init(title: "Also caption my microphone", checked: { if case .both = current { return true }; return false }(),
                               enabled: current.appID != nil, action: { controller.toggleMic() }))
            CaptionsMenu.show(items, at: anchor)
        }
    }

    private func languageMenu() {
        let anchor = CaptionsMenu.anchor()
        let items = CaptionLanguage.all.map { id in
            CaptionsMenu.Item(title: CaptionLanguage.fullName(id), checked: id == controller.language, action: { controller.setLanguage(id) })
        }
        CaptionsMenu.show(items, at: anchor)
    }

    private func sizeMenu() {
        let anchor = CaptionsMenu.anchor()
        let items = CaptionSize.allCases.map { s in
            CaptionsMenu.Item(title: s.title, checked: s == size, action: { sizeRaw = s.rawValue })
        }
        CaptionsMenu.show(items, at: anchor)
    }
}

/// A quiet chip (the kit's neutral wash behind ink text) that opens a menu at the pointer.
struct CaptionsChip: View {
    var title: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Refined.neutral, in: Capsule())
                .opacity(hover ? 0.85 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
    }
}

// MARK: - Entry points

/// The menu bar panel's Live captions row, below the panel's own rows.
struct LiveCaptionsMenuRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var captions = LiveCaptions.shared
    var body: some View {
        Button { app.toggleLiveCaptions() } label: {
            HStack(spacing: 10) {
                IconGlyph(art: .iconCaptions, size: 18, color: Ink.ink).frame(width: 26)
                Text(captions.isOpen ? "Close live captions" : "Live captions").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("⌥⌘C").font(.system(size: 11)).foregroundStyle(Ink.mute)
            }
            .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
