import SwiftUI

/// Add from Library on iPhone: a searchable list of transcripts not in Recently Deleted and not already in the project,
/// built like the Library (its soft type and platform chips, mono day headers, and flat rows with a leading check),
/// tap to select, and an Add button. A transcript is in one project at a
/// time, so one from another project says where it moves from, and adding asks first.
struct PhoneAddFromLibrarySheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look
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
                    chips(candidates, searching: searching)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section {
                    if shown.isEmpty {
                        Text(query.isEmpty ? "Everything in your library is already in \(projectName)." : "Nothing matches “\(query)”.")
                            .font(.system(size: 15)).foregroundStyle(.lookDim)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    ForEach(Self.days(shown), id: \.day) { group in
                        PhoneDayHeader(text: PhoneDayHeader.label(group.day))
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        ForEach(group.items) { t in
                            row(t)
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .phonePage()
            .animation(limitMotion ? Motion.fade : Motion.settle, value: shown.map(\.id))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: look.isNative ? "Search your library" : "Find the line you need")
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

    /// The Library's chips: All and each type the candidates have, then platforms for Videos and Links.
    private func chips(_ candidates: [Transcript], searching: Bool) -> some View {
        let sources = filter.sourceCounts(candidates, searching: searching).filter { $0.0 != .all }.map(\.0)
        let platforms = filter.platformCounts(candidates, searching: searching)
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PhoneChip(label: "All", selected: filter == .all) { setFilter(.all) }
                    ForEach(sources) { s in
                        PhoneChip(label: s.label, selected: filter.source == s, dot: LibraryScreen.dot(s)) {
                            setFilter(filter.source == s ? .all : LibraryFilter(source: s))
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            if filter.source.hasPlatforms, !platforms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(platforms, id: \.0) { p, n in
                            PhoneChip(label: p, selected: filter.platform == p, count: n) {
                                setFilter(LibraryFilter(source: filter.source, platform: filter.platform == p ? nil : p))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .accessibilityElement(children: .contain).accessibilityLabel("Platform")
            }
        }
    }

    private func setFilter(_ f: LibraryFilter) {
        guard f != filter else { return }
        filter = f
        filter.save(LibraryFilter.addSheetKey)
    }

    /// The candidates by day, newest day first, keeping their order inside each day.
    static func days(_ items: [Transcript]) -> [(day: Date, items: [Transcript])] {
        let cal = Calendar.current
        var out: [(day: Date, items: [Transcript])] = []
        for t in items {
            let d = cal.startOfDay(for: t.createdAt)
            if let last = out.indices.last, out[last].day == d { out[last].items.append(t) } else { out.append((d, [t])) }
        }
        return out
    }

    /// A Library row with a check in front: tap to choose it. One from another project says where it moves from.
    private func row(_ t: Transcript) -> some View {
        let on = selection.contains(t.id)
        var meta = LibraryScreen.meta(t)
        if let other = t.projectId, let name = app.store.projects.first(where: { $0.id == other })?.name { meta += " · Moves from \(name)" }
        return Button {
            if on { selection.remove(t.id) } else { selection.insert(t.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(on ? Ink.ink : Ink.mute)
                    .accessibilityHidden(true)
                PhoneFlatRow(transcript: t, serif: false, meta: meta) {
                    if t.duration > 0 { Text(HomeRecentStyle.length(t.duration)).font(Ink.mono(12)).foregroundStyle(.lookDim) }
                }
            }
            .contentShape(Rectangle())
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
