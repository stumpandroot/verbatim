import SwiftUI
#if os(macOS)
import AppKit
typealias PColor = NSColor
#else
import UIKit
typealias PColor = UIColor
#endif

// Shared by the Mac and iPhone apps and their extensions: the palette, type roles, radii, and motion. Mac-only
// controls are in Controls.swift.

// MARK: - The palette

// Verbose's one look (DESIGN.md §13; approved mockup "Verbose Refined Look", October 28, 2026). Apple draws the
// chrome; these values draw the content. Every value has a light and a dark value, and an
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
    /// The Mac window's sidebar: a paper gray beside the page (mockup: every Mac board), with a persimmon tint on the
    /// selected row.
    static let side = Tone(0xECE6DA, 0x1C2A24)

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
    /// Fills under white system labels, the same in light and dark (the light text tones): swipe actions (Pin, Restore)
    /// and the native Paste button. White on them is 5.8:1 and 6.5:1; the dark text tones measure 2.3:1 and 1.7:1.
    static let accentFill = Tone(0xB23F24, 0xB23F24)
    static let sageFill = Tone(0x4F6440, 0x4F6440)
    /// A destructive row's title (Delete all data, Clear saved voices): red, apart from the persimmon accent, on its
    /// neutral square. Recording's system red stays on the record disc and the stop square.
    static let danger = Tone(0xB3261E, 0xFF8A80, hc: (0x8C1D18, 0xFFB4AB))
    /// Ink on a Full fill, in both modes: the fills stay light in dark mode, so their text stays ink.
    static let onFill = Tone(0x26352E, 0x26352E)
    /// Reader white in both modes: the ready chip's lift on the Record card.
    static let lift = Tone(0xFFFDF9, 0xFFFDF9)

    // Fills (the Full palette): the Record card, tiles, kind badges, speaker and kind chips, and icon squares. Each hue
    // has a meaning within a role (DESIGN.md §1, Roles; GPT-29): a capture action (persimmon Record, butter Dictate,
    // sage Import, petal App audio), a kind, telling speakers or projects apart, or decoration that carries no meaning.
    // Persimmon text and tints (`accentText`, `persimmonTint`) mean "chosen" or "a link"; butter also marks what a search
    // found, and sage what's playing. The word or glyph beside a hue always carries the meaning.
    static let persimmon = Tone(0xFB7350, 0xF27A57)
    static let butter = Tone(0xF4C76B, 0xDDB563)
    static let sage = Tone(0xAFC398, 0x9DB088)
    static let petal = Tone(0xEFB6C8, 0xD9A3B5)

    // Tints (the Soft palette's Record card and tiles; a selected filter chip or row)
    static let persimmonTint = Tone(0xFDE4DA, 0x3A2A22)
    static let butterTint = Tone(0xFCF0D2, 0x332E20)
    static let sageTint = Tone(0xE9EFE0, 0x26322A)
    static let petalTint = Tone(0xFAE6EC, 0x33282D)
    /// The neutral icon square, under an ink glyph: Settings' rows and the Mac's Settings panes (IP-36; a destructive
    /// row adds the `danger` glyph and word), templates, and any other square whose glyph names no capture action.
    static let neutralSquare = Tone(0xE6DFD1, 0x2E3B34)

    // The words calendar's five shades (WordsCalendar.level): a day with no words, then more and more. Day numbers sit
    // on them in `ink`, except the top shade, which takes `onFill` (it stays light in dark mode).
    static let heat0 = Tone(0xEFE9DD, 0x26352E)
    static let heat1 = Tone(0xFDE4DA, 0x3A2A22)
    static let heat2 = Tone(0xFCC4AF, 0x5A3A2C)
    static let heat3 = Tone(0xFB9C80, 0x8A4532)
    static let heat4 = Tone(0xFB7350, 0xF27A57)

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
    /// Every other row of a table in a card (the Mac Library), so a long row reads across; a row under the pointer.
    static let stripe = Wash(ink, 0.025, 0.03, hc: (0.05, 0.06))
    /// A card, tile, or the Record card under the pointer (the Mac's Home, MAC-20): ink at 4% over its fill.
    static let hoverWash = Wash(ink, 0.04, 0.05, hc: (0.08, 0.09))
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

/// The refined look's colors (DESIGN.md §13), built once from `RefinedHex`. Palette-dependent fills come from
/// `RefinedRules`.
enum Refined {
    static func color(_ t: RefinedHex.Tone) -> Color {
        make { dark, hc in PColor(hex: t.value(dark: dark, increased: hc)) }
    }
    static func color(_ w: RefinedHex.Wash) -> Color {
        make { dark, hc in
            PColor(hex: w.base.value(dark: dark, increased: hc)).withAlphaComponent(CGFloat(w.alpha(dark: dark, increased: hc)))
        }
    }

    static let paper = color(RefinedHex.paper)
    static let card = color(RefinedHex.card)
    static let field = color(RefinedHex.field)
    static let track = color(RefinedHex.track)
    static let rail = color(RefinedHex.rail)
    static let side = color(RefinedHex.side)
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
    /// The words calendar's shades, by `WordsCalendar.level` (0 to 4).
    static let heat = [color(RefinedHex.heat0), color(RefinedHex.heat1), color(RefinedHex.heat2), color(RefinedHex.heat3), color(RefinedHex.heat4)]
    static let played = color(RefinedHex.played)
    static let waveRest = color(RefinedHex.waveRest)
    static let macSwitch = color(RefinedHex.macSwitch)
    static let separator = color(RefinedHex.separator)
    static let neutral = color(RefinedHex.neutral)
    static let stripe = color(RefinedHex.stripe)
    static let hoverWash = color(RefinedHex.hoverWash)
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


/// How a token resolves: per appearance (dark?) and contrast setting (increased?), on the Mac, iPhone, and Apple Watch.
extension Refined {
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

// MARK: - Fixed values

/// Values that stay the same in light and dark, built from the table: the ink on a kind color's fill, surfaces that
/// are always black (the notch, the Ribbon, the Dynamic Island), and the Lock Screen's Live Activity, which follows the
/// Lock Screen rather than the app.
extension Refined {
    static let inkFixed = Color(hex: RefinedHex.ink.light)
    static let paperFixed = Color(hex: RefinedHex.paper.light)
    static let cardFixed = Color(hex: RefinedHex.card.light)
    static let darkPaperFixed = Color(hex: RefinedHex.paper.dark)
    static let persimmonFixed = Color(hex: RefinedHex.persimmon.light)
    static let butterFixed = Color(hex: RefinedHex.butter.light)
    /// Accent and quiet text on the fixed paper and on the fixed dark paper.
    static let accentTextOnPaper = Color(hex: RefinedHex.accentText.light)
    /// Fills that carry white system labels in light and dark: swipe actions and the native Paste button (IP-03, IP-13).
    static let accentFillFixed = color(RefinedHex.accentFill)
    static let sageFillFixed = color(RefinedHex.sageFill)
    static let accentTextOnInk = Color(hex: RefinedHex.accentText.dark)
    static let muteOnPaper = Color(hex: RefinedHex.mute.light)
    static let muteOnInk = Color(hex: RefinedHex.mute.dark)
    /// Black surfaces and what sits on them: paper text, 62% paper for secondary text (6.2:1 on the dark paper), and a
    /// 16% paper hairline.
    static let black = Color(hex: 0x000000)
    static let onBlack = paperFixed
    static let onBlackDim = paperFixed.opacity(0.62)
    static let onBlackHair = paperFixed.opacity(0.16)
    static let dangerOnBlack = Color(hex: RefinedHex.danger.dark)
}

// MARK: - Type roles

/// Type roles (DESIGN.md §13): New York for the display serif, SF Pro for everything else, with monospaced digits for
/// times and counts. (The Mac's Ribbon, notch, and floating button keep SF Mono: `SurfaceFont`.)
extension Refined {
    /// Editorial serif: titles, the Home headline, document titles. Never transcript body text.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Data: timestamps, durations, dates, counts. SF Pro with tabular digits, so a running time doesn't jitter.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
    /// The wordmark (DESIGN.md §4): lowercase "verbose" in the serif with a persimmon period. The period is a mark,
    /// so it uses the text-safe persimmon (`accentText`); the bright fill is too faint on paper.
    static func wordmark(_ size: CGFloat, color: Color = Refined.ink) -> Text {
        Text("\(Text("verbose").foregroundStyle(color))\(Text(".").foregroundStyle(accentText))").font(serif(size))
    }
    /// The tagline (DESIGN.md §4), set in the serif on About and the first onboarding screen.
    static let tagline = "Go ahead. Be verbose."
}

// MARK: - Scaled type

/// SF Pro (or the serif) at a size given for the default text size, grown and shrunk with Dynamic Type on the text
/// style nearest that size (DESIGN.md §2, §13 Type 3). For screens, widgets, Live Activities, and the watch that set a
/// size of their own instead of a kit role (`refinedFont`). The Mac has no Dynamic Type, so it keeps the size.
struct ScaledFont: ViewModifier {
    let weight: Font.Weight
    let design: Font.Design
    @ScaledMetric private var size: CGFloat

    init(_ size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle?) {
        self.weight = weight
        self.design = design
        _size = ScaledMetric(wrappedValue: size, relativeTo: style ?? ScaledFont.style(for: size))
    }

    /// The text style whose default size is nearest at or below `size`, so a size scales the way that style does.
    static func style(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case 34...: return .largeTitle
        case 28..<34: return .title
        case 22..<28: return .title2
        case 20..<22: return .title3
        case 17..<20: return .body
        case 16..<17: return .callout
        case 15..<16: return .subheadline
        case 13..<15: return .footnote
        case 12..<13: return .caption
        default: return .caption2
        }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// `size` points at the default text size, scaling with Dynamic Type: `.scaledFont(15, weight: .semibold)`.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                    relativeTo style: Font.TextStyle? = nil) -> some View {
        modifier(ScaledFont(size, weight: weight, design: design, relativeTo: style))
    }
}

// MARK: - Touch targets

extension View {
    /// A 44 pt touch area around a control drawn smaller (a Live Activity's or a widget's button, a keyboard chip),
    /// without changing its layout (GPT-23, SF-26): the area grows past the drawn shape on each side that's under 44 pt.
    func activityTarget(width: CGFloat? = nil, height: CGFloat) -> some View {
        let v = max(0, (44 - height) / 2), h = width.map { max(0, (44 - $0) / 2) } ?? 0
        return padding(.vertical, v).padding(.horizontal, h).contentShape(Rectangle()).padding(.vertical, -v).padding(.horizontal, -h)
    }
}

// MARK: - Apple Watch

/// The Apple Watch app and its complications (DESIGN.md §20). Always dark: the page is the dark paper, text is paper,
/// and persimmon means record, the one fill on a screen (the fill's ink on it). Fixed values, because the watch has no
/// light mode.
enum WatchColor {
    /// The page: the dark paper.
    static let page = Refined.darkPaperFixed
    /// The Smart Stack card and the complications' plate: the dark card.
    static let card = Color(hex: RefinedHex.card.dark)
    static let text = Refined.paperFixed
    /// Secondary text, 62% paper (6.2:1 on the page).
    static let dim = Refined.paperFixed.opacity(0.62)
    /// Outlined buttons (New thought, Mark) and the Sent ring.
    static let hair = Refined.paperFixed.opacity(0.22)
    /// A pressed outlined button.
    static let pressed = Refined.paperFixed.opacity(0.16)
    /// Record, Stop, the recording dot, and the voice bars: the persimmon fill, with the fill's ink on it.
    static let record = Refined.persimmonFixed
    static let onRecord = Refined.inkFixed
    /// The "Marked 4:12" toast: paper with ink text.
    static let toast = Refined.paperFixed
    static let onToast = Refined.inkFixed
}

extension View {
    /// The neutral card surface (DESIGN.md §13): a fill (the card by default) in a continuous rounded rectangle, with no
    /// outline; a separator edge under Increase Contrast, where an off-white card on paper is about 1.1:1.
    func cardSurface(radius: CGFloat, fill: Color = Refined.card) -> some View {
        modifier(CardSurface(radius: radius, fill: fill))
    }
}

private struct CardSurface: ViewModifier {
    var radius: CGFloat
    var fill: Color
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background(fill, in: shape)
            .overlay { if contrast == .increased { shape.strokeBorder(Refined.separator) } }
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

/// Motion (DESIGN.md §7): quick ease-outs for hovers and presses; what moves from one place to another (a selected
/// segment, a page, a tab's content) travels on a spring with a slight bounce, so it settles instead of stopping.
/// `snap` remains as a name but no longer overshoots.
enum Motion {
    /// A selection that moves: a segmented control's pill, a highlighted row. Quick, with a slight bounce.
    static let glide = Animation.spring(duration: 0.34, bounce: 0.22)
    /// A page, a tab's content, or a view switch arriving: a spring with a slight bounce.
    static let page = Animation.spring(duration: 0.44, bounce: 0.16)
    /// How far a page travels in from the side (opening or leaving a transcript; an iPhone tab).
    static let pageTravel: CGFloat = 22
    /// How far a sidebar page travels in, up or down, as it fades in.
    static let sidebarTravel: CGFloat = 14
    /// How far a view switch's content travels in (a transcript's tabs).
    static let switchTravel: CGFloat = 18
    /// Hover tints on small, frequent controls (chips, sidebar rows): quick, so they never trail the pointer.
    static let touch = Animation.easeOut(duration: 0.18)
    /// A press lands fast.
    static let press = Animation.easeOut(duration: 0.1)
    static let settle = Animation.smooth(duration: 0.3)
    /// Screen changes: 300 ms, minimal movement.
    static let nav = Animation.smooth(duration: 0.3)
    static let snap = Animation.smooth(duration: 0.24)
    /// What replaces movement when motion is limited: a short crossfade.
    static let fade = Animation.easeOut(duration: 0.2)
    /// A row that flashes to show where something landed (a Settings search result), then fades back slowly.
    static let flash = Animation.easeOut(duration: 0.6)
    /// A view switch in place (a transcript's Original, Cleaned, and Summary; a list's filter): 150 ms.
    static let crossfade = Animation.easeOut(duration: 0.15)
    /// The Ribbon's and the notch's shape between states, one curve for both (DESIGN.md §12, `SurfaceMotion`): 0.3 s, no
    /// bounce, and it keeps its velocity if the state changes mid-move. Under Reduce Motion or Limit animation the
    /// surfaces don't use it; the shape changes at once. (Literals: the widget targets share this file but not
    /// MotionRules.swift; test-motion.sh checks they match `SurfaceMotion`.)
    static let surfaceMorph = Animation.smooth(duration: 0.3)
    /// The surfaces' contents when shape changes are held still: a crossfade over `SurfaceMotion.stillFade` (0.12 s).
    static let surfaceStillFade = AnyTransition.opacity.animation(.easeOut(duration: 0.12))

    /// A card that comes and goes on a dashboard (Home's What's new, the Unlock card): it fades and slides 6 pt,
    /// and the space it leaves closes with `settle`. Under Limit animation it only fades.
    static func cardTransition(limited: Bool) -> AnyTransition {
        limited ? .opacity : .opacity.combined(with: .offset(y: 6))
    }
    /// The animation that goes with `cardTransition`: `settle`, or `fade` under Limit animation.
    static func cardAnimation(limited: Bool) -> Animation { limited ? fade : settle }
}

/// Crossfades a view as a whole when `key` changes (DESIGN.md §7, view switches): the old view fades out as the new one
/// fades in, over `Motion.crossfade`, with no movement, so Limit animation keeps it. The view gets a new identity per
/// key, and only that switch animates; nothing inside (rows, lines) animates on its own.
struct CrossfadeSwitch<Key: Hashable>: ViewModifier {
    var key: Key
    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content.id(key).transition(.opacity)
        }
        .animation(Motion.crossfade, value: key)
    }
}

extension View {
    /// See `CrossfadeSwitch`.
    func crossfadeSwitch<Key: Hashable>(on key: Key) -> some View { modifier(CrossfadeSwitch(key: key)) }
    /// See `SlideSwitch`.
    func slideSwitch<Key: Hashable>(on key: Key, order: Int) -> some View { modifier(SlideSwitch(key: key, order: order)) }
}

/// A count that changes in place (This week's words, the Library's count, the recorder's moments, a run's part): the
/// digits roll to the new value on `Motion.snap`, and only when the count itself changes; under Limit animation they
/// crossfade (DESIGN.md §7). Never on a running clock, which changes every second.
struct CountChange: ViewModifier {
    var value: Int
    @Environment(\.limitMotion) private var limited
    func body(content: Content) -> some View {
        content
            .contentTransition(limited ? .opacity : .numericText(value: Double(value)))
            .animation(limited ? Motion.crossfade : Motion.snap, value: value)
    }
}

extension View {
    /// See `CountChange`.
    func countChange(_ value: Int) -> some View { modifier(CountChange(value: value)) }
}

/// A view switch with a direction (a transcript's tabs): the new view slides in `Motion.switchTravel` from the side of the
/// tab you picked, toward a later tab from the right and an earlier one from the left, as the old one fades out, on
/// `Motion.page`. Limit animation keeps only the crossfade. `order` is the chosen tab's place in its row.
struct SlideSwitch<Key: Hashable>: ViewModifier {
    var key: Key
    var order: Int
    @Environment(\.limitMotion) private var limited
    @State private var heading = SwitchHeading()

    func body(content: Content) -> some View {
        let forward = heading.forward(to: order)
        let insertion: AnyTransition = limited ? .opacity
            : .offset(x: forward ? Motion.switchTravel : -Motion.switchTravel).combined(with: .opacity)
        return ZStack(alignment: .topLeading) {
            content.id(key).transition(.asymmetric(insertion: insertion, removal: .opacity))
        }
        .animation(limited ? Motion.crossfade : Motion.page, value: key)
    }
}

/// Which way the last switch went. It changes only when the order does, so a redraw during the slide (which reads
/// the same order again) keeps the direction the slide started with. Not observed: reading it never redraws anything.
final class SwitchHeading {
    private var last: Int?
    private var wasForward = true
    func forward(to order: Int) -> Bool {
        if let last, last != order { wasForward = order > last }
        last = order
        return wasForward
    }
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
