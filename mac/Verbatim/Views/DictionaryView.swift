import SwiftUI

// The Dictionary on the refined kit (DESIGN.md §13) in both look settings: the large serif title with the count, the
// search field, Add word and the CSV menu; suggestions in a card; the words in a table on a card, the preferred
// spelling in semibold, and a switch per word.

/// Words Verbatim spells your way. Entries come from corrections you chose to remember, or from here.
struct DictionaryView: View {
    @EnvironmentObject var app: AppState
    @State private var filter = ""
    @State private var adding = false
    @State private var newPreferred = ""
    @State private var newHeard = ""
    /// nil = all words; .some(nil) = words for every transcript; .some(id) = one project's words.
    @State private var scope: UUID?? = nil
    @FocusState private var addFocused: Bool
    @Environment(\.limitMotion) private var limitMotion

    private var entries: [DictionaryEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return app.store.dictionary
            .filter { q.isEmpty || $0.preferred.lowercased().contains(q) || $0.heardAs.joined(separator: " ").lowercased().contains(q) }
            .filter { e in scope.map { e.projectId == $0 } ?? true }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        let count = app.store.dictionary.count
        let list = entries
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RefinedPageHeader(title: "Dictionary", count: count == 1 ? "1 word" : "\(count.formatted()) words",
                                  lede: "Right-click a word in any transcript, choose Correct, and turn on Remember. Fixes are listed on each transcript, so nothing changes silently.") {
                    addButton
                    // Import CSV… and Export CSV… (Views/TrustViews.swift).
                    DictionaryCSVMenu()
                }
                RefinedSearchField(text: $filter, prompt: count == 1 ? "Search 1 word" : "Search \(count.formatted()) words")
                    .frame(maxWidth: 360)

                // About me names, repeated fixes, and Contacts (VocabularyViews.swift).
                DictionarySuggestions()

                if !app.store.projects.isEmpty {
                    RefinedChipRow(label: "Where words apply") {
                        RefinedChip(title: "All", selected: scope == nil) { scope = nil }
                        RefinedChip(title: "Everywhere", selected: scope == .some(nil)) { scope = .some(nil) }
                        ForEach(app.store.projects) { p in RefinedChip(title: p.name, selected: scope == .some(p.id)) { scope = .some(p.id) } }
                    }
                }

                if adding {
                    addForm.transition(limitMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.98).combined(with: .opacity), removal: .identity))
                }

                if list.isEmpty {
                    emptyState
                } else {
                    table(list)
                }

                BuiltInVocabularySection()
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 18).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .softScrollEdges(.top)
        .background(Refined.paper)
        .animation(limitMotion ? Motion.fade : Motion.settle, value: adding)
        .onChange(of: app.store.projects) { _, ps in
            if case .some(.some(let id)) = scope, !ps.contains(where: { $0.id == id }) { scope = nil }
        }
    }

    private var addButton: some View {
        Button {
            adding.toggle()
            if adding { DispatchQueue.main.async { addFocused = true } }
        } label: { Label("Add word", systemImage: "plus") }
        .buttonStyle(RefinedActionStyle(kind: .strong))
        .help("Add a word Verbose should spell your way")
    }

    // MARK: Add

    /// The new word: the preferred spelling, how it's heard, then Add (Return) or Cancel.
    private var addForm: some View {
        HStack(spacing: 10) {
            field("Preferred spelling (Lititz)", text: $newPreferred).focused($addFocused)
            field("Heard as (Lit it's, Lititz's)", text: $newHeard)
            Button("Add") { add() }
                .buttonStyle(RefinedActionStyle(kind: .strong))
                .keyboardShortcut(.defaultAction)
            Button("Cancel") { adding = false }
                .buttonStyle(RefinedActionStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain).refinedFont(.body).foregroundStyle(Refined.ink)
            .padding(.horizontal, 10).frame(height: 32)
            .refinedFieldBox()
            .onSubmit { add() }
    }

    private func add() {
        let heard = newHeard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let p = newPreferred.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !heard.isEmpty else { return }
        // Added while a project is picked: the word belongs to that project.
        app.store.dictionary.append(DictionaryEntry(preferred: p, heardAs: heard, learnedFrom: "Added by you", projectId: scope ?? nil))
        newPreferred = ""; newHeard = ""
        adding = false
    }

    // MARK: Table

    private func table(_ list: [DictionaryEntry]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Preferred spelling").frame(width: DictionaryColumns.preferred, alignment: .leading)
                Text("Heard as").frame(maxWidth: .infinity, alignment: .leading)
                Text("Learned from").frame(width: DictionaryColumns.learned, alignment: .leading)
                Color.clear.frame(width: DictionaryColumns.toggle, height: 1)
            }
            .refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute).lineLimit(1)
            .padding(.horizontal, 20).frame(height: 36)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            PaperDivider(leading: 0)
            // Lazy: only the words on screen are built.
            LazyVStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                    DictionaryRow(entry: e)
                        .background(i.isMultiple(of: 2) ? Color.clear : Refined.stripe)
                }
            }
        }
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    @ViewBuilder private var emptyState: some View {
        if filter.trimmingCharacters(in: .whitespaces).isEmpty && scope == nil {
            RefinedEmptyState(art: .iconDictionary, hue: .petal, title: "No words yet",
                              message: "Brand names, people, and places are the usual suspects. Add them before a transcript, or fix them after.",
                              action: adding ? nil : "Add word") {
                adding = true
                DispatchQueue.main.async { addFocused = true }
            }
        } else if filter.trimmingCharacters(in: .whitespaces).isEmpty {
            RefinedEmptyState(art: .iconDictionary, hue: .petal, title: "No words here",
                              message: "Words added while this is picked belong to it.", action: "Show all") { scope = nil }
        } else {
            RefinedEmptyState(art: .search, title: "Nothing matches \u{201C}\(filter)\u{201D}",
                              message: "Try another spelling, or add it as a new word.", action: "Clear search") { filter = "" }
        }
    }
}

/// The table's column widths: the preferred spelling, Learned from, and the switch; Heard as takes the rest.
enum DictionaryColumns {
    static let preferred: CGFloat = 200
    static let learned: CGFloat = 250
    static let toggle: CGFloat = 40
}

/// One word: the preferred spelling in semibold, what it's heard as, where it came from ("Only in Lapp Wagons" with
/// the project's chip when it belongs to one), and the switch. Off, the row dims (the switch stays clear).
/// Right-click to move it to a project or delete it (with Undo).
struct DictionaryRow: View {
    @EnvironmentObject var app: AppState
    var entry: DictionaryEntry
    @State private var hover = false

    private func setProject(_ id: UUID?) {
        if let i = app.store.dictionary.firstIndex(where: { $0.id == entry.id }) { app.store.dictionary[i].projectId = id }
    }

    private var project: Project? {
        entry.projectId.flatMap { app.store.projectsByID[$0] }
    }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                WordPill(text: entry.preferred).frame(width: DictionaryColumns.preferred, alignment: .leading)
                Text(entry.heardAs.joined(separator: ", ")).refinedFont(.rowTitle).foregroundStyle(Refined.ink)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(entry.learnedFrom).refinedFont(.rowTitle).foregroundStyle(Refined.dim).lineLimit(1)
                    if let project {
                        KindColorChip(title: "Only in \(project.name)", hue: RefinedRules.projectHue(project.colorIndex))
                            .layoutPriority(1)
                    }
                }
                .frame(width: DictionaryColumns.learned, alignment: .leading)
            }
            .opacity(entry.enabled ? 1 : 0.45)
            Toggle("Use \(entry.preferred)", isOn: Binding(get: { entry.enabled }, set: { v in
                if let i = app.store.dictionary.firstIndex(where: { $0.id == entry.id }) { app.store.dictionary[i].enabled = v }
            }))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
            .refinedSwitchTint()
            .help(entry.enabled ? "On: new transcripts use this spelling" : "Off: kept, but not used")
            .frame(width: DictionaryColumns.toggle, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .frame(minHeight: 44)
        .background(hover ? Refined.stripe : Color.clear)
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
                app.toast = Toast("Removed \u{201C}\(removed.preferred)\u{201D}", action: "Undo") { [weak app] in app?.store.dictionary.append(removed) }
            }
        }
    }
}

/// A word's preferred spelling (the Dictionary's first column): semibold ink, one line.
struct WordPill: View {
    var text: String
    var body: some View {
        Text(text).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
    }
}
