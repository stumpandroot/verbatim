import SwiftUI
import AppKit

// The Dictionary screen's Suggestions (About me names, repeated fixes, Contacts) and Built-in vocabulary sections.

/// Names from About me and fixes you keep making, each with Add and Dismiss, plus the Contacts button.
struct DictionarySuggestions: View {
    @EnvironmentObject var app: AppState
    @AppStorage(AboutMeContext.key) private var aboutMe = ""
    @AppStorage(VocabularySuggestions.dismissedKey) private var dismissedRaw = ""
    @AppStorage(EditLearner.storeKey) private var pairsData = Data()
    @State private var modelNames: [String] = []
    @State private var showContacts = false

    private static let shown = 8

    var body: some View {
        let all = VocabularySuggestions.current(aboutMe: aboutMe, extraNames: modelNames, dictionary: app.store.dictionary,
                                                dismissedRaw: dismissedRaw, pairs: EditLearner.load(pairsData))
        let list = Array(all.prefix(Self.shown))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Suggestions").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { showContacts = true } label: { Label("Suggest names from Contacts", art: .iconAboutMe) }
                    .buttonStyle(.brandSecondary)
                    .help("Pick names from your contacts. Names stay on this Mac.")
            }
            if list.isEmpty {
                Text("Names from About me, and fixes you make more than once, show up here.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        row(s)
                        if s.id != list.last?.id { Divider().opacity(0.5) }
                    }
                }
                .cardSurface(radius: Radius.row)
                if all.count > list.count {
                    Text("\(all.count - list.count) more after these.").font(.system(size: 12)).foregroundStyle(Ink.mute)
                }
            }
        }
        .padding(.bottom, 18)
        .task(id: aboutMe) { modelNames = await NameExtractor.modelNames(in: aboutMe) }
        .sheet(isPresented: $showContacts) { ContactNamesSheet().environmentObject(app) }
    }

    private func row(_ s: VocabularySuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.source == .aboutMe ? "person.text.rectangle" : "arrow.triangle.2.circlepath")
                .font(.system(size: 13)).foregroundStyle(Ink.mute).frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
                Text(s.detail).font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Spacer(minLength: 8)
            Button("Dismiss") {
                dismissedRaw = VocabularySuggestions.dismissing(s.id, in: dismissedRaw)
                if s.source == .edits, let h = s.heard.first { EditLearner.forget(heard: h, fixed: s.preferred) }
            }
            .buttonStyle(.brandSecondary)
            .accessibilityLabel("Dismiss \(s.preferred)")
            Button("Add") {
                app.store.addSuggestion(s)
                app.toast = Toast("Added \(s.preferred) to your Dictionary")
            }
            .buttonStyle(.brandPrimary)
            .accessibilityLabel("Add \(s.preferred)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Picks names from Contacts to add in bulk. Asks for access first; reads names only, on this Mac.
struct ContactNamesSheet: View {
    @EnvironmentObject var app: AppState
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Names from Contacts").font(Ink.serif(26)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader)
            Text("Pick the names Verbose should spell your way. Unusual names start selected. Names stay on this Mac.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            switch phase {
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading names…").foregroundStyle(Ink.mute) }
                    .frame(maxWidth: .infinity, minHeight: 280)
            case .denied:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Verbose doesn't have access to Contacts. Turn it on in System Settings › Privacy & Security › Contacts, then try again.")
                        .font(.system(size: 13)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.brandSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            case .ready:
                if candidates.isEmpty {
                    Text("Every name in your contacts is already in your Dictionary or spelled well without it.")
                        .font(.system(size: 13)).foregroundStyle(Ink.mute)
                        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
                } else {
                    HStack(spacing: 8) {
                        TextField("Search \(candidates.count) names", text: $filter).textFieldStyle(.roundedBorder)
                        Button("Select all") { picked.formUnion(visible.map(\.id)) }.buttonStyle(.brandSecondary)
                        Button("Select none") { picked.subtract(visible.map(\.id)) }.buttonStyle(.brandSecondary)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visible) { c in
                                Toggle(isOn: Binding(get: { picked.contains(c.id) }, set: { on in if on { picked.insert(c.id) } else { picked.remove(c.id) } })) {
                                    Text(c.name).font(.system(size: 13.5)).foregroundStyle(Ink.ink)
                                }
                                .toggleStyle(.checkbox)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                            }
                        }
                    }
                    .frame(height: 280)
                    .cardSurface(radius: Radius.button)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(picked.isEmpty ? "Add selected" : "Add \(picked.count) selected") {
                    let names = candidates.filter { picked.contains($0.id) }.map(\.name)
                    app.store.addNames(names, learnedFrom: "From Contacts")
                    app.toast = Toast(names.count == 1 ? "Added 1 name to your Dictionary" : "Added \(names.count) names to your Dictionary")
                    dismiss()
                }
                .buttonStyle(.brandPrimary).keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || phase != .ready)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Ink.paper)
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

/// The built-in vocabulary: the switch, a count, and a searchable list with a switch per term.
struct BuiltInVocabularySection: View {
    @AppStorage(BuiltInVocabulary.enabledKey) private var on = true
    @AppStorage(BuiltInVocabulary.disabledKey) private var disabledRaw = ""
    @State private var query = ""
    @State private var showList = false

    var body: some View {
        let all = BuiltInVocabulary.terms
        let off = BuiltInVocabulary.disabled(disabledRaw)
        let active = all.filter { !off.contains($0.id) }.count
        VStack(alignment: .leading, spacing: 8) {
            Text("Built-in vocabulary").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Spell modern words right").font(.system(size: 14)).foregroundStyle(Ink.ink)
                        Text(on ? "\(active) of \(all.count) terms on, like ChatGPT, GitHub, and macOS. Your Dictionary always wins, and words like “zoom in” stay as you said them."
                                : "Off. Verbose spells only your Dictionary's words its own way.")
                            .font(.system(size: 12.5)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Built-in vocabulary", isOn: $on).toggleStyle(.switch).labelsHidden().tint(Ink.switchOn)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                if on {
                    Divider()
                    HStack(spacing: 8) {
                        TextField("Search \(all.count) terms", text: $query).textFieldStyle(.roundedBorder)
                        Button(showList ? "Hide list" : "Show list") { showList.toggle() }.buttonStyle(.brandSecondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    if showList || !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let shown = matching(all)
                        Divider()
                        if shown.isEmpty {
                            Text("Nothing matches “\(query)”").font(.system(size: 13)).foregroundStyle(Ink.mute).padding(14)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(shown) { t in termRow(t, on: !off.contains(t.id)) }
                                }
                            }
                            .frame(height: 320)
                        }
                    }
                }
            }
            .cardSurface(radius: Radius.row)
        }
        .padding(.top, 28)
    }

    private func matching(_ all: [BuiltInTerm]) -> [BuiltInTerm] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { t in
            t.term.lowercased().contains(q) || t.category.lowercased().contains(q) || t.forms.contains { $0.lowercased().contains(q) }
        }
    }

    private func termRow(_ t: BuiltInTerm, on termOn: Bool) -> some View {
        HStack(spacing: 10) {
            Pill(text: t.term).frame(width: 180, alignment: .leading)
            Text(t.isContextual ? "Only next to words like “call” or “app”: \(t.forms.joined(separator: ", "))" : t.forms.joined(separator: ", "))
                .font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(t.forms.joined(separator: ", "))
            Text(t.category).font(.system(size: 11.5)).foregroundStyle(Ink.mute).frame(width: 100, alignment: .leading)
            Toggle(t.term, isOn: Binding(get: { termOn }, set: { v in disabledRaw = BuiltInVocabulary.setting(t.id, on: v, in: disabledRaw) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Ink.switchOn)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .opacity(termOn ? 1 : 0.55)
    }
}
