import SwiftUI
import UIKit

// Templates on the iPhone (mockup "Library features", section 1): Library › Templates (the library, a template's
// sections, Try on a recording, Run automatically for a kind, and your own templates), Settings › Templates (Run
// automatically: one template or Off per kind, and three options, kept on this iPhone), the result as a tab in the
// transcript. Record a kind from a long press on Record is the Record as tray (RecordTray.swift). Built from the Settings page kit
// and the refined kit (DESIGN.md §13).

struct TemplatesRoute: Hashable {}
struct TemplateDetailRoute: Hashable { var id: UUID }
struct TemplatesAutoRoute: Hashable {}


// MARK: - Library

struct TemplatesScreen: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @State private var filter: TemplateOrigin? = nil
    @State private var editing: TranscriptTemplate? = nil
    /// What the screen showed last, for the self-test.
    static var shown: (count: Int, filter: TemplateOrigin?)? = nil

    var body: some View {
        let all = app.store.allTemplates
        let settings = auto.settings.pruned(existing: Set(all.map(\.id)))
        let shown = all.filter { filter == nil || $0.origin == filter }
        SettingsPageScaffold(title: "Templates") {
            Text("Turn a transcript into notes, a plan, or a draft. Each kind of recording can run one on its own.")
                .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            RefinedSegmented(label: "Show", options: [(TemplateOrigin?.none, "All"), (TemplateOrigin?.some(.builtIn), "Built in"),
                                     (TemplateOrigin?.some(.scenario), "Scenarios"), (TemplateOrigin?.some(.yours), "Yours")],
                           selection: $filter)
                .padding(.top, 14)
            SettingsPageGroup(first: true) {
                NavigationLink(value: TemplatesAutoRoute()) {
                    SettingsRow(hue: .sage, art: .iconRecent, title: "Run automatically",
                                subtitle: "A template for each kind, when a recording finishes") {
                        SettingsValue("\(settings.assignedCount) of \(AutoRunSettings.kinds.count)")
                        SettingsChevron()
                    }
                }
                .buttonStyle(SettingsRowPress())
                .accessibilityIdentifier("templates.auto")
            }
            ForEach(TemplateOrigin.allCases) { o in
                let items = shown.filter { $0.origin == o }
                if !items.isEmpty {
                    SettingsPageGroup(title: "\(o.title) · \(items.count)") {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { SettingsDivider() }
                            NavigationLink(value: TemplateDetailRoute(id: t.id)) { row(t, settings) }
                                .buttonStyle(SettingsRowPress())
                        }
                    }
                }
            }
            if shown.isEmpty {
                Text("No templates of yours yet. Tap + to make one, or open a template and choose Duplicate and edit.")
                    .refinedFont(.body).foregroundStyle(Refined.mute).padding(.top, 22)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = TemplateLibrary.blank() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New template")
            }
        }
        .sheet(item: $editing) { t in PhoneTemplateEditor(draft: t, isNew: true).environmentObject(app) }
        .onAppear { Self.shown = (shown.count, filter) }
        .onChange(of: filter) { _, f in Self.shown = (all.filter { f == nil || $0.origin == f }.count, f) }
    }

    private func row(_ t: TranscriptTemplate, _ s: AutoRunSettings) -> some View {
        let kinds = s.kinds(for: t.id)
        return SettingsRow(hue: .neutral, art: t.art, title: t.name, subtitle: TemplateLibrary.summaryLine(t), subtitleLines: 1) {
            if !kinds.isEmpty { Text("Auto").font(.system(size: 14)).foregroundStyle(Refined.mute) }
            SettingsChevron()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(kinds.isEmpty ? "Opens the template" : "Runs automatically for " + kinds.map(\.label).joined(separator: ", "))
    }
}

// MARK: - A template

struct TemplateDetailScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    var id: UUID
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @State private var editing: TranscriptTemplate? = nil
    @State private var editingIsNew = false
    @State private var tryOn: TemplateTryOn? = nil
    @State private var confirmDelete = false

    var body: some View {
        if let t = TemplateLibrary.template(id, yours: app.store.templates) {
            content(t)
        } else {
            Text("This template was deleted.").refinedFont(.body).foregroundStyle(Refined.mute).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Refined.paper.ignoresSafeArea())
        }
    }

    private func content(_ t: TranscriptTemplate) -> some View {
        let kinds = t.kinds.isEmpty ? AutoRunSettings.kinds : t.kinds
        let recent = app.store.live.filter { $0.status == .ready && !$0.isDictation && !$0.segments.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }.prefix(12)
        return SettingsPageScaffold(title: t.name, eyebrow: t.origin.eyebrow, inline: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text(TemplateLibrary.summaryLine(t)).refinedFont(.body).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            SettingsPageGroup(title: "Sections", first: true) {
                ForEach(Array(t.sections.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { SettingsDivider() }
                    HStack(spacing: 12) {
                        Text(String(format: "%02d", i + 1)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                        Text(s.name).refinedFont(.body).foregroundStyle(Refined.ink)
                        Spacer(minLength: 8)
                        Text(s.format.title).refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 46)
                }
            }
            SettingsPageGroup(title: "Run automatically for", footer: "A kind runs one template. Turning one on here replaces the template it had.") {
                ForEach(Array(kinds.enumerated()), id: \.element) { i, k in
                    if i > 0 { SettingsDivider() }
                    SettingsToggleRow(title: k.label,
                                      subtitle: other(k, t).map { "Now runs \($0)" },
                                      isOn: Binding(get: { auto.settings.template(for: k) == t.id }, set: { on in auto.set(on ? t.id : nil, for: k) }))
                        .accessibilityIdentifier("template.kind.\(k.rawValue)")
                }
            }
            SettingsPageGroup(footer: TemplateCopy.onDevice("iPhone")) {
                Menu {
                    if recent.isEmpty { Text("No recordings yet") }
                    ForEach(Array(recent)) { r in Button(r.title) { tryOn = TemplateTryOn(template: t, transcript: r.id) } }
                } label: {
                    SettingsRow(hue: .sage, art: .iconPlay, title: "Try on a recording", subtitle: "See the result; nothing is saved") {
                        SettingsMenuMark()
                    }
                }
                SettingsDivider()
                Button {
                    editingIsNew = true; editing = TemplateLibrary.duplicate(t)
                } label: {
                    SettingsRow(hue: .butter, art: .iconCopy, title: t.isEditable ? "Duplicate" : "Duplicate and edit") { SettingsChevron() }
                }
                .buttonStyle(SettingsRowPress())
                .accessibilityIdentifier("template.duplicate")
                if t.isEditable {
                    SettingsDivider()
                    Button { editingIsNew = false; editing = t } label: {
                        SettingsRow(hue: .butter, art: .iconNotes, title: "Edit") { SettingsChevron() }
                    }
                    .buttonStyle(SettingsRowPress())
                    SettingsDivider()
                    Button { confirmDelete = true } label: {
                        SettingsRow(hue: .petal, art: .iconDeleteAll, title: "Delete template", danger: true) { EmptyView() }
                    }
                    .buttonStyle(SettingsRowPress())
                }
            }
        }
        .sheet(item: $editing) { e in PhoneTemplateEditor(draft: e, isNew: editingIsNew).environmentObject(app) }
        .sheet(item: $tryOn) { x in PhoneTemplateTryOnSheet(template: x.template, transcriptID: x.transcript).environmentObject(app) }
        .alert("Delete \u{201C}\(t.name)\u{201D}?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                auto.removed(t.id)
                let tid = t.id
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.store.templates.removeAll { $0.id == tid } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Results it already wrote stay in their transcripts. Kinds that ran it turn Off.") }
    }

    /// The template a kind runs now, when it isn't this one.
    private func other(_ k: RecordingKind, _ t: TranscriptTemplate) -> String? {
        guard let id = auto.settings.template(for: k), id != t.id else { return nil }
        return TemplateLibrary.template(id, yours: app.store.templates)?.name
    }
}

// MARK: - Run automatically

/// Settings › Templates and Library › Templates › Run automatically: one template or Off per kind, and Skip short
/// recordings, Show the result first, and Notify me when it's done. Kept on this iPhone; the results sync.
struct TemplatesAutoScreen: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var auto = TemplateSettingsModel.shared
    /// Ask's recipes, hidden until you show them (consolidation, `RecipesSetting`).
    @AppStorage(RecipesSetting.key) private var showRecipes = false

    var body: some View {
        let all = app.store.allTemplates
        let settings = auto.settings.pruned(existing: Set(all.map(\.id)))
        SettingsPageScaffold(title: "Run automatically") {
            Text("Pick a template for each kind. It runs when a recording of that kind finishes, after the transcript and summary.")
                .refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            SettingsPageGroup(title: "When a recording finishes", first: true) {
                ForEach(Array(AutoRunSettings.kinds.enumerated()), id: \.element) { i, k in
                    if i > 0 { SettingsDivider() }
                    kindRow(k, all, settings)
                }
                // Audio only has no transcript, so no template can run on it: listed with no picker.
                SettingsDivider()
                SettingsRow(hue: .neutral, art: RecordingKind.audio.art, title: RecordingKind.audio.label, subtitle: AudioOnlyCopy.noTemplate) {
                    EmptyView()
                }
                .accessibilityIdentifier("templates.auto.audio")
            }
            .settingsSearchTarget("templatesAuto", flash: nil)
            SettingsPageGroup(footer: TemplateCopy.onDevice("iPhone") + " Your Mac keeps its own choices; the results sync with the library.") {
                SettingsToggleRow(title: "Skip short recordings", subtitle: "Under 2 minutes",
                                  isOn: $auto.settings.skipShort)
                    .settingsSearchTarget("templatesSkipShort", flash: nil)
                SettingsDivider()
                SettingsToggleRow(title: "Show the result first", subtitle: "Open transcripts on it",
                                  isOn: $auto.settings.showFirst)
                    .settingsSearchTarget("templatesShowFirst", flash: nil)
                SettingsDivider()
                SettingsToggleRow(title: "Notify me when it\u{2019}s done", subtitle: "For recordings over 20 minutes",
                                  isOn: $auto.settings.notify)
                    .settingsSearchTarget("templatesNotify", flash: nil)
            }
            SettingsPageGroup(footer: app.store.recipes.isEmpty ? "Questions you save in Ask and run again, now or every week."
                                                                : "Ask shows your recipes while you have one.") {
                SettingsToggleRow(title: "Recipes", subtitle: "Show them in Ask",
                                  isOn: Binding(get: { RecipesSetting.shows(stored: showRecipes, hasRecipes: !app.store.recipes.isEmpty) }, set: { showRecipes = $0 }))
                    .disabled(!app.store.recipes.isEmpty)
                    .settingsSearchTarget("askRecipes", flash: nil)
            }
        }
    }

    private func kindRow(_ k: RecordingKind, _ all: [TranscriptTemplate], _ s: AutoRunSettings) -> some View {
        let current = s.template(for: k).flatMap { id in all.first { $0.id == id } }
        let suggested = all.filter { $0.kinds.contains(k) }
        let others = all.filter { !$0.kinds.contains(k) }
        return Menu {
            Button { auto.set(nil, for: k) } label: { if current == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") } }
            Section("Suits \(k.plural)") {
                ForEach(suggested) { t in choice(t, k, current) }
            }
            Section("Other templates") {
                ForEach(others) { t in choice(t, k, current) }
            }
        } label: {
            SettingsRow(hue: .neutral, art: k.art, title: k.label) {
                SettingsValue(current?.name ?? "Off")
                SettingsMenuMark()
            }
        }
        .accessibilityIdentifier("templates.auto.\(k.rawValue)")
    }

    @ViewBuilder private func choice(_ t: TranscriptTemplate, _ k: RecordingKind, _ current: TranscriptTemplate?) -> some View {
        Button { auto.set(t.id, for: k) } label: {
            if current?.id == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
        }
    }
}

// MARK: - Editor

/// New template, Duplicate and edit, or Edit: the name, the kinds it suits, what it should write, and its sections.
struct PhoneTemplateEditor: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TranscriptTemplate
    var isNew: Bool
    @State private var problem: String? = nil
    @State private var tryOn: TemplateTryOn? = nil
    @FocusState private var focused: Bool

    init(draft: TranscriptTemplate, isNew: Bool) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Yours").refinedFont(.meta).foregroundStyle(Refined.mute).padding(.top, 8)
                    field("Name") {
                        TextField("Website client call", text: $draft.name)
                            .refinedFont(.body).foregroundStyle(Refined.ink).focused($focused)
                            .padding(.horizontal, 14).frame(minHeight: 48)
                            .accessibilityIdentifier("editor.name")
                    }
                    field("What should it write?") {
                        TextEditor(text: $draft.instructions)
                            .refinedFont(.body).foregroundStyle(Refined.ink).scrollContentBackground(.hidden).focused($focused)
                            .frame(minHeight: 110).padding(8)
                    }
                    Text(TemplateCopy.ruleNote).refinedFont(.meta).foregroundStyle(Refined.mute)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).padding(.top, 6)
                    SettingsPageGroup(title: "Use it for") {
                        ForEach(Array(AutoRunSettings.kinds.enumerated()), id: \.element) { i, k in
                            if i > 0 { SettingsDivider() }
                            SettingsToggleRow(title: k.label,
                                              isOn: Binding(get: { draft.kinds.contains(k) }, set: { on in
                                                  draft.kinds.removeAll { $0 == k }
                                                  if on { draft.kinds.append(k) }
                                              }))
                        }
                    }
                    SettingsPageGroup(title: "Sections") {
                        ForEach(Array(draft.sections.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { SettingsDivider() }
                            sectionRow(i, s)
                        }
                        SettingsDivider()
                        Button { draft.sections.append(TemplateSection("", .bullets)) } label: {
                            SettingsRow(hue: .sage, art: nil, title: "Add a section") { EmptyView() }
                        }
                        .buttonStyle(SettingsRowPress())
                    }
                    if let problem {
                        Text(problem).refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText).padding(.top, 14)
                    }
                    Text(TemplateCopy.onDevice("iPhone")).refinedFont(.meta).foregroundStyle(Refined.mute).padding(.top, 18)
                }
                .padding(.horizontal, 20).padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Refined.paper.ignoresSafeArea())
            .navigationTitle(isNew ? "New template" : "Edit template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("editor.save") }
                ToolbarItem(placement: .bottomBar) {
                    Menu("Try on a recording") {
                        let recent = app.store.live.filter { $0.status == .ready && !$0.isDictation && !$0.segments.isEmpty }
                            .sorted { $0.createdAt > $1.createdAt }.prefix(12)
                        ForEach(Array(recent)) { r in Button(r.title) { tryOn = TemplateTryOn(template: draft, transcript: r.id) } }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } }
            }
            .sheet(item: $tryOn) { x in PhoneTemplateTryOnSheet(template: x.template, transcriptID: x.transcript).environmentObject(app) }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute).padding(.horizontal, 4)
            content().refinedFieldBox()
        }
        .padding(.top, 16)
    }

    private func sectionRow(_ i: Int, _ s: TemplateSection) -> some View {
        let id = s.id
        return HStack(spacing: 10) {
            TextField("Section name", text: Binding(get: { draft.sections.first { $0.id == id }?.name ?? "" },
                                                    set: { v in if let j = draft.sections.firstIndex(where: { $0.id == id }) { draft.sections[j].name = v } }))
                .refinedFont(.body).foregroundStyle(Refined.ink).focused($focused)
            Menu {
                Picker("Format", selection: Binding(get: { draft.sections.first { $0.id == id }?.format ?? .bullets },
                                                    set: { v in if let j = draft.sections.firstIndex(where: { $0.id == id }) { draft.sections[j].format = v } })) {
                    ForEach(TemplateSectionFormat.allCases) { f in Text(f.title).tag(f) }
                }
                Divider()
                Button("Move up") { move(id, by: -1) }.disabled(i == 0)
                Button("Move down") { move(id, by: 1) }.disabled(i == draft.sections.count - 1)
                Button("Remove", role: .destructive) { DispatchQueue.main.async { draft.sections.removeAll { $0.id == id } } }
            } label: {
                HStack(spacing: 4) {
                    Text(s.format.title).refinedFont(.meta)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Refined.mute)
                .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 48)
    }

    private func move(_ id: UUID, by d: Int) {
        guard let i = draft.sections.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard draft.sections.indices.contains(j) else { return }
        draft.sections.swapAt(i, j)
    }

    private func save() {
        var t = draft
        t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        t.instructions = t.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in t.sections.indices { t.sections[i].name = t.sections[i].name.trimmingCharacters(in: .whitespaces) }
        if let p = TemplateLibrary.problem(t) { problem = p; return }
        if let i = app.store.templates.firstIndex(where: { $0.id == t.id }) { app.store.templates[i] = t } else { app.store.templates.append(t) }
        app.say(isNew ? "Saved \u{201C}\(t.name)\u{201D}" : "Template saved")
        dismiss()
    }
}

// MARK: - Try on

/// A template's result on one recording, made on this iPhone and never saved: copy it, or close.
struct PhoneTemplateTryOnSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    var template: TranscriptTemplate
    var transcriptID: UUID
    @StateObject private var preview = TemplatePreview()

    var body: some View {
        let t = app.store.transcript(transcriptID)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("On \u{201C}\(t?.title ?? "a recording")\u{201D} · nothing is saved").refinedFont(.meta).foregroundStyle(Refined.mute)
                    switch preview.phase {
                    case .running:
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(preview.part.isEmpty ? "Working on your iPhone…" : preview.part).refinedFont(.body).foregroundStyle(Refined.mute)
                        }
                        .padding(.top, 30).frame(maxWidth: .infinity)
                    case .done:
                        TemplateResultBody(text: preview.text, heading: .system(size: 20, design: .serif), textFont: .system(size: 16),
                                           ink: AnyShapeStyle(Refined.ink), dim: AnyShapeStyle(Refined.mute))
                        Text(TemplateCopy.footer(madeOn: "iPhone", here: "iPhone")).refinedFont(.meta).foregroundStyle(Refined.mute)
                    case .failed:
                        Text(preview.failure ?? "Apple's on-device model didn't answer. Try again.").refinedFont(.body).foregroundStyle(Refined.mute)
                            .padding(.top, 20)
                    }
                }
                .padding(20)
            }
            .background(Refined.paper.ignoresSafeArea())
            .navigationTitle(template.name.isEmpty ? "Try on" : template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { preview.stop(); dismiss() } }
                if preview.phase == .done {
                    ToolbarItem(placement: .primaryAction) { Button("Copy") { UIPasteboard.general.string = preview.text; app.say("Copied"); Haptics.play(.copied) } }
                }
            }
        }
        .onAppear { if let t { preview.start(template, on: t) } }
        .onDisappear { preview.stop() }
    }
}

// MARK: - The result in a transcript

/// A transcript's template results, the tab beside Original and Cleaned: the template's name, why it ran, Run again
/// and Edit, the sections, and the footer. The kind-change offer and the waiting line live here too.
struct PhoneTemplateResults: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    /// A plan task's time: play that line in the transcript.
    var onJump: ((Double) -> Void)? = nil
    @ObservedObject private var center = TemplateCenter.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @State private var editing: TemplateResult? = nil
    @State private var draft = ""
    @State private var confirmReplace: TemplateResult? = nil
    @FocusState private var focused: Bool

    /// The tab's label: the result's template, or "Results" with more than one.
    static func tabTitle(_ t: Transcript, busyName: String?) -> String? {
        let r = t.shownTemplateResults
        if r.count == 1 { return r[0].name }
        if r.count > 1 { return "Results" }
        if let busyName { return busyName }
        return t.autoRun.flatMap { $0.state == .waiting || $0.state == .failed ? $0.name : nil }
    }

    var body: some View {
        let results = transcript.shownTemplateResults
        let templates = app.store.allTemplates
        let busy = center.busyTemplate(transcript.id)
        VStack(alignment: .leading, spacing: 14) {
            if let b = busy {
                status("Running \(templates.first { $0.id == b }?.name ?? "the template")" + (center.progress[transcript.id].map { " · \($0)" } ?? "") + "…")
            } else if let w = transcript.autoRunWaitingText {
                status(w)
            }
            if let m = transcript.autoRun, m.state == .failed, busy == nil, !results.contains(where: { $0.templateId == m.templateId }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(m.name) didn\u{2019}t run").refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink)
                    if let note = m.note { Text(note).refinedFont(.hint).foregroundStyle(Refined.mute) }
                    if TemplateLibrary.current(m.templateId) != nil {
                        Button("Run again") { center.run(m.templateId, on: transcript.id, store: app.store, kind: m.kind) }.buttonStyle(RefinedActionStyle())
                    }
                }
            }
            if let why = center.failures[transcript.id] {
                Text(why).refinedFont(.hint).foregroundStyle(Refined.accentText)
            }
            ForEach(results) { r in card(r, templates) }
        }
        .sheet(item: $editing) { r in editor(r) }
        .alert("Replace your edited result?", isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } })) {
            Button("Replace", role: .destructive) { if let r = confirmReplace { runAgain(r, force: true) } }
            Button("Keep mine", role: .cancel) {}
        } message: { Text("Apple Intelligence writes it again, and your edits are gone.") }
    }

    private func card(_ r: TemplateResult, _ templates: [TranscriptTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Template").refinedFont(.meta).foregroundStyle(Refined.mute)
            Text(r.name).refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
            if let reason = AutoRunRules.reason(r) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                    Text(reason)
                }
                .refinedFont(.hint).foregroundStyle(Refined.mute)
            }
            HStack(spacing: 8) {
                // A cut template's result (Key points) has no Run again; a retired one's runs its replacement.
                if TemplateLibrary.runAgain(r) != nil {
                    Button { runAgain(r) } label: { Text("Run again") }
                        .buttonStyle(RefinedActionStyle()).disabled(center.busyTemplate(transcript.id) != nil)
                        .accessibilityIdentifier("result.runAgain")
                }
                Button("Edit") { draft = r.text; editing = r }.buttonStyle(RefinedActionStyle())
                    .accessibilityIdentifier("result.edit")
                Menu {
                    Menu("Run another template") {
                        ForEach(templates.filter { $0.id != r.templateId }) { t in
                            Button(t.name) { center.run(t.id, on: transcript.id, store: app.store) }
                        }
                    }
                    Button("Copy") { UIPasteboard.general.string = TemplateResultText.plain(r.text); app.say("Copied"); Haptics.play(.copied) }
                    ShareLink(item: TemplateResultText.plain(r.text)) { Text("Share") }
                    Button("Save as note") {
                        app.store.addNote(Note(text: TemplateResultText.plain(r.text), aiAction: r.name), to: transcript.id)
                        app.say("Saved as a note")
                    }
                    Button("Delete result", role: .destructive) { app.store.update(transcript.id) { $0.removeTemplateResult(r.id) } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Refined.ink)
                        .frame(width: 44, height: 44).background(Refined.neutral, in: Circle()).contentShape(Circle())
                }
                .accessibilityLabel("More")
            }
            .lineLimit(1)
            if let offer = AutoRunRules.offer(transcript, settings: auto.settings, templates: templates), offer.result == r.id {
                VStack(alignment: .leading, spacing: 8) {
                    Text(offer.text).refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink)
                    HStack(spacing: 8) {
                        Button("Run") { center.run(offer.template, on: transcript.id, store: app.store, replacing: offer.result, kind: offer.kind) }
                            .buttonStyle(RefinedActionStyle(kind: .strong)).accessibilityIdentifier("result.offer.run")
                        Button("Not now") {
                            app.store.update(transcript.id) { x in
                                if let i = x.templateResults?.firstIndex(where: { $0.id == offer.result }) { x.templateResults?[i].offerDismissed = offer.kind.rawValue }
                            }
                        }
                        .buttonStyle(RefinedActionStyle()).accessibilityIdentifier("result.offer.dismiss")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Refined.neutral, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
            }
            if r.skippedParts > 0 {
                Text("Apple Intelligence declined \(r.skippedParts) of \(r.totalParts) parts, so their words aren\u{2019}t in this result.")
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            if DayPlan.isPlan(r) {
                // Plan my day: the plan, with Send to Reminders (PhonePlanViews.swift).
                PhonePlanResult(transcript: transcript, result: r, onJump: onJump).padding(.top, 4)
            } else {
                TemplateResultBody(text: r.text, heading: .system(size: 20, design: .serif), textFont: .system(size: 16),
                                   ink: AnyShapeStyle(Refined.ink), dim: AnyShapeStyle(Refined.mute))
                    .padding(.top, 4)
            }
            Rectangle().fill(Refined.separator).frame(height: 1)
            Text(TemplateCopy.footer(madeOn: r.madeOn, here: TemplateCenter.here)).refinedFont(.meta).foregroundStyle(Refined.mute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Refined.neutral, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func runAgain(_ r: TemplateResult, force: Bool = false) {
        if r.edited && !force { confirmReplace = r; return }
        guard let next = TemplateLibrary.runAgain(r) else { return }
        center.run(next.template, on: transcript.id, store: app.store, replacing: next.replacing, kind: r.auto ? r.kind : nil)
    }

    private func editor(_ r: TemplateResult) -> some View {
        NavigationStack {
            TextEditor(text: $draft)
                .refinedFont(.body).foregroundStyle(Refined.ink).scrollContentBackground(.hidden).focused($focused)
                .padding(16)
                .background(Refined.paper.ignoresSafeArea())
                .navigationTitle(r.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let text = draft
                            app.store.update(transcript.id) { x in
                                if let i = x.templateResults?.firstIndex(where: { $0.id == r.id }) { x.templateResults?[i].text = text; x.templateResults?[i].edited = true }
                            }
                            editing = nil
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Save as note") {
                            app.store.addNote(Note(text: TemplateResultText.plain(draft), aiAction: r.name), to: transcript.id)
                            app.say("Saved as a note"); editing = nil
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } }
                }
                .accessibilityLabel("Result, editable. Made by Apple Intelligence")
        }
    }
}
