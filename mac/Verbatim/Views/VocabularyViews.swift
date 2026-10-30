import SwiftUI
import AppKit

// The Dictionary screen's Suggestions (About me names, repeated fixes, Contacts) and Built-in vocabulary sections, on
// the refined kit (DESIGN.md §13): suggestions in a card, each one a quiet chip with Add.

/// Names from About me and fixes you keep making, each a chip with Add (and a small × to dismiss it), plus the Contacts
/// button, in a card.
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
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(all.isEmpty ? "Suggestions" : "Suggestions · \(all.count)").refinedFont(.meta).foregroundStyle(Refined.mute)
                    .accessibilityAddTraits(.isHeader)
                Text("Names and fixes").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).lineLimit(1)
                Button { showContacts = true } label: {
                    HStack(spacing: 6) { IconGlyph(art: .iconAboutMe, size: 14, color: Refined.ink); Text("Suggest names from Contacts") }
                }
                .buttonStyle(RefinedActionStyle())
                .help("Pick names from your contacts. Names stay on this Mac.")
                .padding(.top, 6)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 8) {
                if list.isEmpty {
                    Text("Names from About me, and fixes you make more than once, show up here.")
                        .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                } else {
                    FlowRow(spacing: 8, lineSpacing: 8) {
                        ForEach(list) { s in pill(s) }
                    }
                    if all.count > list.count {
                        Text("\(all.count - list.count) more after these.").refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .task(id: aboutMe) { modelNames = await NameExtractor.modelNames(in: aboutMe) }
        .sheet(isPresented: $showContacts) { ContactNamesSheet().environmentObject(app) }
    }

    /// "Jonathan  from About me  [Add] ×": a quiet chip with Add and a dismiss.
    private func pill(_ s: VocabularySuggestion) -> some View {
        HStack(spacing: 8) {
            Text(s.title).refinedFont(.chip, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
            Text(s.detail).refinedFont(.caption).foregroundStyle(Refined.mute).lineLimit(1)
            Button("Add") {
                app.store.addSuggestion(s)
                app.toast = Toast("Added \(s.preferred) to your Dictionary")
            }
            .buttonStyle(.plain).refinedFont(.chip, weight: .semibold).foregroundStyle(Refined.accentText)
            .help("Adds \(s.preferred) to your Dictionary")
            .accessibilityLabel("Add \(s.preferred)")
            Button { dismiss(s) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Refined.mute)
                    .frame(width: 20, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss \(s.preferred)")
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: 32)
        .background(Refined.neutral, in: Capsule())
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Add \(s.preferred)") { app.store.addSuggestion(s); app.toast = Toast("Added \(s.preferred) to your Dictionary") }
            Button("Dismiss") { dismiss(s) }
        }
    }

    private func dismiss(_ s: VocabularySuggestion) {
        dismissedRaw = VocabularySuggestions.dismissing(s.id, in: dismissedRaw)
        if s.source == .edits, let h = s.heard.first { EditLearner.forget(heard: h, fixed: s.preferred) }
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
        RefinedSheet(title: "Names from Contacts", message: "Pick the names Verbose should spell your way. Unusual names start selected. Names stay on this Mac.", width: 480) {
            switch phase {
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading names…").refinedFont(.body).foregroundStyle(Refined.mute) }
                    .frame(maxWidth: .infinity, minHeight: 280)
            case .denied:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Verbose doesn't have access to Contacts. Turn it on in System Settings › Privacy & Security › Contacts, then try again.")
                        .refinedFont(.body).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") { NSWorkspace.shared.open(url) }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            case .ready:
                if candidates.isEmpty {
                    Text("Every name in your contacts is already in your Dictionary or spelled well without it.")
                        .refinedFont(.body).foregroundStyle(Refined.mute)
                        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
                } else {
                    HStack(spacing: 8) {
                        TextField("Search \(candidates.count) names", text: $filter).textFieldStyle(.roundedBorder)
                        Button("Select all") { picked.formUnion(visible.map(\.id)) }
                        Button("Select none") { picked.subtract(visible.map(\.id)) }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visible) { c in
                                Toggle(isOn: Binding(get: { picked.contains(c.id) }, set: { on in if on { picked.insert(c.id) } else { picked.remove(c.id) } })) {
                                    Text(c.name).refinedFont(.rowTitle).foregroundStyle(Refined.ink)
                                }
                                .toggleStyle(.checkbox)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                            }
                        }
                    }
                    .frame(height: 280)
                    .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                }
            }
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(picked.isEmpty ? "Add selected" : "Add \(picked.count) selected") {
                let names = candidates.filter { picked.contains($0.id) }.map(\.name)
                app.store.addNames(names, learnedFrom: "From Contacts")
                app.toast = Toast(names.count == 1 ? "Added 1 name to your Dictionary" : "Added \(names.count) names to your Dictionary")
                dismiss()
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(picked.isEmpty || phase != .ready)
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
            SectionTitle("Built-in vocabulary")
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Spell modern words right").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        Text(on ? "\(active) of \(all.count) terms on, like ChatGPT, GitHub, and macOS. Your Dictionary always wins, and words like \u{201C}zoom in\u{201D} stay as you said them. Dictation also fixes mix-ups like \u{201C}could of been.\u{201D}"
                                : "Off. Verbose spells only your Dictionary's words its own way.")
                            .refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Built-in vocabulary", isOn: $on).toggleStyle(.switch).labelsHidden().controlSize(.small).refinedSwitchTint()
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                if on {
                    PaperDivider(leading: 0)
                    HStack(spacing: 10) {
                        RefinedSearchField(text: $query, prompt: "Search \(all.count) terms")
                        Button(showList ? "Hide list" : "Show list") { showList.toggle() }
                            .buttonStyle(RefinedActionStyle())
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    if showList || !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let shown = matching(all)
                        PaperDivider(leading: 0)
                        if shown.isEmpty {
                            Text("Nothing matches \u{201C}\(query)\u{201D}").refinedFont(.body).foregroundStyle(Refined.mute).padding(14)
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
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        }
        .padding(.top, 10)
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
            WordPill(text: t.term).frame(width: DictionaryColumns.preferred, alignment: .leading)
            Text(t.isContextual ? "Only next to words like \u{201C}call\u{201D} or \u{201C}app\u{201D}: \(t.forms.joined(separator: ", "))" : t.forms.joined(separator: ", "))
                .refinedFont(.meta).foregroundStyle(Refined.dim).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(t.forms.joined(separator: ", "))
            Text(t.category).refinedFont(.caption).foregroundStyle(Refined.mute).frame(width: 100, alignment: .leading)
            Toggle(t.term, isOn: Binding(get: { termOn }, set: { v in disabledRaw = BuiltInVocabulary.setting(t.id, on: v, in: disabledRaw) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini).refinedSwitchTint()
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .opacity(termOn ? 1 : 0.55)
    }
}
