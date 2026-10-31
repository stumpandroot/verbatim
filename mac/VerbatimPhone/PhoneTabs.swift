import SwiftUI

// The iPhone's tabs (Settings › Personalization and preferences › Tab bar, PhoneTabBar.swift): Home first, then up to
// four you pick, each with its own navigation stack. Settings isn't a tab: it opens as a sheet (`openSettings`). A screen asked for whose tab isn't in
// the bar (Home's Journal tile with no Journal tab) opens pushed inside Library, or inside Home when Library isn't in the
// bar either, rather than failing. Moments became the Library's Marked filter in the consolidation (October 28, 2026).

/// The Library pushed inside another tab: when Library isn't in the bar, or a project from the Projects tab. `request`
/// is a `libraryFilterRequest` ("working", "project:<id>", or a kind's raw value).
struct LibraryRoute: Hashable { var request: String? = nil }

extension PhoneTab {
    /// The tab's fine-line glyph in the tab bar. Journal is the Mac sidebar's journal glyph.
    var art: BrandArt {
        switch self {
        case .home: return .iconHome
        case .library: return .iconLibrary
        case .thoughts: return .iconThought
        case .journal: return .iconNotes
        case .dictations: return .iconDictations
        case .projects: return .iconProject
        }
    }

}

extension PhoneState {
    // MARK: Paths

    /// A tab's navigation path.
    func path(_ t: Tab) -> NavigationPath {
        switch t {
        case .home: return homePath
        case .library: return libraryPath
        case .thoughts: return thoughtsPath
        case .journal: return journalPath
        case .dictations: return dictationsPath
        case .projects: return projectsPath
        }
    }

    func setPath(_ t: Tab, _ p: NavigationPath) {
        switch t {
        case .home: homePath = p
        case .library: libraryPath = p
        case .thoughts: thoughtsPath = p
        case .journal: journalPath = p
        case .dictations: dictationsPath = p
        case .projects: projectsPath = p
        }
    }

    /// Pushes a screen on a tab's stack.
    func push<V: Hashable>(_ value: V, on t: Tab) {
        var p = path(t)
        p.append(value)
        setPath(t, p)
    }

    /// Pushes a screen on the tab on screen. From Settings, the sheet closes and it goes where the Library would
    /// (Library, else Home).
    func pushHere<V: Hashable>(_ value: V) {
        if showSettings { showSettings = false; tab = tabBar.host(for: .library) }
        push(value, on: tab)
    }

    // MARK: Settings

    /// Settings, as a sheet over the tab you're on (the round button beside Home's date; October 31, 2026, as in
    /// Verbose Tasks). `page` opens one of its pages on the way ("you", "keyboard", "whatsNew"); with Settings already
    /// open, the page opens there.
    func openSettings(page: String? = nil) {
        if let page { SettingsPage.open(page) }
        if !showSettings { showSettings = true }
    }

    /// Closes Settings, then runs `next` once the sheet has gone: the recorder, live captions, and the welcome tour
    /// present from the root, which can't show one sheet over another. With Settings closed, `next` runs at once.
    func closeSettings(then next: (() -> Void)? = nil) {
        guard showSettings else { next?(); return }
        showSettings = false
        if let next { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: next) }
    }

    /// A tab's binding for its NavigationStack.
    func pathBinding(_ t: Tab) -> Binding<NavigationPath> {
        Binding(get: { [unowned self] in self.path(t) }, set: { [unowned self] in self.setPath(t, $0) })
    }

    // MARK: The bar

    /// Saves the tabs after Home. A tab that left the bar loses its stack; if it was on screen, Home
    /// comes up.
    func setTabBar(_ middle: [Tab]) {
        let old = tabBar
        tabBarStore.set(middle)
        let now = tabBar
        guard now != old else { return }
        for t in old.tabs where !now.contains(t) { setPath(t, NavigationPath()) }
        let keep = now.selection(keeping: tab)
        if keep != tab { tab = keep }
        Log.note("tab bar: \(now.tabs.map(\.rawValue).joined(separator: ", "))")
    }

    // MARK: Going places

    /// The Library on its Marked chip: the recordings with a moment (the Moments screen's place since the
    /// consolidation).
    func openMarked() { go(.library, filter: "source:" + LibrarySource.marked.rawValue) }

    /// Opens a tab's screen: the tab itself when it's in the bar; otherwise its screen pushed inside Library, or Home.
    /// `filter` opens the Library on a chip (`libraryFilterRequest`).
    func go(_ t: Tab, filter: String? = nil) {
        closeSettings()
        let bar = tabBar
        switch t {
        case .home:
            tab = t
        case .library:
            if bar.contains(.library) {
                if let filter { libraryFilterRequest = filter }
                tab = .library
            } else {
                push(LibraryRoute(request: filter), on: .home)
                tab = .home
            }
        case .dictations:
            let host = bar.host(for: .dictations)
            if host == .dictations {
                dictationsPath = NavigationPath()
            } else {
                if host == .library { libraryPath = NavigationPath() }
                push(DictationsRoute(), on: host)
            }
            tab = host
        case .projects:
            if bar.contains(.projects) { tab = .projects } else { go(.library) }
        case .thoughts:
            openThoughtPage()
        case .journal:
            let host = bar.host(for: .journal)
            if host == .journal { journalPath = NavigationPath() } else { push(ByDayRoute(kind: .journal), on: host) }
            tab = host
        }
    }
}

// MARK: - Routes on every stack

extension View {
    /// The screens any tab's stack can push, so a screen opens wherever it's asked for.
    func phoneRoutes() -> some View {
        navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
            .navigationDestination(for: DocumentRoute.self) { TranscriptScreen(id: $0.id, startMode: .document) }
            .navigationDestination(for: DictationsRoute.self) { _ in DictationsListScreen() }
            .navigationDestination(for: HomeDictionaryRoute.self) { _ in DictionaryScreen() }
            .navigationDestination(for: ByDayRoute.self) { r in ByDayScreen(kind: r.kind) }
            .navigationDestination(for: DayPageRoute.self) { r in DayPageScreen(kind: r.kind, day: r.day).id(r) }
            .navigationDestination(for: ThoughtsPlanRoute.self) { r in ThoughtsPlanScreen(day: r.day) }
            .navigationDestination(for: LibraryRoute.self) { r in LibraryScreen(route: r) }
            .navigationDestination(for: TemplatesRoute.self) { _ in TemplatesScreen() }
            .navigationDestination(for: TemplateDetailRoute.self) { r in TemplateDetailScreen(id: r.id) }
            .navigationDestination(for: TemplatesAutoRoute.self) { _ in TemplatesAutoScreen() }
            .navigationDestination(for: AskRoute.self) { r in AskScreen(route: r) }
            .navigationDestination(for: RecipesRoute.self) { _ in RecipesScreen() }
            .navigationDestination(for: RecipeRoute.self) { r in RecipeScreen(id: r.id) }
    }
}

// MARK: - Projects tab

/// The Projects tab (refined kit, DESIGN.md §13): the large serif "Projects" with the count, then each project in a card
/// with its folder square and how many recordings it holds, and New project in the navigation bar. A project opens the
/// Library on it, inside this tab. With none, one card says what projects are and offers New project.
struct ProjectsScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var newProject = false
    @State private var projectName = ""
    /// For the self-test: whether the Projects tab's root is on screen.
    static var visible = false

    var body: some View {
        let counts = app.store.memo("phone.project-counts") { () -> [UUID: Int] in
            var counts: [UUID: Int] = [:]
            for t in app.store.live where !t.isDictation { if let p = t.projectId { counts[p, default: 0] += 1 } }
            return counts
        }
        let projects = app.store.projects
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LargeSerifTitle(title: "Projects", count: HomeCounts.countLabel(projects.count, "project", "projects"))
                    .accessibilityElement(children: .combine)
                if projects.isEmpty {
                    RefinedEmptyState(art: .iconProject, hue: .sage, title: "No projects yet",
                                      message: "Projects group recordings. Make one here, or from a recording's menu.",
                                      action: "New project") { newProject = true }
                } else {
                    PaperList(projects, id: \.id, inset: 56) { p in
                        NavigationLink(value: LibraryRoute(request: "project:\(p.id.uuidString)")) {
                            IconSquareRow(art: .iconProject, hue: .sage, title: p.name,
                                          value: HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings"))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the project in your library.")
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newProject = true } label: { Image(systemName: "plus") }.accessibilityLabel("New project")
            }
        }
        .alert("New project", isPresented: $newProject) {
            TextField("Name", text: $projectName)
            Button("Cancel", role: .cancel) { projectName = "" }
            Button("Create") {
                let n = projectName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { _ = app.store.addProject(n) }
                projectName = ""
            }
        }
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }
}
