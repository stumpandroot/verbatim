import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Settings › Ribbon and notch › Show dictation in: the two ways dictation shows on screen. Both read the same
/// `FlowBarModel` phases, so prompts and notices work in each. Pure Foundation, so the Linux tests cover it. The
/// floating button retired (consolidation, October 28, 2026): a stored "button" reads as the Ribbon, and
/// `migrateRetired` rewrites it once.
enum DictationSurface: String, CaseIterable, Identifiable {
    /// A paper or ink tab flush with the bottom, left, or right edge (`FlowBarView`). The default, and what
    /// everyone had before the other two existed.
    case ribbon
    /// Grows sideways out of the notch at the top of the screen (`NotchView`).
    case notch

    static let key = "flow.surface"
    var id: String { rawValue }

    static func stored(_ d: UserDefaults = .standard) -> DictationSurface {
        DictationSurface(rawValue: d.string(forKey: key) ?? "") ?? .ribbon
    }

    /// The floating button's stored value, from builds before it retired.
    static let retiredButton = "button"

    /// Moves anyone on the retired floating button to the Ribbon, once at launch. Its own settings
    /// (`flow.button.*`) stay where they are, so an older build on this Mac still finds them. True when it moved.
    @discardableResult
    static func migrateRetired(_ d: UserDefaults = .standard) -> Bool {
        guard d.string(forKey: key) == retiredButton else { return false }
        d.set(DictationSurface.ribbon.rawValue, forKey: key)
        return true
    }

    var title: String {
        switch self {
        case .ribbon: return "Ribbon"
        case .notch: return "Notch"
        }
    }

    var detail: String {
        switch self {
        case .ribbon: return "A paper tab at the bottom, left, or right edge."
        case .notch: return "Grows out of the notch at the top of the screen."
        }
    }

    /// Where to click, for empty states and hints: "the Ribbon at the edge of your screen".
    var clickHint: String {
        switch self {
        case .ribbon: return "the Ribbon at the edge of your screen"
        case .notch: return "the notch at the top of your screen"
        }
    }

    /// What actually shows on one display.
    enum Shown: Equatable { case ribbon, notch, pill }

    /// The notch style shows in the notch where there is one, and as a pill or the Ribbon where there isn't.
    static func shown(chosen: DictationSurface, hasNotch: Bool, fallback: NotchFallback) -> Shown {
        switch chosen {
        case .ribbon: return .ribbon
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

/// Where the thought bubble's center sits on a display, as fractions of the visible frame, so it lands in the same
/// place after a resolution change and clamps onto the screen after a display change.
struct ButtonSpot: Codable, Equatable {
    var x: Double
    var y: Double
    /// Lower right, clear of the Dock's middle and of most windows' controls.
    static let standard = ButtonSpot(x: 0.96, y: 0.18)
}

/// Where a floating panel of a fixed size sits (the thought bubble, ThoughtBubble.swift). Pure, so the Linux tests
/// cover it.
enum FloatingGeometry {
    /// Space kept between the panel and the screen's edge.
    static let margin: CGFloat = 8

    /// Keeps a center far enough inside `frame` that a panel `size` big stays fully on screen.
    static func clamp(_ p: CGPoint, in frame: CGRect, size: CGSize) -> CGPoint {
        let hw = size.width / 2 + margin, hh = size.height / 2 + margin
        let x = frame.width > 2 * hw ? min(max(p.x, frame.minX + hw), frame.maxX - hw) : frame.midX
        let y = frame.height > 2 * hh ? min(max(p.y, frame.minY + hh), frame.maxY - hh) : frame.midY
        return CGPoint(x: x, y: y)
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
