import SwiftUI
import AppKit

// brand: native file
//
// The main window's frame in Native (DESIGN.md §13.1 and §13.2): the split view, one toolbar for every screen, and
// one inspector, all built once at the window and kept while screens change. Screens used to bring their own toolbars
// and the transcript its own inspector, so every screen change removed and inserted toolbar items and a split-view
// column before the first frame (4 to 7 times Verbose style's time on CI). Now the toolbar's items keep their
// identities and only switch what they show, the inspector stays open across the Library and transcripts (the
// Library's preview, the transcript's summary and moments), and the screen swaps in place with no transition.

// MARK: - State

/// What the Native window's toolbar, inspector, and screens share: the transcript's tab and text size, the Library's
/// selection, the inspector, and back and forward. One per app (the main window).
@MainActor
final class NativeNav: ObservableObject {
    static let shared = NativeNav()

    /// The inspector beside the Library and transcripts. Remembered on this Mac.
    @Published var inspector: Bool { didSet { UserDefaults.standard.set(inspector, forKey: Self.inspectorKey) } }
    static let inspectorKey = "native.inspector"
    /// The open transcript's tab, text size, and whether the text follows playback.
    @Published var mode: TranscriptView.Mode = .original
    @Published var textSize: CGFloat = 16
    @Published var follow = true
    /// The passage selected in the open transcript (a note added in the inspector links to it).
    @Published var selectedSegment: UUID?
    /// The Library item whose preview the inspector shows.
    @Published var librarySelection: UUID?
    /// The Library as the first Native look's table (View as Table) instead of the list.
    @Published var libraryTable: Bool { didSet { UserDefaults.standard.set(libraryTable, forKey: Self.tableKey) } }
    static let tableKey = "native.libraryTable"
    /// An action running on the open transcript (its sheet), and why Summarize can't run here.
    @Published var runningAction: FlowAction?
    @Published var summaryUnavailable: String?
    /// The detail's width in 20 pt steps, for the scope bar (segmented when it fits).
    @Published var detailWidth: CGFloat = 800
    @Published private(set) var history = NavHistory<Screen>()

    /// Play on an item: open its transcript and start playing once the audio opens.
    private var autoplay: UUID?
    /// The last click on a list item, for double-click.
    private var lastClick: (id: UUID, at: Date)?

    init() {
        let d = UserDefaults.standard
        inspector = d.object(forKey: Self.inspectorKey) as? Bool ?? true
        libraryTable = d.bool(forKey: Self.tableKey)
    }

    // Navigation

    func visited(_ s: Screen) { history.visit(s) }

    func goBack(_ app: AppState) {
        dropDeleted(app)
        if let s = history.goBack() { app.go(s) }
    }

    func goForward(_ app: AppState) {
        dropDeleted(app)
        if let s = history.goForward() { app.go(s) }
    }

    private func dropDeleted(_ app: AppState) {
        history.removeAll { s in
            if case .transcript(let id) = s { return app.store.transcript(id).map { $0.deletedAt != nil } ?? true }
            return false
        }
    }

    // The Library list

    /// True when this click on `id` is the second of a double-click (the system's double-click time).
    func isDoubleClick(on id: UUID) -> Bool {
        let now = Date()
        defer { lastClick = (id, now) }
        guard let last = lastClick, last.id == id else { return false }
        if now.timeIntervalSince(last.at) <= NSEvent.doubleClickInterval { lastClick = nil; return true }
        return false
    }

    /// Opens the transcript and plays it.
    func play(_ t: Transcript, app: AppState) {
        if app.screen == .transcript(t.id), let u = app.store.audioURL(for: t) {
            app.player.loadAsync(u, autoplay: true)
            return
        }
        autoplay = t.id
        app.go(.transcript(t.id))
    }

    /// True once, for the transcript that Play opened.
    func takeAutoplay(_ id: UUID) -> Bool {
        guard autoplay == id else { return false }
        autoplay = nil
        return true
    }

    // The open transcript

    func summarize(_ t: Transcript, app: AppState) {
        if let why = SummaryAction.unavailableReason { summaryUnavailable = why; return }
        SummaryCenter.shared.summarize(t.id, store: app.store, replacingEdits: false)
    }

    func bookmark(_ t: Transcript, app: AppState) {
        let at = app.player.time
        let seg = t.segments.first(where: { at >= $0.start && at < $0.end })
        app.addNote(transcript: t.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
    }

    var copyVersion: Exporter.CopyVersion { mode == .document ? .cleaned : .original }
}

extension Screen {
    var transcriptID: UUID? { if case .transcript(let id) = self { return id }; return nil }
    /// Screens with the inspector: the Library (its preview) and transcripts (summary, moments, speakers).
    var hasNativeInspector: Bool { self == .library || transcriptID != nil }
}

// MARK: - The window

/// The Native window: the standard sidebar, the screen, the inspector, and the toolbar, built once.
struct NativeWindow<Detail: View>: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: NativeNav
    @Binding var columns: NavigationSplitViewVisibility
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            NativeSidebar()
        } detail: {
            detail()
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { setWidth(g.size.width) }
                        .onChange(of: g.size.width) { _, w in setWidth(w) }
                })
                .inspector(isPresented: inspectorShown) {
                    NativeInspector(nav: nav)
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
                }
        }
        .toolbar { NativeToolbar(nav: nav, screen: app.screen) }
        .onChange(of: app.nav) { _, n in nav.visited(n.screen) }
        .onAppear { nav.visited(app.screen) }
        .sheet(item: $nav.runningAction) { a in
            if let id = app.screen.transcriptID, let t = app.store.transcript(id) {
                TranscriptActionSheet(action: a, transcript: t).environmentObject(app)
            }
        }
        .alert("Summaries need Apple Intelligence", isPresented: Binding(get: { nav.summaryUnavailable != nil }, set: { if !$0 { nav.summaryUnavailable = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(nav.summaryUnavailable ?? "") }
    }

    /// Open on the Library and transcripts while the person wants it; the binding survives every screen change.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { nav.inspector && app.screen.hasNativeInspector }, set: { open in
            if app.screen.hasNativeInspector { nav.inspector = open }
        })
    }

    private func setWidth(_ w: CGFloat) {
        let stepped = (w / 20).rounded() * 20
        if nav.detailWidth != stepped { nav.detailWidth = stepped }
    }
}

/// The inspector's content for the screen: the Library's preview or the transcript's side column.
struct NativeInspector: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: NativeNav

    var body: some View {
        ZStack {
            PremiumInk.window.ignoresSafeArea()
            switch app.screen {
            case .library:
                PremiumLibraryPreview(nav: nav)
            case .transcript(let id):
                if let t = app.store.transcript(id) { PremiumTranscriptInspector(transcript: t, nav: nav) }
            default:
                Color.clear
            }
        }
    }
}

// MARK: - The toolbar

/// Every screen's toolbar items, declared once at the window. Items keep their identities as screens change, so
/// AppKit reuses them: the leading item (the Library's title, a transcript's back and forward), the center (the
/// Library's scope, a transcript's tabs), the actions, and the inspector button. Search is the window's own field.
struct NativeToolbar: ToolbarContent {
    let nav: NativeNav
    var screen: Screen

    var body: some ToolbarContent {
        if screen.hasNativeInspector {
            ToolbarItem(id: "native.leading", placement: .navigation) { NativeLeadingItem(nav: nav, screen: screen) }
            ToolbarItem(id: "native.center", placement: .principal) { NativeCenterItem(nav: nav, screen: screen) }
        }
        ToolbarItem(id: "native.actions", placement: .primaryAction) { NativeActionsItem(nav: nav, screen: screen) }
        if screen.hasNativeInspector {
            ToolbarItem(id: "native.inspector", placement: .primaryAction) { NativeInspectorButton(nav: nav) }
        }
    }
}

private struct NativeInspectorButton: View {
    @ObservedObject var nav: NativeNav
    var body: some View {
        Button { nav.inspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            .help(nav.inspector ? "Hide the inspector" : "Show the inspector")
    }
}

/// The Library's title and count, or a transcript's Back and Forward.
private struct NativeLeadingItem: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: NativeNav
    var screen: Screen

    var body: some View {
        if screen.transcriptID != nil {
            // Two plain buttons in one item (hosted as SwiftUI, so they keep their identity as the content changes).
            HStack(spacing: 0) {
                Button { nav.goBack(app) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.borderless)
                    .disabled(!nav.history.canGoBack)
                    .help("Back")
                    .accessibilityLabel("Back")
                    .uiWindowTarget("tb-back")
                Button { nav.goForward(app) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.borderless)
                    .disabled(!nav.history.canGoForward)
                    .help("Forward")
                    .accessibilityLabel("Forward")
            }
            .font(.system(size: 14, weight: .medium))
        } else {
            let count = NativeLibraryScope.list(app).count
            VStack(alignment: .leading, spacing: 0) {
                Text(NativeLibraryScope.title(app)).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(count == 1 ? "1 transcript" : "\(count.formatted()) transcripts").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A transcript's Original, Cleaned, and Review; or the Library's scope (segmented when it fits, else a menu).
private struct NativeCenterItem: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: NativeNav
    var screen: Screen

    var body: some View {
        if screen.transcriptID != nil {
            Picker("View", selection: $nav.mode) {
                ForEach(TranscriptView.visibleModes, id: \.self) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Original keeps every word as said; Cleaned is the tidied text; Review shows each fix")
        } else {
            let options = NativeLibraryScope.options(app)
            let binding = Binding<NativeLibraryScope.Scope>(get: { NativeLibraryScope.current(app) }, set: { s in
                nav.librarySelection = nil
                NativeLibraryScope.choose(s, app: app)
            })
            // One picker, styled from the room the detail has (it used to build both and measure them).
            let segmented = ScopeBarStyle.segmented(options.map(\.1), available: Double(nav.detailWidth) - 520)
            Picker("Show", selection: binding) {
                ForEach(options, id: \.0) { o in Text(o.1).tag(o.0) }
            }
            .labelsHidden().fixedSize()
            .modifier(ScopePickerStyle(segmented: segmented))
            .help("Show everything, one kind of source, or one kind of recording")
        }
    }
}

private struct ScopePickerStyle: ViewModifier {
    var segmented: Bool
    func body(content: Content) -> some View {
        if segmented { content.pickerStyle(.segmented) } else { content.pickerStyle(.menu) }
    }
}

/// The screen's actions: Import and You on Home; Sort and More in the Library; Bookmark, Actions, Share, and Text Size
/// on a transcript; Import elsewhere.
private struct NativeActionsItem: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: NativeNav
    var screen: Screen
    @AppStorage(LibrarySort.key) private var sortRaw = LibrarySort.newest.rawValue

    var body: some View {
        switch screen {
        case .transcript(let id):
            if let t = app.store.transcript(id) { transcriptActions(t) }
        case .library:
            libraryActions
        case .home:
            HStack(spacing: 8) {
                importButton
                Button { app.go(.activity) } label: { Label("You", systemImage: "person.crop.circle") }
                    .help("You: your week, cleanup, and where you dictate")
            }
        default:
            importButton
        }
    }

    private var importButton: some View {
        Button { app.chooseFiles() } label: { Label("Import", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon) }
            .help("Import audio or video files (⌘O)")
    }

    @ViewBuilder private var libraryActions: some View {
        ControlGroup {
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases) { s in Text(s.title).tag(s.rawValue) }
                }
                .pickerStyle(.inline)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                .help("Sort the Library: newest, oldest, longest, or by title")
            Menu {
                Button("Import Files…") { app.chooseFiles() }
                if let p = app.projectFilter { Button("Add from Library…") { app.addFromLibrary = p } }
                Button("New Project…") { app.newProjectFor = [] }
                Divider()
                Toggle("View as Table", isOn: $nav.libraryTable)
                Divider()
                Button("Export Library as Markdown…") { MarkdownBulkExport.run(MarkdownBulkExport.all(app), app: app) }
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .help("Import, add from your library, start a project, or view as a table")
        }
    }

    private func transcriptActions(_ t: Transcript) -> some View {
        ControlGroup {
            Button { nav.bookmark(t, app: app) } label: { Label("Bookmark", systemImage: "bookmark") }
                .disabled(t.audioFileName == nil || t.status != .ready)
                .help("Bookmark this moment (B)")
            Menu {
                Button("Continue Recording") { app.continueRecording(t.id) }
                    .disabled(t.status != .ready || t.audioFileName == nil || t.pendingAppend != nil || app.recorder.isRecording)
                Divider()
                ActionsMenuItems { nav.runningAction = $0 }
                Divider()
                Button(SummaryAction.title(t)) { nav.summarize(t, app: app) }
                    .disabled(t.summaryIsEdited || SummaryCenter.shared.isRunning(t.id))
            } label: { Label("Actions", systemImage: "sparkles") }
                .disabled(t.status != .ready)
                .help("Run a saved action: decisions and next steps, a brief, an email; summarize; or record more")
            Menu {
                Button("Copy (⇧⌘C)") { ExportMenu.copy(t, nav.copyVersion, app: app) }
                Button("Copy with Timestamps") { ExportMenu.copy(t, nav.copyVersion, timestamps: true, app: app) }
                Button(nav.copyVersion == .cleaned ? "Copy the Original" : "Copy the Cleaned Text") { ExportMenu.copy(t, nav.copyVersion.other, app: app) }
                Button("Copy Engine Words") { ExportMenu.copy(t, .engine, app: app) }
                    .disabled(!t.hasEngineWords)
                Button("Copy for AI") { CopyForAI.copy(t, app: app) }
                Divider()
                Button("Export…") { app.exportRequest = ExportRequest(ids: [t.id]) }
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(t.status != .ready)
                .help("Copy, or export as text, Markdown, Word, subtitles, or JSON")
            Menu {
                Button("Larger Text") { nav.textSize = min(22, nav.textSize + 1) }
                Button("Smaller Text") { nav.textSize = max(13, nav.textSize - 1) }
                Button("Default Size") { nav.textSize = 16 }
            } label: { Label("Text Size", systemImage: "textformat.size") }
                .help("Text size (⌘+ and ⌘−)")
        }
    }
}

// MARK: - The Library's scope

/// The Library's scope (all, a type of source, or a kind) and its title and count, shared by the toolbar and the list.
@MainActor
enum NativeLibraryScope {
    enum Scope: Hashable { case all, source(LibrarySource), kind(RecordingKind) }

    static func current(_ app: AppState) -> Scope {
        if let k = app.libraryKind { return .kind(k) }
        if app.libraryFilter.source != .all { return .source(app.libraryFilter.source) }
        return .all
    }

    static func choose(_ s: Scope, app: AppState) {
        switch s {
        case .all: app.libraryKind = nil; app.libraryFilter = .all
        case .source(let src): app.libraryKind = nil; app.libraryFilter = LibraryFilter(source: src)
        case .kind(let k): app.libraryFilter = .all; app.libraryKind = k
        }
    }

    static func searching(_ app: AppState) -> Bool { !app.search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// What the Library shows: the filtered library, then the source filter and the kind.
    static func list(_ app: AppState) -> [Transcript] {
        let all = app.libraryFilter.apply(app.filtered, searching: searching(app))
        return app.libraryKind.map { k in all.filter { $0.kind == k } } ?? all
    }

    /// "All", then the sources and kinds the library has.
    static func options(_ app: AppState) -> [(Scope, String)] {
        let base = app.filtered
        let s = searching(app)
        let sources = LibraryFilter.all.sourceCounts(base, searching: s).filter { $0.0 != .all && $0.1 > 0 }.map(\.0)
        var kindCounts: [RecordingKind: Int] = [:]
        for t in LibraryFilter.all.apply(base, searching: s) { if let k = t.kind { kindCounts[k, default: 0] += 1 } }
        let kinds = RecordingKind.pickable.filter { (kindCounts[$0] ?? 0) > 0 || app.libraryKind == $0 }
        return [(.all, "All")] + sources.map { (.source($0), $0.label) } + kinds.map { (.kind($0), $0.plural) }
    }

    static func title(_ app: AppState) -> String {
        if let p = app.projectFilter, let name = app.store.projects.first(where: { $0.id == p })?.name { return name }
        return app.libraryKind?.plural ?? "Library"
    }
}
