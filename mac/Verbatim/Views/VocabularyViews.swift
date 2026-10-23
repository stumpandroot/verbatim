import SwiftUI
import AppKit

// brand: web style
//
// The Dictionary screen's Suggestions (About me names, repeated fixes, Contacts) and Built-in vocabulary sections.
// Suggestions sit on a butter panel with grain and the `lines` drawing (mac/DESIGN.md §11), each one a paper pill
// with a mini dark Add.

/// Names from About me and fixes you keep making, each a paper pill with Add (and a small × to dismiss it), plus the
/// Contacts button, on a butter panel.
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
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: all.isEmpty ? "Suggestions" : "Suggestions · \(all.count)", color: Ink.inkFixed)
                    .accessibilityAddTraits(.isHeader)
                WebText.serif("Names and", italic: "fixes.", size: 24).foregroundStyle(Ink.inkFixed).lineLimit(1)
                PillButton(title: "Suggest names from Contacts", kind: .line, size: .mini, icon: .iconAboutMe, fixedInk: true,
                           hint: "Pick names from your contacts. Names stay on this Mac.") { showContacts = true }
                    .help("Pick names from your contacts. Names stay on this Mac.")
                    .padding(.top, 6)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 8) {
                if list.isEmpty {
                    Text("Names from About me, and fixes you make more than once, show up here.")
                        .font(.system(size: 13)).foregroundStyle(Ink.inkFixed).fixedSize(horizontal: false, vertical: true)
                } else {
                    FlowRow(spacing: 8, lineSpacing: 8) {
                        ForEach(list) { s in pill(s) }
                    }
                    if all.count > list.count {
                        Text("\(all.count - list.count) more after these.").font(.system(size: 12.5)).foregroundStyle(Ink.inkFixed.opacity(0.8))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 20).padding(.trailing, 90).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .colorPanel(Ink.panelButter, radius: Radius.record) {
            PanelArt(kind: .lines).frame(width: 200, height: 140).offset(x: 20, y: -10)
        }
        .task(id: aboutMe) { modelNames = await NameExtractor.modelNames(in: aboutMe) }
        .sheet(isPresented: $showContacts) { ContactNamesSheet().environmentObject(app) }
    }

    /// "Jonathan  from About me  [Add] ×": paper fill, an ink outline, a mini dark Add.
    private func pill(_ s: VocabularySuggestion) -> some View {
        HStack(spacing: 8) {
            Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.inkFixed).lineLimit(1)
            Text(s.detail).font(.system(size: 11.5)).foregroundStyle(Ink.muteOnPaper).lineLimit(1)
            PillButton(title: "Add", kind: .dark, size: .mini, fixedInk: true, hint: "Adds \(s.preferred) to your Dictionary") {
                app.store.addSuggestion(s)
                app.toast = Toast("Added \(s.preferred) to your Dictionary")
            }
            .accessibilityLabel("Add \(s.preferred)")
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.muteOnPaper)
                .frame(width: 20, height: 26).contentShape(Rectangle())
                .tapArea { dismiss(s) }
                .help("Dismiss")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Dismiss \(s.preferred)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { dismiss(s) }
        }
        .padding(.leading, 14).padding(.trailing, 4)
        .frame(height: 34)
        .background(Ink.paperFixed, in: Capsule())
        .overlay(Capsule().inset(by: -0.75).stroke(Ink.inkFixed, lineWidth: 1.5))
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
            SectionTitle(title: "Built-in", italic: "vocabulary").padding(.bottom, 6)
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Spell modern words right").font(.system(size: 14)).foregroundStyle(Ink.ink)
                        Text(on ? "\(active) of \(all.count) terms on, like ChatGPT, GitHub, and macOS. Your Dictionary always wins, and words like “zoom in” stay as you said them."
                                : "Off. Verbose spells only your Dictionary's words its own way.")
                            .font(.system(size: 12.5)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    InkSwitch(isOn: $on, label: "Built-in vocabulary")
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                if on {
                    Rectangle().fill(Ink.hairline).frame(height: 1)
                    HStack(spacing: 10) {
                        WebSearchField(text: $query, prompt: "Search \(all.count) terms", height: 36)
                        Button(showList ? "Hide list" : "Show list") { showList.toggle() }
                            .buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    if showList || !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let shown = matching(all)
                        Rectangle().fill(Ink.hairline).frame(height: 1)
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
            .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
            .inkEdge(outline: true, radius: Radius.record)
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
            WordPill(text: t.term).frame(width: DictionaryColumns.preferred, alignment: .leading)
            Text(t.isContextual ? "Only next to words like “call” or “app”: \(t.forms.joined(separator: ", "))" : t.forms.joined(separator: ", "))
                .font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(t.forms.joined(separator: ", "))
            Text(t.category).font(.system(size: 11.5)).foregroundStyle(Ink.mute).frame(width: 100, alignment: .leading)
            InkSwitch(isOn: Binding(get: { termOn }, set: { v in disabledRaw = BuiltInVocabulary.setting(t.id, on: v, in: disabledRaw) }), label: t.term)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .opacity(termOn ? 1 : 0.55)
    }
}
