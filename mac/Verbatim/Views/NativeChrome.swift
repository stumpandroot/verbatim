import SwiftUI
import AppKit

// brand: native file
//
// The main window's frame in Native (DESIGN.md §13.2; mockup "Verbose Native Redesign", sections 8 and 9): the split
// view, one toolbar for every screen, and one inspector, all built once at the window and kept while screens change. Screens used to bring their own toolbars
// and the transcript its own inspector, so every screen change removed and inserted toolbar items and a split-view
// column before the first frame (4 to 7 times Verbose style's time on CI). Now the toolbar's items keep their
// identities and only switch what they show, the inspector stays open across the Library and transcripts (the
// Library's preview, the transcript's summary and moments), and the screen swaps in place with no transition.

// MARK: - State

/// What the Native window's toolbar, inspector, and screens share: the transcript's tab and text size, the Library's
/// selection, and the inspector. Back and Forward are both looks' (NavTrail, App/NavTrail.swift). One per app.
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
    /// The Library as a table (the default) or as a list of rows with what was said (the toolbar's Table and List).
    @Published var libraryTable: Bool { didSet { UserDefaults.standard.set(libraryTable, forKey: Self.tableKey) } }
    static let tableKey = "native.libraryTable"
    /// The Library opens as a table until you pick List.
    static func storedTable(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: tableKey) as? Bool ?? true }
    /// An action running on the open transcript (its sheet), and why Summarize can't run here.
    @Published var runningAction: FlowAction?
    @Published var summaryUnavailable: String?
    /// Play on an item: open its transcript and start playing once the audio opens.
    private var autoplay: UUID?
    /// The last click on a list item, for double-click.
    private var lastClick: (id: UUID, at: Date)?

    init() {
        let d = UserDefaults.standard
        inspector = d.object(forKey: Self.inspectorKey) as? Bool ?? true
        libraryTable = Self.storedTable(d)
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

    /// Review shows each fix side by side; it lives in More, beside Original and Cleaned in the toolbar.
    func toggleReview() { mode = mode == .review ? .original : .review }
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
        LookSwitch.mark("native-window")
        return NavigationSplitView(columnVisibility: $columns) {
            NativeSidebar()
        } detail: {
            detail()
                .inspector(isPresented: inspectorShown) {
                    NativeInspector(nav: nav)
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
                }
        }
        .toolbar { NativeToolbar(nav: nav, screen: app.screen) }
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
}

/// The inspector's content for the screen: the Library's preview or the transcript's side column.
struct NativeInspector: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: NativeNav

    var body: some View {
        LookSwitch.mark("inspector")
        return ZStack {
            switch app.screen {
            case .library:
                PremiumLibraryPreview(nav: nav)
            case .transcript(let id):
                if let t = app.store.transcript(id) {
                    if t.showsAudioDetail { MacAudioInspector(transcript: t) } else { PremiumTranscriptInspector(transcript: t, nav: nav) }
                }
            default:
                Color.clear
            }
        }
    }
}

// MARK: - The toolbar

/// Every screen's toolbar items, declared once at the window, each in the system's glass group (macOS 26). Items keep
/// their identities as screens change, so AppKit reuses them: the leading item (Back and Forward on every screen, then
/// the Library's title and count), Record with its menu of kinds (everywhere but a transcript), the center (a
/// transcript's Original and Cleaned), the screen's own items, and the inspector button. Search is the window's one
/// system field at the trailing end (`.searchable(placement: .toolbar)`). The leading set never changes, so a screen
/// change doesn't reshuffle the bar (review M-10).
struct NativeToolbar: ToolbarContent {
    let nav: NativeNav
    var screen: Screen

    var body: some ToolbarContent {
        let _ = LookSwitch.mark("toolbar")
        ToolbarItem(id: "native.leading", placement: .navigation) { NativeLeadingItem(nav: nav, screen: screen) }
        if screen.transcriptID != nil {
            ToolbarItem(id: "native.center", placement: .principal) { NativeModePicker(nav: nav) }
        } else {
            ToolbarItem(id: "native.record", placement: .primaryAction) { NativeRecordButton() }
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

/// Back and Forward on every screen, then the Library's title and count on the Library.
private struct NativeLeadingItem: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: NativeNav
    /// Back and Forward, shared with Verbose style's back pill and View › Back and Forward.
    @ObservedObject private var trail = NavTrail.shared
    var screen: Screen

    var body: some View {
        HStack(spacing: 10) {
            // Two plain buttons (hosted as SwiftUI, so they keep their identity as the content changes).
            HStack(spacing: 0) {
                Button { trail.goBack(app) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.borderless)
                    .disabled(!trail.canGoBack)
                    .help("Back (⌘[)")
                    .accessibilityLabel("Back")
                    .uiWindowTarget("tb-back")
                Button { trail.goForward(app) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.borderless)
                    .disabled(!trail.canGoForward)
                    .help("Forward (⌘])")
                    .accessibilityLabel("Forward")
            }
            .font(.system(size: 14, weight: .medium))
            if screen == .library {
                let count = NativeLibraryScope.list(app).count
                VStack(alignment: .leading, spacing: 0) {
                    Text(NativeLibraryScope.title(app)).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(HomeCounts.countLabel(count, "recording", "recordings")).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 4)
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

/// Record in the toolbar (mockup section 8; decision 8): a click records a voice note, and the chevron, or a
/// right-click, opens the menu: Dictate, Live captions, and Import, then Record as's six choices (`RecordKindMenuItems`,
/// the same items as File › Record As). The dot is system red, flat: the only red Verbose draws, beside the word.
/// While you record it turns into Stop with the red stop square. The floating record disc retires in Native.
struct NativeRecordButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let busy = app.recorder.isRecording || app.capture.isCapturing
        HStack(spacing: 2) {
            if busy {
                Button {
                    if app.recorder.isRecording { app.stopRecording() } else { app.stopCapture() }
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(NativeInk.record).frame(width: 10, height: 10)
                        Text("Stop").font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Stop recording (⌥⇧.)")
                .accessibilityLabel("Stop")
                .accessibilityHint("Stops the recording and transcribes it.")
                .uiWindowTarget("tb-record")
            } else {
                Button { app.requestRecord() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(NativeInk.record).frame(width: 10, height: 10)
                        Text("Record").font(.system(size: 13, weight: .medium))
                    }
                    .padding(.leading, 6).padding(.trailing, 2).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Record a voice note (⌥⇧R)")
                .accessibilityLabel("Record")
                .accessibilityHint("Starts a voice note. The menu beside it has the other kinds.")
                .contextMenu { NativeRecordMenu() }
                .uiWindowTarget("tb-record")
                Menu { NativeRecordMenu() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Dictate, live captions, import, and the kinds of recording")
                .accessibilityLabel("Record as")
                .uiWindowTarget("tb-record-menu")
            }
        }
    }
}

/// The menu on Record (and its right-click): Dictate, Live captions, and Import, then the six ways to record. The
/// kinds are `RecordKindMenuItems`, so this menu, File › Record As, and the menu bar's list never drift apart.
struct NativeRecordMenu: View {
    @EnvironmentObject var app: AppState

    /// The items above the kinds, in order (the self-test reads them).
    static let extras = ["Dictate", "Live Captions", "Import…"]

    var body: some View {
        Button { app.goHome(); app.captureMode = "dictate" } label: { Label(Self.extras[0], systemImage: "text.bubble") }
        Button { app.toggleLiveCaptions() } label: { Label(Self.extras[1], systemImage: "captions.bubble") }
        Button { app.chooseFiles() } label: { Label(Self.extras[2], systemImage: "square.and.arrow.down") }
        Divider()
        Section("Record As") { RecordKindMenuItems() }
    }
}

/// A transcript's Original and Cleaned, as a segmented control in the toolbar. Review is in More; while it's on,
/// neither segment is chosen.
private struct NativeModePicker: View {
    @ObservedObject var nav: NativeNav

    var body: some View {
        Picker("View", selection: $nav.mode) {
            Text(TranscriptView.Mode.original.title).tag(TranscriptView.Mode.original)
            Text(TranscriptView.Mode.document.title).tag(TranscriptView.Mode.document)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("Original keeps every word as said; Cleaned is the tidied text")
    }
}

/// The screen's own items, in one slot: You on Home; the scope, Table and List, and More in the Library; Share and
/// More on a transcript.
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
            Button { app.go(.activity) } label: { Label("You", systemImage: "person.crop.circle") }
                .help("You: your week, cleanup, and where you dictate")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var libraryActions: some View {
        HStack(spacing: 8) {
            scopePicker
            Picker("View", selection: $nav.libraryTable) {
                Label("Table", systemImage: "tablecells").labelStyle(.iconOnly).tag(true)
                Label("List", systemImage: "list.bullet").labelStyle(.iconOnly).tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Show the Library as a table or as a list with what was said")
            .uiWindowTarget("tb-library-view")
            Menu {
                if !nav.libraryTable {
                    Picker("Sort By", selection: $sortRaw) {
                        ForEach(LibrarySort.allCases) { s in Text(s.title).tag(s.rawValue) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                }
                Button("Import Files…") { app.chooseFiles() }
                if let p = app.projectFilter { Button("Add from Library…") { app.addFromLibrary = p } }
                Button("New Project…") { app.newProjectFor = [] }
                Divider()
                Button("Export Library as Markdown…") { MarkdownBulkExport.run(MarkdownBulkExport.all(app), app: app) }
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .help("Sort, import, add from your library, start a project, or export")
        }
    }

    /// All recordings, a kind of source, or a kind of recording: one pop-up, as the mockup's "All recordings".
    private var scopePicker: some View {
        let options = NativeLibraryScope.options(app)
        let binding = Binding<NativeLibraryScope.Scope>(get: { NativeLibraryScope.current(app) }, set: { s in
            // Only a real change clears the selection: the picker can write back the scope it already shows as the
            // toolbar's items come back, which dropped the row Back came back to.
            guard s != NativeLibraryScope.current(app) else { return }
            nav.librarySelection = nil
            NativeLibraryScope.choose(s, app: app)
        })
        return Picker("Show", selection: binding) {
            ForEach(options, id: \.0) { o in Text(o.1).tag(o.0) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
        .help("Show every recording, one kind of source, or one kind of recording")
    }

    private func transcriptActions(_ t: Transcript) -> some View {
        HStack(spacing: 8) {
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
                .menuIndicator(.hidden)
                .disabled(t.status != .ready)
                .help("Copy, or export as text, Markdown, Word, subtitles, or JSON")
            Menu {
                Button("Mark This Moment") { nav.bookmark(t, app: app) }
                    .disabled(t.audioFileName == nil || t.status != .ready)
                Button("Continue Recording") { app.continueRecording(t.id) }
                    .disabled(t.status != .ready || t.audioFileName == nil || t.pendingAppend != nil || app.recorder.isRecording)
                Divider()
                Menu("Run an Action") { ActionsMenuItems { nav.runningAction = $0 } }
                    .disabled(t.status != .ready)
                Button(SummaryAction.title(t)) { nav.summarize(t, app: app) }
                    .disabled(t.status != .ready || t.summaryIsEdited || SummaryCenter.shared.isRunning(t.id))
                Toggle("Review Changes", isOn: Binding(get: { nav.mode == .review }, set: { on in if on != (nav.mode == .review) { nav.toggleReview() } }))
                Divider()
                Button(TurboRerun.title + "…") { app.turboAsk = t.id }
                    .disabled(t.status != .ready || TurboRerun.unavailableReason(t) != nil)
                if let other = TurboRerun.switchTitle(t) { Button(other) { app.switchTranscriptVersion(t.id) } }
                Divider()
                Menu("Text Size") {
                    Button("Larger Text") { nav.textSize = min(22, nav.textSize + 1) }
                    Button("Smaller Text") { nav.textSize = max(13, nav.textSize - 1) }
                    Button("Default Size") { nav.textSize = 16 }
                }
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .help("Mark a moment, record more, run an action, summarize, review the fixes, or change the text size")
                .uiWindowTarget("tb-more")
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
        let base = app.filtered
        let s = searching(app), filter = app.libraryFilter, kind = app.libraryKind
        // Asked for by the Library, its toolbar, and its preview on each render: worked out once per library change.
        return app.store.memo("native.list|\(key(app))|\(filter.raw)|\(kind?.rawValue ?? "-")") {
            let all = filter.apply(base, searching: s)
            return kind.map { k in all.filter { $0.kind == k } } ?? all
        }
    }

    /// What `filtered` depends on besides the library: the project and the search.
    private static func key(_ app: AppState) -> String {
        "\(app.projectFilter?.uuidString ?? "-")|\(app.search.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    /// "All recordings", then the sources and kinds the library has.
    static func options(_ app: AppState) -> [(Scope, String)] {
        let base = app.filtered
        let s = searching(app)
        // The sources and kinds present: one pass each per library change, not per render.
        let (sources, kindCounts) = app.store.memo("native.options|\(key(app))") { () -> ([LibrarySource], [RecordingKind: Int]) in
            let sources = LibraryFilter.all.sourceCounts(base, searching: s).filter { $0.0 != .all && $0.1 > 0 }.map(\.0)
            var kindCounts: [RecordingKind: Int] = [:]
            for t in LibraryFilter.all.apply(base, searching: s) { if let k = t.kind { kindCounts[k, default: 0] += 1 } }
            return (sources, kindCounts)
        }
        let kinds = RecordingKind.pickable.filter { (kindCounts[$0] ?? 0) > 0 || app.libraryKind == $0 }
        return [(.all, "All recordings")] + sources.map { (.source($0), $0.label) } + kinds.map { (.kind($0), $0.plural) }
    }

    static func title(_ app: AppState) -> String {
        if let p = app.projectFilter, let name = app.store.projects.first(where: { $0.id == p })?.name { return name }
        return app.libraryKind?.plural ?? "Library"
    }
}
