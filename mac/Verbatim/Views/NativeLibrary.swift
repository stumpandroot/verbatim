import SwiftUI
import AppKit

// brand: native file
//
// The Library in the Native look (mockup "Verbose Native Redesign", section 8): a system `Table` with sortable columns
// (Name, Kind, People or source, Date, and Length), alternating rows, and the accent selection, under day headers
// while it's sorted by date. The toolbar's List shows the same recordings as rows with what was said, in grouped
// sections by day (PremiumItems.swift). The inspector previews the selected recording. Click selects; double-click or
// Return opens; Space plays. The title and count, Record, the scope, Table and List, and More live in the window's
// toolbar (NativeChrome.swift); search is its one system field. Rows drag onto a project in the sidebar.

struct NativeLibraryView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: NativeNav
    /// The table's selection, kept across screens (ScreenPlaces, App/NavTrail.swift).
    @State private var selection: Set<String> = ScreenPlaces.shared.tableSelection
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    /// The table's sort: one column and its direction, started from the Library's sort.
    @State private var sortOrder: [RowOrder] = {
        let (column, descending) = NativeTableSort.column(forLibrarySort: UserDefaults.standard.string(forKey: LibrarySort.key) ?? "newest")
        return [RowOrder(column: column, order: descending ? .reverse : .forward)]
    }()
    @FocusState private var listFocused: Bool
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }

    /// A table row: a day header, or a transcript with the values its columns show and sort by.
    struct Row: Identifiable {
        let id: String
        var header: String? = nil
        var transcript: Transcript? = nil
        var name = "", kind = "", people = "", length = 0.0
        var date = Date.distantPast

        var cells: (name: String, kind: String, people: String, date: Date, length: Double) { (name, kind, people, date, length) }
    }

    /// A column's sort, as the table's header sets it.
    struct RowOrder: SortComparator, Hashable {
        var column: NativeTableSort
        var order: SortOrder = .forward
        func compare(_ a: Row, _ b: Row) -> ComparisonResult {
            if NativeTableSort.ordered(a.cells, b.cells, by: column, descending: order == .reverse) { return .orderedAscending }
            if NativeTableSort.ordered(b.cells, a.cells, by: column, descending: order == .reverse) { return .orderedDescending }
            return .orderedSame
        }
    }

    var body: some View {
        LookSwitch.mark("library")
        let list = NativeLibraryScope.list(app)
        let groups = app.store.grouped(list, sort: nav.libraryTable ? tableGroupSort : sort)
        return VStack(alignment: .leading, spacing: 0) {
            if app.search.trimmingCharacters(in: .whitespaces).count >= 2 {
                ScrollView { PassageResults(query: app.search, list: list).padding(.horizontal, 24).padding(.bottom, 10) }
                    .frame(maxHeight: 220)
                Divider()
            }
            if groups.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if nav.libraryTable {
                table(tableRows(list, groups: groups))
                    .scrollPlace(ScreenPlaces.scrollKey(ScreenPlaces.libraryKey(app.projectFilter) + "|table", look: .native), sibling: true)
            } else {
                rowList(groups)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: app.projectFilter) { _, _ in selection = []; nav.librarySelection = nil }
        .onChange(of: selection) { _, s in
            ScreenPlaces.shared.tableSelection = s
            // One row chosen: the inspector previews it, and Back comes back to it.
            if s.count == 1, let id = s.first.flatMap(UUID.init(uuidString:)), nav.librarySelection != id { nav.librarySelection = id }
        }
        .onChange(of: sortOrder) { _, o in
            // A column the List view also sorts by keeps the two in step.
            if let first = o.first, let raw = NativeTableSort.librarySort(first.column, descending: first.order == .reverse), raw != sortRaw { sortRaw = raw }
        }
        .onAppear {
            KeptMedia.shared.refresh()
            // Back and the sidebar bring the selection back with the Library.
            if selection.isEmpty, let s = nav.librarySelection { selection = [s.uuidString] }
        }
    }

    // MARK: List

    /// The selected item: the one clicked, or the first while nothing is (the preview shows it either way).
    private func selected(_ flat: [Transcript]) -> UUID? {
        if let s = nav.librarySelection, flat.contains(where: { $0.id == s }) { return s }
        return flat.first?.id
    }

    /// The List view: each day a grouped section of rows. Each row draws its own piece of the section, so the list
    /// stays lazy however many recordings a day has.
    private func rowList(_ groups: [(label: String, items: [Transcript])]) -> some View {
        let flat = groups.flatMap(\.items)
        let current = selected(flat)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.label) { g in
                        PremiumDayHeader(title: g.label)
                        ForEach(Array(g.items.enumerated()), id: \.element.id) { i, t in
                            let last = i == g.items.count - 1
                            NativeRecordingRow(transcript: t, selected: t.id == current, onSelect: { select(t.id) }, divider: !last, showsDay: !sort.groupsByDay)
                                .background(NativeInk.group)
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: i == 0 ? 10 : 0, bottomLeadingRadius: last ? 10 : 0,
                                                                  bottomTrailingRadius: last ? 10 : 0, topTrailingRadius: i == 0 ? 10 : 0, style: .continuous))
                                .id(t.id)
                                .modifier(FirstItemsTarget(id: t.id, flat: flat))
                                .modifier(NativeLibraryRowTarget(id: t.id))
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 2).padding(.bottom, 28)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                // Back and the sidebar bring the list back where you left it, its item still selected.
                .scrollPlace(ScreenPlaces.scrollKey(ScreenPlaces.libraryKey(app.projectFilter), look: .native))
            }
            .softScrollEdges(.top)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1, flat, proxy); return .handled }
            .onKeyPress(.upArrow) { step(-1, flat, proxy); return .handled }
            .onKeyPress(.return) {
                guard let id = selected(flat) else { return .ignored }
                app.go(.transcript(id)); return .handled
            }
            .onKeyPress(.space) {
                guard let id = selected(flat), let t = app.store.transcript(id), t.audioFileName != nil else { return .ignored }
                nav.play(t, app: app); return .handled
            }
        }
    }

    private func select(_ id: UUID) {
        listFocused = true
        if nav.librarySelection != id { nav.librarySelection = id }
    }

    /// Arrow keys: the next or previous item, scrolled into view.
    private func step(_ by: Int, _ flat: [Transcript], _ proxy: ScrollViewProxy) {
        guard !flat.isEmpty else { return }
        let i = selected(flat).flatMap { id in flat.firstIndex { $0.id == id } } ?? 0
        let next = flat[max(0, min(flat.count - 1, i + by))].id
        nav.librarySelection = next
        proxy.scrollTo(next)
    }

    // MARK: Table

    /// The table's column and direction.
    private var tableSort: (column: NativeTableSort, descending: Bool) {
        let first = sortOrder.first ?? RowOrder(column: .date, order: .reverse)
        return (first.column, first.order == .reverse)
    }

    /// Day groups for the table follow its date direction.
    private var tableGroupSort: LibrarySort { tableSort.column == .date && !tableSort.descending ? .oldest : .newest }

    private func row(_ t: Transcript) -> Row {
        Row(id: t.id.uuidString, transcript: t, name: t.title, kind: Self.kind(t),
            people: Self.people(t, projects: app.store.projectsByID), length: t.duration, date: t.createdAt)
    }

    /// Sorted by date: the day headers and each day's recordings. Any other column: every recording, flat.
    private func tableRows(_ list: [Transcript], groups: [(label: String, items: [Transcript])]) -> [Row] {
        let (column, descending) = tableSort
        if column.grouped {
            return groups.flatMap { g in [Row(id: "h:" + g.label, header: g.label)] + g.items.map(row) }
        }
        return list.map(row).sorted { NativeTableSort.ordered($0.cells, $1.cells, by: column, descending: descending) }
    }

    private var tableSelection: Binding<Set<String>> {
        // Day headers never stay selected.
        Binding(get: { selection }, set: { selection = $0.filter { !$0.hasPrefix("h:") } })
    }

    private func table(_ rows: [Row]) -> some View {
        let firstIDs = Array(rows.lazy.filter { $0.transcript != nil }.prefix(2).map(\.id))
        return Table(of: Row.self, selection: tableSelection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: RowOrder(column: .name)) { r in
                if let h = r.header {
                    Text(h).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                } else if let t = r.transcript {
                    HStack(spacing: 4) {
                        if t.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                        Text(t.title).lineLimit(1)
                    }
                    .modifier(TableCellTarget(index: firstIDs.firstIndex(of: r.id)))
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Kind", sortUsing: RowOrder(column: .kind)) { r in
                if let t = r.transcript {
                    // The kind's symbol in secondary gray: the word carries the meaning.
                    HStack(spacing: 5) {
                        NativeKindIcon(transcript: t, size: 16)
                        Text(r.kind).lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 108, max: 150)
            TableColumn("People or Source", sortUsing: RowOrder(column: .people)) { r in
                if let t = r.transcript { peopleCell(t, people: r.people) }
            }
            // Room for "Transcribing" beside its spinner (review M-22).
            .width(min: Self.statusMinWidth, ideal: 170)
            TableColumn("Date", sortUsing: RowOrder(column: .date, order: .reverse)) { r in
                if let t = r.transcript { Text(NativeDateCell.text(t.createdAt)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1) }
            }
            .width(min: 110, ideal: 140, max: 180)
            TableColumn("Length", sortUsing: RowOrder(column: .length, order: .reverse)) { r in
                // A text-only thought has no length (review M-13).
                if let t = r.transcript, !WebStatus.isTextOnly(t) {
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
        .onKeyPress(.space) {
            guard selection.count == 1, let id = selection.first.flatMap(UUID.init(uuidString:)), let t = app.store.transcript(id),
                  t.audioFileName != nil, t.status == .ready else { return .ignored }
            nav.play(t, app: app); return .handled
        }
        .uiWindowTarget("lib-table")
    }

    /// Named people, a link's site, the moments, or the project; while it transcribes, the stage and a spinner.
    @ViewBuilder private func peopleCell(_ t: Transcript, people: String) -> some View {
        switch t.status {
        case .processing:
            LiveStage(t) { t in
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(t.stageText).foregroundStyle(.secondary).lineLimit(1) }
                    .help(t.stageText)
            }
        case .failed:
            Label("Needs Retry", systemImage: "exclamationmark.triangle").foregroundStyle(NativeInk.danger).lineLimit(1)
        case .ready:
            Text(people).foregroundStyle(.secondary).lineLimit(1)
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

    // MARK: Cells

    /// The People or Source column's narrowest: room for "Transcribing" beside its spinner (review M-22).
    static let statusMinWidth: CGFloat = 104

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
                             button: "Add from Library…", action: { app.addFromLibrary = p })
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

/// The self-test's handles on the list's first two items.
private struct FirstItemsTarget: ViewModifier {
    var id: UUID
    var flat: [Transcript]
    func body(content: Content) -> some View {
        if UITest.enabled, let i = flat.prefix(2).firstIndex(where: { $0.id == id }) {
            content.uiWindowTarget("lib-item-\(i)")
        } else {
            content
        }
    }
}

/// The self-test's handles on the table's first two rows (their Name cells).
private struct TableCellTarget: ViewModifier {
    var index: Int?
    func body(content: Content) -> some View {
        if UITest.enabled, let index { content.uiWindowTarget("lib-cell-\(index)") } else { content }
    }
}

/// The self-test's handle on each item (only while its Back steps run, `UITest.rowTargets`).
private struct NativeLibraryRowTarget: ViewModifier {
    var id: UUID
    func body(content: Content) -> some View {
        if UITest.rowTargets { content.uiWindowTarget("lib-row-\(id.uuidString)").uiTarget("lib-row-\(id.uuidString)") } else { content }
    }
}

// MARK: - Preview

/// The Library's preview in the inspector: the selected recording (or the first) with its kind, day, length, and
/// people, its title, the summary, its first line, and Play, Open Transcript, and ⋯. Plain text on the inspector, as
/// the transcript's inspector lists its parts.
struct PremiumLibraryPreview: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: NativeNav
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue

    var body: some View {
        let _ = LookSwitch.mark("library-preview")
        let list = NativeLibraryScope.list(app)
        let chosen = nav.librarySelection.flatMap { id in list.first { $0.id == id } }
            ?? app.store.grouped(list, sort: LibrarySort(rawValue: sortRaw) ?? .newest).first?.items.first
        ScrollView {
            if let t = chosen {
                card(t).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
            } else {
                Text("Select a recording to see its summary.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .scrollIndicators(.never)
    }

    private func card(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t.title).font(.system(size: 17, weight: .bold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(meta(t)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
                .padding(.top, 3)
            HStack(spacing: 8) {
                if t.audioFileName != nil && t.status == .ready {
                    Button { nav.play(t, app: app) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .help("Open and play (Space)")
                }
                Button("Open Transcript") { app.go(.transcript(t.id)) }
                    .buttonStyle(.bordered)
                    .help("Open the transcript (Return)")
                    .uiWindowTarget("lib-open")
                Menu { RowMenu(transcript: t) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More for \(t.title)")
            }
            .controlSize(.regular)
            .padding(.top, 12)
            if let s = t.summary, !s.isEmpty {
                Divider().padding(.vertical, 14)
                NativeSummaryText(summary: s, byModel: t.summaryByModel, compact: true)
            }
            if let line = t.visibleSegments(hideFiller: true).first?.text, !line.isEmpty {
                Divider().padding(.vertical, 14)
                Text("“\(line)”").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3).lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Meeting · Thu Oct 22 · 1:04:12 · Anika, Marcus".
    private func meta(_ t: Transcript) -> String {
        var parts = [NativeLibraryView.kind(t), Formats.pattern("EEE MMM d").string(from: t.createdAt)]
        if t.duration > 0 { parts.append(NativeLibraryView.length(t.duration)) }
        let people = NativeLibraryView.people(t, projects: app.store.projectsByID)
        if !people.isEmpty { parts.append(people) }
        return parts.joined(separator: " · ")
    }
}
