import Foundation

// The Mac's command and small-window rules (DESIGN.md §6.8, §7, §11, the interactions audit of November 7, 2026):
// what Recent dictations does with a key, when a hover may move its selection, what the Recording menu offers, how
// Find in the open transcript matches and steps, which Library columns fit a width, and when the inspector closes to
// make room. Foundation only, so the Linux tests (mac/tools/test-mac-commands.sh) check them; the views and menus read
// them and nothing here draws.

// MARK: - Recent dictations keys

/// The modifier keys Recent dictations looks at, without AppKit (the panel maps `NSEvent.ModifierFlags` to these).
struct KeyMods: OptionSet, Equatable {
    let rawValue: Int
    static let command = KeyMods(rawValue: 1)
    static let option = KeyMods(rawValue: 2)
    static let control = KeyMods(rawValue: 4)
    static let shift = KeyMods(rawValue: 8)
}

/// What a key does in Recent dictations (GPT-12): the search field always takes plain digits, so typing "2026"
/// searches for 2026. ⌘ with a number copies that row and ⇧⌘ with a number pastes it. Return pastes the selection, the
/// arrows move it, and Esc closes. Anything else goes to the search field.
enum RecallKeys {
    enum Action: Equatable { case close, move(Int), pasteSelected, copy(Int), paste(Int) }

    /// The footer's hints, in the panel's one form: the key, then what it does.
    static let copyHint = "⌘ 1–0"
    static let pasteHint = "⇧⌘ 1–0"

    /// The key that picks row `index`: 1–9, then 0.
    static func keyLabel(_ index: Int) -> String? {
        switch index {
        case 0..<9: return "\(index + 1)"
        case 9: return "0"
        default: return nil
        }
    }

    /// The row a number key picks, from the row of number keys or the keypad (key codes, so any layout works).
    static func index(forKeyCode code: UInt16) -> Int? {
        let row: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]   // kVK_ANSI_1…9, 0
        let pad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]   // kVK_ANSI_Keypad1…9, 0
        return row.firstIndex(of: code) ?? pad.firstIndex(of: code)
    }

    static func action(keyCode: UInt16, mods: KeyMods) -> Action? {
        let shift = mods.contains(.shift)
        let rest = mods.subtracting(.shift)
        switch keyCode {
        case 53: return .close                                            // Esc
        case 126: return rest.isEmpty ? .move(-1) : nil                   // ↑
        case 125: return rest.isEmpty ? .move(1) : nil                    // ↓
        case 36, 76: return rest.isEmpty ? .pasteSelected : nil           // Return, Enter (with or without ⇧)
        default: break
        }
        guard let i = index(forKeyCode: keyCode), rest == [.command] else { return nil }
        return shift ? .paste(i) : .copy(i)
    }
}

/// Whether a hover may move a list's selection (MAC-36): only after the pointer really moved. A row that slides under a
/// still pointer (the list scrolled from the keyboard, or the panel opened where the pointer was) doesn't take the
/// selection, so Return pastes the row you picked with the arrows. Positions are screen points.
struct PointerGate: Equatable {
    private(set) var last: CGPoint?

    /// Where the pointer was when the list appeared.
    init(at start: CGPoint? = nil) { last = start }

    /// A hover at `point`: true when the pointer moved since the last one.
    mutating func hover(at point: CGPoint) -> Bool {
        defer { last = point }
        guard let last else { return true }
        return abs(point.x - last.x) >= 1 || abs(point.y - last.y) >= 1
    }
}

// MARK: - The Recording menu

/// The menu bar's Recording menu (MAC-03): Stop and Transcribe (⌥⇧.), Pause or Resume, and Mark Moment, on every
/// screen, enabled while something records. A voice note, a thought, or another app's audio can be running.
struct RecordingMenuState: Equatable {
    var recording = false
    var starting = false
    var paused = false
    var capturing = false
    var thought = false

    /// Stop and Transcribe stops a voice note or an app capture; while the mic starts, it cancels the start.
    var canStop: Bool { recording || capturing }
    var stopTitle: String { recording && starting ? "Cancel Recording" : "Stop and Transcribe" }
    /// Pause is the voice note's: an app capture and a thought don't pause.
    var canPause: Bool { recording && !starting }
    var pauseTitle: String { paused ? "Resume Recording" : "Pause Recording" }
    /// A mark goes to whatever records (MarkCenter): a voice note that has started, a thought, or app audio.
    var canMark: Bool { (recording && !starting) || thought || capturing }

    /// The keys Stop and Transcribe answers to, as the toolbar's tooltip shows them.
    static let stopKeys = "⌥⇧."
}

// MARK: - Find in the open transcript

/// One match of Find in the open transcript: the line and where in its text.
struct PageFindMatch: Equatable {
    var line: Int
    var range: NSRange
}

/// Find in the open transcript (MAC-22): ⌘F opens the bar, matches are the query anywhere in a line, ignoring case and
/// accents, ⌘G and ⇧⌘G step through them and wrap at the ends, and Esc closes.
enum PageFind {
    static func matches(in lines: [String], query: String) -> [PageFindMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [PageFindMatch] = []
        for (i, text) in lines.enumerated() {
            let ns = text as NSString
            var from = 0
            while from < ns.length {
                let r = ns.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound, r.length > 0 else { break }
                out.append(PageFindMatch(line: i, range: r))
                from = r.location + r.length
            }
        }
        return out
    }

    /// The match after (or before) `current`, wrapping around; the first (or last) when there's none yet.
    static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let c = current, c >= 0, c < count else { return forward ? 0 : count - 1 }
        return forward ? (c + 1) % count : (c - 1 + count) % count
    }

    /// "3 of 12", "No matches", or nothing before you type.
    static func countLabel(current: Int?, count: Int, query: String) -> String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard count > 0 else { return "No matches" }
        return "\((current ?? 0) + 1) of \(count)"
    }
}

// MARK: - The Library at small widths

/// The Library table's columns for a card `width` points wide (MAC-05). Name, Kind, and Length always show; as the card
/// narrows, People goes first, then Date, so nothing is cut to "D…" or "People o…". Kind keeps a fixed width so its
/// chip always reads in full (the word pairs with its color). What's left is shared by the shares 3, 1.6, and 1.
struct LibraryColumnPlan: Equatable {
    static let inset: CGFloat = 16
    static let gap: CGFloat = 12
    static let length: CGFloat = 60
    static let kind: CGFloat = 108
    static let minName: CGFloat = 170
    static let minPeople: CGFloat = 120
    static let minDate: CGFloat = 96

    var name: CGFloat
    var people: CGFloat?
    var date: CGFloat?

    init(width: CGFloat) {
        // What Name, People, and Date share once Kind, Length, the insets, and the gaps between columns are taken.
        let free = width - 2 * Self.inset - Self.kind - Self.length
        let both = free - 4 * Self.gap
        let dateOnly = free - 3 * Self.gap
        if both >= Self.minName + Self.minPeople + Self.minDate {
            let unit = both / 5.6
            var p = (unit * 1.6).rounded(.down), d = (unit * 1).rounded(.down)
            // A share can dip under its least width near the boundary; Name gives it back.
            p = max(p, Self.minPeople); d = max(d, Self.minDate)
            name = both - p - d; people = p; date = d
        } else if dateOnly >= Self.minName + Self.minDate {
            let d = max(Self.minDate, (dateOnly / 4).rounded(.down))
            name = dateOnly - d; people = nil; date = d
        } else {
            name = max(Self.minName, free - 2 * Self.gap); people = nil; date = nil
        }
    }

    var showsPeople: Bool { people != nil }
    var showsDate: Bool { date != nil }
}

/// The inspector beside the Library and transcripts closes on its own when the content beside it would be narrower than
/// `minContent` (about 560 pt), the way a split view collapses its sidebar, and comes back when there's room again,
/// unless you closed it yourself (MAC-05, GPT-15).
enum InspectorFit {
    static let minContent: CGFloat = 560

    /// Whether the inspector shows: what you chose, and only while the content keeps its least width.
    static func shows(chosen: Bool, detailWidth: CGFloat, inspectorWidth: CGFloat) -> Bool {
        chosen && detailWidth - inspectorWidth >= minContent
    }
}
