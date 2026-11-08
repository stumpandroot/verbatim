import SwiftUI
import AppKit

/// The Library (DESIGN.md §6.8 and §13; mockup "Verbose Refined Look", MacLibrary): the serif title with the count, the quick filter chips (All, Voice notes, Meetings, Thoughts,
/// Audio, Links, Marked) with the sort ("Newest first") at the end, and every recording as a table in a card: Name,
/// Kind (its colored chip), People or source, Date, and Length, with alternating rows and the selected row in the
/// persimmon tint. Every column sorts. A click selects (⌘-click adds, Shift-click a range), a double-click or Return
/// opens, Space plays, the arrow keys move, and right-click has the row's menu (or the selection's). Rows drag onto a
/// project in the sidebar. With more than one selected, a bar at the foot moves, exports, or deletes them. The window's
/// inspector previews the selection. Search is the Search or ask panel (AskViews.swift, MAC-35), so typing never filters
/// the table; the panel's Show all in the Library does, and the search's chip clears it. Back and the sidebar bring the Library back scrolled where you left it, with the row you opened selected
/// (App/NavTrail.swift). A lazy table: a library of hundreds builds only the rows on screen.
struct LibraryView: View {
    @Environment(AppState.self) var app
    /// Newest, Oldest, Longest, or Title A–Z, remembered on this Mac; the table writes it when its sort is one of them.
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    /// The table's sort: one column and its direction, started from the Library's sort.
    @State private var column: LibraryTableSort
    /// Two columns: where the table starts, so the side column starts level with it.
    @State private var sideTop: CGFloat = 0
    @State private var descending: Bool
    /// The selected recordings, kept across screens (ScreenPlaces).
    @State private var selection: Set<UUID> = ScreenPlaces.shared.tableSelection
    /// Where a Shift-click range starts: the last row clicked or ⌘-clicked.
    @State private var anchor: UUID? = nil
    /// Clear for a moment after a chip changes the filter, then fades in (`fadeList`).
    @State private var listShown = true
    @FocusState private var focused: Bool
    /// Which column has the keyboard (MAC-25): the selected row shows a leading bar while the table has it, and dims
    /// while the sidebar does.
    @ObservedObject private var columns = ColumnFocus.shared
    /// Whether the inspector shows: with it open, the side column (which holds only the Selected card) steps aside.
    @ObservedObject private var nav = WindowNav.shared

    /// How many Libraries are on screen, and their rows' order (the self-test).
    static var onScreen = 0
    static var shownOrder: [UUID] = []

    private static let margin: CGFloat = 40

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
                // Two columns (mockup "Verbose Mac Columns"): the table takes the width, and a 320 pt side column holds
                // the selected recording while the inspector is closed (MAC-34: no Collections card; the sidebar has
                // them). Narrow windows, a project, and an open inspector keep one column.
                let wide = MacSideColumn.librarySplits(wide: MacColumnsMetrics.twoColumns(geo.size.width), inProject: app.projectFilter != nil,
                                                       inspectorVisible: nav.inspectorVisible)
                let margin = geo.size.width < 760 ? 24 : Self.margin
                let width = wide ? MacColumnsMetrics.mainWidth(geo.size.width) : max(320, geo.size.width - 2 * margin)
                HStack(alignment: .top, spacing: wide ? MacColumnsMetrics.gap : 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        page(lists: lists, rows: rows, order: order, width: width)
                            .frame(width: width, alignment: .leading)
                            .coordinateSpace(name: MacColumnsMetrics.space)
                            .padding(.leading, wide ? MacColumnsMetrics.leading : margin)
                            .padding(.trailing, wide ? 0 : margin).padding(.top, MacColumnsMetrics.top)
                            .padding(.bottom, selection.count > 1 ? 90 : 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Back and the sidebar bring the Library back where you left it (App/NavTrail.swift).
                            .scrollPlace(ScreenPlaces.scrollKey(ScreenPlaces.libraryKey(app.projectFilter)))
                            .navMarkWhenLaidOut("library-laid-out")
                    }
                    .softScrollEdges(.top)
                    .focusable()
                    .focused($focused)
                    // No blue ring around the table; the selected row's leading bar shows it has the keyboard.
                    .focusEffectDisabled()
                    .onChange(of: focused) { _, on in columns.set(.library, on) }
                    .onKeyPress(.downArrow) { step(1, order, proxy); return .handled }
                    .onKeyPress(.upArrow) { step(-1, order, proxy); return .handled }
                    // Return and Space open from the keyboard: the transcript shows at once (DESIGN.md §7).
                    .onKeyPress(.return) {
                        return app.fromKeyboard { openSelected() } ? .handled : .ignored
                    }
                    .onKeyPress(.space) {
                        return app.fromKeyboard { playSelected() } ? .handled : .ignored
                    }
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
                .frame(width: wide ? width + MacColumnsMetrics.leading : geo.size.width)
                if wide {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { sideColumn(order: order) }
                            .frame(width: MacColumnsMetrics.side, alignment: .topLeading)
                            .padding(.top, MacColumnsMetrics.top + sideTop).padding(.bottom, 40)
                    }
                    .scrollIndicators(.never)
                    .frame(width: MacColumnsMetrics.side)
                    .padding(.trailing, MacColumnsMetrics.trailing)
                }
                }
            }
        }
        .onPreferenceChange(MacColumnsTopKey.self) { v in
            let t = max(0, (v ?? 0).rounded())
            if sideTop != t { sideTop = t }
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

    // MARK: Side column

    /// The one selected recording with Play and Open, the same card the inspector shows (MAC-18), only while the
    /// inspector is closed. The Collections card (Dictations, Thoughts by day, Journal, Templates, Ask) left: the sidebar
    /// holds every one of them (MAC-34).
    @ViewBuilder private func sideColumn(order: [UUID]) -> some View {
        if let t = single {
            SelectedSideCard(transcript: t, onPlay: { _ = playSelected() }, onOpen: { _ = openSelected() })
        }
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
            Group {
                if rows.isEmpty {
                    emptyState.macColumnsTop().padding(.top, 16)
                } else {
                    table(rows, order: order, columns: LibraryColumns(width: width)).macColumnsTop().padding(.top, 16)
                }
            }
            .opacity(listShown ? 1 : 0)
        }
    }

    /// The title (a project's name, or "Library") and the count; in a project, Add from Library; for Thoughts and
    /// Journal, Read by day.
    private func titleRow(count: Int) -> some View {
        // The last baseline: controls line up with the title, not the count over it.
        HStack(alignment: .lastTextBaseline, spacing: 12) {
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
                // The panel's Show all in the Library (MAC-35): the words, chosen, with a click to clear them.
                if !app.search.isEmpty {
                    RefinedChip(title: "\u{201C}\(app.search)\u{201D}", selected: true) { app.search = "" }
                        .accessibilityLabel("Search: \(app.search)")
                        .accessibilityHint("Clears the search.")
                        .libraryTarget("chip-search")
                }
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
        let filter = LibraryFilter(source: chip.source)
        guard app.libraryKind != chip.kind || app.libraryFilter != filter else { return }
        fadeList {
            app.libraryKind = chip.kind
            app.libraryFilter = filter
        }
    }

    /// A chip's change fades the list in as a whole over 150 ms (DESIGN.md §7, view switches): the rows change at once
    /// while the list is clear, then it fades in. No row animates on its own, and nothing waits for it.
    private func fadeList(_ change: () -> Void) {
        listShown = false
        change()
        DispatchQueue.main.async { withAnimation(Motion.crossfade) { listShown = true } }
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
        let look = SelectionLook.of(.library, focus: self.columns.focus)
        return PaperTable {
            header(columns)
        } rows: {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, t in
                LibraryTableRow(transcript: t, columns: columns, selected: selection.contains(t.id), look: look, striped: i % 2 == 0,
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
            ForEach(LibraryTableSort.allCases.filter { columns.shows($0) }, id: \.self) { c in
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

/// The table's column widths for a card `width` points wide (`LibraryColumnPlan`, App/MacCommandRules.swift): Name,
/// Kind at a fixed width so its chip always reads in full, People or source, Date, and 60 pt for Length. As the card
/// narrows, People goes first and then Date (MAC-05); a hidden column has width 0 and isn't drawn.
struct LibraryColumns {
    static let length = LibraryColumnPlan.length
    static let gap = LibraryColumnPlan.gap
    static let inset = LibraryColumnPlan.inset
    var name: CGFloat, kind: CGFloat, people: CGFloat, date: CGFloat

    init(width: CGFloat) {
        let plan = LibraryColumnPlan(width: width)
        name = plan.name; kind = LibraryColumnPlan.kind
        people = plan.people ?? 0; date = plan.date ?? 0
    }

    /// Whether the column has room at this width.
    func shows(_ c: LibraryTableSort) -> Bool {
        switch c {
        case .people: return people > 0
        case .date: return date > 0
        default: return true
        }
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
    @Environment(AppState.self) var app
    var transcript: Transcript
    var columns: LibraryColumns
    var selected: Bool
    /// The selection's look (MAC-25): the tint, the tint with the focus bar, or dimmed.
    var look: SelectionLook = .tint
    var striped: Bool
    var people: String
    var onClick: () -> Void
    var dragIDs: () -> [UUID]

    var body: some View {
        LiveStage(transcript) { t in
            cells(t)
                .padding(.horizontal, LibraryColumns.inset).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(selected ? (look == .dimmed ? Refined.neutral : Refined.persimmonTint) : (striped ? Refined.stripe : Color.clear))
                .overlay(alignment: .leading) { if selected && look == .focused { FocusBar() } }
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
            if columns.shows(.people) {
                peopleCell(t)
                    .frame(width: columns.people, alignment: .leading)
            }
            if columns.shows(.date) {
                Text(RefinedRules.shortDay(t.createdAt)).refinedFont(.rowTitle).foregroundStyle(Refined.dim).lineLimit(1)
                    .frame(width: columns.date, alignment: .leading)
            }
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

// MARK: - Preview

/// The Library's preview in the window's inspector: the selected recording (or the newest) as `LibrarySelectionCard`,
/// the same card the side column shows while the inspector is closed (MAC-18).
struct LibraryPreview: View {
    @Environment(AppState.self) var app
    @ObservedObject var nav: WindowNav

    var body: some View {
        let _ = NavMarks.mark("library-preview")
        let list = app.libraryLists(kind: app.libraryKind).list
        let chosen = nav.librarySelection.flatMap { id in list.first { $0.id == id } } ?? list.max { $0.createdAt < $1.createdAt }
        ScrollView {
            if let t = chosen {
                LibrarySelectionCard(transcript: t, full: true, onPlay: { nav.play(t, app: app) }, onOpen: { app.go(.transcript(t.id)) })
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
            } else {
                Text("Select a recording to see its summary.")
                    .refinedFont(.body).foregroundStyle(Refined.mute)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .scrollIndicators(.never)
    }
}

/// The side column's Selected card: the selection card in a side card, only while the inspector is closed, so the
/// selection is previewed once (MAC-18).
private struct SelectedSideCard: View {
    var transcript: Transcript
    var onPlay: () -> Void
    var onOpen: () -> Void
    @ObservedObject private var nav = WindowNav.shared

    var body: some View {
        if !nav.inspectorVisible {
            MacSideCard(title: "Selected") {
                LibrarySelectionCard(transcript: transcript, full: false, onPlay: onPlay, onOpen: onOpen)
            }
        }
    }
}

/// The selected recording, one design wherever the Library previews it (MAC-18; DESIGN.md §13): the title in the row
/// title's size, semibold; its kind, day, length, and people in the meta style; a quiet Play with the kit's play glyph
/// (DESIGN.md §3) and a strong Open; then the first line. The inspector's (`full`) adds More, the summary, and a longer
/// first line. Kit type and tokens only, on whatever surface holds it.
struct LibrarySelectionCard: View {
    @Environment(AppState.self) var app
    var transcript: Transcript
    var full: Bool
    var onPlay: () -> Void
    var onOpen: () -> Void

    var body: some View {
        let t = transcript
        VStack(alignment: .leading, spacing: 0) {
            Text(t.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                .lineLimit(full ? 3 : 2).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(Self.meta(t, projects: app.store.projectsByID)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.dim)
                .lineLimit(2).padding(.top, 3)
            HStack(spacing: 8) {
                if t.audioFileName != nil && t.status == .ready {
                    Button(action: onPlay) {
                        HStack(spacing: 6) {
                            IconGlyph(art: .iconPlay, size: 12, color: Refined.ink)
                            Text("Play")
                        }
                    }
                    .buttonStyle(RefinedActionStyle())
                    .help("Open and play (Space)")
                }
                Button("Open", action: onOpen)
                    .buttonStyle(RefinedActionStyle(kind: .strong))
                    .help("Open the transcript (Return)")
                    .accessibilityLabel("Open transcript")
                    .modifier(OpenTarget(full: full))
                if full {
                    Menu { RowMenu(transcript: t) } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("More for \(t.title)")
                }
            }
            .padding(.top, 10)
            if full, let s = t.summary, !s.isEmpty {
                summary(s, byModel: t.summaryByModel).padding(.top, 16)
            }
            if let line = t.visibleSegments(hideFiller: true).first?.text, !line.isEmpty {
                Text("\u{201C}\(full ? line : String(line.prefix(140)))\u{201D}").refinedFont(.meta).foregroundStyle(Refined.dim)
                    .lineSpacing(2).lineLimit(full ? 5 : 3).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, full ? 16 : 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The overview, the first three key points with the summary's sage dots, and Apple Intelligence's note, as the
    /// Summary tab draws them at the body size.
    private func summary(_ s: TranscriptSummary, byModel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute).accessibilityAddTraits(.isHeader)
            if !s.overview.isEmpty {
                Text(s.overview).refinedFont(.body).foregroundStyle(Refined.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !s.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(s.keyPoints.prefix(3).enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Refined.played).frame(width: 5, height: 5)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                                .accessibilityHidden(true)
                            Text(p).refinedFont(.body).foregroundStyle(Refined.ink)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 2)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Key points")
            }
            if byModel {
                Text(AIGeneratedNote.summary).refinedFont(.meta).foregroundStyle(Refined.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Meeting · Thu Oct 22 · 1:04:12 · Anika, Marcus".
    static func meta(_ t: Transcript, projects: [UUID: Project]) -> String {
        var parts = [RecordingKind.refinedName(t.refinedKind), Formats.pattern("EEE MMM d").string(from: t.createdAt)]
        if t.duration > 0 && !RowStatus.isTextOnly(t) { parts.append(HomeRecentStyle.length(t.duration)) }
        let people = LibraryView.people(t, projects: projects)
        if !people.isEmpty { parts.append(people) }
        return parts.joined(separator: " · ")
    }

    /// The inspector's Open is the self-test's "lib-open" (the inspector's frames are the window's).
    private struct OpenTarget: ViewModifier {
        var full: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if full { content.uiWindowTarget("lib-open") } else { content }
        }
    }
}
