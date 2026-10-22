import SwiftUI

/// Every transcript, searchable, with filter chips for pinned, in progress, and each project, plus the shared type
/// and platform chips (LibraryFilterBar). A project's view adds transcripts from the rest of the library.
struct LibraryScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var search = ""
    @State private var filter: Filter = .all
    /// Type and platform chips, remembered on this iPhone.
    @State private var typeFilter = LibraryFilter.saved(LibraryFilter.libraryKey)
    @State private var newProject = false
    @State private var projectName = ""
    /// Rows rise in once; the first screenful staggers when you switch to Library.
    @State private var seen = SeenRows()
    @State private var entrance = 0
    /// Newest, Oldest, Longest, or Title A–Z, remembered on this iPhone.
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }

    enum Filter: Hashable { case all, pinned, working, project(UUID), kind(RecordingKind) }

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The chip filter and the search, before the type chips (which count over this). Dictations are included here;
    /// `LibraryFilter.apply` leaves them out unless you're searching or chose Dictations.
    private var scoped: [Transcript] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return app.store.live.filter { t in
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
        }
    }

    /// Press-and-hold dictations, newest first. They have their own list, reached from the card at the top.
    private var dictations: [Transcript] {
        app.store.live.filter(\.isDictation).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        // `scoped` searches every transcript's text; work it out once per render.
        let scoped = self.scoped
        let items = sort.sorted(typeFilter.apply(scoped, searching: searching))
        let passages = search.trimmingCharacters(in: .whitespaces).count >= 2 ? LibrarySearch.passages(items, query: search, perTranscript: 3, cap: 60) : []
        let project: UUID? = { if case .project(let p) = filter { return p }; return nil }()
        let heroKind: RecordingKind? = { if case .kind(let k) = filter { return k }; return nil }()
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", .all)
                        ForEach(RecordingKind.pickable) { k in chip(k.plural, .kind(k)) }
                        chip("Pinned", .pinned)
                        chip("In progress", .working)
                        ForEach(app.store.projects) { p in
                            chip(p.name, .project(p.id))
                                .dropDestination(for: String.self) { items, _ in
                                    let ids = items.flatMap { TranscriptDrag.ids(from: $0) }
                                    guard !ids.isEmpty else { return false }
                                    for id in ids { app.move(id, to: p.id) }
                                    app.say(ids.count == 1 ? "Moved to \(p.name)" : "Moved \(ids.count) to \(p.name)")
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    return true
                                }
                        }
                        Button { newProject = true } label: { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32) }
                            .buttonStyle(TactileButtonStyle()).accessibilityLabel("New project")
                    }
                    .padding(.horizontal, 20)
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                LibraryFilterBar(filter: $typeFilter, items: scoped, searching: searching, wraps: false) {
                    typeFilter.save(LibraryFilter.libraryKey)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if let p = project {
                Section {
                    Button { app.addFromLibrary = p } label: {
                        HStack(spacing: 10) {
                            ArtIcon(art: .iconLibrary, size: 18)
                            Text("Add from Library").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                        }
                        .foregroundStyle(Ink.ink)
                        .padding(.horizontal, 14).frame(minHeight: 48)
                        .cardSurface(radius: Radius.row)
                        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    }
                    .buttonStyle(SoftPress())
                    .accessibilityHint("Adds transcripts you already have to this project")
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            if filter == .all, search.isEmpty, typeFilter == .all, !dictations.isEmpty {
                Section {
                    NavigationLink(value: DictationsRoute()) { DictationsCard(dictations: dictations) }
                        .buttonStyle(SoftPress())
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            if let k = heroKind {
                Section {
                    KindHeroCard(kind: k, meta: heroMeta(k, items))
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            if !passages.isEmpty {
                Section {
                    Text("Passages").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.mute)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    ForEach(passages) { hit in
                        PhonePassageCard(transcript: hit.transcript, lines: hit.lines, count: hit.count, query: search)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
            }
            if filter == .kind(.journal), !items.isEmpty {
                ForEach(JournalDays.group(items)) { day in
                    Section {
                        EditorialSectionHeader(index: day.date, label: day.label)
                            .padding(.top, 10)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 2, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        ForEach(day.entries) { t in
                            Button { app.open(t.id) } label: { journalCard(t) }
                                .buttonStyle(SoftPress())
                                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contextMenu { RowActions(transcript: t) }
                        }
                    }
                }
            } else {
            Section {
                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if search.isEmpty { IconPlate(art: .iconLibrary, size: 96) } else { EmptyStateArt(art: .search, tint: Ink.butterTint) }
                        Text(!search.isEmpty ? "Nothing matches “\(search)”."
                             : typeFilter != .all ? "Nothing here matches \(typeFilter.platform ?? typeFilter.source.label)."
                             : project != nil ? "Nothing in this project yet. Add transcripts from your library."
                             : "Nothing here yet.").font(.system(size: 15)).foregroundStyle(Ink.dim)
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    Button { app.open(t.id) } label: { PhoneRow(transcript: t) }
                        .buttonStyle(SoftPress())
                        .riseIn(t.id, index: i, seen: seen, epoch: entrance, scrollRise: search.isEmpty)   // typing never animates rows
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
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
            }
            }
        }
        .listStyle(.plain)
        .tabEntrance(.library) { seen.entered(); entrance += 1 }
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Library")
        .navigationDestination(for: DictationsRoute.self) { _ in DictationsListScreen() }
        .searchable(text: $search, prompt: "Find the line you need")
        .toolbar {
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
        .onReceive(app.$libraryFilterRequest) { r in
            // The screenshot tour (and anything else) can open Library on a kind, or back on All.
            guard let r else { return }
            filter = RecordingKind(rawValue: r).map { .kind($0) } ?? .all
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
                if !n.isEmpty { filter = .project(app.store.addProject(n).id) }
                projectName = ""
            }
        }
    }

    private func heroMeta(_ k: RecordingKind, _ list: [Transcript]) -> String {
        if k == .journal {
            let week = Date().addingTimeInterval(-7 * 86_400)
            return "\(list.filter { $0.createdAt >= week }.count) this week"
        }
        return list.count == 1 ? "1 saved" : "\(list.count) saved"
    }

    /// A Journal entry: title, time, and the opening lines, in the row-card form.
    private func journalCard(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(t.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(2)
                Spacer(minLength: 4)
                Text(Formats.pattern("h:mm a").string(from: t.createdAt)).font(Ink.mono(12.5)).foregroundStyle(Ink.mute)
            }
            Text(JournalDays.preview(t)).font(.system(size: 15)).foregroundStyle(Ink.dim).lineSpacing(2).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .cardSurface(radius: Radius.row)
        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func chip(_ label: String, _ f: Filter) -> some View {
        Button { withAnimation(Motion.snap) { filter = f } } label: {
            Text(label).font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14).frame(height: 32)
                .foregroundStyle(filter == f ? Ink.onInteractive : Ink.ink)
                .background(filter == f ? Ink.interactive : Ink.card, in: Capsule())
                .overlay(Capsule().strokeBorder(filter == f ? Color.clear : Ink.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == f ? .isSelected : [])
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
                Text(transcript.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                Spacer(minLength: 6)
                Text(count == 1 ? "1 match" : "\(count) matches").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            ForEach(lines) { s in
                Button { app.open(transcript.id, segment: s.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(s.start.timecode).font(Ink.mono(12)).foregroundStyle(Ink.accentText).frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if transcript.speakers.count >= 2, let sp = transcript.speakerName(s.speaker) {
                                Text(sp).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                            }
                            Text(marked(s.text)).font(.system(size: 15)).foregroundStyle(Ink.ink).lineLimit(3)
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
            a[r].backgroundColor = Ink.persimmonTint; a[r].font = .system(size: 15, weight: .semibold)
            start = r.upperBound
        }
        return a
    }
}
