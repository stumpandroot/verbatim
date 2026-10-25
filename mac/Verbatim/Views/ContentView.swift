import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var sidebarOpen = true
    @State private var newProjectName = ""
    @ObservedObject private var rename = RenameCenter.shared
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look
    /// The Native sidebar's visibility (NavigationSplitView); Verbose style uses `sidebarOpen`.
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The Native window's shared state (toolbar, inspector, Library selection). Held without observing it: only the
    /// views that show a part of it re-render when it changes.
    @State private var nativeNav = NativeNav.shared

    var body: some View {
        if UITest.enabled { Log.note("UITEST render screen=\(screenKey) nav=\(app.navCount)") }
        // Only the main content rebuilds when the look changes (LookRebuild); the sheets below stay open.
        return main.environmentObject(nativeNav).lookRebuild()
        // The "link added" card, in this view's coordinate space so its tile can fly from the content into the
        // sidebar's Queue item (anchored by the sidebar; no flight when the sidebar is hidden).
        .overlayPreferenceValue(QueueItemAnchor.self) { anchor in
            GeometryReader { g in
                if let id = app.linkCardID, let imp = app.linkImports[id] {
                    let side: CGFloat = look == .native ? 0 : (sidebarOpen ? 244 : 0)
                    LinkCardOverlay(imp: imp, metrics: .mac,
                                    target: anchor.map { g[$0] }.map { CGPoint(x: $0.midX, y: $0.midY) },
                                    scrimRect: CGRect(x: side, y: 0, width: max(0, g.size.width - side), height: g.size.height),
                                    onCancel: { app.cancelLinkCard(id) },
                                    onRetry: { app.retryLinkCard(id) },
                                    onLanded: { app.linkCardLanded(id) },
                                    onClosed: { app.closeLinkCard(id) })
                        .id(id)
                }
            }
        }
        .background(Ink.paper)
        .background(WindowReader { w in if app.mainWindow !== w { app.mainWindow = w } })
        .searchable(text: $app.search, placement: .toolbar, prompt: "Search transcripts")
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
        .onAppear { LaunchClock.rootAppeared(); UITest.run(app: app); app.installLinkPasteMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimOpenSettings)) { _ in openSettings() }
        .lookTint(look)   // switches and checkboxes in brand sage (Verbose style) or the persimmon accent (Native)
        .sheet(isPresented: $app.showOnboarding) { OnboardingView(startStep: UITest.onboardingStep).environmentObject(app).lookRoot() }
    }

    /// The sidebar and the screen: Verbose style's paper sidebar beside the screen, or Native's NavigationSplitView
    /// with the standard sidebar (Settings lives in the app menu there, ⌘,), its one toolbar, and its inspector
    /// (NativeChrome.swift).
    @ViewBuilder private var main: some View {
        if look == .native {
            NativeWindow(nav: nativeNav, columns: $columns) { nativeDetail }
        } else {
            HStack(spacing: 0) {
                if sidebarOpen {
                    Sidebar().frame(width: 244).transition(.asymmetric(insertion: limitMotion ? .opacity : .move(edge: .leading).combined(with: .opacity), removal: .identity))
                }
                detail
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { withAnimation(Motion.settle) { sidebarOpen.toggle() } } label: { Image(systemName: "sidebar.left") }
                        .help("Hide or show the sidebar")
                }
            }
        }
    }

    /// Native's screen: swapped in place, with no transition or animation, as Mail and Notes do. The id gives each
    /// screen (and each transcript) its own identity, so its `onAppear` times the change. Premium Native's warm
    /// background and glow sit behind every screen, and the record button floats over Home and the Library.
    private var nativeDetail: some View {
        ZStack {
            PremiumBackground()
            screenView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { app.screenAppeared(); if UITest.enabled { UITest.screenAppeared(screenKey, nav: app.navCount, since: app.navStartedAt) } }
                .id(screenKey)
        }
        .overlay(alignment: .bottomTrailing) {
            if (app.screen == .home || app.screen == .library) && !app.recorder.isRecording && !app.capture.isCapturing {
                PremiumRecordButton(label: app.screen == .home).padding(.trailing, 28).padding(.bottom, 26)
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
    }

    private var detail: some View {
        ZStack {
            Ink.paper
            // Pin each screen to the space it has. Without this a wide screen pushes the whole row
            // outward and the sidebar slides off the left edge.
            GeometryReader { g in
                screenView.frame(width: g.size.width, height: g.size.height)
                    // Each screen change is timed from the click to here: a "Navigate" signpost always, and a
                    // UITEST TIMING line in the self-test.
                    .onAppear { app.screenAppeared(); if UITest.enabled { UITest.screenAppeared(screenKey, nav: app.navCount, since: app.navStartedAt) } }
                    .id(screenKey).transition(transition).zIndex(Double(app.navCount))
            }
        }
        .clipped()
        .animation(navAnimation, value: app.navCount)
        .overlay(alignment: .bottom) { ToastView() }
    }

    private var screenKey: String {
        switch app.screen {
        case .home: return "home"
        case .library: return "library"
        case .queue: return "queue"
        case .links: return "links"
        case .moments: return "moments"
        case .trash: return "trash"
        case .dictionary: return "dict"
        case .dictations: return "dictations"
        case .activity: return "activity"
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
        case .library: if look == .native { NativeLibraryView() } else { LibraryView() }
        case .queue: QueueView()
        case .links: LinksView()
        case .moments: MomentsView()
        case .trash: TrashView()
        case .dictionary: DictionaryView()
        case .dictations: DictationsView()
        case .activity: YouView()
        case .transcript(let id): TranscriptView(id: id)
        }
    }

    /// Screen changes are quick (motion rules: navigation never makes you wait). Sidebar moves are a 120 ms crossfade;
    /// opening or leaving a transcript also moves 12 pt over 150 ms, so it still reads as going in and coming back.
    private var navAnimation: Animation {
        switch app.direction {
        case .push, .pop: return limitMotion ? Self.navFade : .easeOut(duration: 0.15)
        case .up, .down: return Self.navFade
        }
    }
    private static let navFade = Animation.easeOut(duration: 0.12)

    /// Fades in; a transcript also slides in from the right (push) or the left (pop). Sidebar moves only fade.
    /// Both ends of every transition go through `ScreenSlide`, which turns hit-testing off while a screen is
    /// entering or leaving. An outgoing screen can linger when springs are interrupted, and a lingering screen
    /// that still takes clicks is exactly the "have to click twice" bug.
    private var transition: AnyTransition {
        // Removal is instant on purpose: an outgoing screen that animates can get stuck on top, fully drawn,
        // until the next navigation (seen on macOS 26). The incoming screen still slides and fades in.
        // Limit Motion: a crossfade, nothing moves.
        if limitMotion { return .asymmetric(insertion: ScreenSlide.transition(), removal: .identity) }
        switch app.direction {
        case .push: return .asymmetric(insertion: ScreenSlide.transition(x: 12), removal: .identity)
        case .pop: return .asymmetric(insertion: ScreenSlide.transition(x: -12), removal: .identity)
        case .up, .down: return .asymmetric(insertion: ScreenSlide.transition(), removal: .identity)
        }
    }
}

/// A slide-and-fade whose off-screen state cannot be clicked.
struct ScreenSlide: ViewModifier {
    var active: Bool
    var x: CGFloat = 0
    var y: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .offset(x: active ? x : 0, y: active ? y : 0)
            .opacity(active ? 0 : 1)
            .allowsHitTesting(!active)
    }
    static func transition(x: CGFloat = 0, y: CGFloat = 0) -> AnyTransition {
        .modifier(active: ScreenSlide(active: true, x: x, y: y), identity: ScreenSlide(active: false, x: x, y: y))
    }
}
