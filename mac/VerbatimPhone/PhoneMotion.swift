import SwiftUI

// Motion for the iPhone screens, matched to the approved web prototype (timings in `Motion`, Tokens.swift).
// Rules from the design system: never animate keyboard-initiated or high-frequency actions; stagger only the
// first screenful when a screen appears; delight stays small and rare. Everything here reads `\.limitMotion`
// (Reduce Motion or Settings › Limit animation): movement becomes a short fade and ambient motion stops.

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
        _shown = State(initialValue: !PhoneMotion.on || seen.ids.contains(id) || (!scrollRise && !firstScreenful))
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

/// A switch whose knob settles with a small spring (520 ms), in the brand's sage. Keeps the system switch's
/// accessibility (role, value, and actions) through `accessibilityRepresentation`.
struct SpringSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { SpringSwitch(configuration: configuration) }
    private struct SpringSwitch: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.limitMotion) private var limitMotion
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let on = configuration.isOn
            Button {
                withAnimation(limitMotion ? Motion.fade : Motion.toggle) { configuration.$isOn.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 12) {
                    configuration.label
                    Spacer(minLength: 8)
                    ZStack(alignment: on ? .trailing : .leading) {
                        Capsule().fill(on ? Ink.switchOn : Ink.outlineStrong)
                        Circle().fill(Ink.readerFixed)
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                            .padding(2)
                    }
                    .frame(width: 51, height: 31)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
            .sensoryFeedback(.selection, trigger: on)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

// MARK: - Ambient motion (small, slow, and off when motion is limited)

/// The Record key's soft halo: a disc that swells to 1.38× and fades, every 4.2 s.
struct RecordHalo: View {
    var color: Color = Ink.persimmon
    @Environment(\.limitMotion) private var limitMotion
    var body: some View {
        if limitMotion || !PhoneMotion.on {
            Color.clear
        } else {
            Circle().fill(color)
                .keyframeAnimator(initialValue: 0.0, repeating: true) { content, v in
                    content.scaleEffect(1 + 0.38 * v).opacity(0.35 * (1 - v))
                } keyframes: { _ in
                    KeyframeTrack { LinearKeyframe(1.0, duration: 4.2, timingCurve: .easeOut) }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A straight segment in a design-space box, aspect fit like BrandGlyph (for trimmed, animated lines).
struct ArtLine: Shape {
    var box: CGRect
    var from: CGPoint
    var to: CGPoint
    func path(in rect: CGRect) -> Path {
        let space = ArtSpace(box: box, size: rect.size)
        var p = Path()
        p.move(to: from); p.addLine(to: to)
        return p.applying(space.transform).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The Import icon: the document's lines erase and rewrite every 4.8 s, one after another.
struct ImportGlyph: View {
    var color: Color = Ink.ink
    @Environment(\.limitMotion) private var limitMotion
    private static let page = BrandArt(box: BrandArt.iconBox, strokes: [.path("M43 22h34l17 17v68H43z M77 22v19h17")])
    private static let lines: [(y: CGFloat, end: CGFloat)] = [(56, 83), (71, 83), (86, 73)]
    /// BrandGlyph's floor at icon size (4.5 × 24 / 112 is under it).
    private let lineWidth: CGFloat = 1.1

    var body: some View {
        ZStack {
            BrandGlyph(art: Self.page, color: color)
            ForEach(0..<3, id: \.self) { i in line(i) }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func line(_ i: Int) -> some View {
        let l = Self.lines[i]
        let shape = ArtLine(box: BrandArt.iconBox, from: CGPoint(x: 52, y: l.y), to: CGPoint(x: l.end, y: l.y))
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        if limitMotion || !PhoneMotion.on {
            shape.stroke(color, style: style)
        } else {
            let tint = color
            Color.clear.keyframeAnimator(initialValue: 1.0, repeating: true) { _, v in
                shape.trim(from: 0, to: v).stroke(tint, style: style)
            } keyframes: { _ in
                // Hold, erase from the end, rewrite, hold: 4.8 s per cycle, each line 0.25 s after the last.
                KeyframeTrack {
                    LinearKeyframe(1.0, duration: 2.64 + 0.25 * Double(i))
                    LinearKeyframe(0.0, duration: 0.72, timingCurve: .easeInOut)
                    LinearKeyframe(1.0, duration: 0.72, timingCurve: .easeInOut)
                    LinearKeyframe(1.0, duration: 0.72 - 0.25 * Double(i))
                }
            }
        }
    }
}

/// The Link icon: the chain gives a small, slow bounce every 5 s.
struct LinkGlyph: View {
    @Environment(\.limitMotion) private var limitMotion
    var body: some View {
        if limitMotion || !PhoneMotion.on {
            symbol
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                symbol.symbolEffect(.bounce, options: .speed(0.5), value: context.date)
            }
        }
    }
    private var symbol: some View {
        Image(systemName: "link").font(.system(size: 17, weight: .light)).accessibilityHidden(true)
    }
}

/// Voice-note tiles: the brand mic with three small level bars that breathe at slightly different rates.
struct VoiceTileArt: View {
    @Environment(\.limitMotion) private var limitMotion
    var body: some View {
        ZStack(alignment: .topTrailing) {
            BrandGlyph(art: .capture, color: Ink.ink, minLineWidth: 1.3).padding(8)
            HStack(alignment: .bottom, spacing: 1.5) {
                bar(height: 5, period: 1.6)
                bar(height: 7, period: 1.9)
                bar(height: 4, period: 1.4)
            }
            .frame(height: 7, alignment: .bottom)
            .padding(.top, 7).padding(.trailing, 6)
        }
    }

    @ViewBuilder private func bar(height: CGFloat, period: Double) -> some View {
        let shape = Capsule().fill(Ink.ink.opacity(0.75)).frame(width: 1.3, height: height)
        if limitMotion || !PhoneMotion.on {
            shape
        } else {
            shape.keyframeAnimator(initialValue: 0.35, repeating: true) { content, v in
                content.scaleEffect(x: 1, y: v, anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(1.0, duration: period / 2, timingCurve: .easeInOut)
                    LinearKeyframe(0.35, duration: period / 2, timingCurve: .easeInOut)
                }
            }
        }
    }
}

/// Link tiles: the play triangle breathes (1 → 1.12 → 1 over 3.6 s) inside its still circle.
struct PlayTileArt: View {
    @Environment(\.limitMotion) private var limitMotion
    private static let ring = BrandArt(box: BrandArt.iconBox, strokes: [.circle(64, 64, 42)])
    private static let triangle = BrandArt(box: BrandArt.iconBox, strokes: [.path("M55 43l29 21-29 21z")])
    var body: some View {
        ZStack {
            BrandGlyph(art: Self.ring, color: Ink.ink, minLineWidth: 1.3)
            if limitMotion || !PhoneMotion.on {
                BrandGlyph(art: Self.triangle, color: Ink.ink, minLineWidth: 1.3)
            } else {
                BrandGlyph(art: Self.triangle, color: Ink.ink, minLineWidth: 1.3)
                    .keyframeAnimator(initialValue: 1.0, repeating: true) { content, v in
                        content.scaleEffect(v)
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(1.12, duration: 1.8, timingCurve: .easeInOut)
                            LinearKeyframe(1.0, duration: 1.8, timingCurve: .easeInOut)
                        }
                    }
            }
        }
        .padding(8)
    }
}
