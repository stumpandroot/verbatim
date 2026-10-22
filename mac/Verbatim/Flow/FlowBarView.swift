import SwiftUI
import AppKit

// MARK: - The Ribbon

/// How the Ribbon looks, chosen in Settings › Dictation › Floating button look.
enum RibbonStyle: String { case paper, ink; static let key = "flow.ribbonStyle" }
/// What moves with your voice: the logo's three bars or the colophon's tangent rings.
enum RibbonMark: String { case bars, rings; static let key = "flow.ribbonMark" }
/// Settings › Dictation › Floating button look › Show words as you speak. On by default.
enum LiveWordsSetting {
    static let key = "flow.liveWords"
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// The Ribbon's colors. Paper (the default) is a light tab with ink type and persimmon marks; Ink is the dark
/// tab with paper type. Either stays the same in light and dark mode, so it reads as Verbatim on any wallpaper.
/// Views that use these also read the setting with @AppStorage, so they redraw when it changes.
private enum RibbonInk {
    private static var dark: Bool { UserDefaults.standard.string(forKey: RibbonStyle.key) == RibbonStyle.ink.rawValue }
    private static let inkHex: UInt32 = 0x26352E, paperHex: UInt32 = 0xF5F0E6
    static var tab: Color { Color(hex: dark ? inkHex : paperHex) }
    static var edge: Color { dark ? Color(hex: paperHex).opacity(0.16) : Color(hex: inkHex).opacity(0.18) }
    static var text: Color { Color(hex: dark ? paperHex : inkHex) }
    static var raised: Color { (dark ? Color(hex: paperHex) : Color(hex: inkHex)).opacity(dark ? 0.12 : 0.08) }
    static var track: Color { (dark ? Color(hex: paperHex) : Color(hex: inkHex)).opacity(dark ? 0.16 : 0.12) }
    static let persimmon = Color(hex: 0xFA6B47)
    /// Accent for text: deep persimmon on paper (4.9:1), butter on ink.
    static var persimmonText: Color { dark ? Color(hex: 0xF4C76B) : Color(hex: 0xB23F24) }
    static let paper = Color(hex: paperHex)
    static var muted: Color { dark ? Color(hex: 0xC9C2B3) : Color(hex: 0x5F6A62) }
}

/// The voice mark at whatever size a state needs.
private struct RibbonMeter: View {
    var edge: BarEdge
    var levels: [Double]
    var thickness: CGFloat
    var length: CGFloat
    @AppStorage(RibbonMark.key) private var mark: String = RibbonMark.bars.rawValue
    var body: some View {
        if mark == RibbonMark.rings.rawValue { RibbonRings(levels: levels, size: length) }
        else { RibbonBars(edge: edge, levels: levels, thickness: thickness, length: length) }
    }
}

/// The colophon's three rings, tangent at the bottom point, swelling with your voice.
struct RibbonRings: View {
    var levels: [Double]
    var size: CGFloat
    var color: Color = Color(hex: 0xFA6B47)
    var body: some View {
        let base: [CGFloat] = [0.5, 0.36, 0.22]
        ZStack(alignment: .bottom) {
            ForEach(0..<3, id: \.self) { i in
                let d = size * base[i] * 2 * (0.82 + CGFloat(levels[min(i, levels.count - 1)]) * 0.3)
                Circle().stroke(color, lineWidth: max(1.2, size / 16)).frame(width: d, height: d)
            }
        }
        .frame(width: size * 1.15, height: size * 1.15, alignment: .bottom)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

struct FlowBarView: View {
    @AppStorage(RibbonStyle.key) private var ribbonStyle: String = RibbonStyle.paper.rawValue
    @AppStorage(RibbonMark.key) private var ribbonMark: String = RibbonMark.bars.rawValue
    @ObservedObject var model: FlowBarModel
    let controller: FlowBarController
    @ObservedObject var live: LiveMeter
    /// Live words while listening (a preview; the pasted text comes from the main engine).
    @ObservedObject var words: LiveTranscriber
    @AppStorage(LiveWordsSetting.key) private var showWords = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Settings › General › Limit animation. The bar lives in its own panel, outside the window that injects
    /// `limitMotion`, so it reads the preference directly.
    @AppStorage(MotionPreference.key) private var motionLimited = false
    private var reduceMotion: Bool { systemReduceMotion || motionLimited }

    private var alignment: Alignment {
        switch model.edge { case .left: return .leading; case .right: return .trailing; case .bottom: return .bottom }
    }


    /// Every state shares one paper tab. Between states the tab springs to its new size (0.38 s, a little bounce,
    /// tuned in the Ribbon prototype) and keeps its velocity if the state changes mid-move, while the contents
    /// fade in a beat after the shape starts moving. Reduce Motion turns the morph into a quick fade.
    private var morph: Animation? { reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.38, bounce: 0.22) }

    /// Contents arrive just after the tab starts growing and leave at once, so text never squeezes into a tab
    /// that's still small.
    private var contentTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.94)).animation(.easeOut(duration: 0.18).delay(0.07)),
            removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    private var closed: Bool { model.phase == .idle && !(model.hover || model.dragging) }

    /// Live words show while listening when the setting is on and a session is starting or running. When live
    /// words aren't possible on this Mac, the session goes back to off and nothing extra shows.
    private var liveWordsShown: Bool { model.phase == .listening && showWords && words.state != .off }
    /// The words as the Ribbon shows them: the end only, so the line stays short to lay out.
    private var liveTail: LiveWords { words.words.tail(model.edge == .bottom ? 90 : 80) }
    /// The tab grows with the words on the same spring as the state morph; with Reduce Motion or Limit
    /// animation, a quick ease instead (no spring).
    private var liveMorph: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.38, bounce: 0.22) }
    /// Keyed on the word count, not the text: a new word grows the tab on the spring, while a word that's revised
    /// in place (volatile to final) swaps without restarting the animation.
    private var liveKey: String { liveWordsShown ? "\(words.state)|\(liveTail.text.split(separator: " ").count)" : "" }

    /// Changes to any of these animate the shape.
    private var stateKey: String {
        "\(ribbonStyle)-\(model.phase)-\(closed)-\(model.dragging)-\(model.handsFree)-\(model.warning.isEmpty)-\(model.alert?.title ?? "")-\(model.command)-\(model.edge)-\(model.noticeAction ?? "")-\(model.notice.count)"
    }

    private var screenEdge: Edge { switch model.edge { case .left: return .leading; case .right: return .trailing; case .bottom: return .bottom } }

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            Group {
                if model.phase == .prompt, let p = model.prompt {
                    PromptCard(prompt: p, controller: controller)
                        .padding(model.edge == .bottom ? .bottom : (model.edge == .left ? .leading : .trailing), 10)
                        .transition(.asymmetric(insertion: .move(edge: screenEdge).combined(with: .opacity), removal: .opacity))
                } else {
                    tabbed.transition(.opacity)
                }
            }
            .background(GeometryReader { g in Color.clear.preference(key: RibbonSizeKey.self, value: g.size) })
            .contentShape(Rectangle())
            // One gesture: a drag moves the Ribbon, otherwise it's a click. Buttons inside (Stop, Cancel,
            // Discard, Paste anyway) take their own clicks and don't also trigger the Ribbon's.
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in controller.dragChanged() }
                .onEnded { _ in controller.dragEnded() }
                .exclusively(before: TapGesture().onEnded { controller.clicked() }))
            .accessibilityElement(children: model.phase == .listening || model.phase == .prompt ? .contain : .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            // Slides in from the edge when it first appears (and after sleep or a display change).
            .offset(x: model.shown ? 0 : (model.edge == .left ? -12 : model.edge == .right ? 12 : 0), y: model.shown || model.edge != .bottom ? 0 : 12)
            .opacity(model.shown ? 1 : 0)
        }
        .onPreferenceChange(RibbonSizeKey.self) { s in if model.contentSize != s { model.contentSize = s } }
        .animation(morph, value: stateKey)
    }

    /// The tab's rounded side faces into the screen; the edge side is square, flush with the screen edge.
    private func tab(_ r: CGFloat) -> UnevenRoundedRectangle {
        switch model.edge {
        case .left: return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .right: return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        case .bottom: return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: r, style: .continuous)
        }
    }

    /// The one paper tab, sized by whatever it holds; closed, it's a thin sliver at the edge.
    private var tabbed: some View {
        let r: CGFloat = closed ? 3 : 13
        return inner
            .padding(.vertical, closed ? 0 : 9)
            .padding(.horizontal, closed ? 0 : 14)
            .frame(width: closed ? (model.edge == .bottom ? 54 : 6) : nil, height: closed ? (model.edge == .bottom ? 6 : 54) : nil)
            .background(tab(r).fill(RibbonInk.tab))
            .overlay(tab(r).strokeBorder(model.command && model.phase == .listening ? RibbonInk.persimmon : RibbonInk.edge, lineWidth: model.command && model.phase == .listening ? 1.5 : 0.75))
            .clipShape(tab(r))
            .shadow(color: .black.opacity(closed ? 0.12 : 0.16), radius: closed ? 4 : 12, x: 0, y: 0)
            .animation(liveMorph, value: liveKey)
    }

    /// What's inside the shape for each state. Each fades in and out as the shape morphs.
    @ViewBuilder private var inner: some View {
        switch model.phase {
        case .idle where closed:
            Color.clear.frame(width: 0, height: 0)
        case .idle:
            edgeRow(spacing: 9) {
                RibbonMeter(edge: model.edge, levels: [0.75, 0.5, 0.95], thickness: 3.5, length: 13)
            } rest: {
                Text(model.dragging ? "Drop at an edge" : hintLine)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(RibbonInk.text).fixedSize()
            }
            .transition(contentTransition)
        case .listening:
            VStack(spacing: 4) {
                if liveWordsShown {
                    LiveWordsLine(words: liveTail, twoLines: model.edge != .bottom, reduceMotion: reduceMotion)
                        .transition(.opacity)
                }
                edgeRow(spacing: 10) {
                    RibbonMeter(edge: model.edge, levels: liveLevels, thickness: 5, length: 24)
                } rest: {
                    VStack(spacing: 3) {
                        Button(action: controller.stop) {
                            ZStack { Circle().fill(RibbonInk.persimmon); RoundedRectangle(cornerRadius: 1.5).fill(RibbonInk.paper).frame(width: 7, height: 7) }
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain).help("Stop and paste")
                        Text(elapsed).font(.system(size: 11, design: .monospaced)).foregroundStyle(RibbonInk.muted).monospacedDigit()
                    }
                    if model.handsFree {
                        Button(action: controller.cancel) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(RibbonInk.muted).frame(width: 22, height: 22).background(RibbonInk.raised, in: Circle()) }
                            .buttonStyle(.plain).help("Cancel (Esc)")
                    }
                }
                if let a = model.alert {
                    // Muted (the device says so): persimmon on paper, butter on ink. A guess from silence is softer.
                    VStack(spacing: 1) {
                        Text(a.title).font(.system(size: 12, weight: a.strong ? .semibold : .medium)).foregroundStyle(RibbonInk.persimmonText)
                        Text(a.detail).font(.system(size: 10.5, weight: a.strong ? .medium : .regular)).foregroundStyle(a.strong ? RibbonInk.persimmonText : RibbonInk.muted)
                    }
                    .lineLimit(1).fixedSize()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                } else if !model.warning.isEmpty {
                    Text(model.warning).font(.system(size: 10.5, weight: .medium)).foregroundStyle(RibbonInk.persimmonText).lineLimit(1).fixedSize()
                }
            }
            .transition(contentTransition)
        case .working:
            edgeRow(spacing: 9) {
                SweepBar(edge: model.edge, reduceMotion: reduceMotion)
            } rest: {
                Text(model.appLabel.isEmpty ? (model.command ? "EDITING" : "WRITING") : model.appLabel)
                    .font(.system(size: 11, design: .monospaced)).tracking(0.6).foregroundStyle(RibbonInk.text).fixedSize()
            }
            .transition(contentTransition)
        case .notice:
            edgeRow(spacing: 10) {
                RibbonMeter(edge: model.edge, levels: [0.7, 0.5, 0.85], thickness: 3.5, length: 12)
            } rest: {
                Text(model.notice).font(.system(size: 12, weight: .medium)).foregroundStyle(RibbonInk.text).lineLimit(2).frame(maxWidth: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if let a = model.noticeAction { Text(a).font(.system(size: 12, weight: .semibold)).foregroundStyle(RibbonInk.persimmonText).fixedSize() }
            }
            .transition(contentTransition)
        case .prompt:
            EmptyView()
        }
    }

    /// Lays out the bars against the screen edge and the rest beside them, toward the middle of the screen.
    @ViewBuilder private func edgeRow<A: View, B: View>(spacing: CGFloat, @ViewBuilder bars: () -> A, @ViewBuilder rest: () -> B) -> some View {
        if model.edge == .right {
            HStack(spacing: spacing) { rest(); bars() }
        } else {
            HStack(spacing: spacing) { bars(); rest() }
        }
    }

    /// Three bars from your real mic level: the loudest recent moment, the average, and a beat behind.
    private var liveLevels: [Double] {
        let l = live.levels.map(Double.init)
        guard l.count >= 8 else { return [0.2, 0.2, 0.2] }
        let last3 = l.suffix(3), last8 = l.suffix(8)
        return [last3.max() ?? 0, last8.reduce(0, +) / Double(last8.count), l[l.count - 5]].map { min(1, max(0.14, $0)) }
    }

    /// "Click or hold ⌥ to dictate", or the setup or secure-input hint when that's what applies.
    private var hintLine: String { DictationTiming.hintLine(model.hint) }

    private var elapsed: String {
        let s = Int(live.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var accessibilityLabel: String {
        switch model.phase {
        case .idle: return "Verbatim dictation: " + model.hint
        case .listening:
            let base = model.handsFree ? "Listening. Click to stop and paste." : "Listening"
            if let a = model.alert { return "\(base). \(a.title). \(a.detail)." }
            return base
        case .working: return "Writing your words"
        case .notice: return model.notice
        case .prompt: return model.prompt?.title ?? ""
        }
    }
}

/// While listening: your words so far in a serif line, the end showing, the newest word in persimmon. "Listening…"
/// until the first word. Grows the tab up to about 320 pt; past that the older words slide off under a fade on
/// the leading edge. On a side edge it wraps to two lines. Hidden from VoiceOver: announcing every word would
/// drown out everything else, and the pasted text is what counts.
private struct LiveWordsLine: View {
    @AppStorage(RibbonStyle.key) private var ribbonStyle: String = RibbonStyle.paper.rawValue
    var words: LiveWords
    var twoLines: Bool
    var reduceMotion: Bool
    private static let maxWidth: CGFloat = 320
    private static let size: CGFloat = 15.5

    var body: some View {
        Group {
            if words.isEmpty {
                Text("Listening…")
                    .font(Ink.serif(Self.size).italic())
                    .foregroundStyle(RibbonInk.muted)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                LiveFit(maxWidth: twoLines ? Self.maxWidth - 20 : Self.maxWidth, wrap: twoLines) {
                    styled
                        .font(Ink.serif(Self.size))
                        .lineLimit(twoLines ? 2 : nil)
                        .truncationMode(.head)
                        .multilineTextAlignment(.trailing)
                        .contentTransition(reduceMotion ? .opacity : .identity)
                    LinearGradient(colors: [RibbonInk.tab, RibbonInk.tab.opacity(0)], startPoint: .leading, endPoint: .trailing)
                }
                .clipped()
            }
        }
        .accessibilityHidden(true)
    }

    /// Settled words in ink, words that may still change a little lighter, the newest word in persimmon.
    private var styled: Text {
        // A spoken correction ("scratch that", "at 2, actually 3"): the words it removes fade with a strikethrough,
        // the replacement stays in ink. Style only, with no animation of its own.
        if SpokenCorrections.enabled, FlowSettings.shared.cleanup != .literal {
            let spans = SpokenCorrections.liveSpans(words.text)
            if spans.contains(where: { $0.style != .kept }) {
                return spans.reduce(Text("")) { t, s in
                    switch s.style {
                    case .removed: return t + Text(s.text).foregroundColor(RibbonInk.muted).strikethrough(true, color: RibbonInk.muted)
                    case .kept, .inserted: return t + Text(s.text).foregroundColor(RibbonInk.text)
                    }
                }
            }
        }
        let d = words.display
        var t = Text(d.settled).foregroundColor(RibbonInk.text)
        if !d.volatile.isEmpty {
            t = t + Text((d.settled.isEmpty ? "" : " ") + d.volatile).foregroundColor(RibbonInk.text.opacity(0.72))
        }
        let lead = d.settled.isEmpty && d.volatile.isEmpty ? "" : " "
        return t + Text(lead + d.newest).foregroundColor(RibbonInk.persimmonText)
    }
}

/// Sizes the live words to their natural width up to `maxWidth`. One line: the text keeps its full width,
/// pinned to the trailing edge (the caller clips the rest), and the second subview, a fade, covers the leading
/// edge only when something is cut off. Wrapping: the text wraps at `maxWidth`.
private struct LiveFit: Layout {
    var maxWidth: CGFloat
    var wrap: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let ideal = text.sizeThatFits(.unspecified)
        if ideal.width <= maxWidth { return ideal }
        if wrap { return text.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil)) }
        return CGSize(width: maxWidth, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let ideal = text.sizeThatFits(.unspecified)
        if wrap {
            text.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: ProposedViewSize(width: bounds.width, height: nil))
        } else {
            text.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        }
        let overflow = !wrap && ideal.width > bounds.width + 0.5
        for fade in subviews.dropFirst() {
            fade.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: overflow ? 28 : 0, height: bounds.height))
        }
    }
}

private struct RibbonSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The logo's three bars. On the sides they run horizontally from the edge; at the bottom they stand up.
struct RibbonBars: View {
    var edge: BarEdge
    var levels: [Double]
    var thickness: CGFloat
    var length: CGFloat
    var color: Color = Color(hex: 0xFA6B47)

    var body: some View {
        if edge == .bottom {
            HStack(alignment: .bottom, spacing: thickness * 0.65) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(color).frame(width: thickness, height: max(thickness, length * levels[i]))
                }
            }
            .frame(height: length, alignment: .bottom)
            .animation(.linear(duration: 0.08), value: levels)
        } else {
            VStack(alignment: edge == .right ? .trailing : .leading, spacing: thickness * 0.65) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(color).frame(width: max(thickness, length * levels[i]), height: thickness)
                }
            }
            .frame(width: length, alignment: edge == .right ? .trailing : .leading)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}

/// While writing: a persimmon segment sweeping along a dark track.
struct SweepBar: View {
    var edge: BarEdge
    var reduceMotion: Bool
    @State private var forward = false
    var body: some View {
        let vertical = edge == .bottom
        ZStack(alignment: vertical ? .top : .leading) {
            Capsule().fill(RibbonInk.track)
            Capsule().fill(Color(hex: 0xFA6B47))
                .frame(width: vertical ? 6 : 14, height: vertical ? 10 : 6)
                .offset(x: vertical ? 0 : (forward ? 24 : 0), y: vertical ? (forward ? 18 : 0) : 0)
        }
        .frame(width: vertical ? 6 : 38, height: vertical ? 28 : 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { forward = true }
        }
    }
}

/// "Started by mistake?" and other two-choice questions, with a countdown ring on the close button.
struct PromptCard: View {
    @AppStorage(RibbonStyle.key) private var ribbonStyle: String = RibbonStyle.paper.rawValue
    let prompt: FlowBarModel.Prompt
    let controller: FlowBarController
    @State private var progress: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                RibbonBars(edge: .left, levels: [0.8, 0.55, 0.95], thickness: 3.5, length: 12)
                Text(prompt.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(RibbonInk.text)
                Spacer(minLength: 12)
                Button { controller.dismissPrompt() } label: {
                    ZStack {
                        Circle().stroke(RibbonInk.track, lineWidth: 2)
                        Circle().trim(from: 0, to: progress).stroke(RibbonInk.muted, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(RibbonInk.text)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).help("Close (keeps it in Dictations)")
            }
            (Text(prompt.body) + Text(prompt.quote.map { "“\($0)”" } ?? "").foregroundColor(RibbonInk.text) + Text(prompt.after))
                .font(.system(size: 13)).foregroundStyle(RibbonInk.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(prompt.secondary) { controller.answer(primary: false) }
                    .buttonStyle(PromptButton(filled: false))
                if let p = prompt.primary {
                    Button(p) { controller.answer(primary: true) }.buttonStyle(PromptButton(filled: true))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 360)
        .background(RibbonInk.tab, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(RibbonInk.edge, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.16), radius: 14)
        .onAppear { withAnimation(.linear(duration: prompt.seconds)) { progress = 0 } }
    }
}

private struct PromptButton: ButtonStyle {
    var filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: filled ? .semibold : .regular))
            .foregroundStyle(filled ? RibbonInk.tab : RibbonInk.text)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(filled ? RibbonInk.text : RibbonInk.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
