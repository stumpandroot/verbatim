import SwiftUI
import AppKit

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
    static let danger = Color(nsColor: .systemRed)
    /// Always-ink and always-reader-white, for surfaces that stay dark or light in both modes (HUD pill, toasts,
    /// text on brand color fills).
    static let inkFixed = Color(nsColor: NSColor(hex: inkHex))
    static let readerFixed = Color(nsColor: NSColor(hex: readerHex))

    /// Reliable primary controls: ink fill with a reader-white label (cream with an ink label in dark).
    static let interactive = dyn(inkHex, 0xE9E3D6)
    static let onInteractive = dyn(readerHex, 0x18241F)

    // Structure
    static let hairline = Color(nsColor: NSColor(name: nil) { a in
        let hc = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return a.isDark ? NSColor(hex: 0xF5F0E6).withAlphaComponent(hc ? 0.3 : 0.12) : NSColor(hex: inkHex).withAlphaComponent(hc ? 0.4 : 0.14)
    })
    static let outlineStrong = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0xF5F0E6).withAlphaComponent(0.36) : NSColor(hex: inkHex).withAlphaComponent(0.36)
    })
    static let track = dyn(0xE8E2D6, 0x2A3A33)                  // segmented tracks, progress rails
    static let wash = dyn(0xEFE9DD, 0x22312A)                   // selected rows on paper
    static let notes = dyn(0xF1EBDF, 0x1C2A24)                  // notes panel
    /// Saved passage: butter behind ink text, readable in both modes.
    static let saved = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0xD4AB55).withAlphaComponent(0.26) : NSColor(hex: butterHex).withAlphaComponent(0.5)
    })
    /// The playing passage: a quiet sage wash (distinct from saved butter and search persimmon).
    static let playing = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0x93A87C).withAlphaComponent(0.2) : NSColor(hex: sageHex).withAlphaComponent(0.32)
    })
    /// Search matches: persimmon tint.
    static let match = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0xF27A57).withAlphaComponent(0.3) : NSColor(hex: persimmonHex).withAlphaComponent(0.24)
    })
    /// Hover and selected-row tint (accentSubtle).
    static let accentSubtle = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0xF27A57).withAlphaComponent(0.14) : NSColor(hex: persimmonHex).withAlphaComponent(0.11)
    })
    static let glassTint = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor.white.withAlphaComponent(0.03) : NSColor(hex: paperHex).withAlphaComponent(0.35)
    })
    /// The selected sidebar row: a reader-white sheet in light, a soft raised tint in dark.
    static let selectedPill = Color(nsColor: NSColor(name: nil) { a in a.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor(hex: readerHex).withAlphaComponent(0.92) })
    static let selectedPillEdge = Color(nsColor: NSColor(name: nil) { a in a.isDark ? NSColor.white.withAlphaComponent(0.1) : NSColor(hex: inkHex).withAlphaComponent(0.1) })

    // Legacy names, mapped onto the brand (kept so existing screens compile and move together).
    static let iris = interactive
    static let irisDeep = interactive
    static let irisTint = accentSubtle
    static let coral = persimmon
    static let coralTint = persimmonTint
    static let lime = butter
    static let limeDeep = ink
    static let limeTint = butterTint
    static let limeText = sageText
    static let sideTint = Color.clear

    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.isDark ? NSColor(hex: dark) : NSColor(hex: light) })
    }
    /// Like `dyn`, with stronger values when Increase Contrast is on.
    static func dynC(_ light: UInt32, _ dark: UInt32, _ hcLight: UInt32, _ hcDark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let hc = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            return a.isDark ? NSColor(hex: hc ? hcDark : dark) : NSColor(hex: hc ? hcLight : light)
        })
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]).map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0) } ?? false }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
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

/// Small uppercase monospaced label with tracking: "01 / RECENT". Sparse use.
struct Overline: View {
    var text: String
    var color: Color = Ink.mute
    var body: some View {
        Text(text.uppercased()).font(Ink.mono(10.5, weight: .medium)).tracking(1.1).foregroundStyle(color).lineLimit(1)
    }
}

/// A quiet rounded hover background for utility icons and small controls.
struct HoverChip: ViewModifier {
    var radius: CGFloat = 7
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.ink.opacity(hover ? 0.07 : 0)))
            .onHover { hover = $0 }
            .animation(Motion.touch, value: hover)
    }
}
extension View { func hoverChip(radius: CGFloat = 7) -> some View { modifier(HoverChip(radius: radius)) } }

/// Motion (BRAND_GUIDE §10): quick ease-outs, no springy bounce in productivity controls.
/// `snap`, `bounce`, and `hero` remain as names but no longer overshoot.
enum Motion {
    static let touch = Animation.easeOut(duration: 0.16)
    static let settle = Animation.easeOut(duration: 0.22)
    /// Screen changes: short and flat (120–180 ms, minimal movement).
    static let nav = Animation.easeOut(duration: 0.18)
    static let snap = Animation.easeOut(duration: 0.2)
    static let bounce = Animation.easeOut(duration: 0.2)
    static let hero = Animation.easeOut(duration: 0.3)
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

/// A clickable card: pointer spotlight, 3D tilt, press squash, and the click itself.
/// The visuals tilt underneath; an untransformed layer on top takes the pointer, so hit-testing is never
/// subject to the 3D transform or to a competing Button gesture (both lost clicks on macOS 26).
struct CardButton<Content: View>: View {
    var tilt: Double = 1.5
    var lift: Double = 1
    var radius: Double = 12
    /// When set, the card can be dragged (to a project, to Finder as text). Click uses a tap gesture then,
    /// because a zero-distance drag gesture would swallow the system drag.
    var dragPayload: (() -> String)? = nil
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hover: CGPoint? = nil
    @State private var down = false
    @State private var size: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hoverKey: String { hover.map { "\(Int($0.x)),\(Int($0.y))" } ?? "" }

    var body: some View {
        let nx = hover.map { ($0.x / max(size.width, 1)) - 0.5 } ?? 0
        let ny = hover.map { ($0.y / max(size.height, 1)) - 0.5 } ?? 0
        let on = hover != nil && !reduceMotion
        // Brand: hover is a 1 pt rise at most, press a slight compression. No tilt, no spotlight.
        let _ = (nx, ny)
        content()
            .offset(y: on ? -min(lift, 1) : 0)
            .scaleEffect(down ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: down)
            .animation(Motion.touch, value: hover == nil)
            .allowsHitTesting(false)
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } })
            .overlay {
                // The hit layer: flat, on top, and the only thing that receives the pointer.
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.001))
                    .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = p
                        case .ended: hover = nil; down = false
                        }
                    }
                    .modifier(CardHit(dragPayload: dragPayload, size: size, down: $down, action: action))
            }
    }
}

private struct CardHit: ViewModifier {
    var dragPayload: (() -> String)?
    var size: CGSize
    @Binding var down: Bool
    var action: () -> Void
    func body(content: Content) -> some View {
        if let payload = dragPayload {
            content
                .onTapGesture { action() }
                .onDrag { NSItemProvider(object: payload() as NSString) }
        } else {
            content.gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true } }
                .onEnded { v in
                    down = false
                    if CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4).contains(v.location) { action() }
                })
        }
    }
}

/// What a dragged transcript (or a selection of them) carries: a prefixed list of IDs.
enum TranscriptDrag {
    static let prefix = "verbatim-transcripts:"
    static func payload(_ ids: [UUID]) -> String { prefix + ids.map(\.uuidString).joined(separator: ",") }
    static func ids(from s: String) -> [UUID] {
        guard s.hasPrefix(prefix) else { return [] }
        return s.dropFirst(prefix.count).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }
}

/// Non-tilting version for sidebar rows and chips: hover tint and a direct click gesture.
struct TapArea: ViewModifier {
    var action: () -> Void
    @State private var size: CGSize = .zero
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } })
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                if CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4).contains(v.location) { action() }
            })
    }
}

/// Decorative tilt for non-clickable surfaces (the welcome card, the dock frame). Pointer passes through to children.
struct TiltCard: ViewModifier {
    var tilt: Double = 4
    var lift: Double = 2
    var radius: Double = 12
    /// Off for cards that hold their own controls: on macOS 26 a 3D-rotated ancestor loses clicks for its children,
    /// so those cards keep the spotlight and lift and skip the rotation. CardButton tilts safely on its own.
    var rotates: Bool = true
    @State private var hover: CGPoint? = nil
    private var hoverKey: String { hover.map { "\(Int($0.x)),\(Int($0.y))" } ?? "" }
    @State private var size: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let nx = hover.map { ($0.x / max(size.width, 1)) - 0.5 } ?? 0
        let ny = hover.map { ($0.y / max(size.height, 1)) - 0.5 } ?? 0
        let on = hover != nil && !reduceMotion
        // Brand: no tilt or spotlight; at most a 1 pt rise.
        let _ = (nx, ny)
        return content
            .offset(y: on ? -min(lift, 1) : 0)
            .animation(Motion.touch, value: hover == nil)
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p
                case .ended: hover = nil
                }
            }
    }
}

extension View {
    func tiltCard(tilt: Double = 4, lift: Double = 2, radius: Double = 12, rotates: Bool = true) -> some View {
        modifier(TiltCard(tilt: tilt, lift: lift, radius: radius, rotates: rotates))
    }
    func tapArea(_ action: @escaping () -> Void) -> some View { modifier(TapArea(action: action)) }
    /// Press feedback for real Buttons (scale on isPressed through a button style).
    func pressable() -> some View { buttonStyle(PressStyle()) }
}

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? max(scale, 0.97) : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.06 : 0.14), value: configuration.isPressed)
    }
}

/// Rounded label pill used for dictionary words and tags: butter tint, ink text.
struct Pill: View {
    var text: String
    var tint: Color = Ink.butterTint
    var fg: Color = Ink.ink
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(tint, in: Capsule())
            .foregroundStyle(fg)
    }
}

/// Entrance stagger: each element rises 6 pt and fades in, 35 ms after the previous one (first at 0).
struct StaggerIn: ViewModifier {
    var index: Int          // negative = no entrance animation
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(shown || index < 0 ? 1 : 0)
            .offset(y: shown || reduce || index < 0 ? 0 : 4)
            .onAppear { if index >= 0 { withAnimation(Motion.settle.delay(Double(index) * 0.03)) { shown = true } } }
    }
}
extension View { func staggerIn(_ index: Int) -> some View { modifier(StaggerIn(index: index)) } }

/// Short system sounds for the two moments that earn one: record start and transcript done.
enum Sounds {
    static var enabled = true
    static func play(_ name: String) {
        guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
    static func start() { play("Pop") }
    static func done() { play("Tink") }
}
