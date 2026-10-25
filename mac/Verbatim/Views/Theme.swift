import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A quiet rounded hover background for utility icons and small controls.
struct HoverChip: ViewModifier {
    var radius: CGFloat = Radius.button
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.ink.opacity(hover ? 0.07 : 0)))
            .onHover { hover = $0 }
            .animation(Motion.touch, value: hover)
    }
}
extension View { func hoverChip(radius: CGFloat = Radius.button) -> some View { modifier(HoverChip(radius: radius)) } }

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
    /// The card's size for the tilt and the click, kept without state (see `HitBox`).
    @State private var box = HitBox()

    var body: some View {
        content()
            .cardMotion(hover: hover, size: box.size, pressed: down, radius: radius, tilt: tilt, lift: lift)
            .allowsHitTesting(false)
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
                    .modifier(CardHit(dragPayload: dragPayload, box: box, down: $down, action: action))
            }
    }
}

private struct CardHit: ViewModifier {
    var dragPayload: (() -> String)?
    var box: HitBox
    @Binding var down: Bool
    var action: () -> Void
    func body(content: Content) -> some View {
        if let payload = dragPayload {
            content
                .measured(box)
                .onTapGesture { action() }
                .simultaneousGesture(PressTracker.gesture { down = $0 })
                .onDrag { NSItemProvider(object: payload() as NSString) }
        } else {
            content.hitArea(box, pressed: { p in if down != p { down = p } }, action: action)
        }
    }
}

/// Where a direct-gesture control keeps its own size: a plain reference held in `@State`, so writing it never
/// renders the control again. Measured into `@State`, every tap area, pill, and card rendered a second time right
/// after its screen appeared (one extra pass per sidebar row and per transcript timecode). Views that draw from the
/// size (`CardButton`'s tilt) read it on their next render, which a hover or press always brings.
final class HitBox {
    var size: CGSize = .zero
}

/// The click rule every direct-gesture control shares (`TapArea`, `PillButton`, `CardButton`): a zero-distance drag
/// that fires on release inside the control, with 4 pt of slack, as a button's tracking does. A gesture rather than a
/// SwiftUI Button, so it stays safe under parent gestures and in panels (macOS 26 lost Button clicks in both). The
/// size it tests against comes from `measured(_:)` into a `HitBox`, never from state.
struct HitArea: ViewModifier {
    var box: HitBox
    var enabled = true
    /// Press down (true) and release (false), for press feedback.
    var pressed: ((Bool) -> Void)? = nil
    var action: () -> Void
    func body(content: Content) -> some View {
        content
            .measured(box)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed?(true) }
                .onEnded { v in
                    pressed?(false)
                    if enabled && CGRect(origin: .zero, size: box.size).insetBy(dx: -4, dy: -4).contains(v.location) { action() }
                })
    }
}

extension View {
    /// Keeps `box.size` equal to this view's size. Writes a reference, not state, so it causes no render.
    func measured(_ box: HitBox) -> some View {
        background(GeometryReader { g in
            Color.clear.onAppear { box.size = g.size }.onChange(of: g.size) { _, s in box.size = s }
        })
    }
    /// The shared click rule (`HitArea`) on this view, sized by `box`.
    func hitArea(_ box: HitBox, enabled: Bool = true, pressed: ((Bool) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        modifier(HitArea(box: box, enabled: enabled, pressed: pressed, action: action))
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


/// Non-tilting version for sidebar rows and chips: hover tint and a direct click gesture (`HitArea`).
struct TapArea: ViewModifier {
    var action: () -> Void
    @State private var box = HitBox()
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .hitArea(box, action: action)
    }
}

extension View {
    func tapArea(_ action: @escaping () -> Void) -> some View { modifier(TapArea(action: action)) }
    /// Press feedback for real Buttons (scale on isPressed through a button style).
    func pressable() -> some View { buttonStyle(PressStyle()) }
}

/// Press: a slight scale; with Limit Motion, a brief dim instead (nothing changes size).
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View { Pressed(configuration: configuration, scale: scale) }
    private struct Pressed: View {
        let configuration: ButtonStyleConfiguration
        var scale: CGFloat
        @Environment(\.limitMotion) private var limitMotion
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !limitMotion ? max(scale, 0.97) : 1)
                .opacity(configuration.isPressed && limitMotion ? 0.75 : 1)
                .animation(.easeOut(duration: configuration.isPressed ? 0.06 : 0.14), value: configuration.isPressed)
        }
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

/// Entrance stagger, retired: screens arrive at once, so navigation never makes you wait (DESIGN.md §7). Each
/// section used to rise 4 pt and fade in over 180 ms, 20 ms after the one before, on every screen change and inside
/// the screen's own fade, so a transcript reached full opacity about half a second after the click. The modifier
/// stays as a no-op so the screens that call it don't change.
struct StaggerIn: ViewModifier {
    var index: Int
    func body(content: Content) -> some View { content }
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
