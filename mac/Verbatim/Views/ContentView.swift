import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var sidebarOpen = true

    var body: some View {
        if UITest.enabled { Log.note("UITEST render screen=\(screenKey) nav=\(app.navCount)") }
        return HStack(spacing: 0) {
            if sidebarOpen {
                Sidebar().frame(width: 244).transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .identity))
            }
            ZStack {
                Ink.paper
                // Pin each screen to the space it has. Without this a wide screen pushes the whole row
                // outward and the sidebar slides off the left edge.
                GeometryReader { g in
                    screenView.frame(width: g.size.width, height: g.size.height).id(screenKey).transition(transition).zIndex(Double(app.navCount))
                }
            }
            .clipped()
            .animation(Motion.nav, value: app.navCount)
            .overlay(alignment: .bottom) { ToastView() }
        }
        .background(Ink.paper)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(Motion.settle) { sidebarOpen.toggle() } } label: { Image(systemName: "sidebar.left") }
                    .help("Hide or show the sidebar")
            }
        }
        .searchable(text: $app.search, placement: .toolbar, prompt: "Search transcripts")
        .onChange(of: app.search) { _, v in if !v.isEmpty, app.screen != .library { app.go(.library) } }
        .sheet(isPresented: $app.showMicSheet) { MicSheet() }
        .sheet(isPresented: $app.showAppPicker) { AppPickerSheet() }
        .onDrop(of: [.fileURL], isTargeted: nil) { app.handleDrop($0) }
        .onAppear { UITest.run(app: app) }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimOpenSettings)) { _ in openSettings() }
        .tint(Ink.switchOn)   // switches and checkboxes in brand sage instead of the system blue
        .sheet(isPresented: $app.showOnboarding) { OnboardingView(startStep: UITest.onboardingStep).environmentObject(app) }
    }

    private var title: String {
        switch app.screen {
        case .home: return "Verbatim"
        case .library: return app.projectFilter.flatMap { id in app.store.projects.first { $0.id == id }?.name } ?? "Library"
        case .queue: return "Queue"
        case .links: return "Links"
        case .moments: return "Moments"
        case .trash: return "Recently Deleted"
        case .dictionary: return "Dictionary"
        case .dictations: return "Dictations"
        case .activity: return "Activity"
        case .transcript(let id): return app.store.transcript(id)?.title ?? "Transcript"
        }
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
        switch app.screen {
        case .home: HomeView()
        case .library: LibraryView()
        case .queue: QueueView()
        case .links: LinksView()
        case .moments: MomentsView()
        case .trash: TrashView()
        case .dictionary: DictionaryView()
        case .dictations: DictationsView()
        case .activity: ActivityView()
        case .transcript(let id): TranscriptView(id: id)
        }
    }

    /// Slides by direction: push from the right, pop to the right, sidebar order up or down.
    /// Both ends of every transition go through `ScreenSlide`, which turns hit-testing off while a screen is
    /// entering or leaving. An outgoing screen can linger when springs are interrupted, and a lingering screen
    /// that still takes clicks is exactly the "have to click twice" bug.
    private var transition: AnyTransition {
        // Removal is instant on purpose: an outgoing screen that animates can get stuck on top, fully drawn,
        // until the next navigation (seen on macOS 26). The incoming screen still slides and fades in.
        switch app.direction {
        case .push: return .asymmetric(insertion: ScreenSlide.transition(x: 24), removal: .identity)
        case .pop: return .asymmetric(insertion: ScreenSlide.transition(x: -24), removal: .identity)
        case .up: return .asymmetric(insertion: ScreenSlide.transition(y: 14), removal: .identity)
        case .down: return .asymmetric(insertion: ScreenSlide.transition(y: -14), removal: .identity)
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
