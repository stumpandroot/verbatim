import SwiftUI

// Celebrations (DESIGN.md §7, Celebrations; the approved mockup, November 7, 2026), shared by the Mac and iPhone apps:
// the center that says which surface celebrates what, the burst that plays one (`CelebrationBurst`), the ink word
// pill, and This week's milestone. The rules (timings, sizes, words, surfaces) are in Model/CelebrationRules.swift.
//
// Every piece is an overlay that never takes a tap and never changes layout or row height. A burst is the fill (slow,
// then fast), the bounce, and the word rising; a tap during it jumps to the end. Limit animation and Reduce Motion get
// a 0.2 s crossfade to the end state with the word, and VoiceOver hears the word once. Nothing here loops, and every
// change runs in an explicit transaction (no `.animation` modifier catches anything else). The keyboard extension and
// the Mac's status-bar panels (the Ribbon, the notch, Recall) never celebrate: none of this is in them.

// MARK: - Center

/// One celebration a surface is asked to show. Keyed to its transcript (a Library row, the open transcript), or to a
/// fresh token (the Record card's "Saved", a milestone).
struct CelebrationTicket: Identifiable, Equatable {
    let id = UUID()
    var key: UUID
    var surface: ReadySurface? = nil
    var tone: CelebrationTone
    static func == (a: CelebrationTicket, b: CelebrationTicket) -> Bool { a.id == b.id }
}

/// A milestone showing on This week.
struct MilestoneTicket: Identifiable, Equatable {
    let id = UUID()
    var milestone: PendingMilestone
    var mac: Bool
    static func == (a: MilestoneTicket, b: MilestoneTicket) -> Bool { a.id == b.id }
}

/// Which surface celebrates what, now. Surfaces say when they're on screen (plain bookkeeping that redraws nothing);
/// the apps post a celebration, and the surface showing it plays it and says when its fill completes, which plays the
/// haptic and sound that go with it, once. If no surface starts it within `ReadyCelebration.startWithin`, they play
/// anyway, so they're never lost.
@MainActor
final class CelebrationCenter: ObservableObject {
    static let shared = CelebrationCenter()

    /// Finished transcripts celebrating now, by transcript.
    @Published private(set) var ready: [UUID: CelebrationTicket] = [:]
    /// The iPhone recorder's stop ring, filling and held until the recorder closes.
    @Published private(set) var ring: CelebrationTicket?
    /// The Record card's "Saved", while it shows.
    @Published private(set) var saved: CelebrationTicket?
    /// This week's milestone, while it shows.
    @Published private(set) var milestone: MilestoneTicket?

    /// The screenshot tour: a celebration stays at its end state until the tour clears it.
    var holdsEnd = false
    /// Whether Home takes a waiting milestone when it appears. The screenshot tour turns it off and shows its own.
    var milestonesAutomatic = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] != "1"

    private var open: [UUID: Int] = [:]
    private var rows: [UUID: Int] = [:]
    private var lastSwipe: Date?
    private var feedback: [UUID: () -> Void] = [:]
    private var started: Set<UUID> = []
    private var skips: Set<UUID> = []
    private var readied: Set<UUID> = []

    // Where things are.

    func transcriptAppeared(_ id: UUID) { open[id, default: 0] += 1 }
    func transcriptLeft(_ id: UUID) { open[id] = max(0, (open[id] ?? 0) - 1) }
    func isOpen(_ id: UUID) -> Bool { (open[id] ?? 0) > 0 }
    func rowAppeared(_ id: UUID) { rows[id, default: 0] += 1 }
    func rowLeft(_ id: UUID) { rows[id] = max(0, (rows[id] ?? 0) - 1) }
    func rowOnScreen(_ id: UUID) -> Bool { (rows[id] ?? 0) > 0 }
    /// A row's swipe action ran (Delete, Pin): a row waits for it to settle before it starts (SwipeSettle).
    func swiped() { lastSwipe = Date() }
    var sinceSwipe: TimeInterval? { lastSwipe.map { Date().timeIntervalSince($0) } }
    /// The Mac's once per recording (the iPhone uses ReadyOnce, with its haptic).
    func firstReady(_ id: UUID) -> Bool { readied.insert(id).inserted }

    // Posting.

    /// A finished transcript celebrates on `surface`. `feedback` (the haptic and sound) plays when its fill completes.
    @discardableResult
    func celebrateReady(_ id: UUID, on surface: ReadySurface, tone: CelebrationTone, feedback: (() -> Void)?) -> CelebrationTicket {
        let t = CelebrationTicket(key: id, surface: surface, tone: tone)
        ready[id] = t
        arm(t, feedback)
        return t
    }

    /// The stop ring starts filling (iPhone). Its `.success` is PhoneState's, once the recording is saved; the recorder
    /// clears the ring as it closes.
    @discardableResult
    func fillRing(tone: CelebrationTone) -> CelebrationTicket {
        let t = CelebrationTicket(key: UUID(), tone: tone)
        ring = t
        return t
    }

    func clearRing() { ring = nil }

    /// "Saved" on Home's Record card, after `delay` (the recorder closing over it).
    func showSaved(after delay: TimeInterval) {
        let t = CelebrationTicket(key: UUID(), tone: .persimmon)
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            self?.saved = t
        }
    }

    /// Home appeared: the milestone waiting, if there is one, on This week. `feedback` plays as its fill completes.
    func showPendingMilestone(mac: Bool, weekShown: Bool, feedback: (() -> Void)?) {
        guard milestonesAutomatic, weekShown, milestone == nil, let p = MilestoneStore.shared.take() else { return }
        showMilestone(p, mac: mac, feedback: feedback)
    }

    func showMilestone(_ p: PendingMilestone, mac: Bool, feedback: (() -> Void)?) {
        let t = MilestoneTicket(milestone: p, mac: mac)
        milestone = t
        if let feedback { self.feedback[t.id] = feedback }
    }

    // What the surfaces say.

    /// A surface started showing celebration `id`.
    func didStart(_ id: UUID) { started.insert(id) }

    /// Celebration `id`'s fill completed (or a tap skipped to it): its haptic and sound play, once.
    func didFill(_ id: UUID) { feedback.removeValue(forKey: id)?() }

    /// A tap during celebration `id` jumps it to the end. Read by the burst as it plays (and by the recorder's close).
    func skip(_ id: UUID) { skips.insert(id) }
    func skipped(_ id: UUID) -> Bool { skips.contains(id) }

    /// Celebration `id` has finished: it no longer shows anywhere.
    func didFinish(_ id: UUID) {
        if let k = ready.first(where: { $0.value.id == id })?.key { ready[k] = nil }
        if saved?.id == id { saved = nil }
        if milestone?.id == id { milestone = nil }
        if ring?.id == id { ring = nil }
        feedback[id] = nil
        started.remove(id); skips.remove(id)
    }

    /// The screenshot tour: everything ends at once.
    func clearAll() {
        feedback = [:]; started = []; skips = []
        ready = [:]; ring = nil; saved = nil; milestone = nil
    }

    private func arm(_ t: CelebrationTicket, _ f: (() -> Void)?) {
        guard let f else { return }
        feedback[t.id] = f
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ReadyCelebration.startWithin * 1_000_000_000))
            guard let self, !self.started.contains(t.id) else { return }
            // No surface took it (the row scrolled away, the screen closed): the feedback plays now, and it's gone.
            self.didFill(t.id)
            self.didFinish(t.id)
        }
    }
}

extension MilestoneStore {
    /// This device's milestones. The screenshot tour keeps its own.
    static let shared = MilestoneStore(defaults: .standard,
                                       suffix: ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1" ? ".uitest" : "")
}

// MARK: - Burst

/// What a celebration's pieces read as it plays. Hosts draw from it only while `active`.
struct BurstState: Equatable {
    /// The fill's progress, 0 to 1 (a scale along its axis, or a ring's trim).
    var fill: CGFloat = 0
    /// The bounce.
    var scale: CGFloat = 1
    /// The opacity of what the word replaces (a meta line, the ready chip, the processing card's text).
    var old: Double = 1
    /// The word's opacity, and how far below its place it is.
    var word: Double = 0
    var rise: CGFloat = 0
    /// The fill has covered (a toast's words turn to ink once it has).
    var covered = false
    /// From the start to the end of the hold.
    var active = false
    /// The part a tap skips.
    var bursting = false
    /// The whole overlay's opacity: it fades out at the end of a word's hold (the open transcript's Ready overlay).
    var shown: Double = 1

    static let idle = BurstState()
}

/// How one surface's celebration plays.
struct BurstScript {
    var size: CelebrationSize
    /// A fill before the word (the Record card's "Saved" has none: the ring already filled).
    var fills = true
    /// The word, when it has one.
    var word: String? = nil
    /// How long the end state holds after the burst before it ends; nil holds until the ticket goes (the stop ring,
    /// the toast).
    var hold: TimeInterval? = nil
    /// A Library row waits for a swipe to settle before it starts.
    var waitsForSwipe = false

    /// A Library row: the badge fills, "Ready" holds 1.6 s from when it shows.
    static let row = BurstScript(size: .medium, word: CelebrationWord.ready, hold: CelebrationTiming.wordHold, waitsForSwipe: true)
    /// The open transcript: the text and controls are already there; the fill and "Ready" play over the top of the text
    /// (`ReadyOverlay`), hold briefly, and fade.
    static let transcript = BurstScript(size: .medium, word: CelebrationWord.ready, hold: CelebrationTiming.readyOverlayHold)
    /// The toast: the fill sweeps it and stays while it shows.
    static let toast = BurstScript(size: .medium)
    /// The iPhone recorder's stop ring.
    static let ring = BurstScript(size: .small)
    /// "Saved" on the Record card for 1.6 s.
    static let saved = BurstScript(size: .small, fills: false, word: CelebrationWord.saved, hold: CelebrationTiming.wordHold)

    /// How long the hold lasts after the burst, so a word's hold counts from when it appeared.
    func holdAfterBurst(_ motion: CelebrationMotion) -> TimeInterval? {
        guard let hold else { return nil }
        guard word != nil, hold == CelebrationTiming.wordHold else { return hold }
        if motion == .fade { return hold }
        // The word appeared `wordDelay` after the fill; the burst ends `afterFill` after it.
        return max(0, hold - (CelebrationTiming.afterFill - CelebrationTiming.wordDelay))
    }
}

/// Waits `seconds` in frame-sized steps, so a tap (`CelebrationCenter.skip`) or the view going away ends it early.
/// True when it ran its full time.
@MainActor
func celebrationWait(_ seconds: TimeInterval, _ id: UUID) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if Task.isCancelled || CelebrationCenter.shared.skipped(id) { return false }
        try? await Task.sleep(nanoseconds: 16_000_000)
    }
    return !Task.isCancelled
}

/// Plays one surface's celebration and hands its state to `content`, which draws the pieces (as overlays and
/// opacities on what's already there). Runs again for each new ticket, keyed to its id; nil shows nothing.
struct CelebrationBurst<Content: View>: View {
    var ticket: CelebrationTicket?
    var script: BurstScript
    /// The burst ended its hold; nil lets the center drop the ticket (`CelebrationCenter.didFinish`).
    var onEnded: ((CelebrationTicket) -> Void)? = nil
    @ViewBuilder var content: (BurstState) -> Content

    @State private var state = BurstState()
    @Environment(\.limitMotion) private var limited

    var body: some View {
        content(state)
            // A tap during the burst jumps to the end, and a tap during the hold ends it; the host's own taps and gestures
            // still work, and outside a celebration there's no gesture at all (an Optional gesture keeps the view's
            // structure the same either way).
            .simultaneousGesture(state.active ? TapGesture().onEnded { if let t = ticket { CelebrationCenter.shared.skip(t.id) } } : nil)
            .task(id: ticket?.id) { await play() }
    }

    private func play() async {
        guard let ticket else {
            if state.active { withAnimation(.easeOut(duration: CelebrationTiming.fadeOut)) { state = BurstState() } }
            return
        }
        let T = CelebrationTiming.self
        let center = CelebrationCenter.shared
        let motion = CelebrationMotion.of(limited: limited)
        if script.waitsForSwipe {
            let w = SwipeSettle.wait(sinceSwipe: center.sinceSwipe)
            if w > 0 { try? await Task.sleep(nanoseconds: UInt64(w * 1_000_000_000)) }
        }
        guard !Task.isCancelled else { return }
        center.didStart(ticket.id)
        state = BurstState(fill: 0, scale: 1, old: 1, word: 0, rise: CGFloat(script.size.rise), covered: false, active: true, bursting: true)
        var full = true
        if motion == .fade {
            withAnimation(.easeOut(duration: T.reduced)) { state.fill = 1; state.old = script.word == nil ? 1 : 0; state.word = 1; state.rise = 0 }
            full = await celebrationWait(T.reduced, ticket.id)
            state.covered = true
            center.didFill(ticket.id)
        } else {
            if script.fills {
                withAnimation(.timingCurve(T.fillCurve.x1, T.fillCurve.y1, T.fillCurve.x2, T.fillCurve.y2, duration: T.fill)) {
                    state.fill = 1
                }
                full = await celebrationWait(T.fill, ticket.id)
                // Covered: what sits on the fill (a toast's words) turns to its ink now, not while the fill is still
                // sweeping under it.
                withAnimation(.easeOut(duration: T.oldFade)) { state.covered = true }
            } else {
                state.fill = 1; state.covered = true
            }
            center.didFill(ticket.id)
            if full {
                let target = CGFloat(T.bounceTarget(peak: script.size.peak))
                withAnimation(.spring(duration: T.bounceDuration, bounce: T.bounceBounce)) { state.scale = target }
                if script.word != nil {
                    withAnimation(.easeOut(duration: T.oldFade)) { state.old = 0 }
                    withAnimation(.spring(duration: T.riseDuration, bounce: T.riseBounce).delay(T.wordDelay)) { state.rise = 0 }
                    withAnimation(.easeOut(duration: T.wordFade).delay(T.wordDelay)) { state.word = 1 }
                }
                full = await celebrationWait(T.bounceTurn, ticket.id)
                if full {
                    withAnimation(.spring(duration: T.bounceDuration, bounce: T.bounceBounce)) { state.scale = 1 }
                    full = await celebrationWait(T.afterFill - T.bounceTurn, ticket.id)
                }
            }
        }
        if Task.isCancelled { return }
        if !full {
            // A tap: straight to the end state, with no animation.
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                state.fill = 1; state.covered = true; state.scale = 1; state.rise = 0
                state.old = script.word == nil ? 1 : 0; state.word = 1
            }
            center.didFill(ticket.id)
        }
        state.bursting = false
        if let word = script.word { AccessibilityNotification.Announcement(word).post() }
        guard !center.holdsEnd, let hold = script.holdAfterBurst(motion) else { return }
        // Every hold ends early on a tap (nothing waits for a celebration).
        _ = await celebrationWait(hold, ticket.id)
        guard !Task.isCancelled, !center.holdsEnd else { return }
        if script.word != nil {
            // "Ready" and "Saved" go; the line they covered comes back, and the Ready overlay fades.
            withAnimation(.easeOut(duration: T.fadeOut)) { state.word = 0; state.old = 1; state.shown = 0 }
            try? await Task.sleep(nanoseconds: UInt64(T.fadeOut * 1_000_000_000))
            guard !Task.isCancelled else { return }
        }
        state.active = false
        withAnimation(.easeOut(duration: 0.24)) {
            if let onEnded { onEnded(ticket) } else { center.didFinish(ticket.id) }
        }
    }
}

// MARK: - The open transcript's Ready

/// A transcript that finished while it's open (DESIGN.md §7, Celebrations; `ReadyReveal`): its text, tabs, and player
/// are already showing, and this plays on top of the text's first lines: the tint sweeps a band, "Ready" rises onto
/// it, it holds briefly, and it fades. It never takes a tap or changes layout; a tap on the text under it ends it
/// (`celebrationTapSkips`).
struct ReadyOverlay: View {
    var ticket: CelebrationTicket?
    var radius: CGFloat
    var height: CGFloat = 52
    var wordSize: CGFloat = 17

    var body: some View {
        CelebrationBurst(ticket: ticket, script: .transcript) { burst in
            Color.clear
                .frame(maxWidth: .infinity).frame(height: height)
                .celebrationWord(burst.active ? CelebrationWord.ready : nil, state: burst, size: wordSize)
                .padding(.horizontal, 14)
                .celebrationSweep(ticket?.tone.tint ?? Refined.persimmonTint, state: burst, radius: radius)
                .scaleEffect(burst.active ? burst.scale : 1)
                .opacity(burst.active ? burst.shown : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Pieces

extension CelebrationTone {
    var hue: RefinedHue {
        switch self {
        case .persimmon: return .persimmon
        case .sage: return .sage
        case .petal: return .petal
        case .butter: return .butter
        }
    }
    /// The full fill (a badge's, a toast's, a milestone's), with ink on it in both appearances.
    var fill: Color { Refined.badge(hue) }
    /// The pale tint (the processing card's fill, a transcribing badge).
    var tint: Color {
        switch self {
        case .persimmon: return Refined.persimmonTint
        case .sage: return Refined.sageTint
        case .petal: return Refined.petalTint
        case .butter: return Refined.butterTint
        }
    }
}

/// The word: an ink pill in the serif face, reader white on ink in both appearances. Decorative: VoiceOver hears the
/// word once from the burst.
struct CelebrationPill: View {
    var text: String
    @ScaledMetric private var size: CGFloat

    init(_ text: String, size: CGFloat = 15) {
        self.text = text
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .serif))
            .foregroundStyle(Refined.lift)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, size * 0.8).padding(.vertical, size * 0.18)
            .background(Refined.onFill, in: Capsule())
            .accessibilityHidden(true)
    }
}

extension View {
    /// Puts the word on a burst: rising into place, fading in, never taking a tap.
    @MainActor func celebrationWord(_ text: String?, state: BurstState, size: CGFloat = 15, alignment: Alignment = .leading) -> some View {
        overlay(alignment: alignment) {
            if let text, state.active {
                CelebrationPill(text, size: size)
                    .offset(y: state.rise)
                    .opacity(state.word)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A fill that sweeps from the leading edge behind this view, past its edges by `outset`, never changing its size.
    @MainActor func celebrationSweep(_ color: Color, state: BurstState, radius: CGFloat, outset: CGFloat = 0) -> some View {
        background {
            if state.active {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color)
                    .scaleEffect(x: max(0.0001, state.fill), y: 1, anchor: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .padding(-outset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Milestone

/// This week's milestone (big, butter): the fill sweeps the card, "On this iPhone" and the old total show on it, only
/// the changing digits change in place to the new total, then the pill names the milestone; after 2.4 s the card comes
/// back. Under Limit animation a 0.2 s crossfade to the end state. An overlay on This week in the card's own shape that
/// never takes a tap: the card's tap skips it (`celebrationTapSkips`).
struct MilestoneBurst: View {
    var ticket: MilestoneTicket
    var radius: CGFloat
    @State private var fill: CGFloat = 0
    @State private var shown: Double = 1
    @State private var label: Double = 0
    @State private var total: Int
    @State private var pill: Double = 0
    @State private var rise: CGFloat = CGFloat(CelebrationSize.big.rise)
    @State private var scale: CGFloat = 1
    @Environment(\.limitMotion) private var limited

    init(ticket: MilestoneTicket, radius: CGFloat) {
        self.ticket = ticket
        self.radius = radius
        _total = State(initialValue: ticket.milestone.from)
    }

    private var labelText: some View { Text(CelebrationWord.onDevice(mac: ticket.mac)).refinedFont(.hint) }
    private func totalText(_ size: CGFloat = RefinedPlatform.mac ? 18 : 19.5) -> some View {
        Text(CelebrationWord.number(total))
            .font(.system(size: size, weight: .bold)).monospacedDigit()
            .contentTransition(.numericText(value: Double(total)))
    }
    private var pillView: some View {
        CelebrationPill(CelebrationWord.milestone(ticket.milestone.threshold), size: 16)
            .offset(y: rise).opacity(pill)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .leading) {
            shape.fill(CelebrationTone.milestone.fill)
                .scaleEffect(x: max(0.0001, fill), y: 1, anchor: .leading)
                .clipShape(shape)
            // One row where the card is wide (iPhone, a wide Mac Home); stacked where it's narrow (the Mac's This week
            // card beside Recent), so the label and total never truncate.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    labelText.fixedSize()
                    totalText().fixedSize()
                    Spacer(minLength: 8)
                    pillView
                }
                .padding(.leading, 15).padding(.trailing, 9)
                VStack(alignment: .leading, spacing: 6) {
                    labelText
                    totalText(28)
                    pillView
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .lineLimit(1)
            .foregroundStyle(Refined.onFill)
            .opacity(label)
        }
        .scaleEffect(scale)
        .opacity(shown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: ticket.id) { await play() }
    }

    private func play() async {
        let T = CelebrationTiming.self
        let center = CelebrationCenter.shared
        let id = ticket.id
        let to = ticket.milestone.to
        center.didStart(id)
        var full = true
        if CelebrationMotion.of(limited: limited) == .fade {
            withAnimation(.easeOut(duration: T.reduced)) { fill = 1; label = 1; total = to; pill = 1; rise = 0 }
            full = await celebrationWait(T.reduced, id)
            center.didFill(id)
        } else {
            withAnimation(.timingCurve(T.fillCurve.x1, T.fillCurve.y1, T.fillCurve.x2, T.fillCurve.y2, duration: T.fill)) { fill = 1 }
            full = await celebrationWait(T.fill, id)
            if full {
                // The old total shows on the fill as it lands.
                withAnimation(.easeOut(duration: T.milestoneLabelFade)) { label = 1 }
                center.didFill(id)
                withAnimation(.spring(duration: T.bounceDuration, bounce: T.bounceBounce)) { scale = CGFloat(T.bounceTarget(peak: CelebrationSize.big.peak)) }
                full = await celebrationWait(T.bounceTurn, id)
            }
            if full {
                withAnimation(.spring(duration: T.bounceDuration, bounce: T.bounceBounce)) { scale = 1 }
                full = await celebrationWait(T.milestoneDigitsAfter - T.bounceTurn, id)
            }
            if full {
                // Only the digits that change roll, in place.
                withAnimation(.smooth(duration: T.milestoneDigits)) { total = to }
                full = await celebrationWait(T.milestonePillAfter, id)
            }
            if full {
                withAnimation(.spring(duration: T.riseDuration, bounce: T.riseBounce)) { rise = 0 }
                withAnimation(.easeOut(duration: T.wordFade)) { pill = 1 }
                full = await celebrationWait(T.milestoneAfterPill, id)
            }
        }
        if Task.isCancelled { return }
        if !full {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { fill = 1; label = 1; total = to; pill = 1; rise = 0; scale = 1 }
            center.didFill(id)
        }
        AccessibilityNotification.Announcement(CelebrationWord.milestone(ticket.milestone.threshold)).post()
        guard !center.holdsEnd else { return }
        // The hold ends early on a tap on the card (`celebrationTapSkips`).
        _ = await celebrationWait(T.milestoneHold, id)
        guard !Task.isCancelled, !center.holdsEnd else { return }
        withAnimation(.easeOut(duration: T.milestoneFadeOut)) { shown = 0 }
        try? await Task.sleep(nanoseconds: UInt64(T.milestoneFadeOut * 1_000_000_000))
        guard !Task.isCancelled else { return }
        center.didFinish(id)
    }
}

extension View {
    /// This week's milestone over the card, while one shows.
    @MainActor func milestoneOverlay(_ ticket: MilestoneTicket?, radius: CGFloat) -> some View {
        overlay {
            if let ticket { MilestoneBurst(ticket: ticket, radius: radius).id(ticket.id) }
        }
    }

    /// A tap on the host during celebration `id`'s burst jumps it to the end, alongside the host's own tap.
    @MainActor func celebrationTapSkips(_ id: UUID?) -> some View {
        simultaneousGesture(id.map { id in TapGesture().onEnded { CelebrationCenter.shared.skip(id) } })
    }
}
