import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @Environment(\.limitMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(shown || index < 0 ? 1 : 0)
            .offset(y: shown || reduce || index < 0 ? 0 : 4)
            .onAppear { if index >= 0 { withAnimation(Motion.settle.delay(Double(index) * 0.03)) { shown = true } } }
    }
}
extension View { func staggerIn(_ index: Int) -> some View { modifier(StaggerIn(index: index)) } }

/// Short system sounds for the moments that earn one: start, done, and (softer) cancel or wait.
///
/// Follows Settings › General › Sounds (`enabled`) only. Sound isn't motion, so Reduce Motion doesn't silence it.
enum Sounds {
    static var enabled = true
    static func play(_ name: String, volume: Float = 1) {
        guard enabled, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = volume
        sound.play()
    }
    static func start() { play("Pop") }
    static func done() { play("Tink") }
    /// A dictation was cancelled: quieter than start and done.
    static func cancel() { play("Bottle", volume: 0.35) }
    /// A dictation waits for the last one to finish before it listens.
    static func queued() { play("Purr", volume: 0.5) }
}

/// Accepts transcripts dragged from Home, Library, or the Queue.
struct TranscriptDropTarget: ViewModifier {
    var enabled: Bool
    @Binding var dropping: Bool
    var perform: ([UUID]) -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.plainText, .utf8PlainText, .text], isTargeted: $dropping) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    let ids = TranscriptDrag.ids(from: s)
                    if !ids.isEmpty { DispatchQueue.main.async { perform(ids) } }
                }
                return true
            }
        } else { content }
    }
}

extension View {
    /// Makes the view draggable as these transcripts, onto a project in the sidebar (read back by `TranscriptDropTarget`).
    func transcriptDrag(_ ids: [UUID]) -> some View {
        onDrag { NSItemProvider(object: TranscriptDrag.payload(ids) as NSString) }
    }
}
