import SwiftUI
import AppKit

// ↓ from the toolbar's search field into the Library's search passages (MAC-23 follow-up; DESIGN.md §6.8). The field is
// the system's (`.searchable`), which gives no hook for the arrow keys, so a key monitor watches for ↓ only while that
// field is being typed in and the Library shows passages. It hands the keyboard to the Library, which moves through the
// passages with ↓ and ↑ and opens one with Return or Space (`PassageCursor` in App/MacCommandRules.swift). Every other
// key, Tab included, goes on as before, and Return in the field still asks.

/// One passage in the Library's search results: its transcript and its line.
struct PassageKey: Hashable {
    let transcript: UUID
    let segment: UUID
}

@MainActor
final class PassageKeys: ObservableObject {
    static let shared = PassageKeys()

    /// The passages on screen, in reading order (the Library sets them as it draws); empty when none show.
    private(set) var order: [PassageKey] = []
    /// Changes when ↓ in the search field asks the Library to take the keyboard on its first passage.
    @Published private(set) var enterToken = 0
    private var monitor: Any?

    func install(_ app: AppState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak app] e in
            guard let self, let app else { return e }
            return self.handle(e, app: app) ? nil : e
        }
    }

    func setOrder(_ new: [PassageKey]) {
        if new != order { order = new }
    }

    /// ↓ in the toolbar's search field on the Library, with passages showing: the Library takes the keyboard.
    private func handle(_ e: NSEvent, app: AppState) -> Bool {
        guard app.screen == .library, let w = e.window, w === app.mainWindow, Self.typingInToolbarSearch(w) else { return false }
        guard PassageCursor.entersFromField(keyCode: e.keyCode, mods: Self.mods(e.modifierFlags), passages: order.count) else { return false }
        enter()
        return true
    }

    /// The Library takes the keyboard on the first passage (↓ in the field; the self-test calls it directly).
    func enter() {
        guard !order.isEmpty else { return }
        enterToken += 1
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

    /// The toolbar's search field has the keyboard: its field editor is the window's first responder.
    static func typingInToolbarSearch(_ w: NSWindow) -> Bool {
        guard let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSSearchField else { return false }
        return ToolbarSearchPrompt.fields(in: w).contains { $0 === field }
    }

    /// Back to the toolbar's search field (↑ above the first passage, or Esc in the passages).
    static func focusSearchField(_ w: NSWindow?) {
        guard let w, let field = ToolbarSearchPrompt.fields(in: w).first else { return }
        w.makeFirstResponder(field)
    }
}
