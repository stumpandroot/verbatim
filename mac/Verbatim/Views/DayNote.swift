import SwiftUI
import AppKit

// brand: web style
//
// Today's page's note (consolidation, October 28, 2026): the Mac's Brain dump window became a mode of Today's page,
// "Write or dictate" (Flow/ThoughtPad.swift). File › Today's Note, the menu bar's Today's note, and Home's Brain dump
// tile open the page in that mode. The note is a plain text view, so you type and fix between takes; while the page
// shows the note, ⌃⌥ dictation goes straight into it at the cursor (`DayNote.insert`) and isn't listed in Dictations
// (decision 11, Dictation.swift). Plan my day runs on the note's paragraphs; each task links to its paragraph. The
// note and its plan are the day's (`DayPlanRecord`, source note, in `plans.json`), so they sync, and a note the Brain
// dump window kept is that day's page note as it is: nothing is copied, and an older build still opens it in its window.

/// The page's note while it's on screen: where dictation inserts, and where a plan task's ¶ link lands.
@MainActor
enum DayNote {
    /// The note's text view, while the page shows it.
    static weak var textView: NSTextView?

    /// Today's page is open on its note: a dictation goes into it, not into the front app or Dictations.
    static var isTarget: Bool {
        let pad = ThoughtPadController.shared
        return pad.isOpen && pad.state.mode == .note
    }

    /// File › Today's Note: today's page, in note mode, ready to type.
    static func open() { ThoughtPadController.shared.openNote() }

    static func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Text at the note's cursor (a dictation, the self-test).
    static func insert(_ text: String) {
        guard let tv = textView else { return }
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    /// Selects a paragraph of the note (a plan task's ¶ link), opening the page on its day first.
    static func select(paragraph text: String, day: Date) {
        let pad = ThoughtPadController.shared
        if !(pad.isOpen && pad.state.mode == .note) { pad.openNote() }
        if pad.state.day != day { pad.state.day = day }
        DispatchQueue.main.async {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let r = ns.range(of: text.components(separatedBy: " ").prefix(6).joined(separator: " "))
            guard r.location != NSNotFound else { return }
            let para = ns.paragraphRange(for: r)
            tv.setSelectedRange(para)
            tv.scrollRangeToVisible(para)
            tv.window?.makeFirstResponder(tv)
        }
    }
}

/// The page's note in either look: the text view, the ⌃⌥ hint, and Plan my day (its plan opens in its own window,
/// `ThoughtsPlanWindow`, as Organize's does).
struct DayNoteView: View {
    var day: Date
    @Binding var note: String
    @ObservedObject private var center = DayPlanCenter.shared
    @ObservedObject private var capture = ThoughtCapture.shared
    @Environment(\.look) private var look

    private var record: DayPlanRecord? { capture.app?.store.dayPlan(day, source: .note) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if look == .native {
                    DayNoteTextView(text: $note)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))   // brand: native
                } else {
                    DayNoteTextView(text: $note)
                        .padding(10)
                        .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5))
                }
            }
            .uiTarget("page-note")
            HStack(spacing: 6) {
                Keycap(keys: "⌃", size: 12); Keycap(keys: "⌥", size: 12)
                Text("Hold to dictate here, or type. Your words stay in this note.")
            }
            .font(.system(size: 12)).foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.mute))
            planRow
        }
    }

    @ViewBuilder private var planRow: some View {
        let running = center.isRunning(day, .note)
        HStack(spacing: 8) {
            if let r = record, r.hasPlan {
                let at = r.madeAt.map { Formats.style(date: .none, time: .short).string(from: $0) } ?? ""
                Text("Plan \u{00B7} made \(at)").font(.system(size: 12)).foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.mute)).lineLimit(1)
                Spacer(minLength: 4)
                PillButton(title: "Open Plan", kind: .line, size: .mini) { openPlan() }
                    .uiTarget("note-open-plan")
                PillButton(title: "Run again", kind: .line, size: .mini, icon: .iconRecent, enabled: !running) { plan() }
            } else {
                if let why = center.failure(day, .note) {
                    Text(why).font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(2)
                }
                Spacer(minLength: 4)
                if running { ProgressView().controlSize(.small) }
                // One plan maker, Plan my day, everywhere (Make a plan merged into it).
                PillButton(title: "Plan my day", kind: .line, size: .mini, icon: .iconPlanDay,
                           enabled: !running && !DayPlan.paragraphs(note).isEmpty) { plan() }
                    .uiTarget("note-plan-my-day")
            }
        }
    }

    private func plan() {
        guard let app = capture.app else { return }
        DayPlanCenter.shared.saveNote(day: day, note: note, store: app.store)
        DayPlanCenter.shared.planNote(day: day, note: note, store: app.store)
        ThoughtsPlanWindow.open(day: day, source: .note, app: app)
    }

    private func openPlan() {
        guard let app = capture.app else { return }
        ThoughtsPlanWindow.open(day: day, source: .note, app: app)
    }
}

/// The note: a plain NSTextView (no rich text), so a paste, typing, and ⌃⌥ dictation all land at the cursor.
struct DayNoteTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: 15)
        tv.textContainerInset = NSSize(width: 2, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.delegate = context.coordinator
        tv.string = text
        tv.setAccessibilityLabel("Today's note")
        DayNote.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text, !context.coordinator.editing { tv.string = text }
        DayNote.textView = tv
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DayNoteTextView
        var editing = false
        init(_ p: DayNoteTextView) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            editing = true
            parent.text = tv.string
            editing = false
        }
    }
}

// MARK: - The plan beside a note or a day's thoughts

/// A day's plan (the page's note, or Organize today's thoughts): what it was made from, Send to Reminders
/// (a popover in Verbose style, a sheet in Native), Run again, the sections, and the footer.
struct MacPlanPanel: View {
    @EnvironmentObject var app: AppState
    var source: DayPlanRecord.Source
    var day: Date
    @Environment(\.look) private var look
    @ObservedObject private var center = DayPlanCenter.shared
    @State private var model: SendToReminders? = nil

    private var record: DayPlanRecord? { app.store.dayPlan(day, source: source) }
    private var thoughts: [Transcript] { app.store.page(.idea, day: day, hour: Thoughts.newPageHour) }

    var body: some View {
        if let r = record, r.hasPlan {
            let plan = r.plan
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Template")
                    if look == .native { Text("Plan my day").font(.system(size: 15, weight: .bold)) }
                    else { WebText.serif("Plan my", italic: "day", size: 23).foregroundStyle(Ink.ink) }
                    Text(madeLine(r)).font(.system(size: 12)).foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.mute))
                }
                HStack(spacing: 6) {
                    if DayPlan.allSent(plan, sent: r.sent) {
                        Text("\u{2713} " + (DayPlan.sentStatus(plan, sent: r.sent) ?? "")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.ink)
                    } else {
                        PillButton(title: "Send to Reminders", kind: .dark, size: .mini) { open(plan, r, only: nil) }
                            .uiTarget("plan-send-reminders")
                            .popover(isPresented: Binding(get: { model != nil && look != .native }, set: { if !$0 { model = nil } }), arrowEdge: .bottom) {
                                if let m = model { MacRemindersSend(model: m, onSent: { sent(r, $0, $1) }, onCancel: { model = nil }).environmentObject(app) }
                            }
                    }
                    if source == .thoughts || r.hasPlan {
                        PillButton(title: "Run again", kind: .line, size: .mini, icon: .iconRecent, enabled: !center.isRunning(day, source)) { runAgain() }
                    }
                }
                PlanSections(plan: plan, recordedAt: day, sent: r.sent, native: look == .native, headingSize: 17, textSize: 13,
                             link: { link($0, r) }, onJump: { jump($0, r) }, onSend: { open(plan, r, only: $0) })
                Rectangle().fill(Ink.hairline).frame(height: 1)
                Text(TemplateCopy.onDevice("Mac") + (source == .note ? " Made from this note" : " Made from this day\u{2019}s thoughts") + "; it can be wrong, so check the plan before you rely on it.")
                    .font(.system(size: 12)).foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.dim)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(look == .native ? 0 : 16)
            .background { if look != .native { RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Ink.card) } }
            .overlay { if look != .native { RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5) } }
            .sheet(isPresented: Binding(get: { model != nil && look == .native }, set: { if !$0 { model = nil } })) {
                if let m = model { MacRemindersSend(model: m, onSent: { sent(r, $0, $1) }, onCancel: { model = nil }).environmentObject(app) }
            }
        }
    }

    private func madeLine(_ r: DayPlanRecord) -> String {
        let at = r.madeAt.map { Formats.style(date: .none, time: .short).string(from: $0) } ?? ""
        let count = DayPlan.parse(r.text).tasks.count
        if source == .thoughts {
            let fresh = r.newThoughts(in: thoughts.map(\.id))
            let base = "Made from \(DayPages.count(r.thoughtIDs.count, "thought", "thoughts")) at \(at)"
            return fresh > 0 ? base + " · \(fresh == 1 ? "1 new thought" : "\(fresh) new thoughts") since" : base
        }
        return "Made from this note at \(at) · \(DayPages.count(count, "task", "tasks"))"
    }

    private func link(_ item: DayPlan.Item, _ r: DayPlanRecord) -> String? {
        switch source {
        case .note:
            return DayPlan.index(of: item, count: r.paragraphs.count).map { "\u{00B6}\($0 + 1)" }
        case .thoughts:
            guard let i = DayPlan.index(of: item, count: r.thoughtIDs.count), let t = app.store.transcript(r.thoughtIDs[i]) else { return nil }
            return "\(ThoughtText.time(t.createdAt, native: true)) \u{00B7} \(ThoughtText.origin(t))"
        }
    }

    private func jump(_ item: DayPlan.Item, _ r: DayPlanRecord) {
        switch source {
        case .note:
            if let i = DayPlan.index(of: item, count: r.paragraphs.count) { DayNote.select(paragraph: r.paragraphs[i], day: day) }
        case .thoughts:
            if let i = DayPlan.index(of: item, count: r.thoughtIDs.count) {
                ThoughtPadController.shared.open()
                ThoughtPadController.shared.state.day = day
                ThoughtCapture.shared.lastAdded = r.thoughtIDs[i]
            }
        }
    }

    private func open(_ plan: DayPlan, _ r: DayPlanRecord, only: DayPlan.Item?) {
        let m = SendToReminders(plan: plan, sent: r.sent, recordedAt: day, source: source == .note ? "Brain dump" : "Thoughts", anchorLabel: { link($0, r) })
        if let only { m.selection = [only.key] }
        model = m
    }

    private func sent(_ r: DayPlanRecord, _ added: [String: String], _ message: String) {
        DayPlanCenter.shared.recordSent(added, day: day, source: source, store: app.store)
        app.toast = Toast(message)
        model = nil
    }

    private func runAgain() {
        switch source {
        case .note: DayPlanCenter.shared.planNote(day: day, note: record?.note ?? "", store: app.store)
        case .thoughts: DayPlanCenter.shared.organize(day: day, thoughts: thoughts, store: app.store)
        }
    }
}

/// Send to Reminders on the Mac: the list pop-up, each task with a checkbox and its due date, the ideas unchecked, and
/// Add as the default button. Verbose style draws it on the reader card (a popover); Native, as a standard sheet.
struct MacRemindersSend: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: SendToReminders
    var onSent: ([String: String], String) -> Void
    var onCancel: () -> Void
    @Environment(\.look) private var look

    /// On screen, for the self-test.
    static weak var shown: SendToReminders? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if look == .native {
                Text("Send to Reminders").font(.system(size: 15, weight: .bold))
                Text("Each task keeps the day you said as its due date.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                WebText.serif("Send \(DayPages.count(model.plan.tasks.count, "task", "tasks")) to", italic: "Reminders", size: 22).foregroundStyle(Ink.ink)
            }
            HStack {
                Text("List:").font(.system(size: 13))
                Picker("List", selection: Binding(get: { model.list?.id ?? "" }, set: { id in if let l = model.lists.first(where: { $0.id == id }) { model.pick(l) } })) {
                    if model.lists.isEmpty { Text("Reminders\u{2019} default list").tag("") }
                    ForEach(model.lists) { l in Text(l.title).tag(l.id) }
                }
                .labelsHidden().fixedSize()
                .disabled(model.lists.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.plan.tasks) { row($0) }
                    if !model.plan.ideas.isEmpty {
                        Text("Ideas · not sent unless you check them").font(.system(size: 12)).foregroundStyle(Ink.mute).padding(.top, 8)
                        ForEach(model.plan.ideas) { row($0) }
                    }
                }
            }
            .frame(maxHeight: 300)
            if let p = model.problem {
                HStack(spacing: 8) {
                    Text(p).font(.system(size: 12.5)).foregroundStyle(Ink.danger).fixedSize(horizontal: false, vertical: true)
                    if model.access == .denied { PillButton(title: "Open Settings", kind: .line, size: .mini) { RemindersBridge.openSettings() } }
                }
            }
            HStack(spacing: 8) {
                Text("Due dates only where you said a day.").font(.system(size: 12)).foregroundStyle(Ink.mute)
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button(model.checkedCount == 0 ? "Add" : "Add \(model.checkedCount)") { send() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle(kind: .dark, size: .mini))
                    .disabled(model.sending || model.checkedCount == 0)
                    .uiTarget("reminders-add")
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(look == .native ? Color.clear : Ink.card)
        .onAppear { Self.shown = model }
        .onDisappear { if Self.shown === model { Self.shown = nil } }
    }

    private func row(_ item: DayPlan.Item) -> some View {
        let sent = model.isSent(item)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: Binding(get: { sent || model.selection.contains(item.key) }, set: { _ in model.toggle(item) })) {
                Text(item.text).font(.system(size: 13)).foregroundStyle(sent ? Ink.dim : Ink.ink).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .disabled(sent)
            Spacer(minLength: 6)
            Text(sent ? "Sent" : model.dueLabel(item)).font(Ink.mono(12)).foregroundStyle(Ink.mute)
        }
    }

    private func send() {
        Task { @MainActor in
            guard let r = await model.send() else { return }
            onSent(r.added, r.message)
        }
    }
}

/// The Mac's today's page's plans (Organize on the day's thoughts, Plan my day on the note) in their own window, which
/// you can keep open while you work.
@MainActor
enum ThoughtsPlanWindow {
    private static var window: NSWindow?
    static var isOpen: Bool { window?.isVisible == true }
    static func close() { window?.orderOut(nil) }

    static func open(day: Date, source: DayPlanRecord.Source = .thoughts, app: AppState) {
        let root = ScrollView { MacPlanPanel(source: source, day: day).padding(18) }
            .frame(minWidth: 360, minHeight: 360)
            .background(Ink.paper)
            .environmentObject(app).limitMotionRoot().lookRoot()
        if let w = window {
            (w.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(root)
            w.makeKeyAndOrderFront(nil); return
        }
        let host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .resizable]
        w.title = "Plan · " + DayPages.dateTitle(day)
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 420, height: 600))
        w.setFrameAutosaveName("VerbatimThoughtsPlan")
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
