import SwiftUI
import AppKit

// MARK: - The Ribbon

private enum RibbonInk {
    static let ink = Color(hex: 0x26352E)
    static let inkRaised = Color(hex: 0x34453C)
    static let track = Color(hex: 0x3B4A42)
    static let persimmon = Color(hex: 0xFA6B47)
    static let butter = Color(hex: 0xF4C76B)
    static let paper = Color(hex: 0xF5F0E6)
    static let muted = Color(hex: 0xC9C2B3)
}

struct FlowBarView: View {
    @ObservedObject var model: FlowBarModel
    let controller: FlowBarController
    @ObservedObject var live: LiveMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var alignment: Alignment {
        switch model.edge { case .left: return .leading; case .right: return .trailing; case .bottom: return .bottom }
    }


    /// Every state shares one ink shape. Between states the shape morphs to its new size while the contents
    /// cross-fade, so the Ribbon never jumps. Reduce Motion turns the morph into a quick fade.
    private var morph: Animation? { reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.3) }

    private var closed: Bool { model.phase == .idle && !(model.hover || model.dragging) }

    /// Changes to any of these animate the shape.
    private var stateKey: String {
        "\(model.phase)-\(closed)-\(model.dragging)-\(model.handsFree)-\(model.warning.isEmpty)-\(model.command)-\(model.edge)-\(model.noticeAction ?? "")-\(model.notice.count)"
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
            .offset(x: model.shown ? 0 : (model.edge == .left ? -18 : model.edge == .right ? 18 : 0), y: model.shown || model.edge != .bottom ? 0 : 18)
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

    /// The one ink shape, sized by whatever it holds; closed, it's the thin sliver at the edge.
    private var tabbed: some View {
        let r: CGFloat = closed ? 4 : 15
        return inner
            .padding(.vertical, closed ? 0 : (model.phase == .notice ? 10 : 11))
            .padding(.horizontal, closed ? 0 : 12)
            .frame(width: closed ? (model.edge == .bottom ? 50 : 6) : nil, height: closed ? (model.edge == .bottom ? 6 : 50) : nil)
            .background(tab(r).fill(RibbonInk.ink))
            .overlay(tab(r).strokeBorder(RibbonInk.persimmon.opacity(model.command && model.phase == .listening ? 0.9 : 0), lineWidth: 1.5))
            .clipShape(tab(r))
    }

    /// What's inside the shape for each state. Each fades in and out as the shape morphs.
    @ViewBuilder private var inner: some View {
        switch model.phase {
        case .idle where closed:
            Color.clear.frame(width: 0, height: 0)
        case .idle:
            edgeRow(spacing: 9) {
                RibbonBars(edge: model.edge, levels: [0.8, 0.55, 0.95], thickness: 5, length: 18)
            } rest: {
                VStack(alignment: model.edge == .right ? .trailing : .leading, spacing: 1) {
                    Text(model.dragging ? "Drop at an edge" : "Dictate").font(.system(size: 12, weight: .medium)).foregroundStyle(RibbonInk.paper)
                    if !model.dragging { Text(model.hint).font(.system(size: 11, design: .monospaced)).foregroundStyle(RibbonInk.muted) }
                }
                .fixedSize()
            }
            .transition(.opacity)
        case .listening:
            VStack(spacing: 4) {
                edgeRow(spacing: 10) {
                    RibbonBars(edge: model.edge, levels: liveLevels, thickness: 6, length: 46)
                } rest: {
                    VStack(spacing: 3) {
                        Button(action: controller.stop) {
                            ZStack { Circle().fill(RibbonInk.persimmon); RoundedRectangle(cornerRadius: 1.5).fill(RibbonInk.paper).frame(width: 7, height: 7) }
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain).help("Stop and paste")
                        Text(elapsed).font(.system(size: 11, design: .monospaced)).foregroundStyle(RibbonInk.muted).monospacedDigit()
                    }
                    if model.handsFree {
                        Button(action: controller.cancel) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(RibbonInk.muted).frame(width: 18, height: 18) }
                            .buttonStyle(.plain).help("Cancel (Esc)")
                    }
                }
                if !model.warning.isEmpty {
                    Text(model.warning).font(.system(size: 10.5, weight: .medium)).foregroundStyle(RibbonInk.butter).lineLimit(1).fixedSize()
                }
            }
            .transition(.opacity)
        case .working:
            edgeRow(spacing: 9) {
                SweepBar(edge: model.edge, reduceMotion: reduceMotion)
            } rest: {
                Text(model.appLabel.isEmpty ? (model.command ? "EDITING" : "WRITING") : model.appLabel)
                    .font(.system(size: 11, design: .monospaced)).tracking(0.6).foregroundStyle(RibbonInk.paper).fixedSize()
            }
            .transition(.opacity)
        case .notice:
            edgeRow(spacing: 10) {
                RibbonBars(edge: model.edge, levels: [0.7, 0.5, 0.85], thickness: 3.5, length: 12)
            } rest: {
                Text(model.notice).font(.system(size: 12, weight: .medium)).foregroundStyle(RibbonInk.paper).lineLimit(2).frame(maxWidth: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if let a = model.noticeAction { Text(a).font(.system(size: 12, weight: .semibold)).foregroundStyle(RibbonInk.butter).fixedSize() }
            }
            .transition(.opacity)
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

    private var elapsed: String {
        let s = Int(live.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var accessibilityLabel: String {
        switch model.phase {
        case .idle: return "Verbatim dictation: " + model.hint
        case .listening: return model.handsFree ? "Listening. Click to stop and paste." : "Listening"
        case .working: return "Writing your words"
        case .notice: return model.notice
        case .prompt: return model.prompt?.title ?? ""
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
            Capsule().fill(Color(hex: 0x3B4A42))
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
    let prompt: FlowBarModel.Prompt
    let controller: FlowBarController
    @State private var progress: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                RibbonBars(edge: .left, levels: [0.8, 0.55, 0.95], thickness: 3.5, length: 12, color: RibbonInk.butter)
                Text(prompt.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(RibbonInk.paper)
                Spacer(minLength: 12)
                Button { controller.dismissPrompt() } label: {
                    ZStack {
                        Circle().stroke(RibbonInk.track, lineWidth: 2)
                        Circle().trim(from: 0, to: progress).stroke(RibbonInk.muted, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(RibbonInk.paper)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).help("Close (keeps it in Dictations)")
            }
            (Text(prompt.body) + Text(prompt.quote.map { "“\($0)”" } ?? "").foregroundColor(RibbonInk.paper) + Text(prompt.after))
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
        .background(RibbonInk.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { withAnimation(.linear(duration: prompt.seconds)) { progress = 0 } }
    }
}

private struct PromptButton: ButtonStyle {
    var filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: filled ? .semibold : .regular))
            .foregroundStyle(filled ? RibbonInk.ink : RibbonInk.paper)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(filled ? RibbonInk.paper : RibbonInk.inkRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
