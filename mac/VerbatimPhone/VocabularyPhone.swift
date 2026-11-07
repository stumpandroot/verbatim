import SwiftUI
import UIKit

// The iPhone Dictionary screen's Suggestions (About me names, repeated fixes, Contacts) and Built-in vocabulary, on the
// refined kit (DESIGN.md §13): sections on cards, the kit's actions, and the accent's checks.

/// Names from About me and fixes you keep making, each with Add and Dismiss, plus the Contacts button.
struct PhoneDictionarySuggestions: View {
    @Environment(PhoneState.self) var app
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
                    Text(s.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(s.detail).refinedFont(.meta).foregroundStyle(Refined.mute)
                    HStack(spacing: 10) {
                        Button("Add") {
                            app.store.addSuggestion(s)
                            app.say("Added \(s.preferred) to your Dictionary")
                        }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                        .accessibilityLabel("Add \(s.preferred)")
                        Button("Dismiss") {
                            dismissedRaw = VocabularySuggestions.dismissing(s.id, in: dismissedRaw)
                            if s.source == .edits, let h = s.heard.first { EditLearner.forget(heard: h, fixed: s.preferred) }
                        }
                        .buttonStyle(RefinedActionStyle(kind: .quiet))
                        .accessibilityLabel("Dismiss \(s.preferred)")
                    }
                }
                .padding(.vertical, 4)
            }
            Button { showContacts = true } label: {
                Label("Suggest names from Contacts", art: .iconAboutMe)
            }
            .foregroundStyle(Refined.accentText)
            .task(id: aboutMe) { modelNames = await NameExtractor.modelNames(in: aboutMe) }
            .sheet(isPresented: $showContacts) { PhoneContactNamesSheet().phoneState(app) }
        } header: {
            Text("Suggestions")
        } footer: {
            Text(list.isEmpty ? "Names from About me, and fixes you make more than once, show up here. Names from Contacts stay on this iPhone."
                              : "Names from Contacts stay on this iPhone.")
                .foregroundStyle(Refined.mute)
        }
        .listRowBackground(Refined.card)
    }
}

/// Picks names from Contacts to add in bulk. Asks for access first; reads names only, on this iPhone.
struct PhoneContactNamesSheet: View {
    @Environment(PhoneState.self) var app
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
                    HStack(spacing: 10) { ProgressView(); Text("Reading names…").foregroundStyle(Refined.mute) }
                        .listRowBackground(Refined.card)
                case .denied:
                    Section {
                        Text("Verbose doesn't have access to Contacts. Turn it on in Settings › Apps › Verbose › Contacts, then try again.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .foregroundStyle(Refined.accentText)
                    }
                    .listRowBackground(Refined.card)
                case .ready:
                    if candidates.isEmpty {
                        Text("Every name in your contacts is already in your Dictionary or spelled well without it.").foregroundStyle(Refined.mute)
                            .listRowBackground(Refined.card)
                    } else {
                        Section {
                            ForEach(visible) { c in
                                Button {
                                    if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        RefinedCheckbox(on: picked.contains(c.id))
                                        Text(c.name).refinedFont(.body).foregroundStyle(Refined.ink)
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
                                .foregroundStyle(Refined.accentText)
                            }
                        } footer: {
                            Text("Unusual names start selected. Names stay on this iPhone.").foregroundStyle(Refined.mute)
                        }
                        .listRowBackground(Refined.card)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Refined.paper.ignoresSafeArea())
            .searchable(text: $filter, prompt: "Search names")
            .navigationTitle("Names from Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                        let names = candidates.filter { picked.contains($0.id) }.map(\.name)
                        app.store.addNames(names, learnedFrom: "From Contacts")
                        app.say(names.count == 1 ? "Added 1 name to your Dictionary" : "Added \(names.count) names to your Dictionary")
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
        // Terms of a specialty field that's off (Settings › Specialty words) don't count.
        let active = BuiltInVocabulary.active(all, on: true, disabled: off, fieldsOff: VocabularyField.off()).count
        Section {
            Toggle(isOn: $on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spell modern words right").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(on ? "\(active) of \(all.count) terms on" : "Off").refinedFont(.meta).foregroundStyle(Refined.mute)
                }
            }
            .refinedSwitchTint()
            if on {
                NavigationLink { PhoneBuiltInTermsScreen() } label: { Text("Terms") }
            }
        } header: {
            Text("Built-in vocabulary")
        } footer: {
            Text("Verbose spells words like ChatGPT, GitHub, and macOS right. Your Dictionary always wins, and words like \u{201C}zoom in\u{201D} stay as you said them. Dictation also fixes mix-ups like \u{201C}could of been.\u{201D}")
                .foregroundStyle(Refined.mute)
        }
        .listRowBackground(Refined.card)
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
                        Text(t.term).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        Text(t.isContextual ? "Only next to words like \u{201C}call\u{201D} or \u{201C}app\u{201D}: \(t.forms.joined(separator: ", "))" : t.forms.joined(separator: ", "))
                            .refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(2)
                    }
                }
                .refinedSwitchTint()
            }
            .listRowBackground(Refined.card)
        }
        .overlay { if shown.isEmpty { Text("Nothing matches \u{201C}\(query)\u{201D}").refinedFont(.body).foregroundStyle(Refined.mute) } }
        .refinedListPage("Built-in vocabulary")
        .searchable(text: $query, prompt: "Search \(BuiltInVocabulary.terms.count) terms")
    }
}

/// Settings › Specialty words (mockup "Specialty words"): a switch per field of the built-in vocabulary
/// (VocabularyField), with a few of its terms under each. Turning on Medical shows what a word patch can't do. The
/// built-in vocabulary's own switch (Dictionary) still turns every field off. The choices sync with the Mac in the
/// profile (Store.SyncedProfile) while iCloud sync is on.
struct SpecialtyWordsScreen: View {
    @AppStorage(BuiltInVocabulary.enabledKey) private var builtIn = true
    @AppStorage(VocabularyField.film.key) private var film = VocabularyField.film.isOnByDefault
    @AppStorage(VocabularyField.business.key) private var business = VocabularyField.business.isOnByDefault
    @AppStorage(VocabularyField.medical.key) private var medical = VocabularyField.medical.isOnByDefault
    @AppStorage(VocabularyField.legal.key) private var legal = VocabularyField.legal.isOnByDefault
    @AppStorage(VocabularyField.faith.key) private var faith = VocabularyField.faith.isOnByDefault

    /// The group's note: what the switches do, and whether they really sync.
    private var footer: String {
        var parts = [VocabularyField.groupNote]
        if !builtIn { parts.append("Built-in vocabulary is off on the Dictionary page, so these fields don't apply.") }
        parts.append(Cloud.enabled ? "Synced with your Mac through iCloud." : "Kept on this iPhone while iCloud sync is off.")
        return parts.joined(separator: " ")
    }

    var body: some View {
        SettingsPageScaffold(title: "Specialty words") {
            SettingsPageGroup(footer: footer, first: true) {
                row(.film, $film, id: "specialtyFilm")
                SettingsDivider()
                row(.business, $business, id: "specialtyBusiness")
                SettingsDivider()
                row(.medical, $medical, id: "specialtyMedical")
                if medical && builtIn {
                    Text(VocabularyField.medicalNote)
                        .refinedFont(.meta).foregroundStyle(Refined.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.bottom, 12)
                        .accessibilityIdentifier("settings.medicalNote")
                }
                SettingsDivider()
                row(.legal, $legal, id: "specialtyLegal")
                SettingsDivider()
                row(.faith, $faith, id: "specialtyFaith")
            }
        }
    }

    private func row(_ f: VocabularyField, _ on: Binding<Bool>, id: String) -> some View {
        SettingsToggleRow(title: f.title, subtitle: f.examples, isOn: on)
            .disabled(!builtIn)
            .settingsSearchTarget(id, flash: nil)
    }
}
