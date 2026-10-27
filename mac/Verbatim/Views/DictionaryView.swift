import SwiftUI

// brand: web style
//
// The Dictionary in the website style (mac/DESIGN.md §11): a compact title with the count, the search field, an
// "Add word" dark pill and the CSV line pill; suggestions on a butter panel; the words in a paper table with an ink
// outline, mono column heads, the preferred spelling as a serif outlined pill, and an ink switch per word.

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
        GeometryReader { geo in
            let narrow = geo.size.width < 900
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitle(title: "Dictionary", count: count == 1 ? "1 word" : "\(count.formatted()) words",
                              lede: "Right-click a word in any transcript, choose Correct, and turn on Remember. Fixes are listed on each transcript, so nothing changes silently.") {
                        HStack(spacing: 10) {
                            if !narrow { search(count).frame(width: 220) }
                            addButton
                            // Import CSV… and Export CSV… (Views/TrustViews.swift).
                            DictionaryCSVMenu()
                        }
                    }
                    .staggerIn(0)
                    if narrow { search(count).padding(.top, 14) }

                    // About me names, repeated fixes, and Contacts (VocabularyViews.swift).
                    DictionarySuggestions().padding(.top, 22).staggerIn(1)

                    if !app.store.projects.isEmpty {
                        FlowRow(spacing: 8, lineSpacing: 8) {
                            FilterChip(title: "All", selected: scope == nil) { scope = nil }
                            FilterChip(title: "Everywhere", selected: scope == .some(nil)) { scope = .some(nil) }
                            ForEach(app.store.projects) { p in FilterChip(title: p.name, selected: scope == .some(p.id)) { scope = .some(p.id) } }
                        }
                        .padding(.top, 18)
                    }

                    if adding {
                        addForm.padding(.top, 18)
                            .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .identity))
                    }

                    if list.isEmpty {
                        emptyState.padding(.top, 18)
                    } else {
                        table(list).padding(.top, 18).staggerIn(2)
                    }

                    BuiltInVocabularySection()
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(Motion.settle, value: adding)
        .onChange(of: app.store.projects) { _, ps in
            if case .some(.some(let id)) = scope, !ps.contains(where: { $0.id == id }) { scope = nil }
        }
    }

    private func search(_ count: Int) -> some View {
        WebSearchField(text: $filter, prompt: count == 1 ? "Search 1 word" : "Search \(count.formatted()) words", height: 36)
    }

    private var addButton: some View {
        Button {
            withAnimation(Motion.settle) { adding.toggle() }
            if adding { DispatchQueue.main.async { addFocused = true } }
        } label: {
            HStack(spacing: 8) {
                ArtIcon(art: .webPlus, size: 16, lineWidth: 1.5)
                Text("Add word")
            }
        }
        .buttonStyle(PillButtonStyle(kind: .dark, size: .regular))
        .help("Add a word Verbose should spell your way")
    }

    // MARK: Add

    /// The new word: the preferred spelling, how it's heard, then Add (Return) or Cancel.
    private var addForm: some View {
        HStack(spacing: 10) {
            field("Preferred spelling (Lititz)", text: $newPreferred).focused($addFocused)
            field("Heard as (Lit it's, Lititz's)", text: $newHeard)
            Button("Add") { add() }
                .buttonStyle(PillButtonStyle(kind: .dark, size: .mini))
                .keyboardShortcut(.defaultAction)
            Button("Cancel") { withAnimation(Motion.settle) { adding = false } }
                .buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        .inkEdge(outline: true, radius: Radius.record)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(Ink.ink)
            .padding(.horizontal, 14).frame(height: 32)
            .background(Ink.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5))
            .onSubmit { add() }
    }

    private func add() {
        let heard = newHeard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let p = newPreferred.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !heard.isEmpty else { return }
        // Added while a project is picked: the word belongs to that project.
        app.store.dictionary.append(DictionaryEntry(preferred: p, heardAs: heard, learnedFrom: "Added by you", projectId: scope ?? nil))
        newPreferred = ""; newHeard = ""
        withAnimation(Motion.settle) { adding = false }
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
            .font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1)
            .padding(.horizontal, 20).frame(height: 40)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Ink.hairline).frame(height: 1)
            // Lazy: only the words on screen are built.
            LazyVStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                    DictionaryRow(entry: e)
                    if i < list.count - 1 { Rectangle().fill(Ink.hairline).frame(height: 1) }
                }
            }
        }
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        .inkEdge(outline: true, radius: Radius.record)
    }

    @ViewBuilder private var emptyState: some View {
        if filter.trimmingCharacters(in: .whitespaces).isEmpty && scope == nil {
            EmptyStateCard(art: .iconDictionary, title: "No words yet",
                           message: "Brand names, people, and places are the usual suspects. Add them before a transcript, or fix them after.",
                           button: adding ? nil : "Add word") {
                withAnimation(Motion.settle) { adding = true }
                DispatchQueue.main.async { addFocused = true }
            }
        } else if filter.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyStateCard(art: .iconDictionary, title: "No words here",
                           message: "Words added while this is picked belong to it.", button: "Show all") { scope = nil }
        } else {
            EmptyStateCard(art: .search, title: "Nothing matches “\(filter)”",
                           message: "Try another spelling, or add it as a new word.", button: "Clear search") { filter = "" }
        }
    }
}

/// The table's column widths: the preferred spelling, Learned from, and the switch; Heard as takes the rest.
enum DictionaryColumns {
    static let preferred: CGFloat = 200
    static let learned: CGFloat = 250
    static let toggle: CGFloat = 40
}

/// One word: the preferred spelling as a serif outlined pill, what it's heard as, where it came from ("Only in
/// Lapp Wagons" after a petal dot when it belongs to a project), and the switch. Off, the row dims (the switch stays
/// clear). Right-click to move it to a project or delete it (with Undo).
struct DictionaryRow: View {
    @EnvironmentObject var app: AppState
    var entry: DictionaryEntry
    @State private var hover = false

    private func setProject(_ id: UUID?) {
        if let i = app.store.dictionary.firstIndex(where: { $0.id == entry.id }) { app.store.dictionary[i].projectId = id }
    }

    private var project: String? {
        entry.projectId.flatMap { app.store.projectsByID[$0]?.name }
    }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                WordPill(text: entry.preferred).frame(width: DictionaryColumns.preferred, alignment: .leading)
                Text(entry.heardAs.joined(separator: ", ")).font(.system(size: 13.5)).foregroundStyle(Ink.ink)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(entry.learnedFrom).font(.system(size: 13.5)).foregroundStyle(Ink.dim).lineLimit(1)
                    if let project {
                        HStack(spacing: 6) {
                            Circle().fill(Ink.petal).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text("Only in \(project)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim).lineLimit(1)
                        }
                        .layoutPriority(1)
                    }
                }
                .frame(width: DictionaryColumns.learned, alignment: .leading)
            }
            .opacity(entry.enabled ? 1 : 0.45)
            InkSwitch(isOn: Binding(get: { entry.enabled }, set: { v in
                if let i = app.store.dictionary.firstIndex(where: { $0.id == entry.id }) { app.store.dictionary[i].enabled = v }
            }), label: "Use \(entry.preferred)")
            .frame(width: DictionaryColumns.toggle, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(minHeight: 56)
        .background(hover ? Ink.cardHover : Color.clear)
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
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

/// A word as a serif outlined pill ("Lapp Wagons"): 30 pt, serif 17, a 1.5 pt ink inset outline.
struct WordPill: View {
    var text: String
    var body: some View {
        Text(text).font(Ink.serif(17)).foregroundStyle(Ink.ink).lineLimit(1)
            .padding(.horizontal, 13).frame(height: 30)
            .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The website's switch: a 36 × 22 track with a 1.5 pt ink outline; on, the track is ink and the knob paper on the
/// right; off, the track is a hairline wash and the knob ink on the left. VoiceOver reads it as a toggle.
struct InkSwitch: View {
    @Binding var isOn: Bool
    var label: String
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Ink.ink : Ink.hairline)
            Capsule().strokeBorder(Ink.ink, lineWidth: 1.5)
            Circle().fill(isOn ? Ink.paper : Ink.ink).frame(width: 14, height: 14).padding(4)
        }
        .frame(width: 36, height: 22)
        .contentShape(Capsule())
        .animation(limitMotion ? nil : Motion.snap, value: isOn)
        .tapArea { isOn.toggle() }
        .accessibilityRepresentation { Toggle(label, isOn: $isOn) }
        .help(isOn ? "On: new transcripts use this spelling" : "Off: kept, but not used")
    }
}
