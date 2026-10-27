import SwiftUI

struct DictionaryScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var preferred = ""
    @State private var heard = ""
    var body: some View {
        List {
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
            }
            Section("Words") {
                ForEach(app.store.dictionary) { e in
                    Toggle(isOn: Binding(get: { e.enabled }, set: { v in if let i = app.store.dictionary.firstIndex(where: { $0.id == e.id }) { app.store.dictionary[i].enabled = v } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.preferred).font(.system(size: 16, weight: .semibold))
                            Text(e.heardAs.joined(separator: ", ")).font(.system(size: 13)).foregroundStyle(.lookMute)
                        }
                    }
                    .tint(PhoneInk.switchOn)
                }
                .onDelete { idx in app.store.dictionary.remove(atOffsets: idx) }
            }
            PhoneBuiltInVocabularySection()
            // Import CSV… and Export CSV… (PhoneTrust.swift).
            PhoneDictionaryCSVSection()
        }
        .scrollContentBackground(.hidden)
        .phonePage()
        .navigationTitle("Dictionary")
    }
}
