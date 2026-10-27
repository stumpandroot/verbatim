import Foundation

// The dictation hotkey's pure rules: recorded shortcuts, the conflict check against shortcuts Verbose knows about,
// mouse buttons, and the upgrade from the old ⌃⌥ Space choice. No AppKit or Carbon, so the Linux tests
// (`mac/tools/test-surfaces.sh`) cover them; Dictation.swift maps NSEvent flags and Carbon modifiers onto these.

/// Modifier keys, in the order macOS writes them: ⌃ ⌥ ⇧ ⌘.
struct KeyMods: OptionSet, Codable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
    static let control = KeyMods(rawValue: 1 << 0)
    static let option = KeyMods(rawValue: 1 << 1)
    static let shift = KeyMods(rawValue: 1 << 2)
    static let command = KeyMods(rawValue: 1 << 3)

    /// "⌃⌥⇧⌘", in that order.
    var symbols: [String] {
        var s: [String] = []
        if contains(.control) { s.append("⌃") }
        if contains(.option) { s.append("⌥") }
        if contains(.shift) { s.append("⇧") }
        if contains(.command) { s.append("⌘") }
        return s
    }

    /// ⌃, ⌥, or ⌘: a shortcut needs one of these (⇧ alone would type a capital).
    var hasCommandKey: Bool { !intersection([.control, .option, .command]).isEmpty }
}

/// A key and its modifiers, recorded in Settings › Dictation › Hotkey › A shortcut you choose.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var mods: KeyMods

    /// The old menu's ⌃⌥ Space.
    static let controlOptionSpace = KeyCombo(keyCode: KeyNames.space, mods: [.control, .option])

    /// "⌃⌥D", "⌘Space".
    var title: String { mods.symbols.joined() + KeyNames.name(keyCode) }
    /// One keycap per key: ["⌃", "⌥", "D"].
    var keycaps: [String] { mods.symbols + [KeyNames.name(keyCode)] }

    enum Match: Equatable {
        /// The shortcut as recorded.
        case exact
        /// The shortcut with ⇧ added (edit selected text by voice), when ⇧ isn't part of it.
        case withShift
    }

    /// Whether a key press is this shortcut.
    func match(keyCode code: UInt16, mods pressed: KeyMods) -> Match? {
        guard code == keyCode else { return nil }
        if pressed == mods { return .exact }
        if !mods.contains(.shift), pressed == mods.union(.shift) { return .withShift }
        return nil
    }

    /// Saved as "keyCode:mods", readable in `defaults read`.
    var stored: String { "\(keyCode):\(mods.rawValue)" }
    init(keyCode: UInt16, mods: KeyMods) { self.keyCode = keyCode; self.mods = mods }
    init?(stored: String?) {
        guard let parts = stored?.split(separator: ":"), parts.count == 2,
              let k = UInt16(parts[0]), let m = Int(parts[1]), m >= 0, m < 16 else { return nil }
        self.init(keyCode: k, mods: KeyMods(rawValue: m))
    }
}

/// Key names by virtual key code (the US layout's labels, as macOS menus show them).
enum KeyNames {
    static let space: UInt16 = 49, tab: UInt16 = 48, escape: UInt16 = 53, grave: UInt16 = 50
    static let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc", 114: "Help", 115: "Home", 116: "Page Up",
        117: "⌦", 119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    /// F1–F20, which may stand alone as a shortcut.
    static let functionKeys: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    static func name(_ code: UInt16) -> String {
        if let f = functionKeys[code] { return "F\(f)" }
        return names[code] ?? "Key \(code)"
    }
}

/// Checks a recorded shortcut against the ones Verbose knows are taken: macOS's own (Spotlight, input sources,
/// the app switcher, Mission Control, screenshots) and Verbose's. Others can't be known; the recorder says so.
enum ShortcutCheck {
    enum Result: Equatable {
        case ok
        /// No ⌃, ⌥, or ⌘ (and not a function key): it would type a character.
        case needsModifier
        /// Esc on its own cancels dictation.
        case escape
        /// Someone else's: "Spotlight", "⌘Space opens Spotlight."
        case taken(owner: String, sentence: String)
    }

    struct Known {
        var combo: KeyCombo
        var owner: String
        /// What it does, after the shortcut's name: "opens Spotlight".
        var does: String
    }

    private static func k(_ code: UInt16, _ mods: KeyMods, _ owner: String, _ does: String) -> Known {
        Known(combo: KeyCombo(keyCode: code, mods: mods), owner: owner, does: does)
    }

    /// macOS's shortcuts that are on by default and that people keep.
    static let system: [Known] = [
        k(KeyNames.space, [.command], "Spotlight", "opens Spotlight"),
        k(KeyNames.space, [.option, .command], "Finder", "opens a Finder search window"),
        k(KeyNames.space, [.control], "input sources", "switches input sources"),
        k(KeyNames.space, [.control, .command], "the Character Viewer", "opens emoji and symbols"),
        k(KeyNames.tab, [.command], "the app switcher", "switches apps"),
        k(KeyNames.tab, [.shift, .command], "the app switcher", "switches apps"),
        k(KeyNames.grave, [.command], "the app in front", "switches its windows"),
        k(12, [.command], "the app in front", "quits it"),
        k(13, [.command], "the app in front", "closes its window"),
        k(4, [.command], "the app in front", "hides it"),
        k(46, [.command], "the app in front", "minimizes its window"),
        k(KeyNames.escape, [.option, .command], "Force Quit", "opens Force Quit"),
        k(12, [.control, .command], "the lock screen", "locks your Mac"),
        k(KeyNames.up, [.control], "Mission Control", "opens Mission Control"),
        k(KeyNames.down, [.control], "Mission Control", "shows the app's windows"),
        k(KeyNames.left, [.control], "Mission Control", "moves to the Space on the left"),
        k(KeyNames.right, [.control], "Mission Control", "moves to the Space on the right"),
        k(20, [.shift, .command], "Screenshot", "takes a screenshot"),
        k(21, [.shift, .command], "Screenshot", "takes a screenshot of part of the screen"),
        k(23, [.shift, .command], "Screenshot", "opens Screenshot"),
    ]

    /// Verbose's own global shortcuts (Recent dictations is passed in; it's a setting).
    static let verbose: [Known] = [
        k(9, [.control, .command], "Verbose", "pastes your last dictation"),
        k(35, [.control, .option], "Verbose", "starts a thought"),
        k(15, [.option, .shift], "Verbose", "starts a recording"),
        k(8, [.option, .command], "Verbose", "opens Live captions"),
    ]

    static func check(_ c: KeyCombo, also extra: [Known] = []) -> Result {
        if c.keyCode == KeyNames.escape && c.mods.isEmpty { return .escape }
        if !c.mods.hasCommandKey && KeyNames.functionKeys[c.keyCode] == nil { return .needsModifier }
        if let hit = (system + verbose + extra).first(where: { $0.combo == c }) {
            return .taken(owner: hit.owner, sentence: "\(c.title) \(hit.does).")
        }
        return .ok
    }
}

/// Settings › Dictation › Other shortcuts › Mark a moment (mockup "Library features", section 3b): the global hotkey
/// that marks a moment while a recording runs, ⌃⌥B unless you change it (B, as in a playing transcript's bookmark).
/// It's registered only while something records, so with nothing recording other apps get the keys.
enum MarkHotkeyStore {
    static let key = "marks.hotkey"
    static let standard = KeyCombo(keyCode: 11, mods: [.control, .option])

    static func current(_ d: UserDefaults = .standard) -> KeyCombo { KeyCombo(stored: d.string(forKey: key)) ?? standard }

    /// The mark hotkey as a shortcut Verbose knows is taken, for the other shortcut recorders' checks.
    static func known(_ c: KeyCombo) -> ShortcutCheck.Known {
        ShortcutCheck.Known(combo: c, owner: "Verbose", does: "marks a moment while recording")
    }
}

/// Mouse buttons for Settings › Dictation › Hotkey › A mouse button. macOS numbers them from 0 (left, right,
/// middle); people call them 1, 2, 3, so "button 4" is number 3.
enum MouseButtons {
    /// Left, right, and middle never count.
    static func isSideButton(_ number: Int) -> Bool { number >= 3 && number < 32 }
    static func title(_ number: Int) -> String { "button \(number + 1)" }
}

/// Settings › Dictation › Hotkey, as saved. `dictateHotkey` holds the choice; a recorded shortcut and a mouse
/// button keep their own keys, so switching choices never loses them.
enum HotkeyStore {
    static let choiceKey = "dictateHotkey"
    static let customKey = "dictateHotkey.custom"
    static let mouseKey = "dictateHotkey.mouseButton"
    /// The old menu's fourth choice, before you could record your own.
    static let legacyControlOptionSpace = "controlOptionSpace"

    /// The recorded shortcut, if there is one.
    static func custom(_ d: UserDefaults = .standard) -> KeyCombo? { KeyCombo(stored: d.string(forKey: customKey)) }
    /// The chosen mouse button (macOS's number, so button 4 is 3), if there is one.
    static func mouseButton(_ d: UserDefaults = .standard) -> Int? {
        guard let n = d.object(forKey: mouseKey) as? Int, MouseButtons.isSideButton(n) else { return nil }
        return n
    }

    struct Upgrade: Equatable {
        var choice: String
        /// The shortcut to save under `customKey`.
        var custom: KeyCombo
    }

    /// Reads a saved choice from before the picker. ⌃⌥ Space becomes a recorded ⌃⌥ Space, so it works exactly as
    /// before; every other choice keeps its raw value, and nothing saved means the default, right ⌥. Nil: no change.
    static func upgrade(stored: String?) -> Upgrade? {
        guard stored == legacyControlOptionSpace else { return nil }
        return Upgrade(choice: "custom", custom: .controlOptionSpace)
    }
}
