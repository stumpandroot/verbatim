import SwiftUI
import AppKit

// brand: native file
//
// The main window's sidebar in the Native look (mockup "Verbose Native Redesign", section 8): the standard sidebar
// (`List` with the sidebar style, which the system floats on its glass panel), SF Symbols in the system accent color
// (System Settings › Appearance, blue by default), counts as badges, and the system's gray selection. Projects move here from the Library, with their counts and New Project. Settings leaves the
// sidebar for the app menu (⌘,), where Mac apps keep it. The order, hiding, and Customize sidebar work as in Verbose
// style (SidebarLayout); transcripts dropped on Library or a project move there.

struct NativeSidebar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var layout = SidebarLayout.shared
    @ObservedObject private var recordAs = RecordAsStore.shared
    @State private var customizing = false
    @Environment(\.limitMotion) private var limitMotion

    enum Item: Hashable { case main(SidebarItemID), byDay(RecordingKind), templates, ask, project(UUID), trash }

    var body: some View {
        LookSwitch.mark("sidebar")
        // Every count in one pass over the library, once per library change (Store+Memo.swift).
        let counts = app.store.counts
        let library = counts.library, trash = counts.trash, perProject = counts.perProject
        return List(selection: selection) {
            Section {
                ForEach(shownItems) { id in
                    row(id, library: library)
                        .contextMenu {
                            Button("Hide from Sidebar") { withAnimation(limitMotion ? nil : .smooth(duration: 0.3)) { layout.setHidden(id, true) } }
                                .disabled(!layout.canHide(id))
                            Button("Customize Sidebar…") { customizing = true }
                        }
                        .accessibilityAction(named: "Move up") { layout.nudge(id, by: -1) }
                        .accessibilityAction(named: "Move down") { layout.nudge(id, by: 1) }
                        .tag(Item.main(id))
                }
                .onMove { from, to in move(from: from, to: to) }
            }
            // Library › By day: one page a day for Thoughts and Journal (Views/ByDayView.swift).
            Section("By day") {
                Label { Text("Thoughts") } icon: { ThoughtGlyph(color: NativeInk.accent, lineWidth: 1.4).frame(width: 16, height: 16) }
                    .badge(app.store.todaysThoughts().count)
                    .tag(Item.byDay(.idea)).uiTarget("side-thoughts")
                // Journal shows once Journal entry is on in Record As or you have an entry (consolidation, item 16).
                if recordAs.rows.showsJournal(hasEntries: app.store.hasJournalEntries) || app.screen == .byDay(.journal) {
                    Label { Text("Journal") } icon: { Image(systemName: RecordingKind.journal.nativeSymbol).foregroundStyle(NativeInk.accent) }
                        .badge(app.store.journalThisWeek())
                        .tag(Item.byDay(.journal)).uiTarget("side-journal")
                }
            }
            // Make: Templates, and Ask (questions about your library, and recipes).
            Section("Make") {
                Label { Text("Templates") } icon: { Image(systemName: "doc.text").foregroundStyle(NativeInk.accent) }
                    .badge(app.store.allTemplates.count)
                    .tag(Item.templates).uiTarget("side-templates")
                Label { Text("Ask") } icon: { Image(systemName: "questionmark.bubble").foregroundStyle(NativeInk.accent) }
                    .badge(app.store.recipes.count)
                    .tag(Item.ask).uiTarget("side-ask")
            }
            Section("Projects") {
                ForEach(app.store.projects) { p in
                    NativeDropRow(onDrop: { app.move($0, to: p.id) }) {
                        Label { Text(p.name) } icon: { Image(systemName: "folder").foregroundStyle(NativeInk.accent) }
                    }
                    .badge(perProject[p.id] ?? 0)
                    .contextMenu {
                        Button("Delete Project", role: .destructive) { deleteProject(p) }
                    }
                    .tag(Item.project(p.id))
                }
                Button { app.newProjectFor = [] } label: {
                    Label { Text("New Project") } icon: { Image(systemName: "plus").foregroundStyle(.secondary) }
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Group transcripts by client or job, then drag transcripts onto the project.")
            }
            if trash > 0 || app.screen == .trash {
                Section {
                    Label { Text("Recently Deleted") } icon: { Image(systemName: "trash").foregroundStyle(NativeInk.accent) }
                        .badge(trash).tag(Item.trash)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Where the library lives: one quiet line, as Notes and Mail show their accounts' state.
            Label(Cloud.enabled ? "Syncing with iCloud" : "On this Mac", systemImage: Cloud.enabled ? "icloud" : "internaldrive")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .help(Cloud.enabled
                      ? "Transcripts, notes, projects, and the Dictionary sync with your iPhone through your iCloud Drive."
                      : "iCloud is off for Verbose, so everything stays in ~/Library/Application Support/Verbatim.")
        }
        .sheet(isPresented: $customizing) { CustomizeSidebarSheet() }
    }

    /// One main item: its symbol, title, badge, and (Library) drop target.
    @ViewBuilder private func row(_ id: SidebarItemID, library: Int) -> some View {
        let label = Label { Text(id.title) } icon: {
            Image(systemName: NativeSymbols.sidebar(id.rawValue)).foregroundStyle(NativeInk.accent)
        }
        switch id {
        case .library:
            NativeDropRow(onDrop: { app.move($0, to: nil) }) { label }.badge(library).uiTarget("side-library").uiWindowTarget("side-library")
        case .queue:
            label.badge(app.queueBadgeCount)
                .anchorPreference(key: QueueItemAnchor.self, value: .bounds) { $0 }
                .uiTarget("side-queue")
        case .dictionary:
            label.badge(app.store.dictionary.count).uiTarget("side-dict")
        case .home: label.uiTarget("side-home").uiWindowTarget("side-home")
        case .dictations: label.uiTarget("side-dictations")
        case .you: label.uiTarget("side-you")
        }
    }

    // MARK: Selection

    /// The row for the current screen. A transcript selects nothing, so clicking Library (or its project) goes back.
    private var current: Item? {
        switch app.screen {
        case .home: return .main(.home)
        case .library: return app.projectFilter.map { .project($0) } ?? .main(.library)
        case .queue: return .main(.queue)
        case .dictations: return .main(.dictations)
        case .activity: return .main(.you)
        case .dictionary: return .main(.dictionary)
        case .trash: return .trash
        case .byDay(let k): return .byDay(k)
        case .templates: return .templates
        case .ask: return .ask
        case .transcript: return nil
        }
    }

    private var selection: Binding<Item?> {
        Binding(get: { current }, set: { item in if let item { open(item) } })
    }

    private func open(_ item: Item) {
        switch item {
        case .main(let id):
            switch id {
            case .home: app.go(.home)
            case .library: app.projectFilter = nil; app.go(.library)
            case .queue: app.go(.queue)
            case .dictations: app.go(.dictations)
            case .you: app.go(.activity)
            case .dictionary: app.go(.dictionary)
            }
        case .byDay(let k):
            app.go(.byDay(k))
        case .templates:
            app.go(.templates)
        case .ask:
            app.go(.ask)
        case .project(let p):
            app.projectFilter = p
            app.go(.library)
        case .trash:
            app.go(.trash)
        }
    }

    // MARK: Order and projects

    /// The main rows on screen: the visible ones, with Queue only while something works.
    private var shownItems: [SidebarItemID] { layout.visible.filter { $0 != .queue || app.queueShowsInSidebar } }

    /// A drag among the rows on screen, applied to the saved order (hidden rows keep their places).
    private func move(from: IndexSet, to: Int) {
        let visible = shownItems
        guard let i = from.first, visible.indices.contains(i) else { return }
        let id = visible[i]
        let target = to >= visible.count ? visible.last : visible[to > i ? to - 1 : to]
        guard let target, target != id else { return }
        withAnimation(limitMotion ? nil : .smooth(duration: 0.3)) { layout.move(id, to: target) }
    }

    private func deleteProject(_ p: Project) {
        app.store.projects.removeAll { $0.id == p.id }
        if app.projectFilter == p.id { app.projectFilter = nil }
        if FlowSettings.shared.activeProject == p.id { FlowSettings.shared.activeProject = nil }
        // Its words would never apply again; they go back to working everywhere.
        for i in app.store.dictionary.indices where app.store.dictionary[i].projectId == p.id { app.store.dictionary[i].projectId = nil }
    }
}

/// A sidebar row that takes transcripts dragged from Home, the Library, or the Queue (an outline while one is over it).
struct NativeDropRow<Content: View>: View {
    var onDrop: ([UUID]) -> Void
    @ViewBuilder var content: () -> Content
    @State private var dropping = false

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(NativeInk.accent, lineWidth: 2).padding(-3)
                }
            }
            .modifier(TranscriptDropTarget(enabled: true, dropping: $dropping, perform: onDrop))
    }
}
