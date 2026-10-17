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
            return f && (q.isEmpty || t.title.lowercased().contains(q) || t.text.lowercased().contains(q))
        }
    }

    var body: some View {
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
                                    let ids = items.compactMap { $0.hasPrefix("verbatim-transcript:") ? UUID(uuidString: String($0.dropFirst(20))) : nil }
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
                        .draggable("verbatim-transcript:" + t.id.uuidString)   // drop onto a project chip
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

struct TrashScreen: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        List {
            if app.store.trash.isEmpty {
                Text("Nothing here.").foregroundStyle(Ink.mute).listRowBackground(Color.clear)
            }
            ForEach(app.store.trash) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(daysLeft(t)).font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
                .listRowBackground(Ink.card)
                .swipeActions(edge: .leading) { Button { app.restore(t.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(Ink.sageText) }
                .swipeActions(edge: .trailing) { Button(role: .destructive) { app.purge(t.id) } label: { Label("Delete now", systemImage: "trash") } }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Recently Deleted")
    }
    private func daysLeft(_ t: Transcript) -> String {
        guard let d = t.deletedAt else { return "" }
        let left = max(0, 30 - (Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0))
        return "\(left) day\(left == 1 ? "" : "s") left · swipe right to restore"
    }
}

/// Every timed note and bookmark across transcripts, with stills from kept video (made on the Mac).
struct MomentsScreen: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        let moments = app.store.live.flatMap { t in t.notes.filter { $0.at != nil }.map { Moment(t: t, n: $0) } }.sorted { $0.n.createdAt > $1.n.createdAt }
        ScrollView {
            if moments.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateArt(art: .bookmark, tint: Ink.butterTint)
                    Text("Bookmark a moment while a transcript plays, or long-press a line.").font(.system(size: 15)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                }
                .padding(40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(moments) { m in
                    let t = m.t, n = m.n
                    Button { app.open(t.id, segment: n.segmentId ?? t.segments.last { $0.start <= (n.at ?? 0) }?.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let f = n.frameFile { StillImage(file: f).frame(height: 96).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
                            HStack(spacing: 4) {
                                if n.isBookmark { Image(systemName: "bookmark.fill").font(.system(size: 10)) }
                                Text((n.at ?? 0).timecode).font(Ink.mono(11.5))
                            }
                            .foregroundStyle(n.isBookmark ? Ink.sageText : Ink.accentText)
                            Text(n.text).font(.system(size: 14)).foregroundStyle(Ink.ink).lineLimit(4).multilineTextAlignment(.leading)
                            Text(t.title).font(Ink.serif(13)).foregroundStyle(Ink.mute).lineLimit(1)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(n.isBookmark ? Ink.butterTint : n.segmentId != nil ? Ink.petalTint : Ink.persimmonTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let info = t.linkInfo, info.supportsTimestamps, let u = info.url(at: n.at ?? 0) { Link(destination: u) { Label("Open video", systemImage: "play.rectangle") } }
                        Button(role: .destructive) { app.deleteNote(t.id, note: n.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Moments")
    }
}

struct Moment: Identifiable { let t: Transcript; let n: Note; var id: UUID { n.id } }

/// Settings: iCloud status, transcription quality, appearance, and the Dictionary.
struct SettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        Form {
            Section("Sync") {
                Label(Cloud.enabled ? "Syncing with iCloud" : "iCloud is off", systemImage: Cloud.enabled ? "icloud" : "icloud.slash")
                Text(Cloud.enabled ? "Transcripts, notes, bookmarks, projects, and the Dictionary match your Mac. Audio from the other device downloads when you play it." : "Sign in to iCloud in the Settings app to sync with your Mac. Until then, everything stays on this iPhone.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
            Section("Transcription") {
                Picker("Quality", selection: $app.presetRaw) {
                    ForEach(QualityPreset.allCases.filter { $0 != .advanced }) { p in Text(p.title).tag(p.rawValue) }
                }
                Toggle("Identify speakers", isOn: $app.identifySpeakers).tint(Ink.switchOn)
                Toggle("Apply Dictionary", isOn: $app.applyDictionary).tint(Ink.switchOn)
                Text("Transcription runs on this iPhone. The first time, the model downloads once (about 200–600 MB). Links are fetched by your Mac.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
            Section("Appearance") {
                Picker("Appearance", selection: $app.appearance) {
                    Text("Match the system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
            }
            Section("Welcome tour") {
                Toggle("Show it when Verbatim opens", isOn: Binding(get: { Onboarding.showOnLaunch }, set: { Onboarding.showOnLaunch = $0; app.objectWillChange.send() }))
                    .tint(Ink.switchOn)
                Button("Show Tour") { app.showOnboarding = true }
            }
            Section("Dictionary") {
                NavigationLink { DictionaryScreen() } label: { LabeledContent("Words", value: "\(app.store.dictionary.count)") }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            } footer: { Text("Verbatim · Stump & Root Co.") }
        }
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Settings")
    }
}

struct DictionaryScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var preferred = ""
    @State private var heard = ""
    var body: some View {
        List {
            Section("Add a word") {
                TextField("Preferred spelling (Lititz)", text: $preferred)
                TextField("Heard as (Lit it's, Lititz's)", text: $heard)
                Button("Add") {
                    let h = heard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let p = preferred.trimmingCharacters(in: .whitespaces)
                    guard !p.isEmpty, !h.isEmpty else { return }
                    app.store.dictionary.append(DictionaryEntry(preferred: p, heardAs: h, learnedFrom: "Added on iPhone"))
                    preferred = ""; heard = ""
                }
            }
            Section("Words") {
                ForEach(app.store.dictionary) { e in
                    Toggle(isOn: Binding(get: { e.enabled }, set: { v in if let i = app.store.dictionary.firstIndex(where: { $0.id == e.id }) { app.store.dictionary[i].enabled = v } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.preferred).font(.system(size: 16, weight: .semibold))
                            Text(e.heardAs.joined(separator: ", ")).font(.system(size: 13)).foregroundStyle(Ink.mute)
                        }
                    }
                    .tint(Ink.switchOn)
                }
                .onDelete { idx in app.store.dictionary.remove(atOffsets: idx) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Dictionary")
    }
}
