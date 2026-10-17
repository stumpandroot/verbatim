import SwiftUI

/// Every transcript, searchable, with filter chips for pinned, links, in progress, and each project.
struct LibraryScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var newProject = false
    @State private var projectName = ""

    enum Filter: Hashable { case all, pinned, links, working, project(UUID) }

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
                }
            }()
            return f && (q.isEmpty || t.title.lowercased().contains(q) || app.store.searchText(t).contains(q))
        }
    }

    var body: some View {
        // `items` searches every transcript's text; work it out once per render.
        let items = self.items
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", .all)
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
            Section {
                if items.isEmpty {
                    HStack(spacing: 14) {
                        EmptyStateArt(art: search.isEmpty ? .library : .search, tint: Ink.butterTint)
                        Text(search.isEmpty ? "Nothing here yet." : "Nothing matches “\(search)”.").font(.system(size: 15)).foregroundStyle(Ink.dim)
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(items) { t in
                    Button { app.open(t.id) } label: { PhoneRow(transcript: t) }
                        .buttonStyle(.plain)
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Library")
        .searchable(text: $search, prompt: "Find the line you need")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { TrashScreen() } label: { Image(systemName: "trash") }.accessibilityLabel("Recently Deleted")
            }
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
