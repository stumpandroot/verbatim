import AppKit
import SwiftUI

// Today's page (mockup "Thoughts", section 02): the Thought pad, reworked, on the refined kit (DESIGN.md §13).
// The same floating, non-activating panel and size (380 × 540), with the dated serif title
// "Thoughts · Mon, Oct 26", each thought's time in a card of rows, arrows to earlier
// days (Next is off on today), the mic, and Copy and Send to <app> for the whole day. Click a thought to edit it;
// right-click to copy or delete it. No Clear: each day keeps its own page. While the panel is open, a dictation lands
// on today's page as a thought. The panel never makes Verbose the active app and becomes key only while you edit a
// thought, so the app you were in keeps its place and Send can paste straight into it.
//
// Since the consolidation (October 28, 2026) the page has a second mode, Write or dictate: the day's note, which took
// the Brain dump window's place (Views/DayNote.swift). In it the panel takes the keyboard so you can type, ⌃⌥
// dictation goes into the note, Copy and Send use the note, and Plan my day sorts it.

/// Today's page shows the day's thoughts, or the day's note (Write or dictate).
enum TodayPageMode: Hashable { case thoughts, note }

/// The page's day, which thought is being edited, and whether the panel may take the keyboard.
@MainActor
final class ThoughtPageState: ObservableObject {
    @Published var day = DayPages.today(hour: Thoughts.newPageHour)
    @Published var editing: UUID?
    /// Whether today's empty page plays its drawing this time it shows.
    @Published var playEmpty = false
    /// The saved action Copy and Send run first (nil is As is); kept here so it lasts while the page is closed.
    @Published var actionID: FlowAction.ID? = nil
    /// Whether the page is open. Closed, the panel holds an empty view, so nothing in it observes anything (see
    /// `ThoughtPadRoot`).
    @Published var shown = false
    /// The day's thoughts, or the day's note.
    @Published var mode: TodayPageMode = .thoughts

    var today: Date { DayPages.today(hour: Thoughts.newPageHour) }
    var isToday: Bool { day >= today }
    func move(_ step: Int) {
        let next = DayPages.day(day, moved: step)
        guard next <= today else { return }
        editing = nil
        day = next
    }
}

/// The floating page. Never key unless you're editing a thought, never main, and it never activates Verbose.
@MainActor
final class ThoughtPadController {
    static let shared = ThoughtPadController()
    weak var dictation: DictationController?
    let state = ThoughtPageState()
    private var panel: ThoughtPadPanel?

    var isOpen: Bool { panel?.isVisible == true }
    var panelWindow: NSWindow? { panel }

    func toggle() { isOpen ? close() : open() }

    /// Opens on today's page, in front of every app, without taking focus.
    func open() {
        if panel == nil { build() }
        guard let p = panel else { return }
        state.editing = nil
        state.mode = .thoughts
        state.day = state.today
        let today = state.today
        let empty = ThoughtCapture.shared.app?.store.page(.idea, day: today, hour: Thoughts.newPageHour).isEmpty ?? true
        state.playEmpty = empty && EmptyDayArt.shouldPlay(day: today)
        if !state.shown { state.shown = true }
        p.allowsKey = false
        p.orderFrontRegardless()
    }

    /// File › Today's Note: today's page on its note, with the keyboard, so you can type or hold ⌃⌥ and talk.
    func openNote() {
        open()
        setMode(.note)
    }

    /// Switches the page between the day's thoughts and its note. The note takes the keyboard; the thoughts give it back.
    func setMode(_ mode: TodayPageMode) {
        state.editing = nil
        if state.mode != mode { state.mode = mode }
        if mode == .note {
            beginEditing()
            DispatchQueue.main.async { DayNote.focus() }
        } else {
            endEditing()
        }
    }

    func close() {
        endEditing()
        panel?.orderOut(nil)
        if state.shown { state.shown = false }
        // The persimmon tint on the newest thought lasts until you've opened the page and closed it again.
        ThoughtCapture.shared.lastAdded = nil
    }

    /// Editing a thought needs the keyboard: the panel becomes key (Verbose still doesn't become active).
    func beginEditing() {
        guard let p = panel else { return }
        p.allowsKey = true
        p.makeKey()
    }

    /// Done editing: the panel lets go of the keyboard and the app you were in gets it back.
    func endEditing() {
        guard let p = panel else { return }
        let wasKey = p.isKeyWindow
        p.allowsKey = false
        if wasKey { yieldKeyboard(to: NSWorkspace.shared.frontmostApplication) }
    }

    /// When the page has keyboard focus, gives it back to `app` (the page stays on screen), so a paste lands there.
    func yieldKeyboard(to app: NSRunningApplication?) {
        guard let p = panel, p.isKeyWindow else { return }
        p.allowsKey = false
        p.orderOut(nil)
        if app?.bundleIdentifier != Bundle.main.bundleIdentifier { app?.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { p.orderFrontRegardless() }   // back on screen, not key
    }

    private func build() {
        let size = CGSize(width: 380, height: 540)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let f = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: f.maxX - size.width - 30, y: f.maxY - size.height - 30)
        let p = ThoughtPadPanel(contentRect: NSRect(origin: origin, size: size),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.minSize = CGSize(width: 340, height: 420)
        p.setFrameAutosaveName("VerbatimThoughtPad")
        guard let dictation else { return }
        // The page is never key while you read it, so its first click must count (it isn't spent making it key).
        p.contentView = FirstClickHostingView(rootView: ThoughtPadRoot(controller: self, dictation: dictation, state: state))
        // The title bar's close button closes the window without `close()`: the page empties the same way.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { ThoughtPadController.shared.state.shown = false }
        }
        panel = p
    }
    private var closeObserver: NSObjectProtocol?

    /// Pastes the page into the app you were using. The page steps aside first so the keystrokes reach that app.
    func send(_ text: String) {
        let target = NSWorkspace.shared.frontmostApplication
        close()
        target?.activate()   // the page may have had keyboard focus; make sure the keystrokes reach this app
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            let ctx = AppContext.capture(readText: false)
            let isUs = target?.bundleIdentifier == Bundle.main.bundleIdentifier
            let out: Paster.Outcome
            if isUs { Paster.copy(text); out = .copiedOnly }
            else { out = await Paster.paste(text, into: target, focusedField: ctx.hasFocusedField) }
            dictation?.bar?.flash(out == .pasted ? "Sent to \(target?.localizedName ?? "your app")" : "Copied. Click a text field and press ⌘V.", seconds: 3)
        }
    }
}

/// A hosting view whose first click acts, in a panel that isn't key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ThoughtPadPanel: NSPanel {
    /// Only while a thought is being edited.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - The page

/// The panel's root: today's page while it's open, an empty view while it's closed. AppKit keeps a closed panel's
/// views, and the page observes Limit Motion, the library, Thoughts, dictation, and actions: closed, it re-rendered
/// on every one of their changes (build 219). The page is built again when it opens.
private struct ThoughtPadRoot: View {
    let controller: ThoughtPadController
    let dictation: DictationController
    @ObservedObject var state: ThoughtPageState

    var body: some View {
        NavMarks.mark(state.shown ? "pad" : "pad-closed")
        return Group {
            if state.shown {
                ThoughtPageView(controller: controller, dictation: dictation, state: state).limitMotionRoot()
            } else {
                Color.clear
            }
        }
    }
}

struct ThoughtPageView: View {
    let controller: ThoughtPadController
    @ObservedObject var dictation: DictationController
    @ObservedObject var state: ThoughtPageState
    @ObservedObject private var capture = ThoughtCapture.shared
    @ObservedObject private var flow = FlowSettings.shared
    @State private var working = false
    @State private var frontApp = ""
    /// The note as you type it, and the day it belongs to; kept with that day a moment after you stop.
    @State private var note = ""
    @State private var noteDay: Date? = nil
    @State private var saveNote: DispatchWorkItem? = nil

    private var hour: Int { Thoughts.newPageHour }
    private var page: [Transcript] { capture.app?.store.page(.idea, day: state.day, hour: hour) ?? [] }

    var body: some View {
        let items = page
        page(items)
        .onAppear { updateFront(); loadNote() }
        .onChange(of: state.day) { _, _ in loadNote() }
        .onChange(of: state.mode) { _, _ in loadNote() }
        .onChange(of: note) { _, new in
            guard let d = noteDay, let store = capture.app?.store else { return }
            saveNote?.cancel()
            let w = DispatchWorkItem { DayPlanCenter.shared.saveNote(day: d, note: new, store: store) }
            saveNote = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
        .onDisappear { flushNote() }
        // Follows app switches as they happen, for "Send to <app>".
        .onReceive(Self.activations) { note in
            updateFront(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    // MARK: The note

    /// Saves the note you were writing (to its own day), then reads the page's day's note.
    private func loadNote() {
        flushNote()
        let d = state.day
        noteDay = d
        let stored = capture.app?.store.dayPlan(d, source: .note)?.note ?? ""
        if note != stored { note = stored }
    }

    private func flushNote() {
        saveNote?.cancel(); saveNote = nil
        guard let d = noteDay, let store = capture.app?.store else { return }
        DayPlanCenter.shared.saveNote(day: d, note: note, store: store)
    }

    /// The mode switch under the title: Thoughts | Write or dictate.
    private var modeSwitch: some View {
        RefinedSegmented(label: "Today's page shows", options: [(TodayPageMode.thoughts, "Thoughts"), (TodayPageMode.note, "Write or dictate")],
                         selection: Binding(get: { state.mode }, set: { controller.setMode($0) }))
            .fixedSize()
            .background {
                // The self-test's handles on each half.
                HStack(spacing: 0) {
                    Color.clear.uiTarget("page-mode-thoughts")
                    Color.clear.uiTarget("page-mode-note")
                }
                .allowsHitTesting(false)
            }
            .uiTarget("page-mode")
    }

    // MARK: The page

    private func page(_ items: [Transcript]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subtitle(items)).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                        Text((state.mode == .note ? "Note · " : "Thoughts · ") + DayPages.dateTitle(state.day))
                            .refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .accessibilityAddTraits(.isHeader)
                            .uiTarget("page-title")
                    }
                    Spacer(minLength: 8)
                    DayArrow(back: true, enabled: true) { state.move(-1) }.uiTarget("page-prev")
                    DayArrow(back: false, enabled: !state.isToday) { state.move(1) }.uiTarget("page-next")
                }
                modeSwitch
            }
            .padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 10)

            if state.mode == .note {
                DayNoteView(day: state.day, note: $note).padding(.horizontal, 14).padding(.bottom, 8)
            } else if items.isEmpty {
                ThoughtEmptyPage(isToday: state.isToday, play: state.playEmpty && state.isToday)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                                if i > 0 { PaperDivider(leading: 64, trailing: 12) }
                                ThoughtCard(transcript: t, highlighted: t.id == capture.lastAdded, state: state, controller: controller).id(t.id)
                            }
                        }
                        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    .onAppear { if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: items.count) { _, _ in if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                Text("Click a thought to edit it. Right-click to copy or delete it.").refinedFont(.caption).foregroundStyle(Refined.mute)
                    .padding(.horizontal, 18).padding(.vertical, 6)
                // Organize: Plan my day over the page (PlanMaker.swift), in its own window.
                ThoughtPadOrganizeRow(day: state.day, items: items).padding(.horizontal, 14).padding(.bottom, 8)
            }
            bottomBar(items)
        }
        .background(Refined.paper)
        .tint(Refined.accentText)
    }

    /// "Today · 6 thoughts", or the note's words.
    private func subtitle(_ items: [Transcript]) -> String {
        let day = state.isToday ? "Today" : DayPages.listDay(state.day)
        return day + " \u{00B7} " + (state.mode == .note ? DayPages.count(noteWords, "word", "words") : DayPages.count(items.count, "thought", "thoughts"))
    }

    private var noteWords: Int { note.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

    /// Copy and Send have something to work with: the day's thoughts, or the note.
    private func hasText(_ items: [Transcript]) -> Bool {
        state.mode == .note ? !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !items.isEmpty
    }

    /// The page's foot, on the card with a hairline above it (it carries text, so never glass).
    private func bottomBar(_ items: [Transcript]) -> some View {
        HStack(spacing: 8) {
            // The note fills from ⌃⌥ dictation and typing; the mic records thoughts.
            if state.mode == .thoughts { ThoughtMicDisc(size: 36).uiTarget("page-mic") }
            Picker("Action", selection: $state.actionID) {
                Text("As is").tag(FlowAction.ID?.none)
                ForEach(flow.actions) { a in Text(a.name).tag(FlowAction.ID?.some(a.id)) }
            }
            .labelsHidden().pickerStyle(.menu).frame(maxWidth: 120)   // a long action name truncates; it can't push the buttons
            .help("Run a saved action on the whole page before sending")
            Spacer(minLength: 4)
            if working { ProgressView().controlSize(.small) }
            Button("Copy") { copy(items) }.buttonStyle(RefinedActionStyle()).disabled(!hasText(items) || working)
                .uiTarget("page-copy")
            Button(frontApp.isEmpty ? "Send" : "Send to \(frontApp)") { send(items) }
                .buttonStyle(RefinedActionStyle(kind: .strong)).disabled(!hasText(items) || working)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Refined.card)
        .overlay(alignment: .top) { PaperDivider(leading: 0) }
    }

    // MARK: Copy and Send

    private func copy(_ items: [Transcript]) {
        let what = state.mode == .note ? "Today's note copied" : "Today's thoughts copied"
        Task { if let t = await result(items) { Paster.copy(t); controller.dictation?.bar?.flash(what, seconds: 2) } }
    }

    private func send(_ items: [Transcript]) {
        Task { if let t = await result(items) { controller.send(t) } }
    }

    /// The day's words, a blank line between thoughts (or the note), through the chosen action if there is one.
    private func result(_ items: [Transcript]) async -> String? {
        let text = state.mode == .note ? note.trimmingCharacters(in: .whitespacesAndNewlines) : Thoughts.joined(items)
        guard !text.isEmpty else { return nil }
        guard let id = state.actionID, let action = flow.actions.first(where: { $0.id == id }) else { return text }
        working = true
        defer { working = false }
        if let out = await FlowCleanup.apply(instruction: action.instruction, to: text, kind: action.kind) { return out }
        controller.dictation?.bar?.flash(FlowCleanup.available ? "Couldn't run “\(action.name)”" : "Actions need Apple Intelligence on macOS 26.", seconds: 3)
        return nil
    }

    /// One publisher for the view's life, so a render doesn't resubscribe.
    private static let activations = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)

    private func updateFront(_ activated: NSRunningApplication? = nil) {
        let a = activated ?? NSWorkspace.shared.frontmostApplication
        let full = a?.bundleIdentifier == Bundle.main.bundleIdentifier ? "" : (a?.localizedName ?? "")
        let name = full.count > 14 ? String(full.prefix(13)) + "…" : full
        if name != frontApp { frontApp = name }
    }
}

/// A round arrow to the day before or after, on the quiet wash. Next is off on today.
private struct DayArrow: View {
    var back: Bool
    var enabled: Bool
    var action: () -> Void
    var body: some View {
        Image(systemName: back ? "chevron.left" : "chevron.right").font(.system(size: 11, weight: .bold))
            .foregroundStyle(enabled ? Refined.ink : Refined.faint)
            .frame(width: 28, height: 28)
            .background(Refined.neutral, in: Circle())
            .contentShape(Circle())
            .tapArea { if enabled { action() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(back ? "Day before" : "Day after")
            .accessibilityAddTraits(.isButton)
            .help(back ? "Day before" : (enabled ? "Day after" : "This is today"))
    }
}

/// The microphone on today's page and By day: the persimmon disc (it starts a recording) with the Thoughts icon in the
/// fill's ink, and its live wave while a thought records. Click to start a thought; click again to stop.
struct ThoughtMicDisc: View {
    var size: CGFloat
    @ObservedObject private var capture = ThoughtCapture.shared
    var body: some View {
        ZStack {
            Circle().fill(Refined.persimmon)
            if capture.isRecording {
                ThoughtMicLevel(live: capture.recorder.live, color: Refined.onFill).padding(size * 0.2)
            } else {
                BrandGlyph(art: .capture, color: Refined.onFill, minLineWidth: 1.2).padding(size * 0.24)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .tapArea { capture.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(capture.isRecording ? "Stop the thought" : "New thought")
        .accessibilityAddTraits(.isButton)
        .help(capture.isRecording ? "Stop (\(Thoughts.hotkey))" : "New thought (\(Thoughts.hotkey))")
    }
}

/// The icon's wave following the mic.
struct ThoughtMicLevel: View {
    @ObservedObject var live: LiveMeter
    var color: Color = Refined.onFill
    var body: some View { ThoughtGlyph(level: Double(live.level), color: color, lineWidth: 1.4) }
}

/// A page with no thoughts: the empty-day drawing (played once, the first time today's page is empty) and a line.
struct ThoughtEmptyPage: View {
    var isToday: Bool
    var play: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EmptyDayArt(play: play).frame(maxWidth: 300).padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            Text(isToday ? "Nothing here yet" : "No thoughts on this day").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
            Text(isToday ? "Click the microphone, or press \(Thoughts.hotkey) in any app. Each thought lands here with its time." : "Use the arrows to read another day.")
                .refinedFont(.body).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.top, 8)
        .uiTarget("page-empty")
    }
}

/// One thought on the page, a row in the day's card: its time, its words (or "Saved as audio. Transcribing…", or
/// Transcribe again). The thought added last, and the one being edited, take the persimmon tint. Click to edit;
/// right-click to copy or delete.
struct ThoughtCard: View {
    let transcript: Transcript
    var highlighted: Bool
    @ObservedObject var state: ThoughtPageState
    let controller: ThoughtPadController

    var body: some View {
        let t = transcript
        let editing = state.editing == t.id
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Thoughts.time(t.createdAt, native: true)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
                .frame(width: 42, alignment: .leading)
            ThoughtWords(transcript: t, editing: editing, state: state, controller: controller)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted || editing ? Refined.persimmonTint : Color.clear)
        .contextMenu {
            if t.status == .ready { Button("Edit") { startEditing() } }
            Button("Copy") { Paster.copy(Thoughts.words(t)) }.disabled(Thoughts.words(t).isEmpty)
            Divider()
            Button("Delete", role: .destructive) {
                // Let the editor drop its binding first; removing under a focused field can crash.
                state.editing = nil
                let id = t.id
                DispatchQueue.main.async { ThoughtCapture.shared.delete(id) }
            }
        }
        .accessibilityElement(children: editing ? .contain : .combine)
    }

    private func startEditing() {
        state.editing = transcript.id
        controller.beginEditing()
    }
}

/// A thought's words, its transcribing state, or Transcribe again; an editor while it's being edited.
struct ThoughtWords: View {
    let transcript: Transcript
    var editing: Bool
    @ObservedObject var state: ThoughtPageState
    let controller: ThoughtPadController
    var fontSize: CGFloat = 13.5

    var body: some View {
        let t = transcript
        switch t.status {
        case .processing:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Saved as audio. Transcribing…").font(.system(size: fontSize)).foregroundStyle(Refined.dim)
                }
                Text("You can keep going; the words fill in here.").font(.system(size: 12)).foregroundStyle(Refined.mute)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    BrandGlyph(art: .iconAttention, color: Refined.ink, minLineWidth: 1.2).frame(width: 13, height: 13)
                    Text("Couldn't transcribe it. The audio is kept.").font(.system(size: fontSize)).foregroundStyle(Refined.ink)
                }
                Text("Transcribe again").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Refined.accentText)
                    .tapArea { if let app = ThoughtCapture.shared.app { app.retry(t) } }
                    .accessibilityAddTraits(.isButton)
            }
        case .ready:
            if editing {
                ThoughtEditor(id: t.id, text: Thoughts.words(t), fontSize: fontSize, state: state, controller: controller)
            } else {
                let w = Thoughts.words(t)
                Text(w.isEmpty ? "Nothing heard" : w).font(.system(size: fontSize))
                    .foregroundStyle(w.isEmpty ? Refined.mute : Refined.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { state.editing = t.id; controller.beginEditing() }
            }
        }
    }
}

/// Editing one thought. Saves as you type (a second after the last key) and when it loses focus.
private struct ThoughtEditor: View {
    let id: UUID
    @State var text: String
    var fontSize: CGFloat
    @ObservedObject var state: ThoughtPageState
    let controller: ThoughtPadController
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text).font(.system(size: fontSize)).scrollContentBackground(.hidden)
            .frame(minHeight: 54).focused($focused)
            .onAppear { focused = true }
            .onChange(of: text) { _, v in ThoughtCapture.shared.edit(id, to: v) }
            .onChange(of: focused) { _, f in
                if !f, state.editing == id { state.editing = nil; controller.endEditing() }
            }
            .onExitCommand { state.editing = nil; controller.endEditing() }
    }
}

/// Today's page's Organize: runs Plan my day over the page's thoughts and opens the plan in its own window
/// (`ThoughtsPlanWindow`), and once a plan is made, "Plan · made 3:20 PM · 2 new thoughts since". It never runs again
/// on its own.
struct ThoughtPadOrganizeRow: View {
    var day: Date
    var items: [Transcript]
    @ObservedObject private var center = DayPlanCenter.shared
    @ObservedObject private var capture = ThoughtCapture.shared

    var body: some View {
        let store = capture.app?.store
        let record = store?.dayPlan(day, source: .thoughts)
        let running = center.isRunning(day, .thoughts)
        HStack(spacing: 8) {
            if let r = record, r.hasPlan {
                let fresh = r.newThoughts(in: items.map(\.id))
                let at = r.madeAt.map { Formats.style(date: .none, time: .short).string(from: $0) } ?? ""
                Text("Plan \u{00B7} made \(at)" + (fresh > 0 ? " \u{00B7} \(fresh == 1 ? "1 new thought" : "\(fresh) new thoughts") since" : ""))
                    .refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                Spacer(minLength: 4)
                Button("Open plan") { open() }.buttonStyle(RefinedActionStyle())
                    .uiTarget("page-open-plan")
            } else {
                if let why = center.failure(day, .thoughts) {
                    Text(why).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(2)
                }
                Spacer(minLength: 4)
                if running { ProgressView().controlSize(.small) }
                Button { organize() } label: {
                    HStack(spacing: 6) {
                        IconGlyph(art: .iconPlanDay, size: 14, color: Refined.ink)
                        Text("Organize")
                    }
                }
                .buttonStyle(RefinedActionStyle())
                .disabled(running || DayPlanCenter.lines(items).isEmpty)
                .uiTarget("page-organize")
            }
        }
    }

    private func organize() {
        guard let app = capture.app else { return }
        DayPlanCenter.shared.organize(day: day, thoughts: items, store: app.store)
        ThoughtsPlanWindow.open(day: day, app: app)
    }

    private func open() {
        guard let app = capture.app else { return }
        ThoughtsPlanWindow.open(day: day, app: app)
    }
}
