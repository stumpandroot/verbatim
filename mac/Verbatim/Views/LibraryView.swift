import SwiftUI

/// Every transcript, grouped by day (pinned first), filtered by the sidebar project and the search field.
/// Select mode picks many at once to move, export, or delete; any row (or the selection) drags onto a project.
struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var selecting = false
    @State private var selection: Set<UUID> = []

    var body: some View {
        let groups = Store.group(app.filtered)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(app.projectFilter.flatMap { id in app.store.projects.first { $0.id == id }?.name } ?? "Library")
                            .font(Ink.serif(30, weight: .regular)).foregroundStyle(Ink.ink)
                        Text("\(app.filtered.count) transcripts").font(.system(size: 13)).foregroundStyle(Ink.mute)
                        Spacer()
                        if !app.filtered.isEmpty {
                            Button(selecting ? "Done" : "Select") {
                                withAnimation(Motion.snap) { selecting.toggle(); if !selecting { selection = [] } }
                            }
                            .buttonStyle(.bordered).keyboardShortcut(selecting ? .cancelAction : .init("s", modifiers: [.command, .shift]))
                        }
                        Button { app.chooseFiles() } label: { Label("Import", systemImage: "plus") }.buttonStyle(.bordered)
                    }
                    .staggerIn(0).padding(.bottom, 6)
                    if !selecting && !app.store.projects.isEmpty {
                        Text("Drag a transcript onto a project in the sidebar to file it.").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                    }
                    if groups.isEmpty {
                        HStack(spacing: 14) {
                            VerbieView(pose: app.search.isEmpty ? .ready : .nothing, tracksPointer: false).frame(width: 54, height: 72)
                            Text(app.search.isEmpty ? "Nothing in here yet." : "Nothing found for “\(app.search)”.").font(.system(size: 14)).foregroundStyle(Ink.mute)
                        }
                        .padding(.top, 30).staggerIn(1)
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.label) { gi, g in
                        HStack {
                            Text(g.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.mute)
                            Spacer()
                            if selecting {
                                let ids = Set(g.items.map(\.id))
                                Button(ids.isSubset(of: selection) ? "Deselect" : "Select all") {
                                    if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
                                }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.iris)
                            }
                        }
                        .padding(.top, 22).padding(.bottom, 8).staggerIn(1 + gi * 2)
                        VStack(spacing: 8) {
                            ForEach(Array(g.items.enumerated()), id: \.element.id) { ii, t in
                                HistoryRow(transcript: t, selected: selecting ? selection.contains(t.id) : nil,
                                           dragIDs: { selection.contains(t.id) ? Array(selection) : [t.id] },
                                           open: { if selecting { toggle(t.id) } else { app.go(.transcript(t.id)) } })
                                    .staggerIn(2 + gi * 2 + ii)
                                    .contextMenu { RowMenu(transcript: t) }
                            }
                        }
                    }
                }
                .frame(maxWidth: 1040)
                .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, selecting ? 90 : 40)
                .frame(maxWidth: .infinity)
            }
            .animation(Motion.settle, value: app.filtered.map(\.id))
        }
        .overlay(alignment: .bottom) {
            if selecting { actionBar.padding(.bottom, 18).transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .identity)) }
        }
        .onChange(of: app.projectFilter) { _, _ in selection = [] }
    }

    private func toggle(_ id: UUID) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }

    private var chosen: [Transcript] { app.filtered.filter { selection.contains($0.id) } }

    /// Glass action bar for the selection.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "Select transcripts" : "\(selection.count) selected").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
                .frame(minWidth: 110, alignment: .leading)
            Button("Select all") { selection = Set(app.filtered.map(\.id)) }.buttonStyle(.plain).foregroundStyle(Ink.iris).font(.system(size: 13, weight: .medium))
            Divider().frame(height: 20)
            Menu {
                Button("No project") { app.move(Array(selection), to: nil) }
                if !app.store.projects.isEmpty { Divider() }
                ForEach(app.store.projects) { p in Button(p.name) { app.move(Array(selection), to: p.id) } }
            } label: { Label("Move to", systemImage: "folder") }
            .menuStyle(.borderlessButton).fixedSize().disabled(selection.isEmpty)
            Menu {
                ForEach(ExportFormat.allCases) { f in
                    Button("\(f.rawValue)…") {
                        let n = Exporter.saveMany(chosen, as: f)
                        if n > 0 { app.toast = Toast("Exported \(n) transcript\(n == 1 ? "" : "s")") }
                    }
                }
                Divider()
                Button("Copy all to clipboard") {
                    let text = chosen.map { "\($0.title)\n\n" + Exporter.text($0, .saved) }.joined(separator: "\n\n———\n\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    app.toast = Toast("Copied \(chosen.count) transcripts")
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .menuStyle(.borderlessButton).fixedSize().disabled(selection.isEmpty)
            Button(role: .destructive) {
                let ids = Array(selection)
                let alert = NSAlert()
                alert.messageText = "Delete \(ids.count) transcript\(ids.count == 1 ? "" : "s")?"
                alert.informativeText = "Their audio is deleted too. This can't be undone."
                alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
                alert.buttons.first?.hasDestructiveAction = true
                if alert.runModal() == .alertFirstButtonReturn { app.delete(ids); selection = [] }
            } label: { Label("Delete", systemImage: "trash") }
            .buttonStyle(.plain).foregroundStyle(selection.isEmpty ? Ink.mute : Ink.coral).disabled(selection.isEmpty)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.white.opacity(0.55), in: Capsule())
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.ink.opacity(0.08)))
        .shadow(color: Ink.ink.opacity(0.12), radius: 16, y: 6)
    }
}
