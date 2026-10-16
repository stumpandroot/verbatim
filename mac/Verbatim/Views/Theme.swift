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
