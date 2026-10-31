import SwiftUI
import UIKit

// Plan my day on iPhone (approved mockup "Verbose Brain Dump", sections 5 to 7, October 27, 2026): the plan in a
// transcript's result tab, the kind-change offer for a recording filed as a Brain dump, Send to Reminders, and Organize
// today's thoughts with its plan screen, on the refined kit (DESIGN.md §13). The plan's parts are
// shared with the Mac (PlanViews.swift).

// MARK: - The offer

/// "Now a Brain dump. Run Plan my day?" on a recording you filed as a Brain dump with nothing run automatically
/// (`AutoRunRules.brainDumpOffer`). Run runs it and shows the result; Not now never offers again.
struct PhoneKindOffer: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var onRun: () -> Void = {}
    @ObservedObject private var center = TemplateCenter.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared

    var body: some View {
        if let offer = AutoRunRules.offer(transcript, settings: auto.settings, templates: app.store.allTemplates), offer.result == nil,
           !center.isPending(transcript.id), center.busyTemplate(transcript.id) == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(offer.text).refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink)
                HStack(spacing: 8) {
                    Button("Run") {
                        if let why = TemplateCenter.unavailableReason { app.say(why); return }
                        center.run(offer.template, on: transcript.id, store: app.store, kind: offer.kind)
                        onRun()
                    }
                    .buttonStyle(RefinedActionStyle(kind: .strong)).accessibilityIdentifier("offer.run")
                    Button("Not now") {
                        app.store.update(transcript.id) { AutoRunRules.dismissBrainDumpOffer(offer, on: &$0, device: Device.id) }
                    }
                    .buttonStyle(RefinedActionStyle()).accessibilityIdentifier("offer.dismiss")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        }
    }
}

// MARK: - The plan in a result

/// A Plan my day result: Send to Reminders (or how many are there), then the plan's sections. Each task's time plays
/// the line it came from.
struct PhonePlanResult: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var result: TemplateResult
    var onJump: ((Double) -> Void)? = nil
    @State private var sheet: SendToReminders? = nil
    @State private var toast: (message: String, list: String)? = nil

    private var plan: DayPlan { DayPlan.parse(result.text) }
    private var sent: [String: String] { result.sent ?? [:] }

    var body: some View {
        let plan = self.plan
        VStack(alignment: .leading, spacing: 12) {
            sendRow(plan)
            PlanSections(plan: plan, recordedAt: transcript.createdAt, sent: sent,
                         headingSize: 20, textSize: 16,
                         link: { $0.anchor.map(DayPlan.clock) },
                         onJump: jumpToItem,
                         onSend: { item in open(plan, only: item) })
            if let toast { PhoneSentToast(message: toast.message) }
        }
        .sheet(item: $sheet) { model in
            PhoneRemindersSheet(model: model) { added, message, list in
                app.store.update(transcript.id) { $0.recordSentReminders(added, result: result.id) }
                showToast(message, list)
            }
            .environmentObject(app)
        }
    }

    @ViewBuilder private func sendRow(_ plan: DayPlan) -> some View {
        if !plan.tasks.isEmpty || !plan.ideas.isEmpty {
            HStack(spacing: 10) {
                if DayPlan.allSent(plan, sent: sent) {
                    Label { Text(DayPlan.sentStatus(plan, sent: sent) ?? "") } icon: { Image(systemName: "checkmark") }
                        .refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText)
                } else {
                    Button { open(plan, only: nil) } label: { Text("Send to Reminders") }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                        .accessibilityIdentifier("plan.sendToReminders")
                    if let status = DayPlan.sentStatus(plan, sent: sent) {
                        Text(status).refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                }
                Spacer(minLength: 0)
                if !sent.isEmpty, RemindersBridge.canOpenReminders {
                    Button("Open Reminders") { RemindersBridge.openReminders() }
                        .refinedFont(.hint).foregroundStyle(Refined.accentText)
                        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                }
            }
        }
    }

    private var jumpToItem: ((DayPlan.Item) -> Void)? {
        guard let onJump else { return nil }
        return { (item: DayPlan.Item) in if let a = item.anchor { onJump(a) } }
    }

    private func open(_ plan: DayPlan, only: DayPlan.Item?) {
        let model = SendToReminders(plan: plan, sent: sent, recordedAt: transcript.createdAt, source: transcript.kind == .brainDump ? "Brain dump" : transcript.title,
                                    anchorLabel: { $0.anchor.map(DayPlan.clock) })
        if let only { model.selection = [only.key] }
        sheet = model
    }

    private func showToast(_ message: String, _ list: String) {
        let t = (message, list)
        toast = t
        app.say(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if toast?.message == t.0 { toast = nil } }
    }
}

extension SendToReminders: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// "Added 9 reminders to Studio" with Open Reminders, for three seconds after a send. It fades in place (no slide), so
/// Limit animation changes nothing here.
struct PhoneSentToast: View {
    var message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Refined.accentText)
            Text(message).refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(2)
            Spacer(minLength: 6)
            if RemindersBridge.canOpenReminders {
                Button("Open Reminders") { RemindersBridge.openReminders() }
                    .refinedFont(.hint).foregroundStyle(Refined.accentText)
                    .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Send to Reminders

/// The sheet, on the paper with its rows in cards: the list (a menu row), every task checked and the ideas unchecked, each with its due date ("Today", "Wed, Oct 28", or "No date"), and Add. A task gets a due date only when
/// you said a day. The first add asks for Reminders access; if you say no, the sheet says how to turn it on.
struct PhoneRemindersSheet: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject var model: SendToReminders
    var onSent: ([String: String], String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    /// For the self-test: the sheet on screen.
    static weak var shown: SendToReminders? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu {
                        ForEach(model.lists) { l in
                            Button { model.pick(l) } label: {
                                if l.id == model.list?.id { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                            }
                        }
                    } label: {
                        HStack {
                            Text("List").refinedFont(.body).foregroundStyle(Refined.ink)
                            Spacer()
                            Text(model.listTitle).refinedFont(.body).foregroundStyle(Refined.mute).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(Refined.mute)
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(model.lists.isEmpty)
                    .accessibilityLabel("List")
                    .accessibilityValue(model.listTitle)
                }
                .listRowBackground(Refined.card)
                let tasks = model.plan.tasks
                if !tasks.isEmpty {
                    Section(tasks.count == 1 ? "1 task" : "\(tasks.count) tasks") { ForEach(tasks) { row($0) } }
                        .listRowBackground(Refined.card)
                }
                if !model.plan.ideas.isEmpty {
                    Section {
                        ForEach(model.plan.ideas) { row($0) }
                    } header: { Text("Ideas · not sent unless you check them") }
                    .listRowBackground(Refined.card)
                }
                Section {
                    if let p = model.problem {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(p).refinedFont(.hint).foregroundStyle(Refined.ink)
                            if model.access == .denied {
                                Button("Open Settings") { RemindersBridge.openSettings() }.foregroundStyle(Refined.accentText)
                            }
                        }
                    }
                } footer: { Text("A task gets a due date only when you said a day.").foregroundStyle(Refined.mute) }
                .listRowBackground(Refined.card)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Refined.paper)
            .listRowSeparatorTint(Refined.separator)
            .navigationTitle("Send to Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.addTitle) { send() }
                        .disabled(model.sending || model.checkedCount == 0)
                        .accessibilityIdentifier("reminders.add")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { Self.shown = model }
        .onDisappear { if Self.shown === model { Self.shown = nil } }
    }

    private func row(_ item: DayPlan.Item) -> some View {
        let sent = model.isSent(item)
        let on = sent || model.selection.contains(item.key)
        let due = sent ? "Sent" : model.dueLabel(item)
        return Button { model.toggle(item); Haptics.play(.picked) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                RefinedCheckbox(on: on).opacity(sent ? 0.5 : 1)
                if typeSize.isAccessibilitySize {
                    // Larger text: the date moves under the task.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text).refinedFont(.body).foregroundStyle(Refined.ink)
                        Text(due).refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                } else {
                    Text(item.text).refinedFont(.body).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(due).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1).fixedSize()
                }
            }
            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sent)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel("\(item.text), \(due)")
    }

    private func send() {
        Task { @MainActor in
            guard let r = await model.send() else { Haptics.play(.failed); return }
            Haptics.play(.sentToReminders)
            onSent(r.added, r.message, r.list)
            dismiss()
        }
    }
}

// MARK: - Organize today's thoughts

struct ThoughtsPlanRoute: Hashable { var day: Date }

/// Today's page's way into the plan: "Organize today's thoughts" (a quiet action with the plan glyph), and once a plan
/// is made, "Plan · made 3:20 PM", with how many thoughts came after it.
struct ThoughtsOrganizeRow: View {
    @EnvironmentObject var app: PhoneState
    var day: Date
    var isToday: Bool
    var thoughts: [Transcript]
    @ObservedObject private var center = DayPlanCenter.shared

    private var record: DayPlanRecord? { app.store.dayPlan(day, source: .thoughts) }
    private var title: String { isToday ? "Organize today\u{2019}s thoughts" : "Organize this day\u{2019}s thoughts" }

    var body: some View {
        let r = record
        let fresh = r?.newThoughts(in: thoughts.map(\.id)) ?? 0
        VStack(alignment: .leading, spacing: 8) {
            if let r, r.hasPlan {
                NavigationLink(value: ThoughtsPlanRoute(day: day)) {
                    HStack(spacing: 12) {
                        IconSquare(art: .iconPlanDay, hue: .butter)
                        Text(Self.madeLine(r, newThoughts: fresh)).refinedFont(.rowTitle).foregroundStyle(Refined.ink)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.faint)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                    .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("thoughts.plan")
            } else {
                Button { organize() } label: {
                    HStack(spacing: 8) {
                        if center.isRunning(day, .thoughts) { ProgressView().controlSize(.small) }
                        else { IconGlyph(art: .iconPlanDay, size: 16, color: Refined.ink) }
                        Text(center.isRunning(day, .thoughts) ? "Making a plan\u{2026}" : title)
                    }
                }
                .buttonStyle(RefinedActionStyle(kind: .quiet))
                .disabled(center.isRunning(day, .thoughts) || DayPlanCenter.lines(thoughts).isEmpty)
                .accessibilityIdentifier("thoughts.organize")
                .accessibilityHint("Runs Plan my day over this page's thoughts.")
            }
            if let why = center.failure(day, .thoughts) {
                Text(why).refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Plan · made 3:20 PM", or "2 new thoughts since 3:20 PM".
    static func madeLine(_ r: DayPlanRecord, newThoughts: Int) -> String {
        let at = r.madeAt.map { Formats.style(date: .none, time: .short).string(from: $0) } ?? ""
        if newThoughts > 0 { return "\(newThoughts == 1 ? "1 new thought" : "\(newThoughts) new thoughts") since \(at)" }
        return "Plan \u{00B7} made \(at)"
    }

    private func organize() {
        DayPlanCenter.shared.organize(day: day, thoughts: thoughts, store: app.store)
        app.pushHere(ThoughtsPlanRoute(day: day))
    }
}

/// The plan from a day's thoughts: the large serif title, then the plan on a card. Each task's link names the thought's time and where it came from; tap it to go back to the thought on the page.
struct ThoughtsPlanScreen: View {
    @EnvironmentObject var app: PhoneState
    var day: Date
    @ObservedObject private var center = DayPlanCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: SendToReminders? = nil
    @State private var toast: String? = nil

    /// For the self-test.
    static var shown: Date? = nil

    private var record: DayPlanRecord? { app.store.dayPlan(day, source: .thoughts) }
    private var thoughts: [Transcript] { app.store.page(.idea, day: day, hour: app.newPageHour) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LargeSerifTitle(title: "Plan · \(DayPages.dateTitle(day))",
                                eyebrow: "Plan my day \u{00B7} \(DayPages.count(record?.thoughtIDs.count ?? thoughts.count, "thought", "thoughts"))")
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("Plan my day")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        .sheet(item: $sheet) { model in
            PhoneRemindersSheet(model: model) { added, message, _ in
                DayPlanCenter.shared.recordSent(added, day: day, source: .thoughts, store: app.store)
                toast = message; app.say(message)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if toast == message { toast = nil } }
            }
            .environmentObject(app)
        }
        .onAppear { Self.shown = day }
        .onDisappear { if Self.shown == day { Self.shown = nil } }
    }

    @ViewBuilder private var content: some View {
        if center.isRunning(day, .thoughts) {
            HStack(spacing: 10) { ProgressView(); Text("Making a plan from this page\u{2019}s thoughts\u{2026}").refinedFont(.body).foregroundStyle(Refined.dim) }
        } else if let why = center.failure(day, .thoughts) {
            Text(why).refinedFont(.body).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
        }
        if let r = record, r.hasPlan {
            let plan = r.plan
            let fresh = r.newThoughts(in: thoughts.map(\.id))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    IconGlyph(art: .iconThought, size: 13, color: Refined.mute)
                    Text("Made from \(DayPages.count(r.thoughtIDs.count, "thought", "thoughts")) at \(r.madeAt.map { Formats.style(date: .none, time: .short).string(from: $0) } ?? "")")
                }
                .refinedFont(.meta).foregroundStyle(Refined.mute)
                if fresh > 0 {
                    Text("\(fresh == 1 ? "1 new thought" : "\(fresh) new thoughts") since then. Run again to add them.").refinedFont(.hint).foregroundStyle(Refined.dim)
                }
                HStack(spacing: 8) {
                    if DayPlan.allSent(plan, sent: r.sent) {
                        Text(DayPlan.sentStatus(plan, sent: r.sent) ?? "").refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText)
                    } else {
                        Button("Send to Reminders") { openSheet(plan, r, only: nil) }.buttonStyle(RefinedActionStyle(kind: .strong))
                            .accessibilityIdentifier("thoughtsPlan.send")
                    }
                    Button { DayPlanCenter.shared.organize(day: day, thoughts: thoughts, store: app.store) } label: { Text("Run again") }
                        .buttonStyle(RefinedActionStyle(kind: .quiet))
                        .disabled(center.isRunning(day, .thoughts))
                }
                PlanSections(plan: plan, recordedAt: day, sent: r.sent, headingSize: 20, textSize: 16,
                             link: { item in link(item, r) },
                             onJump: { _ in dismiss() },
                             onSend: { item in openSheet(plan, r, only: item) })
                if let toast { PhoneSentToast(message: toast) }
                Text(TemplateCopy.onDevice("iPhone") + " Made from this page\u{2019}s thoughts; it can be wrong, so check the plan before you rely on it.")
                    .refinedFont(.meta).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        }
    }

    /// "7:12 AM · iPhone": the thought's time and where it came from.
    private func link(_ item: DayPlan.Item, _ r: DayPlanRecord) -> String? {
        guard let i = DayPlan.index(of: item, count: r.thoughtIDs.count), let t = app.store.transcript(r.thoughtIDs[i]) else { return nil }
        return "\(ThoughtText.time(t.createdAt, systemFormat: true)) \u{00B7} \(ThoughtText.origin(t))"
    }

    private func openSheet(_ plan: DayPlan, _ r: DayPlanRecord, only: DayPlan.Item?) {
        let model = SendToReminders(plan: plan, sent: r.sent, recordedAt: day, source: "Thoughts", anchorLabel: { link($0, r) })
        if let only { model.selection = [only.key] }
        sheet = model
    }
}
