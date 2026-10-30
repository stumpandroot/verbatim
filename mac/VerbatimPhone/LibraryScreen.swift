import SwiftUI

/// The Library in the refined look (DESIGN.md §6.8 and §13; mockup "Verbose Refined Look", PhoneLibrary), one layout
/// in both look settings: the large serif "Library" with the count, the system search field (Search or ask), the quick
/// filter chips (All, Voice notes, Meetings, Thoughts, Audio, Links, Marked), a card of places (Dictations, By day,
/// Templates, Ask, and Projects when you have one), then each day under its serif title as a card of recordings: the
/// kind's badge, the title, a meta line (the kind, who, the moments, or where it is while it's being made), and the
/// length. An Audio only recording plays from its row. Apple draws the chrome: the navigation bar with Filter (every
/// type, kind, Pinned, In progress, and project, and Sort by) and More (Select recordings, Recently Deleted, New
/// project), swipe actions, context menus, and selection. A plain, lazy `List`, so rows keep swipe actions and
/// selection; each row draws its share of the card (`PaperRowBackground`). Nothing enters with an animation.
struct LibraryScreen: View {
    @EnvironmentObject var app: PhoneState
    /// The search and the filter, kept when a look switch rebuilds Library (`LookKeep`).
    @State private var search = LookKeep.librarySearch
    @State private var filter: Filter = LookKeep.libraryFilter
    /// The type (Voice notes, Links, Marked, …) and its platform, remembered on this iPhone.
    @State private var typeFilter = LibraryFilter.saved(LibraryFilter.libraryKey)
    @State private var newProject = false
    @State private var projectName = ""
    /// Newest, Oldest, Longest, or Title A–Z, remembered on this iPhone.
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }
    @Environment(\.look) private var look
    /// Pushed inside another tab (Library isn't in the bar, or a project from the Projects tab), opened on this filter.
    /// Nil for the Library tab itself.
    var route: LibraryRoute? = nil
    @State private var routeApplied = false
    /// Select recordings (More), the selection, and the pushes from More and the Projects row.
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var showTrash = false
    @State private var showProjects = false

    /// The looks the Library is on screen in (the self-test checks each look draws this one layout, once).
    static var onScreen = Set<AppLook>()

    /// A filter besides the type: a kind, Pinned, In progress, or a project. A type and these don't combine: choosing
    /// one clears the other.
    enum Filter: Hashable { case all, pinned, working, project(UUID), kind(RecordingKind) }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespaces) }
    private var searching: Bool { !trimmedSearch.isEmpty }

    /// The filter and the search, before the type (which counts over this). Dictations are included here;
    /// `LibraryFilter.apply` leaves them out unless you're searching or chose Dictations.
    private var scoped: [Transcript] {
        let q = trimmedSearch.lowercased()
        let filter = self.filter
        // Once per library change, filter, and search (Store+Memo.swift), not on every render.
        return app.store.memo("phone.scoped|\(String(describing: filter))|\(q)") { app.store.live.filter { t in
            let f: Bool = {
                switch filter {
                case .all: return true
                case .pinned: return t.pinned
                case .working: return t.status == .processing
                case .project(let p): return t.projectId == p
                case .kind(let k): return t.kind == k
                }
            }()
            return f && (q.isEmpty || t.title.lowercased().contains(q) || app.store.searchText(t).contains(q))
        } }
    }

    /// What `scoped` depends on besides the library, for the memo keys built on it.
    private var scopeKey: String { "\(String(describing: filter))|\(trimmedSearch.lowercased())" }

    /// Dictations, newest first. They have their own list, reached from the row at the top (and Home's Dictate).
    private var dictations: [Transcript] {
        app.store.memo("phone.dictations") { app.store.live.filter(\.isDictation).sorted { $0.createdAt > $1.createdAt } }
    }

    /// Live recordings that aren't dictations: the title's count.
    private var recordingCount: Int { app.store.memo("phone.recording-count") { app.store.live.filter { !$0.isDictation }.count } }

    /// The list, with a day before each day's first row when the order is by date.
    private enum Line {
        case day(Date, String)
        case row(Transcript)
    }

    private func lines(_ items: [Transcript]) -> [Line] {
        // The same list's lines once per library change and day; days say "Today" and "Yesterday".
        app.store.memo("phone.lines|\(scopeKey)|\(typeFilter.raw)|\(sort.rawValue)|\(Store.dayKey())|\(items.count)") { makeLines(items) }
    }

    private func makeLines(_ items: [Transcript]) -> [Line] {
        let byDate = sort.groupsByDay
        let cal = Calendar.current
        var out: [Line] = []
        var lastDay: Date? = nil
        for t in items {
            if byDate {
                let day = cal.startOfDay(for: t.createdAt)
                if day != lastDay { out.append(.day(day, PhoneDayHeader.label(day))); lastDay = day }
            }
            out.append(.row(t))
        }
        return out
    }

    /// The recordings grouped under their days ("Today", "Yesterday", "Mon Oct 19"); one untitled group when the order
    /// isn't by date.
    private static func daySections(_ lines: [Line]) -> [(label: String, items: [Transcript])] {
        var out: [(label: String, items: [Transcript])] = []
        for line in lines {
            switch line {
            case .day(_, let label): out.append((PhoneDayHeader.nativeLabel(label), []))
            case .row(let t):
                if out.isEmpty { out.append(("", [])) }
                out[out.count - 1].items.append(t)
            }
        }
        return out.filter { !$0.items.isEmpty }
    }

    var body: some View {
        // `scoped` searches every transcript's text; work it out once per render.
        let scoped = self.scoped
        let searching = self.searching, typeFilter = self.typeFilter, sort = self.sort
        let items = app.store.memo("phone.items|\(scopeKey)|\(typeFilter.raw)|\(sort.rawValue)") { sort.sorted(typeFilter.apply(scoped, searching: searching)) }
        let passages = trimmedSearch.count >= 2 ? LibrarySearch.passages(items, query: search, perTranscript: 3, cap: 60) : []
        let project: UUID? = { if case .project(let p) = filter { return p }; return nil }()
        let browsing = filter == .all && !searching && typeFilter == .all && !selecting
        return List(selection: $selection) {
            header(items: items, scoped: scoped)
            if browsing { placesCard }
            if let p = project, !selecting { addFromLibrary(p) }
            if searching { askAbout }
            if !passages.isEmpty { passagesSection(passages) }
            if items.isEmpty { emptyState(project: project) }
            ForEach(Self.daySections(lines(items)), id: \.label) { day in
                daySection(day)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .scrollContentBackground(.hidden)
        .background(Refined.paper.ignoresSafeArea())
        .modifier(LibraryScrollEdge())
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .navigationDestination(isPresented: $showTrash) { TrashScreen() }
        .navigationDestination(isPresented: $showProjects) { ProjectsScreen() }
        .onChange(of: search) { _, v in if route == nil { LookKeep.librarySearch = v } }
        .onChange(of: filter) { _, v in if route == nil { LookKeep.libraryFilter = v } }
        .onAppear {
            Self.onScreen.insert(look)
            // Pushed: starts on its own filter and an empty search, once.
            guard let route, !routeApplied else { return }
            routeApplied = true
            search = ""
            if let r = route.request { applyRequest(r) } else { filter = .all }
        }
        .onDisappear { Self.onScreen.remove(look) }
        .onReceive(app.$libraryFilterRequest) { r in
            // The screenshot tour (and anything else) can open Library on a kind, or back on All; Home's tiles and
            // sections open it on what's transcribing ("working") or on a project ("project:<id>"). For the Library
            // tab only; a pushed Library has its own (`route`).
            guard let r, route == nil else { return }
            applyRequest(r)
            app.libraryFilterRequest = nil
        }
        .sheet(isPresented: Binding(get: { app.addFromLibrary != nil }, set: { if !$0 { app.addFromLibrary = nil } })) {
            if let p = app.addFromLibrary { PhoneAddFromLibrarySheet(project: p).environmentObject(app) }
        }
        .alert("New project", isPresented: $newProject) {
            TextField("Name", text: $projectName)
            Button("Cancel", role: .cancel) { projectName = "" }
            Button("Create") {
                let n = projectName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { filter = .project(app.store.addProject(n).id); setType(.all) }
                projectName = ""
            }
        }
    }

    /// Puts the Library on a filter from a request: "working", "project:<id>", "source:<type>" (Marked, Links), a
    /// kind's raw value, or anything else for All.
    private func applyRequest(_ r: String) {
        if r.hasPrefix("source:"), let s = LibrarySource(rawValue: String(r.dropFirst("source:".count))) {
            filter = .all; setType(LibraryFilter(source: s)); return
        }
        if r == "working" {
            filter = .working
        } else if r.hasPrefix("project:"), let id = UUID(uuidString: String(r.dropFirst("project:".count))) {
            filter = .project(id)
        } else {
            filter = RecordingKind(rawValue: r).map { .kind($0) } ?? .all
        }
        if filter != .all { setType(.all) }
    }

    // MARK: Header

    /// The serif title with the count, the search field, the chips, and a platform row under Links.
    @ViewBuilder private func header(items: [Transcript], scoped: [Transcript]) -> some View {
        LargeSerifTitle(title: title, count: countText(items))
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .modifier(PageRow(top: 0, bottom: 0))
        SystemSearchField(text: $search, prompt: "Search or ask")
            .frame(minHeight: 38)
            .modifier(PageRow(top: 14, bottom: 0))
        chips
            .modifier(PageRow(top: 10, bottom: 0, edge: 0))
        let platforms = typeFilter.platformCounts(scoped, searching: searching)
        if typeFilter.source.hasPlatforms, !platforms.isEmpty {
            RefinedChipRow(label: "Platform", margin: 20) {
                ForEach(platforms, id: \.0) { p, n in
                    RefinedChip(title: p, selected: typeFilter.platform == p) {
                        setType(LibraryFilter(source: typeFilter.source, platform: typeFilter.platform == p ? nil : p))
                    }
                    .accessibilityValue("\(n)")
                }
            }
            .modifier(PageRow(top: 0, bottom: 0, edge: 0))
        }
    }

    /// The project's name in a project, otherwise "Library".
    private var title: String {
        if case .project(let p) = filter, let name = app.store.projects.first(where: { $0.id == p })?.name { return name }
        return "Library"
    }

    /// "47 recordings", or with a filter on, how many it shows ("8 meetings", "3 pinned").
    private func countText(_ items: [Transcript]) -> String {
        let n = items.count
        if typeFilter != .all { return "\(n) \(typeFilter.source.label.lowercased())" }
        switch filter {
        case .all: return HomeCounts.countLabel(searching ? n : recordingCount, "recording", "recordings")
        case .pinned: return "\(n) pinned"
        case .working: return "\(n) in progress"
        case .kind(let k): return n == 1 ? "1 \(RecordingKind.refinedName(k).lowercased())" : "\(n) \(k.plural.lowercased())"
        case .project: return HomeCounts.countLabel(n, "recording", "recordings")
        }
    }

    // MARK: Chips

    /// The chip the current filter is, or nil when the filter menu chose one the chips don't name.
    private var currentChip: LibraryChip? {
        switch filter {
        case .all: return LibraryChip.matching(typeFilter, kind: nil)
        case .kind(let k): return typeFilter == .all ? LibraryChip.matching(.all, kind: k) : nil
        default: return nil
        }
    }

    /// The name of a filter the chips don't name, shown as a chosen chip after All so you can see it and clear it.
    private var otherFilterName: String? {
        switch filter {
        case .all: return LibraryChip.otherLabel(typeFilter, kind: nil)
        case .kind(let k): return LibraryChip.otherLabel(typeFilter, kind: k)
        case .pinned: return "Pinned"
        case .working: return "In progress"
        case .project(let p): return app.store.projects.first { $0.id == p }?.name ?? "Project"
        }
    }

    /// The mockup's seven chips, always in the same order so the row never shifts. Choosing one clears every other
    /// filter; the chosen one again goes back to All. Chip taps never animate rows (high-frequency); the list changes
    /// in place.
    private var chips: some View {
        let current = currentChip
        return RefinedChipRow(label: "Filter", margin: 20) {
            RefinedChip(title: LibraryChip.all.label, selected: current == .all) { choose(.all) }
            if let other = otherFilterName {
                RefinedChip(title: other, selected: true) { choose(.all) }
                    .accessibilityHint("Clears this filter.")
            }
            ForEach(LibraryChip.allCases.filter { $0 != .all }) { c in
                RefinedChip(title: c.label, selected: current == c) { choose(current == c ? .all : c) }
            }
        }
    }

    private func choose(_ chip: LibraryChip) {
        filter = chip.kind.map { .kind($0) } ?? .all
        setType(LibraryFilter(source: chip.source))
    }

    private func setType(_ f: LibraryFilter) {
        guard f != typeFilter else { return }
        typeFilter = f
        typeFilter.save(LibraryFilter.libraryKey)
    }

    /// The type chips in a fixed order: every type the library has, plus the chosen one (the filter menu).
    static func fixedSources(library present: Set<LibrarySource>, selected: LibrarySource) -> [LibrarySource] {
        LibrarySource.allCases.filter { $0 != .all && (present.contains($0) || $0 == selected) }
    }

    // MARK: Places

    /// One place in the card under the chips.
    private struct Place: Identifiable {
        var id: String
        var title: String
        var art: BrandArt
        var hue: RefinedHue
        var value: String?
        var hint: String
        var open: () -> Void
    }

    /// The places under the chips, in order: Dictations (butter), By day (sage), Templates (petal), Ask, and Projects
    /// when you have one. Each with its identifier, name, glyph, hue, and the value at its end (none at zero for By day
    /// and Ask).
    static func placeRows(dictations: Int, todayThoughts: Int, templates: Int, recipes: Int, projects: Int)
        -> [(id: String, title: String, art: BrandArt, hue: RefinedHue, value: String?)] {
        var out: [(id: String, title: String, art: BrandArt, hue: RefinedHue, value: String?)] = [
            ("library.dictations", "Dictations", .iconDictations, .butter, "\(dictations)"),
            ("library.byDay", "By day", .iconCalendar, .sage, todayThoughts > 0 ? "\(todayThoughts) today" : nil),
            ("library.templates", "Templates", .iconSummaries, .petal, "\(templates)"),
            ("library.ask", "Ask", .iconAsk, .neutral, recipes > 0 ? HomeCounts.countLabel(recipes, "recipe", "recipes") : nil),
        ]
        if projects > 0 { out.append(("library.projects", "Projects", .iconProject, .neutral, "\(projects)")) }
        return out
    }

    private var places: [Place] {
        let rows = Self.placeRows(dictations: dictations.count, todayThoughts: app.store.todaysThoughts().count,
                                  templates: app.store.allTemplates.count, recipes: app.store.recipes.count,
                                  projects: app.store.projects.count)
        return rows.map { r in
            Place(id: r.id, title: r.title, art: r.art, hue: r.hue, value: r.value, hint: Self.placeHint(r.id)) { open(place: r.id) }
        }
    }

    private static func placeHint(_ id: String) -> String {
        switch id {
        case "library.dictations": return "Opens every dictation."
        case "library.byDay": return "Opens Thoughts and Journal by day."
        case "library.templates": return "Opens your templates and Run automatically."
        case "library.ask": return "Asks a question about your recordings."
        default: return "Opens your projects."
        }
    }

    /// Pushes a place on the stack the Library is on (the Library tab, or Home or Projects when it's pushed there).
    private func open(place id: String) {
        switch id {
        case "library.dictations": app.pushHere(DictationsRoute())
        case "library.byDay": app.pushHere(ByDayRoute(kind: .idea))
        case "library.templates": app.pushHere(TemplatesRoute())
        case "library.ask": app.pushHere(AskRoute())
        default: showProjects = true
        }
    }

    /// The places as one card, each row a button that pushes on the stack the Library is on.
    @ViewBuilder private var placesCard: some View {
        let all = places
        ForEach(Array(all.enumerated()), id: \.element.id) { i, p in
            Button(action: p.open) { IconSquareRow(art: p.art, hue: p.hue, title: p.title, value: p.value) }
                .buttonStyle(RefinedPress())
                .accessibilityHint(p.hint)
                .accessibilityIdentifier(p.id)
                .modifier(CardRow(first: i == 0, last: i == all.count - 1, divider: 56, top: i == 0 ? 16 : 0))
        }
    }

    /// Add from Library, in a project.
    private func addFromLibrary(_ p: UUID) -> some View {
        Button { app.addFromLibrary = p } label: { IconSquareRow(art: .iconLibrary, hue: .neutral, title: "Add from Library") }
            .buttonStyle(RefinedPress())
            .accessibilityHint("Adds transcripts you already have to this project.")
            .modifier(CardRow(first: true, last: true, divider: 56, top: 16))
    }

    /// The search field asks too: ask about what you typed.
    private var askAbout: some View {
        AskAboutRow(query: trimmedSearch)
            .modifier(CardRow(first: true, last: true, divider: 56, top: 16))
    }

    @ViewBuilder private func passagesSection(_ passages: [LibrarySearch.PassageHit]) -> some View {
        SectionTitle("Passages")
            .modifier(PageRow(top: 18, bottom: 6))
        ForEach(passages) { hit in
            PhonePassageCard(transcript: hit.transcript, lines: hit.lines, count: hit.count, query: search)
                .modifier(PageRow(top: 4, bottom: 4))
        }
    }

    private func emptyState(project: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(searching ? "Nothing matches \u{201C}\(trimmedSearch)\u{201D}" : project != nil ? "Nothing in this project yet" : "Nothing here yet")
                .refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
            Text(searching ? "Search looks at titles and every transcript's words."
                 : project != nil ? "Add transcripts from your library."
                 : filter != .all || typeFilter != .all ? "Choose All to see every recording."
                 : "Tap Record to start one. Recordings and imports land here, and on your Mac.")
                .refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardRow(first: true, last: true, divider: 0, top: 16))
    }

    // MARK: Days and rows

    @ViewBuilder private func daySection(_ day: (label: String, items: [Transcript])) -> some View {
        if !day.label.isEmpty {
            SectionTitle(day.label)
                .modifier(PageRow(top: 22, bottom: 8))
        }
        ForEach(Array(day.items.enumerated()), id: \.element.id) { i, t in
            row(t, first: i == 0, last: i == day.items.count - 1)
        }
    }

    private func row(_ t: Transcript, first: Bool, last: Bool) -> some View {
        LibraryRow(transcript: t, selecting: selecting)
            .modifier(CardRow(first: first, last: last, divider: 58, top: day0Gap(first: first)))
            .tag(t.id)
            .contextMenu { RowActions(transcript: t) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { app.delete([t.id]) } label: { Label("Delete", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
                Button { app.togglePin(t.id) } label: { Label(t.pinned ? "Unpin" : "Pin", systemImage: t.pinned ? "pin.slash" : "pin") }   // brand: system surface (swipe action)
                    .tint(Refined.accentText)
            }
    }

    /// Rows sit right under their day's title; with no titles (sorted by length or title), the first row keeps a gap
    /// from the chips.
    private func day0Gap(first: Bool) -> CGFloat { first && !sort.groupsByDay ? 16 : 0 }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The serif title sits on the page; the bar keeps only Apple's buttons.
        ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { selecting = false; selection = [] }.fontWeight(.semibold)
            }
            ToolbarItem(placement: .topBarTrailing) { selectionMenu }
        } else {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
    }

    /// What to do with the selected recordings: add them to a project, export them, or delete them.
    private var selectionMenu: some View {
        Menu {
            Menu {
                ForEach(app.store.projects) { p in
                    Button(p.name) { app.addToProject(Array(selection), p.id); selecting = false; selection = [] }
                }
            } label: { Label("Add to project", systemImage: "folder.badge.plus") }   // brand: system surface (menu)
            .disabled(app.store.projects.isEmpty)
            Button { app.exportRequest = PhoneExportRequest(ids: Array(selection)) } label: { Label("Export", systemImage: "square.and.arrow.up") }
            Divider()
            Button(role: .destructive) {
                app.delete(Array(selection)); selecting = false; selection = []
            } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Text(selection.isEmpty ? "Select" : "\(selection.count) selected")
        }
        .disabled(selection.isEmpty)
    }

    /// The filter menu: Show (every type, kind, Pinned, In progress, and project) and Sort by.
    private var filterMenu: some View {
        Menu {
            Picker(selection: Binding(get: { choice }, set: { setChoice($0) })) {
                Text("All recordings").tag("all")
                ForEach(menuSources) { s in Text(s.label).tag("source:\(s.rawValue)") }
                ForEach(menuKinds) { k in Text(k.plural).tag("kind:\(k.rawValue)") }
                Text("Pinned").tag("pinned")
                Text("In progress").tag("working")
                ForEach(app.store.projects) { p in Text(p.name).tag("project:\(p.id.uuidString)") }
            } label: { Text("Show") }
            .pickerStyle(.inline)
            Section {
                Picker(selection: $sortRaw) {
                    ForEach(LibrarySort.allCases) { s in Text(s.title).tag(s.rawValue) }
                } label: {
                    Label("Sort by", systemImage: "arrow.up.arrow.down")
                    Text(sort.title)
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")   // brand: system surface (toolbar)
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(choice == "all" ? "All recordings" : (otherFilterName ?? currentChip?.label ?? ""))
        .accessibilityIdentifier("library.filter")
    }

    /// More: Select recordings, Recently Deleted, and New project.
    private var moreMenu: some View {
        Menu {
            Button { selecting = true } label: { Label("Select recordings", systemImage: "checkmark.circle") }   // brand: system surface (menu)
            Button { showTrash = true } label: { Label("Recently Deleted", systemImage: "trash") }
            Button { newProject = true } label: { Label("New project…", systemImage: "folder.badge.plus") }   // brand: system surface (menu)
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel("More")
        .accessibilityIdentifier("library.more")
    }

    /// The filter menu's choices as tags: "all", "source:<raw>", "kind:<raw>", "pinned", "working", "project:<id>".
    private var choice: String {
        if typeFilter != .all { return "source:\(typeFilter.source.rawValue)" }
        switch filter {
        case .all: return "all"
        case .pinned: return "pinned"
        case .working: return "working"
        case .kind(let k): return "kind:\(k.rawValue)"
        case .project(let p): return "project:\(p.uuidString)"
        }
    }

    private func setChoice(_ tag: String) {
        if tag.hasPrefix("source:"), let s = LibrarySource(rawValue: String(tag.dropFirst("source:".count))) {
            filter = .all; setType(LibraryFilter(source: s))
        } else if tag == "pinned" { filter = .pinned; setType(.all) }
        else if tag == "working" { filter = .working; setType(.all) }
        else if tag.hasPrefix("kind:"), let k = RecordingKind(rawValue: String(tag.dropFirst("kind:".count))) { filter = .kind(k); setType(.all) }
        else if tag.hasPrefix("project:"), let id = UUID(uuidString: String(tag.dropFirst("project:".count))) { filter = .project(id); setType(.all) }
        else { filter = .all; setType(.all) }
    }

    /// The types the library has (and the one chosen), in a fixed order; Dictations has its own row.
    private var menuSources: [LibrarySource] {
        let present = app.store.memo("phone.sources-present") {
            Set(LibraryFilter.all.sourceCounts(app.store.live, searching: false).filter { $0.1 > 0 }.map(\.0))
        }
        return Self.fixedSources(library: present, selected: typeFilter.source).filter { $0 != .dictations || typeFilter.source == .dictations }
    }

    private var menuKinds: [RecordingKind] {
        let present = app.store.memo("phone.kinds-present") { Set(app.store.live.compactMap(\.kind)) }
        return RecordingKind.pickable.filter { k in present.contains(k) || filter == .kind(k) }
    }

    // MARK: Meta

    /// A row's meta line (mockup PhoneLibrary): the kind, then the people ("Tim, Jonathan" or "2 speakers") or a
    /// link's site, and the moments ("Meeting · Tim, Jonathan · 4 moments", "Audio only · 2 moments"); while it's
    /// being made, where it is ("Interview · Transcribing 42%", "Video · Queued"); "Didn't finish" when it failed.
    static func rowMeta(_ t: Transcript) -> String {
        var parts = [RecordingKind.refinedName(t.refinedKind)]
        switch t.status {
        case .processing:
            parts.append(t.stageText.isEmpty ? "Transcribing" : t.stageText)
        case .failed:
            parts.append("Didn't finish")
        case .ready:
            if !t.stageText.isEmpty { parts.append(t.stageText) }
            let names = t.speakers.map(\.name).filter { !$0.isEmpty && !$0.hasPrefix("Speaker ") }
            if names.count >= 2 { parts.append(names.prefix(3).joined(separator: ", ")) }
            else if t.speakers.count >= 2 { parts.append("\(t.speakers.count) speakers") }
            else if LibrarySource.isLink(t), let site = t.linkInfo?.site, !site.isEmpty { parts.append(site) }
            let moments = t.notes.filter { $0.at != nil }.count
            if moments > 0 { parts.append(HomeCounts.countLabel(moments, "moment", "moments")) }
        }
        return parts.joined(separator: " · ")
    }

    /// "Meeting · Tim, Jonathan", "Voice note · Idea", "Journal · 3 moments", "youtube.com · Video" (Add from Library's
    /// rows).
    static func meta(_ t: Transcript) -> String {
        let style = HomeRecentStyle(t)
        let source = t.source == .voiceMemo && !LibrarySource.isLink(t) ? "Voice note" : style.source
        // Names people typed; the engine's "Speaker 1" placeholders count as speakers, not names.
        let names = t.speakers.map(\.name).filter { !$0.isEmpty && !$0.hasPrefix("Speaker ") }
        let moments = t.notes.filter { $0.at != nil }.count
        let kind = t.kind.flatMap { $0 == .dictation ? nil : $0 }
        var parts: [String] = []
        if let kind, names.count >= 2 || moments > 0 { parts.append(kind.label) }
        else { parts.append(source); if let kind { parts.append(kind.label) } }
        if names.count >= 2 { parts.append(names.prefix(3).joined(separator: ", ")) }
        else if t.speakers.count >= 2 { parts.append("\(t.speakers.count) speakers") }
        else if moments > 0 { parts.append(moments == 1 ? "1 moment" : "\(moments) moments") }
        return parts.joined(separator: " · ")
    }
}

/// One recording in the Library's card: the kind's badge, the title over the meta line, and the length. A button that
/// opens it, except while selecting, when the list's selection takes the tap. An Audio only recording with no words
/// yet plays from here: its sage play button and waveform sit under the title. VoiceOver reads the title, the meta
/// line (the kind first), and the length.
private struct LibraryRow: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var selecting: Bool

    var body: some View {
        // The live progress (StageClock): a tick re-renders this row, not the Library.
        LiveStage(transcript) { t in
            VStack(alignment: .leading, spacing: 0) {
                if selecting {
                    face(t)
                } else {
                    Button { app.open(t.id) } label: { face(t) }
                        .buttonStyle(RefinedPress())
                        .accessibilityHint("Opens the transcript.")
                }
                if t.showsAudioDetail && !selecting {
                    PhoneAudioRowPlayer(transcript: t)
                        .padding(.leading, 53).padding(.trailing, 14).padding(.bottom, 8)
                }
            }
        }
    }

    private func face(_ t: Transcript) -> some View {
        let meta = LibraryScreen.rowMeta(t)
        let length = t.duration > 0 && !(t.kind == .idea && t.audioFileName == nil) ? HomeRecentStyle.length(t.duration) : nil
        return PaperRow(kind: t.refinedKind, title: PhoneRowTitle.title(t, withTime: false), meta: meta, badge: 32, pinned: t.pinned) {
            if let length { RowLength(text: length) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([t.pinned ? "Pinned" : nil, PhoneRowTitle.title(t, withTime: false), meta,
                              length.map { _ in RefinedRules.spokenTime(t.duration) }] as [String?]).compactMap { $0 }.joined(separator: ", "))
    }
}

/// A row on the page itself (titles, the search field, the chips): no card, no separator, the page's margins.
private struct PageRow: ViewModifier {
    var top: CGFloat
    var bottom: CGFloat
    var edge: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: top, leading: edge, bottom: bottom, trailing: edge))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }
}

/// A row's share of a card: the card behind it (`PaperRowBackground`), a hairline above it when it isn't the first,
/// inset to where its text starts, and `top` points of page above the card's first row.
private struct CardRow: ViewModifier {
    var first: Bool
    var last: Bool
    var divider: CGFloat
    var top: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { if !first { PaperDivider(leading: divider) } }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(PaperRowBackground(first: first, last: last).padding(.top, first ? top : 0))
            .listRowSeparator(.hidden)
            .padding(.top, first ? top : 0)
    }
}

/// The soft scroll edge at the top on iOS 26, where Apple's bar floats over the page.
private struct LibraryScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.scrollEdgeEffectStyle(.soft, for: .top) } else { content }
    }
}

/// One transcript's matching lines from a search: tap a line to open the transcript there, with the audio cued to it.
struct PhonePassageCard: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var lines: [Segment]
    var count: Int
    var query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(transcript.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                Spacer(minLength: 6)
                Text(count == 1 ? "1 match" : "\(count) matches").refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            ForEach(lines) { s in
                Button { app.open(transcript.id, segment: s.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(s.start.timecode).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.accentText)
                            .frame(minWidth: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if transcript.speakers.count >= 2, let sp = transcript.speakerName(s.speaker) {
                                Text(sp).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                            }
                            Text(marked(s.text)).refinedFont(.body).foregroundStyle(Refined.ink).lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RefinedPress())
                .accessibilityHint("Opens the transcript at \(s.start.timecode)")
            }
        }
        .padding(.bottom, 6)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    /// The query in the line, on the persimmon tint in semibold.
    private func marked(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return a }
        var start = a.startIndex
        while start < a.endIndex, let r = a[start...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Refined.persimmonTint
            a[r].inlinePresentationIntent = .stronglyEmphasized
            start = r.upperBound
        }
        return a
    }
}
