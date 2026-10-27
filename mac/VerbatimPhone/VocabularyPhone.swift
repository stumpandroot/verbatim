import SwiftUI
import UIKit

// The iPhone Dictionary screen's Suggestions (About me names, repeated fixes, Contacts) and Built-in vocabulary.

/// Names from About me and fixes you keep making, each with Add and Dismiss, plus the Contacts button.
struct PhoneDictionarySuggestions: View {
    @EnvironmentObject var app: PhoneState
    @AppStorage(AboutMeContext.key) private var aboutMe = ""
    @AppStorage(VocabularySuggestions.dismissedKey) private var dismissedRaw = ""
    @AppStorage(EditLearner.storeKey) private var pairsData = Data()
    @State private var modelNames: [String] = []
    @State private var showContacts = false

    var body: some View {
        let list = Array(VocabularySuggestions.current(aboutMe: aboutMe, extraNames: modelNames, dictionary: app.store.dictionary,
                                                       dismissedRaw: dismissedRaw, pairs: EditLearner.load(pairsData)).prefix(8))
        Section {
            ForEach(list) { s in
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookInk)
                    Text(s.detail).font(.system(size: 13)).foregroundStyle(.lookMute)
                    HStack(spacing: 10) {
                        Button("Add") {
                            app.store.addSuggestion(s)
                            app.toast = "Added \(s.preferred) to your Dictionary"
                        }
                        .buttonStyle(.borderedProminent).tint(Ink.interactive)
                        .accessibilityLabel("Add \(s.preferred)")
                        Button("Dismiss") {
                            dismissedRaw = VocabularySuggestions.dismissing(s.id, in: dismissedRaw)
                            if s.source == .edits, let h = s.heard.first { EditLearner.forget(heard: h, fixed: s.preferred) }
                        }
                        .buttonStyle(.bordered).tint(Ink.ink)
                        .accessibilityLabel("Dismiss \(s.preferred)")
                    }
                }
                .padding(.vertical, 4)
            }
            Button { showContacts = true } label: {
                Label("Suggest names from Contacts", art: .iconAboutMe)
            }
            .tint(Ink.ink)
            .task(id: aboutMe) { modelNames = await NameExtractor.modelNames(in: aboutMe) }
            .sheet(isPresented: $showContacts) { PhoneContactNamesSheet().environmentObject(app) }
        } header: {
            Text("Suggestions")
        } footer: {
            Text(list.isEmpty ? "Names from About me, and fixes you make more than once, show up here. Names from Contacts stay on this iPhone."
                              : "Names from Contacts stay on this iPhone.")
        }
    }
}

/// Picks names from Contacts to add in bulk. Asks for access first; reads names only, on this iPhone.
struct PhoneContactNamesSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    private enum Phase { case loading, denied, ready }
    @State private var phase: Phase = .loading
    @State private var candidates: [ContactNames.Candidate] = []
    @State private var picked: Set<String> = []
    @State private var filter = ""

    private var visible: [ContactNames.Candidate] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? candidates : candidates.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                switch phase {
                case .loading:
                    HStack(spacing: 10) { ProgressView(); Text("Reading names…").foregroundStyle(.lookMute) }
                case .denied:
                    Section {
                        Text("Verbose doesn't have access to Contacts. Turn it on in Settings › Apps › Verbose › Contacts, then try again.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                case .ready:
                    if candidates.isEmpty {
                        Text("Every name in your contacts is already in your Dictionary or spelled well without it.").foregroundStyle(.lookMute)
                    } else {
                        Section {
                            ForEach(visible) { c in
                                Button {
                                    if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(picked.contains(c.id) ? AnyShapeStyle(.lookMark) : AnyShapeStyle(.lookFaint))
                                            .font(.system(size: 20))
                                        Text(c.name).foregroundStyle(.lookInk)
                                    }
                                }
                                .accessibilityAddTraits(picked.contains(c.id) ? .isSelected : [])
                            }
                        } header: {
                            HStack {
                                Text("\(candidates.count) names")
                                Spacer()
                                Button(visible.allSatisfy { picked.contains($0.id) } ? "Select none" : "Select all") {
                                    if visible.allSatisfy({ picked.contains($0.id) }) { picked.subtract(visible.map(\.id)) }
                                    else { picked.formUnion(visible.map(\.id)) }
                                }
                                .font(.footnote.weight(.semibold))
                            }
                        } footer: {
                            Text("Unusual names start selected. Names stay on this iPhone.")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .phonePage()
            .searchable(text: $filter, prompt: "Search names")
            .navigationTitle("Names from Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                        let names = candidates.filter { picked.contains($0.id) }.map(\.name)
                        app.store.addNames(names, learnedFrom: "From Contacts")
                        app.toast = names.count == 1 ? "Added 1 name to your Dictionary" : "Added \(names.count) names to your Dictionary"
                        dismiss()
                    }
                    .disabled(picked.isEmpty || phase != .ready)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard await ContactNames.requestAccess() else { phase = .denied; return }
        let people = await ContactNames.people()
        candidates = ContactNames.candidates(people, dictionary: app.store.dictionary)
        picked = Set(candidates.filter(\.unusual).map(\.id))
        phase = .ready
    }
}

/// The built-in vocabulary switch, with its count and the list of terms.
struct PhoneBuiltInVocabularySection: View {
    @AppStorage(BuiltInVocabulary.enabledKey) private var on = true
    @AppStorage(BuiltInVocabulary.disabledKey) private var disabledRaw = ""

    var body: some View {
        let all = BuiltInVocabulary.terms
        let off = BuiltInVocabulary.disabled(disabledRaw)
        let active = all.filter { !off.contains($0.id) }.count
        Section {
            Toggle(isOn: $on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spell modern words right").font(.system(size: 16, weight: .semibold))
                    Text(on ? "\(active) of \(all.count) terms on" : "Off").font(.system(size: 13)).foregroundStyle(.lookMute)
                }
            }
            .tint(PhoneInk.switchOn)
            if on {
                NavigationLink { PhoneBuiltInTermsScreen() } label: { Text("Terms") }
            }
        } header: {
            Text("Built-in vocabulary")
        } footer: {
            Text("Verbose spells words like ChatGPT, GitHub, and macOS right. Your Dictionary always wins, and words like \u{201C}zoom in\u{201D} stay as you said them. Dictation also fixes mix-ups like \u{201C}could of been.\u{201D}")
        }
    }
}

/// Every built-in term, searchable, with a switch for each.
struct PhoneBuiltInTermsScreen: View {
    @AppStorage(BuiltInVocabulary.disabledKey) private var disabledRaw = ""
    @State private var query = ""

    private var shown: [BuiltInTerm] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return BuiltInVocabulary.terms }
        return BuiltInVocabulary.terms.filter { t in
            t.term.lowercased().contains(q) || t.category.lowercased().contains(q) || t.forms.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        let off = BuiltInVocabulary.disabled(disabledRaw)
        List {
            ForEach(shown) { t in
                Toggle(isOn: Binding(get: { !off.contains(t.id) }, set: { v in disabledRaw = BuiltInVocabulary.setting(t.id, on: v, in: disabledRaw) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.term).font(.system(size: 16, weight: .semibold))
                        Text(t.isContextual ? "Only next to words like \u{201C}call\u{201D} or \u{201C}app\u{201D}: \(t.forms.joined(separator: ", "))" : t.forms.joined(separator: ", "))
                            .font(.system(size: 13)).foregroundStyle(.lookMute).lineLimit(2)
                    }
                }
                .tint(PhoneInk.switchOn)
            }
        }
        .overlay { if shown.isEmpty { Text("Nothing matches \u{201C}\(query)\u{201D}").foregroundStyle(.lookMute) } }
        .scrollContentBackground(.hidden)
        .phonePage()
        .searchable(text: $query, prompt: "Search \(BuiltInVocabulary.terms.count) terms")
        .navigationTitle("Built-in vocabulary")
    }
}
