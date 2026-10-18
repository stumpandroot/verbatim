import SwiftUI

/// Every transcript, searchable, with filter chips for pinned, links, in progress, and each project.
struct LibraryScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var newProject = false
    @State private var projectName = ""
    /// Rows rise in once; the first screenful staggers when you switch to Library.
    @State private var seen = SeenRows()
    @State private var entrance = 0

    enum Filter: Hashable { case all, pinned, links, working, project(UUID), kind(RecordingKind) }

    private var items: [Transcript] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return app.store.live.filter { t in
            let f: Bool = {
                switch filter {
                case .all: return true
                case .pinned: return t.pinned
                case .links: return t.linkInfo != nil || t.source == .link
                case .working: return t.status == .processing
                case .project(let p): return t.projectId == p
                case .kind(let k): return t.kind == k
                }
            }()
            return f && (q.isEmpty || t.title.lowercased().contains(q) || app.store.searchText(t).contains(q))
        }
    }

    var body: some View {
        // `items` searches every transcript's text; work it out once per render.
        let items = self.items
        let heroKind: RecordingKind? = { if case .kind(let k) = filter { return k }; return nil }()
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", .all)
                        ForEach(RecordingKind.allCases) { k in chip(k.plural, .kind(k)) }
                        chip("Pinned", .pinned)
                        chip("Links", .links)
                        chip("In progress", .working)
                        ForEach(app.store.projects) { p in
                            chip(p.name, .project(p.id))
                                .dropDestination(for: String.self) { items, _ in
                                    let ids = items.flatMap { TranscriptDrag.ids(from: $0) }
                                    guard !ids.isEmpty else { return false }
                                    for id in ids { app.move(id, to: p.id) }
                                    app.say(ids.count == 1 ? "Moved to \(p.name)" : "Moved \(ids.count) to \(p.name)")
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    return true
                                }
                        }
                        Button { newProject = true } label: { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32) }
                            .buttonStyle(TactileButtonStyle()).accessibilityLabel("New project")
                    }
                    .padding(.horizontal, 20)
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if let k = heroKind {
                Section {
                    KindHeroCard(kind: k, meta: heroMeta(k, items))
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            if filter == .kind(.journal), !items.isEmpty {
                ForEach(JournalDays.group(items)) { day in
                    Section {
                        EditorialSectionHeader(index: day.date.uppercased(), label: day.label)
                            .padding(.top, 10)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 2, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        ForEach(day.entries) { t in
                            Button { app.open(t.id) } label: { journalCard(t) }
                                .buttonStyle(SoftPress())
                                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contextMenu { RowActions(transcript: t) }
                        }
                    }
                }
            } else {
            Section {
                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if search.isEmpty { IconPlate(art: .iconLibrary, size: 96) } else { EmptyStateArt(art: .search, tint: Ink.butterTint) }
                        Text(search.isEmpty ? "Nothing here yet." : "Nothing matches “\(search)”.").font(.system(size: 15)).foregroundStyle(Ink.dim)
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    Button { app.open(t.id) } label: { PhoneRow(transcript: t) }
                        .buttonStyle(SoftPress())
                        .riseIn(t.id, index: i, seen: seen, epoch: entrance, scrollRise: search.isEmpty)   // typing never animates rows
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .contextMenu { RowActions(transcript: t) }
                        .draggable(TranscriptDrag.payload([t.id]))   // drop onto a project chip
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { app.delete([t.id]) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { app.togglePin(t.id) } label: { Label(t.pinned ? "Unpin" : "Pin", systemImage: "pin") }.tint(Ink.sageText)
                        }
                }
            }
            }
        }
        .listStyle(.plain)
        .tabEntrance(.library) { seen.entered(); entrance += 1 }
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Library")
        .searchable(text: $search, prompt: "Find the line you need")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { TrashScreen() } label: { Image(systemName: "trash") }.accessibilityLabel("Recently Deleted")
            }
        }
        .onReceive(app.$libraryFilterRequest) { r in
            // The screenshot tour (and anything else) can open Library on a kind, or back on All.
            guard let r else { return }
            filter = RecordingKind(rawValue: r).map { .kind($0) } ?? .all
            app.libraryFilterRequest = nil
        }
        .alert("New project", isPresented: $newProject) {
            TextField("Name", text: $projectName)
            Button("Cancel", role: .cancel) { projectName = "" }
            Button("Create") {
                let n = projectName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { filter = .project(app.store.addProject(n).id) }
                projectName = ""
            }
        }
    }

    private func heroMeta(_ k: RecordingKind, _ list: [Transcript]) -> String {
        if k == .journal {
            let week = Date().addingTimeInterval(-7 * 86_400)
            return "\(list.filter { $0.createdAt >= week }.count) this week"
        }
        return list.count == 1 ? "1 saved" : "\(list.count) saved"
    }

    /// A Journal entry: title, time, and the opening lines, in the row-card form.
    private func journalCard(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(t.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(2)
                Spacer(minLength: 4)
                Text(Formats.pattern("h:mm a").string(from: t.createdAt)).font(Ink.mono(12.5)).foregroundStyle(Ink.mute)
            }
            Text(JournalDays.preview(t)).font(.system(size: 15)).foregroundStyle(Ink.dim).lineSpacing(2).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .cardSurface(radius: 14)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func chip(_ label: String, _ f: Filter) -> some View {
        Button { withAnimation(Motion.snap) { filter = f } } label: {
            Text(label).font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14).frame(height: 32)
                .foregroundStyle(filter == f ? Ink.onInteractive : Ink.ink)
                .background(filter == f ? Ink.interactive : Ink.card, in: Capsule())
                .overlay(Capsule().strokeBorder(filter == f ? Color.clear : Ink.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == f ? .isSelected : [])
    }
}
