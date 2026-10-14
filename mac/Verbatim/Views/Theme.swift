import SwiftUI
import AppKit

/// Warm paper palette from the Listening Desk prototype.
enum Ink {
    static let paper = Color(hex: 0xFAF7F2)
    static let side = Color(hex: 0xEFEAE1)
    static let bar = Color(hex: 0xF3EFE8)
    static let card = Color.white
    static let ink = Color(hex: 0x2A2622)
    static let mute = Color(hex: 0x857D70)
    static let dim = Color(hex: 0x6B6459)
    static let iris = Color(hex: 0x6F5AF0)
    static let irisDeep = Color(hex: 0x5742D0)
    static let irisTint = Color(hex: 0xEEE9FF)
    static let coral = Color(hex: 0xFF7C5C)
    static let coralTint = Color(hex: 0xFFF0EA)
    static let lime = Color(hex: 0xB7E26A)
    static let limeDeep = Color(hex: 0x1F3A0A)
    static let limeTint = Color(hex: 0xF1F8E0)
    static let hairline = Color.black.opacity(0.07)
}

/// Five named springs (Verbatim Motion System).
enum Motion {
    static let touch = Animation.spring(duration: 0.15, bounce: 0)
    static let settle = Animation.spring(duration: 0.35, bounce: 0.05)
    static let snap = Animation.spring(duration: 0.3, bounce: 0.25)
    static let bounce = Animation.spring(duration: 0.5, bounce: 0.4)
    static let hero = Animation.spring(duration: 0.7, bounce: 0.35)
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
    var tilt: Double = 4
    var lift: Double = 2
    var radius: Double = 12
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
        content()
            .overlay {
                if let h = hover, !reduceMotion {
                    RadialGradient(colors: [Color.white.opacity(0.32), .clear], center: UnitPoint(x: h.x / max(size.width, 1), y: h.y / max(size.height, 1)), startRadius: 0, endRadius: 220)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(RadialGradient(colors: [Ink.iris.opacity(0.28), .clear], center: UnitPoint(x: h.x / max(size.width, 1), y: h.y / max(size.height, 1)), startRadius: 0, endRadius: 200), lineWidth: 1.5)
                }
            }
            .rotation3DEffect(.degrees(on ? -ny * tilt : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(on ? nx * tilt : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .offset(y: on ? -lift : 0)
            .scaleEffect(down ? 0.97 : 1)
            .animation(down ? .easeOut(duration: 0.08) : Motion.bounce, value: down)
            .animation(hover == nil ? Motion.bounce : Motion.touch, value: hoverKey)
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
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !down { down = true } }
                        .onEnded { v in
                            down = false
                            let inside = CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4).contains(v.location)
                            if inside { action() }
                        })
            }
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
    @State private var hover: CGPoint? = nil
    private var hoverKey: String { hover.map { "\(Int($0.x)),\(Int($0.y))" } ?? "" }
    @State private var size: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let nx = hover.map { ($0.x / max(size.width, 1)) - 0.5 } ?? 0
        let ny = hover.map { ($0.y / max(size.height, 1)) - 0.5 } ?? 0
        let on = hover != nil && !reduceMotion
        return content
            .overlay {
                if let h = hover, !reduceMotion {
                    RadialGradient(colors: [Color.white.opacity(0.22), .clear], center: UnitPoint(x: h.x / max(size.width, 1), y: h.y / max(size.height, 1)), startRadius: 0, endRadius: 260)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .rotation3DEffect(.degrees(on ? -ny * tilt : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(on ? nx * tilt : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .offset(y: on ? -lift : 0)
            .animation(hover == nil ? Motion.bounce : Motion.touch, value: hoverKey)
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
    func tiltCard(tilt: Double = 4, lift: Double = 2, radius: Double = 12) -> some View {
        modifier(TiltCard(tilt: tilt, lift: lift, radius: radius))
    }
    func tapArea(_ action: @escaping () -> Void) -> some View { modifier(TapArea(action: action)) }
    /// Press feedback for real Buttons (scale on isPressed through a button style).
    func pressable() -> some View { buttonStyle(PressStyle()) }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : Motion.bounce, value: configuration.isPressed)
    }
}

/// Rounded label pill (iris / lime / coral) used for dictionary words and tags.
struct Pill: View {
    var text: String
    var tint: Color = Ink.irisTint
    var fg: Color = Color(hex: 0x3B2FB0)
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(tint, in: Capsule())
            .foregroundStyle(fg)
    }
}

/// Entrance stagger: each element rises 6 pt and fades in, 35 ms after the previous one (first at 0).
struct StaggerIn: ViewModifier {
    var index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 6)
            .onAppear { withAnimation(Motion.bounce.delay(Double(index) * 0.035)) { shown = true } }
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
