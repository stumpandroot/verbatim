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
    /// Color panels in the website style (DESIGN.md §5.5): the brand fills in light, a little deeper in dark only, so a
    /// panel never glows on the near-black green. Ink text (`inkFixed`) on all four in both modes. Mac surfaces built
    /// with the web-style kit (WebStyle.swift) use these; the plain brand tokens stay for everything else.
    static let panelRecord = dyn(0xFB7350, 0xE2694B)
    static let panelButter = dyn(butterHex, 0xDDB563)
    static let panelSage = dyn(sageHex, 0x9DB088)
    static let panelPetal = dyn(petalHex, 0xD9A3B5)
    /// The hard offset shadow under outlined cards and highlighted rows (website style): ink in light, near black in dark.
    static let hard = dyn(inkHex, 0x0C1310)
    /// Filter chips at rest (website style): a soft wash, no border. Selected chips are `ink` with `paper` text.
    static let chip = dyn(0xE6DFD1, 0x22312A)
    static let chipHover = dyn(0xDAD4C7, 0x2E3B34)
    /// A switch that's on in the iPhone's website style: ink on paper, the lighter sage on dark so the white knob
    /// always shows. (`switchOn` is the deep sage the Mac uses.)
    static let switchOnInk = dyn(inkHex, 0x6E8A58)
    /// Status text for something kept (a video kept from a link): sage mixed into ink, text-safe on paper and card.
    static let keptText = dynC(0x5D6E58, 0xD2D6C0, 0x3E4A3A, 0xE3E6D6)
    /// Neutral chips and tags (kinds, tags, speakers, projects, counts): ink at 6% behind `dim` text.
    static let neutralChip = make { dark, _ in
        dark ? PColor(hex: 0xF5F0E6).withAlphaComponent(0.08) : PColor(hex: inkHex).withAlphaComponent(0.06)
    }
    /// Always-ink and always-reader-white, for surfaces that stay dark or light in both modes (HUD pill, toasts,
    /// text on brand color fills).
    static let inkFixed = Color(hex: inkHex)
    static let readerFixed = Color(hex: readerHex)
    static let paperFixed = Color(hex: paperHex)
    /// Dark mode's paper, fixed: the Lock Screen's Live Activities in dark (DESIGN.md §13.7), with `onBlack` text.
    static let darkPaperHex: UInt32 = 0x18241F
    static let darkPaperFixed = Color(hex: darkPaperHex)
    static let persimmonFixed = Color(hex: persimmonHex)
    /// Fixed text colors for surfaces that keep one look in both modes (the dictation bar's paper and ink tabs, the
    /// keyboard's lock screen): deep persimmon and mute on paper; light persimmon and light mute on ink.
    static let accentTextOnPaper = Color(hex: 0xB23F24)
    static let accentTextOnInk = Color(hex: 0xFF8A6B)
    static let muteOnPaper = Color(hex: 0x606962)
    static let muteOnInk = Color(hex: 0xA1A29A)
    /// The notch style (DESIGN.md §12): Apple's black, so the shape reads as the notch, with paper type, persimmon
    /// voice marks, and errors in the light persimmon (5.9:1 on black). The same in light and dark mode.
    static let notchBlack = Color(hex: 0x000000)
    static let onBlack = Color(hex: paperHex)
    static let onBlackDim = Color(hex: paperHex).opacity(0.62)
    static let onBlackHair = Color(hex: paperHex).opacity(0.16)
    static let dangerOnBlack = Color(hex: 0xFF8A6B)
    /// The floating button's labeled pill: the brand butter in both modes (butter means Dictate), ink on it.
    static let butterFixed = Color(hex: butterHex)

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

    // Legacy names, mapped onto the brand (kept so existing screens compile and move together).
    static let iris = interactive
    static let coral = persimmon
    static let lime = butter

    #if os(iOS)
    /// Ink as a UIColor, for UIKit surfaces (the keyboard's globe key).
    static let inkUI = UIColor { tc in UIColor(hex: tc.userInterfaceStyle == .dark ? 0xF5F0E6 : inkHex) }
    #endif

    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        make { isDark, hc in
            #if os(macOS)
            // Mac Native look (NativeLook.swift): resolved for this appearance, once, then cached.
            if let native = NativeSwap.color(light: light, dark: isDark, increased: hc) { return native }
            #endif
            return isDark ? PColor(hex: dark) : PColor(hex: light)
        }
    }
    /// Like `dyn`, with stronger values when Increase Contrast is on.
    static func dynC(_ light: UInt32, _ dark: UInt32, _ hcLight: UInt32, _ hcDark: UInt32) -> Color {
        make { isDark, hc in
            #if os(macOS)
            if let native = NativeSwap.color(light: light, dark: isDark, increased: hc) { return native }
            #endif
            return isDark ? PColor(hex: hc ? hcDark : dark) : PColor(hex: hc ? hcLight : light)
        }
    }
    /// A color resolved per appearance (dark?) and contrast setting (increased?), on Mac and iPhone.
    static func make(_ f: @escaping (Bool, Bool) -> PColor) -> Color {
        #if os(macOS)
        // Increase Contrast is read once per change (ContrastSetting), not on every resolve.
        return Color(nsColor: NSColor(name: nil) { a in f(a.isDark, ContrastSetting.increased) })
        #elseif os(watchOS)
        // The Apple Watch app is always dark (DESIGN.md §20), and watchOS has no trait collection to resolve against.
        return Color(uiColor: f(true, false))
        #else
        return Color(uiColor: UIColor { tc in f(tc.userInterfaceStyle == .dark, tc.accessibilityContrast == .high) })
        #endif
    }
}

/// Type roles (BRAND_GUIDE §04). Instrument Serif, Instrument Sans, and IBM Plex Mono aren't bundled (license
/// review pending), so the system stands in: New York for the display serif, SF Pro for sans, SF Mono for data.
extension Ink {
    /// Editorial serif: Home headline, section titles, document titles. Never transcript body text.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        #if os(macOS)
        if NativeSwap.on { return NativeSwap.serif(size, weight: weight) }   // Mac Native look: SF Pro
        #endif
        return .system(size: size, weight: weight, design: .serif)
    }
    /// Monospaced data: timestamps, durations, dates, indexes. Tabular digits.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        #if os(macOS)
        if NativeSwap.on { return .system(size: size, weight: weight).monospacedDigit() }   // Mac Native look
        #endif
        return .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }
    /// The wordmark (DESIGN.md §4): lowercase "verbose" in the serif with a persimmon period. The period is a mark,
    /// so it uses the text-safe persimmon (`accentText`, 5.1:1 on paper); the bright fill measures 2.5:1 on paper.
    static func wordmark(_ size: CGFloat, color: Color = Ink.ink) -> Text {
        Text("\(Text("verbose").foregroundStyle(color))\(Text(".").foregroundStyle(accentText))").font(serif(size))
    }
    /// The tagline (DESIGN.md §4), set in the serif on About and the first onboarding screen.
    static let tagline = "Go ahead. Be verbose."
}

// MARK: - Native look

/// The Native look's one brand color (DESIGN.md §13), set as the tint at the root. Light is persimmon deepened until
/// white on it and it on white both reach 4.5:1 for small text (#D5431F; the mockup's #E04E2A measures 4.0:1). Dark
/// is #FF6B47 (6.0:1 on #1C1C1E). The record disc keeps the brand persimmon (`persimmonFixed`): it carries no text.
extension Ink {
    static let nativeAccentLightHex: UInt32 = 0xD5431F, nativeAccentDarkHex: UInt32 = 0xFF6B47
    static let nativeAccent = dyn(nativeAccentLightHex, nativeAccentDarkHex)
}

// MARK: - Premium Native

/// Premium Native on both devices (DESIGN.md §13.2 for the Mac, §13.3 for iPhone; mockup "premium", section 01): a
/// warm off-white page (black in dark) with a soft persimmon glow, and gradient cards in the warm brand colors, never
/// purple. One name per value: lists the devices share have one name, and a device's own tuning carries its name.
/// Gradient stops run top to bottom.
///   - iPhone: `persimmon`, `ink`, `sage`, and `rose`. White text measures 4.5:1 or better from a third of the way
///     down, and 3:1 at the top under the cards' 10% highlight, where only big numbers sit
///     (mac/tools/test-premium-phone.sh reads these lists).
///   - Mac: `macPersimmon`, `ink`, and `macSage` (rose stays on iPhone). Stop positions and where white text may sit
///     are in Views/PremiumRules.swift, and mac/tools/test-premium.sh checks white text against these values. The
///     light stops sit a little deeper than the mockup's so small white text reaches 4.5:1 where it sits.
///   - Widgets (both devices) use the iPhone's four gradients.
enum PremiumInk {
    /// The page (iPhone) and window (Mac) in light; the iPhone's page in dark.
    static let paperLightHex: UInt32 = 0xF6F3F1, paperDarkHex: UInt32 = 0x0B0B0C
    /// The Mac window in dark: near black, a step lighter than the iPhone's page.
    static let windowDarkHex: UInt32 = 0x121213
    /// Small accent text (links, "Cleaned", moment times) on the Mac's warm window and the selection tint: the accent
    /// itself measures 4.1:1 on #F6F3F1, so light text deepens to #BA3618 (5.2:1); dark keeps `Ink.nativeAccentDarkHex`.
    static let accentTextLightHex: UInt32 = 0xBA3618
    static let persimmonLight: [UInt32] = [0xE2602F, 0xC3401C, 0x9E2E14]
    static let persimmonDark: [UInt32] = [0xD9592C, 0xB63A1A, 0x8C2812]
    static let inkLight: [UInt32] = [0x4A6356, 0x2C3E36, 0x1D2A24]
    static let inkDark: [UInt32] = [0x3E564A, 0x24342D, 0x17211C]
    static let sageLight: [UInt32] = [0x6F8A5E, 0x4A6544]
    static let sageDark: [UInt32] = [0x66805A, 0x3F573A]
    static let roseLight: [UInt32] = [0xCB6070, 0x9C3A54]
    static let roseDark: [UInt32] = [0xBD5868, 0x873249]
    static let macPersimmonLight: [UInt32] = [0xEC6A3D, 0xCC4520, 0xB3351A]
    static let macPersimmonDark: [UInt32] = [0xE8683B, 0xC8401F, 0x9C2D15]
    static let macSageLight: [UInt32] = [0x80996C, 0x5E7C56]
    static let macSageDark: [UInt32] = [0x7D976A, 0x4F6A49]
    /// The record button's disc, which carries no text: highlight, brand persimmon, shade.
    static let disc: [UInt32] = [0xFF9C7C, 0xFA6B47, 0xE0502D]
    /// Text on the accent: white on #D5431F (4.5:1), black on #FF6B47 in dark (7.2:1).
    static let onAccentLightHex: UInt32 = 0xFFFFFF, onAccentDarkHex: UInt32 = 0x000000

    static let onAccent = Ink.make { d, _ in PColor(hex: d ? onAccentDarkHex : onAccentLightHex) }
    /// The accent at 11% (18% in dark): tile symbols' circles, the Note tag, a highlighted line, the Mac's selection tint.
    static let accentSoft = Ink.make { d, _ in PColor(hex: d ? Ink.nativeAccentDarkHex : Ink.nativeAccentLightHex).withAlphaComponent(d ? 0.18 : 0.11) }
    /// The ink-green week card's text on a white day dot.
    static let onWhiteInk = Color(hex: 0x2C3E36)
    static let discColors = disc.map { Color(hex: $0) }
    #if !os(macOS)
    // The iPhone's page, cards, and glow. The Mac's window, cards, and glow are in Views/PremiumLook.swift.
    static let paper = Ink.make { d, _ in PColor(hex: d ? paperDarkHex : paperLightHex) }
    static let card = Ink.make { d, _ in PColor(hex: d ? 0x1C1C1E : 0xFFFFFF) }
    static let glow = Ink.make { d, _ in PColor(hex: d ? Ink.nativeAccentDarkHex : Ink.persimmonHex).withAlphaComponent(d ? 0.16 : 0.17) }
    #endif

    /// A gradient's stops as colors that follow light and dark.
    static func stops(_ light: [UInt32], _ dark: [UInt32]) -> [Color] {
        zip(light, dark).map { l, d in Ink.make { isDark, _ in PColor(hex: isDark ? d : l) } }
    }
}

// MARK: - Apple Watch

/// The Apple Watch app and its complications (DESIGN.md §20; mockup "Library features", section 4). Always dark: the
/// page is the app's dark paper, text is paper, and persimmon means record, the one fill on a screen (ink on it,
/// 4.7:1). Fixed values, because the watch has no light mode.
enum WatchInk {
    /// The page: Ink.paper's dark value.
    static let page = Color(hex: 0x18241F)
    /// The Smart Stack card and the complications' plate: Ink.card's dark value.
    static let card = Color(hex: 0x202F28)
    static let text = Color(hex: Ink.paperHex)
    /// Secondary text, 62% paper (6.2:1 on the page).
    static let dim = Color(hex: Ink.paperHex).opacity(0.62)
    /// Outlined buttons (New thought, Mark) and the Sent ring.
    static let hair = Color(hex: Ink.paperHex).opacity(0.22)
    /// A pressed outlined button.
    static let pressed = Color(hex: Ink.paperHex).opacity(0.16)
    /// Record, Stop, the recording dot, and the voice bars: the Record panel's fill (`recordFill`'s light value), so ink
    /// text on it reaches 4.7:1 at any size.
    static let record = Color(hex: 0xFB7350)
    static let onRecord = Color(hex: Ink.inkHex)
    /// The "Marked 4:12" toast: paper with ink text.
    static let toast = Color(hex: Ink.paperHex)
    static let onToast = Color(hex: Ink.inkHex)
}

// MARK: - The look (refined)

// The one look that replaces Verbose style and Native (DESIGN.md §13; approved mockup "Verbose Refined Look", October
// 28, 2026). Apple draws the chrome; these values draw the content. Every value has a light and a dark value, and an
// Increase Contrast value where the plain one is too faint. The table is plain Swift between the two markers, so
// mac/tools/test-refined.sh lifts it out and checks every text pair the kit draws against 4.5:1 on Linux.
//
// Changes from the mockup's colors, for contrast: a persimmon fill is #FB7350 (ink on the mockup's #FA6B47 measures
// 4.45:1), and dark mode's persimmon fill is #F27A57 (ink on the deeper #E2694B measures 3.9:1). The other three fills
// in dark are the color panels' deeper values (§1.7).

// refined-table begin
/// The refined look's values as 0xRRGGBB, read by `Refined` (below) and by the pure rules (Views/RefinedRules.swift).
enum RefinedHex {
    /// One color: light, dark, and the two Increase Contrast values (the plain ones unless given).
    struct Tone: Equatable {
        let light: UInt32, dark: UInt32, hcLight: UInt32, hcDark: UInt32
        init(_ light: UInt32, _ dark: UInt32, hc: (light: UInt32, dark: UInt32)? = nil) {
            self.light = light; self.dark = dark
            hcLight = hc?.light ?? light; hcDark = hc?.dark ?? dark
        }
        func value(dark isDark: Bool, increased: Bool) -> UInt32 {
            isDark ? (increased ? hcDark : dark) : (increased ? hcLight : light)
        }
    }

    /// A tone laid over whatever is under it at an opacity: light, dark, and the two Increase Contrast opacities.
    struct Wash: Equatable {
        let base: Tone
        let light: Double, dark: Double, hcLight: Double, hcDark: Double
        init(_ base: Tone, _ light: Double, _ dark: Double, hc: (light: Double, dark: Double)? = nil) {
            self.base = base; self.light = light; self.dark = dark
            hcLight = hc?.light ?? light; hcDark = hc?.dark ?? dark
        }
        func alpha(dark isDark: Bool, increased: Bool) -> Double {
            isDark ? (increased ? hcDark : dark) : (increased ? hcLight : light)
        }
    }

    // Surfaces
    /// The page.
    static let paper = Tone(0xF5F0E6, 0x18241F)
    /// Off-white cards and grouped containers, and the neutral tile. No outline; a hairline under Increase Contrast.
    static let card = Tone(0xFFFDF9, 0x202F28)
    /// Search fields on the page.
    static let field = Tone(0xEBE5D9, 0x24332C)
    /// A segmented control's track.
    static let track = Tone(0xE8E2D6, 0x2A3A33)
    /// The Mac player's scrub rail and an off switch on the Mac.
    static let rail = Tone(0xE0D9CB, 0x33433B)

    // Text
    static let ink = Tone(0x26352E, 0xF5F0E6)
    static let dim = Tone(0x545E56, 0xD4CDC0, hc: (0x26352E, 0xF5F0E6))
    static let mute = Tone(0x606962, 0xA1A29A, hc: (0x3E4A43, 0xD4CDC0))
    /// Chevrons and other marks that repeat a word beside them; never text.
    static let faint = Tone(0x8E938A, 0x6F7A72, hc: (0x606962, 0xA1A29A))
    /// Persimmon for text and glyphs: links, the selected tab, a selected filter chip, the Mac's switches.
    static let accentText = Tone(0xB23F24, 0xFF8A6B)
    /// Sage for text: a playing line's time.
    static let sageText = Tone(0x4F6440, 0xB9CDA3)
    /// A destructive row's title (Delete all data, Clear saved voices): red, apart from the persimmon accent, on its
    /// neutral square. Recording's system red stays on the record disc and the stop square.
    static let danger = Tone(0xB3261E, 0xFF8A80, hc: (0x8C1D18, 0xFFB4AB))
    /// Ink on a Full fill, in both modes: the fills stay light in dark mode, so their text stays ink.
    static let onFill = Tone(0x26352E, 0x26352E)
    /// Reader white in both modes: the ready chip's lift on the Record card.
    static let lift = Tone(0xFFFDF9, 0xFFFDF9)

    // Fills (the Full palette): the Record card, tiles, kind badges, speaker and kind chips, and icon squares.
    static let persimmon = Tone(0xFB7350, 0xF27A57)
    static let butter = Tone(0xF4C76B, 0xDDB563)
    static let sage = Tone(0xAFC398, 0x9DB088)
    static let petal = Tone(0xEFB6C8, 0xD9A3B5)

    // Tints (the Soft palette's Record card and tiles; a selected filter chip or row)
    static let persimmonTint = Tone(0xFDE4DA, 0x3A2A22)
    static let butterTint = Tone(0xFCF0D2, 0x332E20)
    static let sageTint = Tone(0xE9EFE0, 0x26322A)
    static let petalTint = Tone(0xFAE6EC, 0x33282D)
    /// An icon square with no hue (Settings rows that aren't one of the four).
    static let neutralSquare = Tone(0xE6DFD1, 0x2E3B34)

    // Playback (sage means playback)
    static let played = Tone(0x6E8A58, 0x9DB088)
    static let waveRest = Tone(0xCFC8BA, 0x56665D)

    /// A switch that's on, on the Mac (iPhone switches stay the system's green). Dark is the deeper panel persimmon,
    /// so the white knob still reads on it (3.3:1; the light accent text measures 2.3:1).
    static let macSwitch = Tone(0xB23F24, 0xE2694B)

    // Washes
    /// Hairline separators inside cards, and a card's edge under Increase Contrast.
    static let separator = Wash(ink, 0.10, 0.12, hc: (0.40, 0.30))
    /// Quiet buttons and chips at rest (filter chips, the recorder's Mark and Pause).
    static let neutral = Wash(ink, 0.07, 0.08, hc: (0.12, 0.14))
    /// Every other row of a table in a card (the Mac Library), so a long row reads across.
    static let stripe = Wash(ink, 0.025, 0.03, hc: (0.05, 0.06))
    /// The line being played.
    static let playing = Wash(Tone(0xAFC398, 0x93A87C), 0.32, 0.20, hc: (0.45, 0.30))
    /// The Record card's rings on a Full fill, and on a Soft tint.
    static let ringFull = Wash(onFill, 0.28, 0.28, hc: (0.45, 0.45))
    static let ringSoft = Wash(accentText, 0.35, 0.35, hc: (0.55, 0.55))
    /// A Home tile's line pattern on a Full fill (fixed ink at 13%), and on a Soft tint or the off-white tile (the
    /// reading ink at 9%).
    static let patternFull = Wash(onFill, 0.13, 0.13)
    static let patternSoft = Wash(ink, 0.09, 0.09)
    /// The ready chip on a Full fill: reader white at 30% (ink on it 6.3:1; the mockup's ink at 10% measures 4.1:1).
    static let chipFull = Wash(lift, 0.30, 0.30, hc: (0.45, 0.45))
    /// The ready chip on a Soft tint.
    static let chipSoft = Wash(ink, 0.10, 0.12)
    /// The player bar where system glass isn't available (before macOS 26 and iOS 26).
    static let glassFallback = Wash(card, 0.92, 0.92, hc: (1, 1))
}
// refined-table end

/// The refined look's colors (DESIGN.md §13), built once from `RefinedHex`. They never turn into the Mac's Native
/// system colors: the kit draws only the refined look. Palette-dependent fills come from `RefinedRules`.
enum Refined {
    static func color(_ t: RefinedHex.Tone) -> Color {
        Ink.make { dark, hc in PColor(hex: t.value(dark: dark, increased: hc)) }
    }
    static func color(_ w: RefinedHex.Wash) -> Color {
        Ink.make { dark, hc in
            PColor(hex: w.base.value(dark: dark, increased: hc)).withAlphaComponent(CGFloat(w.alpha(dark: dark, increased: hc)))
        }
    }

    static let paper = color(RefinedHex.paper)
    static let card = color(RefinedHex.card)
    static let field = color(RefinedHex.field)
    static let track = color(RefinedHex.track)
    static let rail = color(RefinedHex.rail)
    static let ink = color(RefinedHex.ink)
    static let dim = color(RefinedHex.dim)
    static let mute = color(RefinedHex.mute)
    static let faint = color(RefinedHex.faint)
    static let accentText = color(RefinedHex.accentText)
    static let sageText = color(RefinedHex.sageText)
    static let danger = color(RefinedHex.danger)
    static let onFill = color(RefinedHex.onFill)
    /// Reader white in both modes: text on an ink action on a Full fill (the recording card's Stop and transcribe).
    static let lift = color(RefinedHex.lift)
    static let persimmon = color(RefinedHex.persimmon)
    static let butter = color(RefinedHex.butter)
    static let sage = color(RefinedHex.sage)
    static let petal = color(RefinedHex.petal)
    static let persimmonTint = color(RefinedHex.persimmonTint)
    static let butterTint = color(RefinedHex.butterTint)
    static let sageTint = color(RefinedHex.sageTint)
    static let petalTint = color(RefinedHex.petalTint)
    static let neutralSquare = color(RefinedHex.neutralSquare)
    static let played = color(RefinedHex.played)
    static let waveRest = color(RefinedHex.waveRest)
    static let macSwitch = color(RefinedHex.macSwitch)
    static let separator = color(RefinedHex.separator)
    static let neutral = color(RefinedHex.neutral)
    static let stripe = color(RefinedHex.stripe)
    static let playing = color(RefinedHex.playing)
    static let glassFallback = color(RefinedHex.glassFallback)
    /// The record disc's dot and the stop square: the system's red (it adapts to dark mode and Increase Contrast),
    /// and nowhere else.
    static let recordRed = Color.red

    #if os(iOS)
    /// A tone as a UIKit color that follows light, dark, and Increase Contrast: the system search field on the iPhone
    /// Library's page (`SystemSearchField`).
    static func uiColor(_ t: RefinedHex.Tone) -> UIColor {
        UIColor { tc in PColor(hex: t.value(dark: tc.userInterfaceStyle == .dark, increased: tc.accessibilityContrast == .high)) }
    }
    #endif
}

// MARK: - Look switch card

/// Verbose style's paper, card, ink, and hard shadow, which never turn into Native's system colors on the Mac (`dyn`
/// does, under NativeSwap). The look-switch card (LookSwitch.swift) draws Verbose style while Native is still stored.
extension Ink {
    static let paperVerbose = make { dark, _ in PColor(hex: dark ? 0x18241F : paperHex) }
    static let cardVerbose = make { dark, _ in PColor(hex: dark ? 0x202F28 : readerHex) }
    static let inkVerbose = make { dark, _ in PColor(hex: dark ? 0xF5F0E6 : inkHex) }
    static let hardVerbose = make { dark, _ in PColor(hex: dark ? 0x0C1310 : inkHex) }
}

extension View {
    /// The neutral card surface: a fill (reader white by default) in a continuous rounded rectangle, with an
    /// ink hairline. iPhone Native draws a grouped card instead (the Mac's tokens already switch).
    func cardSurface(radius: CGFloat, fill: Color = Ink.card) -> some View {
        modifier(CardSurface(radius: radius, fill: fill))
    }
}

private struct CardSurface: ViewModifier {
    var radius: CGFloat
    var fill: Color
    @Environment(\.look) private var look

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if os(iOS)
        // brand: native begin
        if look == .native {
            // The card and reader whites become the grouped card; any other fill (a selection tint) stays. No hairline.
            let native = fill == Ink.card || fill == Ink.reader ? Color(uiColor: .secondarySystemGroupedBackground) : fill
            content.background(native, in: shape)
        } else {
            content.background(fill, in: shape).overlay(shape.strokeBorder(Ink.hairline))
        }
        // brand: native end
        #else
        content.background(fill, in: shape).overlay(shape.strokeBorder(Ink.hairline))
        #endif
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

/// Corner radii (DESIGN.md §5.3): sharp, in four steps. Don't round everything the same.
enum Radius {
    /// Buttons, fields, chips, keycaps, and menu rows.
    static let button: CGFloat = 4
    /// Rows and sheets.
    static let row: CGFloat = 6
    /// Tiles, cards, and panels.
    static let tile: CGFloat = 8
    /// The Record panel.
    static let record: CGFloat = 10
    /// The Apple Watch app's Record and New thought buttons (DESIGN.md §20), rounded to sit inside the watch's screen.
    static let watch: CGFloat = 26
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

    // Presses on iPhone (tuned in the web prototype, October 2026). Screens and rows have no entrance (§7).
    /// The prototype's ease, cubic-bezier(.22, .7, .2, 1): a quick start that settles slowly.
    static func gentle(_ duration: Double) -> Animation { .timingCurve(0.22, 0.7, 0.2, 1, duration: duration) }
    /// Press: scale 0.97 in and out.
    static let pressSoft = gentle(0.32)
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
