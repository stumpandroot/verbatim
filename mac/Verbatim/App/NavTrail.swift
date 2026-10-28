import SwiftUI
import AppKit

// Back and Forward for the main window, in both looks, and the places screens come back to.
//
// One history (`NavTrail`) records every navigation in `AppState.go`: going somewhere new (a sidebar click, opening a
// transcript) starts a new trail from where you are, as a browser or Finder does, and Back and Forward walk it. Verbose
// style shows a back pill on the transcript's header (`TranscriptBackPill`), Native its toolbar's Back and Forward
// (NativeChrome.swift); both looks have View › Back and Forward (⌘[ and ⌘]), the mouse's back and forward buttons, and
// the trackpad's swipe between pages.
//
// A screen leaves the window the moment you navigate away (ContentView), so what it should come back to lives here
// (`ScreenPlaces`): each scroll view's offset, the Library's selected row, and By day's day. None of it is published:
// a screen reads it once, when it's built, and writes it back as it leaves, so navigating re-renders nothing extra.

/// One place in the window's history: a screen and, for the Library, the project it showed.
struct NavStop: Equatable {
    var screen: Screen
    var project: UUID?
    init(_ screen: Screen, project: UUID?) {
        self.screen = screen
        self.project = screen == .library ? project : nil
    }
}

@MainActor
final class NavTrail: ObservableObject {
    static let shared = NavTrail()

    private var history = NavHistory<NavStop>()
    /// Only whether Back and Forward can go is published, and only when that changes (the menu, Native's toolbar).
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// True for a navigation made by Back or Forward, until the next one. Home puts its scroll back only then.
    private(set) var movingThroughHistory = false
    private var moving = false
    private var monitor: Any?

    /// Where Back goes.
    var backStop: NavStop? { history.previous }

    /// AppState.go, before the screen changes: the place you're leaving (as it is now) and where you're going.
    func record(from: NavStop, to: NavStop) {
        movingThroughHistory = moving
        // Back and Forward have already moved along the trail.
        guard !moving else { return }
        if history.current == nil || history.current?.screen == from.screen { history.replaceCurrent(from) } else { history.visit(from) }
        history.visit(to)
    }

    /// AppState.go, after the screen changed.
    func publish() {
        if canGoBack != history.canGoBack { canGoBack = history.canGoBack }
        if canGoForward != history.canGoForward { canGoForward = history.canGoForward }
        NavMenuItems.shared.refresh()
    }

    func goBack(_ app: AppState) {
        settle(app)
        guard let s = history.goBack() else { publish(); return }
        travel(to: s, app)
    }

    func goForward(_ app: AppState) {
        settle(app)
        guard let s = history.goForward() else { publish(); return }
        travel(to: s, app)
    }

    /// Before stepping: deleted transcripts leave the trail, and the place you're on is recorded as it is now (the
    /// Library may show another project since you came), so Forward returns to it.
    private func settle(_ app: AppState) {
        dropDeleted(app)
        if history.current?.screen == app.screen { history.replaceCurrent(NavStop(app.screen, project: app.projectFilter)) }
    }

    /// The transcript's back pill: Back, or the Library when there's nowhere to go back to.
    func back(_ app: AppState) {
        if history.canGoBack { goBack(app) } else { app.go(.library) }
    }

    private func travel(to s: NavStop, _ app: AppState) {
        moving = true
        defer { moving = false }
        // The project first, as the sidebar does (one publish each; `go` swaps the screen without animation).
        if s.screen == .library, app.projectFilter != s.project { app.projectFilter = s.project }
        if s.screen == app.screen { publish() } else { app.go(s.screen) }
    }

    private func dropDeleted(_ app: AppState) {
        history.removeAll { s in
            if case .transcript(let id) = s.screen { return app.store.transcript(id).map { $0.deletedAt != nil } ?? true }
            return false
        }
    }

    /// The name on the back pill: where Back goes ("Library", "Home", "Dictations", "Thoughts", "Search").
    func backName(_ app: AppState) -> String {
        guard let s = backStop else { return "Library" }
        switch s.screen {
        case .home: return "Home"
        case .library:
            if !app.search.trimmingCharacters(in: .whitespaces).isEmpty { return "Search" }
            if let p = s.project, let name = app.store.projects.first(where: { $0.id == p })?.name { return name }
            return "Library"
        case .queue: return "Queue"
        case .trash: return "Recently Deleted"
        case .dictionary: return "Dictionary"
        case .dictations: return "Dictations"
        case .activity: return "You"
        case .byDay(let k): return Thoughts.pageName(k)
        case .templates: return "Templates"
        case .ask: return "Ask"
        case .transcript(let id): return app.store.transcript(id)?.title ?? "Back"
        }
    }

    /// The mouse's back and forward buttons and the trackpad's swipe between pages, in the main window. A side
    /// button that's the dictation hotkey stays dictation's (MouseButtonTap takes it; a listen-only tap doesn't).
    func installMonitor(_ app: AppState) {
        NavMenuItems.shared.install(app)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { [weak self, weak app] e in
            guard let self, let app, let w = e.window, w === app.mainWindow, w.attachedSheet == nil else { return e }
            switch e.type {
            case .otherMouseDown:
                let n = e.buttonNumber
                guard n == 3 || n == 4 else { return e }
                if app.dictation.enabled, app.dictation.hotkey == .mouse, HotkeyStore.mouseButton() == n { return e }
                if n == 3 { self.goBack(app) } else { self.goForward(app) }
                return nil
            case .swipe:
                // A swipe to the right (deltaX 1) goes back, to the left forward, as in Safari and Finder.
                if e.deltaX > 0 { self.goBack(app) } else if e.deltaX < 0 { self.goForward(app) } else { return e }
                return nil
            default:
                return e
            }
        }
    }
}

/// View › Back and Forward (⌘[ and ⌘]) for the main window in both looks, as AppKit menu items. Builds 222 and 224
/// drew them as SwiftUI commands, first observing NavTrail and then a focused scene value; the menu bar didn't
/// refresh from either, so Forward stayed off after going back and ⌘] did nothing. AppKit validates these when the
/// menu opens and when a key equivalent is looked up, reading the trail then, whichever window is in front.
@MainActor
final class NavMenuItems: NSObject, NSMenuItemValidation {
    static let shared = NavMenuItems()
    private weak var app: AppState?
    private let separator = NSMenuItem.separator()
    private lazy var back = item("Back", "[", #selector(goBack(_:)))
    private lazy var forward = item("Forward", "]", #selector(goForward(_:)))
    private var observers: [NSObjectProtocol] = []
    private var placing = false

    /// Puts the items in the View menu, after Edit Home, and back there whenever SwiftUI rebuilds the menu bar.
    func install(_ app: AppState) {
        self.app = app
        place()
        guard observers.isEmpty else { return }
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeSoon() }
            })
        }
        placeSoon()
    }

    /// Enabled as the trail can go (for a menu that doesn't validate its items).
    func refresh() {
        let trail = NavTrail.shared
        if back.isEnabled != trail.canGoBack { back.isEnabled = trail.canGoBack }
        if forward.isEnabled != trail.canGoForward { forward.isEnabled = trail.canGoForward }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === back { return NavTrail.shared.canGoBack && app != nil }
        if menuItem === forward { return NavTrail.shared.canGoForward && app != nil }
        return true
    }

    @objc private func goBack(_ sender: Any?) { if let app { NavTrail.shared.goBack(app) } }
    @objc private func goForward(_ sender: Any?) { if let app { NavTrail.shared.goForward(app) } }

    private func item(_ title: String, _ key: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = .command
        i.target = self
        return i
    }

    /// Menus change rarely (SwiftUI building the menu bar); the check runs once on the next turn after a burst.
    private func placeSoon() {
        guard !placing else { return }
        placing = true
        DispatchQueue.main.async { [weak self] in
            self?.placing = false
            self?.place()
        }
    }

    private func place() {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        refresh()
        if back.menu === menu, forward.menu === menu, separator.menu === menu { return }
        for i in [separator, back, forward] { i.menu?.removeItem(i) }
        var at = menu.items.firstIndex { $0.title == "Edit Home" }.map { $0 + 1 } ?? menu.items.count
        for i in [separator, back, forward] { menu.insertItem(i, at: at); at += 1 }
    }
}

/// The transcript's Back in Verbose style: a line pill with a chevron, named for where you came from (DESIGN.md §11's
/// pill; Native's Back is in the toolbar). Reads the trail once per render: it changes only by navigating, which
/// builds a new transcript screen.
struct TranscriptBackPill: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let trail = NavTrail.shared
        let name = trail.backName(app)
        return Button { trail.back(app) } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .bold))
                Text(name).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading)
            }
        }
        .buttonStyle(PillButtonStyle(kind: .line, size: .mini))
        .help("Back to \(name) (⌘[)")
        .accessibilityLabel("Back to \(name)")
        .uiTarget("transcript-back")
    }
}

// MARK: - Places

/// What each screen comes back to: scroll offsets (per screen and look), the Library's selected row (per project),
/// Native's table selection, and By day's day and month. Plain storage, never observed.
@MainActor
final class ScreenPlaces {
    static let shared = ScreenPlaces()

    private var offsets: [String: CGFloat] = [:]
    private var rows: [String: UUID] = [:]
    private var days: [RecordingKind: (day: Date?, month: Date?)] = [:]
    /// Native's View as Table selection (the view clears it when the project changes).
    var tableSelection: Set<String> = []
    /// The scroll probes on screen, by key, for the self-test.
    private var live: [String: WeakProbe] = [:]
    /// The last restore: its key, the offset it put back, and whether it was in place before the screen's first frame.
    private(set) var lastRestore: (key: String, offset: CGFloat, early: Bool)?

    static func libraryKey(_ project: UUID?) -> String { "library|\(project?.uuidString ?? "-")" }
    /// A scroll view's key: the screen's (the Library's carries its project) and the look.
    static func scrollKey(_ screen: String, look: AppLook) -> String { "\(screen)|\(look == .native ? "native" : "verbose")" }

    func offset(_ key: String) -> CGFloat? { offsets[key] }
    func setOffset(_ key: String, _ y: CGFloat) { offsets[key] = y }
    func selectedRow(_ project: UUID?) -> UUID? { rows[Self.libraryKey(project)] }
    func day(_ kind: RecordingKind) -> (day: Date?, month: Date?) { days[kind] ?? (nil, nil) }
    func setDay(_ kind: RecordingKind, day: Date?, month: Date?) { days[kind] = (day, month) }

    /// AppState.go, before the screen changes: the Library remembers the row you opened (or, in Native, the row
    /// selected as you left), and Native's selection comes back with the Library.
    func navigating(from: Screen, to next: Screen, app: AppState) {
        let nav = NativeNav.shared
        let native = AppLook.current == .native
        if from == .library {
            let key = Self.libraryKey(app.projectFilter)
            if case .transcript(let id) = next {
                rows[key] = id
                if native, nav.librarySelection != id { nav.librarySelection = id }
            } else if native, let s = nav.librarySelection {
                rows[key] = s
            }
        }
        if next == .library, native, let r = rows[Self.libraryKey(app.projectFilter)], nav.librarySelection != r {
            nav.librarySelection = r
        }
    }

    /// Forgets every place (the self-test, so its screenshots open where they always did).
    func reset() {
        offsets = [:]; rows = [:]; days = [:]; tableSelection = []; lastRestore = nil
    }

    fileprivate func register(_ p: ScrollPlace.Probe, _ key: String) { live[key] = WeakProbe(p) }
    fileprivate func restored(_ key: String, _ y: CGFloat, early: Bool) { lastRestore = (key, y, early) }

    /// The live offset of the scroll view on screen under `key` (the self-test).
    func liveOffset(_ key: String) -> CGFloat? { live[key]?.probe?.currentOffset }
    /// Scrolls the scroll view on screen under `key` by `dy` (the self-test).
    func scrollLive(_ key: String, by dy: CGFloat) { live[key]?.probe?.scroll(by: dy) }

    private struct WeakProbe { weak var probe: ScrollPlace.Probe?; init(_ p: ScrollPlace.Probe) { probe = p } }
}

extension View {
    /// Remembers the enclosing scroll view's offset under `key` as the screen leaves, and puts it back when the screen
    /// is built again, before its first frame. In a scroll view's content; `sibling` for a Table, whose scroll view sits
    /// beside its background. `restore` false only remembers (Home comes back to its place only by Back or Forward).
    func scrollPlace(_ key: String, restore: Bool = true, sibling: Bool = false) -> some View {
        background(ScrollPlace(key: key, restore: restore, sibling: sibling))
    }
}

/// The probe behind `scrollPlace`: an empty view in the scroll content that finds its NSScrollView. It saves the offset
/// as it leaves the window, and restores it during the first layout passes (as the lazy content grows to reach it),
/// so the screen's first frame is already there; one turn of the main loop later it checks and gives up.
struct ScrollPlace: NSViewRepresentable {
    var key: String
    var restore: Bool
    var sibling: Bool

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.key = key; p.restore = restore; p.sibling = sibling
        return p
    }

    func updateNSView(_ p: Probe, context: Context) { p.rekey(key) }

    final class Probe: NSView {
        var key = ""
        var restore = true
        var sibling = false
        private weak var scrollView: NSScrollView?
        private var pending: CGFloat?
        private var firstTurn = true
        /// Scrolling lays the content out again, which lands back here.
        private var applying = false
        private var frameObserver: NSObjectProtocol?
        /// For a moment after a restore below the top: a jump back to the very top that isn't you scrolling. Build 222's
        /// Verbose Library ended at the top after restoring 548, with the window itself first responder (no field had
        /// focus). Build 223's 1.2 s hold put back every move instead, so it undid the self-test's own scroll and both
        /// Back checks failed. Now only that jump is caught, once, and logged; any other move ends the watch.
        private var watch: (y: CGFloat, until: Date, docHeight: CGFloat)?
        private var boundsObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The Library showing another project in place: the old project's offset is kept; nothing moves.
        func rekey(_ k: String) {
            guard k != key else { return }
            if pending == nil, let y = currentOffset { ScreenPlaces.shared.setOffset(key, y) }
            key = k
            ScreenPlaces.shared.register(self, k)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                // A restore that never landed keeps the offset it was given.
                if pending == nil, let y = currentOffset { ScreenPlaces.shared.setOffset(key, y) }
                stop()
                endWatch()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            ScreenPlaces.shared.register(self, key)
            scrollView = findScrollView()
            guard restore, let y = ScreenPlaces.shared.offset(key) else { return }
            pending = y
            firstTurn = true
            apply()
            guard pending != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.secondTurn() }
        }

        override func setFrameSize(_ s: NSSize) {
            super.setFrameSize(s)
            apply()
        }

        override func layout() {
            super.layout()
            apply()
        }

        /// One turn of the main loop after the screen came: check the offset held (a late fix-up, never expected), and stop.
        private func secondTurn() {
            firstTurn = false
            guard let y = pending else { return }
            apply()
            if let s = scrollView, pending != nil {
                Log.note("scroll place \(key): restored late (\(Int(y)) of \(Int(maxOffset(s))))")
                ScreenPlaces.shared.restored(key, min(y, maxOffset(s)), early: false)
            }
            stop()
        }

        private func apply() {
            guard let y = pending, !applying else { return }
            applying = true
            defer { applying = false }
            if scrollView == nil { scrollView = findScrollView() }
            guard let s = scrollView, let doc = s.documentView, doc.isFlipped, s.contentView.bounds.height > 1 else { return }
            if frameObserver == nil {
                doc.postsFrameChangedNotifications = true
                frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
            // Each pass scrolls as far as the content goes, which builds the rows there and can grow it; done once the
            // content reaches the offset. Growth that comes later (the next layout pass) calls back in.
            let clip = s.contentView
            for _ in 0..<8 {
                let maxY = maxOffset(s)
                let target = min(y, maxY)
                if abs(clip.bounds.origin.y - target) > 0.5 {
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
                    s.reflectScrolledClipView(clip)
                }
                if maxY + 0.5 >= y {
                    ScreenPlaces.shared.restored(key, y, early: firstTurn)
                    stop()
                    watchForReset(target, s)
                    return
                }
                if maxOffset(s) <= maxY + 0.5 { return }
            }
        }

        private func stop() {
            pending = nil
            if let o = frameObserver { NotificationCenter.default.removeObserver(o); frameObserver = nil }
        }

        private func watchForReset(_ y: CGFloat, _ s: NSScrollView) {
            endWatch()
            let top = -s.contentInsets.top
            guard y > top + 1 else { return }   // restored to the top: nothing to lose
            watch = (y, Date().addingTimeInterval(1.0), s.documentView?.frame.height ?? 0)
            let clip = s.contentView
            clip.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkReset() }
            }
        }

        private func endWatch() {
            watch = nil
            if let o = boundsObserver { NotificationCenter.default.removeObserver(o); boundsObserver = nil }
        }

        private func checkReset() {
            guard let w = watch, !applying, let s = scrollView else { return }
            let clip = s.contentView
            let now = clip.bounds.origin.y
            guard abs(now - w.y) > 1 else { return }
            let top = -s.contentInsets.top
            // Anything but a jump to the very top in the first second is a scroll someone meant: leave it.
            guard Date() <= w.until, abs(now - top) <= 1, !Self.youAreScrolling else { endWatch(); return }
            endWatch()
            let target = min(w.y, maxOffset(s))
            Log.note("scroll place \(key): reset to the top after restoring \(Int(w.y)); put back once (content \(Int(w.docHeight)) then \(Int(s.documentView?.frame.height ?? 0)) tall, event \(NSApp.currentEvent.map { "\($0.type.rawValue)" } ?? "none"), first responder \(window?.firstResponder.map { "\(type(of: $0))" } ?? "none"))")
            applying = true
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            s.reflectScrolledClipView(clip)
            applying = false
        }

        /// A scroll you're making: the wheel or trackpad, a swipe or pinch, dragging the scroller, or a scrolling key.
        private static var youAreScrolling: Bool {
            guard let e = NSApp.currentEvent else { return false }
            switch e.type {
            case .scrollWheel, .swipe, .magnify, .smartMagnify, .leftMouseDragged: return true
            case .keyDown:
                // Arrows, Page Up and Down, Home, End, and Space; not ⌘[ or another shortcut that navigates.
                return !e.modifierFlags.contains(.command) && [123, 124, 125, 126, 116, 121, 115, 119, 49].contains(e.keyCode)
            default: return false
            }
        }

        private func maxOffset(_ s: NSScrollView) -> CGFloat {
            let doc = s.documentView?.frame.height ?? 0
            return max(-s.contentInsets.top, doc - s.contentView.bounds.height + s.contentInsets.bottom)
        }

        var currentOffset: CGFloat? {
            guard let s = scrollView ?? findScrollView(), s.documentView?.isFlipped == true else { return nil }
            return s.contentView.bounds.origin.y
        }

        func scroll(by dy: CGFloat) {
            guard let s = scrollView ?? findScrollView() else { return }
            let clip = s.contentView
            let y = max(-s.contentInsets.top, min(clip.bounds.origin.y + dy, maxOffset(s)))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            s.reflectScrolledClipView(clip)
        }

        /// The scroll view around this probe; for a Table, the one beside it that covers it.
        private func findScrollView() -> NSScrollView? {
            if !sibling { return enclosingScrollView }
            var up: NSView? = superview
            for _ in 0..<5 {
                guard let v = up else { break }
                if let s = Self.scrollView(in: v, covering: convert(bounds, to: nil), depth: 0) { return s }
                up = v.superview
            }
            return nil
        }

        private static func scrollView(in v: NSView, covering r: NSRect, depth: Int) -> NSScrollView? {
            if let s = v as? NSScrollView, s.documentView is NSTableView, s.convert(s.bounds, to: nil).intersects(r) { return s }
            guard depth < 8 else { return nil }
            for sub in v.subviews { if let s = scrollView(in: sub, covering: r, depth: depth + 1) { return s } }
            return nil
        }
    }
}
