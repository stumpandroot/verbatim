import SwiftUI
import AppKit

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    /// When it appeared, for how long it stays (ToastTiming).
    let shownAt = Date()
    init(_ message: String, action: String? = nil, onAction: (() -> Void)? = nil) {
        self.message = message; self.action = action; self.onAction = onAction
    }
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// The toast at the window's foot: it slides up and fades in, and fades out (as the iPhone's does from the top). The
/// container stays, so whoever sets `app.toast`, with or without an animation, the toast animates; Limit animation
/// fades it both ways. A message alone goes after 4.5 s; one with an action stays at least 8 s and while the pointer is
/// on it (ToastTiming), and ⌘Z runs its Undo (`ToastUndoKey`).
struct ToastView: View {
    @Environment(AppState.self) var app
    @Environment(\.limitMotion) private var limitMotion
    @State private var hold = ToastHold()
    var body: some View {
        ZStack { toast }
            .animation(limitMotion ? Motion.fade : Motion.settle, value: app.toast)
    }

    private var transition: AnyTransition {
        limitMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
    }

    @ViewBuilder private var toast: some View {
        if let t = app.toast {
            HStack(spacing: 14) {
                Text(t.message).font(.system(size: 13)).lineLimit(2)
                if let a = t.action {
                    // A small outlined action in paper on the toast's ink (the refined kit, DESIGN.md §13).
                    Button { app.toast = nil; t.onAction?() } label: {
                        Text(a).font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.paper)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 12).frame(height: 28)
                            .overlay(Capsule().strokeBorder(Refined.paper, lineWidth: 1.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(ToastUndo.offersUndo(a) ? "Undo (⌘Z)" : "")
                    .uiTarget("toast-action")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Refined.ink, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
            .foregroundStyle(Refined.paper)
            .frame(maxWidth: 520)
            .padding(.bottom, 24)
            .transition(transition)
            // The pointer on a toast with an action keeps it (ToastTiming).
            .onHover { over in if t.action != nil { hold.set(over, for: t.id) } }
            .task(id: HoldKey(id: t.id, held: hold.isHeld(t.id))) { await endWhenDue(t) }
        }
    }

    private struct HoldKey: Equatable { var id: UUID; var held: Bool }

    /// Closes toast `t` when its time is up. Runs again when the pointer comes or goes; while it's on the toast, waits.
    private func endWhenDue(_ t: Toast) async {
        while !Task.isCancelled {
            let now = Date()
            guard let wait = ToastTiming.remaining(elapsed: now.timeIntervalSince(t.shownAt), hasAction: t.action != nil, plain: ToastTiming.macPlain,
                                                   held: hold.isHeld(t.id), sinceRelease: hold.sinceRelease(t.id, now: now)) else { return }
            if wait <= 0 { if app.toast == t { app.toast = nil }; return }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
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
