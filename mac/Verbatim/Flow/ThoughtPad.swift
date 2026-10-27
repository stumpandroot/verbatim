import AppKit
import SwiftUI

// brand: web style
//
// Today's page (mockup "Thoughts", section 02): the Thought pad, reworked. The same floating, non-activating panel and
// size (380 × 540), with the dated title "Thoughts · Mon, Oct 26", a mono time on every thought, arrows to earlier
// days (Next is off on today), the mic, and Copy and Send to <app> for the whole day. Click a thought to edit it;
// right-click to copy or delete it. No Clear: each day keeps its own page. While the panel is open, a dictation lands
// on today's page as a thought. The panel never makes Verbose the active app and becomes key only while you edit a
// thought, so the app you were in keeps its place and Send can paste straight into it.

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
        state.day = state.today
        let today = state.today
        let empty = ThoughtCapture.shared.app?.store.page(.idea, day: today, hour: Thoughts.newPageHour).isEmpty ?? true
        state.playEmpty = empty && EmptyDayArt.shouldPlay(day: today)
        if !state.shown { state.shown = true }
        p.allowsKey = false
        p.orderFrontRegardless()
    }

    func close() {
        endEditing()
        panel?.orderOut(nil)
        if state.shown { state.shown = false }
        // The ink outline on the newest thought lasts until you've opened the page and closed it again.
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
/// views, and the page observes the look, Limit Motion, the library, Thoughts, dictation, and actions: closed, it
/// re-rendered on every one of their changes, and at a look switch it built the whole page again in the new look
/// (build 219: part of the 330 ms the Mac's look switches grew, once the self-test had opened the page). The page is
/// built again, in the current look, when it opens.
private struct ThoughtPadRoot: View {
    let controller: ThoughtPadController
    let dictation: DictationController
    @ObservedObject var state: ThoughtPageState

    var body: some View {
        LookSwitch.mark(state.shown ? "pad" : "pad-closed")
        return Group {
            if state.shown {
                ThoughtPageView(controller: controller, dictation: dictation, state: state).limitMotionRoot().lookRoot()
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
    @Environment(\.look) private var look
    @State private var working = false
    @State private var frontApp = ""

    private var hour: Int { Thoughts.newPageHour }
    private var page: [Transcript] { capture.app?.store.page(.idea, day: state.day, hour: hour) ?? [] }

    var body: some View {
        let items = page
        Group {
            if look == .native {
                NativeThoughtPage(state: state, items: items, frontApp: frontApp, working: working, actionID: $state.actionID,
                                  copy: { copy(items) }, send: { send(items) })
            } else {
                verbose(items)
            }
        }
        .onAppear { updateFront() }
        // Follows app switches as they happen, for "Send to <app>".
        .onReceive(Self.activations) { note in
            updateFront(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    // MARK: Verbose

    private func verbose(_ items: [Transcript]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 7, height: 7)
                    Text("Thoughts").font(Ink.mono(12)).foregroundStyle(Ink.dim)
                    DottedRule().frame(height: 1)
                    Text(DayPages.count(items.count, "thought", "thoughts")).font(Ink.mono(12)).monospacedDigit().foregroundStyle(Ink.mute)
                }
                HStack(alignment: .center) {
                    WebText.serif("Thoughts ·", italic: DayPages.dateTitle(state.day), size: 22).foregroundStyle(Ink.ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                        .uiTarget("page-title")
                    Spacer(minLength: 8)
                    DayArrow(back: true, enabled: true) { state.move(-1) }.uiTarget("page-prev")
                    DayArrow(back: false, enabled: !state.isToday) { state.move(1) }.uiTarget("page-next")
                }
            }
            .padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 8)

            if items.isEmpty {
                ThoughtEmptyPage(isToday: state.isToday, play: state.playEmpty && state.isToday)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { t in
                                ThoughtCard(transcript: t, outlined: t.id == capture.lastAdded, state: state, controller: controller).id(t.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    .onAppear { if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: items.count) { _, _ in if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                Text("Click a thought to edit it. Right-click to copy or delete it.").font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                    .padding(.horizontal, 18).padding(.vertical, 6)
            }
            bottomBar(items)
        }
        .background(Ink.paper)
    }

    private func bottomBar(_ items: [Transcript]) -> some View {
        HStack(spacing: 8) {
            ThoughtMicDisc(size: 38).uiTarget("page-mic")
            Picker("Action", selection: $state.actionID) {
                Text("As is").tag(FlowAction.ID?.none)
                ForEach(flow.actions) { a in Text(a.name).tag(FlowAction.ID?.some(a.id)) }
            }
            .labelsHidden().pickerStyle(.menu).frame(maxWidth: 120)   // a long action name truncates; it can't push the buttons
            .help("Run a saved action on the whole page before sending")
            Spacer(minLength: 4)
            if working { ProgressView().controlSize(.small) }
            PillButton(title: "Copy", kind: .line, size: .mini, enabled: !items.isEmpty && !working) { copy(items) }
                .uiTarget("page-copy")
            PillButton(title: frontApp.isEmpty ? "Send" : "Send to \(frontApp)", kind: .dark, size: .mini, enabled: !items.isEmpty && !working) { send(items) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Ink.bar)
        .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }

    // MARK: Copy and Send

    private func copy(_ items: [Transcript]) {
        Task { if let t = await result(items) { Paster.copy(t); controller.dictation?.bar?.flash("Today's thoughts copied", seconds: 2) } }
    }

    private func send(_ items: [Transcript]) {
        Task { if let t = await result(items) { controller.send(t) } }
    }

    /// The day's words, a blank line between thoughts, through the chosen action if there is one.
    private func result(_ items: [Transcript]) async -> String? {
        let text = Thoughts.joined(items)
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

/// A round arrow to the day before or after. Next is off on today.
private struct DayArrow: View {
    var back: Bool
    var enabled: Bool
    var action: () -> Void
    var body: some View {
        Image(systemName: back ? "chevron.left" : "chevron.right").font(.system(size: 11, weight: .bold))
            .foregroundStyle(enabled ? Ink.ink : Ink.faint)
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(enabled ? Ink.ink : Ink.faint, lineWidth: 1.5))
            .contentShape(Circle())
            .tapArea { if enabled { action() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(back ? "Day before" : "Day after")
            .accessibilityAddTraits(.isButton)
            .help(back ? "Day before" : (enabled ? "Day after" : "This is today"))
    }
}

/// The microphone on today's page and in the Library: persimmon (system red, flat, in Native: red means recording), and
/// the Thoughts icon with its live wave while a thought records. Click to start a thought; click again to stop.
struct ThoughtMicDisc: View {
    var size: CGFloat
    @ObservedObject private var capture = ThoughtCapture.shared
    @Environment(\.look) private var look
    var body: some View {
        ZStack {
            Circle().fill(look == .native ? NativeInk.record : Ink.persimmon)
            if capture.isRecording {
                ThoughtMicLevel(live: capture.recorder.live).padding(size * 0.2)
            } else {
                BrandGlyph(art: .capture, color: Ink.inkFixed, minLineWidth: 1.2).padding(size * 0.24)
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

/// The icon's wave following the mic, in ink on persimmon.
struct ThoughtMicLevel: View {
    @ObservedObject var live: LiveMeter
    var color: Color = Ink.inkFixed
    var body: some View { ThoughtGlyph(level: Double(live.level), color: color, lineWidth: 1.4) }
}

/// A page with no thoughts: the empty-day drawing (played once, the first time today's page is empty) and a line.
struct ThoughtEmptyPage: View {
    var isToday: Bool
    var play: Bool
    @Environment(\.look) private var look
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EmptyDayArt(play: play).frame(maxWidth: 300).padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            if look == .native {
                Text(isToday ? "No Thoughts Yet" : "No Thoughts on This Day").font(.system(size: 15, weight: .semibold))
            } else {
                Text(isToday ? "Nothing here yet" : "No thoughts on this day").font(Ink.serif(18)).foregroundStyle(Ink.ink)
            }
            Text(isToday ? "Click the microphone, or press \(Thoughts.hotkey) in any app. Each thought lands here with its time." : "Use the arrows to read another day.")
                .font(.system(size: 13)).foregroundStyle(look == .native ? Color.secondary : Ink.mute).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.top, 8)
        .uiTarget("page-empty")
    }
}

/// One thought on the page: its time in mono, its words (or "Saved as audio. Transcribing…", or Transcribe again).
/// Click to edit; right-click to copy or delete.
struct ThoughtCard: View {
    let transcript: Transcript
    var outlined: Bool
    @ObservedObject var state: ThoughtPageState
    let controller: ThoughtPadController
    @Environment(\.look) private var look

    var body: some View {
        let t = transcript
        let editing = state.editing == t.id
        let shape = RoundedRectangle(cornerRadius: look == .native ? 14 : Radius.row, style: .continuous)
        Group {
            if look == .native {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Thoughts.time(t.createdAt, native: true)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)   // brand: native
                    ThoughtWords(transcript: t, editing: editing, state: state, controller: controller)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PremiumInk.card, in: shape)
                .overlay(shape.strokeBorder(outlined || editing ? NativeInk.accent : Color.clear, lineWidth: 1.5))   // brand: native
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Thoughts.time(t.createdAt, native: false)).font(Ink.mono(12.5)).monospacedDigit().foregroundStyle(Ink.mute)
                        .frame(width: 42, alignment: .leading)
                    ThoughtWords(transcript: t, editing: editing, state: state, controller: controller)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Flat on the paper with a hairline under it (DESIGN.md §14.5); only the thought added last (or the one
                // being edited) takes the reader fill and the 1.5 pt ink outline.
                .background(outlined || editing ? Ink.reader : Color.clear, in: shape)
                .overlay(shape.strokeBorder(Ink.ink, lineWidth: 1.5).opacity(outlined || editing ? 1 : 0))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Ink.hairline).frame(height: 1).opacity(outlined || editing ? 0 : 1).allowsHitTesting(false)
                }
            }
        }
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
    @Environment(\.look) private var look

    var body: some View {
        let t = transcript
        switch t.status {
        case .processing:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Saved as audio. Transcribing…").font(.system(size: fontSize))
                        .foregroundStyle(look == .native ? Color.secondary : Ink.dim)
                }
                if look != .native {
                    Text("You can keep going; the words fill in here.").font(.system(size: 12)).foregroundStyle(Ink.mute)
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    BrandGlyph(art: .iconAttention, color: look == .native ? NativeInk.danger : Ink.danger, minLineWidth: 1.2).frame(width: 13, height: 13)
                    Text("Couldn't transcribe it. The audio is kept.").font(.system(size: fontSize))
                        .foregroundStyle(look == .native ? NativeInk.danger : Ink.danger)
                }
                Text("Transcribe again").font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(look == .native ? NativeInk.accent : Ink.ink).underline(look != .native)
                    .tapArea { if let app = ThoughtCapture.shared.app { app.retry(t) } }
                    .accessibilityAddTraits(.isButton)
            }
        case .ready:
            if editing {
                ThoughtEditor(id: t.id, text: Thoughts.words(t), fontSize: fontSize, state: state, controller: controller)
            } else {
                let w = Thoughts.words(t)
                Text(w.isEmpty ? "Nothing heard" : w).font(.system(size: fontSize))
                    .foregroundStyle(w.isEmpty ? (look == .native ? Color.secondary : Ink.mute) : (look == .native ? Color.primary : Ink.ink))
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

// MARK: - Premium Native

// brand: native begin
/// Today's page in Premium Native (§13.2): the warm window, white cards, SF Pro, and the persimmon accent. The bottom
/// bar stays opaque because it carries text.
private struct NativeThoughtPage: View {
    @ObservedObject var state: ThoughtPageState
    var items: [Transcript]
    var frontApp: String
    var working: Bool
    @Binding var actionID: FlowAction.ID?
    var copy: () -> Void
    var send: () -> Void
    @ObservedObject private var flow = FlowSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thoughts · \(DayPages.dateTitle(state.day))").font(.system(size: 18, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(state.isToday ? "Today" : DayPages.listDay(state.day)) · \(DayPages.count(items.count, "thought", "thoughts"))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    Image(systemName: "chevron.left").frame(width: 30, height: 28).contentShape(Rectangle()).tapArea { state.move(-1) }
                        .accessibilityLabel("Day before").uiTarget("page-prev")
                    Image(systemName: "chevron.right").frame(width: 30, height: 28).contentShape(Rectangle())
                        .foregroundStyle(state.isToday ? .tertiary : .primary)
                        .tapArea { if !state.isToday { state.move(1) } }
                        .accessibilityLabel("Day after").uiTarget("page-next")
                }
                .font(.system(size: 12, weight: .semibold))
                .background(Capsule().fill(PremiumInk.card))
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 10)

            if items.isEmpty {
                ThoughtEmptyPage(isToday: state.isToday, play: state.playEmpty && state.isToday)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { t in
                                ThoughtCard(transcript: t, outlined: t.id == ThoughtCapture.shared.lastAdded, state: state,
                                            controller: ThoughtPadController.shared).id(t.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    .onAppear { if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 8) {
                ThoughtMicDisc(size: 36).uiTarget("page-mic")
                Picker("Action", selection: $actionID) {
                    Text("As Is").tag(FlowAction.ID?.none)
                    ForEach(flow.actions) { a in Text(a.name).tag(FlowAction.ID?.some(a.id)) }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 110)
                Spacer(minLength: 4)
                if working { ProgressView().controlSize(.small) }
                Button("Copy", action: copy).buttonStyle(.bordered).disabled(items.isEmpty || working).uiTarget("page-copy")
                Button(frontApp.isEmpty ? "Send" : "Send to \(frontApp)", action: send).buttonStyle(.borderedProminent)
                    .disabled(items.isEmpty || working).lineLimit(1).fixedSize()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(PremiumInk.card))
            .padding(10)
        }
        .tint(NativeInk.accent)
        .background(PremiumInk.window)
    }
}
// brand: native end
