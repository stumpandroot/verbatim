import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Settings › Dictation › Show dictation in: the three ways dictation shows on screen. All three read the same
/// `FlowBarModel` phases, so prompts and notices work in each. Pure Foundation, so the Linux tests cover it.
enum DictationSurface: String, CaseIterable, Identifiable {
    /// A paper or ink tab flush with the bottom, left, or right edge (`FlowBarView`). The default, and what
    /// everyone had before the other two existed.
    case ribbon
    /// Grows sideways out of the notch at the top of the screen (`NotchView`).
    case notch
    /// A button you drop anywhere (`FloatingButtonView`).
    case button

    static let key = "flow.surface"
    var id: String { rawValue }

    static func stored(_ d: UserDefaults = .standard) -> DictationSurface {
        DictationSurface(rawValue: d.string(forKey: key) ?? "") ?? .ribbon
    }

    var title: String {
        switch self {
        case .ribbon: return "Ribbon"
        case .notch: return "Notch"
        case .button: return "Floating button"
        }
    }

    var detail: String {
        switch self {
        case .ribbon: return "A paper tab at the bottom, left, or right edge."
        case .notch: return "Grows out of the notch at the top of the screen."
        case .button: return "A button you place anywhere. Looks in Floating button."
        }
    }

    /// Where to click, for empty states and hints: "the Ribbon at the edge of your screen".
    var clickHint: String {
        switch self {
        case .ribbon: return "the Ribbon at the edge of your screen"
        case .notch: return "the notch at the top of your screen"
        case .button: return "the floating button"
        }
    }

    /// What actually shows on one display.
    enum Shown: Equatable { case ribbon, notch, pill, button }

    /// The notch style shows in the notch where there is one, and as a pill or the Ribbon where there isn't.
    static func shown(chosen: DictationSurface, hasNotch: Bool, fallback: NotchFallback) -> Shown {
        switch chosen {
        case .ribbon: return .ribbon
        case .button: return .button
        case .notch: return hasNotch ? .notch : (fallback == .pill ? .pill : .ribbon)
        }
    }
}

/// Settings › Dictation › On displays without a notch (shown when the notch style is chosen).
enum NotchFallback: String, CaseIterable, Identifiable {
    case pill, ribbon
    static let key = "flow.notch.noNotch"
    var id: String { rawValue }
    static func stored(_ d: UserDefaults = .standard) -> NotchFallback { NotchFallback(rawValue: d.string(forKey: key) ?? "") ?? .pill }
    var title: String { self == .pill ? "Show a pill at the top" : "Use the Ribbon" }
}

/// Settings › Dictation › Click the notch to dictate. On by default: pointing at the notch shows your hotkey, and a
/// click starts (and a second click pastes). Off, the idle notch ignores the pointer entirely.
enum NotchClick {
    static let key = "flow.notch.click"
    static func isOn(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: key) as? Bool ?? true }
}

/// Settings › Floating button › Button: four looks.
enum FloatingLook: String, CaseIterable, Identifiable {
    /// An ink disc, like the iPhone's Record button in ink, with the bars mark at rest.
    case disc
    /// A small ink pill with five still voice bars.
    case bars
    /// A 16 pt paper dot with an ink ring that grows into a bars pill only while you dictate.
    case dot
    /// Butter, with grain, the word Dictate, and your hotkey as a keycap.
    case label
    static let key = "flow.button.look"
    var id: String { rawValue }
    static func stored(_ d: UserDefaults = .standard) -> FloatingLook { FloatingLook(rawValue: d.string(forKey: key) ?? "") ?? .disc }
    var title: String {
        switch self {
        case .disc: return "Ink disc"
        case .bars: return "Bars pill"
        case .dot: return "Quiet dot"
        case .label: return "Labeled pill"
        }
    }
}

/// Settings › Floating button › Size: small, medium, and large are 32, 44, and 56 pt (the disc's diameter; the
/// other looks scale with it). The click target is never smaller than 28 pt.
enum FloatingSize: String, CaseIterable, Identifiable {
    case small, medium, large
    static let key = "flow.button.size"
    var id: String { rawValue }
    static func stored(_ d: UserDefaults = .standard) -> FloatingSize { FloatingSize(rawValue: d.string(forKey: key) ?? "") ?? .medium }
    var title: String { self == .small ? "Small" : self == .medium ? "Medium" : "Large" }
    var points: CGFloat { self == .small ? 32 : self == .medium ? 44 : 56 }
}

/// The floating button's other settings keys.
enum FloatingButtonKeys {
    /// What moves with your voice: "bars" or "rings" (`RibbonMark` raw values). The Ribbon keeps its own.
    static let mark = "flow.button.mark"
    /// Snap to the screen edge after a drag. Off by default: it stays where you drop it.
    static let snap = "flow.button.snap"
    /// Where it sits on each display: `[display key: ButtonSpot]` as JSON.
    static let positions = "flow.button.positions"
}

/// Where the floating button's center sits on a display, as fractions of the visible frame, so it lands in the same
/// place after a resolution change and clamps onto the screen after a display change.
struct ButtonSpot: Codable, Equatable {
    var x: Double
    var y: Double
    /// Lower right, clear of the Dock's middle and of most windows' controls.
    static let standard = ButtonSpot(x: 0.96, y: 0.18)
}

/// The floating button's placement and hit area. Pure, so the Linux tests cover it.
enum FloatingGeometry {
    /// The smallest click target, whatever the look and size.
    static let minHit: CGFloat = 28
    /// Space kept between the button and the screen's edge.
    static let margin: CGFloat = 8

    /// The button's drawn size at rest.
    static func restSize(look: FloatingLook, size: FloatingSize) -> CGSize {
        let s = size.points
        switch look {
        case .disc: return CGSize(width: s, height: s)
        case .bars: let h = (s * 30 / 44).rounded(); return CGSize(width: (h * 1.6).rounded(), height: h)
        case .dot: let d = (s * 16 / 44).rounded(); return CGSize(width: d, height: d)
        case .label: let h = (s * 34 / 44).rounded(); return CGSize(width: (h * 4.6).rounded(), height: h)
        }
    }

    /// A drawn size grown to the minimum click target, centered on the same point.
    static func hitSize(_ drawn: CGSize) -> CGSize {
        CGSize(width: max(minHit, drawn.width), height: max(minHit, drawn.height))
    }

    /// Keeps a center far enough inside `frame` that a button `size` big stays fully on screen.
    static func clamp(_ p: CGPoint, in frame: CGRect, size: CGSize) -> CGPoint {
        let hw = size.width / 2 + margin, hh = size.height / 2 + margin
        let x = frame.width > 2 * hw ? min(max(p.x, frame.minX + hw), frame.maxX - hw) : frame.midX
        let y = frame.height > 2 * hh ? min(max(p.y, frame.minY + hh), frame.maxY - hh) : frame.midY
        return CGPoint(x: x, y: y)
    }

    /// Slides a center to the nearest edge of `frame` (Snap to the screen edge), keeping it on screen.
    static func snap(_ p: CGPoint, in frame: CGRect, size: CGSize) -> CGPoint {
        let c = clamp(p, in: frame, size: size)
        let hw = size.width / 2 + margin, hh = size.height / 2 + margin
        let dLeft = c.x - frame.minX, dRight = frame.maxX - c.x, dBottom = c.y - frame.minY, dTop = frame.maxY - c.y
        let nearest = min(dLeft, dRight, dBottom, dTop)
        if nearest == dLeft { return CGPoint(x: frame.minX + hw, y: c.y) }
        if nearest == dRight { return CGPoint(x: frame.maxX - hw, y: c.y) }
        if nearest == dBottom { return CGPoint(x: c.x, y: frame.minY + hh) }
        return CGPoint(x: c.x, y: frame.maxY - hh)
    }

    /// The center for a saved spot (or the standard one) on a display, clamped onto it.
    static func center(for spot: ButtonSpot?, in frame: CGRect, size: CGSize) -> CGPoint {
        let s = spot ?? .standard
        let p = CGPoint(x: frame.minX + frame.width * CGFloat(s.x), y: frame.minY + frame.height * CGFloat(s.y))
        return clamp(p, in: frame, size: size)
    }

    /// The spot to save for a center on a display.
    static func spot(for center: CGPoint, in frame: CGRect) -> ButtonSpot {
        guard frame.width > 0, frame.height > 0 else { return .standard }
        let x = Double((center.x - frame.minX) / frame.width), y = Double((center.y - frame.minY) / frame.height)
        return ButtonSpot(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}
