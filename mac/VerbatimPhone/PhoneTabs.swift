import SwiftUI

// The iPhone's tabs (Settings › Personalization and preferences › Tab bar, PhoneTabBar.swift): Home first, Settings
// last, and up to three you pick between them, each with its own navigation stack. A screen asked for whose tab isn't in
// the bar (a Moments link, Home's Journal tile with no Journal tab) opens pushed inside Library, or inside Home when
// Library isn't in the bar either, rather than failing. With the default bar (Library, Moments) every path is the one
// it always was.

/// Moments pushed inside another tab, when Moments isn't in the bar.
struct MomentsRoute: Hashable {}

/// The Library pushed inside another tab: when Library isn't in the bar, or a project from the Projects tab. `request`
/// is a `libraryFilterRequest` ("working", "project:<id>", or a kind's raw value).
struct LibraryRoute: Hashable { var request: String? = nil }

extension PhoneTab {
    /// The tab's line icon in Verbose style: BrandArt, as the other tabs use. Journal is the Mac sidebar's journal glyph.
    var art: BrandArt {
        switch self {
        case .home: return .iconHome
        case .library: return .iconLibrary
        case .thoughts: return .iconThought
        case .journal: return .iconNotes
        case .moments: return .iconMoments
        case .dictations: return .iconDictations
        case .projects: return .iconProject
        case .settings: return .iconSettings
        }
    }

    // brand: native begin
    /// The tab's SF Symbol in Native.
    var symbol: String {
        switch self {
        case .home: return "house"
        case .library: return "books.vertical"
        case .thoughts: return "lightbulb"
        case .journal: return "book"
        case .moments: return "bookmark"
        case .dictations: return "text.bubble"
        case .projects: return "folder"
        case .settings: return "gearshape"
        }
    }
    // brand: native end
}

extension PhoneState {
    // MARK: Paths

    /// A tab's navigation path. Settings keeps its own (SettingsScreen's pages), so it has none here.
    func path(_ t: Tab) -> NavigationPath {
        switch t {
        case .home: return homePath
        case .library: return libraryPath
        case .moments: return momentsPath
        case .thoughts: return thoughtsPath
        case .journal: return journalPath
        case .dictations: return dictationsPath
        case .projects: return projectsPath
        case .settings: return NavigationPath()
        }
    }

    func setPath(_ t: Tab, _ p: NavigationPath) {
        switch t {
        case .home: homePath = p
        case .library: libraryPath = p
        case .moments: momentsPath = p
        case .thoughts: thoughtsPath = p
        case .journal: journalPath = p
        case .dictations: dictationsPath = p
        case .projects: projectsPath = p
        case .settings: break
        }
    }

    /// Pushes a screen on a tab's stack.
    func push<V: Hashable>(_ value: V, on t: Tab) {
        var p = path(t)
        p.append(value)
        setPath(t, p)
    }

    /// Pushes a screen on the tab on screen. From Settings, it goes where the Library would (Library, else Home).
    func pushHere<V: Hashable>(_ value: V) {
        if tab == .settings { tab = tabBar.host(for: .library) }
        push(value, on: tab)
    }

    /// A tab's binding for its NavigationStack.
    func pathBinding(_ t: Tab) -> Binding<NavigationPath> {
        Binding(get: { [unowned self] in self.path(t) }, set: { [unowned self] in self.setPath(t, $0) })
    }

    // MARK: The bar

    /// Saves the tabs between Home and Settings. A tab that left the bar loses its stack; if it was on screen, Home
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

    /// Opens a tab's screen: the tab itself when it's in the bar; otherwise its screen pushed inside Library, or Home.
    /// `filter` opens the Library on a chip (`libraryFilterRequest`).
    func go(_ t: Tab, filter: String? = nil) {
        let bar = tabBar
        switch t {
        case .home, .settings:
            tab = t
        case .library:
            if bar.contains(.library) {
                if let filter { libraryFilterRequest = filter }
                tab = .library
            } else {
                push(LibraryRoute(request: filter), on: .home)
                tab = .home
            }
        case .moments:
            let host = bar.host(for: .moments)
            if host != .moments { push(MomentsRoute(), on: host) }
            tab = host
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
            .navigationDestination(for: MomentsRoute.self) { _ in MomentsScreen(pushed: true) }
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

/// The Projects tab: each project with how many recordings it holds, and New project. A project opens the Library on
/// it, inside this tab.
struct ProjectsScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.look) private var look
    @State private var newProject = false
    @State private var projectName = ""
    /// For the self-test: whether the Projects tab's root is on screen.
    static var visible = false

    var body: some View {
        Group {
            if look.isNative { list.listStyle(.insetGrouped) } else { list.listStyle(.plain) }
        }
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .phonePage()
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
        .toolbar {
            if !look.isNative { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
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

    private var list: some View {
        let counts = app.store.memo("phone.project-counts") { () -> [UUID: Int] in
            var counts: [UUID: Int] = [:]
            for t in app.store.live where !t.isDictation { if let p = t.projectId { counts[p, default: 0] += 1 } }
            return counts
        }
        let projects = app.store.projects
        return List {
            if !look.isNative {
                PhoneCompactTitle(title: "Projects", count: "\(projects.count)")
                    .padding(.top, 4)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if projects.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if !look.isNative { IconPlate(art: .iconProject, size: 96) }
                    Text("Projects group recordings. Make one here, or from a recording's menu.")
                        .font(.system(size: 15)).foregroundStyle(.lookDim)
                }
                .padding(.top, 12)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(projects) { p in
                NavigationLink(value: LibraryRoute(request: "project:\(p.id.uuidString)")) {
                    HStack(spacing: 12) {
                        if !look.isNative { IconGlyph(art: .iconProject, size: 18, color: Ink.ink) }
                        Text(p.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings")).font(.system(size: 14)).foregroundStyle(.lookMute)
                    }
                    .frame(minHeight: 48)
                }
                .accessibilityHint("Opens the project in your library.")
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(look.isNative ? NativeInk.card : Color.clear)
            }
        }
    }
}
