import SwiftUI

/// Add from Library: pick transcripts already in your library and add them to a project, instead of importing files
/// again. Lists everything not in Recently Deleted and not already in the project, with search (title, tags, and text),
/// the Library's type and platform chips, and checkboxes. A transcript is in one project at a time, so one from
/// another project says where it moves from, and adding asks first.
struct AddFromLibrarySheet: View {
    @EnvironmentObject var app: AppState
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add to \(projectName)").font(Ink.serif(28)).foregroundStyle(Ink.ink).lineLimit(1)
                Spacer(minLength: 12)
                Overline(text: selection.isEmpty ? "From your library" : "\(selection.count) selected", color: Ink.mute)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.mute)
                TextField("Search titles, tags, and text", text: $query).textFieldStyle(.plain).font(.system(size: 14))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Ink.mute)
                        .help("Clear the search")
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .cardSurface(radius: Radius.button)
            LibraryFilterBar(filter: $filter, items: candidates, searching: searching, wraps: true) { filter.save(LibraryFilter.addSheetKey) }
            list(shown)
            HStack(spacing: 8) {
                let ids = Set(shown.map(\.id))
                Button(!ids.isEmpty && ids.isSubset(of: selection) ? "Deselect all" : "Select all") {
                    if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
                }
                .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.iris).disabled(shown.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SheetButtonStyle()).frame(width: 110).keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Add to \(projectName)" : "Add \(chosen.count) to \(projectName)") { add(chosen) }
                    .buttonStyle(SheetButtonStyle(primary: true)).frame(minWidth: 180).fixedSize()
                    .keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
                    .uiTarget("add-from-library-add")
            }
        }
        .padding(24)
        .frame(width: 720, height: 620)
        .background(Ink.paper)
        .confirmationDialog(moveTitle(chosen), isPresented: $confirmMove) {
            Button("Move and add") { commit(chosen) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A transcript is in one project at a time. \(moveSources(chosen)) moves to \(projectName).")
        }
    }

    private func list(_ shown: [Transcript]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if shown.isEmpty {
                    Text(query.isEmpty ? "Everything in your library is already in \(projectName)." : "Nothing found for “\(query)”.")
                        .font(.system(size: 14)).foregroundStyle(Ink.mute)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 46) }
                    row(t)
                }
            }
        }
        .cardSurface(radius: Radius.row)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .animation(limitMotion ? Motion.fade : Motion.settle, value: shown.map(\.id))
    }

    private func row(_ t: Transcript) -> some View {
        let on = selection.contains(t.id)
        return Button { if on { selection.remove(t.id) } else { selection.insert(t.id) } } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17)).foregroundStyle(on ? Ink.ink : Ink.mute).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(LibraryFilter.describe(t))
                        Text("·")
                        Text(Formats.style(date: .medium, time: .none).string(from: t.createdAt))
                        if t.duration > 0 { Text("·"); Text(t.duration.timecode) }
                    }
                    .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Ink.mute).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let other = t.projectId, let name = app.store.projects.first(where: { $0.id == other })?.name {
                    Text("Moves from \(name)").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.dim)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Ink.ink.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(on ? Ink.ink.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(t.title), \(LibraryFilter.describe(t))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func add(_ chosen: [Transcript]) {
        let plan = ProjectAdd.plan(chosen.map(\.id), in: app.store.transcripts, to: project)
        if ProjectAdd.moves(plan).isEmpty { commit(chosen) } else { confirmMove = true }
    }

    private func commit(_ chosen: [Transcript]) {
        app.addToProject(chosen.map(\.id), project)
        dismiss()
    }

    private func moving(_ chosen: [Transcript]) -> [Transcript] { chosen.filter { $0.projectId != nil && $0.projectId != project } }

    private func moveTitle(_ chosen: [Transcript]) -> String {
        let n = moving(chosen).count
        return n == 1 ? "Move 1 transcript from another project?" : "Move \(n) transcripts from other projects?"
    }

    /// "Lapp Wagons" or "Lapp Wagons and Field notes": where the moving transcripts are now.
    private func moveSources(_ chosen: [Transcript]) -> String {
        let n = moving(chosen).count
        let names = Array(Set(moving(chosen).compactMap { t in app.store.projects.first { $0.id == t.projectId }?.name })).sorted()
        let from = names.count <= 2 ? names.joined(separator: " and ") : "\(names.count) projects"
        return n == 1 ? "The one from \(from)" : "Each one from \(from)"
    }
}
