import SwiftUI

/// Add from Library on iPhone: a searchable list of transcripts not in Recently Deleted and not already in the project,
/// built like the Library on the refined kit (DESIGN.md §13): the kit's type and platform chips,
/// serif day titles, and each day's rows in a card with a leading check; tap to select, and an Add button. A transcript is in one project at a
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
                    chips(candidates, searching: searching)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section {
                    if shown.isEmpty {
                        Text(query.isEmpty ? "Everything in your library is already in \(projectName)." : "Nothing matches “\(query)”.")
                            .refinedFont(.body).foregroundStyle(Refined.dim)
                            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    ForEach(Self.days(shown), id: \.day) { group in
                        SectionTitle(DayLabel.title(group.day))
                            .padding(.top, 18).padding(.bottom, 8)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { i, t in
                            row(t)
                                .overlay(alignment: .top) { if i > 0 { PaperDivider(leading: 92) } }
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                .listRowBackground(PaperRowBackground(first: i == 0, last: i == group.items.count - 1))
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .background(Refined.paper.ignoresSafeArea())
            .animation(limitMotion ? Motion.fade : Motion.settle, value: shown.map(\.id))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your library")
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
        .tint(Refined.accentText)
    }

    /// The Library's chips: All and each type the candidates have, then platforms for Videos and Links.
    private func chips(_ candidates: [Transcript], searching: Bool) -> some View {
        let sources = filter.sourceCounts(candidates, searching: searching).filter { $0.0 != .all }.map(\.0)
        let platforms = filter.platformCounts(candidates, searching: searching)
        return VStack(alignment: .leading, spacing: 8) {
            RefinedChipRow(label: "Filter", margin: 20) {
                RefinedChip(title: "All", selected: filter == .all) { setFilter(.all) }
                ForEach(sources) { s in
                    RefinedChip(title: s.label, selected: filter.source == s) {
                        setFilter(filter.source == s ? .all : LibraryFilter(source: s))
                    }
                }
            }
            if filter.source.hasPlatforms, !platforms.isEmpty {
                RefinedChipRow(label: "Platform", margin: 20) {
                    ForEach(platforms, id: \.0) { p, n in
                        RefinedChip(title: "\(p) · \(n)", selected: filter.platform == p) {
                            setFilter(LibraryFilter(source: filter.source, platform: filter.platform == p ? nil : p))
                        }
                    }
                }
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
                RefinedCheckbox(on: on, size: 22)
                    .frame(width: 44, height: 44)
                PaperRow(kind: t.refinedKind, title: RecordingRowTitle.title(t, withTime: false), meta: meta, badge: 32, pinned: false) {
                    if t.duration > 0 { RowLength(text: HomeRecentStyle.length(t.duration)) }
                }
            }
            .padding(.leading, 4)
            .background(on ? Refined.persimmonTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(RefinedRowPress())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func commit(_ chosen: [Transcript]) {
        app.addToProject(chosen.map(\.id), project)
        dismiss()
    }
}
