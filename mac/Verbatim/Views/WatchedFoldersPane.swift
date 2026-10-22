import SwiftUI
import AppKit

extension BrandArt {
    /// A folder, in the fine-line interface set (24-unit grid).
    static let iconFolder = BrandArt(box: iconGrid, strokes: [.path("M3 7.5V18C3 18.8 3.7 19.5 4.5 19.5H19.5C20.3 19.5 21 18.8 21 18V9C21 8.2 20.3 7.5 19.5 7.5H12L10 5H4.5C3.7 5 3 5.7 3 6.5Z")], strokeWidth: 1.5)
}

/// Settings › Watched folders: the folder list with each one's status, Add folder and Open activity, then the
/// selected folder's auto-export: formats, where and under what name, and whether to notify.
struct WatchedFoldersPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var watcher = FolderWatcher.shared
    @AppStorage("watch.selected") private var selectedRaw = ""
    @AppStorage("settingsTab") private var tab: SettingsTab = .watched
    @State private var showActivity = false

    private var selected: WatchedFolder? {
        watcher.folders.first { $0.id.uuidString == selectedRaw } ?? watcher.folders.first
    }

    var body: some View {
        SettingsPane(tab: .watched) {
            VStack(alignment: .leading, spacing: 12) {
                if watcher.folders.isEmpty {
                    empty
                } else {
                    VStack(spacing: 0) {
                        ForEach(watcher.folders) { f in
                            WatchedFolderRow(folder: f, status: watcher.status(f), busy: watcher.busy[f.id] ?? 0,
                                             selected: f.id == selected?.id && watcher.folders.count > 1) {
                                selectedRaw = f.id.uuidString
                            }
                        }
                    }
                    .padding(.top, -1)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .cardSurface(radius: Radius.tile)
                    .settingsAnchor("watched.folders", radius: Radius.tile)
                    .uiTarget("watched-list")
                }
                HStack(spacing: 8) {
                    Button("Add folder…") {
                        watcher.addFolder()
                        if let last = watcher.folders.last { selectedRaw = last.id.uuidString }
                    }
                    .buttonStyle(.brandPrimaryLarge)
                    .settingsAnchor("watched.add", radius: Radius.button)
                    .uiTarget("watched-add")
                    Button("Open activity") { showActivity = true }
                        .buttonStyle(.brandSecondaryLarge)
                        .settingsAnchor("watched.activity", radius: Radius.button)
                }
            }
            if let f = selected {
                WatchedFolderDetail(folder: f, openExport: { tab = .export })
                    .id(f.id)
            }
        }
        .sheet(isPresented: $showActivity) { WatchActivitySheet(done: { showActivity = false }).environmentObject(app) }
    }

    private var empty: some View {
        HStack(spacing: 16) {
            IconPlate(art: .iconFolder, size: 64, color: Ink.dim)
            VStack(alignment: .leading, spacing: 4) {
                Text("No folders yet").font(.system(size: 14, weight: .semibold))
                Text("Add a folder and anything new that lands in it is transcribed: a camera card's dailies, a recorder's sync folder, a shared Dropbox. Files already there are left alone.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.tile)
        .settingsAnchor("watched.folders", radius: Radius.tile)
    }
}

/// One watched folder: tinted folder tile, name and path, what it exports where, and a status tag.
struct WatchedFolderRow: View {
    var folder: WatchedFolder
    var status: FolderWatcher.Status
    var busy: Int
    var selected: Bool
    var select: () -> Void
    @ObservedObject private var watcher = FolderWatcher.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            IconGlyph(art: .iconFolder, size: 18, color: Ink.ink)
                .frame(width: 34, height: 34)
                .background(tileColor, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(WatchedFolder.display(folder.path) + (folder.includeSubfolders ? " · subfolders included" : ""))
                    .font(Ink.mono(11.5)).foregroundStyle(Ink.mute).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(summary).font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .trailing)
            tag
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(selected ? Ink.wash : Ink.ink.opacity(hover ? 0.03 : 0))
        .overlay(alignment: .top) { RowRule() }
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .tapArea(select)
        .contextMenu {
            Button(folder.enabled ? "Pause" : "Resume") { watcher.update(folder.id) { $0.enabled.toggle() } }
            if status == .needsAccess { Button("Give Access…") { watcher.reconnect(folder.id) } }
            Button("Show in Finder") { watcher.reveal(folder.id) }
            Divider()
            Button("Stop Watching", role: .destructive) { watcher.remove(folder.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this folder's auto-export settings")
    }

    private var tileColor: Color {
        switch status { case .watching: return Ink.sageTint; case .paused: return Ink.butterTint; case .needsAccess: return Ink.persimmonTint }
    }

    private var summary: String {
        let formats = folder.exportFormats.map(\.rawValue)
        guard !formats.isEmpty else { return "Library only, no export" }
        let dest = folder.destinationPath.map(WatchedFolder.display) ?? "next to the original"
        return formats.joined(separator: " + ") + " → " + dest
    }

    @ViewBuilder private var tag: some View {
        let (text, fill, fg): (String, Color, Color) = {
            switch status {
            case .watching: return (busy > 0 ? "Transcribing \(busy)" : "Watching", Ink.sageTint, Ink.ink)
            case .paused: return ("Paused", Ink.ink.opacity(0.08), Ink.ink)
            case .needsAccess: return ("Needs access", Ink.persimmonTint, Ink.accentText)
            }
        }()
        if status == .needsAccess {
            Button { watcher.reconnect(folder.id) } label: { tagLabel(text, fill, fg) }.buttonStyle(.plain).help("Choose the folder again to keep watching it")
        } else {
            tagLabel(text, fill, fg)
        }
    }

    private func tagLabel(_ text: String, _ fill: Color, _ fg: Color) -> some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(fg)
            .padding(.horizontal, 10).frame(height: 24)
            .background(fill, in: Capsule())
            .fixedSize()
    }
}

/// The selected folder's auto-export: format chips; Save to, File name, When it's done; and the folder's own
/// switches.
struct WatchedFolderDetail: View {
    var folder: WatchedFolder
    var openExport: () -> Void
    @ObservedObject private var watcher = FolderWatcher.shared
    @State private var pattern = ""

    /// The order the chips appear in.
    private let chipOrder: [ExportFormat] = [.srt, .txt, .vtt, .docx, .md, .json]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Auto-export for \(folder.name)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                .lineLimit(1).accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 16) {
                formatsCard
                whereCard
            }
            .fixedSize(horizontal: false, vertical: true)
            SettingsGroup(title: "This folder") {
                SettingsToggleRow("watched.enabled", isOn: binding(\.enabled))
                SettingsToggleRow("watched.subfolders", isOn: binding(\.includeSubfolders))
                SettingsRow("watched.location", detail: WatchedFolder.display(folder.path)) {
                    HStack(spacing: 8) {
                        Button("Show in Finder") { watcher.reveal(folder.id) }.buttonStyle(.brandSecondary)
                        Button("Stop Watching") { watcher.remove(folder.id) }.buttonStyle(.brandSecondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auto-export for \(folder.name)")
        .onAppear { pattern = folder.namePattern }
    }

    private var formatsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardOverline("Export formats")
            FlowChips(spacing: 6) {
                ForEach(chipOrder) { f in
                    SettingsChip(title: f.rawValue, on: folder.formats.contains(f.rawValue)) {
                        watcher.update(folder.id) { w in
                            if let i = w.formats.firstIndex(of: f.rawValue) { w.formats.remove(at: i) } else { w.formats.append(f.rawValue) }
                        }
                    }
                }
            }
            .settingsAnchor("watched.formats", radius: Radius.button)
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.formats.isEmpty ? "None chosen: transcripts stay in your Library." : "Uses the options from Settings › Export (which text, speaker names, timecodes).")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                Button("Open Export settings →", action: openExport).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Ink.accentText)
            }
            .settingsAnchor("watched.exportOptions", radius: 6)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(radius: Radius.tile)
        .uiTarget("watched-formats")
    }

    private var whereCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardOverline("Where and what name")
            HStack {
                Text("Save to").font(.system(size: 13))
                Spacer(minLength: 12)
                Menu {
                    Button("Next to the Original") { watcher.update(folder.id) { $0.destination = nil; $0.destinationPath = nil } }
                    Button("Choose Folder…") { watcher.chooseDestination(folder.id) }
                } label: {
                    Text(folder.destinationPath.map(WatchedFolder.display) ?? "Next to the original").font(Ink.mono(12)).lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .settingsAnchor("watched.saveTo", radius: 6)
            HStack {
                Text("File name").font(.system(size: 13))
                Spacer(minLength: 12)
                TextField("{original name}", text: $pattern)
                    .textFieldStyle(.plain).font(Ink.mono(12)).multilineTextAlignment(.trailing)
                    .frame(minWidth: 120, maxWidth: 180)
                    .onSubmit(savePattern)
                    .onChange(of: pattern) { _, _ in savePattern() }
                    .accessibilityLabel("File name pattern")
                Text("." + (folder.exportFormats.first?.ext ?? "txt")).font(Ink.mono(12)).foregroundStyle(Ink.mute)
            }
            .settingsAnchor("watched.fileName", radius: 6)
            HStack {
                Text("When it's done").font(.system(size: 13))
                Spacer(minLength: 12)
                Picker("When it's done", selection: binding(\.notify)) {
                    Text("Notify me").tag(true)
                    Text("Stay quiet").tag(false)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            .settingsAnchor("watched.notify", radius: 6)
            Text("{original name}, {title}, and {date} fill in for each file.").font(.system(size: 11.5)).foregroundStyle(Ink.mute)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(radius: Radius.tile)
    }

    private func cardOverline(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute).accessibilityAddTraits(.isHeader)
    }

    private func savePattern() {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        watcher.update(folder.id) { $0.namePattern = p.isEmpty ? "{original name}" : p }
    }

    private func binding(_ key: WritableKeyPath<WatchedFolder, Bool>) -> Binding<Bool> {
        Binding(get: { watcher.folders.first { $0.id == folder.id }?[keyPath: key] ?? folder[keyPath: key] },
                set: { v in watcher.update(folder.id) { $0[keyPath: key] = v } })
    }
}

/// Lays out chips left to right, wrapping onto new lines.
struct FlowChips: Layout {
    var spacing: CGFloat = 6
    init(spacing: CGFloat = 6) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

/// What the watched folders have done, newest first.
struct WatchActivitySheet: View {
    var done: () -> Void
    @ObservedObject private var watcher = FolderWatcher.shared
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPaneHeader(overline: "Watched folders", title: "Activity")
            if watcher.events.isEmpty {
                Text("Nothing yet. When a file lands in a watched folder, it shows here as it's transcribed and exported.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(watcher.events) { e in row(e) }
                    }
                    .padding(.top, -1)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .cardSurface(radius: Radius.tile)
                }
            }
            HStack {
                Spacer()
                Button("Done", action: done).buttonStyle(.brandPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 600, height: 520)
        .background(Ink.paper)
    }

    private func row(_ e: WatchEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().fill(color(e.kind)).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(e.file).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(e.folder) · \(e.detail)").font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(e.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.mute)
            if let id = e.transcriptID, app.store.transcript(id) != nil {
                Button("Open") { done(); NSApp.activate(ignoringOtherApps: true); app.go(.transcript(id)) }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Ink.accentText)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { RowRule() }
    }

    private func color(_ k: WatchEvent.Kind) -> Color {
        switch k { case .queued: return Ink.butter; case .exported, .ready: return Ink.sage; case .failed: return Ink.persimmon }
    }
}
