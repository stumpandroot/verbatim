import SwiftUI
import AppKit

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

/// Pointer-driven card motion, shared by every card in the app family.
/// - Tilt: the side under the pointer dips away, as if the pointer were resting on it (a few degrees at most).
/// - Lift: the card rises 2 pt and its shadow deepens, shifted away from the pointer.
/// - Edge light: a thin rim, brightest at the point nearest the pointer, over a hairline that firms on hover.
/// - Press: the card presses in (scale 0.98, a little more tilt) fast, and springs back over 300 ms.
/// Visual only. Callers keep hit-testing on a flat, untransformed layer, because a 3D-rotated view loses
/// clicks on macOS 26. Reduce Motion keeps the edge light and shadow and drops tilt, lift, and scale.
struct CardMotion: ViewModifier {
    var hover: CGPoint?
    var size: CGSize
    var pressed: Bool
    var radius: CGFloat
    var tilt: Double = 3
    var lift: Double = 2
    /// Rows that sit on paper use a quieter shadow than cards that float.
    var shadow: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let w = max(size.width, 1), h = max(size.height, 1)
        let nx = hover.map { min(max($0.x / w, 0), 1) - 0.5 } ?? 0     // -0.5 … 0.5
        let ny = hover.map { min(max($0.y / h, 0), 1) - 0.5 } ?? 0
        let on = hover != nil
        let move = !reduceMotion
        // Wide rows tilt less: the same angle moves a long edge much farther.
        let aspect = min(1, 2.2 * h / w + 0.25)
        let strength = min(1, 2 * (nx * nx + ny * ny).squareRoot())
        let angle = move && on ? (tilt + (pressed ? 1 : 0)) * strength * aspect : 0
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let light = UnitPoint(x: nx + 0.5, y: ny + 0.5)
        let rimReach = max(w, h) * 0.55

        return content
            // Sheen: a soft glow on the surface under the pointer.
            .overlay {
                shape.fill(RadialGradient(colors: [Color.white.opacity(scheme == .dark ? 0.07 : 0.16), .clear],
                                          center: light, startRadius: 0, endRadius: rimReach))
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // Edge: the hairline firms up, and a light rim travels with the pointer.
            .overlay {
                shape.strokeBorder(Ink.outlineStrong.opacity(on ? 0.45 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(RadialGradient(colors: [Color.white.opacity(scheme == .dark ? 0.55 : 0.95), Color.white.opacity(0)],
                                                  center: light, startRadius: 0, endRadius: rimReach), lineWidth: 1.25)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .background {
                if shadow {
                    shape.fill(Color.black.opacity(0.001))
                        .shadow(color: .black.opacity(on ? (scheme == .dark ? 0.35 : 0.13) : 0), radius: on ? 14 : 0,
                                x: move ? -nx * 6 : 0, y: on ? 8 : 0)
                }
            }
            .rotation3DEffect(.degrees(angle), axis: (x: -ny, y: nx, z: 0), perspective: 0.55)
            .offset(y: move && on && !pressed ? -lift : 0)
            .scaleEffect(move && pressed ? 0.98 : 1)
            .animation(pressed ? Motion.press : Motion.card, value: pressed)
            .animation(Motion.card, value: hover.map { "\(Int($0.x / 2)),\(Int($0.y / 2))" } ?? "")
    }
}

extension View {
    func cardMotion(hover: CGPoint?, size: CGSize, pressed: Bool, radius: CGFloat, tilt: Double = 3, lift: Double = 2, shadow: Bool = true) -> some View {
        modifier(CardMotion(hover: hover, size: size, pressed: pressed, radius: radius, tilt: tilt, lift: lift, shadow: shadow))
    }
}

/// A clickable card with pointer tilt, edge light, lift, and press (see `CardMotion`).
/// The visuals move underneath; an untransformed layer on top takes the pointer, so hit-testing is never
/// subject to the 3D transform or to a competing Button gesture (both lost clicks on macOS 26).
struct CardButton<Content: View>: View {
    var tilt: Double = 2
    var lift: Double = 2
    var radius: Double = 12
    /// When set, the card can be dragged (to a project, to Finder as text). Click uses a tap gesture then,
    /// because a zero-distance drag gesture would swallow the system drag.
    var dragPayload: (() -> String)? = nil
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hover: CGPoint? = nil
    @State private var down = false
    @State private var size: CGSize = .zero

    var body: some View {
        content()
            .cardMotion(hover: hover, size: size, pressed: down, radius: radius, tilt: tilt, lift: lift)
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
                .simultaneousGesture(PressTracker.gesture { down = $0 })
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

/// Reports press-down and release without competing with a tap or a system drag: a long press that never
/// completes (10 s) and gives up after 6 pt of movement, run alongside the real gestures.
enum PressTracker {
    static func gesture(_ changed: @escaping (Bool) -> Void) -> some Gesture {
        LongPressGesture(minimumDuration: 10, maximumDistance: 6)
            .onChanged { _ in changed(true) }
            .onEnded { _ in changed(false) }
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

/// Card motion for surfaces that hold their own controls (the Dictionary rows, the dock frame).
/// The pointer passes through to children. With `rotates` off (the default for these), the card keeps the edge
/// light, lift, and shadow and skips the 3D tilt: on macOS 26 a rotated ancestor loses clicks for its children.
struct TiltCard: ViewModifier {
    var tilt: Double = 3
    var lift: Double = 2
    var radius: Double = 12
    var rotates: Bool = true
    @State private var hover: CGPoint? = nil
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .cardMotion(hover: hover, size: size, pressed: false, radius: radius, tilt: rotates ? tilt : 0, lift: lift)
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
