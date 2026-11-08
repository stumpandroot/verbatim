import SwiftUI
import AppKit

// The Search or ask panel's results from the keyboard (MAC-35; DESIGN.md §19). The toolbar's search field is the
// system's (`.searchable`), which gives no hook for the arrow keys, and the panel's own field is a TextField whose field
// editor takes ↑ and ↓ first. So a local key monitor watches for them while the panel shows Search and one of those two
// fields is being typed in, and moves the chosen result (`PanelKeys` in App/MacCommandRules.swift); the typing never
// leaves the field. Esc in the toolbar's field closes the panel. Return goes through each field's own submit, and every
// other key, Tab included, goes on as before.

@MainActor
final class SearchPanelKeys {
    static let shared = SearchPanelKeys()
    private var monitor: Any?

    func install(_ app: AppState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak app] e in
            guard let self, let app else { return e }
            return self.handle(e, app: app) ? nil : e
        }
    }

    /// True when the key was the panel's: ↓ or ↑ through Search's results, or Esc from the toolbar's field.
    private func handle(_ e: NSEvent, app: AppState) -> Bool {
        let nav = AskNav.shared
        guard nav.panelOpen, let w = e.window, w === app.mainWindow,
              let key = PanelKeys.key(keyCode: e.keyCode, mods: Self.mods(e.modifierFlags)) else { return false }
        let inToolbar = Self.typingInToolbarSearch(w)
        switch key {
        case .close:
            // The panel's own field closes it through its exit command.
            guard inToolbar else { return false }
            nav.close()
            return true
        case .down, .up:
            guard nav.mode == .search, !nav.order.isEmpty,
                  inToolbar || (nav.panelFieldFocused && Self.typingInField(w)) else { return false }
            nav.move(down: key == .down)
            return true
        }
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> RecallMods {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        var m: RecallMods = []
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.shift) { m.insert(.shift) }
        return m
    }

    /// A text field has the keyboard: its field editor is the window's first responder.
    static func typingInField(_ w: NSWindow) -> Bool {
        (w.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    /// The toolbar's search field has the keyboard: its field editor is the window's first responder.
    static func typingInToolbarSearch(_ w: NSWindow) -> Bool {
        guard let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSSearchField else { return false }
        return ToolbarSearchPrompt.fields(in: w).contains { $0 === field }
    }
}
