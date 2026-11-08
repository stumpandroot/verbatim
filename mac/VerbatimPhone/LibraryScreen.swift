import SwiftUI
import UIKit

/// The Library in the refined look (DESIGN.md §6.8 and §13; mockup "Verbose Refined Look", PhoneLibrary), one layout
///: the large serif "Library" with the count, the system search field (Search or ask, the one way into search and Ask:
/// typing shows a Search | Ask switch under it, IP-39), one row of small buttons for
/// the places (Dictations, By day, Templates, Ask, and Projects when you have one), the quick filter chips (All, Voice
/// notes, Meetings, Thoughts, Audio, Links, Marked), then each day under its serif title as a card of recordings: the
/// kind's badge, the title, a meta line (the kind, who, the moments, or where it is while it's being made), and the
/// length. An Audio only recording plays from its row. Apple draws the chrome: the navigation bar with Filter (every
/// type, kind, Pinned, In progress, and project, and Sort by) and More (Select recordings, Recently Deleted, New
/// project), swipe actions, context menus, and selection. A plain, lazy `List`, so rows keep swipe actions and
/// selection; each row draws its share of the card (`PaperRowBackground`). Nothing enters with an animation; a chip's
/// change fades the list in as a whole.
struct LibraryScreen: View {
    @Environment(PhoneState.self) var app
    /// The search and the filter, kept when Library is built again (`LibraryKeep`).
    @State private var search = LibraryKeep.librarySearch
    @State private var filter: Filter = LibraryKeep.libraryFilter
    /// Search or Ask in the switch under the field, and where Ask looks (IP-39; `SearchOrAsk`).
    @State private var mode: SearchOrAsk = LibraryKeep.libraryMode
    @State private var askScope = LibraryKeep.libraryAskScope
    /// Bumped to put the keyboard up in the field (the Ask place with nothing asked yet).
    @State private var focusRequest = 0
    /// Save as recipe from Ask's actions in More.
    @State private var editingRecipe: RecipeDraft? = nil
    @ObservedObject private var askCenter = AskCenter.shared
    /// The type (Voice notes, Links, Marked, …) and its platform, remembered on this iPhone.
    @State private var typeFilter = LibraryFilter.saved(LibraryFilter.libraryKey)
    @State private var newProject = false
    @State private var projectName = ""
    /// Newest, Oldest, Longest, or Title A–Z, remembered on this iPhone.
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }
    /// Pushed inside another tab (Library isn't in the bar, or a project from the Projects tab), opened on this filter.
    /// Nil for the Library tab itself.
    var route: LibraryRoute? = nil
    /// A kind's tab (Meetings, …; PhoneApp's `rootScreen`): the tab's name, the title while the Library is on the tab's
    /// kind. Nil elsewhere.
    var tabTitle: String? = nil
    /// Pushed as Ask (`AskRoute`, from a stack without the Library tab): opens with Ask chosen, asking its words at once.
    var ask: AskRoute? = nil
    @State private var routeApplied = false
    /// Select recordings (More), the selection, and the pushes from More and the Projects row.
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var showTrash = false
    @State private var showProjects = false
    /// Clear for a moment after a chip changes the filter, then fades in (`fadeList`).
    @State private var listShown = true

    /// How many Libraries are on screen (the self-test checks there's one).
    static var onScreen = 0
    /// For the self-test: the kind the Library last shown is on (its raw value; nil for any other filter), and its title.
    static var shownKind: String?
    static var shownTitle: String?
    /// For the self-test: Search or Ask in the field's switch, and the field's words, on the Library last shown.
    static var shownMode: SearchOrAsk = .search
    static var shownQuery = ""

    /// A filter besides the type: a kind, Pinned, In progress, or a project. A type and these don't combine: choosing
    /// one clears the other.
    enum Filter: Hashable { case all, pinned, working, project(UUID), kind(RecordingKind) }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespaces) }
    /// What filters the recordings: the field's words with Search chosen, nothing with Ask chosen (they're a question).
    private var listQuery: String { mode == .ask ? "" : trimmedSearch }
    private var searching: Bool { !listQuery.isEmpty }
    /// What the page shows under the field: the Library, the matches, or Ask.
    private var content: SearchOrAsk.Content { SearchOrAsk.content(query: search, mode: mode) }

    /// The filter and the search, before the type (which counts over this). Dictations are included here;
    /// `LibraryFilter.apply` leaves them out unless you're searching or chose Dictations.
    private var scoped: [Transcript] {
        let q = listQuery.lowercased()
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
    private var scopeKey: String { "\(String(describing: filter))|\(listQuery.lowercased())" }

    /// Dictations, newest first. They have their own list, reached from the card at the top (and Home's Dictate and
    /// Recent dictations).
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
                if day != lastDay { out.append(.day(day, DayLabel.title(day))); lastDay = day }
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
            case .day(_, let label): out.append((DayLabel.short(label), []))
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
        let content = self.content
        let passages = content == .search && trimmedSearch.count >= 2 ? LibrarySearch.passages(items, query: search, perTranscript: 3, cap: 60) : []
        return List(selection: $selection) {
            header(items: items, scoped: scoped)
            if content == .ask {
                // Ask, in the same field (IP-39): the answer with its citations, the other passages, and Recipes.
                PhoneAskPanel()
                    .modifier(PageRow(top: 14, bottom: 24))
            } else {
                Group {
                    if let p = project, !selecting { addFromLibrary(p) }
                    if !passages.isEmpty { passagesSection(passages) }
                    if items.isEmpty {
                        if let k = kindTabKind, !searching, project == nil { kindEmptyState(k) } else { emptyState(project: project) }
                    }
                    ForEach(Self.daySections(lines(items)), id: \.label) { day in
                        daySection(day)
                    }
                }
                // A chip's change fades the list in as a whole (`fadeList`); each row takes the same opacity, nothing more.
                .opacity(listShown ? 1 : 0)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .scrollContentBackground(.hidden)
        .background(Refined.paper.ignoresSafeArea())
        .modifier(LibraryScrollEdge())
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(tabTitle ?? "Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // A tab's Library pins its title with its buttons, as Verbose Tasks does; a pushed one keeps Apple's bar.
        .pinnedTitle(isTabRoot) { titleRow(items: items) }
        .navigationDestination(isPresented: $showTrash) { TrashScreen() }
        .navigationDestination(isPresented: $showProjects) { ProjectsScreen() }
        .onChange(of: search) { _, v in if route == nil { LibraryKeep.librarySearch = v } }
        .onChange(of: filter) { _, v in if route == nil { LibraryKeep.libraryFilter = v } }
        .onChange(of: mode) { _, v in if route == nil { LibraryKeep.libraryMode = v }; noteShown() }
        .onChange(of: search) { _, _ in Self.shownQuery = search }
        .onChange(of: askScope) { _, v in
            if route == nil { LibraryKeep.libraryAskScope = v }
            // A new scope asks the question on screen again (not when the field took the answer's own scope).
            if mode == .ask, let r = askCenter.result, r.scope != v, !trimmedSearch.isEmpty { runAsk() }
        }
        .onChange(of: filter) { _, _ in noteShown() }
        .onAppear {
            Self.onScreen += 1
            defer { noteShown() }
            // Pushed: starts on its own filter and an empty search, once (with Ask chosen when it was pushed as Ask).
            guard let route, !routeApplied else { return }
            routeApplied = true
            search = ""
            mode = .search
            if let r = route.request { applyRequest(r) } else { filter = .all }
            if let ask { chooseAsk(requested: ask.query) }
        }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
        .onReceive(app.libraryFilterRequestValues) { r in
            // The screenshot tour (and anything else) can open Library on a kind, or back on All; Home's tiles and
            // sections open it on what's transcribing ("working") or on a project ("project:<id>"). For the Library
            // tab only; a pushed Library has its own (`route`).
            guard let r, route == nil else { return }
            applyRequest(r)
            // Cleared on the next turn, never inside the publish: when this was `$libraryFilterRequest`, which publishes
            // before the value is stored, clearing it here was overwritten by `r` and each later subscription applied it
            // again.
            DispatchQueue.main.async { if app.libraryFilterRequest == r { app.libraryFilterRequest = nil } }
        }
        .onReceive(app.askRequestValues) { r in
            // Ask from anywhere (`openAsk`): this field with Ask chosen. For the Library tab only; cleared on the next turn.
            guard let r, route == nil else { return }
            chooseAsk(requested: r.query)
            DispatchQueue.main.async { if app.askRequest == r { app.askRequest = nil } }
        }
        .sheet(item: $editingRecipe) { d in PhoneRecipeEditor(draft: d).phoneState(app) }
        .sheet(isPresented: Binding(get: { app.addFromLibrary != nil }, set: { if !$0 { app.addFromLibrary = nil } })) {
            if let p = app.addFromLibrary { PhoneAddFromLibrarySheet(project: p).phoneState(app) }
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
        // A filter asks for recordings: Ask's question leaves the field and Search comes back (IP-39).
        if mode == .ask { mode = .search; search = "" }
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
        if !isTabRoot {
            LargeSerifTitle(title: title, count: countText(items), countValue: countNumber(items))
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
                .modifier(PageRow(top: 0, bottom: 0))
        }
        // The one way into search and Ask (IP-39). Return asks while Ask is chosen.
        SystemSearchField(text: $search, prompt: SearchOrAsk.prompt(mode), focusRequest: focusRequest) { submit() }
            .frame(minHeight: 38)
            .accessibilityIdentifier("library.search")
            .modifier(PageRow(top: isTabRoot ? 4 : 14, bottom: 0))
        let content = self.content
        // Search | Ask, under the field while you type and while Ask is chosen (the kit's switch, as on the Mac's panel).
        if SearchOrAsk.showsSwitch(query: search, mode: mode) {
            RefinedSegmented(label: "Search or ask", options: SearchOrAsk.allCases.map { ($0, $0.title) }, selection: modeBinding)
                .accessibilityIdentifier("library.searchOrAsk")
                .modifier(PageRow(top: 8, bottom: 0))
        }
        // Dictations as a card of its own (November 6, 2026, mockup "Verbose Dictations", frame 3: the pill was too
        // easy to miss), then By day, Templates, Ask, and Projects as one row of small buttons, so recordings start
        // higher (critique, build 283). Not inside a project, and not while you search or ask.
        if project == nil, content == .library {
            dictationsCard
                .modifier(PageRow(top: 8, bottom: 0))
            placesRow
                .modifier(PageRow(top: 8, bottom: 0, edge: 0))
        }
        if content == .ask {
            PhoneAskScopeChips(scope: $askScope)
                .modifier(PageRow(top: 10, bottom: 0, edge: 0))
        } else {
            chips
                .modifier(PageRow(top: 10, bottom: 0, edge: 0))
        }
        let platforms = typeFilter.platformCounts(scoped, searching: searching)
        if content != .ask, typeFilter.source.hasPlatforms, !platforms.isEmpty {
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

    /// Library as a tab's first screen (the Library tab, or a kind's tab like Meetings), not pushed from elsewhere.
    private var isTabRoot: Bool { route == nil || tabTitle != nil }

    /// The pinned title: the count over the title, with Filter and More, or Done and the selection's menu while
    /// selecting.
    @ViewBuilder private func titleRow(items: [Transcript]) -> some View {
        TitleRow(title: title, count: countText(items)) {
            if selecting {
                selectionMenu.padding(.horizontal, 8).frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                Button { selecting = false; selection = [] } label: {
                    Text("Done").refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText)
                        .padding(.horizontal, 8).frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                }
                .buttonStyle(RefinedPress())
            } else {
                if content != .ask { filterMenu(circle: true) }
                moreMenu(circle: true)
            }
        }
    }

    /// The project's name in a project, the tab's name on a kind's tab while it's on that kind ("Meetings"), otherwise
    /// "Library".
    private var title: String {
        if case .project(let p) = filter, let name = app.store.projects.first(where: { $0.id == p })?.name { return name }
        if let tabTitle, case .kind(let k) = filter, k.rawValue == route?.request { return tabTitle }
        return "Library"
    }

    /// Notes the filter and title on screen, for the self-test.
    private func noteShown() {
        if case .kind(let k) = filter { Self.shownKind = k.rawValue } else { Self.shownKind = nil }
        Self.shownTitle = title
        Self.shownMode = mode
        Self.shownQuery = search
    }

    /// The number `countText` shows, so it changes in place.
    private func countNumber(_ items: [Transcript]) -> Int {
        typeFilter == .all && filter == .all && !searching ? recordingCount : items.count
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
        return RefinedChipRow(label: "Filter", margin: 20, selected: otherFilterName != nil ? AnyHashable("other") : current.map { AnyHashable($0) }) {
            RefinedChip(title: LibraryChip.all.label, selected: current == .all) { choose(.all) }
                .id(AnyHashable(LibraryChip.all))
            if let other = otherFilterName {
                RefinedChip(title: other, selected: true) { choose(.all) }
                    .accessibilityHint("Clears this filter.")
                    .id(AnyHashable("other"))
            }
            ForEach(LibraryChip.allCases.filter { $0 != .all }) { c in
                RefinedChip(title: c.label, selected: current == c) { choose(current == c ? .all : c) }
                    .id(AnyHashable(c))
            }
        }
    }

    private func choose(_ chip: LibraryChip) {
        let next: Filter = chip.kind.map { .kind($0) } ?? .all
        let type = LibraryFilter(source: chip.source)
        guard next != filter || type != typeFilter else { return }
        fadeList {
            filter = next
            setType(type)
        }
    }

    /// A chip's change fades the list in as a whole over 150 ms (DESIGN.md §7, view switches): the rows change at once
    /// while the list is clear, then it fades in. No row animates on its own, and nothing waits for it.
    private func fadeList(_ change: () -> Void) {
        listShown = false
        change()
        DispatchQueue.main.async { withAnimation(Motion.crossfade) { listShown = true } }
    }

    /// The project the Library is on, if any.
    private var project: UUID? { if case .project(let p) = filter { return p }; return nil }

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

    /// The places in the row under the Dictations card, in order: By day (sage), Templates (petal), Ask, and Projects
    /// when you have one. Each with its identifier, name, glyph, hue, and the value at its end (none at zero for By day
    /// and Ask). Dictations left the row for its own card (`dictationsCard`, still "library.dictations").
    static func placeRows(todayThoughts: Int, templates: Int, recipes: Int, projects: Int)
        -> [(id: String, title: String, art: BrandArt, hue: RefinedHue, value: String?)] {
        var out: [(id: String, title: String, art: BrandArt, hue: RefinedHue, value: String?)] = [
            ("library.byDay", "By day", .iconCalendar, .sage, todayThoughts > 0 ? "\(todayThoughts) today" : nil),
            ("library.templates", "Templates", .iconSummaries, .petal, "\(templates)"),
            ("library.ask", "Ask", .iconAsk, .neutral, recipes > 0 ? HomeCounts.countLabel(recipes, "recipe", "recipes") : nil),
        ]
        if projects > 0 { out.append(("library.projects", "Projects", .iconProject, .neutral, "\(projects)")) }
        return out
    }

    private var places: [Place] {
        let rows = Self.placeRows(todayThoughts: app.store.todaysThoughts().count,
                                  templates: app.store.allTemplates.count, recipes: app.store.recipes.count,
                                  projects: app.store.projects.count)
        return rows.map { r in
            Place(id: r.id, title: r.title, art: r.art, hue: r.hue, value: r.value, hint: Self.placeHint(r.id)) { open(place: r.id) }
        }
    }

    private static func placeHint(_ id: String) -> String {
        switch id {
        case "library.byDay": return "Opens Thoughts and Journal by day."
        case "library.templates": return "Opens your templates and Run automatically."
        case "library.ask": return "Asks a question about your recordings."
        default: return "Opens your projects."
        }
    }

    /// Pushes a place on the stack the Library is on (the Library tab, or Home or Projects when it's pushed there).
    private func open(place id: String) {
        switch id {
        case "library.byDay": app.pushHere(ByDayRoute(kind: .idea))
        case "library.templates": app.pushHere(TemplatesRoute())
        // The same field, with Ask chosen (IP-39), instead of a page with a field of its own.
        case "library.ask": chooseAsk(requested: nil)
        default: showProjects = true
        }
    }

    /// Dictations as a full-width card between the search field and the places (mockup "Verbose Dictations", frame 3):
    /// the dictations glyph on butter (butter means Dictate), "Dictations" with how many, how long ago the newest was
    /// at the end of that line, the newest one's first line under it, and a chevron. With none: "No dictations yet."
    /// A tap opens Dictations on the stack the Library is on. VoiceOver reads one button.
    private var dictationsCard: some View {
        let newest = dictations.first
        let count = dictations.count
        let ago = newest.map { WidgetSnapshot.ago($0.createdAt, now: Date()) }
        let line = newest.map { HomeDictationText.preview($0) } ?? HomeSection.dictations.emptyLine
        return Button { app.pushHere(DictationsRoute()) } label: {
            HStack(spacing: 12) {
                IconSquare(art: .iconDictations, hue: .butter)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Dictations").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).rowLines()
                        if count > 0 { Text("\(count)").refinedFont(.hint).monospacedDigit().foregroundStyle(Refined.mute).lineLimit(1) }
                        Spacer(minLength: 8)
                        if let ago { Text(ago).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute).lineLimit(1) }
                    }
                    Text(line).refinedFont(.hint).foregroundStyle(newest == nil ? Refined.dim : Refined.mute).rowLines()
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.faint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(RefinedPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictations")
        .accessibilityValue(count == 0 ? "None yet" : "\(count), newest \(ago ?? ""): \(line)")
        .accessibilityHint("Opens every dictation.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("library.dictations")
    }

    /// The places as one row of small buttons under the Dictations card, each pushing on the stack the Library is on: the
    /// glyph, the name, and its value in `mute`, on the card with a hairline so they read apart from the filter chips.
    /// The row scrolls sideways when it doesn't fit; VoiceOver reads it as "Go to" with each place's name and value.
    private var placesRow: some View {
        RefinedChipRow(label: "Go to", margin: 20) {
            ForEach(places) { p in
                Button(action: p.open) {
                    HStack(spacing: 6) {
                        IconGlyph(art: p.art, size: 15, color: Refined.ink)
                        Text(p.title).refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                        if let v = p.value { Text(v).refinedFont(.hint).monospacedDigit().foregroundStyle(Refined.mute).lineLimit(1) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Refined.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Refined.separator, lineWidth: 1))
                    .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RefinedPress())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.title)
                .accessibilityValue(p.value ?? "")
                .accessibilityHint(p.hint)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(p.id)
            }
        }
    }

    /// Add from Library, in a project.
    private func addFromLibrary(_ p: UUID) -> some View {
        Button { app.addFromLibrary = p } label: { IconSquareRow(art: .iconLibrary, hue: .neutral, title: "Add from Library") }
            .buttonStyle(RefinedPress())
            .accessibilityHint("Adds transcripts you already have to this project.")
            .modifier(CardRow(first: true, last: true, divider: 56, top: 16))
    }

    // MARK: Search or ask (IP-39)

    /// The switch: choosing Ask goes through `chooseAsk`, so typed words are asked and an empty field shows the last answer
    /// or puts the keyboard up.
    private var modeBinding: Binding<SearchOrAsk> {
        Binding(get: { mode }, set: { v in if v == .ask { chooseAsk(requested: nil) } else { mode = .search } })
    }

    /// Chooses Ask in the field (the switch, the Ask place, `openAsk`, or a pushed `AskRoute`): `requested` words fill
    /// the field and are asked at once (`SearchOrAsk.enter`).
    private func chooseAsk(requested: String?) {
        let e = SearchOrAsk.enter(query: search, requested: requested, lastQuestion: askCenter.result?.question,
                                  answered: askCenter.phase == .done && askCenter.result != nil)
        mode = .ask
        if let f = e.fill {
            search = f
            // The last answer's question comes back with the scope it was asked in.
            if requested == nil, let r = askCenter.result { askScope = r.scope }
        }
        if e.focus { focusRequest += 1 }
        if e.ask { runAsk() }
    }

    /// Return in the field: asks with Ask chosen; with Search, the keyboard goes away and the matches stay.
    private func submit() {
        if SearchOrAsk.submitAsks(query: search, mode: mode) { runAsk() }
    }

    /// Asks the field's words in the chosen scope, with the keyboard put away.
    private func runAsk() {
        guard !trimmedSearch.isEmpty else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        askCenter.ask(trimmedSearch, scope: askScope)
    }

    @ViewBuilder private func passagesSection(_ passages: [LibrarySearch.PassageHit]) -> some View {
        SectionTitle("Passages")
            .modifier(PageRow(top: 18, bottom: 6))
        ForEach(passages) { hit in
            PhonePassageCard(transcript: hit.transcript, lines: hit.lines, count: hit.count, query: search)
                .modifier(PageRow(top: 4, bottom: 4))
        }
    }

    /// The kind this screen is the tab for (Meetings, Brain dumps), while it shows that kind and nothing else.
    private var kindTabKind: RecordingKind? {
        guard tabTitle != nil, typeFilter == .all, case .kind(let k) = filter, k.rawValue == route?.request else { return nil }
        return k
    }

    /// A kind's tab with nothing in it (IP-31): the kit's empty state with the kind's glyph and color, what it's for,
    /// and how to record one, instead of "Choose All".
    private func kindEmptyState(_ k: RecordingKind) -> some View {
        let name = RecordChoice.kind(k).name
        let title = k == .audio ? "No Audio only recordings yet" : "No \(k.plural.lowercased()) yet"
        return RefinedEmptyState(art: k.refinedArt, hue: k.refinedHue, title: title,
                                 message: "Tap Record below to start one, or touch and hold Record and choose \(name).",
                                 action: k == .audio ? "Record audio only" : "Record \(k == .interview ? "an" : "a") \(name.lowercased())") {
            AccessoryRecordButton.start(TabRecordDefault.forTab(app.tab), app)
        }
        .modifier(PageRow(top: 16, bottom: 8))
    }

    private func emptyState(project: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(searching ? "Nothing matches \u{201C}\(trimmedSearch)\u{201D}" : project != nil ? "Nothing in this project yet" : "Nothing here yet")
                .refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
            Text(searching ? "Search looks at titles and every transcript's words."
                 : project != nil ? "Add transcripts from your library."
                 : filter != .all || typeFilter != .all ? "Choose All to see every recording."
                 : (app.macSeen ? "Tap Record to start one. Recordings and imports land here, and on your Mac." : "Tap Record to start one. Recordings and imports land here."))
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
            // A swipe action tells the celebrations to wait for it to settle (SwipeSettle).
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { CelebrationCenter.shared.swiped(); app.delete([t.id]) } label: { Label("Delete", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
                Button { CelebrationCenter.shared.swiped(); app.togglePin(t.id) } label: { Label(t.pinned ? "Unpin" : "Pin", systemImage: t.pinned ? "pin.slash" : "pin") }   // brand: system surface (swipe action)
                    .tint(Refined.accentFillFixed)   // white on it in dark too (IP-03)
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
            if content != .ask { ToolbarItem(placement: .topBarTrailing) { filterMenu(circle: false) } }
            ToolbarItem(placement: .topBarTrailing) { moreMenu(circle: false) }
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
            Button { app.exportRequest = ExportRequest(ids: Array(selection)) } label: { Label("Export", systemImage: "square.and.arrow.up") }
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
    private func filterMenu(circle: Bool) -> some View {
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
            if circle {
                TitleCircle { IconGlyph(art: .iconFilter, size: 18, color: Refined.ink) }   // Our glyph, as Thoughts' circles use (IP-25).
            } else {
                ToolbarArt(art: .iconFilter, key: "filter")
            }
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(choice == "all" ? "All recordings" : (otherFilterName ?? currentChip?.label ?? ""))
        .accessibilityIdentifier("library.filter")
    }

    /// More: Select recordings, Recently Deleted, and New project; with Ask chosen, Ask's actions in place of Select.
    private func moreMenu(circle: Bool) -> some View {
        Menu {
            // With Ask chosen, Ask's actions come first: Copy, Save as recipe, Recipes, and Recent questions.
            if content == .ask {
                PhoneAskMenuItems(recall: { h in search = h.question; askScope = h.scope }, editing: $editingRecipe)
                Divider()
            } else {
                Button { selecting = true } label: { Label("Select recordings", systemImage: "checkmark.circle") }   // brand: system surface (menu)
            }
            Button { showTrash = true } label: { Label("Recently Deleted", systemImage: "trash") }
            Button { newProject = true } label: { Label("New project…", systemImage: "folder.badge.plus") }   // brand: system surface (menu)
        } label: {
            if circle {
                TitleCircle { Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Refined.ink) }
            } else {
                Image(systemName: "ellipsis")
            }
        }
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

    /// A row's badge: pale while its recording transcribes (or waits to), full once it's ready or didn't finish
    /// (DESIGN.md §7, Celebrations).
    static func badgeFill(_ t: Transcript) -> CGFloat { t.status == .processing ? 0 : 1 }

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
///
/// While it transcribes, its badge is pale (the kind's tint with an ink glyph); when it's ready with the row on screen,
/// the full-color disc grows from the center and bounces, and the meta line reads "Ready" for 1.6 s (DESIGN.md §7,
/// Celebrations), all over the row, so its height never changes.
private struct LibraryRow: View {
    @Environment(PhoneState.self) var app
    @ObservedObject private var celebrations = CelebrationCenter.shared
    var transcript: Transcript
    var selecting: Bool

    var body: some View {
        let ticket = celebrations.ready[transcript.id].flatMap { $0.surface == .libraryRow ? $0 : nil }
        return CelebrationBurst(ticket: ticket, script: .row) { burst in
            // The live progress (StageClock): a tick re-renders this row, not the Library.
            LiveStage(transcript) { t in
                VStack(alignment: .leading, spacing: 0) {
                    if selecting {
                        face(t, burst: burst)
                    } else {
                        Button { app.open(t.id) } label: { face(t, burst: burst) }
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
        // Rows on screen, for which surface a finished transcript celebrates on (ReadyCelebration).
        .onAppear { celebrations.rowAppeared(transcript.id) }
        .onDisappear { celebrations.rowLeft(transcript.id) }
    }

    private func face(_ t: Transcript, burst: BurstState) -> some View {
        let meta = LibraryScreen.rowMeta(t)
        let length = t.duration > 0 && !(t.kind == .idea && t.audioFileName == nil) ? HomeRecentStyle.length(t.duration) : nil
        return PaperRow(kind: t.refinedKind, title: RecordingRowTitle.title(t, withTime: false), meta: meta, badge: 32, pinned: t.pinned,
                        badgeFill: LibraryScreen.badgeFill(t), celebration: burst.active ? burst : nil) {
            if let length { RowLength(text: length) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([t.pinned ? "Pinned" : nil, RecordingRowTitle.title(t, withTime: false), meta,
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
    @Environment(PhoneState.self) var app
    var transcript: Transcript
    var lines: [Segment]
    var count: Int
    var query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(transcript.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).rowLines()
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
