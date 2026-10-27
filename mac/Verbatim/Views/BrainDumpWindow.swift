import SwiftUI
import AppKit

// brand: web style
//
// The Mac's brain dump (approved mockup "Verbose Brain Dump", sections 8 and 9, October 27, 2026; decision 9): its own
// window, opened from File › New Brain Dump, the menu bar panel, or Home's Brain dump tile, with one note for today.
// The note is a plain text view, so ⌃⌥ dictation types into it with the existing insertion path (the paste), and you
// can type and fix things between takes; dictations into it stay in the note and aren't listed in Dictations
// (decision 11, Dictation.swift). Make a plan runs Plan my day on the note's paragraphs; each task links to the
// paragraph it came from. Verbose style: the reader sheet with the plan column on the right and Send to Reminders in a
// popover. Native: a document window with Make a Plan as the prominent button, the plan in the inspector, and Send to
// Reminders in a sheet. The note and its plan are kept with the day (`plans.json`), so they sync.

@MainActor
enum BrainDumpWindow {
    private static var window: NSWindow?
    /// The note's text view, while the window is open (the self-test inserts into it as a paste would).
    static weak var textView: NSTextView?
    private static weak var app: AppState?

    /// The brain dump window has the keyboard: a dictation now goes into its note.
    static var isKey: Bool { window?.isKeyWindow == true }
    static var isOpen: Bool { window?.isVisible == true }

    /// Opens (or brings forward) today's brain dump.
    static func open(_ app: AppState?) {
        if let app { self.app = app }
        NSApp.activate(ignoringOtherApps: true)
        if let w = window { w.makeKeyAndOrderFront(nil); focusNote(); return }
        guard let app = app ?? self.app else { return }
        let root = BrainDumpView().environmentObject(app).limitMotionRoot().lookRoot()
        let host = NSHostingController(rootView: root)
        // Sized here, never from the content (NSHostingController sizing rules, DESIGN.md).
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "Brain Dump"
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 980, height: 640))
        w.minSize = NSSize(width: 640, height: 420)
        w.setFrameAutosaveName("VerbatimBrainDump")
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { focusNote() }
    }

    static func close() { window?.orderOut(nil) }

    static func focusNote() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Text at the note's cursor, as a paste puts it there (the self-test, and anything that inserts).
    static func insert(_ text: String) {
        guard let tv = textView else { return }
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    /// Selects a paragraph of the note (a plan task's ¶ link).
    static func select(paragraph text: String) {
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

/// The window's content.
struct BrainDumpView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.look) private var look
    @ObservedObject private var center = DayPlanCenter.shared
    @State private var note = ""
    @State private var loaded = false
    @State private var inspector = true
    @State private var save: DispatchWorkItem? = nil

    private var day: Date { Calendar.current.startOfDay(for: Date()) }
    private var record: DayPlanRecord? { app.store.dayPlan(day, source: .note) }
    private var words: Int { note.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

    var body: some View {
        Group {
            if look == .native { native } else { verbose }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            note = record?.note ?? ""
        }
        .onChange(of: note) { _, new in
            // Kept with the day a moment after you stop typing or dictating.
            save?.cancel()
            let d = day, store = app.store
            let w = DispatchWorkItem { DayPlanCenter.shared.saveNote(day: d, note: new, store: store) }
            save = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
        .onDisappear { DayPlanCenter.shared.saveNote(day: day, note: note, store: app.store) }
    }

    private func makePlan() {
        DayPlanCenter.shared.saveNote(day: day, note: note, store: app.store)
        DayPlanCenter.shared.planNote(day: day, note: note, store: app.store)
        inspector = true
    }

    private func copyNote() {
        Paster.copy(note)
        app.toast = Toast("Copied")
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Keycap(keys: "⌃", size: 12); Keycap(keys: "⌥", size: 12)
            Text("Hold to dictate here, or type. Your words stay in this note.")
        }
        .font(.system(size: 12.5)).foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.mute))
    }

    // MARK: Verbose

    private var verbose: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Brain dump · \(DayPlan.shortDay(day))")
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    WebText.serif("Brain", italic: "dump", size: 34).foregroundStyle(Ink.ink)
                    Text(DayPages.count(words, "word", "words")).font(Ink.mono(12.5)).foregroundStyle(Ink.mute)
                    Spacer()
                    PillButton(title: "Copy", kind: .line, size: .mini, icon: .iconCopy) { copyNote() }
                    if record?.hasPlan == true {
                        PillButton(title: "Run again", kind: .line, size: .mini, icon: .iconRecent, enabled: !center.isRunning(day, .note)) { makePlan() }
                            .uiTarget("braindump-run-again")
                    } else {
                        PillButton(title: "Make a plan", kind: .dark, size: .mini, icon: .iconPlanDay, enabled: !center.isRunning(day, .note)) { makePlan() }
                            .uiTarget("braindump-make-plan")
                    }
                }
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    BrainDumpTextView(text: $note, serif: false)
                        .padding(14)
                        .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5))
                    hint
                }
                .frame(maxWidth: .infinity)
                planColumn
                    .frame(width: 340)
            }
        }
        .padding(24)
        .background(Ink.paper)
    }

    @ViewBuilder private var planColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let r = record, r.hasPlan {
                    MacPlanPanel(source: .note, day: day)
                } else if center.isRunning(day, .note) {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Making a plan\u{2026}").foregroundStyle(Ink.dim) }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        WebText.serif("Your plan", italic: "shows here", size: 23).foregroundStyle(Ink.ink)
                        Text("Make a plan sorts this note into Top three, Today, Tomorrow, This week, Someday, and Ideas, using only what you said.")
                            .font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                        Text(TemplateCopy.onDevice("Mac")).font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
                }
                if let why = center.failure(day, .note) {
                    Text(why).font(.system(size: 12.5)).foregroundStyle(Ink.danger).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Native
    // brand: native begin

    private var native: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Brain Dump").font(.system(size: 15, weight: .bold))
                    Text("\(Formats.style(date: .full, time: .none).string(from: day)) · \(DayPages.count(words, "word", "words"))")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button { copyNote() } label: { Label("Copy", systemImage: "doc.on.doc") }
                if record?.hasPlan == true {
                    Button { inspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                } else {
                    Button { makePlan() } label: { Label("Make a Plan", systemImage: "calendar.badge.checkmark") }
                        .buttonStyle(.borderedProminent)
                        .disabled(center.isRunning(day, .note))
                        .uiTarget("braindump-make-plan")
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
            VStack(alignment: .leading, spacing: 8) {
                BrainDumpTextView(text: $note, serif: false)
                hint
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .inspector(isPresented: Binding(get: { inspector && (record?.hasPlan == true || center.isRunning(day, .note)) }, set: { inspector = $0 })) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if record?.hasPlan == true { MacPlanPanel(source: .note, day: day) }
                    else { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Making a plan\u{2026}").foregroundStyle(.secondary) } }
                    if let why = center.failure(day, .note) { Text(why).font(.system(size: 12)).foregroundStyle(NativeInk.danger) }
                }
                .padding(14)
            }
            .inspectorColumnWidth(min: 280, ideal: 310, max: 420)
        }
    }
    // brand: native end
}

/// The note: a plain NSTextView (no rich text), so a paste, typing, and ⌃⌥ dictation all land at the cursor.
struct BrainDumpTextView: NSViewRepresentable {
    @Binding var text: String
    var serif: Bool

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
        tv.setAccessibilityLabel("Brain dump note")
        BrainDumpWindow.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text, !context.coordinator.editing { tv.string = text }
        BrainDumpWindow.textView = tv
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BrainDumpTextView
        var editing = false
        init(_ p: BrainDumpTextView) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            editing = true
            parent.text = tv.string
            editing = false
        }
    }
}

// MARK: - The plan beside a note or a day's thoughts

/// A day's plan (the brain dump's note, or Organize today's thoughts): what it was made from, Send to Reminders
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
            if let i = DayPlan.index(of: item, count: r.paragraphs.count) { BrainDumpWindow.select(paragraph: r.paragraphs[i]) }
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

/// Organize on the Mac's today's page: the plan from the day's thoughts in its own window, which you can keep open
/// while you work.
@MainActor
enum ThoughtsPlanWindow {
    private static var window: NSWindow?
    static var isOpen: Bool { window?.isVisible == true }
    static func close() { window?.orderOut(nil) }

    static func open(day: Date, app: AppState) {
        let root = ScrollView { MacPlanPanel(source: .thoughts, day: day).padding(18) }
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
