import Foundation

// Celebrations' pure rules (DESIGN.md §7, Celebrations), for the Mac, the iPhone, and the Apple Watch: the timings and
// sizes, the words, which surface shows a finished transcript, whether finishing a recording celebrates, the word
// milestones and their queue, and the Library row's start after a swipe. Foundation only, so the Linux tests
// (mac/tools/test-celebrations.sh) and both self-tests check them (CelebrationChecks.swift). The views read them
// (Views/Celebration.swift); nothing here draws.
//
// Three moments celebrate: finishing a recording (small), a transcript finishing (medium), and a word milestone (big).
// Each is rare, plays once, and is an overlay, so no row or card changes size. Nothing waits for one: content and
// controls show at once, and every hold ends early on a tap (Tim, November 7, 2026). Limit animation and Reduce Motion
// get a 0.2 s crossfade to the end state with the word, and VoiceOver hears the word once.

/// How big a celebration is: how far it bounces and how far its word rises.
enum CelebrationSize: String, CaseIterable, Sendable {
    /// Finishing a recording: the stop ring and the Record card's "Saved".
    case small
    /// A transcript finishing: the open transcript, a Library row, or the toast.
    case medium
    /// A word milestone on This week.
    case big

    /// The scale the bounce reaches before it settles back to 1.
    var peak: Double {
        switch self {
        case .small: return 1.035
        case .medium: return 1.04
        case .big: return 1.05
        }
    }

    /// How far below its place the word starts before it rises in, in points.
    var rise: Double { self == .small ? 8 : 10 }
}

/// What a celebration does instead of moving when motion is limited.
enum CelebrationMotion: String, Sendable {
    /// The fill, the bounce, and the word rising.
    case full
    /// A 0.2 s crossfade to the end state, with the word; no scale and no offset.
    case fade

    /// Limit animation (or the system's Reduce Motion) turns every celebration into the crossfade.
    static func of(limited: Bool) -> CelebrationMotion { limited ? .fade : .full }
}

/// The timings, from the approved mockup (November 7, 2026).
enum CelebrationTiming {
    /// The fill: slow, then fast.
    static let fill: TimeInterval = 0.42
    /// The fill's curve, as a cubic Bézier's control points (`.timingCurve(0.7, 0, 0.84, 0.35, duration: 0.42)`).
    static let fillCurve: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.7, 0, 0.84, 0.35)
    /// The bounce: a spring of this duration and bounce out to the size's peak and back to 1.
    static let bounceDuration: TimeInterval = 0.28
    static let bounceBounce = 0.5
    /// When the bounce turns back toward 1, after it starts.
    static let bounceTurn: TimeInterval = 0.11
    /// The word: it rises on this spring as it fades in.
    static let riseDuration: TimeInterval = 0.45
    static let riseBounce = 0.35
    /// The word starts this long after the fill ends, and fades in over `wordFade`.
    static let wordDelay: TimeInterval = 0.09
    static let wordFade: TimeInterval = 0.18
    /// What the word replaces fades out over this, when the fill ends.
    static let oldFade: TimeInterval = 0.12
    /// The burst (the part a tap skips) ends this long after the fill.
    static let afterFill: TimeInterval = 0.5
    static var burst: TimeInterval { fill + afterFill }
    /// Limit animation's crossfade to the end state.
    static let reduced: TimeInterval = 0.2
    /// "Ready" on a Library row and "Saved" on the Record card stay this long from when they appear.
    static let wordHold: TimeInterval = 1.6
    /// The open transcript: the Ready overlay holds this long after the burst, on top of the text that's already there,
    /// then fades. A tap ends it sooner; nothing waits for it.
    static let readyOverlayHold: TimeInterval = 0.6
    /// The word and the restored line fade over this when the hold ends.
    static let fadeOut: TimeInterval = 0.2
    /// "Saved" waits this long for the recorder to finish closing over Home.
    static let afterSheet: TimeInterval = 0.35
    /// A milestone: the old total shows on the fill as it fades in over `milestoneLabelFade`, the digits change
    /// `milestoneDigitsAfter` after the fill over `milestoneDigits`, the word follows `milestonePillAfter` later, and the
    /// whole card holds `milestoneHold` after the burst before it fades over `milestoneFadeOut`.
    static let milestoneLabelFade: TimeInterval = 0.14
    static let milestoneDigitsAfter: TimeInterval = 0.26
    static let milestoneDigits: TimeInterval = 0.32
    static let milestonePillAfter: TimeInterval = 0.26
    static let milestoneAfterPill: TimeInterval = 0.52
    static var milestoneBurst: TimeInterval { fill + milestoneDigitsAfter + milestonePillAfter + milestoneAfterPill }
    static let milestoneHold: TimeInterval = 2.4
    static let milestoneFadeOut: TimeInterval = 0.3

    /// How long a word shows before the hold ends, from the start of the celebration: the fill, then the word's delay,
    /// then the hold (the crossfade, then the hold, under Limit animation).
    static func wordEnds(_ motion: CelebrationMotion) -> TimeInterval {
        motion == .fade ? reduced + wordHold : fill + wordDelay + wordHold
    }

    /// The fill's progress at time `t` (0...1) on its curve: slow, then fast. For drawings that read the fill from the
    /// clock rather than from an animation (the watch's ring), and for the checks.
    static func fillProgress(at t: TimeInterval) -> Double {
        let x = min(1, max(0, t / fill))
        return bezier(x, fillCurve.x1, fillCurve.y1, fillCurve.x2, fillCurve.y2)
    }

    /// A CSS-style cubic Bézier timing function: y for x.
    static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
        let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
        func sx(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        func sy(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            if sx(t) < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sy(t)
    }

    /// The bounce: SwiftUI's `.spring(duration:bounce:)` (stiffness (2π/d)², damping 4π(1 − bounce)/d, mass 1),
    /// aimed at `target` and turned back toward 1 at `bounceTurn`. Returns the highest scale it reaches.
    static func bounceTop(target: Double) -> Double {
        let d = bounceDuration
        let k = pow(2 * Double.pi / d, 2), c = 4 * Double.pi * (1 - bounceBounce) / d
        var x = 1.0, v = 0.0, t = 0.0, top = 1.0
        let dt = 1.0 / 2400
        while t < 2 {
            let goal = t < bounceTurn ? target : 1
            let a = -k * (x - goal) - c * v
            v += a * dt; x += v * dt; t += dt
            top = max(top, x)
        }
        return top
    }

    /// Where the bounce aims so it tops out at exactly `peak` once it turns back at `bounceTurn` (the mockup scales its
    /// spring the same way): the spring reaches only part of the way before it turns.
    static func bounceTarget(peak: Double) -> Double {
        let reach = bounceTop(target: 2) - 1
        return 1 + (peak - 1) / max(0.01, reach)
    }
}

/// The words, plain, with no exclamation points.
enum CelebrationWord {
    /// The Record card's chip after a recording is saved.
    static let saved = "Saved"
    /// A finished transcript: the open transcript's card and a Library row.
    static let ready = "Ready"

    /// A milestone: "Your first dictation", "10,000 words", "100,000 words".
    static func milestone(_ threshold: Int, locale: Locale = .current) -> String {
        threshold == 1 ? "Your first dictation" : "\(number(threshold, locale: locale)) words"
    }

    /// "10,000", grouped for the locale.
    static func number(_ n: Int, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// The label on a milestone's fill: totals are per device.
    static func onDevice(mac: Bool) -> String { mac ? "On this Mac" : "On this iPhone" }
}

/// A celebration's color: DESIGN.md §1's meanings, no new hues. A Library row's badge keeps its kind's own color; the
/// open transcript's card and the toast take the recording's source.
enum CelebrationTone: String, CaseIterable, Sendable {
    case persimmon, sage, petal, butter

    /// By `SourceKind`'s raw value: recordings persimmon, files and links sage, app audio petal, dictation butter.
    static func of(source raw: String) -> CelebrationTone {
        switch raw {
        case "file", "link": return .sage
        case "app": return .petal
        case "dictation": return .butter
        default: return .persimmon
        }
    }

    /// Word milestones are dictation's: butter.
    static let milestone = CelebrationTone.butter
}

/// Where a finished transcript celebrates: exactly one place, the first on screen of these.
enum ReadySurface: String, CaseIterable, Sendable {
    /// The transcript is open: its text and controls show at once, and the fill and "Ready" play over the top of the
    /// text as an overlay (`ReadyReveal`).
    case transcript
    /// Its row in the iPhone's Library is on screen: the badge's color grows from the center and the meta line reads
    /// "Ready" for 1.6 s.
    case libraryRow
    /// The "Transcript ready" toast: the fill sweeps it.
    case toast
}

enum ReadyCelebration {
    /// Which surface celebrates a transcript that just finished, or nil for none. A dictation pastes and a thought
    /// fills in its words on its page, so neither celebrates (the same rule as the transcription done sound,
    /// `SoundRules.transcriptDone`). It celebrates once per recording (Transcribe again doesn't), only with Verbose in
    /// front (the Mac: `NSApp.isActive`), and only where you can see it: the open transcript, then the iPhone's
    /// Library row, then the toast (which shows only for the last in a batch).
    static func surface(isDictation: Bool, isThought: Bool, first: Bool, foreground: Bool,
                        transcriptOpen: Bool, rowOnScreen: Bool, toastShows: Bool, phone: Bool) -> ReadySurface? {
        guard SoundRules.transcriptDone(isDictation: isDictation, isThought: isThought) != nil, first, foreground else { return nil }
        if transcriptOpen { return .transcript }
        if phone && rowOnScreen { return .libraryRow }
        if toastShows { return .toast }
        return nil
    }

    /// Whether "Transcript ready" shows: for the last in a batch, unless the open transcript or its Library row is
    /// already celebrating it (exactly one place says so; the row and the transcript open it themselves).
    static func toastShows(queueEmpty: Bool, surface: ReadySurface?) -> Bool {
        queueEmpty && (surface == nil || surface == .toast)
    }

    /// The ready haptic and sound wait for the fill when a surface celebrates, so they land with it; with nothing on
    /// screen they play at once.
    static func feedbackWaits(for surface: ReadySurface?) -> Bool { surface != nil }

    /// How long a surface may take to start before the haptic and sound play without it (the row scrolled away, the
    /// screen closed), so they're never lost.
    static let startWithin: TimeInterval = 1
}

/// A transcript that finishes while it's open (Tim, November 7, 2026): the text, the tabs, and the player show the
/// moment it's ready. The Ready fill and word play as an overlay on top of the text; they never hold back the content or
/// the controls, and a tap ends them.
enum ReadyReveal {
    /// The transcript's text and controls show as soon as it's ready, whether or not it's celebrating.
    static func showsContent(ready: Bool, celebrating: Bool) -> Bool { ready }
    /// The processing card shows only while it's processing; a celebration never keeps it up.
    static func showsProcessingCard(processing: Bool, celebrating: Bool) -> Bool { processing }
}

/// Where a Stop came from.
enum StopSource: String, Sendable {
    /// The iPhone recorder's Stop button, tapped.
    case recorderButton
    /// The Mac Home's recording card's Stop and transcribe, clicked.
    case homeCardClick
    /// The Mac thought bubble's disc, clicked.
    case bubbleClick
    /// A key (the Mac's ⌥⇧. or a thought's hotkey): keyboard actions never animate.
    case keyboard
    /// Anywhere else: the Live Activity, the Dynamic Island, the Action button, Siri, the tab bar's mini recorder, the
    /// Mac's menu bar, a call ending.
    case elsewhere
}

/// Whether finishing a recording celebrates, and how.
enum RecordingFinish {
    struct Plan: Equatable, Sendable {
        /// iPhone: the stop button's ring fills while "Saving…" shows.
        var ring = false
        /// iPhone: `.success` when the ring has filled and the recording is saved.
        var haptic = false
        /// Home's Record card chip reads "Saved" for 1.6 s with the small bounce.
        var savedChip = false
        /// The Mac: a thought's check glyph fills once (no bounce, no word).
        var thoughtCheck = false

        static let none = Plan()
    }

    /// The iPhone: only a tap on the recorder's Stop celebrates (the ring is under your finger). Discard never does:
    /// nothing bounces on a destructive action. A thought fills the ring but saves to its page quietly (its own sound
    /// says so), and "Saved" shows only when Home is under the recorder.
    static func phone(source: StopSource, discard: Bool, thought: Bool, homeUnderneath: Bool) -> Plan {
        guard source == .recorderButton, !discard else { return .none }
        return Plan(ring: true, haptic: !thought, savedChip: !thought && homeUnderneath, thoughtCheck: false)
    }

    /// The Mac: "Saved" on the Record card only when Home's recording card was on screen and its Stop was clicked; a
    /// thought's check fills only when the bubble was clicked. Never from a key, and never with Verbose in the
    /// background. The Mac has no haptics.
    static func mac(source: StopSource, thought: Bool, homeOnScreen: Bool, appActive: Bool) -> Plan {
        if thought { return Plan(thoughtCheck: source == .bubbleClick) }
        guard source == .homeCardClick, homeOnScreen, appActive else { return .none }
        return Plan(savedChip: true)
    }

    /// After the save: how long the recorder waits before it closes. The ring is decoration only: once the recording is
    /// saved, the recorder closes at once, whether or not the ring has finished filling, and `.success` plays then.
    static func closeDelay(saved: Bool) -> TimeInterval { 0 }
}

/// The Apple Watch's Saved on Watch: the ring trims and the check pops when you stopped it yourself; held still with
/// the wrist down (`isLuminanceReduced`), and a crossfade under Reduce Motion.
enum WatchSentMotion: String, Sendable {
    case burst, fade, still

    static func of(stoppedByYou: Bool, luminanceReduced: Bool, limited: Bool) -> WatchSentMotion {
        guard stoppedByYou, !luminanceReduced else { return .still }
        return limited ? .fade : .burst
    }
}

/// A Library row (iPhone) doesn't start a celebration while a swipe is settling: on iOS 27 a swipe action that removes
/// a row stutters if another animation starts with it.
enum SwipeSettle {
    static let window: TimeInterval = 0.6

    /// How long to wait before starting, given the time since the last swipe action (nil for none).
    static func wait(sinceSwipe: TimeInterval?) -> TimeInterval {
        guard let s = sinceSwipe, s >= 0 else { return 0 }
        return max(0, window - s)
    }
}

/// Word milestones: 1, 10,000, and 100,000 dictated words on this device (totals are per device, never synced: the
/// Mac's Activity log, the iPhone's dictation tally). Each celebrates once, ever, on This week at the next Home
/// appearance, never at paste time.
enum WordMilestones {
    static let thresholds = [1, 10_000, 100_000]
    /// A step bigger than this is a library arriving (a sync, a restore, the first count after an update), never one
    /// dictation: the thresholds it passes are marked celebrated without showing.
    static let largestStep = 5_000

    /// Every threshold in (old, new].
    static func passed(old: Int, new: Int) -> [Int] {
        thresholds.filter { $0 > old && $0 <= new }
    }

    /// The highest threshold in (old, new] not celebrated yet; nil when there's none.
    static func crossed(old: Int, new: Int, celebrated: Set<Int>) -> Int? {
        passed(old: old, new: new).filter { !celebrated.contains($0) }.max()
    }

    /// What a change in the total does: which threshold to show (nil for none) and which to mark celebrated. A big jump
    /// marks without showing.
    static func step(old: Int, new: Int, celebrated: Set<Int>) -> (show: Int?, mark: [Int]) {
        let fresh = passed(old: old, new: new).filter { !celebrated.contains($0) }
        guard !fresh.isEmpty else { return (nil, []) }
        if new - old > largestStep { return (nil, fresh) }
        return (fresh.max(), fresh)
    }
}

/// A milestone waiting for Home: the threshold, and the totals before and after (the old total shows on the fill, then
/// changes in place to the new one).
struct PendingMilestone: Codable, Equatable, Sendable {
    var threshold: Int
    var from: Int
    var to: Int

    /// A second milestone before Home appears: the higher one shows, from the first one's old total.
    func merged(with next: PendingMilestone) -> PendingMilestone {
        PendingMilestone(threshold: max(threshold, next.threshold), from: min(from, next.from), to: max(to, next.to))
    }
}

/// The milestones celebrated and the one waiting, in this device's defaults (never synced). Kept apart from the totals,
/// so resetting the Mac's Activity or deleting dictations never celebrates the same milestone again.
final class MilestoneStore: @unchecked Sendable {
    static let celebratedKey = "milestones.celebrated"
    static let pendingKey = "milestones.pending"

    private let defaults: UserDefaults
    private let suffix: String
    private let lock = NSLock()

    /// `suffix` keeps the screenshot tour's milestones apart from yours (".uitest").
    init(defaults: UserDefaults, suffix: String = "") {
        self.defaults = defaults
        self.suffix = suffix
    }

    var celebrated: Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return Set((defaults.array(forKey: Self.celebratedKey + suffix) as? [Int]) ?? [])
    }

    var pending: PendingMilestone? {
        lock.lock(); defer { lock.unlock() }
        return readPending()
    }

    /// The total went from `old` to `new`: queues the milestone it crossed (nil when it crossed none) and marks it
    /// celebrated at once, so it never comes back. Returns what's waiting now.
    @discardableResult
    func note(old: Int, new: Int) -> PendingMilestone? {
        lock.lock(); defer { lock.unlock() }
        let done = Set((defaults.array(forKey: Self.celebratedKey + suffix) as? [Int]) ?? [])
        let s = WordMilestones.step(old: old, new: new, celebrated: done)
        guard !s.mark.isEmpty else { return readPending() }
        defaults.set(Array(done.union(s.mark)).sorted(), forKey: Self.celebratedKey + suffix)
        guard let show = s.show else { return readPending() }
        let next = PendingMilestone(threshold: show, from: old, to: new)
        let waiting = readPending().map { $0.merged(with: next) } ?? next
        if let data = try? JSONEncoder().encode(waiting) { defaults.set(data, forKey: Self.pendingKey + suffix) }
        return waiting
    }

    /// Home appeared: the milestone waiting, which is then no longer waiting.
    func take() -> PendingMilestone? {
        lock.lock(); defer { lock.unlock() }
        let p = readPending()
        defaults.removeObject(forKey: Self.pendingKey + suffix)
        return p
    }

    /// Forgets everything (the screenshot tour, before and after its milestone).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.celebratedKey + suffix)
        defaults.removeObject(forKey: Self.pendingKey + suffix)
    }

    private func readPending() -> PendingMilestone? {
        defaults.data(forKey: Self.pendingKey + suffix).flatMap { try? JSONDecoder().decode(PendingMilestone.self, from: $0) }
    }
}
