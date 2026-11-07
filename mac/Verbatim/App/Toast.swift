import SwiftUI
import AppKit

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    /// "Transcript ready" when the transcript isn't open: its color sweeps the toast (DESIGN.md §7, Celebrations).
    var celebration: CelebrationTicket? = nil
    /// When it appeared, for how long it stays (ToastTiming).
    let shownAt = Date()
    init(_ message: String, action: String? = nil, onAction: (() -> Void)? = nil) {
        self.message = message; self.action = action; self.onAction = onAction
    }
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// The toast at the window's foot: it slides up and fades in, and fades out (as the iPhone's does from the top). The
/// container stays, so whoever sets `app.toast`, with or without an animation, the toast animates; Limit animation
/// fades it both ways. A message alone stays by its length (4.5 to 10 s); one with an action stays at least 8 s; any
/// toast stays while the pointer is on it (ToastTiming), and ⌘Z runs its Undo (`ToastUndoKey`). VoiceOver hears every
/// toast and its action (`ToastSpeech`, MAC-07), reads it as one element with the action as a named action, and while
/// it runs a toast with an action stays until it's dismissed or replaced.
struct ToastView: View {
    @Environment(AppState.self) var app
    @Environment(\.limitMotion) private var limitMotion
    @State private var hold = ToastHold()
    var body: some View {
        ZStack { toast }
            .animation(limitMotion ? Motion.fade : Motion.settle, value: app.toast)
            // Whoever sets `app.toast`, VoiceOver hears it.
            .onChange(of: app.toast?.id) { _, id in
                guard id != nil, let t = app.toast else { return }
                HomeAnnounce.say(ToastSpeech.announcement(message: t.message, action: t.action))
            }
    }

    private var transition: AnyTransition {
        limitMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
    }

    @ViewBuilder private var toast: some View {
        if let t = app.toast {
            // A finished transcript's fill sweeps the toast in its color, and the words turn to ink with it.
            CelebrationBurst(ticket: t.celebration, script: .toast) { burst in
                let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous)
                let ink = burst.active && burst.covered ? Refined.onFill : Refined.paper
                HStack(spacing: 14) {
                    Text(t.message).font(.system(size: 13)).lineLimit(2)
                    if let a = t.action {
                        // A small outlined action in paper on the toast's ink (the refined kit, DESIGN.md §13).
                        Button { app.toast = nil; t.onAction?() } label: {
                            Text(a).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 12).frame(height: 28)
                                .overlay(Capsule().strokeBorder(ink, lineWidth: 1.5))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(ToastUndo.offersUndo(a) ? "Undo (⌘Z)" : "")
                        .uiTarget("toast-action")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background {
                    ZStack(alignment: .leading) {
                        shape.fill(Refined.ink)
                        if burst.active, let c = t.celebration {
                            shape.fill(c.tone.fill).scaleEffect(x: max(0.0001, burst.fill), y: 1, anchor: .leading).clipShape(shape)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .foregroundStyle(ink)
                .scaleEffect(burst.active ? burst.scale : 1)
            }
            .onDisappear { if let c = t.celebration { CelebrationCenter.shared.didFinish(c.id) } }
            .frame(maxWidth: 520)
            .padding(.bottom, 24)
            .transition(transition)
            .accessibilityElement(children: .combine)
            .modifier(MacToastActions(action: t.action, run: { app.toast = nil; t.onAction?() }, dismiss: { if app.toast == t { app.toast = nil } }))
            // The pointer on any toast keeps it (ToastTiming).
            .onHover { over in hold.set(over, for: t.id) }
            .task(id: HoldKey(id: t.id, held: hold.isHeld(t.id))) { await endWhenDue(t) }
        }
    }

    private struct HoldKey: Equatable { var id: UUID; var held: Bool }

    /// Closes toast `t` when its time is up. Runs again when the pointer comes or goes; while it's on the toast, waits.
    /// One kept for VoiceOver asks again each second, so it goes on time once VoiceOver is off.
    private func endWhenDue(_ t: Toast) async {
        while !Task.isCancelled {
            let now = Date()
            let held = hold.isHeld(t.id)
            let wait = ToastTiming.remaining(elapsed: now.timeIntervalSince(t.shownAt), hasAction: t.action != nil,
                                             plain: ToastTiming.plain(for: t.message, floor: ToastTiming.macPlain),
                                             held: held, sinceRelease: hold.sinceRelease(t.id, now: now),
                                             voiceOver: NSWorkspace.shared.isVoiceOverEnabled)
            if wait == nil && held { return }
            if let wait, wait <= 0 { if app.toast == t { app.toast = nil }; return }
            try? await Task.sleep(nanoseconds: UInt64((wait ?? 1) * 1_000_000_000))
        }
    }
}

/// The toast's action as a VoiceOver named action, and Dismiss to close it without the action.
private struct MacToastActions: ViewModifier {
    var action: String?
    var run: () -> Void
    var dismiss: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if let action {
            content
                .accessibilityAction(named: Text(action), run)
                .accessibilityAction(named: Text("Dismiss"), dismiss)
        } else {
            content.accessibilityAction(named: Text("Dismiss"), dismiss)
        }
    }
}

/// ⌘Z while the toast offers Undo runs it, as clicking Undo does (DESIGN.md §7). Only in the main window, without a
/// sheet, and not while a text field or text view has the keyboard, where ⌘Z stays the text's own undo.
@MainActor
final class ToastUndoKey {
    static let shared = ToastUndoKey()
    private weak var app: AppState?
    private var monitor: Any?

    func install(_ app: AppState) {
        self.app = app
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let used = MainActor.assumeIsolated { self?.handle(e) == true }
            return used ? nil : e
        }
    }

    /// Runs the toast's Undo for ⌘Z and says whether it did (the key press is then used up).
    @discardableResult
    func handle(_ e: NSEvent) -> Bool {
        guard let app, let t = app.toast, let w = app.mainWindow, e.window === w, w.attachedSheet == nil else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let editing = w.firstResponder is NSText
        guard ToastUndo.commandZRuns(action: t.action, key: e.charactersIgnoringModifiers, command: mods.contains(.command), shift: mods.contains(.shift),
                                     option: mods.contains(.option), control: mods.contains(.control), editingText: editing) else { return false }
        app.toast = nil
        t.onAction?()
        return true
    }
}
