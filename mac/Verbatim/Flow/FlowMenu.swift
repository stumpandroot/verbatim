import AppKit
import SwiftUI

/// The Ribbon's right-click menu, drawn on Verbatim's paper instead of the system menu.
/// It opens beside the Ribbon on the side away from the screen edge; Microphone and Cleanup open side menus.
/// Click outside it, press Esc, or pick an item to close it.
@MainActor
final class FlowMenuController {
    struct Actions {
        var hide: () -> Void
        var settings: () -> Void
        var pasteLast: () -> Void
        var copyLast: () -> Void
        var editByVoice: () -> Void
        var run: (FlowAction) -> Void
        var editActions: () -> Void
        var projects: [Project]
        var newThought: () -> Void
    }

    private var panel: FlowMenuPanel?
    private var monitors: [Any] = []
    private var onClose: (() -> Void)?
    var isOpen: Bool { panel != nil }
    /// When the menu last closed: a click on the Ribbon that closed the menu shouldn't also start dictating.
    private(set) var closedAt = Date.distantPast

    private static let size = CGSize(width: 520, height: 560)

    func open(next ribbon: NSRect, edge: BarEdge, screen: NSScreen, actions: Actions, onClose: @escaping () -> Void) {
        close()
        self.onClose = onClose
        let size = Self.size
        let f = screen.visibleFrame
        // The menu grows away from the edge; its side menu opens further in the same direction.
        var origin: CGPoint
        switch edge {
        case .left: origin = CGPoint(x: ribbon.maxX + 6, y: ribbon.midY - size.height + 150)
        case .right: origin = CGPoint(x: ribbon.minX - 6 - size.width, y: ribbon.midY - size.height + 150)
        case .bottom: origin = CGPoint(x: ribbon.midX - 120, y: ribbon.maxY + 6)
        }
        origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
        origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        let opensLeft = edge == .right
        let p = FlowMenuPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let anchorTop = edge == .bottom ? false : true
        let view = FlowMenuView(opensLeft: opensLeft, anchorTop: anchorTop, actions: actions, close: { [weak self] in self?.close() })
        let host = FlowHostingView(rootView: view)   // takes the first click without Verbatim being active
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
        // Close on a click anywhere else, or Esc.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] _ in Task { @MainActor in self?.close() } }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] e in
            guard let self, let p = self.panel else { return e }
            // Esc closes the menu; any other key closes it too and goes on to where you were typing.
            if e.type == .keyDown { self.close(); return e.keyCode == 53 ? nil : e }
            if e.window !== p { self.close() }
            return e
        }) { monitors.append(l) }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        guard let p = panel else { return }
        panel = nil
        closedAt = Date()
        p.orderOut(nil)
        // Released on the next turn: close() is often called from inside this panel's own SwiftUI action.
        DispatchQueue.main.async { p.close() }
        let done = onClose; onClose = nil
        done?()
    }
}

final class FlowMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }  // typing keeps going to your app; Esc is watched globally
    override var canBecomeMain: Bool { false }
}

/// The menu's colors: Verbatim's tokens, so it follows Dark mode and Increase Contrast like the app.
private enum Paper {
    static let card = Refined.card
    static let line = Refined.separator
    static let rule = Refined.separator
    static let hover = Refined.neutral
    static let ink = Refined.ink
    static let dim = Refined.dim
    static let mute = Refined.mute
}

struct FlowMenuView: View {
    let opensLeft: Bool
    let anchorTop: Bool
    let actions: FlowMenuController.Actions
    let close: () -> Void
    @ObservedObject private var settings = FlowSettings.shared
    @State private var sub: Sub? = nil
    @State private var devices: [AudioDevices.Device] = AudioDevices.inputs()
    @State private var selectedUID: String? = AudioDevices.selectedUID

    enum Sub { case mic, cleanup, actions, project }

    var body: some View {
        ZStack(alignment: anchorTop ? (opensLeft ? .topTrailing : .topLeading) : (opensLeft ? .bottomTrailing : .bottomLeading)) {
            // Clicking the empty part of the panel closes the menu, like clicking outside it.
            Color.clear.contentShape(Rectangle()).onTapGesture { close() }
            HStack(alignment: anchorTop ? .top : .bottom, spacing: 6) {
                if opensLeft, sub != nil { submenu }
                main
                if !opensLeft, sub != nil { submenu }
            }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            item("Hide for 1 hour", .iconHide) { actions.hide(); close() }
            item("Settings", .iconSettings) { actions.settings(); close() }
            rule
            item("Project", .iconProject, trailing: actions.projects.first { $0.id == settings.activeProject }?.name ?? "None", chevron: true, highlighted: sub == .project) { sub = sub == .project ? nil : .project }
                .onHover { if $0 { sub = .project } }
            item("New thought", .iconThought, keys: "⌃⌥P") { actions.newThought(); close() }
                .onHover { if $0 { sub = nil } }
            rule
            item("Microphone", .capture, chevron: true, highlighted: sub == .mic) { sub = sub == .mic ? nil : .mic }
                .onHover { if $0 { sub = .mic } }
            item("Cleanup", .iconQuality, trailing: settings.cleanup.title, chevron: true, highlighted: sub == .cleanup) { sub = sub == .cleanup ? nil : .cleanup }
                .onHover { if $0 { sub = .cleanup } }
            item("Actions", .refine, chevron: true, highlighted: sub == .actions) { sub = sub == .actions ? nil : .actions }
                .onHover { if $0 { sub = .actions } }
            rule
            item("Edit selection by voice", .iconFeedback, keys: "⇧ + key") { actions.editByVoice(); close() }
                .onHover { if $0 { sub = nil } }
            // Dictation history left the Ribbon's menu in the consolidation (October 28, 2026): Dictations in the main
            // window and Recall (⌥⌘V) keep it.
            item("Paste last dictation", .iconPaste, keys: "⌃⌘V") { actions.pasteLast(); close() }
                .onHover { if $0 { sub = nil } }
            item("Copy last dictation", .iconCopy) { actions.copyLast(); close() }
                .onHover { if $0 { sub = nil } }
        }
        .padding(6)
        .frame(width: 240)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Paper.line))
    }

    @ViewBuilder private var submenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch sub {
            case .mic:
                header("Microphone")
                choice("System default" + (AudioDevices.defaultInput().map { " (\($0.name))" } ?? ""), on: selectedUID == nil) { pickMic(nil) }
                ForEach(devices) { d in
                    let uid = AudioDevices.deviceUID(d.id)
                    choice(d.name, on: selectedUID != nil && selectedUID == uid) { pickMic(uid) }
                    if d.transport == "Bluetooth" {
                        Text("Bluetooth: call quality, slow start").font(.system(size: 11.5)).foregroundStyle(Paper.mute).padding(.leading, 37).padding(.bottom, 4)
                    }
                }
            case .cleanup:
                header("Cleanup")
                ForEach(CleanupLevel.allCases) { l in
                    choice(l.title, on: settings.cleanup == l, note: l.shortNote) { settings.cleanup = l; close() }
                }
            case .project:
                header("Dictate into")
                choice("No project", on: !actions.projects.contains { $0.id == settings.activeProject }) { settings.activeProject = nil; close() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(actions.projects) { p in
                            choice(p.name, on: settings.activeProject == p.id) { settings.activeProject = p.id; close() }
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(actions.projects.count) * 31, 280))
                Text(actions.projects.isEmpty ? "Make a project in Verbose's sidebar first." : "Uses the project's Dictionary words and files each dictation there.")
                    .font(.system(size: 11.5)).foregroundStyle(Paper.mute).padding(.horizontal, 10).padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
            case .actions:
                header("On selected text")
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(settings.actions) { a in
                            MenuRow(highlighted: false, action: { close(); actions.run(a) }) {
                                IconGlyph(art: a.art, size: 15, color: Paper.dim).frame(width: 20)
                                Text(a.name).font(.system(size: 13)).foregroundStyle(Paper.ink).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: min(CGFloat(settings.actions.count) * 31, 340))
                Rectangle().fill(Paper.rule).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5)
                MenuRow(highlighted: false, action: { actions.editActions(); close() }) {
                    ArtIcon(art: .iconQuality, size: 16).foregroundStyle(Paper.dim).frame(width: 20)
                    Text("Edit in Templates…").font(.system(size: 13)).foregroundStyle(Paper.ink)
                    Spacer(minLength: 0)
                }
            case nil:
                EmptyView()
            }
        }
        .padding(6)
        .frame(width: 236)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Paper.line))
        .padding(.top, anchorTop ? (sub == .cleanup ? 201 : sub == .mic ? 165 : sub == .project ? 82 : 0) : 0)
    }

    private func pickMic(_ uid: String?) {
        AudioDevices.selectedUID = uid
        selectedUID = uid
        devices = AudioDevices.inputs()
        close()
    }

    private var rule: some View { Rectangle().fill(Paper.rule).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5) }

    private func header(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(Paper.dim).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    }

    private func item(_ title: String, _ art: BrandArt, trailing: String? = nil, keys: String? = nil, chevron: Bool = false, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        MenuRow(highlighted: highlighted, action: action) {
            ArtIcon(art: art, size: 16).foregroundStyle(highlighted ? Paper.ink : Paper.dim).frame(width: 20)
            Text(title).font(.system(size: 13)).foregroundStyle(Paper.ink)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(Paper.mute).lineLimit(1) }
            if let keys { Keycap(keys: keys, size: 10.5).foregroundStyle(Paper.mute) }
            if chevron { Image(systemName: opensLeft ? "chevron.left" : "chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Paper.mute) }
        }
    }

    private func choice(_ title: String, on: Bool, note: String? = nil, action: @escaping () -> Void) -> some View {
        MenuRow(highlighted: false, action: action) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Paper.ink).opacity(on ? 1 : 0).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(Paper.ink).lineLimit(1)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Paper.mute) }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MenuRow<Content: View>: View {
    var highlighted: Bool
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background((hover || highlighted) ? Paper.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}
