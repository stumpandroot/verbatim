import SwiftUI
import UIKit

// Templates on the iPhone (mockup "Library features", section 1): Library › Templates (the library, a template's
// sections, Try on a recording, Run automatically for a kind, and your own templates), Settings › Templates (Run
// automatically: one template or Off per kind, and three options, kept on this iPhone), the result as a tab in the
// transcript, and Record a kind from a long press on Record. Built from the Settings page kit, so both looks follow.

struct TemplatesRoute: Hashable {}
struct TemplateDetailRoute: Hashable { var id: UUID }
struct TemplatesAutoRoute: Hashable {}

/// Touch and hold on Record: start recording as a kind you pick. The new transcript is that kind as yours, so AutoLabel
/// leaves it, and Run automatically runs that kind's template.
struct PhoneRecordKindItems: View {
    /// Starts the recording (the menu's owner passes `app.requestRecord(kind:)`, so it never needs the environment).
    var start: (RecordingKind) -> Void
    var body: some View {
        ForEach(RecordingKind.recordChoices) { k in
            Button(k.recordTitle) { start(k) }
        }
    }
}

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
                .font(.system(size: 15)).foregroundStyle(.lookDim).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            PhoneSegmented(options: [(TemplateOrigin?.none, "All"), (TemplateOrigin?.some(.builtIn), "Built in"),
                                     (TemplateOrigin?.some(.scenario), "Scenarios"), (TemplateOrigin?.some(.yours), "Yours")],
                           selection: $filter)
                .padding(.top, 14)
            SettingsPageGroup(first: true) {
                NavigationLink(value: TemplatesAutoRoute()) {
                    SettingsRow(icon: "arrow.triangle.2.circlepath", tint: Ink.sageTint, art: .iconRecent, title: "Run automatically",
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
                    .font(.system(size: 15)).foregroundStyle(.lookMute).padding(.top, 22)
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
        return SettingsRow(icon: t.nativeSymbol, tint: Ink.neutralChip, art: t.art, title: t.name, subtitle: TemplateLibrary.summaryLine(t), subtitleLines: 1) {
            if !kinds.isEmpty { Text("Auto").font(.system(size: 14)).foregroundStyle(.lookMute) }
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
    @State private var tryOn: PhoneTryOn? = nil
    @State private var confirmDelete = false

    var body: some View {
        if let t = TemplateLibrary.template(id, yours: app.store.templates) {
            content(t)
        } else {
            Text("This template was deleted.").foregroundStyle(.lookMute).frame(maxWidth: .infinity, maxHeight: .infinity).phonePage()
        }
    }

    private func content(_ t: TranscriptTemplate) -> some View {
        let kinds = t.kinds.isEmpty ? AutoRunSettings.kinds : t.kinds
        let recent = app.store.live.filter { $0.status == .ready && !$0.isDictation && !$0.segments.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }.prefix(12)
        return SettingsPageScaffold(title: t.name, eyebrow: t.origin.eyebrow) {
            VStack(alignment: .leading, spacing: 6) {
                Text(TemplateLibrary.summaryLine(t)).font(.system(size: 15)).foregroundStyle(.lookDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            SettingsPageGroup(title: "Sections", first: true) {
                ForEach(Array(t.sections.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { SettingsDivider() }
                    HStack(spacing: 12) {
                        Text(String(format: "%02d", i + 1)).lookMono(13).foregroundStyle(.lookMute)
                        Text(s.name).font(.system(size: 16)).foregroundStyle(.lookInk)
                        Spacer(minLength: 8)
                        Text(s.format.title).font(.system(size: 14)).foregroundStyle(.lookMute)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 46)
                }
            }
            SettingsPageGroup(title: "Run automatically for", footer: "A kind runs one template. Turning one on here replaces the template it had.") {
                ForEach(Array(kinds.enumerated()), id: \.element) { i, k in
                    if i > 0 { SettingsDivider() }
                    SettingsToggleRow(icon: k.nativeSymbol, tint: Ink.neutralChip, art: k.art, title: k.label,
                                      subtitle: other(k, t).map { "Now runs \($0)" },
                                      isOn: Binding(get: { auto.settings.template(for: k) == t.id }, set: { on in auto.set(on ? t.id : nil, for: k) }))
                        .accessibilityIdentifier("template.kind.\(k.rawValue)")
                }
            }
            SettingsPageGroup(footer: TemplateCopy.onDevice("iPhone")) {
                Menu {
                    if recent.isEmpty { Text("No recordings yet") }
                    ForEach(Array(recent)) { r in Button(r.title) { tryOn = PhoneTryOn(template: t, transcript: r.id) } }
                } label: {
                    SettingsRow(icon: "play.circle", tint: Ink.sageTint, art: .iconPlay, title: "Try on a recording", subtitle: "See the result; nothing is saved") {
                        SettingsMenuMark()
                    }
                }
                SettingsDivider()
                Button {
                    editingIsNew = true; editing = TemplateLibrary.duplicate(t)
                } label: {
                    SettingsRow(icon: "plus.square.on.square", tint: Ink.butterTint, art: .iconCopy, title: t.isEditable ? "Duplicate" : "Duplicate and edit") { SettingsChevron() }
                }
                .buttonStyle(SettingsRowPress())
                .accessibilityIdentifier("template.duplicate")
                if t.isEditable {
                    SettingsDivider()
                    Button { editingIsNew = false; editing = t } label: {
                        SettingsRow(icon: "square.and.pencil", tint: Ink.butterTint, art: .iconNotes, title: "Edit") { SettingsChevron() }
                    }
                    .buttonStyle(SettingsRowPress())
                    SettingsDivider()
                    Button { confirmDelete = true } label: {
                        SettingsRow(icon: "trash", tint: Ink.petalTint, art: .iconDeleteAll, title: "Delete template", danger: true) { EmptyView() }
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

struct PhoneTryOn: Identifiable {
    let id = UUID()
    var template: TranscriptTemplate
    var transcript: UUID
}

// MARK: - Run automatically

/// Settings › Templates and Library › Templates › Run automatically: one template or Off per kind, and Skip short
/// recordings, Show the result first, and Notify me when it's done. Kept on this iPhone; the results sync.
struct TemplatesAutoScreen: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var auto = TemplateSettingsModel.shared

    var body: some View {
        let all = app.store.allTemplates
        let settings = auto.settings.pruned(existing: Set(all.map(\.id)))
        SettingsPageScaffold(title: "Run automatically") {
            Text("Pick a template for each kind. It runs when a recording of that kind finishes, after the transcript and summary.")
                .font(.system(size: 15)).foregroundStyle(.lookDim).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            SettingsPageGroup(title: "When a recording finishes", first: true) {
                ForEach(Array(AutoRunSettings.kinds.enumerated()), id: \.element) { i, k in
                    if i > 0 { SettingsDivider() }
                    kindRow(k, all, settings)
                }
            }
            .settingsSearchTarget("templatesAuto", flash: nil)
            SettingsPageGroup(footer: TemplateCopy.onDevice("iPhone") + " Your Mac keeps its own choices; the results sync with the library.") {
                SettingsToggleRow(icon: "clock", tint: Ink.sageTint, art: .iconRecent, title: "Skip short recordings", subtitle: "Under 2 minutes",
                                  isOn: $auto.settings.skipShort)
                    .settingsSearchTarget("templatesSkipShort", flash: nil)
                SettingsDivider()
                SettingsToggleRow(icon: "doc.text", tint: Ink.sageTint, art: .iconSummaries, title: "Show the result first", subtitle: "Open transcripts on it",
                                  isOn: $auto.settings.showFirst)
                    .settingsSearchTarget("templatesShowFirst", flash: nil)
                SettingsDivider()
                SettingsToggleRow(icon: "bell", tint: Ink.sageTint, art: .iconAttention, title: "Notify me when it\u{2019}s done", subtitle: "For recordings over 20 minutes",
                                  isOn: $auto.settings.notify)
                    .settingsSearchTarget("templatesNotify", flash: nil)
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
            SettingsRow(icon: k.nativeSymbol, tint: Ink.neutralChip, art: k.art, title: k.label) {
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
    @State private var tryOn: PhoneTryOn? = nil
    @FocusState private var focused: Bool

    init(draft: TranscriptTemplate, isNew: Bool) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PhoneEyebrow(text: "Yours").padding(.top, 8)
                    field("Name") {
                        TextField("Website client call", text: $draft.name)
                            .font(.system(size: 17)).focused($focused)
                            .padding(.horizontal, 14).frame(minHeight: 48)
                            .accessibilityIdentifier("editor.name")
                    }
                    field("What should it write?") {
                        TextEditor(text: $draft.instructions)
                            .font(.system(size: 16)).scrollContentBackground(.hidden).focused($focused)
                            .frame(minHeight: 110).padding(8)
                    }
                    Text(TemplateCopy.ruleNote).font(.system(size: 13)).foregroundStyle(.lookMute)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).padding(.top, 6)
                    SettingsPageGroup(title: "Use it for") {
                        ForEach(Array(AutoRunSettings.kinds.enumerated()), id: \.element) { i, k in
                            if i > 0 { SettingsDivider() }
                            SettingsToggleRow(icon: k.nativeSymbol, tint: Ink.neutralChip, art: k.art, title: k.label,
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
                            SettingsRow(icon: "plus", tint: Ink.sageTint, art: nil, title: "Add a section") { EmptyView() }
                        }
                        .buttonStyle(SettingsRowPress())
                    }
                    if let problem {
                        Text(problem).font(.system(size: 14, weight: .semibold)).foregroundStyle(.lookAccentText).padding(.top, 14)
                    }
                    Text(TemplateCopy.onDevice("iPhone")).font(.system(size: 13)).foregroundStyle(.lookMute).padding(.top, 18)
                }
                .padding(.horizontal, 20).padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .phonePage()
            .navigationTitle(isNew ? "New template" : "Edit template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("editor.save") }
                ToolbarItem(placement: .bottomBar) {
                    Menu("Try on a recording") {
                        let recent = app.store.live.filter { $0.status == .ready && !$0.isDictation && !$0.segments.isEmpty }
                            .sorted { $0.createdAt > $1.createdAt }.prefix(12)
                        ForEach(Array(recent)) { r in Button(r.title) { tryOn = PhoneTryOn(template: draft, transcript: r.id) } }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } }
            }
            .sheet(item: $tryOn) { x in PhoneTemplateTryOnSheet(template: x.template, transcriptID: x.transcript).environmentObject(app) }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.lookInk).padding(.horizontal, 4)
            content().phoneOutlined(radius: Radius.row, line: 1)
        }
        .padding(.top, 16)
    }

    private func sectionRow(_ i: Int, _ s: TemplateSection) -> some View {
        let id = s.id
        return HStack(spacing: 10) {
            TextField("Section name", text: Binding(get: { draft.sections.first { $0.id == id }?.name ?? "" },
                                                    set: { v in if let j = draft.sections.firstIndex(where: { $0.id == id }) { draft.sections[j].name = v } }))
                .font(.system(size: 16)).focused($focused)
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
                    Text(s.format.title).font(.system(size: 14))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.lookMute)
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
    @Environment(\.look) private var look

    var body: some View {
        let t = app.store.transcript(transcriptID)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PhoneEyebrow(text: "On \u{201C}\(t?.title ?? "a recording")\u{201D} · nothing is saved")
                    switch preview.phase {
                    case .running:
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(preview.part.isEmpty ? "Working on your iPhone…" : preview.part).font(.system(size: 15)).foregroundStyle(.lookMute)
                        }
                        .padding(.top, 30).frame(maxWidth: .infinity)
                    case .done:
                        TemplateResultBody(text: preview.text, heading: look.serif(19), textFont: .system(size: 16),
                                           ink: AnyShapeStyle(.lookInk), dim: AnyShapeStyle(.lookMute))
                        Text(TemplateCopy.footer(madeOn: "iPhone", here: "iPhone")).font(.system(size: 13)).foregroundStyle(.lookMute)
                    case .failed:
                        Text(preview.failure ?? "Apple's on-device model didn't answer. Try again.").font(.system(size: 15)).foregroundStyle(.lookMute)
                            .padding(.top, 20)
                    }
                }
                .padding(20)
            }
            .phonePage()
            .navigationTitle(template.name.isEmpty ? "Try on" : template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { preview.stop(); dismiss() } }
                if preview.phase == .done {
                    ToolbarItem(placement: .primaryAction) { Button("Copy") { UIPasteboard.general.string = preview.text; app.say("Copied") } }
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
    @ObservedObject private var center = TemplateCenter.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @Environment(\.look) private var look
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
                    Text("\(m.name) didn\u{2019}t run").font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk)
                    if let note = m.note { Text(note).font(.system(size: 14)).foregroundStyle(.lookMute) }
                    Button("Run again") { center.run(m.templateId, on: transcript.id, store: app.store, kind: m.kind) }.buttonStyle(.phoneSecondary)
                }
            }
            if let why = center.failures[transcript.id] {
                Text(why).font(.system(size: 14)).foregroundStyle(.lookAccentText)
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
            PhoneEyebrow(text: "Template")
            Text(r.name).lookSerif(26).foregroundStyle(.lookInk).accessibilityAddTraits(.isHeader)
            if let reason = AutoRunRules.reason(r) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                    Text(reason)
                }
                .font(.system(size: 14)).foregroundStyle(.lookMute)
            }
            HStack(spacing: 8) {
                Button { runAgain(r) } label: { Label("Run again", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.phoneSecondary).disabled(center.busyTemplate(transcript.id) != nil)
                    .accessibilityIdentifier("result.runAgain")
                Button("Edit") { draft = r.text; editing = r }.buttonStyle(.phoneSecondary)
                    .accessibilityIdentifier("result.edit")
                Menu {
                    Menu("Run another template") {
                        ForEach(templates.filter { $0.id != r.templateId }) { t in
                            Button(t.name) { center.run(t.id, on: transcript.id, store: app.store) }
                        }
                    }
                    Button("Copy") { UIPasteboard.general.string = TemplateResultText.plain(r.text); app.say("Copied") }
                    ShareLink(item: TemplateResultText.plain(r.text)) { Text("Share") }
                    Button("Save as note") {
                        app.store.addNote(Note(text: TemplateResultText.plain(r.text), aiAction: r.name), to: transcript.id)
                        app.say("Saved as a note")
                    }
                    Button("Delete result", role: .destructive) { app.store.update(transcript.id) { $0.removeTemplateResult(r.id) } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .accessibilityLabel("More")
            }
            .labelStyle(.titleAndIcon)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            if let offer = AutoRunRules.offer(transcript, settings: auto.settings, templates: templates), offer.result == r.id {
                VStack(alignment: .leading, spacing: 8) {
                    Text(offer.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk)
                    HStack(spacing: 8) {
                        Button("Run") { center.run(offer.template, on: transcript.id, store: app.store, replacing: offer.result, kind: offer.kind) }
                            .buttonStyle(.phonePrimary).accessibilityIdentifier("result.offer.run")
                        Button("Not now") {
                            app.store.update(transcript.id) { x in
                                if let i = x.templateResults?.firstIndex(where: { $0.id == offer.result }) { x.templateResults?[i].offerDismissed = offer.kind.rawValue }
                            }
                        }
                        .buttonStyle(.phoneSecondary).accessibilityIdentifier("result.offer.dismiss")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(look.isNative ? NativeInk.fill : Ink.chip, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            }
            if r.skippedParts > 0 {
                Text("Apple Intelligence declined \(r.skippedParts) of \(r.totalParts) parts, so their words aren\u{2019}t in this result.")
                    .font(.system(size: 13)).foregroundStyle(.lookMute)
            }
            TemplateResultBody(text: r.text, heading: look.serif(20), textFont: .system(size: 16),
                               ink: AnyShapeStyle(.lookInk), dim: AnyShapeStyle(.lookMute))
                .padding(.top, 4)
            Rectangle().fill(.lookHairline).frame(height: 1)
            Text(TemplateCopy.footer(madeOn: r.madeOn, here: TemplateCenter.here)).font(.system(size: 13)).foregroundStyle(.lookMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneOutlined(radius: Radius.record, line: 1.5)
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 14)).foregroundStyle(.lookDim).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.isNative ? NativeInk.fill : Ink.chip, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func runAgain(_ r: TemplateResult, force: Bool = false) {
        if r.edited && !force { confirmReplace = r; return }
        center.run(r.templateId, on: transcript.id, store: app.store, replacing: r.auto ? r.id : nil, kind: r.auto ? r.kind : nil)
    }

    private func editor(_ r: TemplateResult) -> some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(.system(size: 16)).scrollContentBackground(.hidden).focused($focused)
                .padding(16)
                .phonePage()
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
