import SwiftUI

/// The Library in the website style: a compact serif title with the count in mono, a search field on the paper, one
/// row of soft filter chips (types with a color dot, kinds, pinned, in progress, and each project), mono day headers,
/// and flat rows with hairlines: the serif title, a meta line, and the state as a plain word over the length in mono.
/// Drag a row onto a project chip to move it there.
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
    @Environment(\.look) private var look

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

    /// Dictations, newest first. They have their own list, reached from the row at the top (and Home's Dictate).
    private var dictations: [Transcript] {
        app.store.live.filter(\.isDictation).sorted { $0.createdAt > $1.createdAt }
    }

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
        let items = sort.sorted(typeFilter.apply(scoped, searching: searching))
        let passages = search.trimmingCharacters(in: .whitespaces).count >= 2 ? LibrarySearch.passages(items, query: search, perTranscript: 3, cap: 60) : []
        let project: UUID? = { if case .project(let p) = filter { return p }; return nil }()
        Group {
        if look.isNative {
            nativeList(scoped: scoped, items: items, passages: passages, project: project)
        } else {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    PhoneCompactTitle(title: "Library", count: "\(app.store.live.filter { !$0.isDictation }.count)")
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
            if filter == .all, search.isEmpty, typeFilter == .all, !dictations.isEmpty {
                Section {
                    NavigationLink(value: DictationsRoute()) { DictationsCard(dictations: dictations) }
                        .buttonStyle(PhoneCardPress())
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 20))
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
        .tabEntrance(.library) { seen.entered(); entrance += 1 }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .phonePage()
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
        .navigationDestination(for: DictationsRoute.self) { _ in DictationsListScreen() }
        .toolbar {
            // Verbose style: the serif title sits on the paper; the bar keeps only Apple's buttons. Native: the large title.
            if !look.isNative {
                ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
            }
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
            if filter != .all { setType(.all) }
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

    // MARK: Rows

    private func row(_ t: Transcript, index i: Int) -> some View {
        Button { app.open(t.id) } label: {
            PhoneFlatRow(transcript: t, meta: Self.meta(t)) { PhoneRowState(transcript: t) }
        }
        .buttonStyle(PhoneCardPress())
        .riseIn(t.id, index: i, seen: seen, epoch: entrance, scrollRise: search.isEmpty)   // typing never animates rows
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

    /// One row of soft chips. A type and the other filters don't combine: choosing one clears the other.
    private func chips(_ scoped: [Transcript]) -> some View {
        let sources = typeFilter.sourceCounts(scoped, searching: searching).filter { $0.0 != .all }
        let platforms = typeFilter.platformCounts(scoped, searching: searching)
        let kinds = RecordingKind.pickable.filter { k in app.store.live.contains { $0.kind == k } || filter == .kind(k) }
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PhoneChip(label: "All", selected: filter == .all && typeFilter == .all) { pick(.all); setType(.all) }
                    ForEach(sources, id: \.0) { s, n in
                        PhoneChip(label: s.label, selected: typeFilter.source == s, dot: Self.dot(s)) {
                            pick(.all)
                            setType(typeFilter.source == s ? .all : LibraryFilter(source: s))
                        }
                        .accessibilityValue("\(n)")
                    }
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
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        }
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

/// Applies `.searchable` in the Native look, where the search field sits under the large title.
private struct NativeSearchable: ViewModifier {
    var enabled: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        } else {
            content
        }
    }
}

/// The Library in the Native look (the native mockup's section 01): the count under the large title, capsule filters,
/// Dictations as the first row, and inset grouped sections per day ("Today", "Yesterday"), each row with a tinted SF
/// Symbol, a subtitle, and the length in monospaced digits over its state. Same rows, menus, and swipes.
extension LibraryScreen {
    private struct DaySection: Identifiable {
        var id: String
        var title: String?
        var rows: [(Transcript, Int)]
    }

    private func daySections(_ items: [Transcript]) -> [DaySection] {
        var out: [DaySection] = []
        for line in lines(items) {
            switch line {
            case .day(let d, let label):
                out.append(DaySection(id: "day-\(d.timeIntervalSince1970)", title: PhoneDayHeader.nativeLabel(label), rows: []))
            case .row(let t, let i):
                if out.isEmpty { out.append(DaySection(id: "all", title: nil, rows: [])) }
                out[out.count - 1].rows.append((t, i))
            }
        }
        return out
    }

    func nativeList(scoped: [Transcript], items: [Transcript], passages: [LibrarySearch.PassageHit], project: UUID?) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(PhoneCompactTitle.nativeCount("Library", "\(app.store.live.filter { !$0.isDictation }.count)"))
                        .font(.subheadline).foregroundStyle(NativeInk.secondary)
                        .padding(.horizontal, 20)
                    chips(scoped)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if let p = project {
                Section {
                    Button { app.addFromLibrary = p } label: {
                        Label("Add from Library", systemImage: "plus.circle").foregroundStyle(NativeInk.accent)
                    }
                    .accessibilityHint("Adds transcripts you already have to this project")
                }
            }
            if filter == .all, search.isEmpty, typeFilter == .all, !dictations.isEmpty {
                Section {
                    NavigationLink(value: DictationsRoute()) {
                        HStack {
                            Label { Text("Dictations").foregroundStyle(NativeInk.label) } icon: {
                                Image(systemName: "mic").foregroundStyle(NativeInk.accent)
                            }
                            Spacer()
                            Text("\(dictations.count)").monospacedDigit().foregroundStyle(NativeInk.secondary)
                        }
                    }
                }
            }
            if !passages.isEmpty {
                Section {
                    ForEach(passages) { hit in
                        PhonePassageCard(transcript: hit.transcript, lines: hit.lines, count: hit.count, query: search)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                } header: { Text("Passages").textCase(nil) }
            }
            if items.isEmpty {
                Section {
                    Text(!search.isEmpty ? "Nothing matches “\(search)”."
                         : typeFilter != .all ? "Nothing here matches \(typeFilter.platform ?? typeFilter.source.label)."
                         : project != nil ? "Nothing in this project yet. Add transcripts from your library."
                         : "Nothing here yet.")
                        .font(.subheadline).foregroundStyle(NativeInk.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(daySections(items)) { section in
                Section {
                    ForEach(section.rows, id: \.0.id) { t, i in nativeRow(t, index: i) }
                } header: {
                    if let title = section.title { Text(title).textCase(nil) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func nativeRow(_ t: Transcript, index i: Int) -> some View {
        Button { app.open(t.id) } label: {
            PhoneFlatRow(transcript: t, meta: Self.meta(t)) { PhoneRowState(transcript: t) }
        }
        .buttonStyle(.plain)
        .contextMenu { RowActions(transcript: t) }
        .draggable(TranscriptDrag.payload([t.id]))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { app.delete([t.id]) } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button { app.togglePin(t.id) } label: { Label(t.pinned ? "Unpin" : "Pin", systemImage: "pin") }.tint(Color(uiColor: .systemOrange))
        }
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
            a[r].backgroundColor = Ink.persimmonTint; a[r].font = .system(size: 15, weight: .semibold)
            start = r.upperBound
        }
        return a
    }
}
