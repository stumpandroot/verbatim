import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
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
                                    onClosed: { app.closeLinkCard(id) })
                        .id(id)
                }
            }
        }
        .background(Refined.paper)
        .background(WindowReader { w in if app.mainWindow !== w { app.mainWindow = w } })
        // Search or ask (⌘K): the panel over the window (Views/AskViews.swift). The toolbar's search field is the
        // window's one search field; Return there asks.
        .overlay { AskPanelLayer() }
        .onChange(of: app.search) { _, v in if !v.isEmpty, app.screen != .library { app.go(.library) } }
        .sheet(isPresented: $app.showMicSheet) { MicSheet() }
        .sheet(isPresented: $app.showAppPicker) { AppPickerSheet() }
        .sheet(item: $app.multitrackDraft) { d in MultitrackSheet(draft: d).environmentObject(app) }
        .sheet(item: $app.exportRequest) { r in ExportSheet(ids: r.ids).environmentObject(app) }
        .sheet(item: Binding(get: { app.signInRequest }, set: { if $0 == nil, app.signInRequest != nil { app.cancelSignIn() } })) { r in
            SignInSheet(request: r).environmentObject(app)
        }
        .sheet(isPresented: Binding(get: { app.addFromLibrary != nil }, set: { if !$0 { app.addFromLibrary = nil } })) {
            if let p = app.addFromLibrary { AddFromLibrarySheet(project: p).environmentObject(app) }
        }
        .alert("New project", isPresented: Binding(get: { app.newProjectFor != nil }, set: { if !$0 { app.newProjectFor = nil } })) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) { newProjectName = "" }
            Button("Create") {
                let n = newProjectName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty, let ids = app.newProjectFor {
                    let project = app.store.addProject(n)
                    if !ids.isEmpty { app.addToProject(ids, project.id) }
                }
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
        .onAppear { LaunchClock.rootAppeared(); UITest.run(app: app); app.installLinkPasteMonitor(); NavTrail.shared.installMonitor(app) }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimOpenSettings)) { _ in openSettings() }
        // The chrome takes the accent (DESIGN.md §13): toolbar buttons, menus, and selection. Mac switches take
        // `macSwitch` where they're drawn (`refinedSwitchTint()`).
        .tint(Refined.accentText)
        .sheet(isPresented: $app.showOnboarding) { OnboardingView(startStep: UITest.onboardingStep).environmentObject(app) }
    }

    /// The window (MacChrome.swift): the split view with the refined sidebar, one toolbar with Back and Forward, Record,
    /// the screen's items, and the search field, and one inspector.
    private var main: some View {
        MacWindow(nav: windowNav, columns: $columns) { detail }
            .searchable(text: $app.search, placement: .toolbar, prompt: "Search or ask")
            .onSubmit(of: .search) { AskNav.shared.open(mode: .ask, query: app.search, askNow: true) }
    }

    /// The screen. One screen is in the window at a time: a navigation swaps the screen in a transaction with no
    /// animation, so the outgoing screen leaves the hierarchy in the same update the new one arrives. (Build 215 and
    /// earlier faded the new screen in over the old on `navCount`: with an animated transaction, SwiftUI keeps a removed
    /// view until the animation ends, even with an `.identity` removal, so both screens showed for 120 to 150 ms and the
    /// outgoing one re-rendered with the navigation's publish.) Each screen draws its own paper, so it is opaque from its
    /// first frame. Opening or leaving a transcript still slides it 12 pt (`ScreenEntrance`); sidebar moves are instant,
    /// as switching tabs is a frequent action (motion rules: never animate those), and Limit Motion is instant for all.
    /// Record lives in the toolbar (MacChrome.swift), so nothing floats over the content.
    private var detail: some View {
        ZStack {
            Refined.paper.ignoresSafeArea()
            // Pin each screen to the space it has, so a wide screen never pushes the window's columns.
            GeometryReader { g in
                screenView.frame(width: g.size.width, height: g.size.height)
                    .background(Refined.paper)
                    .modifier(ScreenEntrance(x: entranceOffset))
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

    /// Opening a transcript slides it in 12 pt from the right, and leaving one slides the screen in from the left; sidebar
    /// moves and Limit Motion don't move at all.
    private var entranceOffset: CGFloat {
        if limitMotion { return 0 }
        switch app.direction {
        case .push: return 12
        case .pop: return -12
        case .up, .down: return 0
        }
    }
}

/// A transcript's short entrance: the screen starts `x` points over and settles in 150 ms, ease-out, opaque all the way
/// (no fade). It runs from the screen's own `onAppear`, in a transaction of its own, so the navigation's transaction
/// stays unanimated and the outgoing screen is gone at once. Until it appears the screen takes no clicks (what
/// `ScreenSlide` did for a lingering screen; nothing lingers now).
struct ScreenEntrance: ViewModifier {
    /// Where the screen starts, taken once when the screen is made (a later change of direction or Limit Motion
    /// doesn't move a screen that's already there).
    @State private var x: CGFloat
    init(x: CGFloat) { _x = State(initialValue: x) }

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .allowsHitTesting(x == 0)
            .onAppear {
                guard x != 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) { x = 0 }
            }
    }
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
