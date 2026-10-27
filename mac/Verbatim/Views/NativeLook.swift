import SwiftUI
import AppKit

// brand: native file
//
// The Native look on the Mac (mockup "Two looks", sections 03 to 06): a stock macOS 26 app whose only brand element is
// the persimmon accent (`Ink.nativeAccent`). Shared kit components (WebStyle.swift, SettingsKit.swift) read
// `@Environment(\.look)` and draw these pieces instead of their Verbose style ones. Two things can't read the
// environment, so they read the stored look directly (`NativeSwap`): the Ink tokens, whose neutral surfaces and text
// turn into system colors (Tokens.swift asks `NativeSwap.color(light:)`), and the serif and mono type roles, which
// turn into SF Pro. `LookRebuild` redraws a window's content when the look changes, so all of it switches at once.
// The Ribbon, the notch, the floating button, and the menu bar icon keep one look (`SurfaceFont`, fixed colors).

// MARK: - The stored look, for tokens and type

enum NativeSwap {
    /// True when this Mac uses the Native look. Read on every token and font lookup, so it's cached, and read again
    /// whenever defaults change (posted on the writing thread before SwiftUI's next render, so a switch is never stale).
    /// Defaults can change on any thread (the iCloud container lookup, the model engine), so the cache is locked.
    static var on: Bool {
        _ = watcher
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let v = read()
        cache = v
        return v
    }
    private static let lock = NSLock()
    private static var cache: Bool?
    private static func read() -> Bool { UserDefaults.standard.string(forKey: AppLook.key) == AppLook.native.rawValue }
    private static let watcher: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            let v = read()
            lock.lock(); cache = v; lock.unlock()
        }

    /// The system color standing in for a Verbose token (by the token's light value) under Native, for the appearance
    /// AppKit is resolving (`dark`, `increased` contrast), not whichever appearance happens to be drawing. Nil in
    /// Verbose style and for brand fills, which keep their color. Each (token, appearance, contrast) resolves once:
    /// resolving a system color allocates, and every Ink color in every view asks on every render.
    static func color(light: UInt32, dark: Bool, increased: Bool) -> NSColor? {
        guard on, let role = NativeRoles.role(light: light) else { return nil }
        let key = NativeRoles.cacheKey(light: light, dark: dark, increased: increased)
        _ = colorWatchers
        colorLock.lock()
        if let hit = colors[key] { colorLock.unlock(); return hit }
        colorLock.unlock()
        let out = role.resolved(dark: dark, increased: increased)
        colorLock.lock(); colors[key] = out; colorLock.unlock()
        return out
    }

    /// `color(light:dark:increased:)` for the appearance drawing now (the self-test's checks).
    static func color(light: UInt32) -> NSColor? {
        color(light: light, dark: NSAppearance.currentDrawing().isDark, increased: ContrastSetting.increased)
    }

    private static let colorLock = NSLock()
    private static var colors: [UInt64: NSColor] = [:]
    /// System colors can change under us (accessibility display options, the system's own palette): start over then.
    private static let colorWatchers: [NSObjectProtocol] = [
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: nil) { _ in flush() },
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil) { _ in flush() },
    ]
    static func flush() { colorLock.lock(); colors.removeAll(); colorLock.unlock() }
    /// How many resolved colors are cached (the self-test checks a repeat lookup doesn't add one).
    static var cachedColorCount: Int { colorLock.lock(); defer { colorLock.unlock() }; return colors.count }

    /// The serif type role in Native: SF Pro, a step smaller and semibold for titles (serif display sizes run large).
    static func serif(_ size: CGFloat, weight: Font.Weight) -> Font {
        guard size >= 18 else { return .system(size: max(11, size - 2), weight: weight) }
        return .system(size: max(13, (size * 0.7).rounded()), weight: weight == .regular ? .semibold : weight)
    }
}

/// Increase Contrast, read once and again only when it changes (it was asked on every color resolve).
enum ContrastSetting {
    static var increased: Bool {
        _ = watcher
        lock.lock(); defer { lock.unlock() }
        return value
    }
    private static let lock = NSLock()
    private static var value = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private static let watcher: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil) { _ in
            let v = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            lock.lock(); value = v; lock.unlock()
        }
}

extension NativeRole {
    /// The role's color. The window is Premium Native's warm off-white (black in dark, DESIGN.md §13.2), not the
    /// system's window gray; the rest are system colors.
    var nsColor: NSColor {
        switch self {
        case .window: return PremiumInk.windowNS
        case .content: return .controlBackgroundColor
        case .label: return .labelColor
        case .secondaryLabel: return .secondaryLabelColor
        case .tertiaryLabel: return .tertiaryLabelColor
        case .accentText: return NSColor(Ink.nativeAccent)
        case .selection: return .unemphasizedSelectedContentBackgroundColor
        case .fill: return .quaternaryLabelColor
        }
    }
}

extension NativeRole {
    /// The role's color as drawn in light or dark, with or without Increase Contrast, as a plain sRGB color.
    func resolved(dark: Bool, increased: Bool) -> NSColor {
        let name: NSAppearance.Name = increased ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua)
        guard let appearance = NSAppearance(named: name) ?? NSAppearance(named: dark ? .darkAqua : .aqua) else { return nsColor }
        return nsColor.resolved(in: appearance)
    }
}

extension NSColor {
    /// This color as drawn in `appearance` (system and dynamic colors resolve to plain sRGB values).
    func resolved(in appearance: NSAppearance) -> NSColor {
        var out = self
        appearance.performAsCurrentDrawingAppearance { out = self.usingColorSpace(.sRGB) ?? self }
        return out
    }
}

/// System colors for code that draws Native on purpose (the Native layouts and the kit's Native branches).
enum NativeInk {
    /// The window: Premium Native's warm off-white, black in dark (`PremiumInk`).
    static let window = PremiumInk.window
    static let content = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let accent = Ink.nativeAccent
    /// Errors keep their word and a symbol, in the system red.
    static let danger = Color(nsColor: .systemRed)
    /// A group box: a faint wash on the window, with a faint edge.
    static let box = Color.primary.opacity(0.045)
    static let boxEdge = Color.primary.opacity(0.07)
    /// A grouped Form's section, as System Settings draws it: white on the window gray in light, a lighter wash in dark.
    static let group = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.controlBackgroundColor.resolved(in: a)
    })
    /// Hover and press washes for plain rows and bordered buttons.
    static let hover = Color.primary.opacity(0.05)
    static let bordered = Color.primary.opacity(0.08)
    static let borderedHover = Color.primary.opacity(0.12)
}

extension Ink {
    /// Text and marks on a color panel: fixed ink in Verbose style (panels keep their fill in both appearances); the
    /// label color in Native, where panels become plain boxes.
    static let panelInk = Color(nsColor: NSColor(name: nil) { a in
        NativeSwap.on ? NSColor.labelColor.resolved(in: a) : NSColor(hex: Ink.inkHex)
    })
}

/// The serif and mono roles for surfaces that keep one look (the Ribbon, the notch, the floating button), so the
/// Native look's SF Pro never reaches them. The same fonts `Ink.serif` and `Ink.mono` draw in Verbose style.
enum SurfaceFont {
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced).monospacedDigit() }
}

// MARK: - Switching

/// Rebuilds the content when the look changes, so every token and font re-resolves, and shows the look-switch card
/// over it (LookSwitch.swift): a pick shows the card, the rebuild runs behind it with no animation of its own (two whole
/// windows crossfading was most of the switch's cost), and the card's fade out crossfades into the result. Apply inside
/// `lookRoot()`, around a window's content but outside its sheets, so a sheet that's open (the welcome tour) stays open.
struct LookRebuild: ViewModifier {
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        content
            .id(look)
            .overlay { LookSwitchLayer() }
    }
}

extension View {
    func lookRebuild() -> some View { modifier(LookRebuild()) }
    /// The accent for switches, buttons, and selection: brand sage in Verbose style, persimmon in Native.
    func lookTint(_ look: AppLook) -> some View { tint(look == .native ? Ink.nativeAccent : Ink.switchOn) }
    /// The soft scroll edge effect on these edges (macOS 26), so text that scrolls under the toolbar's glass or beside
    /// the player bar fades instead of colliding with it (DESIGN.md §13.5; review M-05, M-29). Earlier systems
    /// draw no glass there, so nothing changes.
    @ViewBuilder func softScrollEdges(_ edges: Edge.Set) -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: edges) } else { self }
    }
}

// MARK: - Boxes

extension View {
    /// A Native group box: the faint wash and edge macOS draws for `GroupBox`, in place of a color panel.
    func nativeBox(radius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(8, radius), style: .continuous)
        return background(NativeInk.box, in: shape)
            .overlay(shape.strokeBorder(NativeInk.boxEdge, lineWidth: 1).allowsHitTesting(false))
    }

    /// A Native grouped-form section (Settings cards).
    func nativeGroup(radius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return clipShape(shape)
            .background(NativeInk.group, in: shape)
            .overlay(shape.strokeBorder(NativeInk.boxEdge, lineWidth: 1).allowsHitTesting(false))
    }
}

// MARK: - Buttons and chips

/// Button sizes in Native, as macOS draws push buttons.
enum NativeButtonSize {
    case mini, regular, large
    var height: CGFloat { switch self { case .mini: return 22; case .regular: return 28; case .large: return 34 } }
    var font: CGFloat { switch self { case .mini: return 12; case .regular: return 13; case .large: return 14 } }
    var padding: CGFloat { switch self { case .mini: return 10; case .regular: return 14; case .large: return 18 } }
}

/// The face of a Native button: `.borderedProminent` (the accent, white text in light and black in dark, where white on
/// #FF6B47 measures 2.8:1) or `.bordered` (a gray wash), title case.
/// Used where the kit keeps its own click handling (PillButton, cards that show a button).
struct NativeButtonFace: View {
    var title: String
    var prominent: Bool
    var size: NativeButtonSize = .regular
    var fullWidth = false
    var hover = false
    var pressed = false
    var titleCase = true

    var body: some View {
        Text(titleCase ? NativeText.titleCase(title) : title)
            .font(.system(size: size.font, weight: prominent ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(prominent ? PremiumInk.onAccent : Color.primary)
            .padding(.horizontal, size.padding)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: size.height)
            .background {
                if prominent {
                    Capsule().fill(Ink.nativeAccent).brightness(pressed ? -0.08 : (hover ? 0.04 : 0))
                } else {
                    Capsule().fill(pressed ? NativeInk.borderedHover : (hover ? NativeInk.borderedHover : NativeInk.bordered))
                }
            }
            .fixedSize(horizontal: !fullWidth, vertical: true)
            .contentShape(Capsule())
    }
}

/// The Native face for a real Button's label (PillButtonStyle, Settings pills).
struct NativeButtonStyleFace: View {
    let configuration: ButtonStyleConfiguration
    var prominent: Bool
    var size: NativeButtonSize
    var tint: Color? = nil
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: size.font, weight: prominent ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(prominent ? PremiumInk.onAccent : (tint ?? Color.primary))
            .padding(.horizontal, size.padding)
            .frame(height: size.height)
            .background {
                if prominent {
                    Capsule().fill(Ink.nativeAccent).brightness(configuration.isPressed ? -0.08 : (hover ? 0.04 : 0))
                } else {
                    Capsule().fill(configuration.isPressed || hover ? NativeInk.borderedHover : NativeInk.bordered)
                }
            }
            .fixedSize()
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
            .onHover { hover = $0 }
    }
}

/// A Native filter chip: a capsule, the accent with white text when chosen, no color dots.
struct NativeChipFace: View {
    var title: String
    var count: Int? = nil
    var selected: Bool
    var small = false
    var hover = false
    /// Chosen kinds and tags stay neutral (a stronger wash and a check), so the accent marks only the selected filter.
    var neutral = false

    var body: some View {
        let accent = selected && !neutral
        HStack(spacing: 5) {
            if selected && neutral { Image(systemName: "checkmark").font(.system(size: small ? 9 : 10, weight: .bold)) }
            Text(title)
            if let count { Text("\(count)").monospacedDigit().opacity(0.7) }
        }
        .font(.system(size: small ? 11.5 : 12, weight: selected && neutral ? .semibold : .medium))
        .lineLimit(1)
        .foregroundStyle(accent ? PremiumInk.onAccent : Color.primary)
        .padding(.horizontal, small ? 9 : 11)
        .frame(height: small ? 22 : 26)
        .background(Capsule().fill(accent ? Ink.nativeAccent : (selected || hover ? NativeInk.borderedHover : NativeInk.bordered)))
        .contentShape(Capsule())
    }
}

// MARK: - Icons, fields, and empty states

/// A transcript's kind as a tinted SF Symbol (in place of the Verbose style's colored dot).
struct NativeKindIcon: View {
    var transcript: Transcript
    var size: CGFloat = 34

    var body: some View {
        Group {
            if transcript.kind == .idea {
                // Thoughts have no SF Symbol: the Thoughts icon, at the symbol's size.
                ArtIcon(art: .iconThought, size: max(14, size * 0.5), lineWidth: 1.4)
            } else {
                Image(systemName: Self.symbol(transcript)).font(.system(size: max(12, size * 0.44), weight: .regular))
            }
        }
        .foregroundStyle(Ink.nativeAccent)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func symbol(_ t: Transcript) -> String {
        NativeSymbols.kind(t.kind?.rawValue, link: LibrarySource.isLink(t), file: t.source == .file,
                           dictation: t.isDictation, speakers: t.speakers.count)
    }
}

/// A Native search field: a capsule with the magnifying glass.
struct NativeSearchField: View {
    @Binding var text: String
    var prompt: String
    var height: CGFloat = 28

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(NativeInk.bordered, in: Capsule())
    }
}

/// An empty screen in Native: `ContentUnavailableView` with the screen's icon, one sentence, and one action.
struct NativeEmptyState: View {
    var art: BrandArt
    var title: String
    var message: String
    var button: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label { Text(title) } icon: { IconGlyph(art: art, size: 34, color: Color.secondary) }
        } description: {
            Text(message)
        } actions: {
            if let button, let action {
                Button(NativeText.titleCase(button), action: action).buttonStyle(PremiumProminentButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - The look picker

/// A small live rendering of Home in one look, for the picker (Settings › General and the welcome tour). It follows
/// light and dark, and always draws its own look, whichever look is on (fixed brand colors for Verbose style, system
/// colors for Native), so the two can be compared.
struct LookThumbnail: View {
    var look: AppLook
    var width: CGFloat = 190
    @Environment(\.colorScheme) private var scheme

    private var height: CGFloat { (width * 0.6).rounded() }

    var body: some View {
        let u = width / 190   // drawn on a 190 × 114 grid
        Group {
            if look == .verbose { verbose(u) } else { native(u) }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7 * u, style: .continuous))
        .accessibilityHidden(true)
    }

    private func verbose(_ u: CGFloat) -> some View {
        let dark = scheme == .dark
        let ink = dark ? Ink.paperFixed : Ink.inkFixed
        let card = dark ? Ink.inkFixed : Ink.readerFixed
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(dark ? Ink.inkFixed : Ink.paperFixed)
            if dark { Rectangle().fill(Color.black.opacity(0.35)) }
            // Sidebar: the wordmark and a few rows.
            VStack(alignment: .leading, spacing: 5 * u) {
                Capsule().fill(Ink.persimmonFixed).frame(width: 18 * u, height: 3 * u)
                ForEach(0..<5, id: \.self) { i in Capsule().fill(ink.opacity(i == 0 ? 0.5 : 0.22)).frame(width: (i == 0 ? 20 : 16) * u, height: 2.5 * u) }
            }
            .padding(.leading, 8 * u).padding(.top, 10 * u)
            VStack(alignment: .leading, spacing: 4 * u) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Good afternoon, Tim.").font(SurfaceFont.serif(8.5 * u))
                    Text("What are we keeping?").font(SurfaceFont.serif(8.5 * u).italic())
                }
                .foregroundStyle(ink).lineLimit(1).fixedSize()
                HStack(alignment: .top, spacing: 4 * u) {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 3 * u).fill(Ink.persimmonFixed)
                        Circle().stroke(Ink.inkFixed, lineWidth: 1 * u).frame(width: 20 * u, height: 20 * u).offset(x: 4 * u, y: 8 * u)
                        Circle().stroke(Ink.inkFixed, lineWidth: 1 * u).frame(width: 12 * u, height: 12 * u).offset(x: 0, y: 12 * u)
                    }
                    .frame(width: 70 * u, height: 36 * u)
                    .overlay(RoundedRectangle(cornerRadius: 3 * u).stroke(Ink.inkFixed, lineWidth: 0.8 * u))
                    .clipped()
                    VStack(spacing: 3 * u) {
                        HStack(spacing: 3 * u) { tile(Ink.butterFixed, u); tile(Color(hex: Ink.sageHex), u) }
                        HStack(spacing: 3 * u) { tile(Color(hex: Ink.petalHex), u); tile(card, u, outlined: ink) }
                    }
                    .frame(width: 52 * u)
                }
                RoundedRectangle(cornerRadius: 3 * u).fill(card).frame(width: 126 * u, height: 12 * u)
                    .overlay(RoundedRectangle(cornerRadius: 3 * u).stroke(ink, lineWidth: 0.8 * u))
                HStack(spacing: 4 * u) {
                    Circle().fill(Color(hex: Ink.sageHex)).frame(width: 6 * u, height: 6 * u)
                    Capsule().fill(ink.opacity(0.4)).frame(width: 50 * u, height: 2.5 * u)
                }
            }
            .padding(.leading, 44 * u).padding(.top, 10 * u)
        }
    }

    private func tile(_ fill: Color, _ u: CGFloat, outlined: Color? = nil) -> some View {
        RoundedRectangle(cornerRadius: 2.5 * u).fill(fill).frame(height: 16.5 * u)
            .overlay { if let outlined { RoundedRectangle(cornerRadius: 2.5 * u).stroke(outlined, lineWidth: 0.8 * u) } }
    }

    private func native(_ u: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(NativeInk.content)
            // The floating sidebar.
            RoundedRectangle(cornerRadius: 5 * u, style: .continuous).fill(NativeInk.window)
                .frame(width: 34 * u, height: 102 * u).padding(6 * u)
            VStack(alignment: .leading, spacing: 5 * u) {
                ForEach(0..<6, id: \.self) { i in
                    HStack(spacing: 3 * u) {
                        Circle().fill(Ink.nativeAccent).frame(width: 3.5 * u, height: 3.5 * u)
                        Capsule().fill(Color.primary.opacity(0.25)).frame(width: 14 * u, height: 2.5 * u)
                    }
                }
            }
            .padding(.leading, 11 * u).padding(.top, 14 * u)
            VStack(alignment: .leading, spacing: 5 * u) {
                Text("Good afternoon, Tim").font(.system(size: 8.5 * u, weight: .bold)).foregroundStyle(.primary).lineLimit(1).fixedSize()
                HStack(alignment: .top, spacing: 4 * u) {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 4 * u).fill(Color.primary.opacity(0.06))
                        Circle().fill(Ink.persimmonFixed).frame(width: 10 * u, height: 10 * u).padding(5 * u)
                    }
                    .frame(width: 70 * u, height: 36 * u)
                    VStack(spacing: 3 * u) {
                        HStack(spacing: 3 * u) { nativeTile(u); nativeTile(u) }
                        HStack(spacing: 3 * u) { nativeTile(u); nativeTile(u) }
                    }
                    .frame(width: 52 * u)
                }
                RoundedRectangle(cornerRadius: 4 * u).fill(Color.primary.opacity(0.06)).frame(width: 126 * u, height: 12 * u)
                VStack(alignment: .leading, spacing: 4 * u) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 4 * u) {
                            Circle().fill(Ink.nativeAccent).frame(width: 4 * u, height: 4 * u)
                            Capsule().fill(Color.primary.opacity(0.3)).frame(width: 56 * u, height: 2.5 * u)
                        }
                    }
                }
            }
            .padding(.leading, 48 * u).padding(.top, 10 * u)
        }
    }

    private func nativeTile(_ u: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3 * u).fill(Color.primary.opacity(0.06)).frame(height: 16.5 * u)
            .overlay(alignment: .topLeading) { Circle().fill(Ink.nativeAccent).frame(width: 4 * u, height: 4 * u).padding(3 * u) }
    }
}

/// The two looks side by side, each a button with its thumbnail and name. Choosing one shows the switching card, and
/// every window rebuilds in the new look behind it (`LookRebuild`, LookSwitch.swift).
struct LookPicker: View {
    var thumbnail: CGFloat = 190
    var captions = true
    @AppStorage(AppLook.key, store: AppLook.store) private var raw = AppLook.verbose.rawValue
    @Environment(\.look) private var current

    private var chosen: AppLook { AppLook(rawValue: raw) ?? .verbose }

    var body: some View {
        HStack(alignment: .top, spacing: thumbnail >= 160 ? 18 : 12) {
            ForEach(AppLook.allCases) { l in choice(l) }
        }
        .onAppear { LookSwitch.prewarm() }   // the other look's type, before it's picked
    }

    static func caption(_ l: AppLook) -> String { l == .verbose ? "Paper, color, and line art" : "Like Apple's own apps" }

    private func choice(_ l: AppLook) -> some View {
        let on = chosen == l
        let radius = 7 * thumbnail / 190
        // The card shows, then the windows rebuild behind it (LookSwitch.swift).
        return Button { if raw != l.rawValue { LookSwitch.shared.pick(l) } } label: {
            VStack(spacing: 6) {
                LookThumbnail(look: l, width: thumbnail)
                    .background {
                        // The hard shadow under the chosen one (Verbose style).
                        if current == .verbose && on {
                            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.hard).offset(x: 3, y: 4)
                        }
                    }
                    .overlay { selection(on: on, radius: radius) }
                    .padding(.bottom, current == .verbose && on ? 3 : 0)
                VStack(spacing: 2) {
                    Text(l.label)
                        .font(current == .verbose ? Ink.serif(thumbnail >= 160 ? 17 : 14) : .system(size: thumbnail >= 160 ? 13 : 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(Ink.ink)
                    if captions {
                        Text(Self.caption(l)).font(.system(size: 11.5)).foregroundStyle(Ink.mute)
                    }
                }
                .lineLimit(1).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l.label)
        .accessibilityValue(Self.caption(l))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .uiTarget("look-\(l.rawValue)")
    }

    /// Verbose style: an ink outline with a hard shadow and a check. Native: a persimmon ring, as System Settings
    /// rings the chosen appearance.
    @ViewBuilder private func selection(on: Bool, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if current == .native {
            if on {
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous).strokeBorder(Ink.nativeAccent, lineWidth: 2.5).padding(-4)
            } else {
                shape.strokeBorder(NativeInk.separator, lineWidth: 1)
            }
        } else if on {
            shape.inset(by: -0.75).stroke(Ink.ink, lineWidth: 1.5)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Ink.ink, Ink.paper)
                        .background(Circle().fill(Ink.paper).padding(1))
                        .offset(x: 5, y: -5)
                }
        } else {
            shape.strokeBorder(Ink.hairline, lineWidth: 1)
        }
    }
}
