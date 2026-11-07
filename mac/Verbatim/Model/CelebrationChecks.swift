import Foundation

/// Celebrations' rules (CelebrationRules.swift), checked by the Linux tests (`mac/tools/test-celebrations.sh`) and by
/// both apps' self-tests. `check` logs PASS or FAIL.
enum CelebrationChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let T = CelebrationTiming.self
        // Timings and sizes, as approved.
        check("celebrations: the fill is 0.42 s on (0.7, 0, 0.84, 0.35), slow then fast",
              T.fill == 0.42 && T.fillCurve.x1 == 0.7 && T.fillCurve.y1 == 0 && T.fillCurve.x2 == 0.84 && T.fillCurve.y2 == 0.35
              && T.fillProgress(at: T.fill / 2) < 0.25 && T.fillProgress(at: 0) == 0 && T.fillProgress(at: T.fill) == 1)
        var rising = true, last = -1.0
        for i in 0...42 { let p = T.fillProgress(at: Double(i) / 100); if p < last { rising = false }; last = p }
        check("celebrations: the fill only moves forward", rising)
        check("celebrations: the bounce is a 0.28 s spring at 0.5, the word's rise 0.45 s at 0.35",
              T.bounceDuration == 0.28 && T.bounceBounce == 0.5 && T.riseDuration == 0.45 && T.riseBounce == 0.35)
        check("celebrations: small, medium, and big bounce to 1.035, 1.04, and 1.05",
              CelebrationSize.small.peak == 1.035 && CelebrationSize.medium.peak == 1.04 && CelebrationSize.big.peak == 1.05)
        let tops = CelebrationSize.allCases.map { abs(T.bounceTop(target: T.bounceTarget(peak: $0.peak)) - $0.peak) }
        check("celebrations: the bounce, aimed and turned back, tops out at each size's peak", tops.allSatisfy { $0 < 0.0005 })
        check("celebrations: a burst lasts about a second, never longer than 1.2 s",
              T.burst >= 0.9 && T.burst <= 1.2 && T.milestoneBurst <= 1.6)
        check("celebrations: Limit animation is a 0.2 s crossfade", CelebrationMotion.of(limited: true) == .fade
              && CelebrationMotion.of(limited: false) == .full && T.reduced == 0.2)
        check("celebrations: Ready and Saved hold 1.6 s from when they appear",
              T.wordHold == 1.6 && abs(T.wordEnds(.full) - (T.fill + T.wordDelay + 1.6)) < 0.0001 && abs(T.wordEnds(.fade) - 1.8) < 0.0001)

        // Words: plain, sentence case, no exclamation points.
        let en = Locale(identifier: "en_US")
        let words = [CelebrationWord.saved, CelebrationWord.ready, CelebrationWord.milestone(1, locale: en),
                     CelebrationWord.milestone(10_000, locale: en), CelebrationWord.milestone(100_000, locale: en)]
        check("celebrations: the words are Saved, Ready, Your first dictation, 10,000 words, and 100,000 words",
              words == ["Saved", "Ready", "Your first dictation", "10,000 words", "100,000 words"])
        check("celebrations: no word shouts", words.allSatisfy { !$0.contains("!") && !$0.contains("\u{2014}") })
        check("celebrations: the milestone's label says the total is this device's",
              CelebrationWord.onDevice(mac: true) == "On this Mac" && CelebrationWord.onDevice(mac: false) == "On this iPhone")

        // Colors: DESIGN.md §1's meanings.
        check("celebrations: recordings persimmon, files and links sage, app audio petal, milestones butter",
              CelebrationTone.of(source: "voiceMemo") == .persimmon && CelebrationTone.of(source: "file") == .sage
              && CelebrationTone.of(source: "link") == .sage && CelebrationTone.of(source: "app") == .petal
              && CelebrationTone.milestone == .butter && CelebrationTone.of(source: "something new") == .persimmon)

        // A transcript finishing: exactly one place, the first on screen.
        func surface(dictation: Bool = false, thought: Bool = false, first: Bool = true, front: Bool = true,
                     open: Bool = false, row: Bool = false, toast: Bool = true, phone: Bool = true) -> ReadySurface? {
            ReadyCelebration.surface(isDictation: dictation, isThought: thought, first: first, foreground: front,
                                     transcriptOpen: open, rowOnScreen: row, toastShows: toast, phone: phone)
        }
        check("celebrations: the open transcript comes first, then the Library row, then the toast",
              surface(open: true, row: true) == .transcript && surface(row: true) == .libraryRow && surface() == .toast)
        check("celebrations: the Mac has no Library row celebration", surface(row: true, phone: false) == .toast
              && surface(open: true, row: true, phone: false) == .transcript)
        check("celebrations: a dictation and a thought never celebrate (the transcription done sound's rule)",
              surface(dictation: true, open: true) == nil && surface(thought: true, row: true) == nil
              && surface(dictation: true) == nil)
        check("celebrations: a keyboard dictation (a dictation, even after Retry) never celebrates",
              surface(dictation: true, open: true, row: true, toast: true) == nil)
        check("celebrations: once per recording, and only in front",
              surface(first: false, open: true) == nil && surface(front: false, open: true) == nil)
        check("celebrations: the toast stays away while the transcript or its row celebrates, and shows for the last in a batch otherwise",
              !ReadyCelebration.toastShows(queueEmpty: true, surface: .transcript) && !ReadyCelebration.toastShows(queueEmpty: true, surface: .libraryRow)
              && ReadyCelebration.toastShows(queueEmpty: true, surface: .toast) && ReadyCelebration.toastShows(queueEmpty: true, surface: nil)
              && !ReadyCelebration.toastShows(queueEmpty: false, surface: nil))
        check("celebrations: nothing on screen and no toast (a batch) celebrates nowhere, so the haptic plays at once",
              surface(toast: false) == nil && !ReadyCelebration.feedbackWaits(for: nil)
              && ReadyCelebration.feedbackWaits(for: .libraryRow) && ReadyCelebration.startWithin <= 1)

        // Finishing a recording.
        let F = RecordingFinish.self
        check("celebrations: a tap on the iPhone recorder's Stop fills the ring, plays success, and shows Saved over Home",
              F.phone(source: .recorderButton, discard: false, thought: false, homeUnderneath: true)
              == RecordingFinish.Plan(ring: true, haptic: true, savedChip: true, thoughtCheck: false))
        check("celebrations: Saved shows only with Home under the recorder",
              F.phone(source: .recorderButton, discard: false, thought: false, homeUnderneath: false).savedChip == false
              && F.phone(source: .recorderButton, discard: false, thought: false, homeUnderneath: false).haptic)
        check("celebrations: Discard never celebrates", F.phone(source: .recorderButton, discard: true, thought: false, homeUnderneath: true) == .none)
        check("celebrations: a stop from the Live Activity, the Island, the Action button, or the mini recorder doesn't celebrate",
              F.phone(source: .elsewhere, discard: false, thought: false, homeUnderneath: true) == .none
              && F.phone(source: .keyboard, discard: false, thought: false, homeUnderneath: true) == .none)
        check("celebrations: an iPhone thought fills the ring, with no success and no Saved",
              F.phone(source: .recorderButton, discard: false, thought: true, homeUnderneath: true)
              == RecordingFinish.Plan(ring: true, haptic: false, savedChip: false, thoughtCheck: false))
        check("celebrations: the Mac shows Saved only for a click on Home's recording card, in front",
              F.mac(source: .homeCardClick, thought: false, homeOnScreen: true, appActive: true).savedChip
              && F.mac(source: .keyboard, thought: false, homeOnScreen: true, appActive: true) == .none
              && F.mac(source: .homeCardClick, thought: false, homeOnScreen: false, appActive: true) == .none
              && F.mac(source: .homeCardClick, thought: false, homeOnScreen: true, appActive: false) == .none
              && F.mac(source: .elsewhere, thought: false, homeOnScreen: true, appActive: true) == .none)
        check("celebrations: a Mac thought fills its check only when the bubble was clicked, never with a bounce or word",
              F.mac(source: .bubbleClick, thought: true, homeOnScreen: false, appActive: false) == RecordingFinish.Plan(thoughtCheck: true)
              && F.mac(source: .keyboard, thought: true, homeOnScreen: true, appActive: true) == .none)
        check("celebrations: the recorder closes as soon as the recording is saved; the ring is decoration only",
              F.closeDelay(saved: true) == 0 && F.closeDelay(saved: false) == 0)

        // A transcript that finishes while it's open: the text and controls show at once (Tim, November 7, 2026).
        check("celebrations: a ready transcript shows its text and controls at once, celebrating or not",
              ReadyReveal.showsContent(ready: true, celebrating: true) && ReadyReveal.showsContent(ready: true, celebrating: false)
              && !ReadyReveal.showsContent(ready: false, celebrating: true))
        check("celebrations: a celebration never keeps the processing card up",
              !ReadyReveal.showsProcessingCard(processing: false, celebrating: true) && ReadyReveal.showsProcessingCard(processing: true, celebrating: false))
        check("celebrations: the Ready overlay is brief (under 2 s from the fill to its end)",
              T.burst + T.readyOverlayHold + T.fadeOut < 2)

        // The watch.
        check("celebrations: the watch's ring and check move only when you stopped it, held still with the wrist down",
              WatchSentMotion.of(stoppedByYou: true, luminanceReduced: false, limited: false) == .burst
              && WatchSentMotion.of(stoppedByYou: true, luminanceReduced: false, limited: true) == .fade
              && WatchSentMotion.of(stoppedByYou: true, luminanceReduced: true, limited: false) == .still
              && WatchSentMotion.of(stoppedByYou: false, luminanceReduced: false, limited: false) == .still)

        // Swipes.
        check("celebrations: a row waits for a swipe to settle",
              SwipeSettle.wait(sinceSwipe: nil) == 0 && abs(SwipeSettle.wait(sinceSwipe: 0.2) - 0.4) < 0.0001 && SwipeSettle.wait(sinceSwipe: 3) == 0)

        // Milestones.
        let M = WordMilestones.self
        check("celebrations: milestones at 1, 10,000, and 100,000 words", M.thresholds == [1, 10_000, 100_000])
        check("celebrations: crossing a threshold names it; landing on it counts",
              M.crossed(old: 0, new: 12, celebrated: []) == 1 && M.crossed(old: 9_963, new: 10_000, celebrated: []) == 10_000
              && M.crossed(old: 9_999, new: 10_040, celebrated: [1]) == 10_000 && M.crossed(old: 10_000, new: 10_040, celebrated: []) == nil)
        check("celebrations: a celebrated milestone never comes back",
              M.crossed(old: 0, new: 5, celebrated: [1]) == nil && M.crossed(old: 99_990, new: 100_020, celebrated: [100_000]) == nil)
        check("celebrations: nothing crossed, nothing shown", M.crossed(old: 20, new: 900, celebrated: []) == nil
              && M.step(old: 20, new: 900, celebrated: []).show == nil && M.step(old: 20, new: 900, celebrated: []).mark.isEmpty)
        let jump = M.step(old: 0, new: 80_000, celebrated: [])
        check("celebrations: a library arriving at once (a sync) marks its milestones without showing them",
              jump.show == nil && jump.mark == [1, 10_000])
        check("celebrations: going down (a reset) shows nothing", M.step(old: 50_000, new: 0, celebrated: []).show == nil)

        // The store: queue at the count, show at Home, never twice, apart from the totals.
        let suite = "celebration-checks-\(UUID().uuidString)"
        if let d = UserDefaults(suiteName: suite) {
            let store = MilestoneStore(defaults: d, suffix: ".check")
            let empty = store.pending == nil && store.celebrated.isEmpty && store.take() == nil
            let queued = store.note(old: 0, new: 14)
            check("celebrations: the first dictation queues its milestone and marks it at once",
                  empty && queued == PendingMilestone(threshold: 1, from: 0, to: 14) && store.celebrated == [1])
            check("celebrations: nothing shows at paste time; it waits for Home", store.pending == queued)
            let taken = store.take()
            check("celebrations: Home takes it once", taken == queued && store.pending == nil && store.take() == nil)
            // A reset of the totals: back to 0, then a dictation again.
            store.note(old: 14, new: 0)
            store.note(old: 0, new: 9)
            check("celebrations: resetting the totals doesn't celebrate the first dictation again", store.pending == nil && store.celebrated == [1])
            store.note(old: 9_960, new: 10_010)
            store.note(old: 10_010, new: 10_030)
            check("celebrations: 10,000 queues from its old total", store.pending == PendingMilestone(threshold: 10_000, from: 9_960, to: 10_010))
            let a = PendingMilestone(threshold: 1, from: 0, to: 3), b = PendingMilestone(threshold: 10_000, from: 9_990, to: 10_002)
            check("celebrations: two waiting show the higher, from the first's old total", a.merged(with: b) == PendingMilestone(threshold: 10_000, from: 0, to: 10_002))
            let other = MilestoneStore(defaults: d)
            check("celebrations: the screenshot tour's store is apart from yours", other.celebrated.isEmpty && other.pending == nil)
            store.reset()
            check("celebrations: reset forgets the tour's milestones", store.celebrated.isEmpty && store.pending == nil)
            d.removePersistentDomain(forName: suite)
        } else {
            check("celebrations: a scratch defaults suite for the milestone store", false)
        }
    }
}
