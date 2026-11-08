import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) var app
    @Environment(\.openSettings) private var openSettings
    @State private var newProjectName = ""
    @ObservedObject private var rename = RenameCenter.shared
    @Environment(\.limitMotion) private var limitMotion
    /// The sidebar's visibility (NavigationSplitView).
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The window's shared state (toolbar, inspector, Library selection). Held without observing it: only the views
    /// that show a part of it re-render when it changes.
    @State private var windowNav = WindowNav.shared

    var body: some View {
        if UITest.enabled { Log.note("UITEST render screen=\(screenKey) nav=\(app.navCount)") }
        NavMarks.mark("main")
        return main.environmentObject(windowNav)
        // The "link added" card, in this view's coordinate space so its tile can fly from the content into the
        // sidebar's Queue item (anchored by the sidebar; no flight when the sidebar is hidden).
        .overlayPreferenceValue(QueueItemAnchor.self) { anchor in
            GeometryReader { g in
                if let id = app.linkCardID, let imp = app.linkImports[id] {
                    LinkCardOverlay(imp: imp, metrics: .mac,
                                    target: anchor.map { g[$0] }.map { CGPoint(x: $0.midX, y: $0.midY) },
                                    scrimRect: CGRect(x: 0, y: 0, width: g.size.width, height: g.size.height),
                                    onCancel: { app.cancelLinkCard(id) },
                                    onRetry: { app.retryLinkCard(id) },
                                    onLanded: { app.linkCardLanded(id) },
                                    onClosed: { app.closeLinkCard(id) },
                                    fromKeyboard: app.linkCardFromKeyboard)
                        .id(id)
                }
            }
        }
        .background(Refined.paper)
        .background(WindowReader { w in if app.mainWindow !== w { app.mainWindow = w } })
        // Search or ask: the panel over the window (Views/AskViews.swift), from ⌘K or from typing in the toolbar's
        // search field (MAC-35).
        .overlay { AskPanelLayer() }
        .sheet(isPresented: Bindable(app).showMicSheet) { MicSheet() }
        .sheet(isPresented: Bindable(app).showAppPicker) { AppPickerSheet() }
        .sheet(item: Bindable(app).multitrackDraft) { d in MultitrackSheet(draft: d).appState(app) }
        .sheet(item: Bindable(app).exportRequest) { r in ExportSheet(ids: r.ids).appState(app) }
        .sheet(item: Binding(get: { app.signInRequest }, set: { if $0 == nil, app.signInRequest != nil { app.cancelSignIn() } })) { r in
            SignInSheet(request: r).appState(app)
        }
        .sheet(isPresented: Binding(get: { app.addFromLibrary != nil }, set: { if !$0 { app.addFromLibrary = nil } })) {
            if let p = app.addFromLibrary { AddFromLibrarySheet(project: p).appState(app) }
        }
        .alert("New project", isPresented: Binding(get: { app.newProjectFor != nil }, set: { if !$0 { app.newProjectFor = nil } })) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) { newProjectName = "" }
            Button("Create") {
                // A project started empty opens in the Library; a row's transcript joins it instead.
                if let ids = app.newProjectFor { app.createProject(newProjectName, adding: ids) }
                newProjectName = ""
            }
        } message: {
            // Library's New project starts one with nothing in it; a row's menu brings its transcript along.
            Text(app.newProjectFor?.isEmpty == false ? "The transcript joins the new project." : "Group transcripts by client or job. Drag transcripts onto it in the sidebar.")
        }
        .alert("Rename transcript", isPresented: Binding(get: { rename.target != nil }, set: { if !$0 { rename.target = nil } })) {
            TextField("Title", text: $rename.draft)
            Button("Cancel", role: .cancel) { rename.target = nil }
            Button("Rename") { rename.commit(app.store) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { app.handleDrop($0) }
        .onAppear { LaunchClock.rootAppeared(); UITest.run(app: app); app.installLinkPasteMonitor(); NavTrail.shared.installMonitor(app); ToastUndoKey.shared.install(app); SearchPanelKeys.shared.install(app) }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimOpenSettings)) { _ in openSettings() }
        // The chrome takes the accent (DESIGN.md §13): toolbar buttons, menus, and selection. Mac switches take
        // `macSwitch` where they're drawn (`refinedSwitchTint()`).
        .tint(Refined.accentText)
        .sheet(isPresented: Bindable(app).showOnboarding) { OnboardingView(startStep: UITest.onboardingStep).appState(app) }
    }

    /// The window (MacChrome.swift): the split view with the refined sidebar, one toolbar with Back and Forward, Record,
    /// the screen's items, and the search field, and one inspector.
    private var main: some View {
        MacWindow(nav: windowNav, columns: $columns) { detail }
            // The toolbar's field opens Search or ask (MAC-35): its words go to the panel, which lists recordings and
            // passages, so the Library never filters under you while you type. Return opens the chosen result, or
            // asks; ↓ and ↑ move through the results (Views/SearchPanelKeys.swift).
            .searchable(text: Bindable(app).toolbarQuery, placement: .toolbar, prompt: ToolbarSearchPrompt.prompt)
            .onSubmit(of: .search) { AskNav.shared.submit(app, fromToolbar: true) }
            .onChange(of: app.toolbarQuery) { _, v in AskNav.shared.toolbarChanged(v) }
            // The prompt in `mute` once the toolbar exists, and again after each screen change (MacChrome.swift).
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ToolbarSearchPrompt.apply(to: app.mainWindow) } }
            .onChange(of: app.navCount) { _, _ in DispatchQueue.main.async { ToolbarSearchPrompt.apply(to: app.mainWindow) } }
    }

    /// The screen. One screen is in the window at a time: a navigation swaps the screen in a transaction with no
    /// animation, so the outgoing screen leaves the hierarchy in the same update the new one arrives. (Build 215 and
    /// earlier faded the new screen in over the old on `navCount`: with an animated transaction, SwiftUI keeps a removed
    /// view until the animation ends, even with an `.identity` removal, so both screens showed for 120 to 150 ms and the
    /// outgoing one re-rendered with the navigation's publish.) Each screen draws its own paper, so it is opaque from its
    /// first frame. Only the new screen moves (`ScreenEntrance`), on a spring with a slight bounce: opening or leaving a
    /// transcript slides it in from the side, and a sidebar move rises or drops 14 pt (behind `PageFade.enabled`), opaque
    /// from its first frame. Nothing waits for it, and Limit Motion only fades.
    /// Record lives in the toolbar (MacChrome.swift), so nothing floats over the content.
    private var detail: some View {
        ZStack {
            Refined.paper.ignoresSafeArea()
            // Pin each screen to the space it has, so a wide screen never pushes the window's columns.
            GeometryReader { g in
                screenView.frame(width: g.size.width, height: g.size.height)
                    .background(Refined.paper)
                    .modifier(ScreenEntrance(offset: entranceOffset, limited: entrance == .fade))
                    // Each screen change is timed from the click to here: a "Navigate" signpost always, and a
                    // UITEST TIMING line in the self-test.
                    .onAppear {
                        NavMarks.mark("screen-appear")
                        app.screenAppeared(); if UITest.enabled { UITest.screenAppeared(screenKey, nav: app.navCount, since: app.navStartedAt, window: app.mainWindow) }
                    }
                    .screenRootMarker(screenKey)
                    .id(screenKey)
                    .transition(.identity)
            }
            // The navigation's own transaction never animates, whoever called `go`: no removal can linger.
            .transaction(value: app.navCount) { t in
                t.animation = nil
                t.disablesAnimations = true
            }
        }
        .clipped()
        .overlay(alignment: .bottom) { ToastView() }
    }

    private var screenKey: String {
        switch app.screen {
        case .home: return "home"
        case .library: return "library"
        case .queue: return "queue"
        case .trash: return "trash"
        case .dictionary: return "dict"
        case .dictations: return "dictations"
        case .activity: return "activity"
        case .byDay(let k): return k == .journal ? "byday-journal" : "byday-thoughts"
        case .templates: return "templates"
        case .ask: return "ask"
        case .transcript(let id): return "t-\(id)"
        }
    }

    @ViewBuilder private var screenView: some View {
        // Until the library has loaded at launch: the screen's background and, after a moment, a small spinner.
        if !app.store.isLoaded { LibraryLoadingView() } else { screen }
    }

    @ViewBuilder private var screen: some View {
        switch app.screen {
        case .home: HomeView()
        // The Library (DESIGN.md §6.8).
        case .library: LibraryView()
        case .queue: QueueView()
        case .trash: TrashView()
        case .dictionary: DictionaryView()
        case .dictations: DictationsView()
        case .activity: YouView()
        case .byDay(let k): ByDayView(kind: k)
        case .templates: TemplatesView()
        case .ask: AskView()
        case .transcript(let id):
            // Audio only with no words yet: its own screen (MacAudioDetail.swift), until Transcribe brings the words.
            if app.store.transcript(id)?.showsAudioDetail == true { MacAudioDetail(id: id) } else { TranscriptView(id: id) }
        }
    }

    /// How the new screen arrives (`NavEntrance`): at once at launch and after a navigation from the keyboard, faded
    /// in under Limit Motion, slid in otherwise.
    private var entrance: NavEntrance {
        NavEntrance.of(launch: app.navCount == 0, keyboard: app.nav.keyboard, limited: limitMotion)
    }

    /// Where the new screen starts. Opening a transcript slides it in from the right, and leaving one slides the screen in
    /// from the left (`Motion.pageTravel`). A sidebar move rises from below when you go down the sidebar and drops from
    /// above when you go up (`Motion.sidebarTravel`). The launch screen, a navigation from the keyboard, and Limit Motion
    /// don't move.
    private var entranceOffset: CGSize {
        if entrance != .slide { return .zero }
        switch app.direction {
        case .push: return CGSize(width: Motion.pageTravel, height: 0)
        case .pop: return CGSize(width: -Motion.pageTravel, height: 0)
        case .up: return PageFade.enabled ? CGSize(width: 0, height: Motion.sidebarTravel) : .zero
        case .down: return PageFade.enabled ? CGSize(width: 0, height: -Motion.sidebarTravel) : .zero
        }
    }
}

/// A new screen's entrance: it starts `offset` away and settles on `Motion.page`, a spring with a slight bounce. It's
/// opaque from its first frame: build 292's sidebar moves also faded in from clear, which read as the page loading in.
/// With motion limited it only fades in, over `Motion.fade`. With no offset and no fade (launch, or a navigation from
/// the keyboard), it's simply there.
///
/// The spring starts on the main loop's next turn, after the new screen's first frame is committed, not in `onAppear`.
/// Building and committing a screen like Library or You takes 80 to 180 ms after `onAppear` (the self-test's
/// `UITEST TIMING ... settled=`). A spring started in `onAppear` ran its clock through that stall, so the first frame
/// you saw was already partway through and the page jumped (Tim, build 293: "jolty"). Started after the commit, every
/// frame of the spring is drawn. It runs in a transaction of its own, so the navigation's transaction stays unanimated
/// and the outgoing screen is gone at once. Clicks reach the screen from its first frame.
struct ScreenEntrance: ViewModifier {
    /// Where the screen starts, taken once when the screen is made (a later change of direction or Limit Motion
    /// doesn't move a screen that's already there).
    @State private var offset: CGSize
    @State private var shown: Bool
    private let limited: Bool
    init(offset: CGSize, limited: Bool) {
        _offset = State(initialValue: offset)
        _shown = State(initialValue: !limited)
        self.limited = limited
    }

    func body(content: Content) -> some View {
        content
            .offset(offset)
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard offset != .zero || !shown else { return }
                DispatchQueue.main.async {
                    withAnimation(limited ? Motion.fade : Motion.page) { offset = .zero; shown = true }
                }
            }
    }
}

/// The sidebar's page motion (DESIGN.md §7). One switch: set `enabled` to false and every sidebar move is instant again.
///
/// Risk: macOS 26 left a stale screen in the window when `AppState.go()` changed the screen inside `withAnimation`
/// (builds 215 and earlier). This motion never animates the navigation's own transaction. The outgoing screen still
/// leaves in the same unanimated update; only the incoming screen's offset animates, started after its first frame
/// (`ScreenEntrance`). If a stale or doubled screen ever shows again after a sidebar move, turn this off first.
enum PageFade {
    static let enabled = true
}

/// Marks a screen's root for the self-test, which counts the screens in the window right after a navigation
/// (`UITest.screenRoots`): a removed screen that lingers keeps its marker view in the window. Adds nothing outside the
/// self-test.
private struct ScreenRootMarker: NSViewRepresentable {
    var key: String
    func makeNSView(context: Context) -> ScreenRootMarkerView {
        let v = ScreenRootMarkerView()
        v.key = key
        return v
    }
    func updateNSView(_ v: ScreenRootMarkerView, context: Context) { v.key = key }
}

final class ScreenRootMarkerView: NSView {
    var key = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    @ViewBuilder func screenRootMarker(_ key: String) -> some View {
        if UITest.enabled { background(ScreenRootMarker(key: key)) } else { self }
    }

    /// A navigation mark (`NavMarks.mark`) once this view has been measured: a reader in its background is sized after
    /// it. For the self-test's per-step marks; adds nothing outside the self-test.
    @ViewBuilder func navMarkWhenLaidOut(_ name: String) -> some View {
        if UITest.enabled { background(GeometryReader { _ in let _ = NavMarks.mark(name); Color.clear }) } else { self }
    }
}
