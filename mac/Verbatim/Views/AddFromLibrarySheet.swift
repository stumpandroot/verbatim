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
    /// The Library's kind chips (Journal, Thoughts, Meetings, …), on top of the type chips (review M-20).
    @State private var kind: RecordingKind? = nil
    @State private var confirmMove = false

    private var projectName: String { app.store.projects.first { $0.id == project }?.name ?? "Project" }

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let candidates = ProjectAdd.candidates(app.store.transcripts, project: project, query: query) { app.store.searchText($0) }
        let typed = filter.apply(candidates, searching: searching)
        let shown = kind.map { k in typed.filter { $0.kind == k } } ?? typed
        let chosen = candidates.filter { selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add to \(projectName)").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Text(selection.isEmpty ? "From your library" : "\(selection.count) selected").refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            RefinedSearchField(text: $query, prompt: "Search titles, tags, and text")
            LibraryFilterBar(filter: $filter, items: candidates, searching: searching, wraps: true) { filter.save(LibraryFilter.addSheetKey) }
            kindChips(typed)
            list(shown)
            HStack(spacing: 8) {
                let ids = Set(shown.map(\.id))
                Button(!ids.isEmpty && ids.isSubset(of: selection) ? "Deselect all" : "Select all") {
                    if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
                }
                .buttonStyle(.plain).refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText).disabled(shown.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Add to \(projectName)" : "Add \(chosen.count) to \(projectName)") { add(chosen) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
                    .uiTarget("add-from-library-add")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 720, height: 620)
        .background(Refined.paper)
        .tint(Refined.accentText)
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
                    Text(query.isEmpty ? "Everything in your library is already in \(projectName)." : "Nothing found for \u{201C}\(query)\u{201D}.")
                        .refinedFont(.body).foregroundStyle(Refined.mute)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { PaperDivider(leading: 48, trailing: 14) }
                    row(t)
                }
            }
        }
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .animation(limitMotion ? Motion.fade : Motion.settle, value: shown.map(\.id))
    }

    private func row(_ t: Transcript) -> some View {
        let on = selection.contains(t.id)
        return PaperRowButton(selected: on, action: { if on { selection.remove(t.id) } else { selection.insert(t.id) } }) {
            HStack(spacing: 12) {
                RefinedCheckbox(on: on, size: 20).frame(width: 22)
                KindBadge(kind: t.kind, size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                    Text(Self.meta(t)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let other = t.projectId, let name = app.store.projects.first(where: { $0.id == other })?.name {
                    Text("Moves from \(name)").refinedFont(.chip, weight: .medium).foregroundStyle(Refined.dim)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Refined.neutral, in: Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .accessibilityLabel("\(t.title), \(LibraryFilter.describe(t))")
    }

    /// The Library's kinds that have something here, as chips; a second click clears one.
    @ViewBuilder private func kindChips(_ items: [Transcript]) -> some View {
        let counts = Dictionary(grouping: items.compactMap(\.kind), by: { $0 }).mapValues(\.count)
        let kinds = RecordingKind.pickable.filter { (counts[$0] ?? 0) > 0 || kind == $0 }
        if !kinds.isEmpty {
            FlowRow(spacing: 8, lineSpacing: 8) {
                ForEach(kinds, id: \.self) { k in
                    RefinedChip(title: "\(k.plural) \u{00B7} \(counts[k] ?? 0)", selected: kind == k) { kind = kind == k ? nil : k }
                }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Kind")
        }
    }

    /// The Library row's order: "Voice note · Thoughts · Oct 27 · 2:04", the year only when it isn't this year.
    static func meta(_ t: Transcript, now: Date = Date()) -> String {
        let style = HomeRecentStyle(t)
        var parts = [LibrarySource.isLink(t) && !t.sourceLabel.isEmpty ? t.sourceLabel : style.source]
        if let k = t.kind, k != .dictation { parts.append(k.label) }
        parts.append(HomeRecentStyle.day(t.createdAt, now: now))
        if t.duration > 0 { parts.append(HomeRecentStyle.length(t.duration)) }
        return parts.joined(separator: " · ")
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
