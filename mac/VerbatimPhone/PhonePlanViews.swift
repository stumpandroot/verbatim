import SwiftUI
import UIKit

// Plan my day on iPhone (approved mockup "Verbose Brain Dump", sections 5 to 7, October 27, 2026): the plan in a
// transcript's result tab, the kind-change offer for a recording filed as a Brain dump, Send to Reminders in both
// looks, and Organize today's thoughts with its plan screen. The plan's parts are shared with the Mac (PlanViews.swift).

// MARK: - The offer

/// "Now a Brain dump. Run Plan my day?" on a recording you filed as a Brain dump with nothing run automatically
/// (`AutoRunRules.brainDumpOffer`). Run runs it and shows the result; Not now never offers again.
struct PhoneKindOffer: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var onRun: () -> Void = {}
    @ObservedObject private var center = TemplateCenter.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @Environment(\.look) private var look

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
    @Environment(\.look) private var look
    @State private var sheet: SendToReminders? = nil
    @State private var toast: (message: String, list: String)? = nil

    private var plan: DayPlan { DayPlan.parse(result.text) }
    private var sent: [String: String] { result.sent ?? [:] }

    var body: some View {
        let plan = self.plan
        VStack(alignment: .leading, spacing: 12) {
            sendRow(plan)
            PlanSections(plan: plan, recordedAt: transcript.createdAt, sent: sent, native: look.isNative,
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
                    if look.isNative {
                        Button { open(plan, only: nil) } label: { Label("Sent to Reminders", systemImage: "checklist") }   // brand: native
                            .buttonStyle(.phoneSecondary).disabled(true)
                    } else {
                        Label { Text(DayPlan.sentStatus(plan, sent: sent) ?? "") } icon: { Image(systemName: "checkmark") }
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                    }
                } else {
                    Button { open(plan, only: nil) } label: { Text("Send to Reminders") }
                        .buttonStyle(.phonePrimary)
                        .accessibilityIdentifier("plan.sendToReminders")
                    if let status = DayPlan.sentStatus(plan, sent: sent) {
                        Text(status).font(.system(size: 13)).foregroundStyle(.lookMute)
                    }
                }
                Spacer(minLength: 0)
                if !sent.isEmpty {
                    Button("Open Reminders") { RemindersBridge.openReminders() }.font(.system(size: 14)).foregroundStyle(.lookInk)
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
    @Environment(\.look) private var look
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
            Text(message).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            Spacer(minLength: 6)
            Button("Open Reminders") { RemindersBridge.openReminders() }.font(.system(size: 14))
        }
        .foregroundStyle(.lookInk)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(look.isNative ? NativeInk.fill : Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay { if !look.isNative { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5) } }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Send to Reminders

/// The sheet: the list (a pop-up chip in Verbose style, a menu row in Native), every task checked and the ideas
/// unchecked, each with its due date ("Today", "Wed, Oct 28", or "No date"), and Add. A task gets a due date only when
/// you said a day. The first add asks for Reminders access; if you say no, the sheet says how to turn it on.
struct PhoneRemindersSheet: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject var model: SendToReminders
    var onSent: ([String: String], String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
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
                            Text("List").foregroundStyle(.lookInk)
                            Spacer()
                            Text(model.listTitle).foregroundStyle(.lookMute).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.lookMute)
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(model.lists.isEmpty)
                    .accessibilityLabel("List")
                    .accessibilityValue(model.listTitle)
                }
                let tasks = model.plan.tasks
                if !tasks.isEmpty {
                    Section(tasks.count == 1 ? "1 task" : "\(tasks.count) tasks") { ForEach(tasks) { row($0) } }
                }
                if !model.plan.ideas.isEmpty {
                    Section {
                        ForEach(model.plan.ideas) { row($0) }
                    } header: { Text(look.isNative ? "Ideas" : "Ideas · not sent unless you check them") }
                }
                Section {
                    if let p = model.problem {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(p).font(.system(size: 14)).foregroundStyle(.lookInk)
                            if model.access == .denied { Button("Open Settings") { RemindersBridge.openSettings() } }
                        }
                    }
                } footer: { Text("A task gets a due date only when you said a day.") }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(look.isNative ? .automatic : .hidden)
            .background(look.isNative ? Color.clear : Ink.paper)
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
                checkbox(on: on, sent: sent)
                if typeSize.isAccessibilitySize {
                    // Larger text: the date moves under the task.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text).foregroundStyle(.lookInk)
                        Text(due).font(look.isNative ? .footnote : Ink.mono(12)).foregroundStyle(.lookMute)
                    }
                } else {
                    Text(item.text).foregroundStyle(.lookInk).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(due).font(look.isNative ? .footnote : Ink.mono(12)).foregroundStyle(.lookMute).lineLimit(1).fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sent)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel("\(item.text), \(due)")
    }

    @ViewBuilder private func checkbox(on: Bool, sent: Bool) -> some View {
        if look.isNative {
            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? NativeInk.accent : NativeInk.tertiary)   // brand: native
                .font(.system(size: 20))
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Ink.ink, lineWidth: 1.5)
                .background(on ? Ink.ink : Color.clear, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay { if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.paper) } }
                .frame(width: 18, height: 18)
                .opacity(sent ? 0.5 : 1)
        }
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

/// Today's page's way into the plan: "Organize today's thoughts" (Verbose: a line pill under the day pills; Native: an
/// accent row), and once a plan is made, "Plan · made 3:20 PM", with how many thoughts came after it.
struct ThoughtsOrganizeRow: View {
    @EnvironmentObject var app: PhoneState
    var day: Date
    var isToday: Bool
    var thoughts: [Transcript]
    @ObservedObject private var center = DayPlanCenter.shared
    @Environment(\.look) private var look

    private var record: DayPlanRecord? { app.store.dayPlan(day, source: .thoughts) }
    private var title: String { isToday ? "Organize today\u{2019}s thoughts" : "Organize this day\u{2019}s thoughts" }

    var body: some View {
        let r = record
        let fresh = r?.newThoughts(in: thoughts.map(\.id)) ?? 0
        VStack(alignment: .leading, spacing: 8) {
            if let r, r.hasPlan {
                NavigationLink(value: ThoughtsPlanRoute(day: day)) {
                    HStack(spacing: 8) {
                        LookIcon(art: .iconPlanDay, symbol: "calendar.badge.checkmark", size: 16, color: Ink.ink, nativeColor: NativeInk.accent)
                        Text(Self.madeLine(r, newThoughts: fresh)).font(.system(size: 14)).foregroundStyle(.lookInk)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.lookMute)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("thoughts.plan")
            } else {
                Button { organize() } label: {
                    HStack(spacing: 8) {
                        if center.isRunning(day, .thoughts) { ProgressView().controlSize(.small) }
                        else { LookIcon(art: .iconPlanDay, symbol: "calendar.badge.checkmark", size: 16, color: Ink.ink, nativeColor: NativeInk.accent) }
                        Text(center.isRunning(day, .thoughts) ? "Making a plan\u{2026}" : title)
                            .font(.system(size: 15, weight: look.isNative ? .regular : .semibold))
                            .foregroundStyle(look.isNative ? AnyShapeStyle(NativeInk.accent) : AnyShapeStyle(Ink.ink))
                    }
                    .padding(.horizontal, look.isNative ? 0 : 14).frame(minHeight: look.isNative ? 44 : 34)
                    .overlay { if !look.isNative { Capsule().strokeBorder(Ink.ink, lineWidth: 1.5) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(center.isRunning(day, .thoughts) || DayPlanCenter.lines(thoughts).isEmpty)
                .accessibilityIdentifier("thoughts.organize")
                .accessibilityHint("Runs Plan my day over this page's thoughts.")
            }
            if let why = center.failure(day, .thoughts) {
                Text(why).font(.system(size: 13)).foregroundStyle(.lookMute).fixedSize(horizontal: false, vertical: true)
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

/// The plan from a day's thoughts (Verbose: the result card; Native: a pushed screen of grouped sections). Each task's
/// link names the thought's time and where it came from; tap it to go back to the thought on the page.
struct ThoughtsPlanScreen: View {
    @EnvironmentObject var app: PhoneState
    var day: Date
    @ObservedObject private var center = DayPlanCenter.shared
    @Environment(\.look) private var look
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
                if !look.isNative {
                    PhoneEyebrow(text: "Plan my day \u{00B7} \(DayPages.count(record?.thoughtIDs.count ?? thoughts.count, "thought", "thoughts"))")
                    SerifTitle("Plan ·", italic: DayPages.dateTitle(day), size: 28).foregroundStyle(.lookInk)
                } else {
                    Text("From \(DayPages.count(record?.thoughtIDs.count ?? thoughts.count, "thought", "thoughts")) · \(Formats.style(date: .full, time: .none).string(from: day))")
                        .font(.subheadline).foregroundStyle(NativeInk.secondary)
                }
                content
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
        .phoneTopFade()
        .phonePage(plain: true)
        .navigationTitle(look.isNative ? "Plan my day" : "")
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
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
            HStack(spacing: 10) { ProgressView(); Text("Making a plan from this page\u{2019}s thoughts\u{2026}").foregroundStyle(.lookDim) }
        } else if let why = center.failure(day, .thoughts) {
            Text(why).font(.system(size: 15)).foregroundStyle(.lookDim).fixedSize(horizontal: false, vertical: true)
        }
        if let r = record, r.hasPlan {
            let plan = r.plan
            let fresh = r.newThoughts(in: thoughts.map(\.id))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    LookIcon(art: .iconThought, symbol: "lightbulb", size: 13, color: Ink.mute, nativeColor: NativeInk.secondary)
                    Text("Made from \(DayPages.count(r.thoughtIDs.count, "thought", "thoughts")) at \(r.madeAt.map { Formats.style(date: .none, time: .short).string(from: $0) } ?? "")")
                }
                .font(.system(size: 14)).foregroundStyle(.lookMute)
                if fresh > 0 {
                    Text("\(fresh == 1 ? "1 new thought" : "\(fresh) new thoughts") since then. Run again to add them.").font(.system(size: 14)).foregroundStyle(.lookDim)
                }
                HStack(spacing: 8) {
                    if DayPlan.allSent(plan, sent: r.sent) {
                        Text(DayPlan.sentStatus(plan, sent: r.sent) ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(.lookInk)
                    } else {
                        Button("Send to Reminders") { openSheet(plan, r, only: nil) }.buttonStyle(.phonePrimary)
                            .accessibilityIdentifier("thoughtsPlan.send")
                    }
                    Button { DayPlanCenter.shared.organize(day: day, thoughts: thoughts, store: app.store) } label: { Label("Run again", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.phoneSecondary)
                        .disabled(center.isRunning(day, .thoughts))
                }
                .labelStyle(.titleAndIcon)
                PlanSections(plan: plan, recordedAt: day, sent: r.sent, native: look.isNative, headingSize: 20, textSize: 16,
                             link: { item in link(item, r) },
                             onJump: { _ in dismiss() },
                             onSend: { item in openSheet(plan, r, only: item) })
                if let toast { PhoneSentToast(message: toast) }
                Text(TemplateCopy.onDevice("iPhone") + " Made from this page\u{2019}s thoughts; it can be wrong, so check the plan before you rely on it.")
                    .font(.system(size: 13)).foregroundStyle(.lookMute).fixedSize(horizontal: false, vertical: true)
            }
            .padding(look.isNative ? 0 : 16)
            .modifier(PlanCardSurface(native: look.isNative))
        }
    }

    /// "7:12 AM · iPhone": the thought's time and where it came from.
    private func link(_ item: DayPlan.Item, _ r: DayPlanRecord) -> String? {
        guard let i = DayPlan.index(of: item, count: r.thoughtIDs.count), let t = app.store.transcript(r.thoughtIDs[i]) else { return nil }
        return "\(ThoughtText.time(t.createdAt, native: true)) \u{00B7} \(ThoughtText.origin(t))"
    }

    private func openSheet(_ plan: DayPlan, _ r: DayPlanRecord, only: DayPlan.Item?) {
        let model = SendToReminders(plan: plan, sent: r.sent, recordedAt: day, source: "Thoughts", anchorLabel: { link($0, r) })
        if let only { model.selection = [only.key] }
        sheet = model
    }
}

/// The plan's card: the reader card with the ink outline in Verbose style; nothing extra in Native, whose sections
/// are their own grouped cells.
struct PlanCardSurface: ViewModifier {
    var native: Bool
    func body(content: Content) -> some View {
        if native { content } else { content.phoneOutlined(radius: Radius.record, line: 1.5) }
    }
}
