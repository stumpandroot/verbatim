import SwiftUI

// brand: web style
//
/// Every transcript, grouped by day (pinned first), filtered by the sidebar project, the kind and type chips, and the
/// search field. Website style (mac/DESIGN.md §11): a compact title with a mono count and the search field on the
/// right, soft filter chips, mono day headers, flat rows with serif titles, and the projects on color panels in a
/// right column. Select mode picks many at once to move, export, or delete; any row (or the selection) drags onto a
/// project. ⌘-click adds or removes a row and Shift-click selects a range, starting Select mode when it's off.
struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    /// Where a Shift-click range starts: the last row clicked or ⌘-clicked.
    @State private var anchor: UUID? = nil
    /// The project card under the pointer: its drawing moves (one moving drawing per screen; otherwise the first).
    @State private var hoveredProject: UUID? = nil
    @State private var projectDown: UUID? = nil
    /// Library › kind chips (nil is All), kept on AppState so the screenshot tour can choose one.
    private var kind: RecordingKind? { app.libraryKind }
    /// Newest, Oldest, Longest, or Title A–Z, remembered on this Mac.
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }

    private static let margin: CGFloat = 40
    private static let maxContent: CGFloat = 1100
    private static let sideWidth: CGFloat = 300

    var body: some View {
        // `filtered` searches every transcript's text; work it out once per render.
        let base = app.filtered
        let searching = !app.search.trimmingCharacters(in: .whitespaces).isEmpty
        let typeFilter = app.libraryFilter
        // Dictations stay out unless you're searching or chose Dictations; they live in Dictations.
        let all = typeFilter.apply(base, searching: searching)
        let byKind = kind.map { k in base.filter { $0.kind == k } } ?? base
        let list = kind.map { k in all.filter { $0.kind == k } } ?? all
        let groups = Store.group(list, sort: sort)
        let order = groups.flatMap { $0.items.map(\.id) }
        // Project names by ID, once per render (rows italicize after their project's name and name it outside it).
        let projectNames = Dictionary(app.store.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        GeometryReader { geo in
            let inner = min(Self.maxContent, max(320, geo.size.width - 2 * Self.margin))
            // The projects column: on wide windows, outside a project, and not in the Journal's reading view.
            let side = inner >= 820 && app.projectFilter == nil && kind != .journal
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(count: list.count, searchBelow: inner < 760).staggerIn(0)
                    if inner < 760 {
                        WebSearchField(text: $app.search, prompt: "Find the line you need").padding(.top, 14)
                    }
                    chips(base: base, all: all, byKind: byKind, searching: searching).padding(.top, 18).staggerIn(1)
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 0) {
                            if let k = kind {
                                KindHeroCard(kind: k, meta: heroMeta(k, list), compact: true).frame(maxWidth: 760).padding(.top, 16)
                            }
                            if app.search.trimmingCharacters(in: .whitespaces).count >= 2 {
                                PassageResults(query: app.search, list: list).padding(.top, 14)
                            }
                            if groups.isEmpty {
                                emptyState(typeFilter).padding(.top, 22).staggerIn(1)
                            }
                            if kind == .journal && !selecting {
                                journal(list, order: order).padding(.top, 20)
                            } else {
                                rows(groups, order: order, projectNames: projectNames)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if side {
                            projectColumn.frame(width: Self.sideWidth).padding(.top, 22).staggerIn(2)
                        }
                    }
                }
                .frame(width: inner, alignment: .leading)
                .padding(.horizontal, Self.margin).padding(.top, 30).padding(.bottom, selecting ? 90 : 40)
                .frame(maxWidth: .infinity)
            }
            .animation(Motion.settle, value: list.map(\.id))
        }
        .overlay(alignment: .bottom) {
            if selecting { actionBar.padding(.bottom, 18).transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .identity)) }
        }
        .onChange(of: app.projectFilter) { _, _ in selection = [] }
        .onAppear { KeptMedia.shared.refresh() }
    }

    // MARK: Header and chips

    private var projectName: String? { app.projectFilter.flatMap { id in app.store.projects.first { $0.id == id }?.name } }

    /// "Library  46 transcripts", with Select, Add from Library (in a project), Import, and the search field.
    private func header(count: Int, searchBelow: Bool) -> some View {
        let title: (String, String?) = projectName.map { WebText.splitLastWord($0) } ?? (kind?.plural ?? "Library", nil)
        return PageTitle(title: title.0, italic: title.1, count: count == 1 ? "1 transcript" : "\(count.formatted()) transcripts") {
            HStack(spacing: 8) {
                if count > 0 {
                    Button(selecting ? "Done" : "Select") {
                        withAnimation(Motion.snap) { selecting.toggle(); if !selecting { selection = []; anchor = nil } }
                    }
                    .buttonStyle(PillButtonStyle(kind: selecting ? .dark : .line, size: .mini))
                    .keyboardShortcut(selecting ? .cancelAction : .init("s", modifiers: [.command, .shift]))
                }
                if let p = app.projectFilter {
                    Button("Add from Library…") { app.addFromLibrary = p }
                        .buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                        .help("Add transcripts you already have to this project (⇧⌘L)")
                        .uiTarget("add-from-library")
                }
                Button("Import") { app.chooseFiles() }
                    .buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                    .help(app.projectFilter == nil ? "Import audio or video files" : "Import audio or video files into this project")
                if !searchBelow {
                    WebSearchField(text: $app.search, prompt: "Find the line you need").frame(width: 300)
                }
            }
        }
    }

    /// One row of soft chips, as the mockup's Library (`#library .chips`): All with the full count, each type with its
    /// source's color dot, then each kind, and the sort menu at the end. All clears both filters; a chosen chip clicked
    /// again clears its own. Types and kinds with nothing in them stay out (unless chosen). Videos and Links add their
    /// platforms on a second, smaller row when there's more than one. ⌥⌘1–7 choose a type (All is 1).
    private func chips(base: [Transcript], all: [Transcript], byKind: [Transcript], searching: Bool) -> some View {
        let filter = app.libraryFilter
        let total = LibraryFilter.all.apply(base, searching: searching).count
        let sources = filter.sourceCounts(byKind, searching: searching).filter { $0.0 != .all }
        var kindCounts: [RecordingKind: Int] = [:]
        for t in all { if let k = t.kind { kindCounts[k, default: 0] += 1 } }
        let kinds: [(RecordingKind, Int)] = RecordingKind.pickable.compactMap { k in
            let n = kindCounts[k] ?? 0
            return n > 0 || kind == k ? (k, n) : nil
        }
        let platforms = filter.platformCounts(byKind, searching: searching)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                FlowRow(spacing: 8, lineSpacing: 8) {
                    FilterChip(title: "All", count: total, selected: kind == nil && filter == .all) {
                        app.libraryKind = nil
                        app.libraryFilter = .all
                        selection = []
                    }
                    .modifier(TypeShortcut(index: 1, on: true))
                    .uiTarget("kind-all")
                    ForEach(sources, id: \.0) { s, n in
                        FilterChip(title: s.label, count: n, dot: LibraryFilterBar.dot(s), ring: s == .links, selected: filter.source == s) {
                            app.libraryFilter = filter.source == s ? .all : LibraryFilter(source: s)
                            selection = []
                        }
                        .modifier(TypeShortcut(index: LibrarySource.allCases.firstIndex(of: s).map { $0 + 1 }, on: true))
                        .uiTarget("source-\(s.rawValue)")
                    }
                    ForEach(kinds, id: \.0) { k, n in
                        FilterChip(title: k.plural, count: n, selected: kind == k) {
                            app.libraryKind = kind == k ? nil : k
                            selection = []
                        }
                        .uiTarget("kind-\(k.rawValue)")
                    }
                }
                .accessibilityElement(children: .contain).accessibilityLabel("Filter")
                Spacer(minLength: 0)
                Menu {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(LibrarySort.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(sort.title, systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Sort the Library: newest, oldest, longest, or by title")
                .accessibilityLabel("Sort by \(sort.title)")
            }
            if !platforms.isEmpty {
                FlowRow(spacing: 8, lineSpacing: 8) {
                    ForEach(platforms, id: \.0) { p, n in
                        FilterChip(title: p, count: n, selected: filter.platform == p, small: true) {
                            app.libraryFilter = LibraryFilter(source: filter.source, platform: filter.platform == p ? nil : p)
                            selection = []
                        }
                        .uiTarget("platform-\(p)")
                    }
                }
                .accessibilityElement(children: .contain).accessibilityLabel("Platform")
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: platforms.isEmpty)
    }

    // MARK: Rows

    /// "Today · Fri Oct 23": the group's label, with the date for Today and Yesterday.
    private func dayLabel(_ g: (label: String, items: [Transcript])) -> String {
        guard g.label == "Today" || g.label == "Yesterday", let first = g.items.first else { return g.label }
        return "\(g.label) · \(Formats.pattern("EEE MMM d").string(from: first.createdAt))"
    }

    /// Lazy, so a library of hundreds builds only the rows on screen. Rows and day headers don't stagger in: they
    /// arrive with the screen.
    private func rows(_ groups: [(label: String, items: [Transcript])], order: [UUID], projectNames: [UUID: String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.label) { gi, g in
                HStack(spacing: 12) {
                    DayHeader(text: dayLabel(g))
                    if selecting {
                        let ids = Set(g.items.map(\.id))
                        Button(ids.isSubset(of: selection) ? "Deselect" : "Select all") {
                            if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
                        }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.ink)
                    }
                }
                .padding(.top, gi == 0 ? 22 : 18).padding(.bottom, 8)
                ForEach(Array(g.items.enumerated()), id: \.element.id) { ii, t in
                    let own = t.projectId.flatMap { projectNames[$0] }
                    HistoryRow(transcript: t, selected: selecting ? selection.contains(t.id) : nil,
                               project: app.projectFilter == nil ? own : nil, projectName: own,
                               dragIDs: { selection.contains(t.id) ? Array(selection) : [t.id] },
                               open: { click(t.id, order: order) })
                        .contextMenu { RowMenu(transcript: t) }
                        .padding(.top, ii == 0 ? 0 : 2)
                }
            }
        }
    }

    private func emptyState(_ typeFilter: LibraryFilter) -> some View {
        Group {
            if !app.search.isEmpty {
                EmptyStateCard(art: .search, title: "Nothing found",
                               message: "Nothing matches “\(app.search)”. Search looks at titles and every transcript's text.")
            } else if typeFilter != .all {
                EmptyStateCard(art: .iconLibrary, title: "Nothing here",
                               message: "Nothing here matches \(typeFilter.platform ?? typeFilter.source.label).",
                               button: "Show all", action: { app.libraryFilter = .all })
            } else if let p = app.projectFilter {
                EmptyStateCard(art: .iconProject, title: "Nothing in this project yet",
                               message: "Add transcripts from your library or import files.",
                               button: "Add from Library", action: { app.addFromLibrary = p })
            } else if kind != nil {
                EmptyStateCard(art: .iconLibrary, title: "Nothing here yet",
                               message: "Recordings of this kind land here as you make them.",
                               button: "Show all", action: { app.libraryKind = nil })
            } else {
                EmptyStateCard(art: .iconLibrary, title: "Nothing here yet",
                               message: "Record a voice note, import a file, or paste a link on Home. Every transcript lands here.",
                               button: "Import files", action: { app.chooseFiles() })
            }
        }
    }

    // MARK: Projects

    /// The projects on color panels, each with its drawing, and New project. Only one drawing moves: the card under
    /// the pointer, or the first.
    private var projectColumn: some View {
        let projects = app.store.projects
        let moving = hoveredProject ?? projects.first?.id
        // Every project's transcripts in one pass, not one pass over the library per card.
        var members: [UUID: [Transcript]] = [:]
        for t in app.store.transcripts where t.deletedAt == nil && !t.isDictation { if let p = t.projectId { members[p, default: []].append(t) } }
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(projects.enumerated()), id: \.element.id) { i, p in
                projectCard(p, items: members[p.id] ?? [], index: i, moving: moving == p.id)
            }
            PillButton(title: "New project", kind: .line, trailing: .plus, fullWidth: true,
                       hint: "Names a new project. Then drag transcripts onto it in the sidebar.") { app.newProjectFor = [] }
                .uiTarget("library-new-project")
            Text(projects.isEmpty ? "Group transcripts by client or job." : "Drag a transcript onto a project in the sidebar to file it.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let projectFills: [Color] = [Ink.panelButter, Ink.panelPetal, Ink.panelSage]

    private func projectCard(_ p: Project, items: [Transcript], index i: Int, moving: Bool) -> some View {
        let people = Set(items.flatMap { t in t.speakers.map(\.name).filter { !$0.isEmpty && !$0.hasPrefix("Speaker ") } }).count
        let meta = [HomeCounts.countLabel(items.count, "transcript", "transcripts"), people > 0 ? HomeCounts.countLabel(people, "person", "people") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let name = WebText.splitLastWord(p.name)
        return HomeCard(tilt: 3, radius: Radius.record, shadow: false, onHover: { h in
            if h { hoveredProject = p.id } else if hoveredProject == p.id { hoveredProject = nil }
        }, onPress: { down in projectDown = down ? p.id : nil }, action: { app.projectFilter = p.id }) { hovering in
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "Project", color: Ink.inkFixed)
                Spacer(minLength: 8)
                WebText.serif(name.0, italic: name.1, size: 28).lineLimit(2).minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                Text(meta).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Ink.inkFixed)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 170)
            .colorPanel(Self.projectFills[i % Self.projectFills.count], radius: Radius.record) {
                if i % 2 == 0 {
                    PanelArt(kind: .lines, running: moving).frame(width: 200, height: 170).offset(x: 30, y: 0)
                } else {
                    PanelArt(kind: .circles, running: moving).frame(width: 230, height: 200).offset(x: 70, y: -50)
                }
            }
            .inkEdge(outline: hovering, shadow: InkEdge.card(hover: hovering, pressed: projectDown == p.id), radius: Radius.record)
        }
        .accessibilityLabel("Project \(p.name)")
        .accessibilityValue(meta)
        .accessibilityHint("Shows this project's transcripts.")
    }

    private func heroMeta(_ k: RecordingKind, _ list: [Transcript]) -> String {
        if k == .journal {
            let week = Date().addingTimeInterval(-7 * 86_400)
            let n = list.filter { $0.createdAt >= week }.count
            return "\(n) this week"
        }
        return list.count == 1 ? "1 saved" : "\(list.count) saved"
    }

    /// Journal reads by day: "Today · Sat 17 Oct", then each entry as a flat row with its serif title, time, length,
    /// and opening lines.
    private func journal(_ list: [Transcript], order: [UUID]) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(JournalDays.group(list)) { day in
                VStack(alignment: .leading, spacing: 8) {
                    DayHeader(text: day.label == day.date ? day.label : "\(day.label) · \(day.date)")
                    VStack(spacing: 2) {
                        ForEach(day.entries) { t in
                            FlatRowButton(action: { click(t.id, order: order) }) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        WebText.serif(t.title, size: 22).foregroundStyle(Ink.ink).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text("\(Formats.pattern("h:mm a").string(from: t.createdAt)) · \(WebFormat.clock(t.duration))")
                                            .font(Ink.mono(12)).foregroundStyle(Ink.dim).lineLimit(1).fixedSize()
                                    }
                                    Text(JournalDays.preview(t)).font(.system(size: 15)).foregroundStyle(Ink.dim).lineSpacing(3).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            }
                            .contextMenu { RowMenu(transcript: t) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func toggle(_ id: UUID) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }

    /// A row click: ⌘ adds or removes it, Shift selects the range from the anchor (both start Select mode); a plain
    /// click toggles in Select mode and opens the transcript otherwise.
    private func click(_ id: UUID, order: [UUID]) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift), let a = anchor ?? (selecting ? selection.first : nil),
           let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            withAnimation(Motion.snap) { selecting = true }
            selection.formUnion(order[min(i, j)...max(i, j)])
        } else if flags.contains(.command) || flags.contains(.shift) {
            withAnimation(Motion.snap) { selecting = true }
            toggle(id); anchor = id
        } else if selecting {
            toggle(id); anchor = id
        } else {
            app.go(.transcript(id))
        }
    }

    private var chosen: [Transcript] { app.filtered.filter { selection.contains($0.id) } }

    private var exportTitle: String {
        let n = chosen.filter { $0.status == .ready }.count
        return n == 1 ? "Export 1 transcript" : "Export \(n) transcripts"
    }

    /// The export sheet for the selection, in Library order (transcripts still in progress are left out).
    private func openExport() {
        let ids = chosen.filter { $0.status == .ready }.map(\.id)
        guard !ids.isEmpty else { return }
        app.exportRequest = ExportRequest(ids: ids)
    }

    /// Glass action bar for the selection.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "Select transcripts" : "\(selection.count) selected").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
                .frame(minWidth: 110, alignment: .leading)
            Button("Select all") { selection = Set(app.filtered.map(\.id)) }.buttonStyle(.plain).foregroundStyle(Ink.iris).font(.system(size: 13, weight: .medium))
            Divider().frame(height: 20)
            Menu {
                Button("No project") { app.move(Array(selection), to: nil) }
                if !app.store.projects.isEmpty { Divider() }
                ForEach(app.store.projects) { p in Button(p.name) { app.move(Array(selection), to: p.id) } }
            } label: { Label("Move to", art: .iconProject, size: 15) }
            .menuStyle(.borderlessButton).fixedSize().disabled(selection.isEmpty)
            Menu {
                Button(exportTitle + "…") { openExport() }
                Divider()
                Button("Copy all to clipboard") {
                    let text = Exporter.clipboard(chosen.filter { $0.status == .ready }, as: .txt, options: .saved)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    app.toast = Toast("Copied \(chosen.count) transcripts")
                }
                Divider()
                // One Markdown note per transcript, with properties Obsidian reads (Views/TrustViews.swift).
                Button("Export as Markdown files…") { MarkdownBulkExport.run(chosen, app: app) }
                Button("Export all as Markdown files…") { MarkdownBulkExport.run(MarkdownBulkExport.all(app), app: app) }
            } label: { Label(exportTitle + "…", systemImage: "square.and.arrow.up") } primaryAction: { openExport() }
            .menuStyle(.borderlessButton).fixedSize().disabled(selection.isEmpty)
            .help("Choose a format and options, then a folder: one file per transcript")
            Button(role: .destructive) {
                app.delete(Array(selection)); selection = []
            } label: { Label("Delete", systemImage: "trash") }
            .help("Moves to Recently Deleted for 30 days")
            .buttonStyle(.plain).foregroundStyle(selection.isEmpty ? Ink.mute : Ink.danger).disabled(selection.isEmpty)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).padding(.vertical, 10)
        // Opaque: text never sits on a blur (DESIGN.md §5.1).
        .background(Ink.bar, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.hairline))
        .shadow(color: Ink.inkFixed.opacity(0.08), radius: 3, y: 1)
    }
}

/// Search that finds the moment, not just the file: each matching line with its speaker and time, grouped by
/// transcript. Click a line to open the transcript there.
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
            Text(results.isEmpty ? "No passages match “\(query)”" : "Passages")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.mute)
            ForEach(results, id: \.0.id) { t, segs, n in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(t.title).font(Ink.serif(16, weight: .regular)).foregroundStyle(Ink.ink).lineLimit(1)
                        if let site = t.linkInfo?.site { Text(site).font(.system(size: 11.5)).foregroundStyle(Ink.mute) }
                        Spacer()
                        Text("\(n) match\(n == 1 ? "" : "es")").font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                    ForEach(segs) { s in PassageLine(transcript: t, segment: s, query: query) }
                }
                .padding(.bottom, 6)
                .background(NoteCardBackground(hover: false))
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
            Text(segment.start.timecode).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Ink.iris).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if transcript.speakers.count >= 2, let sp = transcript.speakerName(segment.speaker) {
                    Text(sp).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Ink.mute)
                }
                Text(marked).font(.system(size: 14)).foregroundStyle(Ink.ink).lineLimit(3)
            }
            Spacer(minLength: 8)
            if let info = transcript.linkInfo, info.supportsTimestamps, hover {
                Button { if let u = info.url(at: segment.start) { NSWorkspace.shared.open(u) } } label: { ArtIcon(art: .iconPlay, size: 15) }
                    .buttonStyle(.plain).foregroundStyle(Ink.iris).help("Open the video at \(segment.start.timecode)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(hover ? Ink.iris.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.focusSegment = segment.id; app.go(.transcript(transcript.id)) }
    }

    private var marked: AttributedString {
        var a = AttributedString(segment.text)
        var start = a.startIndex
        while start < a.endIndex, let r = a[start...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Ink.match; a[r].font = .system(size: 14, weight: .semibold)
            start = r.upperBound
        }
        return a
    }
}
