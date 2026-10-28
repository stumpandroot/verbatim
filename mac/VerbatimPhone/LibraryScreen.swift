import SwiftUI

/// The Library in the website style: a compact serif title with the count in mono, a search field on the paper, one
/// row of soft filter chips (types with a color dot, kinds, pinned, in progress, and each project), mono day headers,
/// and flat rows with hairlines: the serif title, a meta line, and the state as a plain word over the length in mono.
/// Drag a row onto a project chip to move it there.
struct LibraryScreen: View {
    @EnvironmentObject var app: PhoneState
    /// The search and the chip, kept when a look switch rebuilds Library (`LookKeep`).
    @State private var search = LookKeep.librarySearch
    @State private var filter: Filter = LookKeep.libraryFilter
    /// Type and platform chips, remembered on this iPhone.
    @State private var typeFilter = LibraryFilter.saved(LibraryFilter.libraryKey)
    @State private var newProject = false
    @State private var projectName = ""
    /// Newest, Oldest, Longest, or Title A–Z, remembered on this iPhone.
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }
    @Environment(\.look) private var look
    /// Pushed inside another tab (Library isn't in the bar, or a project from the Projects tab), opened on this chip.
    /// Nil for the Library tab itself.
    var route: LibraryRoute? = nil
    @State private var routeApplied = false
    /// Native: Select recordings, the selection, and the pushes from More and the Projects row.
    @State var nativeSelecting = false
    @State var nativeSelection = Set<UUID>()
    @State var nativeShowTrash = false
    @State var nativeShowProjects = false

    enum Filter: Hashable { case all, pinned, working, project(UUID), kind(RecordingKind) }

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The chip filter and the search, before the type chips (which count over this). Dictations are included here;
    /// `LibraryFilter.apply` leaves them out unless you're searching or chose Dictations.
    private var scoped: [Transcript] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filter = self.filter
        // Once per library change, chip, and search (Store+Memo.swift), not on every render.
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
    private var scopeKey: String { "\(String(describing: filter))|\(search.trimmingCharacters(in: .whitespaces).lowercased())" }

    /// Dictations, newest first. They have their own list, reached from the row at the top (and Home's Dictate).
    private var dictations: [Transcript] {
        app.store.memo("phone.dictations") { app.store.live.filter(\.isDictation).sorted { $0.createdAt > $1.createdAt } }
    }

    /// Live recordings that aren't dictations: the title's count.
    private var recordingCount: Int { app.store.memo("phone.recording-count") { app.store.live.filter { !$0.isDictation }.count } }

    /// The list, with a day header before each day's first row when the order is by date.
    private enum Line: Identifiable {
        case day(Date, String)
        case row(Transcript, Int)
        var id: AnyHashable {
            switch self {
            case .day(let d, _): return AnyHashable("day-\(d.timeIntervalSince1970)")
            case .row(let t, _): return AnyHashable(t.id)
            }
        }
    }

    private func lines(_ items: [Transcript]) -> [Line] {
        // The same list's lines once per library change and day; day headers say "Today" and "Yesterday".
        app.store.memo("phone.lines|\(scopeKey)|\(typeFilter.raw)|\(sort.rawValue)|\(Store.dayKey())|\(items.count)") { makeLines(items) }
    }

    private func makeLines(_ items: [Transcript]) -> [Line] {
        let byDate = sort == .newest || sort == .oldest
        let cal = Calendar.current
        var out: [Line] = []
        var lastDay: Date? = nil
        for (i, t) in items.enumerated() {
            if byDate {
                let day = cal.startOfDay(for: t.createdAt)
                if day != lastDay { out.append(.day(day, PhoneDayHeader.label(day))); lastDay = day }
            }
            out.append(.row(t, i))
        }
        return out
    }

    var body: some View {
        // `scoped` searches every transcript's text; work it out once per render.
        let scoped = self.scoped
        let searching = self.searching, typeFilter = self.typeFilter, sort = self.sort
        let items = app.store.memo("phone.items|\(scopeKey)|\(typeFilter.raw)|\(sort.rawValue)") { sort.sorted(typeFilter.apply(scoped, searching: searching)) }
        let passages = search.trimmingCharacters(in: .whitespaces).count >= 2 ? LibrarySearch.passages(items, query: search, perTranscript: 3, cap: 60) : []
        let project: UUID? = { if case .project(let p) = filter { return p }; return nil }()
        Group {
        if look.isNative {
            nativeList(scoped: scoped, items: items, passages: passages, project: project)
        } else {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    PhoneCompactTitle(title: "Library", count: "\(recordingCount)")
                    PhoneSearchField(text: $search, prompt: "Find the line you need")
                }
                .padding(.top, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)).listRowBackground(Color.clear).listRowSeparator(.hidden)
                chips(scoped)
                    .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 4, trailing: 0)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if let p = project {
                Section {
                    Button { app.addFromLibrary = p } label: {
                        HStack(spacing: 10) {
                            ArtIcon(art: .iconLibrary, size: 18)
                            Text("Add from Library").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.lookMute)
                        }
                        .foregroundStyle(.lookInk)
                        .padding(.horizontal, 14).frame(minHeight: 48)
                        .phoneOutlined(radius: Radius.row, line: 1)
                        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    }
                    .buttonStyle(PhoneCardPress())
                    .accessibilityHint("Adds transcripts you already have to this project")
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            // Dictations, By day (Thoughts and Journal), Templates, and Ask: one row of compact tiles, so the first
            // recording starts near the top. Buttons, not NavigationLinks, so the list never adds its own chevron.
            if filter == .all, search.isEmpty, typeFilter == .all {
                Section {
                    LibraryWaysIn(dictations: dictations.count, todayThoughts: app.store.todaysThoughts().count,
                                  templates: app.store.allTemplates.count, recipes: app.store.recipes.count)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            // The search field takes questions too: ask about what you typed.
            if searching {
                Section {
                    AskAboutRow(query: search.trimmingCharacters(in: .whitespaces))
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            if !passages.isEmpty {
                Section {
                    PhoneDayHeader(text: "Passages")
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    ForEach(passages) { hit in
                        PhonePassageCard(transcript: hit.transcript, lines: hit.lines, count: hit.count, query: search)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
            }
            Section {
                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if search.isEmpty { IconPlate(art: .iconLibrary, size: 96) } else { EmptyStateArt(art: .search, tint: Ink.butterTint) }
                        Text(!search.isEmpty ? "Nothing matches “\(search)”."
                             : typeFilter != .all ? "Nothing here matches \(typeFilter.platform ?? typeFilter.source.label)."
                             : project != nil ? "Nothing in this project yet. Add transcripts from your library."
                             : "Nothing here yet.").font(.system(size: 15)).foregroundStyle(.lookDim)
                    }
                    .padding(.top, 16)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(lines(items)) { line in
                    switch line {
                    case .day(_, let label):
                        PhoneDayHeader(text: label)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    case .row(let t, let i):
                        row(t, index: i)
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        }
        }
        .modifier(NativeSearchable(enabled: look.isNative, text: $search))
        .onChange(of: search) { _, v in if route == nil { LookKeep.librarySearch = v } }
        .onChange(of: filter) { _, v in if route == nil { LookKeep.libraryFilter = v } }
        .onAppear {
            // Pushed: starts on its own chip and an empty search, once.
            guard let route, !routeApplied else { return }
            routeApplied = true
            search = ""
            if let r = route.request { applyRequest(r) } else { filter = .all }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .phoneTopFade()
        .phonePage(plain: true)
        .navigationTitle("Library")
        .nativeSubtitle(look.isNative ? nativeSubtitleText(items) : nil)
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
        .toolbar {
            if look.isNative {
                nativeToolbar
            } else {
                // Verbose style: the serif title sits on the paper; the bar keeps only Apple's buttons.
                ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sortRaw) {
                            ForEach(LibrarySort.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s.rawValue) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .accessibilityLabel("Sort by \(sort.title)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { TrashScreen() } label: { Image(systemName: "trash") }.accessibilityLabel("Recently Deleted")
                }
            }
        }
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

    /// Puts the Library on a chip from a request: "working", "project:<id>", "source:<type>" (Marked, Links), a kind's
    /// raw value, or anything else for All.
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

    // MARK: Rows

    private func row(_ t: Transcript, index i: Int) -> some View {
        Group {
            if t.showsAudioDetail {
                // Audio only: a waveform card you can play from the list (AudioDetailScreen.swift).
                PhoneAudioCard(transcript: t)
            } else {
                Button { app.open(t.id) } label: {
                    PhoneFlatRow(transcript: t, meta: Self.meta(t)) { PhoneRowState(transcript: t) }
                }
                .buttonStyle(PhoneCardPress())
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
        .contextMenu { RowActions(transcript: t) }
        .draggable(TranscriptDrag.payload([t.id]))   // drop onto a project chip
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { app.delete([t.id]) } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button { app.togglePin(t.id) } label: { Label(t.pinned ? "Unpin" : "Pin", systemImage: "pin") }.tint(Ink.sageText)   // brand: system surface (swipe action)
        }
    }

    /// "Meeting · Tim, Jonathan", "Voice note · Idea", "Journal · 3 moments", "youtube.com · Video".
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

    // MARK: Chips

    /// Two rows of soft chips. The first is All and the types; the types stay put as you pick (every type the library
    /// has, counted inside the current chip and search, dimmed at zero). Platforms for Videos and Links sit under it,
    /// then kinds, Pinned, In progress, and the projects. A type and the other filters don't combine: choosing one
    /// clears the other.
    private func chips(_ scoped: [Transcript]) -> some View {
        let inScope = Dictionary(typeFilter.sourceCounts(scoped, searching: searching), uniquingKeysWith: { a, _ in a })
        let sources = Self.fixedSources(library: app.store.memo("phone.sources-present") {
            Set(LibraryFilter.all.sourceCounts(app.store.live, searching: false).filter { $0.1 > 0 }.map(\.0))
        }, selected: typeFilter.source)
        let platforms = typeFilter.platformCounts(scoped, searching: searching)
        let present = app.store.memo("phone.kinds-present") { Set(app.store.live.compactMap(\.kind)) }
        let kinds = RecordingKind.pickable.filter { k in present.contains(k) || filter == .kind(k) }
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PhoneChip(label: "All", selected: filter == .all && typeFilter == .all) { pick(.all); setType(.all) }
                    ForEach(sources) { s in
                        let n = inScope[s] ?? 0
                        let on = typeFilter.source == s
                        PhoneChip(label: s.label, selected: on, dot: Self.dot(s)) {
                            pick(.all)
                            setType(on ? .all : LibraryFilter(source: s))
                        }
                        .opacity(n == 0 && !on ? 0.45 : 1)
                        .disabled(n == 0 && !on)
                        .accessibilityValue(n == 0 ? "None here" : "\(n)")
                    }
                }
                .padding(.horizontal, 20)
            }
            if typeFilter.source.hasPlatforms, !platforms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(platforms, id: \.0) { p, n in
                            PhoneChip(label: p, selected: typeFilter.platform == p, count: n) {
                                setType(LibraryFilter(source: typeFilter.source, platform: typeFilter.platform == p ? nil : p))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .accessibilityElement(children: .contain).accessibilityLabel("Platform")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(kinds) { k in chip(k.plural, .kind(k)) }
                    chip("Pinned", .pinned)
                    chip("In progress", .working)
                    ForEach(app.store.projects) { p in
                        chip(p.name, .project(p.id))
                            .dropDestination(for: String.self) { items, _ in
                                let ids = items.flatMap { TranscriptDrag.ids(from: $0) }
                                guard !ids.isEmpty else { return false }
                                for id in ids { app.move(id, to: p.id) }
                                app.say(ids.count == 1 ? "Moved to \(p.name)" : "Moved \(ids.count) to \(p.name)")
                                Haptics.play(.smallSave)
                                return true
                            }
                    }
                    Button { newProject = true } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.lookInk)
                            .frame(width: 32, height: 32)
                            .background(PhoneInk.wash, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    }
                    .buttonStyle(PhoneCardPress())
                    .accessibilityLabel("New project")
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// The type chips, in a fixed order: every type the library has, plus the chosen one. Picking a kind or searching
    /// never adds or removes one, so the row doesn't shift under your finger.
    static func fixedSources(library present: Set<LibrarySource>, selected: LibrarySource) -> [LibrarySource] {
        LibrarySource.allCases.filter { $0 != .all && (present.contains($0) || $0 == selected) }
    }

    private func chip(_ label: String, _ f: Filter) -> some View {
        PhoneChip(label: label, selected: filter == f) {
            pick(filter == f ? .all : f)
            setType(.all)
        }
    }

    /// Chip taps never animate rows (high-frequency); the list changes in place.
    private func pick(_ f: Filter) { filter = f }

    private func setType(_ f: LibraryFilter) {
        guard f != typeFilter else { return }
        typeFilter = f
        typeFilter.save(LibraryFilter.libraryKey)
    }

    /// The source's color, as on Home: voice notes record, files and links sage, app audio petal, dictation butter.
    static func dot(_ s: LibrarySource) -> Color? {
        switch s {
        case .all: return nil
        case .voiceMemos: return PhoneInk.record
        case .videos, .audioFiles, .links: return PhoneInk.sage
        case .appAudio: return PhoneInk.petal
        case .dictations: return PhoneInk.butter
        }
    }
}

// MARK: - Native look
// brand: native begin

/// Applies `.searchable` in the Native look, where the search field sits under the large title. The system field keeps
/// its microphone, which dictates into it.
private struct NativeSearchable: ViewModifier {
    var enabled: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles and words")
        } else {
            content
        }
    }
}

/// The Library in the Native look (mockup "Verbose Native Redesign", section 2): a plain list like Mail's inbox. Rows
/// for Dictations, Projects, By day, Templates, and Ask at the top, like Mail's mailboxes (and Moments when it isn't a
/// tab), then the recordings under day headers: the title and time, the kind, length, and names, and two lines of what
/// was said. The filter is a system menu behind the filter button, which fills while a filter is on; Sort by and
/// Select recordings sit in it too. Swipe a row to delete or pin it. A plain, lazy `List`; nothing enters with an
/// animation.
extension LibraryScreen {
    /// The filter menu's choices as tags: "all", "source:<raw>", "kind:<raw>", "pinned", "working", "project:<id>".
    var nativeChoice: String {
        if typeFilter != .all { return "source:\(typeFilter.source.rawValue)" }
        switch filter {
        case .all: return "all"
        case .pinned: return "pinned"
        case .working: return "working"
        case .kind(let k): return "kind:\(k.rawValue)"
        case .project(let p): return "project:\(p.uuidString)"
        }
    }

    func setNativeChoice(_ tag: String) {
        if tag.hasPrefix("source:"), let s = LibrarySource(rawValue: String(tag.dropFirst("source:".count))) {
            pick(.all); setType(LibraryFilter(source: s))
        } else if tag == "pinned" { pick(.pinned); setType(.all) }
        else if tag == "working" { pick(.working); setType(.all) }
        else if tag.hasPrefix("kind:"), let k = RecordingKind(rawValue: String(tag.dropFirst("kind:".count))) { pick(.kind(k)); setType(.all) }
        else if tag.hasPrefix("project:"), let id = UUID(uuidString: String(tag.dropFirst("project:".count))) { pick(.project(id)); setType(.all) }
        else { pick(.all); setType(.all) }
    }

    /// The navigation subtitle: "25 recordings", or with a filter on, how many it shows ("8 meetings").
    func nativeSubtitleText(_ items: [Transcript]) -> String {
        let n = items.count
        if typeFilter != .all { return "\(n) \(typeFilter.source.label.lowercased())" }
        switch filter {
        case .all: return HomeCounts.countLabel(recordingCount, "recording", "recordings")
        case .pinned: return "\(n) pinned"
        case .working: return "\(n) in progress"
        case .kind(let k): return n == 1 ? "1 \(k.label.lowercased())" : "\(n) \(k.plural.lowercased())"
        case .project(let p): return "\(HomeCounts.countLabel(n, "recording", "recordings")) in \(app.store.projects.first { $0.id == p }?.name ?? "the project")"
        }
    }

    func nativeList(scoped: [Transcript], items: [Transcript], passages: [LibrarySearch.PassageHit], project: UUID?) -> some View {
        let now = Date()
        let days = Self.daySections(lines(items))
        let browsing = filter == .all && search.isEmpty && typeFilter == .all && !nativeSelecting
        return List(selection: $nativeSelection) {
            if !NativeSubtitle.supported {
                Text(nativeSubtitleText(items)).font(.subheadline).foregroundStyle(NativeInk.secondary)
                    .listRowSeparator(.hidden)
            }
            if browsing { mailboxes }
            if let p = project, !nativeSelecting {
                Button { app.addFromLibrary = p } label: { Label("Add from Library", systemImage: "plus.circle") }
                    .accessibilityHint("Adds transcripts you already have to this project")
            }
            if searching {
                AskAboutRow(query: search.trimmingCharacters(in: .whitespaces))
                    .listRowSeparator(.hidden)
            }
            if !passages.isEmpty {
                Section {
                    ForEach(passages) { hit in
                        PhonePassageCard(transcript: hit.transcript, lines: hit.lines, count: hit.count, query: search)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                } header: { Text("Passages") }
            }
            if items.isEmpty {
                Group {
                    if !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ContentUnavailableView {
                            Label(project != nil ? "Nothing in this project yet" : "No recordings here", systemImage: "waveform")
                        } description: {
                            Text(project != nil ? "Add transcripts from your library." : "Tap Record to start one.")
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(days, id: \.label) { day in
                Section {
                    ForEach(day.items) { t in nativeRow(t, now: now) }
                } header: {
                    if !day.label.isEmpty { Text(day.label).font(.headline).foregroundStyle(NativeInk.label).textCase(nil) }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(nativeSelecting ? .active : .inactive))
        .navigationDestination(isPresented: $nativeShowTrash) { TrashScreen() }
        .navigationDestination(isPresented: $nativeShowProjects) { ProjectsScreen() }
    }

    /// The recordings grouped under their day headers ("Today", "Yesterday", "Mon Oct 19"); one unnamed group when the
    /// order isn't by date.
    private static func daySections(_ lines: [Line]) -> [(label: String, items: [Transcript])] {
        var out: [(label: String, items: [Transcript])] = []
        for line in lines {
            switch line {
            case .day(_, let label): out.append((PhoneDayHeader.nativeLabel(label), []))
            case .row(let t, _):
                if out.isEmpty { out.append(("", [])) }
                out[out.count - 1].items.append(t)
            }
        }
        return out.filter { !$0.items.isEmpty }
    }

    /// Dictations, Projects, By day, Templates, and Ask, like Mail's mailboxes: a blue symbol, the name, a count, and a
    /// chevron. Moments left them in the consolidation: it's the filter's Marked type.
    @ViewBuilder private var mailboxes: some View {
        let today = app.store.todaysThoughts().count
        mailbox("Dictations", symbol: "text.bubble", value: "\(dictations.count)", id: "library.dictations") { app.pushHere(DictationsRoute()) }
        mailbox("Projects", symbol: "folder", value: "\(app.store.projects.count)", id: "library.projects") { nativeShowProjects = true }
        mailbox("By day", symbol: "calendar", value: today > 0 ? "\(today) today" : nil, id: "library.byDay") { app.pushHere(ByDayRoute(kind: .idea)) }
        mailbox("Templates", symbol: "doc.text", value: "\(app.store.allTemplates.count)", id: "library.templates") { app.pushHere(TemplatesRoute()) }
        mailbox("Ask", symbol: "questionmark.bubble", value: app.store.recipes.isEmpty ? nil : "\(app.store.recipes.count) recipes", id: "library.ask") { app.pushHere(AskRoute()) }
    }

    private func mailbox(_ title: String, symbol: String, value: String?, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(NativeInk.accent).frame(width: 28)
                Text(title).foregroundStyle(NativeInk.label)
                Spacer(minLength: 8)
                if let value { Text(value).monospacedDigit().foregroundStyle(NativeInk.secondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(NativeInk.tertiary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func nativeRow(_ t: Transcript, now: Date) -> some View {
        NavigationLink(value: t.id) { NativeLibraryRow(transcript: t, now: now) }
            .tag(t.id)
            .contextMenu { RowActions(transcript: t) }
            .draggable(TranscriptDrag.payload([t.id]))
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { app.delete([t.id]) } label: { Label("Delete", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
                Button { app.togglePin(t.id) } label: { Label(t.pinned ? "Unpin" : "Pin", systemImage: t.pinned ? "pin.slash" : "pin") }
                    .tint(Color(uiColor: .systemOrange))
            }
    }

    /// The toolbar: the filter menu (Show, Sort by, Select recordings) and More (Recently Deleted, New project). While
    /// selecting: Done, and what to do with the selected recordings.
    @ToolbarContentBuilder var nativeToolbar: some ToolbarContent {
        if nativeSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { nativeSelecting = false; nativeSelection = [] }.fontWeight(.semibold)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu {
                        ForEach(app.store.projects) { p in
                            Button(p.name) { app.addToProject(Array(nativeSelection), p.id); nativeSelecting = false; nativeSelection = [] }
                        }
                    } label: { Label("Add to project", systemImage: "folder.badge.plus") }
                    .disabled(app.store.projects.isEmpty)
                    Button { app.exportRequest = PhoneExportRequest(ids: Array(nativeSelection)) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button(role: .destructive) {
                        app.delete(Array(nativeSelection)); nativeSelecting = false; nativeSelection = []
                    } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Text(nativeSelection.isEmpty ? "Select" : "\(nativeSelection.count) selected")
                }
                .disabled(nativeSelection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(selection: Binding(get: { nativeChoice }, set: { setNativeChoice($0) })) {
                        Text("All recordings").tag("all")
                        ForEach(nativeSources) { s in Text(s.label).tag("source:\(s.rawValue)") }
                        ForEach(nativeKinds) { k in Text(k.plural).tag("kind:\(k.rawValue)") }
                        Text("Pinned").tag("pinned")
                        Text("In progress").tag("working")
                        ForEach(app.store.projects) { p in Text(p.name).tag("project:\(p.id.uuidString)") }
                    } label: { Text("Show") }
                    .pickerStyle(.inline)
                    Section {
                        Picker(selection: $sortRaw) {
                            ForEach(LibrarySort.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s.rawValue) }
                        } label: {
                            Label("Sort by", systemImage: "arrow.up.arrow.down")
                            Text(sort.title)
                        }
                        .pickerStyle(.menu)
                        Button { nativeSelecting = true } label: { Label("Select recordings", systemImage: "checkmark.circle") }
                    }
                } label: {
                    Image(systemName: nativeChoice == "all" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter")
                .accessibilityValue(nativeChoice == "all" ? "All recordings" : nativeSubtitleText([]))
                .accessibilityIdentifier("library.filter")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { nativeShowTrash = true } label: { Label("Recently Deleted", systemImage: "trash") }
                    Button { newProject = true } label: { Label("New project…", systemImage: "folder.badge.plus") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
            }
        }
    }

    /// The types the library has (and the one chosen), in a fixed order.
    private var nativeSources: [LibrarySource] {
        let present = app.store.memo("phone.sources-present") {
            Set(LibraryFilter.all.sourceCounts(app.store.live, searching: false).filter { $0.1 > 0 }.map(\.0))
        }
        return Self.fixedSources(library: present, selected: typeFilter.source).filter { $0 != .dictations }
    }

    private var nativeKinds: [RecordingKind] {
        let present = app.store.memo("phone.kinds-present") { Set(app.store.live.compactMap(\.kind)) }
        return RecordingKind.pickable.filter { k in present.contains(k) || filter == .kind(k) }
    }
}
// brand: native end

/// One transcript's matching lines from a search: tap a line to open the transcript there, with the audio cued to it.
struct PhonePassageCard: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var lines: [Segment]
    var count: Int
    var query: String
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(transcript.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
                Spacer(minLength: 6)
                Text(count == 1 ? "1 match" : "\(count) matches").font(.system(size: 12.5)).foregroundStyle(.lookMute)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            ForEach(lines) { s in
                Button { app.open(transcript.id, segment: s.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(s.start.timecode).lookMono(12).foregroundStyle(.lookAccentText).frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if transcript.speakers.count >= 2, let sp = transcript.speakerName(s.speaker) {
                                Text(sp).font(.system(size: 12, weight: .semibold)).foregroundStyle(.lookMute)
                            }
                            Text(marked(s.text)).font(.system(size: 15)).foregroundStyle(.lookInk).lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SoftPress())
                .accessibilityHint("Opens the transcript at \(s.start.timecode)")
            }
        }
        .padding(.bottom, 6)
        .cardSurface(radius: Radius.row)
    }

    private func marked(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return a }
        var start = a.startIndex
        while start < a.endIndex, let r = a[start...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = look.isNative ? NativeFind.highlight : Ink.persimmonTint; a[r].font = .system(size: 15, weight: .semibold)
            start = r.upperBound
        }
        return a
    }
}

/// Library's ways in (Verbose style): Dictations, By day (Thoughts and Journal), Templates, and Ask as one row of
/// compact outlined tiles in one style, each the icon, a count in mono, and the name. Each tile is a Button that pushes
/// on the stack the Library is on (the Library tab, or Home or Projects when it's pushed there), so the list never adds
/// a disclosure chevron. At accessibility text sizes the tiles wrap two by two.
struct LibraryWaysIn: View {
    @EnvironmentObject var app: PhoneState
    var dictations: Int
    var todayThoughts: Int
    var templates: Int
    var recipes: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 13.5

    /// The four tiles, in order: name, count (nil shows none), and VoiceOver's label.
    static func tiles(dictations: Int, todayThoughts: Int, templates: Int, recipes: Int) -> [(name: String, count: Int?, label: String)] {
        let today: String = todayThoughts == 1 ? "By day, 1 thought today" : todayThoughts > 0 ? "By day, \(todayThoughts) thoughts today" : "By day"
        let asks: String = recipes == 1 ? "Ask, 1 recipe" : recipes > 0 ? "Ask, \(recipes) recipes" : "Ask"
        return [(name: "Dictations", count: Optional(dictations), label: "Dictations, \(dictations)"),
                (name: "By day", count: todayThoughts > 0 ? Optional(todayThoughts) : nil, label: today),
                (name: "Templates", count: Optional(templates), label: "Templates, \(templates)"),
                (name: "Ask", count: recipes > 0 ? Optional(recipes) : nil, label: asks)]
    }

    var body: some View {
        let t = Self.tiles(dictations: dictations, todayThoughts: todayThoughts, templates: templates, recipes: recipes)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 2 : 4)
        LazyVGrid(columns: columns, spacing: 8) {
            tile(t[0], art: .iconDictations, id: "library.dictations", hint: "Opens every dictation") { app.pushHere(DictationsRoute()) }
            tile(t[1], art: .iconCalendar, id: "library.byDay", hint: "Opens Thoughts and Journal by day") { app.pushHere(ByDayRoute(kind: .idea)) }
            tile(t[2], art: .iconSummaries, id: "library.templates", hint: "Opens your templates and Run automatically") { app.pushHere(TemplatesRoute()) }
            tile(t[3], art: .iconAsk, id: "library.ask", hint: "Asks a question about your recordings") { app.pushHere(AskRoute()) }
        }
    }

    private func tile(_ t: (name: String, count: Int?, label: String), art: BrandArt, id: String, hint: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    IconGlyph(art: art, size: 18, color: Ink.ink)
                    Spacer(minLength: 0)
                    if let n = t.count { Text("\(n)").font(Ink.mono(12)).foregroundStyle(.lookMute).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Text(t.name).font(.system(size: nameSize, weight: .semibold)).foregroundStyle(.lookInk)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .phoneOutlined(radius: Radius.tile, line: 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t.label)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
    }
}
