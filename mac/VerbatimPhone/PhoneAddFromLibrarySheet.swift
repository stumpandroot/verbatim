import SwiftUI

/// Add from Library on iPhone: a searchable list of transcripts not in Recently Deleted and not already in the project,
/// with the Library's type and platform chips, tap to select, and an Add button. A transcript is in one project at a
/// time, so one from another project says where it moves from, and adding asks first.
struct PhoneAddFromLibrarySheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.limitMotion) private var limitMotion
    var project: UUID
    @State private var query = ""
    @State private var filter = LibraryFilter.saved(LibraryFilter.addSheetKey)
    @State private var selection: Set<UUID> = []
    @State private var confirmMove = false

    private var projectName: String { app.store.projects.first { $0.id == project }?.name ?? "Project" }

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let candidates = ProjectAdd.candidates(app.store.transcripts, project: project, query: query) { app.store.searchText($0) }
        let shown = filter.apply(candidates, searching: searching)
        let chosen = candidates.filter { selection.contains($0.id) }
        let moving = chosen.filter { $0.projectId != nil }
        NavigationStack {
            List {
                Section {
                    LibraryFilterBar(filter: $filter, items: candidates, searching: searching, wraps: false) { filter.save(LibraryFilter.addSheetKey) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section {
                    if shown.isEmpty {
                        Text(query.isEmpty ? "Everything in your library is already in \(projectName)." : "Nothing matches “\(query)”.")
                            .font(.system(size: 15)).foregroundStyle(Ink.dim)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    ForEach(shown) { t in
                        row(t)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Ink.paper.ignoresSafeArea())
            .animation(limitMotion ? Motion.fade : Motion.settle, value: shown.map(\.id))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles, tags, and text")
            .navigationTitle("Add to \(projectName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.isEmpty ? "Add" : "Add \(chosen.count)") {
                        if moving.isEmpty { commit(chosen) } else { confirmMove = true }
                    }
                    .fontWeight(.semibold).disabled(chosen.isEmpty)
                }
            }
            .confirmationDialog(moving.count == 1 ? "Move 1 transcript from another project?" : "Move \(moving.count) transcripts from other projects?",
                                isPresented: $confirmMove, titleVisibility: .visible) {
                Button("Move and add to \(projectName)") { commit(chosen) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("A transcript is in one project at a time. Adding moves it out of the project it's in.")
            }
        }
        .tint(Ink.ink)
    }

    private func row(_ t: Transcript) -> some View {
        let on = selection.contains(t.id)
        return Button {
            if on { selection.remove(t.id) } else { selection.insert(t.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(on ? Ink.ink : Ink.mute)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(LibraryFilter.describe(t))
                        if t.duration > 0 { Text("·"); Text(t.duration.timecode).font(Ink.mono(12.5)) }
                    }
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).lineLimit(1)
                    if let other = t.projectId, let name = app.store.projects.first(where: { $0.id == other })?.name {
                        Text("Moves from \(name)").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.dim)
                    }
                }
                Spacer(minLength: 6)
                Text(Formats.style(date: .short, time: .none).string(from: t.createdAt)).font(Ink.mono(12)).foregroundStyle(Ink.mute)
            }
            .padding(12)
            .cardSurface(radius: Radius.row, fill: on ? Ink.ink.opacity(0.06) : Ink.card)
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func commit(_ chosen: [Transcript]) {
        app.addToProject(chosen.map(\.id), project)
        dismiss()
    }
}
