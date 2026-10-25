import SwiftUI
import AppKit

// brand: native file
//
// The Library in Premium Native (mockup "Premium Native", Mac Library): recordings as an editorial list under plain day
// headers (the Voicenotes item, PremiumItems.swift) beside a preview in the inspector (the selected item's summary
// card, its first line, Play, and Open Transcript). Click selects; double-click, Return, or Open Transcript opens;
// arrow keys move; Space plays. The title and count, the scope, Sort, and More live in the window's toolbar
// (NativeChrome.swift). More › View as Table brings back the first Native look's `Table` (multiple selection, columns).
// Rows drag onto a project in the sidebar, where the projects live in Native. Search is the window's toolbar field.

struct NativeLibraryView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: NativeNav
    @State private var selection: Set<String> = []
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue
    @FocusState private var listFocused: Bool
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .newest }

    /// A table row: a day header, or a transcript.
    struct Row: Identifiable {
        let id: String
        var header: String? = nil
        var transcript: Transcript? = nil
    }

    var body: some View {
        let list = NativeLibraryScope.list(app)
        let groups = Store.group(list, sort: sort)
        return VStack(alignment: .leading, spacing: 0) {
            if app.search.trimmingCharacters(in: .whitespaces).count >= 2 {
                ScrollView { PassageResults(query: app.search, list: list).padding(.horizontal, 32).padding(.bottom, 10) }
                    .frame(maxHeight: 220)
                Divider()
            }
            if groups.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if nav.libraryTable {
                table(groups.flatMap { g in [Row(id: "h:" + g.label, header: g.label)] + g.items.map { Row(id: $0.id.uuidString, transcript: $0) } })
                    .padding(.top, 6)
            } else {
                premiumList(groups)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: app.projectFilter) { _, _ in selection = []; nav.librarySelection = nil }
        .onAppear { KeptMedia.shared.refresh() }
    }

    // MARK: List

    /// The selected item: the one clicked, or the first while nothing is (the preview shows it either way).
    private func selected(_ flat: [Transcript]) -> UUID? {
        if let s = nav.librarySelection, flat.contains(where: { $0.id == s }) { return s }
        return flat.first?.id
    }

    private func premiumList(_ groups: [(label: String, items: [Transcript])]) -> some View {
        let flat = groups.flatMap(\.items)
        let current = selected(flat)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.label) { g in
                        PremiumDayHeader(title: g.label)
                        ForEach(g.items) { t in
                            PremiumRecordingItem(transcript: t, selected: t.id == current, onSelect: { select(t.id) })
                                .id(t.id)
                                .modifier(FirstItemsTarget(id: t.id, flat: flat))
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.top, 4).padding(.bottom, 110)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

// MARK: - Preview

/// The Library's preview in the inspector: the selected item (or the first) with its kind, day, length, and people,
/// its title, the summary card, its first line, and Play, Open Transcript, and ⋯.
struct PremiumLibraryPreview: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: NativeNav
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue

    var body: some View {
        let list = NativeLibraryScope.list(app)
        let chosen = nav.librarySelection.flatMap { id in list.first { $0.id == id } }
            ?? Store.group(list, sort: LibrarySort(rawValue: sortRaw) ?? .newest).first?.items.first
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
            Text(meta(t)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(2)
            Text(t.title).font(.system(size: 21, weight: .bold)).tracking(-0.3).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            if let s = t.summary, !s.isEmpty {
                PremiumSummaryCard(summary: s, byModel: t.summaryByModel, compact: true).padding(.top, 14)
            }
            if let line = t.visibleSegments(hideFiller: true).first?.text, !line.isEmpty {
                Text("“\(line)”").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            HStack(spacing: 8) {
                if t.audioFileName != nil && t.status == .ready {
                    Button { nav.play(t, app: app) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(PremiumProminentButtonStyle())
                        .help("Open and play (Space)")
                }
                Button("Open Transcript") { app.go(.transcript(t.id)) }
                    .buttonStyle(PremiumBorderedButtonStyle())
                    .help("Open the transcript (Return)")
                    .uiWindowTarget("lib-open")
                Menu { RowMenu(transcript: t) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                        .frame(width: 40, height: 30).background(PremiumInk.fill, in: Capsule()).contentShape(Capsule())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More for \(t.title)")
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(radius: 22)
    }

    /// "Podcast · Thu Oct 22 · 1:04:12 · Allie Beth Stuckey, Ginna Cross".
    private func meta(_ t: Transcript) -> String {
        var parts = [NativeLibraryView.kind(t), Formats.pattern("EEE MMM d").string(from: t.createdAt)]
        if t.duration > 0 { parts.append(NativeLibraryView.length(t.duration)) }
        let people = NativeLibraryView.people(t, projects: app.store.projectsByID)
        if !people.isEmpty { parts.append(people) }
        return parts.joined(separator: " · ")
    }
}
