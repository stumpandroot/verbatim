import Foundation

/// What cleaned the Cleaned text.
enum CleanupSource: String, Codable, TolerantEnum {
    /// A source a newer build added reads as Apple Intelligence's (the more careful label).
    static var fallback: CleanupSource { .model }
    init(from decoder: Decoder) throws { self = try Self.tolerantValue(from: decoder) }
    /// Apple Intelligence rewrote it (Clean up or Tone), at any level, None included.
    case model
    /// Only rules changed it: Harper's spelling and grammar fixes.
    case rules

    /// The label the Cleaned tab shows.
    var label: String { self == .model ? "Cleaned by Apple Intelligence" : "Cleaned with rules" }
}

/// The Cleaned tab's text and its history, kept the same way on Mac and iPhone. The Original (`original` and the
/// corrected `segments`) is never changed by anything here.
extension Transcript {
    static let documentHistoryCap = 30

    /// The text Clean up and Tone always start from: the corrected lines as paragraphs, never an earlier cleanup.
    var cleanupBase: String { DocumentText.build(from: self) }

    /// How the Cleaned text was made, when it differs from the corrected lines.
    var cleanedBy: CleanupSource? { document == nil ? nil : documentCleanedBy }

    /// True when Apple Intelligence wrote the Cleaned text shown now.
    var cleanedByModel: Bool { cleanedBy == .model }

    /// Keeps `documentMarkHistory` the same length as `documentHistory` (older files and builds have no marks).
    private mutating func alignMarks() {
        if documentMarkHistory.count > documentHistory.count { documentMarkHistory.removeFirst(documentMarkHistory.count - documentHistory.count) }
        if documentMarkHistory.count < documentHistory.count {
            documentMarkHistory.insert(contentsOf: Array(repeating: "", count: documentHistory.count - documentMarkHistory.count), at: 0)
        }
    }

    /// Saves the Cleaned text as it is now, and how it was made, so Undo brings it back.
    mutating func pushDocumentHistory() {
        alignMarks()
        documentHistory.append(documentText)
        documentMarkHistory.append(cleanedBy?.rawValue ?? "")
        while documentHistory.count > Self.documentHistoryCap { documentHistory.removeFirst(); documentMarkHistory.removeFirst() }
    }

    /// Undo: the previous Cleaned text and its label. False when there's nothing to undo.
    @discardableResult
    mutating func undoDocument() -> Bool {
        alignMarks()
        guard let last = documentHistory.popLast() else { return false }
        let mark = documentMarkHistory.popLast() ?? ""
        document = last
        documentCleanedBy = CleanupSource(rawValue: mark)
        documentEdited = documentCleanedBy == nil && last != cleanupBase
        return true
    }

    /// Clean up or Tone finished: the new Cleaned text replaces the old, which stays in history.
    mutating func applyCleanup(_ text: String, level: String, tone: String, byModel: Bool) {
        pushDocumentHistory()
        document = text; documentLevel = level; documentTone = tone
        documentCleanedBy = byModel ? .model : .rules
        documentEdited = false
    }

    /// Spelling and grammar fixes accepted (rules). Keeps an Apple Intelligence label when the text already has one.
    mutating func applyRuleFixes(_ text: String) {
        pushDocumentHistory()
        document = text
        if documentCleanedBy == nil { documentCleanedBy = .rules }
    }

    /// Typing in the Cleaned text: a layer of the person's own, which Clean up warns before replacing.
    mutating func typeInCleaned(_ text: String) {
        document = text
        documentEdited = true
    }

    /// Reset: back to the corrected lines, with the current text in history.
    mutating func resetCleaned() {
        pushDocumentHistory()
        document = nil; documentLevel = "None"; documentTone = "As spoken"
        documentCleanedBy = nil; documentEdited = false
    }
}
