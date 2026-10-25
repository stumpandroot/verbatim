import Foundation

// Settings › Keyboard › Dictate button (the notch mockup's section 05): the size, position, and style of the
// button you tap most. Foundation only (no UIKit), so mac/tools/test-keyboard.sh compiles and checks it on Linux.
// Compiled into the keyboard, which draws it (KeyboardView.swift), and into the app, whose Settings writes it.

/// The keyboard's dictate button: Typing's Start, Home's Tap to talk, and Listening's Done follow it.
///
/// - Size: Standard keeps the 46 pt pill with the word Start; Large is a 62 pt disc with the voice bars only, and
///   makes the keyboard 16 pt taller (its top bar grows from 46 to 62 pt).
/// - Position: left, center, or right, so the button sits under one thumb. The menu button takes the opposite
///   corner. Home's Tap to talk and Listening's Done move with it, so the thumb lands in the same place.
/// - Style: Filled is butter with grain and a hard shadow; Outline is card white with an ink ring, and keeps the
///   hard shadow so it still reads as the main action.
///
/// Every combination keeps the VoiceOver label "Start dictation" and a hit area of at least 46 pt.
struct DictateButton: Equatable {
    enum Size: String, CaseIterable, Identifiable {
        case standard, large
        var id: String { rawValue }
        var title: String { self == .standard ? "Standard" : "Large" }
    }

    enum Position: String, CaseIterable, Identifiable {
        case left, center, right
        var id: String { rawValue }
        var title: String {
            switch self {
            case .left: return "Left"
            case .center: return "Center"
            case .right: return "Right"
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable {
        case filled, outline
        var id: String { rawValue }
        var title: String { self == .filled ? "Filled" : "Outline" }
    }

    var size: Size = .standard
    var position: Position = .right
    var style: Style = .filled

    /// Standard, right, filled: the keyboard as it shipped before the setting.
    static let standard = DictateButton()

    /// In the App Group (`KeyboardBridge.appGroup`): the app's Settings writes them, the keyboard reads them each
    /// time it appears. Without Allow Full Access the keyboard can't read the App Group and uses `standard`.
    enum Key {
        static let size = "kb.dictate.size"
        static let position = "kb.dictate.position"
        static let style = "kb.dictate.style"
    }

    init(size: Size = .standard, position: Position = .right, style: Style = .filled) {
        self.size = size
        self.position = position
        self.style = style
    }

    /// From stored raw values. Anything missing or unknown reads as the default for that choice.
    init(size: String?, position: String?, style: String?) {
        self.size = size.flatMap(Size.init(rawValue:)) ?? .standard
        self.position = position.flatMap(Position.init(rawValue:)) ?? .right
        self.style = style.flatMap(Style.init(rawValue:)) ?? .filled
    }

    static func read(_ d: UserDefaults?) -> DictateButton {
        guard let d else { return .standard }
        return DictateButton(size: d.string(forKey: Key.size), position: d.string(forKey: Key.position), style: d.string(forKey: Key.style))
    }

    func write(_ d: UserDefaults?) {
        d?.set(size.rawValue, forKey: Key.size)
        d?.set(position.rawValue, forKey: Key.position)
        d?.set(style.rawValue, forKey: Key.style)
    }

    // MARK: Layout (points)

    /// The keyboard's height with Standard; the system adds its own globe and dictation row below.
    static let baseKeyboardHeight: Double = 280
    /// The 46 pt top bar, and the large disc's diameter (62 pt). Large adds the difference to the keyboard.
    static let standardBar: Double = 46
    static let disc: Double = 62
    /// The smallest hit area any combination gets.
    static let minimumHit: Double = 46

    var barHeight: Double { size == .large ? Self.disc : Self.standardBar }
    var keyboardHeight: Double { Self.baseKeyboardHeight + (barHeight - Self.standardBar) }

    /// What sits in Typing's top bar, left to right. `balance` is an invisible menu-sized space that keeps a
    /// centered button centered.
    enum Slot: Equatable { case menu, button, spacer, balance }

    var typingBar: [Slot] {
        switch position {
        case .right: return [.menu, .spacer, .button]
        case .left: return [.button, .spacer, .menu]
        case .center: return [.menu, .spacer, .button, .spacer, .balance]
        }
    }

    /// Listening's Done leads the bar (with cancel and the cleanup chip trailing) only for Left; otherwise it
    /// trails, where it always was.
    var doneLeads: Bool { position == .left }

    /// The VoiceOver label for every combination.
    static let accessibilityLabel = "Start dictation"
}
