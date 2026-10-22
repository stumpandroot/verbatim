import SwiftUI
import AppKit

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @State private var newProject = false
    @State private var projectName = ""
    @Namespace private var pill
    @ObservedObject private var layout = SidebarLayout.shared
    @State private var customizing = false
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        // `store.trash` filters and sorts every transcript; read it once per render.
        let trashCount = app.store.trash.count
        VStack(alignment: .leading, spacing: 2) {
            // Compact lockup: the bars mark and the serif wordmark.
            HStack(spacing: 10) {
                BarsMark(color: Ink.persimmon).frame(width: 19, height: 20)
                Ink.wordmark(21)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 22)
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbose")

            // The main items, in your order (SidebarLayout): drag to move, right-click to hide or customize.
            ForEach(layout.visible) { id in
                mainItem(id)
                    .onDrag { layout.itemProvider(id) }
                    .onDrop(of: [SidebarLayout.dragType], delegate: SidebarReorderDrop(target: id, layout: layout, animation: limitMotion ? nil : .spring(duration: 0.3, bounce: 0)))
                    .contextMenu {
                        Button("Hide from sidebar") { withAnimation(limitMotion ? nil : .spring(duration: 0.3, bounce: 0)) { layout.setHidden(id, true) } }
                            .disabled(!layout.canHide(id))
                        Button("Customize sidebar…") { customizing = true }
                    }
                    .accessibilityAction(named: "Move up") { layout.nudge(id, by: -1) }
                    .accessibilityAction(named: "Move down") { layout.nudge(id, by: 1) }
                    .accessibilityAction(named: "Hide from sidebar") { layout.setHidden(id, true) }
            }

            HStack {
                Text("Projects").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute).accessibilityAddTraits(.isHeader)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 22, height: 22).hoverChip().tapArea { newProject = true }
                    .help("New project")
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.top, 18).padding(.bottom, 4)
            ForEach(app.store.projects) { p in
                SideItem(label: p.name, art: .iconProject,
                         selected: app.screen == .library && app.projectFilter == p.id, pill: pill, onDropIDs: { app.move($0, to: p.id) }) { app.projectFilter = p.id; app.go(.library) }
                    .contextMenu { Button("Delete project", role: .destructive) {
                        app.store.projects.removeAll { $0.id == p.id }
                        if app.projectFilter == p.id { app.projectFilter = nil }
                        if FlowSettings.shared.activeProject == p.id { FlowSettings.shared.activeProject = nil }
                        // Its words would never apply again; they go back to working everywhere.
                        for i in app.store.dictionary.indices where app.store.dictionary[i].projectId == p.id { app.store.dictionary[i].projectId = nil }
                    } }
            }
            if app.store.projects.isEmpty && !newProject {
                Text("Group transcripts by client or job.").font(.system(size: 11.5)).foregroundStyle(Ink.mute).padding(.horizontal, 12).padding(.top, 2)
            }
            if newProject {
                TextField("Project name", text: $projectName, onCommit: {
                    let n = projectName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { app.projectFilter = app.store.addProject(n).id; app.go(.library) }
                    projectName = ""; newProject = false
                })
                .textFieldStyle(.roundedBorder).font(.system(size: 12.5)).padding(.horizontal, 6)
                .onExitCommand { newProject = false; projectName = "" }
            }
            Spacer()
            if trashCount > 0 || app.screen == .trash {
                SideItem(label: "Recently Deleted", art: .iconDeleted, selected: app.screen == .trash, badge: "\(trashCount)", pill: pill) { app.go(.trash) }
                    .padding(.bottom, 6)
            }
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 8).padding(.bottom, 8)
            HStack(spacing: 12) {
                IconGlyph(art: Cloud.enabled ? .iconSync : .iconSyncOff, size: 19, color: Ink.dim)
                Text(Cloud.enabled ? "Syncing with iCloud" : "On this Mac")
            }
            .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .help(Cloud.enabled
                  ? "Transcripts, notes, projects, and the Dictionary sync with your iPhone through your iCloud Drive. Models and recordings in progress stay on this Mac."
                  : "iCloud is off for Verbose, so everything stays in ~/Library/Application Support/Verbatim. Sign in to iCloud with iCloud Drive on, and run a build signed with your team, to sync with your iPhone.")
            SettingsLink {
                HStack(spacing: 12) { IconGlyph(art: .iconSettings, size: 19, color: Ink.dim); Text("Settings"); Spacer(); Text("⌘,").font(.system(size: 11)).foregroundStyle(Ink.mute) }
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
                    .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverChip(radius: Radius.button)
        }
        .padding(.horizontal, 12).padding(.top, 40).padding(.bottom, 12)
        .font(.system(size: 14.5))
        .foregroundStyle(Ink.ink)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(SidebarPaper())
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $customizing) { CustomizeSidebarSheet() }
    }

    /// One main item: its label, icon, selection, badge, and drop target for transcripts.
    @ViewBuilder private func mainItem(_ id: SidebarItemID) -> some View {
        switch id {
        case .home:
            SideItem(label: id.title, art: id.art, selected: app.screen == .home, pill: pill) { app.go(.home) }
                .uiTarget("side-home")
        case .library:
            SideItem(label: id.title, art: id.art, selected: app.screen == .library && app.projectFilter == nil, pill: pill, onDropIDs: { app.move($0, to: nil) }) { app.projectFilter = nil; app.go(.library) }
                .uiTarget("side-library")
        case .links:
            SideItem(label: id.title, art: id.art, selected: app.screen == .links, pill: pill) { app.go(.links) }
                .uiTarget("side-links")
        case .moments:
            SideItem(label: id.title, art: id.art, selected: app.screen == .moments, pill: pill) { app.go(.moments) }
                .uiTarget("side-moments")
        case .queue:
            // Links on their way in count too, once their "link added" card has landed here (AppState+LinkCard).
            let queued = app.queueBadgeCount
            SideItem(label: id.title, art: id.art, selected: app.screen == .queue,
                     badge: queued == 0 ? nil : "\(queued)", busy: app.runningID != nil, pill: pill,
                     pillBadge: true, badgePops: app.queueBadgePops) { app.go(.queue) }
                .anchorPreference(key: QueueItemAnchor.self, value: .bounds) { $0 }
                .uiTarget("side-queue")
        case .dictations:
            SideItem(label: id.title, art: id.art, selected: app.screen == .dictations, pill: pill) { app.go(.dictations) }
                .uiTarget("side-dictations")
        case .you:
            SideItem(label: id.title, art: id.art, selected: app.screen == .activity, pill: pill) { app.go(.activity) }
                .uiTarget("side-you")
        case .dictionary:
            SideItem(label: id.title, art: id.art, selected: app.screen == .dictionary, badge: app.store.dictionary.isEmpty ? nil : "\(app.store.dictionary.count)", pill: pill) { app.go(.dictionary) }
                .uiTarget("side-dict")
        }
    }
}

/// The Queue row's bounds, so the "link added" tile knows where to fly (ContentView).
struct QueueItemAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The sidebar is part of the page: the same opaque paper as the content, flush to the window edges,
/// divided from the content by one hairline. No glass, no shadow, no inset; the selected row carries a
/// persimmon tick at the window edge. Hairline strength follows Increase Contrast through `Ink.hairline`.
struct SidebarPaper: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Ink.paper.ignoresSafeArea())
            .overlay(alignment: .trailing) { Rectangle().fill(Ink.hairline).frame(width: 1).ignoresSafeArea() }
    }
}

struct SideItem: View {
    var label: String
    var symbol: String? = nil
    /// A fine-line Verbatim icon; used instead of `symbol` when set.
    var art: BrandArt? = nil
    var symbolColor: Color? = nil
    var selected: Bool
    var badge: String? = nil
    var busy = false
    var pill: Namespace.ID
    /// Shows the badge as a persimmon count pill (Queue), which pops when `badgePops` goes up.
    var pillBadge = false
    var badgePops = 0
    /// Makes the row a drop target for dragged transcripts.
    var onDropIDs: (([UUID]) -> Void)? = nil
    var action: () -> Void
    @State private var hover = false
    @State private var dropping = false

    var body: some View {
        HStack(spacing: 12) {
            if let a = art { IconGlyph(art: a, size: 19, color: symbolColor ?? Ink.ink) }
            else if let s = symbol { Image(systemName: s).font(.system(size: 14.5, weight: .regular)).frame(width: 19).foregroundStyle(symbolColor ?? Ink.ink) }
            Text(label).lineLimit(1)
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.mini) }
            if pillBadge {
                // Always in place, so the pop also plays when the first item arrives.
                CountPill(text: badge ?? "", pops: badgePops)
                    .opacity(badge == nil ? 0 : 1)
                    .frame(width: badge == nil ? 0 : nil)
                    .animation(Motion.fade, value: badge == nil)
            } else if let b = badge { Text(b).font(.system(size: 11)).foregroundStyle(Ink.mute) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            ZStack {
                // Hover previews with a light ink tint; selection is the persimmon tick and semibold type, no fill.
                if dropping { RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.wash).overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5)) }
                else if hover && !selected { RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.ink.opacity(0.06)) }
            }
        }
        .overlay(alignment: .leading) {
            if selected { UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 1.5, topTrailingRadius: 1.5).fill(Ink.persimmon).frame(width: 3, height: 18).offset(x: -12).matchedGeometryEffect(id: "marker", in: pill) }
        }
        .foregroundStyle(Ink.ink)
        .fontWeight(selected ? .semibold : .regular)
        .tapArea(action)
        .onHover { hover = $0 }
        .modifier(TranscriptDropTarget(enabled: onDropIDs != nil, dropping: $dropping) { onDropIDs?($0) })
        .animation(Motion.touch, value: hover)
        .animation(Motion.touch, value: dropping)
        .animation(Motion.snap, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
    }
}

