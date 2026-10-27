// brand: native file
import SwiftUI
import UIKit

// The Native look on iPhone (DESIGN.md §13; mockup "Verbose Native Redesign", October 27, 2026): drawn the way Apple
// draws its own apps since iOS 27.2, with the brand taken out of the chrome. System blue for everything you tap, system
// red only for recording (the record disc, the stop square, the recording playhead), system grouped backgrounds,
// SF Pro and SF Symbols, and no glows, gradient cards, tinted icon circles, or custom shadows. The kit in
// PhoneWebStyle.swift reads `@Environment(\.look)` and draws either look, so most screens switch without edits; Home,
// Library, the transcript, the recorder, Settings, and Appearance have Native layouts of their own.
//
// This file is Native look code: brand-check skips its SF Symbols and system colors (`// brand: native file`).

// MARK: - Tokens

/// The Native look's colors, named like the `Ink` tokens they stand in for. All system colors: they follow light and
/// dark, Increase Contrast, and the system's own tuning, so nothing here is a brand hue.
enum NativeInk {
    /// Lists and grouped screens (Home, Settings, Moments): the system grouped background.
    static let paper = Color(uiColor: .systemGroupedBackground)
    /// Plain lists and reading surfaces (the Library, a transcript, the recorder sheet).
    static let plain = Color(uiColor: .systemBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let raised = Color(uiColor: .tertiarySystemGroupedBackground)
    /// Chips, the search field, segmented tracks, and the sponsor row.
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let fillStrong = Color(uiColor: .secondarySystemFill)
    static let separator = Color(uiColor: .separator)
    static let label = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let tertiary = Color(uiColor: .tertiaryLabel)
    /// Bars and quiet marks (This week's days, the meter at rest).
    static let gray = Color(uiColor: .systemGray3)
    /// Tabs, links, selection, primary buttons, and list symbols: system blue, the default accent (#007AFF, #0A84FF in
    /// dark; #0040DD and #409CFF with Increase Contrast).
    static let accent = Color(uiColor: .systemBlue)
    /// Text and glyphs on the accent: white, as on Apple's own filled buttons.
    static let onAccent = Color.white
    /// Recording only: the record disc, the stop square, and the recording playhead. System red, flat.
    static let record = Color(uiColor: .systemRed)
    /// Switches stay green, as in Apple's own iPhone apps.
    static let toggle = Color(uiColor: .systemGreen)
    /// Destructive actions, drawn by the system's destructive role.
    static let danger = Color(uiColor: .systemRed)
    /// Settings › Keyboard's preview of the Native keyboard: Apple's gray backdrop, white keys (gray in dark), and the
    /// function key gray.
    static let keyboardBackdrop = Color(uiColor: .systemGray5)
    static let keyboardKey = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGray2 : .white })
    static let keyboardFunction = Color(uiColor: .systemGray3)
}

/// Find's highlight in Native: the system's yellow at a third, as Safari's and Notes' find draw it.
enum NativeFind {
    static let highlight = Color(uiColor: .systemYellow).opacity(0.35)
}

extension NativeRules.Square {
    /// The square's system color (Settings' rows, iPhone and Mac alike).
    var color: Color {
        switch self {
        case .blue: return Color(uiColor: .systemBlue)
        case .indigo: return Color(uiColor: .systemIndigo)
        case .purple: return Color(uiColor: .systemPurple)
        case .pink: return Color(uiColor: .systemPink)
        case .orange: return Color(uiColor: .systemOrange)
        case .yellow: return Color(uiColor: .systemYellow)
        case .green: return Color(uiColor: .systemGreen)
        case .mint: return Color(uiColor: .systemMint)
        case .teal: return Color(uiColor: .systemTeal)
        case .cyan: return Color(uiColor: .systemCyan)
        case .brown: return Color(uiColor: .systemBrown)
        case .gray: return Color(uiColor: .systemGray)
        }
    }
}

/// A color that follows the look: the Verbose style token, or its Native stand-in. Resolved from the environment, so a
/// view using it changes with the look without reading `\.look` itself.
struct LookStyle: ShapeStyle {
    var verbose: Color
    var native: Color
    func resolve(in environment: EnvironmentValues) -> Color { environment.look == .native ? native : verbose }
}

extension ShapeStyle where Self == LookStyle {
    static var lookInk: LookStyle { LookStyle(verbose: Ink.ink, native: NativeInk.label) }
    static var lookDim: LookStyle { LookStyle(verbose: Ink.dim, native: NativeInk.secondary) }
    static var lookMute: LookStyle { LookStyle(verbose: Ink.mute, native: NativeInk.secondary) }
    static var lookFaint: LookStyle { LookStyle(verbose: Ink.faint, native: NativeInk.tertiary) }
    static var lookAccentText: LookStyle { LookStyle(verbose: Ink.accentText, native: NativeInk.accent) }
    static var lookCard: LookStyle { LookStyle(verbose: Ink.card, native: NativeInk.card) }
    static var lookReader: LookStyle { LookStyle(verbose: Ink.reader, native: NativeInk.card) }
    static var lookHairline: LookStyle { LookStyle(verbose: Ink.hairline, native: NativeInk.separator) }
    static var lookPaper: LookStyle { LookStyle(verbose: Ink.paper, native: NativeInk.paper) }
    /// Text on a color panel: always ink in Verbose style (the panels stay bright in dark), the label color on Native's
    /// grouped card.
    static var lookOnPanel: LookStyle { LookStyle(verbose: Ink.inkFixed, native: NativeInk.label) }
    /// Recording's mark (a live dot): persimmon in Verbose style, system red in Native.
    static var lookRecord: LookStyle { LookStyle(verbose: Ink.persimmon, native: NativeInk.record) }   // verbose look
    /// A status mark that isn't a recording (the keyboard session's voice bars, a hint's dot): persimmon in Verbose
    /// style, the accent in Native.
    static var lookMark: LookStyle { LookStyle(verbose: Ink.persimmon, native: NativeInk.accent) }   // verbose look
    /// A soft wash behind a marked strip or a flashed row: the persimmon tint in Verbose style, the system fill in Native.
    static var lookWash: LookStyle { LookStyle(verbose: Ink.persimmonTint, native: NativeInk.fill) }   // verbose look
}

extension AppLook {
    var isNative: Bool { self == .native }
    /// The display serif in Verbose style; SF Pro in Native (semibold where the serif was regular).
    func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        isNative ? .system(size: size, weight: weight == .regular ? .semibold : weight) : Ink.serif(size, weight: weight)
    }
    /// Mono data in Verbose style; SF Pro with monospaced digits in Native.
    func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        isNative ? .system(size: size, weight: weight).monospacedDigit() : Ink.mono(size, weight: weight)
    }
}

/// Sets a serif or mono font that follows the look.
private struct LookFont: ViewModifier {
    var serif: Bool
    var size: CGFloat
    var weight: Font.Weight
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        content.font(serif ? look.serif(size, weight: weight) : look.mono(size, weight: weight))
    }
}

extension View {
    /// `Ink.serif` in Verbose style, SF Pro in Native.
    func lookSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> some View { modifier(LookFont(serif: true, size: size, weight: weight)) }
    /// `Ink.mono` in Verbose style, SF Pro with monospaced digits in Native.
    func lookMono(_ size: CGFloat, weight: Font.Weight = .regular) -> some View { modifier(LookFont(serif: false, size: size, weight: weight)) }
    /// A screen's background: paper, or the system grouped background in Native (`plain`: the system background, for
    /// plain lists and reading surfaces).
    func phonePage(plain: Bool = false) -> some View { modifier(PhonePage(plain: plain)) }
    /// At the app's root, inside `lookRoot()` and `limitMotionRoot()`: the tint (ink, or none in Native, so the
    /// system accent and green switches apply). A look
    /// switch has no animation of its own here: the switching card covers the rebuild and fades out over it
    /// (LookSwitch.swift). Animating every changed view in both looks at once was most of what made switching slow.
    func phoneLookRoot() -> some View { modifier(PhoneLookRoot()) }
}

private struct PhonePage: ViewModifier {
    var plain: Bool
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        if look.isNative {
            content.background((plain ? NativeInk.plain : NativeInk.paper).ignoresSafeArea())
        } else {
            content.background(Ink.paper.ignoresSafeArea())
        }
    }
}

private struct PhoneLookRoot: ViewModifier {
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        // Native sets no tint: the default accent is system blue, and switches keep the system's green, as in
        // Apple's own iPhone apps (a blue tint here would turn every switch blue).
        content.tint(look.isNative ? nil : Ink.ink)
    }
}

// MARK: - Grouped cards

enum NativeMetrics {
    /// Inset grouped corners: iOS 26's rounder cards, 10 pt before it.
    static var groupRadius: CGFloat {
        if #available(iOS 26, *) { return 26 }
        return 10
    }
    /// A hairline between rows.
    static let hairline: CGFloat = 0.5
}

/// A sentence-case section header over an inset grouped card.
struct NativeSectionHeader: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(NativeInk.secondary).textCase(nil)
            .padding(.horizontal, 16)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An inset grouped card with an optional header and footer, like a `List` section.
struct NativeGroup<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NativeMetrics.groupRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            if let header { NativeSectionHeader(header) }
            VStack(spacing: 0) { content() }
                .background(NativeInk.card, in: shape)
                .clipShape(shape)
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(NativeInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// The hairline between grouped rows, inset like the system's.
struct NativeDivider: View {
    var leading: CGFloat = 16
    var body: some View {
        Rectangle().fill(NativeInk.separator).frame(height: NativeMetrics.hairline).padding(.leading, leading)
            .accessibilityHidden(true)
    }
}

/// Rows highlight while pressed, as List rows do.
struct NativeRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color(uiColor: .systemGray4).opacity(configuration.isPressed ? 1 : 0))
    }
}

// MARK: - Symbols

/// SF Symbols for the Native look, in place of the brand line icons.
enum NativeSymbol {
    /// A recording's kind: meeting person.2, voice note waveform, journal book, link and podcast link.
    static func kind(_ t: Transcript) -> String {
        if t.isDictation { return "mic" }
        if LibrarySource.isLink(t) { return "link" }
        switch t.kind {
        case .meeting?, .interview?: return "person.2"
        case .journal?: return "book"
        case .idea?: return "lightbulb"
        case .podcast?: return "link"
        case .video?: return "play.rectangle"
        case .talk?: return "person.wave.2"
        default: break
        }
        switch t.source {
        case .file: return "doc"
        default: return "waveform"
        }
    }
}

/// A brand line icon in Verbose style, its SF Symbol in Native.
struct LookIcon: View {
    var art: BrandArt
    var symbol: String
    var size: CGFloat = 20
    var color: Color = Ink.ink
    /// The color in Native; the look's text color when nil.
    var nativeColor: Color? = nil
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative {
            Image(systemName: symbol)
                .font(.system(size: size * 0.8, weight: .regular))
                .foregroundStyle(nativeColor ?? NativeInk.label)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            IconGlyph(art: art, size: size, color: color)
        }
    }
}

// MARK: - Buttons

/// The primary pill: the dark pill in Verbose style; a tinted, filled capsule (`.borderedProminent`) in Native.
struct PhonePrimaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, large: large) }
    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        var large: Bool
        @Environment(\.look) private var look
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            if look.isNative {
                // White on system blue, as Apple's filled buttons draw it.
                configuration.label
                    .font(.system(size: large ? 17 : 15, weight: .semibold))
                    .foregroundStyle(NativeInk.onAccent)
                    .padding(.horizontal, large ? 20 : 14).frame(minHeight: large ? 50 : 34)
                    .background(NativeInk.accent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
                    .opacity(enabled ? 1 : 0.45)
                    .contentShape(Capsule())
            } else {
                // Verbose style: the dark pill (DESIGN.md §11.5), 36 pt when large, 28 pt (mini) otherwise.
                configuration.label
                    .font(.system(size: large ? 13.5 : 12, weight: .semibold))
                    .foregroundStyle(Ink.onInteractive)
                    .padding(.horizontal, large ? 18 : 12).frame(minHeight: large ? 36 : 28)
                    .background(Ink.interactive.opacity(configuration.isPressed ? 0.85 : 1), in: Capsule())
                    .opacity(enabled ? 1 : 0.45)
                    .contentShape(Capsule())
            }
        }
    }
}

/// The secondary pill: the line pill in Verbose style; the accent on the system's gray fill in Native, as `.bordered`
/// draws it ("Record another").
struct PhoneSecondaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, large: large) }
    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        var large: Bool
        @Environment(\.look) private var look
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            if look.isNative {
                configuration.label
                    .font(.system(size: large ? 17 : 15, weight: .medium))
                    .foregroundStyle(NativeInk.accent)
                    .padding(.horizontal, large ? 20 : 14).frame(minHeight: large ? 50 : 34)
                    .background(NativeInk.fill.opacity(configuration.isPressed ? 0.6 : 1), in: Capsule())
                    .opacity(enabled ? 1 : 0.45)
                    .contentShape(Capsule())
            } else {
                // Verbose style: the line pill (DESIGN.md §11.5), a 1.5 pt ink outline, 36 pt when large, 28 pt otherwise.
                configuration.label
                    .font(.system(size: large ? 13.5 : 12, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, large ? 18 : 12).frame(minHeight: large ? 36 : 28)
                    .background(Ink.ink.opacity(configuration.isPressed ? 0.08 : 0), in: Capsule())
                    .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5))
                    .opacity(enabled ? 1 : 0.45)
                    .contentShape(Capsule())
            }
        }
    }
}

extension ButtonStyle where Self == PhonePrimaryButtonStyle {
    static var phonePrimary: PhonePrimaryButtonStyle { PhonePrimaryButtonStyle() }
    static var phonePrimaryLarge: PhonePrimaryButtonStyle { PhonePrimaryButtonStyle(large: true) }
}
extension ButtonStyle where Self == PhoneSecondaryButtonStyle {
    static var phoneSecondary: PhoneSecondaryButtonStyle { PhoneSecondaryButtonStyle() }
    static var phoneSecondaryLarge: PhoneSecondaryButtonStyle { PhoneSecondaryButtonStyle(large: true) }
}

// MARK: - Look thumbnails and picker

/// A small live rendering of Home in one look (Settings › Appearance and onboarding's Pick a look). Drawn from the
/// look's own tokens, so each follows light and dark whatever look the screen is in.
struct LookThumbnail: View {
    var look: AppLook
    var width: CGFloat = 104

    var body: some View {
        let h = width * 1.9
        let r = width * 0.17
        ZStack(alignment: .topLeading) {
            (look.isNative ? NativeInk.paper : Ink.paper)
            Group {
                if look.isNative { native } else { verbose }
            }
            .padding(.horizontal, width * 0.08).padding(.top, width * 0.12)
            tabBar.frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, width * 0.06)
        }
        .frame(width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color.black, lineWidth: width * 0.035))
        .accessibilityHidden(true)
    }

    private var u: CGFloat { width / 104 }

    private var verbose: some View {
        VStack(alignment: .leading, spacing: 5 * u) {
            Capsule().fill(Ink.ink.opacity(0.4)).frame(width: 22 * u, height: 2 * u)
            VStack(alignment: .leading, spacing: 0) {
                Text("Good afternoon,").font(Ink.serif(8 * u))
                Text("What are we keeping?").font(Ink.serif(7 * u)).italic()
            }
            .foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.5)
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 3 * u).fill(Ink.panelRecord)
                ForEach(0..<3) { i in
                    Circle().stroke(Ink.inkFixed, lineWidth: 0.8 * u).frame(width: CGFloat(30 - i * 8) * u)
                        .offset(x: -4 * u, y: -3 * u)
                }
            }
            .frame(height: 34 * u)
            .overlay(RoundedRectangle(cornerRadius: 3 * u).strokeBorder(Ink.inkFixed, lineWidth: 0.8 * u))
            HStack(spacing: 4 * u) {
                RoundedRectangle(cornerRadius: 2 * u).fill(Ink.panelButter)
                RoundedRectangle(cornerRadius: 2 * u).fill(Ink.panelSage)
            }
            .frame(height: 14 * u)
            HStack(spacing: 4 * u) {
                RoundedRectangle(cornerRadius: 2 * u).fill(Ink.panelPetal)
                RoundedRectangle(cornerRadius: 2 * u).fill(Ink.card).overlay(RoundedRectangle(cornerRadius: 2 * u).strokeBorder(Ink.ink, lineWidth: 0.8 * u))
            }
            .frame(height: 14 * u)
            RoundedRectangle(cornerRadius: 2 * u).strokeBorder(Ink.ink, lineWidth: 0.8 * u).frame(height: 10 * u)
            ForEach(0..<2) { i in
                HStack(spacing: 4 * u) {
                    Circle().fill(i == 0 ? Ink.panelSage : Ink.panelRecord).frame(width: 5 * u)
                    Capsule().fill(Ink.ink.opacity(0.7)).frame(width: 38 * u, height: 2 * u)
                }
            }
        }
    }

    /// Native: the large title, an inset grouped card of blue-symbol rows, This week as one stat cell, and a recent
    /// recording, over the system grouped background.
    private var native: some View {
        VStack(alignment: .leading, spacing: 5 * u) {
            Text("Home").font(.system(size: 10 * u, weight: .bold)).foregroundStyle(NativeInk.label)
            VStack(alignment: .leading, spacing: 4 * u) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 4 * u) {
                        RoundedRectangle(cornerRadius: 1 * u).fill(NativeInk.accent).frame(width: 5 * u, height: 5 * u)
                        Capsule().fill(NativeInk.label).frame(width: 30 * u, height: 2 * u)
                    }
                }
            }
            .padding(5 * u)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NativeInk.card, in: RoundedRectangle(cornerRadius: 5 * u, style: .continuous))
            VStack(alignment: .leading, spacing: 3 * u) {
                HStack(alignment: .bottom) {
                    Text("1,414").font(.system(size: 9 * u, weight: .bold)).monospacedDigit().foregroundStyle(NativeInk.label)
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: 1.5 * u) {
                        ForEach([5, 7, 4, 1, 1], id: \.self) { h in
                            Capsule().fill(h == 4 ? NativeInk.accent : NativeInk.gray).frame(width: 2 * u, height: CGFloat(h) * u)
                        }
                    }
                }
                Capsule().fill(NativeInk.secondary).frame(width: 34 * u, height: 1.8 * u)
            }
            .padding(5 * u)
            .background(NativeInk.card, in: RoundedRectangle(cornerRadius: 5 * u, style: .continuous))
            VStack(alignment: .leading, spacing: 2.5 * u) {
                Capsule().fill(NativeInk.label).frame(width: 46 * u, height: 2.5 * u)
                Capsule().fill(NativeInk.secondary).frame(width: 60 * u, height: 1.8 * u)
            }
            .padding(5 * u)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NativeInk.card, in: RoundedRectangle(cornerRadius: 5 * u, style: .continuous))
        }
    }

    /// The tab bar; in Native, the bottom accessory above it with the red record disc.
    private var tabBar: some View {
        VStack(spacing: 3 * u) {
            if look.isNative {
                HStack(spacing: 4 * u) {
                    Circle().fill(NativeInk.record).frame(width: 7 * u, height: 7 * u)
                    Capsule().fill(NativeInk.label).frame(width: 20 * u, height: 2 * u)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5 * u).padding(.vertical, 3.5 * u)
                .background(NativeInk.card, in: Capsule())
            }
            tabCapsule
        }
        .padding(.horizontal, 8 * u)
    }

    private var tabCapsule: some View {
        HStack(spacing: 0) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1.5 * u)
                    .fill(i == 0 ? (look.isNative ? NativeInk.accent : Ink.persimmon) : (look.isNative ? NativeInk.gray : Ink.ink.opacity(0.35)))   // verbose look
                    .frame(width: 7 * u, height: 7 * u)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 5 * u)
        .background((look.isNative ? NativeInk.card : Ink.card), in: Capsule())
    }
}

/// The two looks side by side, each one button with its name, a line under it, and its state for VoiceOver ("Native,
/// selected"). In Native, radio circles under the thumbnails (Display & Brightness); in Verbose style, the selected
/// thumbnail gets the ink outline, the hard shadow, and a check.
struct LookPicker: View {
    @Binding var selection: AppLook
    var thumbWidth: CGFloat = 104
    @Environment(\.look) private var look

    static func subtitle(_ l: AppLook) -> String { l == .native ? "Like Apple's own apps" : "Paper, color, and line art" }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(AppLook.allCases) { l in
                Button { if selection != l { selection = l } } label: { option(l) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(l.label)
                    .accessibilityValue(Self.subtitle(l))
                    .accessibilityAddTraits(selection == l ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { LookSwitch.prewarm() }   // the other look's type, before it's picked
    }

    @ViewBuilder private func option(_ l: AppLook) -> some View {
        let on = selection == l
        VStack(spacing: 6) {
            LookThumbnail(look: l, width: thumbWidth)
                .padding(look.isNative ? 0 : 6)
                .background { if !look.isNative, on { RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Ink.card) } }
                .overlay { if !look.isNative, on { RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5) } }
                .background { if !look.isNative, on { RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Ink.hard).offset(x: 3, y: 4) } }
                .overlay(alignment: .topTrailing) {
                    if !look.isNative, on {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.paper)
                            .frame(width: 20, height: 20).background(Ink.ink, in: Circle())
                            .offset(x: 6, y: -6)
                    }
                }
            Text(l.label)
                .font(look.isNative ? .system(size: 16, weight: .semibold) : Ink.serif(18))
                .foregroundStyle(look.isNative ? NativeInk.label : Ink.ink)
            Text(Self.subtitle(l)).font(.system(size: 12.5))
                .foregroundStyle(look.isNative ? NativeInk.secondary : Ink.mute)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if look.isNative {
                ZStack {
                    if on {
                        Circle().fill(NativeInk.accent)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(NativeInk.onAccent)
                    } else {
                        Circle().strokeBorder(NativeInk.gray, lineWidth: 1.5)
                    }
                }
                .frame(width: 24, height: 24)
                .padding(.top, 4)
            }
        }
        .frame(width: thumbWidth + 30)
        .contentShape(Rectangle())
    }
}
