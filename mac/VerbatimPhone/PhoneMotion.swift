import SwiftUI

// Motion for the iPhone screens, matched to the approved web prototype (timings in `Motion`, Tokens.swift).
// Rules from the design system: never animate keyboard-initiated or high-frequency actions; stagger only the
// first screenful when a screen appears; delight stays small and rare. Everything here reads `\.limitMotion`
// (Reduce Motion or Settings › Limit animation): movement becomes a short fade and nothing loops.

enum PhoneMotion {
    /// The screenshot tour (VERBATIM_UITEST=1) wants settled screens, so entrances and ambient loops stay off there.
    static let on = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] != "1"
}

// MARK: - Entrances

/// Which rows a screen has already shown, so a row rises in the first time it appears, not on every scroll or
/// data change. `enteredAt` marks the screen's latest entrance; rows appearing just after it stagger in order.
final class SeenRows {
    var ids = Set<AnyHashable>()
    var enteredAt = Date()
    /// Rows that appear this soon after an entrance are the first screenful.
    static let window: TimeInterval = 0.5
    /// Only the first ten elements stagger (index 0…9).
    static let staggerLimit = 9
    var entering: Bool { Date().timeIntervalSince(enteredAt) < Self.window }
    func entered() { enteredAt = Date() }
}

/// A screen element that fades in and rises into place.
/// - First screenful (within `SeenRows.window` of an entrance, index ≤ 9): rises 12 pt over 760 ms, 70 ms after
///   the previous element, starting `base` seconds in.
/// - Scrolled into view later (`scrollRise`): rises 14 pt over 900 ms, once per screen.
/// - `epoch` moves on when the screen enters again (a tab switch): the first screenful staggers again.
/// With motion limited: a 200 ms fade, no movement.
struct RiseIn: ViewModifier {
    var id: AnyHashable
    var index: Int
    var seen: SeenRows
    var epoch: Int
    var base: Double
    var scrollRise: Bool
    @Environment(\.limitMotion) private var limitMotion
    @State private var shown: Bool
    @State private var lift: CGFloat = 14

    init(id: AnyHashable, index: Int, seen: SeenRows, epoch: Int, base: Double, scrollRise: Bool) {
        self.id = id; self.index = index; self.seen = seen; self.epoch = epoch; self.base = base; self.scrollRise = scrollRise
        let firstScreenful = seen.entering && index <= SeenRows.staggerLimit
        // A screen rebuilt behind the look-switch card is simply there when the card fades (LookSwitch.swift).
        _shown = State(initialValue: !PhoneMotion.on || LookSwitch.rebuilding || seen.ids.contains(id) || (!scrollRise && !firstScreenful))
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || limitMotion ? 0 : lift)
            .onAppear {
                guard PhoneMotion.on, !seen.ids.contains(id) else { return }
                seen.ids.insert(id)
                guard !shown else { return }
                play(staggered: seen.entering && index <= SeenRows.staggerLimit)
            }
            .onChange(of: epoch) { _, _ in
                guard PhoneMotion.on, index <= SeenRows.staggerLimit else { return }
                var hide = Transaction()
                hide.disablesAnimations = true
                withTransaction(hide) { shown = false }
                DispatchQueue.main.async { play(staggered: true) }
            }
    }

    private func play(staggered: Bool) {
        if limitMotion {
            withAnimation(Motion.fade) { shown = true }
            return
        }
        lift = staggered ? 12 : 14
        let animation = staggered ? Motion.enter.delay(base + Double(index) * Motion.enterStep) : Motion.rise
        withAnimation(animation) { shown = true }
    }
}

extension View {
    /// See `RiseIn`. `index` is the element's place on the screen, top to bottom.
    func riseIn(_ id: AnyHashable, index: Int, seen: SeenRows, epoch: Int, base: Double = 0.12, scrollRise: Bool = true) -> some View {
        modifier(RiseIn(id: id, index: index, seen: seen, epoch: epoch, base: base, scrollRise: scrollRise))
    }
}

/// A tab's content enters from the side you moved toward (26 pt, fading in over 620 ms) when you switch to it.
/// Standard TabView, so this runs on each tab's content root. `onEnter` lets the screen restagger its first
/// screenful. Popping back from a pushed screen isn't a tab switch, so nothing replays then.
struct TabEntrance: ViewModifier {
    @EnvironmentObject var app: PhoneState
    var tab: PhoneState.Tab
    var onEnter: () -> Void
    @Environment(\.limitMotion) private var limitMotion
    @State private var dx: CGFloat = 0
    @State private var alpha: Double = 1
    @State private var handled: Int? = nil

    func body(content: Content) -> some View {
        content
            .offset(x: dx)
            .opacity(alpha)
            .onAppear { enterIfNeeded() }
            .onChange(of: app.tabEpoch) { _, _ in enterIfNeeded() }
    }

    private func enterIfNeeded() {
        guard handled != app.tabEpoch else { return }
        handled = app.tabEpoch
        // Rebuilt in a new look while on screen (LookSwitch.swift): not a tab switch, so nothing enters.
        guard !LookSwitch.rebuilding else { return }
        guard app.tab == tab, app.tabFrom != tab else { return }
        onEnter()
        guard PhoneMotion.on else { return }
        let from: CGFloat = limitMotion ? 0 : (tab.order > app.tabFrom.order ? 26 : -26)
        var start = Transaction()
        start.disablesAnimations = true
        withTransaction(start) { dx = from; alpha = 0 }
        DispatchQueue.main.async {
            withAnimation(limitMotion ? Motion.fade : Motion.enterTab) { dx = 0; alpha = 1 }
        }
    }
}

extension View {
    func tabEntrance(_ tab: PhoneState.Tab, onEnter: @escaping () -> Void = {}) -> some View {
        modifier(TabEntrance(tab: tab, onEnter: onEnter))
    }
}

// MARK: - Controls

/// Press: scale 0.97 in and out over 320 ms. With motion limited, a brief dim instead.
struct SoftPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pressable(configuration: configuration) }
    private struct Pressable: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.limitMotion) private var limitMotion
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !limitMotion ? 0.97 : 1)
                .opacity(configuration.isPressed && limitMotion ? 0.7 : 1)
                .animation(limitMotion ? Motion.fade : Motion.pressSoft, value: configuration.isPressed)
        }
    }
}
