import SwiftUI
import UIKit

// The transcript scrubber, like Photos' date scrubber: on transcripts taller than about three screens, a small
// handle appears at the right edge while you scroll and fades about 1.5 s after scrolling stops. Hold it (or hold
// the edge while it shows) and drag: the finger's height picks a place in the recording, paced by time
// (ScrubMath.swift), the transcript jumps there, and a bubble beside the finger names the time and the speaker
// ("23:41 · Ginna Cross"). A light selection haptic marks each minute (or a longer step on long recordings), never
// each line. VoiceOver: the handle stays put and is adjustable; swipe up or down to move a minute. Limit animation
// and Reduce Motion: no fades. Hidden in Select text. The track sits between the navigation bar and the player
// dock (or the tab bar), inside the safe area.

/// Where the transcript is scrolled and whether the handle shows. Kept out of TranscriptScreen's own state, so
/// scrolling re-renders only the scrubber, never the transcript.
@MainActor
final class TranscriptScrubModel: ObservableObject {
    /// How far down the transcript is scrolled, 0...1.
    @Published private(set) var progress: Double = 0
    /// Taller than about three screens.
    @Published private(set) var long = false
    /// Scrolling, or less than 1.5 s since it stopped.
    @Published private(set) var visible = false
    /// A finger is on the handle (or the UI test holds it there).
    @Published var dragging = false
    /// Where the finger is on the track, 0...1, while dragging.
    @Published var dragFraction: Double = 0
    /// VoiceOver's place after a swipe, until you scroll yourself.
    var voiceOverIndex: Int?

    private var contentHeight: Double = 0
    private var viewport: Double = 0
    private var offset: Double = 0
    private var hideTask: Task<Void, Never>?
    /// iOS 17: a finger is dragging the scroll view, or let go a moment ago (it may still be gliding).
    private var touching = false
    private var touchEnded = Date.distantPast
    static let fadeDelay: TimeInterval = 1.5

    func setViewport(_ height: Double) {
        guard abs(height - viewport) > 0.5 else { return }
        viewport = height
        update()
    }

    func setContent(minY: Double, height: Double) {
        let moved = abs(-minY - offset) > 0.5
        offset = -minY
        contentHeight = height
        update()
        // iOS 18 reads the scroll phase instead (`phase(_:)`).
        if #available(iOS 18, *) { return }
        if moved, !dragging, touching || Date().timeIntervalSince(touchEnded) < 0.8 { scrolled() }
    }

    /// iOS 17: the scroll view's own drag, seen alongside it.
    func touch(_ down: Bool) {
        touching = down
        if !down { touchEnded = Date() }
    }

    /// iOS 18: the person drags or flings the scroll view (not code scrolling it).
    @available(iOS 18.0, *)
    func phase(_ phase: ScrollPhase) {
        switch phase {
        case .interacting, .decelerating: show()
        case .idle: hideSoon()
        default: break
        }
    }

    private func update() {
        let l = ScrubMath.shows(contentHeight: contentHeight, viewport: viewport)
        if l != long { long = l }
        let p = min(1, max(0, offset / max(1, contentHeight - viewport)))
        if abs(p - progress) > 0.0005 { progress = p }
    }

    private func scrolled() {
        show()
        hideSoon()
    }

    private func show() {
        hideTask?.cancel(); hideTask = nil
        voiceOverIndex = nil
        if !visible { visible = true }
    }

    func hideSoon() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.fadeDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.dragging else { return }
            self.visible = false
        }
    }
}

extension Notification.Name {
    /// The UI test holds the scrubber mid-drag at a fraction of the track (a Double), or lets go (nil).
    static let verbatimScrubPreview = Notification.Name("verbatimScrubPreview")
}

/// Feeds the model from the transcript's scroll view: its height, the content's frame, and (iOS 18) the scroll
/// phase, or (iOS 17) the drag alongside the scroll.
private struct ScrubTracking: ViewModifier {
    var model: TranscriptScrubModel
    func body(content: Content) -> some View {
        let tracked = content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.setViewport($0) }
        if #available(iOS 18, *) {
            tracked.onScrollPhaseChange { _, phase in model.phase(phase) }
        } else {
            tracked.simultaneousGesture(DragGesture(minimumDistance: 12)
                .onChanged { _ in model.touch(true) }
                .onEnded { _ in model.touch(false) })
        }
    }
}

extension View {
    /// On the transcript's ScrollView.
    func scrubTracking(_ model: TranscriptScrubModel) -> some View { modifier(ScrubTracking(model: model)) }
    /// On the ScrollView's content; `space` is the ScrollView's named coordinate space.
    func scrubContent(_ model: TranscriptScrubModel, in space: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { r in
            model.setContent(minY: r.minY, height: r.height)
        }
    }
}

/// The handle, the bubble, and the edge you can hold. Fills the space between the navigation bar and the dock;
/// only the handle and the edge strip take touches, and only while they show.
struct TranscriptScrubber: View {
    @ObservedObject var model: TranscriptScrubModel
    /// The lines on screen, in order (asked for when a drag starts, not on every frame).
    var lines: () -> [Segment]
    /// When the recording ends; zero when there are no timings.
    var end: Double
    /// The speaker's name for the bubble, when there are speakers.
    var speaker: (Segment) -> String?
    /// Jumps the transcript to a line, at once.
    var jump: (Segment) -> Void
    /// A drag began (turns Follow off while playing).
    var onBegin: () -> Void

    @Environment(\.limitMotion) private var limitMotion
    @State private var voiceOver = UIAccessibility.isVoiceOverRunning
    /// The lines and their starts for the drag in progress.
    @State private var held: [Segment] = []
    @State private var starts: [Double] = []
    @State private var landed = -1
    @State private var tick = 0
    /// Bumped at each minute (or step) crossing; the haptic's trigger.
    @State private var crossings = 0
    @State private var trackHeight: CGFloat = 1

    private static let handleSize = CGSize(width: 24, height: 44)
    /// The UI test reads where the last drag landed ("23:41 · Ginna Cross").
    static var lastLanding: String?
    private static let space = "transcript-scrubber"

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let shown = model.long && (model.visible || model.dragging || voiceOver)
            let f = model.dragging ? model.dragFraction : model.progress
            let y = Self.handleY(f, height: h)
            ZStack(alignment: .topLeading) {
                // The edge: hold it while the handle shows, then drag.
                Color.clear
                    .frame(width: 34, height: h)
                    .contentShape(Rectangle())
                    .gesture(LongPressGesture(minimumDuration: 0.3)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
                        .onChanged { v in if case .second(true, let d?) = v { drag(to: d.location.y, height: h) } }
                        .onEnded { _ in release() })
                    .accessibilityHidden(true)
                    .position(x: g.size.width - 17, y: h / 2)
                handle
                    .position(x: g.size.width - 4 - Self.handleSize.width / 2, y: y)
                if model.dragging, let text = bubbleText {
                    // Beside the finger, its right edge 10 pt from the handle.
                    let room = max(0, g.size.width - 48)
                    bubble(text)
                        .frame(maxWidth: min(280, room))
                        .frame(width: room, alignment: .trailing)
                        .position(x: room / 2, y: min(max(y, 22), max(22, h - 22)))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: g.size.width, height: h)
            .coordinateSpace(.named(Self.space))
            .opacity(shown ? 1 : 0)
            .animation(limitMotion ? nil : .easeOut(duration: 0.2), value: shown)
            .allowsHitTesting(shown)
            .onAppear { trackHeight = h }
            .onChange(of: h) { _, new in trackHeight = new }
        }
        .sensoryFeedback(.selection, trigger: crossings)
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            voiceOver = UIAccessibility.isVoiceOverRunning
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimScrubPreview)) { n in
            if let f = n.object as? Double { scrub(to: f) } else { release() }
        }
    }

    // MARK: Handle and bubble

    private var handle: some View {
        Capsule()
            .fill(Ink.ink)
            .overlay {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.paper)
            }
            .frame(width: Self.handleSize.width, height: Self.handleSize.height)
            .scaleEffect(model.dragging && !limitMotion ? 1.08 : 1)
            .animation(limitMotion ? nil : Motion.press, value: model.dragging)
            .frame(width: 44, height: 60)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { v in drag(to: v.location.y, height: trackHeight) }
                .onEnded { _ in release() })
            .accessibilityElement()
            .accessibilityLabel("Transcript position")
            .accessibilityValue(voiceOverValue)
            .accessibilityHint("Swipe up or down to move a minute at a time.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(1)
                case .decrement: step(-1)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("transcript-scrubber")
    }

    /// "23:41 · Ginna Cross" on card white with an ink outline and the hard shadow (DESIGN.md §11), never glass.
    private func bubble(_ text: (time: String, name: String?)) -> some View {
        HStack(spacing: 6) {
            Text(text.time).font(Ink.mono(13, weight: .medium))
            if let name = text.name {
                Text("·").foregroundStyle(Ink.mute)
                Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
        }
        .foregroundStyle(Ink.ink)
        .padding(.horizontal, 12).frame(height: 34)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5))
        .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(Ink.hard).offset(x: 4, y: 5))
    }

    private var bubbleText: (time: String, name: String?)? {
        guard held.indices.contains(landed) else { return nil }
        return Self.label(held[landed], index: landed, count: held.count, timed: ScrubMath.pacedByTime(starts: starts, end: end), name: speaker(held[landed]))
    }

    /// The time (or "Line 12 of 340" without timings) and the speaker's name.
    static func label(_ s: Segment, index: Int, count: Int, timed: Bool, name: String?) -> (time: String, name: String?) {
        (timed ? s.start.timecode : "Line \(index + 1) of \(count)", name)
    }

    private static func handleY(_ fraction: Double, height: CGFloat) -> CGFloat {
        let half = handleSize.height / 2
        return half + CGFloat(min(1, max(0, fraction))) * max(0, height - handleSize.height)
    }

    private static func fraction(_ y: CGFloat, height: CGFloat) -> Double {
        let half = handleSize.height / 2
        return Double((y - half) / max(1, height - handleSize.height))
    }

    // MARK: Dragging

    private func drag(to y: CGFloat, height: CGFloat) {
        scrub(to: Self.fraction(y, height: height))
    }

    /// Moves to the line at `fraction` of the track; a new line jumps the transcript, a new minute ticks.
    private func scrub(to fraction: Double) {
        if !model.dragging {
            held = lines()
            starts = held.map(\.start)
            landed = -1
            tick = Int.min
            model.dragging = true
            onBegin()
        }
        let f = min(1, max(0, fraction))
        model.dragFraction = f
        guard !held.isEmpty else { return }
        let i = ScrubMath.index(at: f, starts: starts, end: end)
        guard i != landed else { return }
        landed = i
        jump(held[i])
        if PhoneUITest.enabled { Self.lastLanding = bubbleText.map { [$0.time, $0.name].compactMap { $0 }.joined(separator: " · ") } }
        let t = ScrubMath.tick(index: i, starts: starts, end: end, trackHeight: Double(trackHeight))
        if tick != Int.min, t != tick { crossings &+= 1 }
        tick = t
    }

    private func release() {
        guard model.dragging else { return }
        model.dragging = false
        held = []; starts = []; landed = -1
        model.hideSoon()
    }

    // MARK: VoiceOver

    private var voiceOverValue: String {
        guard voiceOver else { return "" }
        let all = lines()
        guard !all.isEmpty else { return "" }
        let s = all.map(\.start)
        let i = min(all.count - 1, model.voiceOverIndex ?? ScrubMath.index(at: model.progress, starts: s, end: end))
        let l = Self.label(all[i], index: i, count: all.count, timed: ScrubMath.pacedByTime(starts: s, end: end), name: speaker(all[i]))
        return [l.time, l.name].compactMap { $0 }.joined(separator: ", ")
    }

    private func step(_ direction: Int) {
        let all = lines()
        guard !all.isEmpty else { return }
        let s = all.map(\.start)
        let from = min(all.count - 1, model.voiceOverIndex ?? ScrubMath.index(at: model.progress, starts: s, end: end))
        let to = ScrubMath.stepped(from: from, direction: direction, starts: s, end: end, trackHeight: Double(trackHeight))
        onBegin()
        model.voiceOverIndex = to
        jump(all[to])
        model.objectWillChange.send()
    }
}
