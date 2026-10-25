import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the notch is on a display and how big the notch style's black shape is in each state. Pure logic, so the
/// Linux tests (`mac/tools/test-surfaces.sh`) cover it; `NotchController` feeds it `NSScreen` values.
///
/// macOS has no notch API to draw into. A display has a notch when `safeAreaInsets.top` is more than 0; the camera
/// housing is the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`. Only their widths are used, so it
/// works whichever coordinate space those rects come in. On a display without a notch the same shape hangs from the
/// top center as a pill, 8 pt deeper than the menu bar.
struct NotchGeometry: Equatable {
    /// True on a display with a camera housing; false for the pill.
    var hasNotch: Bool
    /// The camera housing's width, 0 for the pill.
    var cameraWidth: CGFloat
    /// The first row's height: the housing's height plus 1 pt (so no hardware edge shows), or the pill's depth.
    var rowHeight: CGFloat
    /// The housing's center (or the display's), in screen coordinates.
    var centerX: CGFloat
    /// The display's top edge, in screen coordinates (bottom-left origin, so the shape hangs down from here).
    var top: CGFloat

    /// The housing's measured width on 14" and 16" MacBook Pros at default scaling, used when the side areas are missing.
    static let defaultCamera: CGFloat = 186
    /// The small concave flares where the shape meets the menu bar.
    static let flare: CGFloat = 6
    /// Wing widths (each side of the camera): pointing at it idle, listening or writing, hovered, and a prompt.
    /// The active wing stays under 120 pt, so it hides as little of the menu bar as it can.
    static let peekWing: CGFloat = 77, wing: CGFloat = 117, wideWing: CGFloat = 137, promptWing: CGFloat = 160
    /// The pill's widths: one row, hovered or a notice, and a prompt.
    static let pillWidth: CGFloat = 250, pillWideWidth: CGFloat = 330, pillPromptWidth: CGFloat = 380
    /// How far the pill hangs below the menu bar.
    static let pillDrop: CGFloat = 8
    /// The fixed panel's height: room for the tallest state (a prompt) under the first row.
    static let panelHeight: CGFloat = 260

    /// Measures a display. `menuBarHeight` is `frame.maxY - visibleFrame.maxY` (0 when the menu bar hides).
    static func measure(frame: CGRect, safeAreaTop: CGFloat, leftAreaWidth: CGFloat?, rightAreaWidth: CGFloat?, menuBarHeight: CGFloat) -> NotchGeometry {
        guard safeAreaTop > 0 else {
            let bar = menuBarHeight >= 18 ? menuBarHeight : 24
            return NotchGeometry(hasNotch: false, cameraWidth: 0, rowHeight: (bar + pillDrop).rounded(), centerX: frame.midX, top: frame.maxY)
        }
        var camera = defaultCamera
        var center = frame.midX
        if let l = leftAreaWidth, let r = rightAreaWidth {
            let gap = frame.width - l - r
            // A gap outside any real housing's size means the areas weren't what we expect; keep the measured default.
            if gap >= 80 && gap <= 400 {
                camera = gap
                center = frame.minX + l + gap / 2
            }
        }
        return NotchGeometry(hasNotch: true, cameraWidth: camera, rowHeight: safeAreaTop + 1, centerX: center, top: frame.maxY)
    }

    /// How wide the shape is in each state.
    enum Size: Equatable {
        /// Idle: the hardware notch (1 pt larger each side), or nothing for the pill.
        case rest
        /// Idle with the pointer on it: a little wider, for the bars mark and the hotkey.
        case peek
        /// Listening, writing, or a notice.
        case active
        /// Hovered while listening, an error, or a notice with an action.
        case wide
        /// A prompt ("Remember this word?").
        case prompt
    }

    func width(_ size: Size) -> CGFloat {
        if hasNotch {
            switch size {
            case .rest: return cameraWidth + 2
            case .peek: return cameraWidth + 2 * Self.peekWing
            case .active: return cameraWidth + 2 * Self.wing
            case .wide: return cameraWidth + 2 * Self.wideWing
            case .prompt: return cameraWidth + 2 * Self.promptWing
            }
        }
        switch size {
        case .rest: return 0
        case .peek, .active: return Self.pillWidth
        case .wide: return Self.pillWideWidth
        case .prompt: return Self.pillPromptWidth
        }
    }

    /// The width of each wing beside the camera for a shape this wide (the whole width for the pill).
    func wingWidth(_ width: CGFloat) -> CGFloat {
        hasNotch ? max(0, (width - cameraWidth) / 2) : width
    }

    /// The bottom corners: the notch's own 9 pt (the pill's 14 pt) for one row, rounder as the shape grows.
    func radius(height: CGFloat) -> CGFloat {
        let extra = height - rowHeight
        if extra <= 0.5 { return hasNotch ? 9 : 14 }
        if extra < 40 { return 16 }
        if extra < 80 { return 18 }
        return 20
    }

    /// The fixed panel the shape draws in: wide enough for a prompt plus the flares, flush with the top edge.
    var panelFrame: CGRect {
        let w = (width(.prompt) + 2 * Self.flare + 16).rounded(.up)
        let h = Self.panelHeight
        return CGRect(x: (centerX - w / 2).rounded(), y: top - h, width: w, height: h)
    }

    /// The shape's own rectangle on screen (the flares aren't clickable), for a shape `size` big.
    func shapeRect(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: centerX - width / 2, y: top - height, width: width, height: height)
    }
}

/// How a notice reads in the notch: its first sentence as a bold title, the rest under it.
enum NoticeText {
    static func split(_ text: String) -> (title: String, detail: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first ". " or ": " ends the title; a period inside "⌃⌘V" or a number doesn't.
        var cut: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if (c == "." || c == ":" || c == "?" || c == "!"), next < s.endIndex, s[next] == " " { cut = i; break }
            i = next
        }
        guard let end = cut else { return (s, "") }
        let title = String(s[...end]).trimmingCharacters(in: .whitespaces)
        let detail = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        // "Stopped listening:" reads better without the colon as a title.
        return (title.hasSuffix(":") ? String(title.dropLast()) : title, detail)
    }
}
