import SwiftUI
import AppKit

// The main window's sidebar in the refined look (DESIGN.md §13; mockup "Verbose Refined Look", the sidebar on every
// Mac board), one design in both look settings: the paper-gray `side` column of the window's split view, SF Pro rows
// with each place's fine-line glyph in the accent, counts in `mute`, sentence-case group headers (By day, Make,
// Projects), and the selected row on the persimmon tint in semibold. Settings sits at the foot. The order, hiding,
// and Customize sidebar work as before (SidebarLayout.swift); Queue shows only while something works; transcripts
// dropped on Library or a project move there. With the sidebar focused, the up and down arrows move between places.

/// A place the sidebar opens, in the order the rows show (the arrow keys walk it).
enum SidebarPlace: Hashable {
    case main(SidebarItemID), byDay(RecordingKind), templates, ask, project(UUID), trash
}

struct MacSidebar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var layout = SidebarLayout.shared
    @ObservedObject private var recordAs = RecordAsStore.shared
    @State private var customizing = false
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        LookSwitch.mark("sidebar")
        // Every count in one pass over the library, once per library change (Store+Memo.swift).
        let counts = app.store.counts
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shownItems) { id in
                        mainItem(id, library: counts.library)
                            .onDrag { layout.itemProvider(id) }
                            .onDrop(of: [SidebarLayout.dragType], delegate: SidebarReorderDrop(target: id, layout: layout, animation: limitMotion ? nil : .smooth(duration: 0.3)))
                            .contextMenu {
                                Button("Hide from Sidebar") { withAnimation(limitMotion ? nil : .smooth(duration: 0.3)) { layout.setHidden(id, true) } }
                                    .disabled(!layout.canHide(id))
                                Button("Customize Sidebar…") { customizing = true }
                            }
                            .accessibilityAction(named: "Move up") { layout.nudge(id, by: -1) }
                            .accessibilityAction(named: "Move down") { layout.nudge(id, by: 1) }
                            .accessibilityAction(named: "Hide from sidebar") { layout.setHidden(id, true) }
                    }

                    // Library › By day: one page a day for Thoughts and Journal (Views/ByDayView.swift).
                    SidebarHeader(title: "By day")
                    SidebarRow(title: "Thoughts", art: .iconThought, selected: app.screen == .byDay(.idea),
                               count: SideBadge.count(app.store.todaysThoughts().count)) { open(.byDay(.idea)) }
                        .uiTarget("side-thoughts")
                    // Journal shows once Journal entry is on in Record As or you have an entry (consolidation, item 16).
                    if showsJournal {
                        SidebarRow(title: "Journal", art: .iconNotes, selected: app.screen == .byDay(.journal),
                                   count: SideBadge.count(app.store.journalThisWeek())) { open(.byDay(.journal)) }
                            .uiTarget("side-journal")
                    }

                    // Make: what Apple Intelligence makes from your recordings: Templates, and Ask (questions and recipes).
                    SidebarHeader(title: "Make")
                    SidebarRow(title: "Templates", art: .iconSummaries, selected: app.screen == .templates,
                               count: "\(app.store.allTemplates.count)") { open(.templates) }
                        .uiTarget("side-templates")
                    SidebarRow(title: "Ask", art: .iconAsk, selected: app.screen == .ask,
                               count: app.store.recipes.isEmpty ? nil : "\(app.store.recipes.count)") { open(.ask) }
                        .uiTarget("side-ask")

                    SidebarHeader(title: "Projects") {
                        Button { app.newProjectFor = [] } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Refined.mute)
                                .frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New project: group transcripts by client or job, then drag transcripts onto it")
                        .accessibilityLabel("New project")
                        .uiTarget("side-new-project")
                    }
                    ForEach(app.store.projects) { p in
                        SidebarRow(title: p.name, art: .iconProject, selected: app.screen == .library && app.projectFilter == p.id,
                                   count: SideBadge.count(counts.perProject[p.id] ?? 0), onDropIDs: { app.move($0, to: p.id) }) { open(.project(p.id)) }
                            .contextMenu { Button("Delete Project", role: .destructive) { deleteProject(p) } }
                    }
                    if app.store.projects.isEmpty {
                        Text("Group transcripts by client or job.").refinedFont(.meta).foregroundStyle(Refined.mute)
                            .padding(.horizontal, 10).padding(.top, 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if counts.trash > 0 || app.screen == .trash {
                        SidebarHeader(title: "")
                        SidebarRow(title: "Recently Deleted", art: .iconDeleted, selected: app.screen == .trash,
                                   count: "\(counts.trash)") { open(.trash) }
                            .uiTarget("side-trash")
                    }
                }
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            foot
        }
        // minHeight 0: the sidebar never reports more height than the window has; any overflow scrolls.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(Refined.side.ignoresSafeArea())
        .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
        .focusable()
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .sheet(isPresented: $customizing) { CustomizeSidebarSheet() }
    }

    /// Where the library lives, one quiet line, then Settings (⌘,).
    private var foot: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                IconGlyph(art: Cloud.enabled ? .iconSync : .iconSyncOff, size: 14, color: Refined.mute)
                Text(Cloud.enabled ? "Syncing with iCloud" : "On this Mac").refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .help(Cloud.enabled
                  ? "Transcripts, notes, projects, and the Dictionary sync with your iPhone through your iCloud Drive. Models and recordings in progress stay on this Mac."
                  : "iCloud is off for Verbose, so everything stays in ~/Library/Application Support/Verbatim. Sign in to iCloud with iCloud Drive on, and run a build signed with your team, to sync with your iPhone.")
            SettingsLink {
                HStack(spacing: 9) {
                    IconGlyph(art: .iconSettings, size: 16, color: Refined.dim)
                    Text("Settings").refinedFont(.rowTitle).foregroundStyle(Refined.dim)
                    Spacer(minLength: 4)
                    Text("⌘,").refinedFont(.caption).foregroundStyle(Refined.mute).accessibilityHidden(true)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .uiTarget("side-settings")
        }
        .padding(.horizontal, 10).padding(.bottom, 12).padding(.top, 4)
    }

    private var showsJournal: Bool {
        recordAs.rows.showsJournal(hasEntries: app.store.hasJournalEntries) || app.screen == .byDay(.journal)
    }

    /// One main item: its glyph, title, count, and (Library) drop target.
    @ViewBuilder private func mainItem(_ id: SidebarItemID, library: Int) -> some View {
        switch id {
        case .home:
            SidebarRow(title: id.title, art: id.art, selected: app.screen == .home) { open(.main(.home)) }
                .uiTarget("side-home")
        case .library:
            SidebarRow(title: id.title, art: id.art, selected: app.screen == .library && app.projectFilter == nil,
                       count: SideBadge.count(library), onDropIDs: { app.move($0, to: nil) }) { open(.main(.library)) }
                .uiTarget("side-library")
        case .queue:
            // Links on their way in count too, once their "link added" card has landed here (AppState+LinkCard).
            SidebarRow(title: id.title, art: id.art, selected: app.screen == .queue,
                       count: SideBadge.count(app.queueBadgeCount), busy: app.runningID != nil) { open(.main(.queue)) }
                .anchorPreference(key: QueueItemAnchor.self, value: .bounds) { $0 }
                .uiTarget("side-queue")
        case .dictations:
            SidebarRow(title: id.title, art: id.art, selected: app.screen == .dictations) { open(.main(.dictations)) }
                .uiTarget("side-dictations")
        case .you:
            SidebarRow(title: id.title, art: id.art, selected: app.screen == .activity) { open(.main(.you)) }
                .uiTarget("side-you")
        case .dictionary:
            SidebarRow(title: id.title, art: id.art, selected: app.screen == .dictionary,
                       count: SideBadge.count(app.store.dictionary.count)) { open(.main(.dictionary)) }
                .uiTarget("side-dict")
        }
    }

    // MARK: Places

    /// The main rows on screen: the visible ones, with Queue only while something works.
    private var shownItems: [SidebarItemID] { layout.visible.filter { $0 != .queue || app.queueShowsInSidebar } }

    /// Every place in the order its row shows.
    private var places: [SidebarPlace] {
        var out = shownItems.map { SidebarPlace.main($0) }
        out.append(.byDay(.idea))
        if showsJournal { out.append(.byDay(.journal)) }
        out += [.templates, .ask]
        out += app.store.projects.map { .project($0.id) }
        if app.store.counts.trash > 0 || app.screen == .trash { out.append(.trash) }
        return out
    }

    /// The row for the current screen. A transcript selects nothing.
    private var current: SidebarPlace? {
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

    /// The up and down arrows: the place before or after the current one (the first or last from a transcript).
    private func step(_ by: Int) -> KeyPress.Result {
        let all = places
        guard !all.isEmpty else { return .ignored }
        let i = current.flatMap { all.firstIndex(of: $0) }
        let next = i.map { $0 + by } ?? (by > 0 ? 0 : all.count - 1)
        guard all.indices.contains(next) else { return .handled }
        open(all[next])
        return .handled
    }

    private func open(_ place: SidebarPlace) {
        switch place {
        case .main(let id):
            switch id {
            case .home: app.go(.home)
            case .library: app.projectFilter = nil; app.go(.library)
            case .queue: app.go(.queue)
            case .dictations: app.go(.dictations)
            case .you: app.go(.activity)
            case .dictionary: app.go(.dictionary)
            }
        case .byDay(let k): app.go(.byDay(k))
        case .templates: app.go(.templates)
        case .ask: app.go(.ask)
        case .project(let p): app.projectFilter = p; app.go(.library)
        case .trash: app.go(.trash)
        }
    }

    private func deleteProject(_ p: Project) {
        app.store.projects.removeAll { $0.id == p.id }
        if app.projectFilter == p.id { app.projectFilter = nil }
        if FlowSettings.shared.activeProject == p.id { FlowSettings.shared.activeProject = nil }
        // Its words would never apply again; they go back to working everywhere.
        for i in app.store.dictionary.indices where app.store.dictionary[i].projectId == p.id { app.store.dictionary[i].projectId = nil }
    }
}

/// A group's header in the sidebar (By day, Make, Projects): 11 pt semibold in `mute`, sentence case, with an optional
/// control at the trailing end (Projects' New project). An empty title is a gap.
struct SidebarHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            if !title.isEmpty {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Refined.mute)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.top, 14).padding(.bottom, 4)
        .frame(minHeight: 22)
    }
}

extension SidebarHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// A sidebar row (mockup): the place's glyph in the accent, its name, and a count in `mute` (or a spinner while the
/// Queue works). Selected, the persimmon tint behind it and the name in semibold; under the pointer, the quiet wash.
/// Clicks use `tapArea`, which stays reliable on macOS 26 under the row's drag and drop (Theme.swift).
struct SidebarRow: View {
    var title: String
    var art: BrandArt
    var selected: Bool
    var count: String? = nil
    var busy = false
    /// Makes the row a drop target for dragged transcripts.
    var onDropIDs: (([UUID]) -> Void)? = nil
    var action: () -> Void
    @State private var hover = false
    @State private var dropping = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 9) {
            IconGlyph(art: art, size: 16, color: Refined.accentText)
            Text(title).refinedFont(.rowTitle, weight: selected ? .semibold : .regular).foregroundStyle(Refined.ink).lineLimit(1)
            Spacer(minLength: 4)
            if busy { ProgressView().controlSize(.mini) }
            if let count { Text(count).refinedFont(.rowTitle).monospacedDigit().foregroundStyle(Refined.mute) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: 30)
        .background {
            if selected { shape.fill(Refined.persimmonTint) } else if hover || dropping { shape.fill(Refined.neutral) }
        }
        .overlay { if dropping { shape.strokeBorder(Refined.accentText, lineWidth: 1.5) } }
        .contentShape(shape)
        .tapArea(action)
        .onHover { hover = $0 }
        .modifier(TranscriptDropTarget(enabled: onDropIDs != nil, dropping: $dropping) { onDropIDs?($0) })
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(title)
        .accessibilityValue(count ?? "")
        .accessibilityAction { action() }
    }
}

/// Badges count items, never days: Thoughts shows today's thoughts and Journal this week's entries; zero shows none.
enum SideBadge {
    static func count(_ n: Int) -> String? { n > 0 ? "\(n)" : nil }
}

/// The Queue row's bounds, so the "link added" tile knows where to fly (ContentView).
struct QueueItemAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The Settings window's sidebar surface until it moves to the refined look (step 5 of the look's move): Verbose
/// style's paper, flush to the window edges, divided from the content by one hairline.
struct SidebarPaper: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Ink.paper.ignoresSafeArea())
            .overlay(alignment: .trailing) { Rectangle().fill(Ink.hairline).frame(width: 1).ignoresSafeArea() }
    }
}

#if DEBUG
struct MacSidebarRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarRow(title: "Home", art: .iconHome, selected: true) {}
            SidebarRow(title: "Library", art: .iconLibrary, selected: false, count: "47") {}
            SidebarHeader(title: "By day")
            SidebarRow(title: "Thoughts", art: .iconThought, selected: false, count: "7") {}
        }
        .padding(10)
        .frame(width: 232)
        .background(Refined.side)
    }
}
#endif
