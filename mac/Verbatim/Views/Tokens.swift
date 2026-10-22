import SwiftUI
#if os(macOS)
import AppKit
typealias PColor = NSColor
#else
import UIKit
typealias PColor = UIColor
#endif

// Shared by the Mac and iPhone apps: palette, type roles, motion. Mac-only components stay in Theme.swift.

/// The palette: Verbatim brand, "The Idea Archive" (BRAND_GUIDE.md, October 2026).
/// Paper surfaces, ink structure, persimmon focal moments; pink, butter, and sage for feature cards and notes.
/// Every token has a light and a dark value and follows the system (or Settings › Appearance). Dark mode is a
/// near-black green, not an inversion. Under Increase Contrast, secondary text and rules move toward ink.
///
/// The older token names (iris, coral, lime…) stay as aliases so every screen moved to the new palette at once;
/// new code uses the brand names in the second block.
enum Ink {
    // Canonical brand palette
    static let paperHex: UInt32 = 0xF5F0E6, inkHex: UInt32 = 0x26352E, persimmonHex: UInt32 = 0xFA6B47
    static let petalHex: UInt32 = 0xEFB6C8, butterHex: UInt32 = 0xF4C76B, sageHex: UInt32 = 0xAFC398, readerHex: UInt32 = 0xFFFDF9

    // Surfaces
    static let paper = dyn(paperHex, 0x18241F)                 // app background
    static let reader = dyn(readerHex, 0x1D2B25)               // transcript reading sheet
    static let card = dyn(readerHex, 0x202F28)                 // neutral cards and rows
    static let cardHover = dyn(0xFBF8F1, 0x253630)
    static let side = dyn(0xEFE9DD, 0x1C2A24)
    static let bar = dyn(0xF1EBDF, 0x1E2C26)
    static let raised = dyn(0xFAF6EE, 0x202F28)

    // Text (contrast-checked on paper and reader white)
    static let ink = dyn(inkHex, 0xF5F0E6)                       // primary, 11.9:1
    static let dim = dynC(0x545E56, 0xD4CDC0, inkHex, 0xF5F0E6)  // secondary, 5.9:1
    static let mute = dynC(0x606962, 0xA1A29A, 0x3E4A43, 0xD4CDC0) // metadata and timestamps, 5.0:1
    static let faint = dynC(0x8E938A, 0x6F7A72, 0x606962, 0xA1A29A) // decorative only, never body text

    // Brand accents
    static let persimmon = dyn(persimmonHex, 0xF27A57)
    /// Persimmon for small text and glyphs on paper (5.1:1); the bright persimmon is for fills and large marks.
    static let accentText = dyn(0xB23F24, 0xFF8A6B)
    static let petal = dyn(petalHex, 0xC98EA2)
    static let butter = dyn(butterHex, 0xD4AB55)
    static let sage = dyn(sageHex, 0x93A87C)
    static let sageText = dyn(0x4F6440, 0xB9CDA3)
    static let persimmonTint = dyn(0xFDE4DA, 0x3A2A22)
    static let petalTint = dyn(0xFAE6EC, 0x33282D)
    static let butterTint = dyn(0xFCF0D2, 0x332E20)
    static let sageTint = dyn(0xE9EFE0, 0x26322A)
    /// A switch that's on: deep sage on paper, a lighter sage on dark, so the white knob always shows.
    static let switchOn = dyn(0x4F6440, 0x6E8A58)
    /// Errors and destructive actions (DESIGN.md §1): always with an icon and a word, never persimmon.
    static let danger = dyn(0xB23F24, 0xFF8A6B)
    /// Butter's text color: small text and glyphs on butter tint (6.4:1 on #FCF0D2).
    static let butterText = dyn(0x6B5320, 0xE5C77F)
    /// The Record panel's fill: persimmon nudged lighter (#FB7350), so ink text on it reaches 4.7:1 at any size.
    /// `persimmon` (#FA6B47) stays the brand and app-icon color.
    static let recordFill = dyn(0xFB7350, 0xF27A57)
    /// Neutral chips and tags (kinds, tags, speakers, projects, counts): ink at 6% behind `dim` text.
    static let neutralChip = make { dark, _ in
        dark ? PColor(hex: 0xF5F0E6).withAlphaComponent(0.08) : PColor(hex: inkHex).withAlphaComponent(0.06)
    }
    /// The disc behind an icon on a colored tile: ink at 8%, never a white disc (DESIGN.md §3).
    static let iconDisc = inkFixed.opacity(0.08)
    /// Always-ink and always-reader-white, for surfaces that stay dark or light in both modes (HUD pill, toasts,
    /// text on brand color fills).
    static let inkFixed = Color(hex: inkHex)
    static let readerFixed = Color(hex: readerHex)
    static let paperFixed = Color(hex: paperHex)
    static let persimmonFixed = Color(hex: persimmonHex)
    /// Fixed text colors for surfaces that keep one look in both modes (the dictation bar's paper and ink tabs, the
    /// keyboard's lock screen): deep persimmon and mute on paper; light persimmon and light mute on ink.
    static let accentTextOnPaper = Color(hex: 0xB23F24)
    static let accentTextOnInk = Color(hex: 0xFF8A6B)
    static let muteOnPaper = Color(hex: 0x606962)
    static let muteOnInk = Color(hex: 0xA1A29A)

    /// Reliable primary controls: ink fill with a reader-white label (cream with an ink label in dark).
    static let interactive = dyn(inkHex, 0xE9E3D6)
    static let onInteractive = dyn(readerHex, 0x18241F)

    // Structure
    static let hairline = make { dark, hc in
        return dark ? PColor(hex: 0xF5F0E6).withAlphaComponent(hc ? 0.3 : 0.12) : PColor(hex: inkHex).withAlphaComponent(hc ? 0.4 : 0.14)
    }
    static let outlineStrong = make { dark, _ in
        dark ? PColor(hex: 0xF5F0E6).withAlphaComponent(0.36) : PColor(hex: inkHex).withAlphaComponent(0.36)
    }
    static let track = dyn(0xE8E2D6, 0x2A3A33)                  // segmented tracks, progress rails
    /// Placeholders while a link loads: the title bar, and the striped thumbnail's two stripes.
    static let placeholder = dyn(0xEEE7DA, 0x26352E)
    static let stripeA = dyn(0xE9E1D2, 0x24332C)
    static let stripeB = dyn(0xE2D9C8, 0x2A3A33)
    static let wash = dyn(0xEFE9DD, 0x22312A)                   // selected rows on paper
    static let notes = dyn(0xF1EBDF, 0x1C2A24)                  // notes panel
    /// Saved passage: butter behind ink text, readable in both modes.
    static let saved = make { dark, _ in
        dark ? PColor(hex: 0xD4AB55).withAlphaComponent(0.26) : PColor(hex: butterHex).withAlphaComponent(0.5)
    }
    /// The playing passage: a quiet sage wash (distinct from saved butter and search persimmon).
    static let playing = make { dark, _ in
        dark ? PColor(hex: 0x93A87C).withAlphaComponent(0.2) : PColor(hex: sageHex).withAlphaComponent(0.32)
    }
    /// Search matches: persimmon tint.
    static let match = make { dark, _ in
        dark ? PColor(hex: 0xF27A57).withAlphaComponent(0.3) : PColor(hex: persimmonHex).withAlphaComponent(0.24)
    }
    /// Hover and selected-row tint (accentSubtle).
    static let accentSubtle = make { dark, _ in
        dark ? PColor(hex: 0xF27A57).withAlphaComponent(0.14) : PColor(hex: persimmonHex).withAlphaComponent(0.11)
    }
    static let glassTint = make { dark, _ in
        dark ? PColor.white.withAlphaComponent(0.03) : PColor(hex: paperHex).withAlphaComponent(0.35)
    }
    /// The selected sidebar row: a reader-white sheet in light, a soft raised tint in dark.
    static let selectedPill = make { dark, _ in dark ? PColor.white.withAlphaComponent(0.08) : PColor(hex: readerHex).withAlphaComponent(0.92) }
    static let selectedPillEdge = make { dark, _ in dark ? PColor.white.withAlphaComponent(0.1) : PColor(hex: inkHex).withAlphaComponent(0.1) }

    // Legacy names, mapped onto the brand (kept so existing screens compile and move together).
    static let iris = interactive
    static let irisDeep = interactive
    static let irisTint = accentSubtle
    static let coral = persimmon
    static let coralTint = persimmonTint
    static let lime = butter
    static let limeTint = butterTint
    static let limeText = sageText

    #if os(iOS)
    /// Paper and ink as UIColors, for UIKit surfaces (the keyboard's background and its globe key).
    static let paperUI = UIColor { tc in UIColor(hex: tc.userInterfaceStyle == .dark ? 0x18241F : paperHex) }
    static let inkUI = UIColor { tc in UIColor(hex: tc.userInterfaceStyle == .dark ? 0xF5F0E6 : inkHex) }
    #endif

    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        make { isDark, _ in isDark ? PColor(hex: dark) : PColor(hex: light) }
    }
    /// Like `dyn`, with stronger values when Increase Contrast is on.
    static func dynC(_ light: UInt32, _ dark: UInt32, _ hcLight: UInt32, _ hcDark: UInt32) -> Color {
        make { isDark, hc in isDark ? PColor(hex: hc ? hcDark : dark) : PColor(hex: hc ? hcLight : light) }
    }
    /// A color resolved per appearance (dark?) and contrast setting (increased?), on Mac and iPhone.
    static func make(_ f: @escaping (Bool, Bool) -> PColor) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { a in f(a.isDark, NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) })
        #else
        return Color(uiColor: UIColor { tc in f(tc.userInterfaceStyle == .dark, tc.accessibilityContrast == .high) })
        #endif
    }
}

/// Type roles (BRAND_GUIDE §04). Instrument Serif, Instrument Sans, and IBM Plex Mono aren't bundled (license
/// review pending), so the system stands in: New York for the display serif, SF Pro for sans, SF Mono for data.
extension Ink {
    /// Editorial serif: Home headline, section titles, document titles. Never transcript body text.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }
    /// Monospaced data: timestamps, durations, dates, indexes. Tabular digits.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced).monospacedDigit() }
}

extension View {
    /// The neutral card surface: a fill (reader white by default) in a continuous rounded rectangle, with an
    /// ink hairline.
    func cardSurface(radius: CGFloat, fill: Color = Ink.card) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Ink.hairline))
    }
}

/// Small uppercase monospaced label with tracking: "01 / RECENT". Sparse use.
struct Overline: View {
    var text: String
    var color: Color = Ink.mute
    var body: some View {
        Text(text.uppercased()).font(Ink.mono(10.5, weight: .medium)).tracking(1.1).foregroundStyle(color).lineLimit(1)
    }
}

/// Corner radii (DESIGN.md §5.3). Don't round everything the same.
enum Radius {
    /// Buttons, fields, and menu rows.
    static let button: CGFloat = 9
    /// Rows, sheets, and small cards.
    static let row: CGFloat = 13
    /// Tiles and panels.
    static let tile: CGFloat = 17
    /// The Record panel.
    static let record: CGFloat = 22
}

/// Motion (BRAND_GUIDE §10): quick ease-outs, no springy bounce in productivity controls.
/// `snap`, `bounce`, and `hero` remain as names but no longer overshoot.
enum Motion {
    /// Hover tints on small, frequent controls (chips, sidebar rows): quick, so they never trail the pointer.
    static let touch = Animation.easeOut(duration: 0.18)
    /// Cards: tilt, lift, edge light, and release. A 300 ms critically damped spring, so it retargets smoothly
    /// as the pointer moves and when a press is let go mid-flight.
    static let card = Animation.smooth(duration: 0.3)
    /// The press itself lands fast; the release uses `card`.
    static let press = Animation.easeOut(duration: 0.1)
    static let settle = Animation.smooth(duration: 0.3)
    /// Screen changes: 300 ms, minimal movement.
    static let nav = Animation.smooth(duration: 0.3)
    static let snap = Animation.smooth(duration: 0.24)
    static let bounce = Animation.smooth(duration: 0.3)
    static let hero = Animation.smooth(duration: 0.36)

    // Entrances and presses on iPhone (tuned in the web prototype, October 2026). Gentle, never fast.
    /// The prototype's ease, cubic-bezier(.22, .7, .2, 1): a quick start that settles slowly.
    static func gentle(_ duration: Double) -> Animation { .timingCurve(0.22, 0.7, 0.2, 1, duration: duration) }
    /// A screen's first screenful: each element rises 12 pt and fades in, 70 ms after the previous one.
    static let enter = gentle(0.76)
    static let enterStep: Double = 0.07
    /// Tab content arrives from the side you moved toward (26 pt) while it fades in.
    static let enterTab = gentle(0.62)
    /// Rows rise 14 pt as they first scroll into view.
    static let rise = gentle(0.9)
    /// Press: scale 0.97 in and out.
    static let pressSoft = gentle(0.32)
    /// Switches settle without overshoot (no bounce in productivity controls).
    static let toggle = snap
    /// What replaces movement when motion is limited: a short crossfade.
    static let fade = Animation.easeOut(duration: 0.2)
}

// MARK: - Limit animation

/// The "Limit animation" preference (Settings on both apps). Off by default.
enum MotionPreference {
    static let key = "motion.limited"
}

private struct LimitMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the system's Reduce Motion is on or the person turned on Limit animation. Views read this
    /// instead of `accessibilityReduceMotion`, so both switches behave identically: fades instead of movement,
    /// illustrations still, no symbol effects or press scaling. Injected at each window root by `limitMotionRoot()`.
    var limitMotion: Bool {
        get { self[LimitMotionKey.self] }
        set { self[LimitMotionKey.self] = newValue }
    }
}

/// Works out `limitMotion` from the system setting and the preference, and hands it to everything below.
struct LimitMotionRoot: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(MotionPreference.key) private var limited = false
    func body(content: Content) -> some View {
        content.environment(\.limitMotion, systemReduceMotion || limited)
    }
}

extension View {
    /// Apply once at each window root (and in panels hosted outside a window group).
    func limitMotionRoot() -> some View { modifier(LimitMotionRoot()) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}


#if os(macOS)
extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]).map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0) } ?? false }
}
#endif

extension PColor {
    convenience init(hex: UInt32) {
        #if os(macOS)
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        #else
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        #endif
    }
}
