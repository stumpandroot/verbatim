import SwiftUI

/// Settings › Dictionary on the iPhone, on the refined kit (DESIGN.md §13) in both look settings: the serif title, the
/// suggestions, Add a word, your words with a switch each, the built-in vocabulary, and CSV, each group on a card.
struct DictionaryScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var preferred = ""
    @State private var heard = ""
    var body: some View {
        List {
            RefinedListTitle(title: "Dictionary", count: app.store.dictionary.isEmpty ? nil : "\(app.store.dictionary.count)",
                             lede: "Words Verbose should spell your way, and what it hears instead.")
            // About me names, repeated fixes, and Contacts (VocabularyPhone.swift).
            PhoneDictionarySuggestions()
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
                .foregroundStyle(Refined.accentText)
            }
            .listRowBackground(Refined.card)
            Section("Words") {
                ForEach(app.store.dictionary) { e in
                    Toggle(isOn: Binding(get: { e.enabled }, set: { v in if let i = app.store.dictionary.firstIndex(where: { $0.id == e.id }) { app.store.dictionary[i].enabled = v } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.preferred).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                            Text(e.heardAs.joined(separator: ", ")).refinedFont(.meta).foregroundStyle(Refined.mute)
                        }
                    }
                    .refinedSwitchTint()
                }
                .onDelete { idx in app.store.dictionary.remove(atOffsets: idx) }
            }
            .listRowBackground(Refined.card)
            PhoneBuiltInVocabularySection()
            // Import CSV… and Export CSV… (PhoneTrust.swift).
            PhoneDictionaryCSVSection()
                .listRowBackground(Refined.card)
        }
        .refinedListPage("Dictionary")
    }
}
