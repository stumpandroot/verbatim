import SwiftUI
import AppKit

// The main window's frame in the refined look (DESIGN.md §13; mockup "Verbose Refined Look", the sidebar and toolbar
// on every Mac board): the split view with the paper-gray sidebar (MacSidebar.swift),
// one system toolbar for every screen, and one inspector, all built once at the window and kept while screens change.
// Apple draws the chrome (the toolbar, its glass, the search field, the inspector); Verbose draws the content and tints
// the chrome with the accent. The toolbar's items keep their identities and only switch what they show, the inspector
// stays open across the Library and transcripts (the Library's preview, the transcript's moments and details), and
// the screen swaps in place with no transition.

// MARK: - State

/// What the window's toolbar, inspector, and screens share: the transcript's tab and text size, the Library's
/// selection, and the inspector. Back and Forward are NavTrail's (App/NavTrail.swift). One per app.
@MainActor
final class WindowNav: ObservableObject {
    static let shared = WindowNav()

    /// The inspector beside the Library and transcripts. Remembered on this Mac.
    @Published var inspector: Bool { didSet { UserDefaults.standard.set(inspector, forKey: Self.inspectorKey) } }
    static let inspectorKey = "native.inspector"
    /// The open transcript's tab, reading text size, and whether the text follows playback.
    @Published var mode: TranscriptView.Mode = .original
    @Published var textSize: CGFloat = WindowNav.textSizes.normal
    @Published var follow = true
    /// The Original tab's engine words and Select text, from More or the row above the lines.
    @Published var showEngine = false
    @Published var selecting = false
    /// The reading text's sizes: the serif's 18 pt (DESIGN.md §13), from 14 to 24 with ⌘+ and ⌘−.
    struct TextSizes {
        let min: CGFloat = 14, max: CGFloat = 24, normal: CGFloat = 18
        func clamp(_ v: CGFloat) -> CGFloat { Swift.min(max, Swift.max(min, v)) }
    }
    static let textSizes = TextSizes()
    /// The passage selected in the open transcript (a note added in the inspector links to it).
    @Published var selectedSegment: UUID?
    /// The Library item whose preview the inspector shows, and the row Back comes back to.
    @Published var librarySelection: UUID?
    /// The old Table and List choice for the Library. The refined Library is the table only (DESIGN.md §6.8), so
    /// the stored choice is removed at launch.
    static let retiredTableKey = "native.libraryTable"
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
        Self.retireTableChoice(d)
    }

    /// Removes the Table and List choice: every Library is the table now, whatever was picked.
    static func retireTableChoice(_ d: UserDefaults = .standard) {
        if d.object(forKey: retiredTableKey) != nil { d.removeObject(forKey: retiredTableKey) }
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

    /// Review shows each fix side by side: a tab once there are corrections, and More's Review Changes.
    func toggleReview() { mode = mode == .review ? .original : .review }

    /// A transcript opened: its own tab (the result first when Show the result first says so), and Original's
    /// words and lines as they are.
    func opened(_ t: Transcript, focus: Bool) {
        let start: TranscriptView.Mode = !focus && TemplateResultsSection.showsFirst(t) ? .result : .original
        if mode != start { mode = start }
        if showEngine { showEngine = false }
        if selecting { selecting = false }
    }
}

extension Screen {
    var transcriptID: UUID? { if case .transcript(let id) = self { return id }; return nil }
    /// Screens with the inspector: the Library (its preview) and transcripts (moments, speakers, export, details).
    var hasInspector: Bool { self == .library || transcriptID != nil }
}

// MARK: - The window

/// The window: the sidebar, the screen, the inspector, and the toolbar, built once.
struct MacWindow<Detail: View>: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: WindowNav
    @Binding var columns: NavigationSplitViewVisibility
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        NavMarks.mark("window")
        return NavigationSplitView(columnVisibility: $columns) {
            MacSidebar()
        } detail: {
            detail()
                .inspector(isPresented: inspectorShown) {
                    MacInspector(nav: nav)
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
                }
        }
        .toolbar { MacToolbar(nav: nav, screen: app.screen) }
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
        Binding(get: { nav.inspector && app.screen.hasInspector }, set: { open in
            if app.screen.hasInspector { nav.inspector = open }
        })
    }
}

/// The inspector's content for the screen: the Library's preview or the transcript's side column, on paper.
struct MacInspector: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: WindowNav

    var body: some View {
        NavMarks.mark("inspector")
        return ZStack {
            Refined.paper.ignoresSafeArea()
            switch app.screen {
            case .library:
                LibraryPreview(nav: nav)
            case .transcript(let id):
                if let t = app.store.transcript(id) {
                    if t.showsAudioDetail { MacAudioInspector(transcript: t) } else { TranscriptSide(transcript: t, nav: nav) }
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
/// Record with its menu of kinds everywhere but a transcript), the center (a transcript's tabs), the screen's own items,
/// and the inspector button. Search is the window's one system field at the trailing end
/// (`.searchable(placement: .toolbar)`, "Search or ask"). The leading set never changes, so a screen change doesn't
/// reshuffle the bar (review M-10).
///
/// Record sits in the leading item, beside Back and Forward, so it never goes into the toolbar's overflow: a toolbar
/// short of room moves its trailing items there first, and in build 239's 1000 pt window the inspector and the search
/// field pushed a trailing Record out of sight.
struct MacToolbar: ToolbarContent {
    let nav: WindowNav
    var screen: Screen

    var body: some ToolbarContent {
        let _ = NavMarks.mark("toolbar")
        ToolbarItem(id: "window.leading", placement: .navigation) { ToolbarLeadingItem(nav: nav, screen: screen) }
        if let id = screen.transcriptID {
            ToolbarItem(id: "window.center", placement: .principal) { ToolbarModePicker(nav: nav, id: id) }
        }
        ToolbarItem(id: "window.actions", placement: .primaryAction) { ToolbarActionsItem(nav: nav, screen: screen) }
        if screen.hasInspector {
            ToolbarItem(id: "window.inspector", placement: .primaryAction) { ToolbarInspectorButton(nav: nav) }
        }
    }
}

private struct ToolbarInspectorButton: View {
    @ObservedObject var nav: WindowNav
    var body: some View {
        Button { nav.inspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }   // brand: system surface
            .help(nav.inspector ? "Hide the inspector" : "Show the inspector")
    }
}

/// Back and Forward on every screen, then Record everywhere but a transcript. Every screen draws its own serif title
/// on the page (DESIGN.md §13).
private struct ToolbarLeadingItem: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: WindowNav
    /// Back and Forward, shared with View › Back and Forward and the mouse's side buttons.
    @ObservedObject private var trail = NavTrail.shared
    var screen: Screen

    var body: some View {
        // Two plain buttons (hosted as SwiftUI, so they keep their identity as the content changes).
        HStack(spacing: 0) {
            Button { trail.goBack(app) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .disabled(!trail.canGoBack)
                .help("Back to \(trail.canGoBack ? trail.backName(app) : "the last screen") (⌘[)")
                .accessibilityLabel("Back")
                .uiWindowTarget("tb-back")
            Button { trail.goForward(app) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .disabled(!trail.canGoForward)
                .help("Forward (⌘])")
                .accessibilityLabel("Forward")
            if screen.transcriptID == nil {
                ToolbarRecordButton().padding(.leading, 6)
            }
        }
        .font(.system(size: 14, weight: .medium))
    }
}

/// Record in the toolbar (mockup: the Record capsule beside the search field): a click records a voice note, and the
/// chevron, or a right-click, opens the menu: Dictate, Live captions, and Import, then Record as's choices
/// (`RecordKindMenuItems`, the same items as File › Record As). The dot is the system red (`recordRed`): the record
/// disc's red, beside the word. While you record it turns into the live timer capsule (`ToolbarRecordingStatus`): the
/// red dot, the time, and Stop.
struct ToolbarRecordButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let busy = app.recorder.isRecording || app.capture.isCapturing
        HStack(spacing: 2) {
            if busy {
                ToolbarRecordingStatus(onCard: false)
                    .uiWindowTarget("tb-record")
            } else {
                Button { app.requestRecord() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Refined.recordRed).frame(width: 10, height: 10)
                        Text("Record").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.leading, 6).padding(.trailing, 2).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Record a voice note (⌥⇧R)")
                .accessibilityLabel("Record")
                .accessibilityHint("Starts a voice note. The menu beside it has the other kinds.")
                .contextMenu { ToolbarRecordMenu() }
                .uiWindowTarget("tb-record")
                Menu { ToolbarRecordMenu() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Refined.dim)
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

/// The menu on Record (and its right-click): Dictate, Live captions, and Import, then the ways to record. The kinds
/// are `RecordKindMenuItems`, so this menu, File › Record As, and the menu bar's list never drift apart.
struct ToolbarRecordMenu: View {
    @EnvironmentObject var app: AppState

    /// The items above the kinds, in order (the self-test reads them).
    static let extras = ["Dictate", "Live Captions", "Import…"]

    var body: some View {
        Button { app.goHome(); app.captureMode = "dictate" } label: { Label(Self.extras[0], systemImage: "text.bubble") }   // brand: system surface
        Button { app.toggleLiveCaptions() } label: { Label(Self.extras[1], systemImage: "captions.bubble") }   // brand: system surface
        Button { app.chooseFiles() } label: { Label(Self.extras[2], systemImage: "square.and.arrow.down") }   // brand: system surface
        Divider()
        Section("Record As") { RecordKindMenuItems() }
    }
}

/// A transcript's tabs as a segmented control in the toolbar: Original, Cleaned, and Summary, then Review once there
/// are corrections and a template's result (`TranscriptView.tabs`). An Audio only recording has none.
private struct ToolbarModePicker: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: WindowNav
    var id: UUID

    var body: some View {
        if let t = app.store.transcript(id), !t.showsAudioDetail, t.status == .ready {
            Picker("View", selection: $nav.mode) {
                ForEach(TranscriptView.tabs(t, current: nav.mode, templates: app.store.allTemplates), id: \.0) { m, title in Text(title).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Original keeps every word as said; Cleaned is the tidied text; Summary has the overview")
        }
    }
}

/// The screen's own items, in one slot: You on Home; More in the Library; Share and More on a transcript.
private struct ToolbarActionsItem: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var nav: WindowNav
    var screen: Screen

    var body: some View {
        switch screen {
        case .transcript(let id):
            if let t = app.store.transcript(id) { transcriptActions(t) }
        case .library:
            libraryActions
        case .home:
            Button { app.go(.activity) } label: { Label("You", systemImage: "person.crop.circle") }   // brand: system surface
                .help("You: your week, cleanup, and where you dictate")
        default:
            EmptyView()
        }
    }

    /// The Library's More: Import, Add from Library (in a project), New project, and Export. Its filters and sort are
    /// on the page (the chips), as in the refined mockup.
    private var libraryActions: some View {
        Menu {
            Button("Import Files…") { app.chooseFiles() }
            if let p = app.projectFilter { Button("Add from Library…") { app.addFromLibrary = p } }
            Button("New Project…") { app.newProjectFor = [] }
            Divider()
            Button("Export Library as Markdown…") { MarkdownBulkExport.run(MarkdownBulkExport.all(app), app: app) }
        } label: { Label("More", systemImage: "ellipsis.circle") }
            .menuIndicator(.hidden)
            .help("Import, add from your library, start a project, or export")
    }

    private func transcriptActions(_ t: Transcript) -> some View {
        HStack(spacing: 8) {
            Menu { TranscriptShareItems(transcript: t, nav: nav) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .menuIndicator(.hidden)
                .disabled(t.status != .ready)
                .help("Copy, or export as text, Markdown, Word, subtitles, or JSON")
                .uiWindowTarget("tb-share")
            Menu { TranscriptMoreItems(transcript: t, nav: nav) } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .help("Mark a moment, record more, run a template or an action, summarize, review the fixes, or change the text size")
                .uiWindowTarget("tb-more")
        }
    }
}
