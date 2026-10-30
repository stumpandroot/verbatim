import SwiftUI
import AppKit

// A template's result in the transcript (mockup "Library features", section 1d), on the refined kit (DESIGN.md §13): the template's name, why it ran
// ("Ran automatically because this is a Meeting"), Run again and Edit, the menu with Run another template, the
// result's sections, and the footer that says Apple Intelligence made it. While Run automatically's run waits or works,
// a line says so; when the kind changed after it ran, "Now a Journal. Run Daily reflection?" offers the new kind's
// template and never runs it on its own (the transcript shows that offer under its header). The transcript's result
// tab.

struct TemplateResultsSection: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    /// In the reading column (Show the result first), where there's room for a wider card.
    var inline = false
    /// The "Run a template" pill when there's no result. Off where the screen offers it elsewhere (review M-26).
    var runRow = true
    /// The kind-change offer ("Now a Journal. Run Daily reflection?"). The transcript shows it under its header
    /// (`KindOfferRow`), so its result tab leaves it out.
    var showsOffers = true
    @ObservedObject private var center = TemplateCenter.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @State private var editing: TemplateResult? = nil
    @State private var draft = ""
    @State private var confirmReplace: TemplateResult? = nil

    /// Show the result first: the transcript opens with its automatic result above the text.
    static func showsFirst(_ t: Transcript) -> Bool {
        TemplateSettingsModel.shared.settings.showFirst && t.shownTemplateResults.contains { $0.auto }
    }

    var body: some View {
        let results = transcript.shownTemplateResults
        let busy = center.busyTemplate(transcript.id)
        let templates = app.store.allTemplates
        VStack(alignment: .leading, spacing: 12) {
            if let b = busy {
                let name = templates.first { $0.id == b }?.name ?? "the template"
                statusRow("Running \(name)" + (center.progress[transcript.id].map { " · \($0)" } ?? "") + "…", spinner: true)
            } else if let waiting = transcript.autoRunWaitingText {
                statusRow(waiting, spinner: true)
            }
            if let m = transcript.autoRun, m.state == .failed, busy == nil, !results.contains(where: { $0.templateId == m.templateId }) {
                failedRow(m)
            }
            if let why = center.failures[transcript.id] {
                Text(why).refinedFont(.meta).foregroundStyle(Refined.accentText).fixedSize(horizontal: false, vertical: true)
            }
            // Filed as a Brain dump afterward, with nothing run: "Now a Brain dump. Run Plan my day?"
            if showsOffers, let offer = AutoRunRules.offer(transcript, settings: auto.settings, templates: templates), offer.result == nil,
               !center.isPending(transcript.id), busy == nil {
                offerRow(offer)
            }
            ForEach(results) { r in card(r, templates) }
            if runRow, results.isEmpty, busy == nil, transcript.status == .ready, transcript.autoRunWaitingText == nil {
                runMenu(title: "Run a template", replacing: nil, templates: templates)
                    .uiTarget("transcript-run-template")
            }
        }
        .sheet(item: $editing) { r in editor(r) }
        .confirmationDialog("Replace your edited result?", isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } }),
                            titleVisibility: .visible) {
            Button("Replace", role: .destructive) { if let r = confirmReplace { runAgain(r, force: true) } }
            Button("Keep Mine", role: .cancel) {}
        } message: { Text("Apple Intelligence writes it again, and your edits are gone.") }
    }

    // MARK: Card

    private func card(_ r: TemplateResult, _ templates: [TranscriptTemplate]) -> some View {
        let parts = TemplateTitle.split(r.name)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Template").refinedFont(.meta).foregroundStyle(Refined.mute)
                Text([parts.0, parts.1].compactMap { $0 }.joined(separator: " ")).refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let reason = AutoRunRules.reason(r) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                        Text(reason)
                    }
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
                }
            }
            HStack(spacing: 6) {
                // A cut template's result (Key points) has no Run again; a retired one's runs its replacement.
                if TemplateLibrary.runAgain(r) != nil {
                    Button("Run again") { runAgain(r) }.buttonStyle(RefinedActionStyle())
                        .disabled(center.busyTemplate(transcript.id) != nil)
                        .uiTarget("result-run-again")
                }
                Button("Edit") { draft = r.text; editing = r }.buttonStyle(RefinedActionStyle())
                    .uiTarget("result-edit")
                moreMenu(r, templates)
            }
            if showsOffers, let offer = AutoRunRules.offer(transcript, settings: auto.settings, templates: templates), offer.result == r.id {
                offerRow(offer)
            }
            if r.skippedParts > 0 {
                Text("Apple Intelligence declined \(r.skippedParts) of \(r.totalParts) parts, so their words aren\u{2019}t in this result.")
                    .refinedFont(.caption).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
            }
            if DayPlan.isPlan(r) {
                // Plan my day: the plan, with Send to Reminders (DayNote.swift's MacRemindersSend).
                MacPlanResult(transcript: transcript, result: r, inline: inline)
            } else {
                TemplateResultBody(text: r.text, heading: .system(size: inline ? 19 : 17, design: .serif), textFont: .system(size: 13.5),
                                   ink: AnyShapeStyle(Refined.ink), dim: AnyShapeStyle(Refined.mute))
            }
            Rectangle().fill(Refined.separator).frame(height: 1)
            Text(TemplateCopy.footer(madeOn: r.madeOn, here: TemplateCenter.here)).refinedFont(.meta).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .accessibilityElement(children: .contain)
    }

    private func offerRow(_ offer: AutoRunRules.Offer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.text).refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Run") {
                    center.run(offer.template, on: transcript.id, store: app.store, replacing: offer.result, kind: offer.kind)
                }
                .buttonStyle(RefinedActionStyle(kind: .strong))
                .uiTarget("result-offer-run")
                Button("Not now") {
                    app.store.update(transcript.id) { x in
                        if offer.result == nil { AutoRunRules.dismissBrainDumpOffer(offer, on: &x, device: Device.id); return }
                        if let i = x.templateResults?.firstIndex(where: { $0.id == offer.result }) { x.templateResults?[i].offerDismissed = offer.kind.rawValue }
                    }
                }
                .buttonStyle(RefinedActionStyle())
                .uiTarget("result-offer-dismiss")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Refined.neutral, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
    }

    private func moreMenu(_ r: TemplateResult, _ templates: [TranscriptTemplate]) -> some View {
        Menu {
            Menu("Run another template") {
                ForEach(templates.filter { $0.id != r.templateId }) { t in
                    Button(t.name) { center.run(t.id, on: transcript.id, store: app.store) }
                }
            }
            Divider()
            Button("Copy") { Paster.copy(TemplateResultText.plain(r.text)); app.toast = Toast("Copied") }
            Button("Save as Note") {
                app.store.addNote(Note(text: TemplateResultText.plain(r.text), aiAction: r.name), to: transcript.id)
                app.toast = Toast("Saved as a note")
            }
            Divider()
            Button("Delete Result", role: .destructive) { app.store.update(transcript.id) { $0.removeTemplateResult(r.id) } }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.ink)
                .frame(width: 32, height: 32)
                .background(Refined.neutral, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Run another template, copy, save as a note, or delete")
        .accessibilityLabel("More")
    }

    /// A menu of every template, for a transcript with no result yet.
    private func runMenu(title: String, replacing: UUID?, templates: [TranscriptTemplate]) -> some View {
        RunTemplateMenu(transcript: transcript, title: title, replacing: replacing, templates: templates)
    }

    private func statusRow(_ text: String, spinner: Bool) -> some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text).refinedFont(.meta).foregroundStyle(Refined.dim).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Refined.neutral, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func failedRow(_ m: AutoRunMark) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(m.name) didn\u{2019}t run").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink)
            if let note = m.note { Text(note).refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true) }
            if TemplateLibrary.current(m.templateId) != nil {
                Button("Run again") {
                    center.run(m.templateId, on: transcript.id, store: app.store, kind: m.kind)
                }
                .buttonStyle(RefinedActionStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Refined.neutral, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
    }

    // MARK: Actions

    /// Run again replaces the result; an edited one asks first. An automatic result stays marked as automatic.
    private func runAgain(_ r: TemplateResult, force: Bool = false) {
        if r.edited && !force { confirmReplace = r; return }
        guard let next = TemplateLibrary.runAgain(r) else { return }
        center.run(next.template, on: transcript.id, store: app.store, replacing: next.replacing, kind: r.auto ? r.kind : nil)
    }

    private func editor(_ r: TemplateResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit the result").refinedFont(.meta).foregroundStyle(Refined.mute)
            Text(r.name).refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
            TextEditor(text: $draft)
                .refinedFont(.body).foregroundStyle(Refined.ink).scrollContentBackground(.hidden)
                .padding(8)
                .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                .accessibilityLabel("Result, editable. Made by Apple Intelligence")
            Text("Headings start with ## and checklist lines with - [ ]. It stays marked as Apple Intelligence\u{2019}s.")
                .refinedFont(.caption).foregroundStyle(Refined.mute)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { editing = nil }.buttonStyle(RefinedActionStyle())
                Button("Save as Note") {
                    app.store.addNote(Note(text: TemplateResultText.plain(draft), aiAction: r.name), to: transcript.id)
                    app.toast = Toast("Saved as a note"); editing = nil
                }
                .buttonStyle(RefinedActionStyle())
                Button("Save") {
                    let text = draft
                    app.store.update(transcript.id) { x in
                        if let i = x.templateResults?.firstIndex(where: { $0.id == r.id }) { x.templateResults?[i].text = text; x.templateResults?[i].edited = true }
                    }
                    editing = nil
                }
                .buttonStyle(RefinedActionStyle(kind: .strong))
            }
        }
        .padding(22)
        .frame(width: 600, height: 520)
        .background(Refined.paper)
    }
}

/// A menu of every template, by where it came from, as the kit's quiet action: runs the chosen one on the transcript
/// (replacing a result when `replacing` is set). On the transcript's Summary tab and in a result's card.
struct RunTemplateMenu: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var title = "Run a template"
    var replacing: UUID? = nil
    var templates: [TranscriptTemplate]
    @ObservedObject private var center = TemplateCenter.shared

    var body: some View {
        Menu {
            ForEach(TemplateOrigin.allCases) { o in
                let items = templates.filter { $0.origin == o }
                if !items.isEmpty {
                    Section(o.title) {
                        ForEach(items) { t in Button(t.name) { center.run(t.id, on: transcript.id, store: app.store, replacing: replacing) } }
                    }
                }
            }
        } label: {
            Text(title)
        }
        .menuStyle(.button).buttonStyle(RefinedActionStyle()).menuIndicator(.hidden).fixedSize()
        .help("Make notes, a plan, or a draft from this transcript with a template")
        .accessibilityLabel(title)
    }
}

/// A Plan my day result in a transcript: Send to Reminders (a sheet) or how many are there, then the plan. Each task's
/// time plays the line it came from.
struct MacPlanResult: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var result: TemplateResult
    var inline = false
    @State private var model: SendToReminders? = nil

    var body: some View {
        let plan = DayPlan.parse(result.text)
        let sent = result.sent ?? [:]
        VStack(alignment: .leading, spacing: 10) {
            if !plan.isEmpty {
                HStack(spacing: 8) {
                    if DayPlan.allSent(plan, sent: sent) {
                        Text("\u{2713} " + (DayPlan.sentStatus(plan, sent: sent) ?? "")).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink)
                    } else {
                        Button("Send to Reminders") { open(plan, sent, only: nil) }
                            .buttonStyle(RefinedActionStyle(kind: .strong))
                            .uiTarget("result-send-reminders")
                        if let s = DayPlan.sentStatus(plan, sent: sent) { Text(s).refinedFont(.meta).foregroundStyle(Refined.mute) }
                    }
                }
            }
            PlanSections(plan: plan, recordedAt: transcript.createdAt, sent: sent,
                         headingSize: inline ? 19 : 17, textSize: 13,
                         link: { $0.anchor.map(DayPlan.clock) },
                         onJump: { item in if let a = item.anchor { app.player.play(from: a) } },
                         onSend: { open(plan, sent, only: $0) })
        }
        .sheet(isPresented: Binding(get: { model != nil }, set: { if !$0 { model = nil } })) {
            if let m = model { MacRemindersSend(model: m, onSent: done, onCancel: { model = nil }).environmentObject(app) }
        }
    }

    private func open(_ plan: DayPlan, _ sent: [String: String], only: DayPlan.Item?) {
        let m = SendToReminders(plan: plan, sent: sent, recordedAt: transcript.createdAt,
                                source: transcript.kind == .brainDump ? "Brain dump" : transcript.title, anchorLabel: { $0.anchor.map(DayPlan.clock) })
        if let only { m.selection = [only.key] }
        model = m
    }

    private func done(_ added: [String: String], _ message: String) {
        app.store.update(transcript.id) { $0.recordSentReminders(added, result: result.id) }
        app.toast = Toast(message)
        model = nil
    }
}
