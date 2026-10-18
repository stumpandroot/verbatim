import SwiftUI
import AppKit

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @State private var newProject = false
    @State private var projectName = ""
    @Namespace private var pill

    var body: some View {
        // `store.trash` filters and sorts every transcript; read it once per render.
        let trashCount = app.store.trash.count
        VStack(alignment: .leading, spacing: 2) {
            // Compact lockup: the bars mark and the serif wordmark.
            HStack(spacing: 10) {
                BarsMark(color: Ink.persimmon).frame(width: 19, height: 20)
                Text("Verbatim").font(Ink.serif(21)).foregroundStyle(Ink.ink)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 22)
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbatim")

            SideItem(label: "Home", art: .iconHome, selected: app.screen == .home, pill: pill) { app.go(.home) }
                .uiTarget("side-home")
            SideItem(label: "Library", art: .iconLibrary, selected: app.screen == .library && app.projectFilter == nil, pill: pill, onDropIDs: { app.move($0, to: nil) }) { app.projectFilter = nil; app.go(.library) }
                .uiTarget("side-library")
            SideItem(label: "Links", art: .iconLinks, selected: app.screen == .links, badge: nil, pill: pill) { app.go(.links) }
                .uiTarget("side-links")
            SideItem(label: "Moments", art: .iconMoments, selected: app.screen == .moments, pill: pill) { app.go(.moments) }
                .uiTarget("side-moments")
            SideItem(label: "Queue", art: .iconQueue, selected: app.screen == .queue,
                     badge: app.queue.count + (app.runningID == nil ? 0 : 1) == 0 ? nil : "\(app.queue.count + (app.runningID == nil ? 0 : 1))", busy: app.runningID != nil, pill: pill) { app.go(.queue) }
                .uiTarget("side-queue")
            SideItem(label: "Dictations", art: .iconDictations, selected: app.screen == .dictations, badge: nil, pill: pill) { app.go(.dictations) }
                .uiTarget("side-dictations")
            SideItem(label: "Activity", art: .iconActivity, selected: app.screen == .activity, badge: nil, pill: pill) { app.go(.activity) }
                .uiTarget("side-activity")
            SideItem(label: "Dictionary", art: .iconDictionary, selected: app.screen == .dictionary, badge: app.store.dictionary.isEmpty ? nil : "\(app.store.dictionary.count)", pill: pill) { app.go(.dictionary) }
                .uiTarget("side-dict")

            HStack {
                Overline(text: "Projects", color: Ink.mute)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 22, height: 22).hoverChip().tapArea { newProject = true }
                    .help("New project")
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.top, 18).padding(.bottom, 4)
            ForEach(app.store.projects) { p in
                SideItem(label: p.name, symbol: "folder.fill", symbolColor: [Ink.persimmon, Ink.sageText, Ink.petal][p.colorIndex % 3],
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
                  : "iCloud is off for Verbatim, so everything stays in ~/Library/Application Support/Verbatim. Sign in to iCloud with iCloud Drive on, and run a build signed with your team, to sync with your iPhone.")
            SettingsLink {
                HStack(spacing: 12) { IconGlyph(art: .iconSettings, size: 19, color: Ink.dim); Text("Settings"); Spacer(); Text("⌘,").font(.system(size: 11)).foregroundStyle(Ink.mute) }
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
                    .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverChip(radius: 10)
        }
        .padding(.horizontal, 12).padding(.top, 40).padding(.bottom, 12)
        .font(.system(size: 14.5))
        .foregroundStyle(Ink.ink)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(SidebarPaper())
        .ignoresSafeArea(edges: .top)
    }
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
            if let b = badge { Text(b).font(.system(size: 11)).foregroundStyle(Ink.mute) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            ZStack {
                // Hover previews with a light ink tint; selection is the persimmon tick and semibold type, no fill.
                if dropping { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.accentSubtle).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.persimmon, lineWidth: 1.5)) }
                else if hover && !selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.ink.opacity(0.06)) }
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

/// The app mark for the menu bar panel: the persimmon app icon geometry (app_icon_persimmon).
struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.persimmon)
            BarsMark(color: Color(hex: Ink.paperHex)).padding(4.5)
        }
    }
}

/// A native AppKit material (sidebar, popover, HUD) for SwiftUI.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .withinWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = blending; v.state = .followsWindowActiveState; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending }
}
