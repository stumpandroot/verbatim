import Foundation

/// Whether text the keyboard put in a field is still exactly where it left it, so an action that removes it (Undo,
/// Use as spoken, the polished swap) deletes only those characters and never your other words. Foundation only:
/// compiled into the keyboard, the app and the widgets (with `KeyboardBridge.polishSwap`), and tested on Linux
/// (`tools/test-keyboard.sh`).
///
/// The keyboard can only delete backward from the cursor, so it may remove the inserted text only when the field
/// is the same one, nothing is selected, and the text before the cursor still ends with it.
enum InsertionGuard {
    /// How the text before the cursor compares with the inserted text.
    enum Ending: Equatable {
        /// It ends with the inserted text (or, for a host that reports only the last part, with enough of it).
        case matches
        /// The host reports nothing before the cursor.
        case unreadable
        /// The host reports only a short end of the inserted text: too little to be sure.
        case tooShort
        /// It ends with something else: the cursor moved or the text changed.
        case changed
    }

    /// The fewest characters of a partial report (a host that reports only the last part) that count as a match,
    /// unless the report starts right after a line break inside the inserted text.
    static let partialMinimum = 16

    /// Compares what the field reports before the cursor with `inserted`.
    static func ending(before: String?, inserted: String) -> Ending {
        guard let before, !before.isEmpty else { return .unreadable }
        if before.hasSuffix(inserted) { return .matches }
        if inserted.hasSuffix(before) {
            let cut = inserted.index(inserted.endIndex, offsetBy: -before.count)
            let afterBreak = cut > inserted.startIndex && inserted[inserted.index(before: cut)].isNewline
            return before.count >= partialMinimum || afterBreak ? .matches : .tooShort
        }
        return .changed
    }

    enum Recovery: Equatable {
        case allowed
        /// Not safe to delete backward; the reason goes in the log.
        case blocked(String)
    }

    /// Whether Undo or Use as spoken may delete the inserted text now. `sameField` compares the field's
    /// `safeDocumentIdentifier` with the one it went into; `selected` is the field's selected text (nil or empty
    /// for none). Anything uncertain blocks: a keyboard that can't check never deletes.
    static func recovery(inserted: String, before: String?, sameField: Bool, selected: String?) -> Recovery {
        if inserted.isEmpty { return .blocked("nothing was inserted") }
        if !sameField { return .blocked("a different text field") }
        if let selected, !selected.isEmpty { return .blocked("text is selected") }
        switch ending(before: before, inserted: inserted) {
        case .matches: return .allowed
        case .unreadable: return .blocked("the field doesn't show the text before the cursor")
        case .tooShort: return .blocked("too little text before the cursor to be sure")
        case .changed: return .blocked("the text before the cursor changed")
        }
    }

    /// How long after inserting the keyboard trusts the insertion while the host catches up: some hosts report the
    /// text before the cursor late (`InsertLanding`), so a change notice this soon checks only the field and the
    /// selection. A tap on Undo or Use as spoken always checks everything.
    static let settle: TimeInterval = 0.5

    /// After the host says the text or the selection changed: whether to keep offering Undo (and Use as spoken).
    /// Within `settle` of inserting, only a different field or a selection withdraws it.
    static func keepAfterHostChange(inserted: String, before: String?, sameField: Bool, selected: String?, age: TimeInterval) -> Bool {
        switch recovery(inserted: inserted, before: before, sameField: sameField, selected: selected) {
        case .allowed: return true
        case .blocked:
            if age < settle { return sameField && (selected ?? "").isEmpty }
            return false
        }
    }

    /// The line the keyboard shows when you tap Undo or Use as spoken after the text changed.
    static let changedNotice = "The text changed, so Verbose left it as it is."
}
