// The Mac's shared controls: direct-click gestures that stay safe under parent gestures and in panels, press
// feedback, short system sounds, and the transcript drop target.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A quiet rounded hover background for utility icons and small controls.
struct HoverChip: ViewModifier {
    var radius: CGFloat = Radius.button
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Refined.ink.opacity(hover ? 0.07 : 0)))
            .onHover { hover = $0 }
            .animation(Motion.touch, value: hover)
    }
}
extension View { func hoverChip(radius: CGFloat = Radius.button) -> some View { modifier(HoverChip(radius: radius)) } }

/// Where a direct-gesture control keeps its own size: a plain reference held in `@State`, so writing it never
/// renders the control again. Measured into `@State`, every tap area, pill, and card rendered a second time right
/// after its screen appeared (one extra pass per sidebar row and per transcript timecode). Views that draw from the
/// size read it on their next render, which a hover or press always brings.
final class HitBox {
    var size: CGSize = .zero
}

/// The click rule every direct-gesture control shares (`TapArea`): a zero-distance drag
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


/// A direct click for sidebar rows, chips, and panels: a click gesture (`HitArea`) instead of a SwiftUI Button.
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
