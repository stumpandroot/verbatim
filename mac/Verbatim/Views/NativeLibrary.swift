import SwiftUI
import AppKit

// brand: native file
//
// The Library in the Native look (mockup section 03, "Mac Library"): the title and count in the toolbar (as a toolbar
// title with its subtitle), a segmented scope bar in place of the filter chips, and a `Table` with alternating rows and
// the standard selection, which fills with the accent. Rows group by day under plain headers. Double-click (or
// Return) opens a transcript; right-click acts on the selection; rows drag onto a project in the sidebar, where the
// project cards live in Native. Search is the window's toolbar field.

struct NativeLibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var selection: Set<String> = []
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }

    /// The scope bar's choices: everything, a type of source, or a kind.
    enum Scope: Hashable { case all, source(LibrarySource), kind(RecordingKind) }

    /// A table row: a day header, or a transcript.
    struct Row: Identifiable {
        let id: String
        var header: String? = nil
        var transcript: Transcript? = nil
    }

    var body: some View {
        let base = app.filtered
        let searching = !app.search.trimmingCharacters(in: .whitespaces).isEmpty
        let all = app.libraryFilter.apply(base, searching: searching)
        let list = app.libraryKind.map { k in all.filter { $0.kind == k } } ?? all
        let groups = Store.group(list, sort: sort)
        let rows = groups.flatMap { g in [Row(id: "h:" + g.label, header: g.label)] + g.items.map { Row(id: $0.id.uuidString, transcript: $0) } }
        return VStack(alignment: .leading, spacing: 0) {
            scopeBar(base: base, searching: searching)
                .padding(.horizontal, 16).padding(.vertical, 10)
            if app.search.trimmingCharacters(in: .whitespaces).count >= 2 {
                ScrollView { PassageResults(query: app.search, list: list).padding(.horizontal, 16).padding(.bottom, 10) }
                    .frame(maxHeight: 220)
                Divider()
            }
            if groups.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(rows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar { toolbar(count: list.count) }
        .onChange(of: app.projectFilter) { _, _ in selection = [] }
        .onAppear { KeptMedia.shared.refresh() }
    }

    // MARK: Toolbar

    private var title: String {
        if let p = app.projectFilter, let name = app.store.projects.first(where: { $0.id == p })?.name { return name }
        return app.libraryKind?.plural ?? "Library"
    }

    @ToolbarContentBuilder private func toolbar(count: Int) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(count == 1 ? "1 transcript" : "\(count.formatted()) transcripts").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases) { s in Text(s.title).tag(s.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort the Library: newest, oldest, longest, or by title")
            Menu {
                Button("Import Files…") { app.chooseFiles() }
                if let p = app.projectFilter {
                    Button("Add from Library…") { app.addFromLibrary = p }
                }
                Button("New Project…") { app.newProjectFor = [] }
                Divider()
                Button("Export Library as Markdown…") { MarkdownBulkExport.run(MarkdownBulkExport.all(app), app: app) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Import, add from your library, or start a project")
        }
    }

    // MARK: Scope bar

    private var scope: Scope {
        if let k = app.libraryKind { return .kind(k) }
        if app.libraryFilter.source != .all { return .source(app.libraryFilter.source) }
        return .all
    }

    private func scopeBar(base: [Transcript], searching: Bool) -> some View {
        let sources = LibraryFilter.all.sourceCounts(base, searching: searching).filter { $0.0 != .all && $0.1 > 0 }.map(\.0)
        var kindCounts: [RecordingKind: Int] = [:]
        for t in LibraryFilter.all.apply(base, searching: searching) { if let k = t.kind { kindCounts[k, default: 0] += 1 } }
        let kinds = RecordingKind.pickable.filter { (kindCounts[$0] ?? 0) > 0 || app.libraryKind == $0 }
        let options: [(Scope, String)] = [(.all, "All")] + sources.map { (.source($0), $0.label) } + kinds.map { (.kind($0), $0.plural) }
        let binding = Binding<Scope>(get: { scope }, set: { choose($0) })
        return ViewThatFits(in: .horizontal) {
            Picker("Show", selection: binding) {
                ForEach(options, id: \.0) { o in Text(o.1).tag(o.0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("Show", selection: binding) {
                ForEach(options, id: \.0) { o in Text(o.1).tag(o.0) }
            }
            .pickerStyle(.menu).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func choose(_ s: Scope) {
        selection = []
        switch s {
        case .all: app.libraryKind = nil; app.libraryFilter = .all
        case .source(let src): app.libraryKind = nil; app.libraryFilter = LibraryFilter(source: src)
        case .kind(let k): app.libraryFilter = .all; app.libraryKind = k
        }
    }

    // MARK: Table

    private var tableSelection: Binding<Set<String>> {
        // Day headers never stay selected.
        Binding(get: { selection }, set: { selection = $0.filter { !$0.hasPrefix("h:") } })
    }

    private func table(_ rows: [Row]) -> some View {
        Table(of: Row.self, selection: tableSelection) {
            TableColumn("") { r in
                if let t = r.transcript { NativeKindIcon(transcript: t, size: 18) }
            }
            .width(22)
            TableColumn("Name") { r in
                if let h = r.header {
                    Text(h).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                } else if let t = r.transcript {
                    HStack(spacing: 4) {
                        if t.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                        Text(t.title).lineLimit(1)
                    }
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Kind") { r in
                if let t = r.transcript { Text(Self.kind(t)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .width(min: 70, ideal: 90, max: 130)
            TableColumn("People or Source") { r in
                if let t = r.transcript { Text(Self.people(t, projects: app.store.projectsByID)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .width(min: 90, ideal: 180)
            TableColumn("Status") { r in
                if let t = r.transcript { status(t) }
            }
            .width(min: 70, ideal: 90, max: 140)
            TableColumn("Length") { r in
                if let t = r.transcript {
                    Text(Self.length(t.duration)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 56, ideal: 66, max: 90)
        } rows: {
            ForEach(rows) { r in
                TableRow(r).itemProvider { drag(r) }
            }
        }
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first(where: { !$0.hasPrefix("h:") }), let u = UUID(uuidString: id) { app.go(.transcript(u)) }
        }
    }

    /// A row drags its transcript, or the whole selection when it's part of it, onto a project.
    private func drag(_ r: Row) -> NSItemProvider? {
        guard let t = r.transcript else { return nil }
        let key = t.id.uuidString
        let ids = selection.contains(key) ? selection.compactMap(UUID.init(uuidString:)) : [t.id]
        return NSItemProvider(object: TranscriptDrag.payload(ids) as NSString)
    }

    @ViewBuilder private func menu(for ids: Set<String>) -> some View {
        let chosen = ids.compactMap(UUID.init(uuidString:)).compactMap { app.store.transcript($0) }
        if chosen.count == 1, let t = chosen.first {
            RowMenu(transcript: t)
        } else if chosen.count > 1 {
            let ready = chosen.filter { $0.status == .ready }.map(\.id)
            Button("Export \(ready.count) Transcripts…") { app.exportRequest = ExportRequest(ids: ready) }
                .disabled(ready.isEmpty)
            Menu("Move To") {
                Button("No Project") { app.move(chosen.map(\.id), to: nil) }
                if !app.store.projects.isEmpty { Divider() }
                ForEach(app.store.projects) { p in Button(p.name) { app.move(chosen.map(\.id), to: p.id) } }
            }
            Button("Export as Markdown Files…") { MarkdownBulkExport.run(chosen, app: app) }
            Divider()
            Button("Move to Recently Deleted", role: .destructive) { app.delete(chosen.map(\.id)); selection = [] }
        }
    }

    @ViewBuilder private func status(_ t: Transcript) -> some View {
        switch t.status {
        case .processing:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(t.stageText).foregroundStyle(.secondary).lineLimit(1) }
        case .failed:
            Label("Needs Retry", systemImage: "exclamationmark.triangle").foregroundStyle(NativeInk.danger).lineLimit(1)
        case .ready:
            if t.document != nil { Text("Cleaned").foregroundStyle(Ink.nativeAccent) } else { Text("Original").foregroundStyle(.secondary) }
        }
    }

    // MARK: Cells

    /// "Meeting", "Voice note", "Link".
    static func kind(_ t: Transcript) -> String {
        if let k = t.kind { return k.label }
        if LibrarySource.isLink(t) { return "Link" }
        return HomeRecentStyle(t).source
    }

    /// Named speakers, a link's site, the moments, or the project.
    static func people(_ t: Transcript, projects: [UUID: Project]) -> String {
        let named = t.speakers.map(\.name).filter { !$0.isEmpty && !$0.hasPrefix("Speaker ") }
        if !named.isEmpty { return named.count > 3 ? named.prefix(3).joined(separator: ", ") + " +\(named.count - 3)" : named.joined(separator: ", ") }
        if LibrarySource.isLink(t) { return t.linkInfo?.site ?? (t.sourceLabel.isEmpty ? "Link" : t.sourceLabel) }
        let moments = WebStatus.moments(t)
        if moments > 0 { return HomeCounts.countLabel(moments, "moment", "moments") }
        if let p = t.projectId, let name = projects[p]?.name { return name }
        return t.speakers.count >= 2 ? "\(t.speakers.count) speakers" : ""
    }

    /// "1:04:12", "15:39", "7:50".
    static func length(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Empty

    @ViewBuilder private var emptyState: some View {
        if !app.search.isEmpty {
            NativeEmptyState(art: .search, title: "Nothing found",
                             message: "Nothing matches “\(app.search)”. Search looks at titles and every transcript's text.")
        } else if app.libraryFilter != .all {
            NativeEmptyState(art: .iconLibrary, title: "Nothing here",
                             message: "Nothing here matches \(app.libraryFilter.platform ?? app.libraryFilter.source.label).",
                             button: "Show all", action: { app.libraryFilter = .all })
        } else if let p = app.projectFilter {
            NativeEmptyState(art: .iconProject, title: "Nothing in this project yet",
                             message: "Add transcripts from your library or import files.",
                             button: "Add from Library", action: { app.addFromLibrary = p })
        } else if app.libraryKind != nil {
            NativeEmptyState(art: .iconLibrary, title: "Nothing here yet",
                             message: "Recordings of this kind land here as you make them.",
                             button: "Show all", action: { app.libraryKind = nil })
        } else {
            NativeEmptyState(art: .iconLibrary, title: "Nothing here yet",
                             message: "Record a voice note, import a file, or paste a link on Home. Every transcript lands here.",
                             button: "Import files", action: { app.chooseFiles() })
        }
    }
}
