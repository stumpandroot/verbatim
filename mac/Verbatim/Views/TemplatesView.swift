import SwiftUI
import AppKit

// Make › Templates in the main window (mockup "Library features", sections 1a to 1c), on the refined kit (DESIGN.md
// §13): the template library with filter chips, a template's sections and Run automatically
// chips beside it, the editor for your own, and Run automatically (one template or Off per kind, and three options).
// Since the consolidation (October 28, 2026) it's the one list of what turns words into something else: the transcript
// templates and the text actions the Ribbon's menu runs on selected text (Settings › Actions moved here), each marked
// with where it works (`TemplateScope`). Templates are neutral (DESIGN.md §17.2): neutral icon squares and ink, with
// the persimmon tint only on what's selected.

enum TemplatesPane: String { case library, auto }

/// The library's chips: All, one origin, the ones that run automatically, or the ones that work on selected text.
enum TemplateFilter: Hashable { case all, origin(TemplateOrigin), auto, text }

/// The Templates screen's state, kept across visits.
@MainActor
final class TemplatesNav: ObservableObject {
    static let shared = TemplatesNav()
    @Published var pane: TemplatesPane = .library
    @Published var filter: TemplateFilter = .all
    @Published var selected: UUID? = nil
    /// The template being edited: a new one, a copy, or one of yours.
    @Published var editing: TranscriptTemplate? = nil
    @Published var editingIsNew = false
    /// Try on a recording: the template and the recording.
    @Published var tryOn: TemplateTryOn? = nil

    func newTemplate() { editingIsNew = true; editing = TemplateLibrary.blank() }
    /// A new text action at the end of the list, selected so its fields are ready to fill in.
    func newTextAction() {
        let a = FlowAction(name: "New action", instruction: "")
        FlowSettings.shared.actions.append(a)
        if filter != .all { filter = .text }
        selected = a.id
    }
    func duplicate(_ t: TranscriptTemplate) { editingIsNew = true; editing = TemplateLibrary.duplicate(t) }
    func edit(_ t: TranscriptTemplate) { editingIsNew = false; editing = t }
}

/// Ready recordings to try a template on, newest first.
@MainActor
enum TemplateTryOnList {
    static func recent(_ store: Store, limit: Int = 12) -> [Transcript] {
        Array(store.live.filter { $0.status == .ready && !$0.isDictation && !$0.segments.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}

struct TemplatesView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = TemplatesNav.shared

    var body: some View {
        NavMarks.mark("templates")
        return Group {
            switch nav.pane {
            case .library: TemplateLibraryPane()
            case .auto: RunAutomaticallyPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Refined.paper)
        .sheet(item: $nav.editing) { t in TemplateEditorSheet(draft: t, isNew: nav.editingIsNew).environmentObject(app) }
        .sheet(item: $nav.tryOn) { x in TemplateTryOnSheet(template: x.template, transcriptID: x.transcript).environmentObject(app) }
    }
}

/// A card on a Make page (a template's detail, Run automatically's table, Ask's answer and recipes): the refined
/// card, or the persimmon tint when it's the selected one. No outline or shadow; a hairline under Increase Contrast.
struct TemplateCardSurface: ViewModifier {
    var selected = false
    func body(content: Content) -> some View {
        content.refinedSurface(selected ? Refined.persimmonTint : Refined.card, radius: RefinedPlatform.radius(.card))
    }
}

/// A Make page's column: the content's widest, its margins, and the paper under it.
private struct MakePage<Content: View>: View {
    var maxWidth: CGFloat = 1180
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 40).padding(.top, 18).padding(.bottom, 40)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softScrollEdges(.top)
    }
}

// MARK: - Library

struct TemplateLibraryPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = TemplatesNav.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @ObservedObject private var flow = FlowSettings.shared
    @State private var confirmRestore = false

    var body: some View {
        let all = app.store.allTemplates
        let settings = auto.settings.pruned(existing: Set(all.map(\.id)))
        let textIDs = Set(flow.actions.map(\.id))
        // Text actions that are also templates (Plan my day, Write a draft, …) show once, as the template.
        let templateIDs = Set(all.map(\.id))
        let texts = flow.actions.filter { !templateIDs.contains($0.id) }
        let shown = filtered(all, settings, textIDs)
        let shownTexts = nav.filter == .all || nav.filter == .text ? texts : []
        let pickedText = shownTexts.first { $0.id == nav.selected }
        let pickedTemplate = shown.first { $0.id == nav.selected } ?? (pickedText == nil ? shown.first : nil)
        let fallbackText = pickedTemplate == nil ? (pickedText ?? shownTexts.first) : nil
        return MakePage {
            RefinedPageHeader(title: "Templates", count: HomeCounts.countLabel(all.count + texts.count, "template", "templates"),
                              lede: "Turn a recording into notes, a plan, or a draft, or rework text you select in any app. Each says where it works. Pick one per kind to run when a recording finishes.") {
                TemplatesPaneSwitch()
                Button { nav.newTextAction() } label: { Label("New text action", systemImage: "plus") }
                    .buttonStyle(RefinedActionStyle())
                    .uiTarget("templates-new-text")
                Button { nav.newTemplate() } label: { Label("New template", systemImage: "plus") }
                    .buttonStyle(RefinedActionStyle(kind: .strong))
                    .uiTarget("templates-new")
            }
            chips(all, settings, textIDs: textIDs, texts: texts.count)
            HStack(alignment: .top, spacing: 22) {
                list(shown, settings, textIDs: textIDs, texts: shownTexts, selected: pickedTemplate?.id ?? fallbackText?.id)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                if let t = pickedTemplate {
                    TemplateDetailCard(template: t, scope: TemplateScope.of(template: t.id, textActions: textIDs))
                        .frame(width: 340)
                        .id(t.id)
                } else if let a = fallbackText {
                    TextActionDetailCard(actionID: a.id)
                        .frame(width: 340)
                        .id(a.id)
                }
            }
        }
        .confirmationDialog("Restore the text actions that come with Verbose?", isPresented: $confirmRestore) {
            Button("Restore", role: .destructive) { flow.actions = FlowAction.builtIn; nav.selected = nil }
        } message: { Text("Replaces your text actions with the \(FlowAction.builtIn.count) that come with Verbose. Text actions you added or changed are removed. Your templates stay.") }
    }

    private func filtered(_ all: [TranscriptTemplate], _ s: AutoRunSettings, _ textIDs: Set<UUID>) -> [TranscriptTemplate] {
        switch nav.filter {
        case .all: return all
        case .origin(let o): return TemplateLibrary.filtered(all, origin: o, autoOnly: false, settings: s)
        case .auto: return TemplateLibrary.filtered(all, origin: nil, autoOnly: true, settings: s)
        case .text: return all.filter { textIDs.contains($0.id) }
        }
    }

    private func chips(_ all: [TranscriptTemplate], _ s: AutoRunSettings, textIDs: Set<UUID>, texts: Int) -> some View {
        let autoCount = all.filter { !s.kinds(for: $0.id).isEmpty }.count
        return RefinedChipRow(label: "Filter") {
            RefinedChip(title: "All", selected: nav.filter == .all) { nav.filter = .all }
                .accessibilityValue("\(all.count + texts)")
            ForEach([TemplateOrigin.builtIn, .scenario, .yours]) { o in
                RefinedChip(title: o.title, selected: nav.filter == .origin(o)) { nav.filter = nav.filter == .origin(o) ? .all : .origin(o) }
                    .accessibilityValue("\(all.filter { $0.origin == o }.count)")
                    .uiTarget("templates-filter-\(o.rawValue)")
            }
            RefinedChip(title: "Runs automatically", selected: nav.filter == .auto) { nav.filter = nav.filter == .auto ? .all : .auto }
                .accessibilityValue("\(autoCount)")
            RefinedChip(title: "On selected text", selected: nav.filter == .text) { nav.filter = nav.filter == .text ? .all : .text }
                .accessibilityValue("\(texts + all.filter { textIDs.contains($0.id) }.count)")
                .uiTarget("templates-filter-text")
        }
    }

    /// Each origin's templates in a card under its label ("Scenarios · 8"), then the text actions.
    private func list(_ shown: [TranscriptTemplate], _ s: AutoRunSettings, textIDs: Set<UUID>, texts: [FlowAction], selected: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(TemplateOrigin.allCases) { o in
                let items = shown.filter { $0.origin == o }
                if !items.isEmpty {
                    PaperGroup("\(o.title) · \(items.count)") {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { PaperDivider(leading: 48, trailing: 14) }
                            row(t, s, scope: TemplateScope.of(template: t.id, textActions: textIDs), selected: t.id == selected)
                        }
                    }
                }
            }
            if !texts.isEmpty {
                PaperGroup("Text actions · \(texts.count)") {
                    ForEach(Array(texts.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { PaperDivider(leading: 48, trailing: 14) }
                        textRow(a, selected: a.id == selected)
                    }
                }
                RefinedLink(title: "Restore the text actions that come with Verbose") { confirmRestore = true }
                    .padding(.leading, 4)
            }
            if shown.isEmpty && texts.isEmpty {
                Text("No templates here yet. Choose New template to make your own.").refinedFont(.body).foregroundStyle(Refined.dim)
                    .padding(.vertical, 12)
            }
        }
    }

    /// A text action of yours or one that comes with Verbose: it works on selected text and on recordings.
    private func textRow(_ a: FlowAction, selected: Bool) -> some View {
        PaperRowButton(selected: selected, action: { nav.selected = a.id }) {
            rowFace(art: a.art, title: a.name.isEmpty ? "Untitled action" : a.name,
                    meta: TemplateScope.metaLine(TemplateScope.textAction, a.kind.title))
        }
        .accessibilityLabel((a.name.isEmpty ? "Untitled action" : a.name) + ", works on " + TemplateScope.textAction.title.lowercased())
        .uiTarget("text-action-row-\(a.id.uuidString.prefix(8))")
    }

    private func row(_ t: TranscriptTemplate, _ s: AutoRunSettings, scope: TemplateScope, selected: Bool) -> some View {
        let kinds = s.kinds(for: t.id)
        return PaperRowButton(selected: selected, action: { nav.selected = t.id }) {
            // The auto state goes in the meta line, so the name has the whole row (review M-31).
            rowFace(art: t.art, title: t.name,
                    meta: TemplateScope.metaLine(scope, TemplateAutoBadge.metaLine(summary: TemplateLibrary.summaryLine(t), kinds: kinds)))
        }
        .accessibilityLabel(t.name + ", works on " + scope.title.lowercased() + (kinds.isEmpty ? "" : ", runs automatically for " + kinds.map(\.label).joined(separator: ", ")))
        .uiTarget("template-row-\(t.id.uuidString.prefix(8))")
    }

    private func rowFace(art: BrandArt, title: String, meta: String) -> some View {
        HStack(spacing: 12) {
            IconSquare(art: art, hue: .neutral)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                Text(meta).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// "Runs for Meeting": a template that runs automatically for some kinds.
struct TemplateAutoBadge: View {
    /// A list row's meta line: "Runs for Meeting · Decisions, next steps" (the kinds first), or the summary alone.
    static func metaLine(summary: String, kinds: [RecordingKind]) -> String {
        guard !kinds.isEmpty else { return summary }
        let runs = "Runs for " + kinds.map(\.label).joined(separator: ", ")
        return summary.isEmpty ? runs : runs + " · " + summary
    }

    var kinds: [RecordingKind]
    var body: some View {
        HStack(spacing: 5) {
            IconGlyph(art: .iconRecent, size: 12, color: Refined.mute)
            Text("Runs for " + kinds.map(\.label).joined(separator: ", ")).lineLimit(1)
        }
        .refinedFont(.meta).foregroundStyle(Refined.mute)
    }
}

// MARK: - Detail

/// A template beside the library: what it is, its name, description, sections, the kinds it runs for automatically,
/// Try on a recording, and Duplicate and edit (or Edit, Duplicate, and Delete for yours).
struct TemplateDetailCard: View {
    @EnvironmentObject var app: AppState
    var template: TranscriptTemplate
    /// Where it works: recordings, and selected text too when it's also a text action.
    var scope: TemplateScope = .recording
    @ObservedObject private var nav = TemplatesNav.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @State private var confirmDelete = false

    var body: some View {
        let kinds = template.kinds.isEmpty ? AutoRunSettings.kinds : template.kinds
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(template.origin.eyebrow).refinedFont(.meta).foregroundStyle(Refined.mute)
                Text(template.name).refinedFont(.sectionTitle).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(TemplateLibrary.summaryLine(template)).refinedFont(.body).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Works on " + scope.title.lowercased()).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                    .uiTarget("template-scope")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Sections").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute).padding(.bottom, 4)
                ForEach(Array(template.sections.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { PaperDivider(leading: 0) }
                    HStack(spacing: 10) {
                        Text("\(i + 1)").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute).frame(width: 16, alignment: .leading)
                        Text(s.name).refinedFont(.rowTitle).foregroundStyle(Refined.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(s.format.title).refinedFont(.meta).foregroundStyle(Refined.dim)
                    }
                    .padding(.vertical, 6)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Runs automatically for").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                FlowRow(spacing: 6, lineSpacing: 6) {
                    ForEach(kinds) { k in
                        RefinedChip(title: k.label, selected: auto.settings.template(for: k) == template.id) {
                            auto.toggle(template.id, for: k)
                        }
                        .uiTarget("template-kind-\(k.rawValue)")
                    }
                }
                Text("A kind runs one template. Choosing it here replaces the one it had.").refinedFont(.meta).foregroundStyle(Refined.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowRow(spacing: 8, lineSpacing: 8) {
                TemplateTryOnMenu(template: template)
                if template.isEditable {
                    Button("Edit") { nav.edit(template) }.buttonStyle(RefinedActionStyle(kind: .strong)).uiTarget("template-edit")
                    Button("Duplicate") { nav.duplicate(template) }.buttonStyle(RefinedActionStyle())
                } else {
                    Button("Duplicate and edit") { nav.duplicate(template) }.buttonStyle(RefinedActionStyle(kind: .strong)).uiTarget("template-duplicate")
                }
            }
            if template.isEditable {
                Button("Delete template…", role: .destructive) { confirmDelete = true }
                    .buttonStyle(RefinedActionStyle())
            }
            HStack(alignment: .top, spacing: 7) {
                IconGlyph(art: .iconPrivacy, size: 14, color: Refined.mute)
                Text(TemplateCopy.onDevice("Mac")).refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TemplateCardSurface())
        .confirmationDialog("Delete \u{201C}\(template.name)\u{201D}?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let id = template.id
                nav.selected = nil
                auto.removed(id)
                DispatchQueue.main.async { app.store.templates.removeAll { $0.id == id } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Results it already wrote stay in their transcripts. Kinds that ran it turn Off.") }
    }
}

/// Try on a recording: a menu of recent recordings; the result shows in a sheet and nothing is saved.
struct TemplateTryOnMenu: View {
    @EnvironmentObject var app: AppState
    var template: TranscriptTemplate
    var title = "Try on a recording"
    var onPick: ((UUID) -> Void)? = nil
    @ObservedObject private var nav = TemplatesNav.shared

    var body: some View {
        let recent = TemplateTryOnList.recent(app.store)
        Menu {
            if recent.isEmpty { Text("No recordings yet") }
            ForEach(recent) { t in
                Button(t.title) {
                    if let onPick { onPick(t.id) } else { nav.tryOn = TemplateTryOn(template: template, transcript: t.id) }
                }
            }
        } label: {
            RefinedMenuLabel(title: title)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(title)
    }
}

/// Library | Run automatically: the kit's segmented control, the same on both panes.
private struct TemplatesPaneSwitch: View {
    @ObservedObject private var nav = TemplatesNav.shared
    var body: some View {
        RefinedSegmented(label: "Templates view", options: [(TemplatesPane.library, "Library"), (TemplatesPane.auto, "Run automatically")],
                         selection: $nav.pane)
            .fixedSize()
            .background {
                // The self-test's handles on each half.
                HStack(spacing: 0) {
                    Color.clear.uiTarget("templates-library")
                    Color.clear.uiTarget("templates-auto")
                }
                .allowsHitTesting(false)
            }
    }
}

// MARK: - Run automatically

struct RunAutomaticallyPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var nav = TemplatesNav.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared

    var body: some View {
        let all = app.store.allTemplates
        let settings = auto.settings.pruned(existing: Set(all.map(\.id)))
        return MakePage(maxWidth: 1000) {
            RefinedPageHeader(title: "Run automatically", count: "\(settings.assignedCount) of \(AutoRunSettings.kinds.count) kinds",
                              lede: "When a recording of a kind finishes, its template runs after the transcript and summary.") {
                TemplatesPaneSwitch()
            }
            PaperCard {
                HStack(spacing: 0) {
                    Text("Kind").frame(width: 200, alignment: .leading)
                    Text("Template").frame(width: 230, alignment: .leading)
                    Text("This month")
                    Spacer(minLength: 0)
                }
                .refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .accessibilityHidden(true)
                PaperDivider(leading: 0)
                ForEach(Array(AutoRunSettings.kinds.enumerated()), id: \.element) { i, k in
                    if i > 0 { PaperDivider(leading: 16, trailing: 16) }
                    kindRow(k, all, settings)
                }
                PaperDivider(leading: 16, trailing: 16)
                // Audio only has no transcript, so no template can run on it: listed with no picker.
                HStack(spacing: 0) {
                    kindName(.audio).frame(width: 200, alignment: .leading)
                    Text(AudioOnlyCopy.noTemplate).refinedFont(.meta).foregroundStyle(Refined.mute)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .uiTarget("auto-kind-audio")
            }
            HStack(spacing: 12) {
                option("Skip short recordings", "Under 2 minutes", $auto.settings.skipShort, target: "auto-skip")
                option("Show the result first", "Open transcripts on it", $auto.settings.showFirst, target: "auto-first")
                option("Notify me when it's done", "For recordings over 20 minutes", $auto.settings.notify, target: "auto-notify")
            }
            HStack(spacing: 7) {
                IconGlyph(art: .iconPrivacy, size: 14, color: Refined.mute)
                Text(TemplateCopy.onDevice("Mac") + " Your iPhone keeps its own choices; the results sync with the library.")
                    .refinedFont(.meta).foregroundStyle(Refined.dim)
            }
        }
    }

    private func kindName(_ k: RecordingKind) -> some View {
        HStack(spacing: 10) {
            IconSquare(art: k.refinedArt, hue: k.refinedHue)
            Text(k.label).refinedFont(.rowTitle).foregroundStyle(Refined.ink)
        }
    }

    private func kindRow(_ k: RecordingKind, _ all: [TranscriptTemplate], _ s: AutoRunSettings) -> some View {
        let assigned = s.template(for: k)
        let note = AutoRunRules.monthNote(AutoRunRules.runsThisMonth(app.store.live, kind: k), kind: k, assigned: assigned != nil)
        let suggested = all.filter { $0.kinds.contains(k) }
        let others = all.filter { !$0.kinds.contains(k) }
        return HStack(spacing: 0) {
            kindName(k).frame(width: 200, alignment: .leading)
            Picker("Template for \(k.label)", selection: Binding<UUID?>(get: { assigned }, set: { auto.set($0, for: k) })) {
                Text("Off").tag(UUID?.none)
                Divider()
                ForEach(suggested) { t in Text(t.name).tag(UUID?.some(t.id)) }
                if !suggested.isEmpty && !others.isEmpty { Divider() }
                ForEach(others) { t in Text(t.name).tag(UUID?.some(t.id)) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .frame(width: 230, alignment: .leading)
            .uiTarget("auto-kind-\(k.rawValue)")
            Text(note).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private func option(_ title: String, _ detail: String, _ on: Binding<Bool>, target: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                Text(detail).refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            Spacer(minLength: 6)
            Toggle(title, isOn: on).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .refinedSwitchTint()
                .uiTarget(target)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .modifier(TemplateCardSurface())
    }
}

// MARK: - Editor

/// New template, Duplicate and edit, or Edit: the name, the kinds it suits, what it should write (the no-add rule is
/// added for you), its sections in order with a format each, and Try on a recording before you save.
struct TemplateEditorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TranscriptTemplate
    var isNew: Bool
    @State private var problem: String? = nil
    @State private var tryOn: TemplateTryOn? = nil

    init(draft: TranscriptTemplate, isNew: Bool) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The fields scroll when the sheet would be taller than the window, so the footer always shows.
            ViewThatFits(in: .vertical) {
                fields
                ScrollView { fields.padding(.trailing, 10) }
            }
            PaperDivider(leading: 0)
            HStack(spacing: 10) {
                IconGlyph(art: .iconPrivacy, size: 14, color: Refined.mute)
                // The one on-device promise (DESIGN.md §8, M-65).
                Text(TemplateCopy.onDevice("Mac")).refinedFont(.meta).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // macOS order (review M-32): Try on at the left; Cancel and Save, the default action, at the right.
            HStack(spacing: 8) {
                TemplateTryOnMenu(template: draft, title: "Try on", onPick: { tryOn = TemplateTryOn(template: draft, transcript: $0) })
                Spacer(minLength: 8)
                if let problem { Text(problem).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.accentText).lineLimit(2) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).uiTarget("editor-save")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 20)
        .frame(width: 660)
        .frame(maxHeight: TemplateEditorSheet.maxHeight(window: app.mainWindow?.contentLayoutRect.height))
        .background(Refined.paper)
        .tint(Refined.accentText)
        .sheet(item: $tryOn) { x in TemplateTryOnSheet(template: x.template, transcriptID: x.transcript).environmentObject(app) }
    }

    /// The window's content height less 80, so the sheet never runs past the window (no window: no cap).
    static func maxHeight(window: CGFloat?) -> CGFloat {
        guard let window, window > 0 else { return .infinity }
        return max(360, window - 80)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Yours").refinedFont(.meta).foregroundStyle(Refined.mute)
                Text(isNew ? "New template" : "Edit template").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    label("Name")
                    TextField("Website client call", text: $draft.name).textFieldStyle(.roundedBorder).refinedFont(.body)
                        .uiTarget("editor-name")
                }
                .frame(width: 260)
                VStack(alignment: .leading, spacing: 6) {
                    label("Use it for")
                    FlowRow(spacing: 6, lineSpacing: 6) {
                        ForEach(AutoRunSettings.kinds) { k in
                            RefinedChip(title: k.label, selected: draft.kinds.contains(k)) {
                                if let i = draft.kinds.firstIndex(of: k) { draft.kinds.remove(at: i) } else { draft.kinds.append(k) }
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                label("What should it write?")
                TextEditor(text: $draft.instructions)
                    .refinedFont(.body).foregroundStyle(Refined.ink).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 88)
                    .refinedFieldBox()
                    .accessibilityLabel("What should it write")
                Text(TemplateCopy.ruleNote).refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            VStack(alignment: .leading, spacing: 6) {
                label("Sections")
                PaperCard {
                    ForEach(Array(draft.sections.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { PaperDivider(leading: 12, trailing: 12) }
                        sectionRow(i, s)
                    }
                }
                Button { draft.sections.append(TemplateSection("", .bullets)) } label: { Label("Add a section", systemImage: "plus") }
                    .buttonStyle(.plain).refinedFont(.hint).foregroundStyle(Refined.accentText)
                    .uiTarget("editor-add-section")
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink)
    }

    private func sectionRow(_ i: Int, _ s: TemplateSection) -> some View {
        let id = s.id
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .medium)).foregroundStyle(Refined.faint).accessibilityHidden(true)
            TextField("Section name", text: Binding(get: { draft.sections.first { $0.id == id }?.name ?? "" },
                                                    set: { v in if let j = draft.sections.firstIndex(where: { $0.id == id }) { draft.sections[j].name = v } }))
                .textFieldStyle(.plain).refinedFont(.body).foregroundStyle(Refined.ink)
            Picker("Format", selection: Binding(get: { draft.sections.first { $0.id == id }?.format ?? .bullets },
                                                set: { v in if let j = draft.sections.firstIndex(where: { $0.id == id }) { draft.sections[j].format = v } })) {
                ForEach(TemplateSectionFormat.allCases) { f in Text(f.title).tag(f) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Button { move(id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(i == 0).help("Move up").accessibilityLabel("Move \(s.name) up")
            Button { move(id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(i == draft.sections.count - 1).help("Move down").accessibilityLabel("Move \(s.name) down")
            Button {
                // After the row's fields let go of their bindings, or AppKit can read a removed index.
                DispatchQueue.main.async { draft.sections.removeAll { $0.id == id } }
            } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.borderless).help("Remove this section").accessibilityLabel("Remove \(s.name)")
        }
        .padding(.horizontal, 12).frame(height: 40)
    }

    private func move(_ id: UUID, by d: Int) {
        guard let i = draft.sections.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard draft.sections.indices.contains(j) else { return }
        DispatchQueue.main.async { draft.sections.swapAt(i, j) }
    }

    private func save() {
        var t = draft
        t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        t.instructions = t.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in t.sections.indices { t.sections[i].name = t.sections[i].name.trimmingCharacters(in: .whitespaces) }
        if let p = TemplateLibrary.problem(t) { problem = p; return }
        if let i = app.store.templates.firstIndex(where: { $0.id == t.id }) { app.store.templates[i] = t } else { app.store.templates.append(t) }
        TemplatesNav.shared.selected = t.id
        TemplatesNav.shared.filter = .all
        app.toast = Toast(isNew ? "Saved \u{201C}\(t.name)\u{201D}" : "Template saved")
        dismiss()
    }
}

// MARK: - Try on

/// A template's result on one recording, made on this Mac and never saved: copy it, or close.
struct TemplateTryOnSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var template: TranscriptTemplate
    var transcriptID: UUID
    @StateObject private var preview = TemplatePreview()

    var body: some View {
        let t = app.store.transcript(transcriptID)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Try on").refinedFont(.meta).foregroundStyle(Refined.mute)
                Text(template.name.isEmpty ? "Untitled" : template.name).refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("On \u{201C}\(t?.title ?? "a recording")\u{201D}. Nothing is saved.").refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            Group {
                switch preview.phase {
                case .running:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(preview.part.isEmpty ? "Working on your Mac…" : preview.part).refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    ScrollView {
                        TemplateResultBody(text: preview.text, heading: .system(size: 18, design: .serif), textFont: .system(size: 13.5),
                                           ink: AnyShapeStyle(Refined.ink), dim: AnyShapeStyle(Refined.mute))
                            .padding(14)
                    }
                    .modifier(TemplateCardSurface())
                case .failed:
                    VStack(spacing: 6) {
                        Text("Couldn't run this template").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                        Text(preview.failure ?? "Apple's on-device model didn't answer. Try again.")
                            .refinedFont(.body).foregroundStyle(Refined.mute).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            if preview.phase == .done {
                Text(TemplateCopy.footer(madeOn: "Mac", here: "Mac")).refinedFont(.meta).foregroundStyle(Refined.dim)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Close") { preview.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                if preview.phase != .running, let t { Button("Try again") { preview.start(template, on: t) } }
                if preview.phase == .done {
                    Button("Copy") { Paster.copy(preview.text); app.toast = Toast("Copied") }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 600, height: 520)
        .background(Refined.paper)
        .tint(Refined.accentText)
        .onAppear { if let t { preview.start(template, on: t) } }
        .onDisappear { preview.stop() }
    }
}
