import SwiftUI

/// Words Verbatim spells your way. Entries come from corrections you chose to remember, or from here.
struct DictionaryView: View {
    @EnvironmentObject var app: AppState
    @State private var filter = ""
    @State private var adding = false
    @State private var newPreferred = ""
    @State private var newHeard = ""
    /// nil = all words; .some(nil) = words for every transcript; .some(id) = one project's words.
    @State private var scope: UUID?? = nil

    private var entries: [DictionaryEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return app.store.dictionary
            .filter { q.isEmpty || $0.preferred.lowercased().contains(q) || $0.heardAs.joined(separator: " ").lowercased().contains(q) }
            .filter { e in scope.map { e.projectId == $0 } ?? true }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Dictionary").font(.system(size: 28, weight: .bold)).foregroundStyle(Ink.ink)
                Text("Right-click a word in any transcript, choose Correct, and turn on Remember. From then on, every new transcript gets it right. Fixes are listed on each transcript so nothing changes silently.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim).frame(maxWidth: 560, alignment: .leading).padding(.top, 4).padding(.bottom, 18)

                // About me names, repeated fixes, and Contacts (VocabularyViews.swift).
                DictionarySuggestions()

                HStack(spacing: 8) {
                    TextField("Search \(app.store.dictionary.count) words", text: $filter).textFieldStyle(.roundedBorder)
                    Button { adding.toggle() } label: { Label("Add word", systemImage: "plus") }.buttonStyle(.brandPrimary)
                    // Import CSV… and Export CSV… (Views/TrustViews.swift).
                    DictionaryCSVMenu()
                }
                .padding(.bottom, 10)

                if !app.store.projects.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            SiteChip(label: "All", on: scope == nil) { scope = nil }
                            SiteChip(label: "Everywhere", on: scope == .some(nil)) { scope = .some(nil) }
                            ForEach(app.store.projects) { p in SiteChip(label: p.name, on: scope == .some(p.id)) { scope = .some(p.id) }.fixedSize() }
                        }
                    }
                    .padding(.bottom, 12)
                }

                if adding {
                    HStack(spacing: 8) {
                        TextField("Preferred spelling (Lititz)", text: $newPreferred).textFieldStyle(.roundedBorder)
                        TextField("Heard as (Lit it's, Lititz's)", text: $newHeard).textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let heard = newHeard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            let p = newPreferred.trimmingCharacters(in: .whitespaces)
                            guard !p.isEmpty, !heard.isEmpty else { return }
                            // Added while a project is picked: the word belongs to that project.
                            app.store.dictionary.append(DictionaryEntry(preferred: p, heardAs: heard, learnedFrom: "Added by you", projectId: scope ?? nil))
                            newPreferred = ""; newHeard = ""; adding = false
                        }
                        .buttonStyle(.brandPrimary).keyboardShortcut(.defaultAction)
                        Button("Cancel") { adding = false }
                    }
                    .padding(12).cardSurface(radius: 10)
                    .padding(.bottom, 12)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .identity))
                }

                if entries.isEmpty {
                    VStack(spacing: 10) {
                        if filter.isEmpty { IconPlate(art: .iconDictionary, size: 96) } else { EmptyStateArt(art: .search, tint: Ink.petalTint) }
                        Text(filter.isEmpty ? "No words yet" : "Nothing matches “\(filter)”").font(.system(size: 15, weight: .semibold))
                        if filter.isEmpty {
                            Text("Brand names, people, and places are the usual suspects. Add them before a transcript, or fix them after.")
                                .font(.system(size: 13)).foregroundStyle(Ink.mute).multilineTextAlignment(.center).frame(maxWidth: 380)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 50)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Preferred spelling").frame(width: 180, alignment: .leading)
                            Text("Heard as").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Learned from").frame(width: 200, alignment: .leading)
                            Text("").frame(width: 40)
                        }
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Ink.mute)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        Divider()
                        ForEach(entries) { e in
                            DictionaryRow(entry: e)
                            Divider().opacity(0.5)
                        }
                    }
                    .cardSurface(radius: 12)
                    .tiltCard(lift: 1, radius: 12, rotates: false)
                }

                BuiltInVocabularySection()
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 40).padding(.top, 36).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .animation(Motion.settle, value: adding)
        .onChange(of: app.store.projects) { _, ps in
            if case .some(.some(let id)) = scope, !ps.contains(where: { $0.id == id }) { scope = nil }
        }
    }
}

struct DictionaryRow: View {
    @EnvironmentObject var app: AppState
    var entry: DictionaryEntry
    @State private var hover = false

    private func setProject(_ id: UUID?) {
        if let i = app.store.dictionary.firstIndex(where: { $0.id == entry.id }) { app.store.dictionary[i].projectId = id }
    }

    var body: some View {
        HStack {
            Pill(text: entry.preferred).frame(width: 180, alignment: .leading)
            Text(entry.heardAs.joined(separator: ", ")).font(.system(size: 13)).foregroundStyle(Ink.dim).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.learnedFrom).font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
                if let pid = entry.projectId, let p = app.store.projects.first(where: { $0.id == pid }) {
                    Text("Only in \(p.name)").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.iris)
                }
            }
            .frame(width: 200, alignment: .leading)
            Toggle("", isOn: Binding(get: { entry.enabled }, set: { v in
                if let i = app.store.dictionary.firstIndex(where: { $0.id == entry.id }) { app.store.dictionary[i].enabled = v }
            })).toggleStyle(.switch).controlSize(.small).labelsHidden().frame(width: 40)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(hover ? Ink.cardHover : .clear)
        .opacity(entry.enabled ? 1 : 0.55)
        .onHover { hover = $0 }
        .contextMenu {
            if !app.store.projects.isEmpty {
                Menu("Use In") {
                    Button("Every transcript") { setProject(nil) }
                    ForEach(app.store.projects) { p in Button("Only \(p.name)") { setProject(p.id) } }
                }
                Divider()
            }
            Button("Delete", role: .destructive) {
                let removed = entry
                app.store.dictionary.removeAll { $0.id == entry.id }
                app.toast = Toast("Removed “\(removed.preferred)”", action: "Undo") { [weak app] in app?.store.dictionary.append(removed) }
            }
        }
    }
}
