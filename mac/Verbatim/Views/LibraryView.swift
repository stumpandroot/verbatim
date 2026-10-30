import SwiftUI
import AppKit

/// The Library (DESIGN.md §6.8 and §13; mockup "Verbose Refined Look", MacLibrary): the serif title with the count, the quick filter chips (All, Voice notes, Meetings, Thoughts,
/// Audio, Links, Marked) with the sort ("Newest first") at the end, and every recording as a table in a card: Name,
/// Kind (its colored chip), People or source, Date, and Length, with alternating rows and the selected row in the
/// persimmon tint. Every column sorts. A click selects (⌘-click adds, Shift-click a range), a double-click or Return
/// opens, Space plays, the arrow keys move, and right-click has the row's menu (or the selection's). Rows drag onto a
/// project in the sidebar. With more than one selected, a bar at the foot moves, exports, or deletes them. The window's
/// inspector previews the selection, and search is the toolbar's system field (MacChrome.swift). Back and the sidebar bring the Library back scrolled where you left it, with the row you opened selected
/// (App/NavTrail.swift). A lazy table: a library of hundreds builds only the rows on screen.
struct LibraryView: View {
    @EnvironmentObject var app: AppState
    /// Newest, Oldest, Longest, or Title A–Z, remembered on this Mac; the table writes it when its sort is one of them.
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    /// The table's sort: one column and its direction, started from the Library's sort.
    @State private var column: LibraryTableSort
    @State private var descending: Bool
    /// The selected recordings, kept across screens (ScreenPlaces).
    @State private var selection: Set<UUID> = ScreenPlaces.shared.tableSelection
    /// Where a Shift-click range starts: the last row clicked or ⌘-clicked.
    @State private var anchor: UUID? = nil
    @FocusState private var focused: Bool

    /// How many Libraries are on screen, and their rows' order (the self-test).
    static var onScreen = 0
    static var shownOrder: [UUID] = []

    private static let margin: CGFloat = 40
    private static let maxContent: CGFloat = 1100

    init() {
        let (c, d) = LibraryTableSort.column(forLibrarySort: UserDefaults.standard.string(forKey: LibrarySort.key) ?? LibrarySort.newest.rawValue)
        _column = State(initialValue: c)
        _descending = State(initialValue: d)
    }

    var body: some View {
        let _ = NavMarks.mark("library")
        let lists = app.libraryLists(kind: app.libraryKind)
        let rows = ordered(lists.list)
        let order = rows.map(\.id)
        if UITest.enabled { Self.shownOrder = order }
        return VStack(spacing: 0) {
            GeometryReader { geo in
                let margin = geo.size.width < 760 ? 24 : Self.margin
                let width = min(Self.maxContent, max(320, geo.size.width - 2 * margin))
                ScrollViewReader { proxy in
                    ScrollView {
                        page(lists: lists, rows: rows, order: order, width: width)
                            .frame(width: width, alignment: .leading)
                            .padding(.horizontal, margin).padding(.top, 18)
                            .padding(.bottom, selection.count > 1 ? 90 : 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Back and the sidebar bring the Library back where you left it (App/NavTrail.swift).
                            .scrollPlace(ScreenPlaces.scrollKey(ScreenPlaces.libraryKey(app.projectFilter)))
                            .navMarkWhenLaidOut("library-laid-out")
                    }
                    .softScrollEdges(.top)
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { step(1, order, proxy); return .handled }
                    .onKeyPress(.upArrow) { step(-1, order, proxy); return .handled }
                    .onKeyPress(.return) { openSelected() ? .handled : .ignored }
                    .onKeyPress(.space) { playSelected() ? .handled : .ignored }
                    .onKeyPress(.escape) {
                        guard !selection.isEmpty else { return .ignored }
                        selection = []; anchor = nil
                        return .handled
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        selection = Set(order)
                        return .handled
                    }
                }
            }
        }
        .background(Refined.paper)
        .background { typeShortcuts }
        .overlay(alignment: .bottom) {
            if selection.count > 1 { actionBar(order: order).padding(.bottom, 18) }
        }
        .onChange(of: app.projectFilter) { _, _ in selection = []; anchor = nil; WindowNav.shared.librarySelection = nil }
        .onChange(of: selection) { _, s in
            ScreenPlaces.shared.tableSelection = s
            // One row chosen: the inspector previews it, and Back comes back to it.
            if s.count == 1, let id = s.first, WindowNav.shared.librarySelection != id { WindowNav.shared.librarySelection = id }
        }
        .onAppear {
            NavMarks.mark("library-appear")
            KeptMedia.shared.refresh()
            Self.onScreen += 1
            // Back and the sidebar bring the selection back with the Library.
            if let s = WindowNav.shared.librarySelection ?? ScreenPlaces.shared.selectedRow(app.projectFilter), !selection.contains(s) {
                selection = [s]; anchor = s
            }
        }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
    }

    // MARK: Page

    @ViewBuilder private func page(lists: AppState.LibraryLists, rows: [Transcript], order: [UUID], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow(count: lists.list.count)
            chipsRow.padding(.top, 14)
            if !lists.platforms.isEmpty {
                RefinedChipRow(label: "Platform") {
                    ForEach(lists.platforms, id: \.0) { p, n in
                        RefinedChip(title: p, selected: app.libraryFilter.platform == p) {
                            let f = app.libraryFilter
                            app.libraryFilter = LibraryFilter(source: f.source, platform: f.platform == p ? nil : p)
                        }
                        .accessibilityValue("\(n)")
                        .uiTarget("platform-\(p)")
                    }
                }
                .padding(.top, 8)
            }
            if app.search.trimmingCharacters(in: .whitespaces).count >= 2 {
                PassageResults(query: app.search, list: lists.list).padding(.top, 16)
            }
            if rows.isEmpty {
                emptyState.padding(.top, 16)
            } else {
                table(rows, order: order, columns: LibraryColumns(width: width)).padding(.top, 16)
            }
        }
    }

    /// The title (a project's name, or "Library") and the count; in a project, Add from Library; for Thoughts and
    /// Journal, Read by day.
    private func titleRow(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            LargeSerifTitle(title: projectName ?? "Library", count: HomeCounts.countLabel(count, "recording", "recordings"))
                .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let k = app.libraryKind, k == .idea || k == .journal {
                // Thoughts and Journal also read by day: one link there, so it's one feature with two views (review
                // M-21). By day's All thoughts comes back to this list.
                RefinedLink(title: "Read by day") { app.go(.byDay(k)) }
                    .help("Opens \(k.plural) as one page a day.")
                    .uiTarget("library-read-by-day")
            }
            if let p = app.projectFilter {
                Button("Add from Library…") { app.addFromLibrary = p }
                    .buttonStyle(RefinedActionStyle())
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .help("Add transcripts you already have to this project (⇧⌘L)")
                    .uiTarget("add-from-library")
            }
        }
    }

    private var projectName: String? { app.projectFilter.flatMap { app.store.projectsByID[$0]?.name } }

    // MARK: Chips and sort

    /// The chip the current filter is, or nil when it's one the chips don't name.
    private var currentChip: LibraryChip? { LibraryChip.matching(app.libraryFilter, kind: app.libraryKind) }

    /// The mockup's seven chips, always in the same order, a chosen chip for a filter they don't name (a kind from By
    /// day, another type), More with every type and kind, and the sort at the end. Choosing a chip clears every other
    /// filter; the chosen one again goes back to All.
    private var chipsRow: some View {
        let current = currentChip
        let other = LibraryChip.otherLabel(app.libraryFilter, kind: app.libraryKind)
        return HStack(spacing: 12) {
            RefinedChipRow(label: "Filter") {
                RefinedChip(title: LibraryChip.all.label, selected: current == .all) { choose(.all) }
                    .libraryTarget("kind-all")
                if let other {
                    RefinedChip(title: other, selected: true) { choose(.all) }
                        .accessibilityHint("Clears this filter.")
                        .libraryTarget("chip-other")
                }
                ForEach(LibraryChip.allCases.filter { $0 != .all }) { c in
                    RefinedChip(title: c.label, selected: current == c) { choose(current == c ? .all : c) }
                        .libraryTarget(Self.chipTarget(c))
                }
                moreFilters
            }
            sortMenu.fixedSize()
        }
    }

    /// The self-test's handle on a chip: kinds as "kind-<raw>", types as "source-<raw>", as the chips were named before.
    static func chipTarget(_ c: LibraryChip) -> String {
        if let k = c.kind { return "kind-\(k.rawValue)" }
        return c == .all ? "kind-all" : "source-\(c.source.rawValue)"
    }

    private func choose(_ chip: LibraryChip) {
        app.libraryKind = chip.kind
        app.libraryFilter = LibraryFilter(source: chip.source)
    }

    /// Every type and kind the chips don't name, as a menu at the end of the chips.
    private var moreFilters: some View {
        let lists = app.libraryLists(kind: app.libraryKind)
        let chipSources = Set(LibraryChip.allCases.map(\.source))
        let chipKinds = Set(LibraryChip.allCases.compactMap(\.kind))
        let sources = lists.sources.map(\.0).filter { !chipSources.contains($0) }
        let kinds = RecordingKind.pickable.filter { !chipKinds.contains($0) && ((lists.kindCounts[$0] ?? 0) > 0 || app.libraryKind == $0) }
        return Menu {
            ForEach(sources, id: \.self) { s in
                Button(s.label) { app.libraryKind = nil; app.libraryFilter = LibraryFilter(source: s) }
            }
            if !sources.isEmpty && !kinds.isEmpty { Divider() }
            ForEach(kinds) { k in
                Button(k.plural) { app.libraryFilter = .all; app.libraryKind = k }
            }
        } label: {
            Text("More").refinedFont(.hint).foregroundStyle(Refined.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Refined.neutral, in: Capsule())
        .disabled(sources.isEmpty && kinds.isEmpty)
        .help("Show another type or kind of recording")
    }

    /// The sort, as the mockup's "Newest first" at the end of the chips; the column headers sort too.
    private var sortMenu: some View {
        Menu {
            ForEach(Self.sortChoices, id: \.title) { c in
                Button {
                    setSort(c.column, descending: c.descending)
                } label: {
                    if c.column == column && c.descending == descending { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                }
            }
        } label: {
            Text(column.title(descending: descending)).refinedFont(.hint).foregroundStyle(Refined.dim)
        }
        .menuStyle(.borderlessButton)
        .help("Sort the Library")
        .accessibilityLabel("Sort")
        .accessibilityValue(column.title(descending: descending))
        .libraryTarget("library-sort")
    }

    /// The sorts the menu offers, in its order.
    static let sortChoices: [(title: String, column: LibraryTableSort, descending: Bool)] = [
        (LibraryTableSort.date.title(descending: true), .date, true), (LibraryTableSort.date.title(descending: false), .date, false),
        (LibraryTableSort.length.title(descending: true), .length, true), (LibraryTableSort.length.title(descending: false), .length, false),
        (LibraryTableSort.name.title(descending: false), .name, false), (LibraryTableSort.kind.title(descending: false), .kind, false),
        (LibraryTableSort.people.title(descending: false), .people, false),
    ]

    private func setSort(_ c: LibraryTableSort, descending d: Bool) {
        column = c; descending = d
        // A sort the Library's other places share writes the Library's sort.
        if let raw = LibraryTableSort.librarySort(c, descending: d), raw != sortRaw { sortRaw = raw }
    }

    /// ⌥⌘1 to ⌥⌘8 choose a type (All is 1), as the type chips' shortcuts always did.
    private var typeShortcuts: some View {
        ZStack {
            ForEach(Array(LibrarySource.allCases.enumerated()), id: \.element) { i, s in
                Button(s.label) { app.libraryKind = nil; app.libraryFilter = LibraryFilter(source: s) }
                    .modifier(TypeShortcut(index: i + 1, on: true))
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Table

    /// The rows in the table's order: by the chosen column; sorted by date, pinned recordings come first.
    private func ordered(_ list: [Transcript]) -> [Transcript] {
        let column = self.column, descending = self.descending
        let projects = app.store.projectsByID
        let key = "refined-library|\(app.projectFilter?.uuidString ?? "-")|\(app.search.trimmingCharacters(in: .whitespaces).lowercased())|\(app.libraryFilterRaw)|\(app.libraryKind?.rawValue ?? "-")|\(column.rawValue)|\(descending)"
        return app.store.memo(key) {
            let cells = list.map { t in (t, (name: t.title, kind: RecordingKind.refinedName(t.refinedKind), people: Self.people(t, projects: projects),
                                             date: t.createdAt, length: t.duration)) }
            let sorted = cells.sorted { LibraryTableSort.ordered($0.1, $1.1, by: column, descending: descending) }.map(\.0)
            guard column == .date else { return sorted }
            return sorted.filter(\.pinned) + sorted.filter { !$0.pinned }
        }
    }

    private func table(_ rows: [Transcript], order: [UUID], columns: LibraryColumns) -> some View {
        let projects = app.store.projectsByID
        return PaperTable {
            header(columns)
        } rows: {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, t in
                LibraryTableRow(transcript: t, columns: columns, selected: selection.contains(t.id), striped: i % 2 == 0,
                                people: Self.people(t, projects: projects),
                                onClick: { clicked(t.id, order: order) },
                                dragIDs: { selection.contains(t.id) ? order.filter { selection.contains($0) } : [t.id] })
                    .contextMenu { menu(for: t, order: order) }
                    .id(t.id)
                    .modifier(LibraryRowTarget(id: t.id, index: i))
            }
        }
        .uiTarget("lib-table")
    }

    /// The column titles: a click sorts by that column, and again turns the order around.
    private func header(_ columns: LibraryColumns) -> some View {
        HStack(spacing: LibraryColumns.gap) {
            ForEach(LibraryTableSort.allCases, id: \.self) { c in
                Button {
                    if c == column { setSort(c, descending: !descending) } else { setSort(c, descending: c.startsDescending) }
                } label: {
                    HStack(spacing: 4) {
                        if c == .length { Spacer(minLength: 0) }
                        Text(c.header).lineLimit(1)
                        if c == column {
                            Image(systemName: descending ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold))
                                .accessibilityHidden(true)
                        }
                        if c != .length { Spacer(minLength: 0) }
                    }
                    .refinedFont(.meta, weight: .semibold)
                    .foregroundStyle(c == column ? Refined.ink : Refined.mute)
                    .frame(width: columns.width(c))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(c.header)")
                .accessibilityValue(c == column ? (descending ? "Descending" : "Ascending") : "")
                .accessibilityAddTraits(c == column ? .isSelected : [])
                .libraryTarget("lib-sort-\(c.rawValue)")
            }
        }
        .padding(.horizontal, LibraryColumns.inset).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Selection

    /// A click: ⌘ adds or removes the row, Shift selects the range from the anchor, a plain click selects it, and a
    /// second click within the double-click time opens it.
    private func clicked(_ id: UUID, order: [UUID]) {
        focused = true
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift), let a = anchor ?? selection.first, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            selection = Set(order[min(i, j)...max(i, j)])
        } else if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if WindowNav.shared.isDoubleClick(on: id) {
            app.go(.transcript(id))
        } else {
            selection = [id]; anchor = id
        }
    }

    /// The arrow keys: the next or previous row, scrolled into view.
    private func step(_ by: Int, _ order: [UUID], _ proxy: ScrollViewProxy) {
        guard !order.isEmpty else { return }
        let current = anchor.flatMap { a in order.firstIndex(of: a) } ?? selection.compactMap { order.firstIndex(of: $0) }.min()
        let next = order[current.map { max(0, min(order.count - 1, $0 + by)) } ?? 0]
        selection = [next]; anchor = next
        proxy.scrollTo(next)
    }

    private var single: Transcript? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return app.store.transcript(id)
    }

    private func openSelected() -> Bool {
        guard let t = single else { return false }
        app.go(.transcript(t.id)); return true
    }

    private func playSelected() -> Bool {
        guard let t = single, t.audioFileName != nil, t.status == .ready else { return false }
        WindowNav.shared.play(t, app: app); return true
    }

    /// Right-click: the row's menu, or the selection's when the row is part of a selection of more than one.
    @ViewBuilder private func menu(for t: Transcript, order: [UUID]) -> some View {
        if selection.count > 1, selection.contains(t.id) {
            let chosen = selectedTranscripts(order)
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
        } else {
            RowMenu(transcript: t)
        }
    }

    private func selectedTranscripts(_ order: [UUID]) -> [Transcript] { order.filter { selection.contains($0) }.compactMap { app.store.transcript($0) } }

    /// The selection's bar at the foot: how many, Select all, Move to, Export, and Delete. Opaque: text never sits on
    /// a blur.
    private func actionBar(order: [UUID]) -> some View {
        let chosen = selectedTranscripts(order)
        let ready = chosen.filter { $0.status == .ready }
        let exportTitle = ready.count == 1 ? "Export 1 transcript" : "Export \(ready.count) transcripts"
        return HStack(spacing: 12) {
            Text("\(selection.count) selected").refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink)
                .monospacedDigit()
            Button("Select all") { selection = Set(order) }
                .buttonStyle(.plain).foregroundStyle(Refined.accentText)
            Divider().frame(height: 18)
            Menu("Move to") {
                Button("No project") { app.move(chosen.map(\.id), to: nil) }
                if !app.store.projects.isEmpty { Divider() }
                ForEach(app.store.projects) { p in Button(p.name) { app.move(chosen.map(\.id), to: p.id) } }
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button(exportTitle + "…") { app.exportRequest = ExportRequest(ids: ready.map(\.id)) }
                Divider()
                Button("Copy all to clipboard") {
                    let text = Exporter.clipboard(ready, as: .txt, options: .saved)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    app.toast = Toast("Copied \(ready.count) transcripts")
                }
                Divider()
                // One Markdown note per transcript, with properties Obsidian reads (Views/TrustViews.swift).
                Button("Export as Markdown files…") { MarkdownBulkExport.run(chosen, app: app) }
                Button("Export all as Markdown files…") { MarkdownBulkExport.run(MarkdownBulkExport.all(app), app: app) }
            } label: { Text(exportTitle + "…") } primaryAction: { app.exportRequest = ExportRequest(ids: ready.map(\.id)) }
            .menuStyle(.borderlessButton).fixedSize().disabled(ready.isEmpty)
            .help("Choose a format and options, then a folder: one file per transcript")
            Button("Delete") { app.delete(chosen.map(\.id)); selection = [] }
                .buttonStyle(.plain).foregroundStyle(Refined.accentText)
                .help("Moves to Recently Deleted for 30 days")
        }
        .refinedFont(.body)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Refined.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Refined.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }

    // MARK: Cells

    /// Named people, a link's site, or where it came from ("Audio file", "Voice note"); while it transcribes, the
    /// stage (the row adds a spinner).
    static func people(_ t: Transcript, projects: [UUID: Project]) -> String {
        let named = t.speakers.map(\.name).filter { !$0.isEmpty && !$0.hasPrefix("Speaker ") }
        if !named.isEmpty { return named.count > 3 ? named.prefix(3).joined(separator: ", ") + " +\(named.count - 3)" : named.joined(separator: ", ") }
        if LibrarySource.isLink(t) { return t.linkInfo?.site ?? (t.sourceLabel.isEmpty ? "Link" : t.sourceLabel) }
        if t.speakers.count >= 2 { return "\(t.speakers.count) speakers" }
        if let p = t.projectId, let name = projects[p]?.name { return name }
        return HomeRecentStyle(t).source
    }

    // MARK: Empty

    @ViewBuilder private var emptyState: some View {
        if !app.search.isEmpty {
            empty("Nothing found", "Nothing matches \u{201C}\(app.search)\u{201D}. Search looks at titles and every transcript's words.")
        } else if app.libraryFilter != .all || app.libraryKind != nil {
            empty("Nothing here", "Nothing here matches \(LibraryChip.otherLabel(app.libraryFilter, kind: app.libraryKind) ?? currentChip?.label ?? "this filter").",
                  button: "Show all") { choose(.all) }
        } else if let p = app.projectFilter {
            empty("Nothing in this project yet", "Add transcripts from your library or import files.", button: "Add from Library…") { app.addFromLibrary = p }
        } else {
            empty("Nothing here yet", "Record a voice note, import a file, or paste a link on Home. Every transcript lands here.",
                  button: "Import files") { app.chooseFiles() }
        }
    }

    private func empty(_ title: String, _ message: String, button: String? = nil, action: @escaping () -> Void = {}) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                Text(message).refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
                if let button {
                    Button(button, action: action).buttonStyle(RefinedActionStyle()).padding(.top, 8)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }
}

/// The table's column widths for a card `width` points wide: the mockup's shares of 3, 1.2, 1.6, and 1 for Name, Kind,
/// People or source, and Date, and 60 pt for Length.
struct LibraryColumns {
    static let length: CGFloat = 60
    static let gap: CGFloat = 12
    static let inset: CGFloat = 16
    var name: CGFloat, kind: CGFloat, people: CGFloat, date: CGFloat

    init(width: CGFloat) {
        let free = max(300, width - 2 * Self.inset - Self.length - 4 * Self.gap)
        let unit = free / 6.8
        name = (unit * 3).rounded(.down); kind = (unit * 1.2).rounded(.down)
        people = (unit * 1.6).rounded(.down); date = (unit * 1).rounded(.down)
    }

    func width(_ c: LibraryTableSort) -> CGFloat {
        switch c {
        case .name: return name
        case .kind: return kind
        case .people: return people
        case .date: return date
        case .length: return Self.length
        }
    }
}

/// One recording in the Library's table: the title (with its pin), the kind's colored chip, the people or source (the
/// stage and a spinner while it transcribes), the day, and the length. Selected rows take the persimmon tint, others
/// alternate with the stripe. The row is one VoiceOver element that reads every column; its action opens it.
private struct LibraryTableRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var columns: LibraryColumns
    var selected: Bool
    var striped: Bool
    var people: String
    var onClick: () -> Void
    var dragIDs: () -> [UUID]

    var body: some View {
        LiveStage(transcript) { t in
            cells(t)
                .padding(.horizontal, LibraryColumns.inset).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(selected ? Refined.persimmonTint : (striped ? Refined.stripe : Color.clear))
                .allowsHitTesting(false)
                .overlay { hitLayer }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(t))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint("Selects it. Double-click or press Return to open.")
                .accessibilityAction { app.go(.transcript(t.id)) }
                .accessibilityAction(named: "Play") { play(t) }
        }
    }

    private func cells(_ t: Transcript) -> some View {
        HStack(spacing: LibraryColumns.gap) {
            HStack(spacing: 5) {
                if t.pinned { IconGlyph(art: .iconPin, size: 12, color: Refined.mute) }
                Text(t.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
            }
            .frame(width: columns.name, alignment: .leading)
            KindChip(kind: t.refinedKind)
                .frame(width: columns.kind, alignment: .leading)
            peopleCell(t)
                .frame(width: columns.people, alignment: .leading)
            Text(RefinedRules.shortDay(t.createdAt)).refinedFont(.rowTitle).foregroundStyle(Refined.dim).lineLimit(1)
                .frame(width: columns.date, alignment: .leading)
            Text(length(t) ?? "").refinedFont(.rowTitle).monospacedDigit().foregroundStyle(Refined.dim).lineLimit(1)
                .frame(width: LibraryColumns.length, alignment: .trailing)
        }
    }

    @ViewBuilder private func peopleCell(_ t: Transcript) -> some View {
        switch t.status {
        case .processing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(t.stageText.isEmpty ? "Transcribing" : t.stageText).refinedFont(.rowTitle).foregroundStyle(Refined.dim).lineLimit(1)
            }
            .help(t.stageText)
        case .failed:
            Text("Didn't finish").refinedFont(.rowTitle).foregroundStyle(Refined.dim).lineLimit(1)
        case .ready:
            Text(t.stageText.isEmpty ? people : t.stageText).refinedFont(.rowTitle).foregroundStyle(Refined.dim).lineLimit(1)
        }
    }

    /// A text-only thought has no length (review M-13).
    private func length(_ t: Transcript) -> String? {
        RowStatus.isTextOnly(t) ? nil : HomeRecentStyle.length(t.duration)
    }

    private func label(_ t: Transcript) -> String {
        let status: String? = t.status == .processing ? (t.stageText.isEmpty ? "Transcribing" : t.stageText) : t.status == .failed ? "Didn't finish" : nil
        let parts: [String?] = [t.pinned ? "Pinned" : nil, t.title, RecordingKind.refinedName(t.refinedKind), status ?? (people.isEmpty ? nil : people),
                                RefinedRules.shortDay(t.createdAt), length(t).map { _ in RefinedRules.spokenTime(t.duration) }]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    private var hitLayer: some View {
        Rectangle().fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .onTapGesture { onClick() }
            .onDrag { NSItemProvider(object: TranscriptDrag.payload(dragIDs()) as NSString) }
    }

    private func play(_ t: Transcript) {
        guard t.audioFileName != nil, t.status == .ready else { app.go(.transcript(t.id)); return }
        WindowNav.shared.play(t, app: app)
    }
}

/// The self-test's handles on the table's rows: the first two always (`lib-item-0`, `lib-item-1`), and every row while
/// the Back steps run (`lib-row-<id>`, `UITest.rowTargets`), both in SwiftUI's frames and the window's.
struct LibraryRowTarget: ViewModifier {
    var id: UUID
    var index: Int
    func body(content: Content) -> some View {
        if UITest.enabled && index < 2 {
            rows(content.uiWindowTarget("lib-item-\(index)").uiTarget("lib-item-\(index)"))
        } else {
            rows(content)
        }
    }

    @ViewBuilder private func rows<V: View>(_ v: V) -> some View {
        if UITest.rowTargets { v.uiWindowTarget("lib-row-\(id.uuidString)").uiTarget("lib-row-\(id.uuidString)") } else { v }
    }
}

extension View {
    /// The self-test's handle on a Library control, in SwiftUI's frames and the window's (the split view hosts
    /// its detail apart from the window's content, so its clicks use the window's).
    func libraryTarget(_ id: String) -> some View { uiWindowTarget(id).uiTarget(id) }
}

// MARK: - Passages

/// Search that finds the moment, not just the file: each matching line with its speaker and time, grouped by
/// transcript in a card. Click a line to open the transcript there.
struct PassageResults: View {
    var query: String
    /// The library's filtered transcripts, worked out once by the caller.
    var list: [Transcript]

    /// Per transcript: up to six matching lines to show, and how many lines match in all.
    private var hits: [(Transcript, [Segment], Int)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [(Transcript, [Segment], Int)] = []
        var total = 0
        for t in list where t.status == .ready {
            let segs = t.segments.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            guard !segs.isEmpty else { continue }
            // The count is matched against the query as typed (untrimmed), as it always was.
            let matches = q == query ? segs.count : t.segments.filter { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.count
            out.append((t, Array(segs.prefix(6)), matches))
            total += segs.count
            if total > 300 { break }
        }
        return out
    }

    var body: some View {
        let results = hits
        VStack(alignment: .leading, spacing: 10) {
            if results.isEmpty {
                Text("No passages match \u{201C}\(query)\u{201D}").refinedFont(.meta).foregroundStyle(Refined.mute)
            } else {
                SectionTitle("Passages")
            }
            ForEach(results, id: \.0.id) { t, segs, n in
                PaperCard {
                    HStack(spacing: 8) {
                        Text(t.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                        if let site = t.linkInfo?.site { Text(site).refinedFont(.meta).foregroundStyle(Refined.mute) }
                        Spacer()
                        Text(HomeCounts.countLabel(n, "match", "matches")).refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                    ForEach(segs) { s in PassageLine(transcript: t, segment: s, query: query) }
                }
                .padding(.bottom, 2)
            }
        }
    }
}

struct PassageLine: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var segment: Segment
    var query: String
    @State private var hover = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(segment.start.timecode).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.accentText).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if transcript.speakers.count >= 2, let sp = transcript.speakerName(segment.speaker) {
                    Text(sp).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                }
                Text(marked).refinedFont(.body).foregroundStyle(Refined.ink).lineLimit(3)
            }
            Spacer(minLength: 8)
            if let info = transcript.linkInfo, info.supportsTimestamps, hover {
                Button { if let u = info.url(at: segment.start) { NSWorkspace.shared.open(u) } } label: { IconGlyph(art: .iconPlay, size: 15, color: Refined.accentText) }
                    .buttonStyle(.plain).help("Open the video at \(segment.start.timecode)")
                    .accessibilityLabel("Open the video at \(segment.start.timecode)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(hover ? Refined.stripe : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.focusSegment = segment.id; app.go(.transcript(transcript.id)) }
        .accessibilityAddTraits(.isButton)
    }

    /// The query in the line, on the persimmon tint in semibold.
    private var marked: AttributedString {
        var a = AttributedString(segment.text)
        var start = a.startIndex
        while start < a.endIndex, let r = a[start...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Refined.persimmonTint
            a[r].inlinePresentationIntent = .stronglyEmphasized
            start = r.upperBound
        }
        return a
    }
}

// MARK: - Preview

/// The Library's preview in the window's inspector: the selected recording (or the newest) with its kind, day, length,
/// and people, its title, the summary, its first line, and Play, Open Transcript, and ⋯. Plain text on the inspector,
/// as the transcript's inspector lists its parts; Apple draws the inspector.
struct LibraryPreview: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: WindowNav

    var body: some View {
        let _ = NavMarks.mark("library-preview")
        let list = app.libraryLists(kind: app.libraryKind).list
        let chosen = nav.librarySelection.flatMap { id in list.first { $0.id == id } } ?? list.max { $0.createdAt < $1.createdAt }
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
                    Button { nav.play(t, app: app) } label: { Label("Play", systemImage: "play.fill") }   // brand: system surface (the inspector)
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
                InspectorSummary(summary: s, byModel: t.summaryByModel)
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
        var parts = [RecordingKind.refinedName(t.refinedKind), Formats.pattern("EEE MMM d").string(from: t.createdAt)]
        if t.duration > 0 && !RowStatus.isTextOnly(t) { parts.append(HomeRecentStyle.length(t.duration)) }
        let people = LibraryView.people(t, projects: app.store.projectsByID)
        if !people.isEmpty { parts.append(people) }
        return parts.joined(separator: " · ")
    }
}

/// A transcript's summary in the Library's inspector, as plain text the way the inspector lists everything else: the
/// overview, the first key points, and "Made by Apple Intelligence" in secondary.
private struct InspectorSummary: View {
    var summary: TranscriptSummary
    var byModel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Summary").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if !summary.overview.isEmpty {
                Text(summary.overview).font(.system(size: 13)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.top, 6)
            }
            if !summary.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.keyPoints.prefix(3).enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•").font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(p).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Key points")
            }
            if byModel {
                Text(AIGeneratedNote.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
