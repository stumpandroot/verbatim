import Foundation

/// Motion's rules (MotionRules.swift), checked by the Linux tests (`mac/tools/test-motion.sh`) and by both apps'
/// self-tests. `check` logs PASS or FAIL.
enum MotionChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let T = ToastTiming.self
        // A message alone stays by its length: its floor for a short one, longer for a long one, never past 10 s.
        check("motion: a short message stays 4.5 s on the Mac and 3 s on iPhone",
              T.plain(for: "Copied", floor: T.macPlain) == 4.5 && T.plain(for: "Copied", floor: T.phonePlain) == 3
              && T.remaining(elapsed: 0, hasAction: false, plain: T.phonePlain, held: false, sinceRelease: nil) == 3
              && T.remaining(elapsed: 3.2, hasAction: false, plain: T.phonePlain, held: false, sinceRelease: nil) == 0)
        let sixteen = Array(repeating: "word", count: 16).joined(separator: " ")
        let fifty = Array(repeating: "word", count: 50).joined(separator: " ")
        check("motion: a long message stays longer (1.5 s plus 0.25 s a word), at most 10 s",
              T.words(in: "  Saved.  Transcribing\nnow. ") == 3 && T.plain(for: sixteen, floor: T.phonePlain) == 5.5
              && T.plain(for: sixteen, floor: T.macPlain) == 5.5 && T.plain(for: fifty, floor: T.phonePlain) == 10)
        check("motion: a finger or the pointer on any toast keeps it, a message alone too",
              T.remaining(elapsed: 30, hasAction: false, plain: T.phonePlain, held: true, sinceRelease: nil) == nil
              && T.remaining(elapsed: 4, hasAction: false, plain: T.phonePlain, held: false, sinceRelease: 1) == 2)
        check("motion: with VoiceOver on, a toast with an action stays until it's dismissed; a message alone still goes",
              T.remaining(elapsed: 600, hasAction: true, plain: T.phonePlain, held: false, sinceRelease: nil, voiceOver: true) == nil
              && T.remaining(elapsed: 3, hasAction: false, plain: T.phonePlain, held: false, sinceRelease: nil, voiceOver: true) == 0)
        check("motion: VoiceOver hears every toast, and its action",
              ToastSpeech.announcement(message: "Copied", action: nil) == "Copied"
              && ToastSpeech.announcement(message: "Moved to Recently Deleted", action: "Undo") == "Moved to Recently Deleted. Undo available."
              && ToastSpeech.announcement(message: "Saved. Transcribing now.", action: "Open") == "Saved. Transcribing now. Open available.")
        // A toast with an action: at least 8 s, still there at 6 s, gone at 8 s.
        check("motion: a toast with an action stays at least 8 s",
              T.minimum(hasAction: true, plain: T.macPlain) == 8 && T.minimum(hasAction: true, plain: T.phonePlain) == 8
              && T.remaining(elapsed: 6, hasAction: true, plain: T.phonePlain, held: false, sinceRelease: nil) == 2
              && T.remaining(elapsed: 8, hasAction: true, plain: T.macPlain, held: false, sinceRelease: nil) == 0)
        check("motion: a held toast with an action never goes, however long it's held",
              T.remaining(elapsed: 2, hasAction: true, plain: T.macPlain, held: true, sinceRelease: nil) == nil
              && T.remaining(elapsed: 600, hasAction: true, plain: T.phonePlain, held: true, sinceRelease: nil) == nil)
        check("motion: let go after 8 s, it stays 3 s more; let go early, the 8 s still count",
              T.remaining(elapsed: 20, hasAction: true, plain: T.macPlain, held: false, sinceRelease: 0) == 3
              && T.remaining(elapsed: 21, hasAction: true, plain: T.macPlain, held: false, sinceRelease: 1) == 2
              && T.remaining(elapsed: 3, hasAction: true, plain: T.phonePlain, held: false, sinceRelease: 1) == 5)

        // The hold follows the toast showing now.
        let a = UUID(), b = UUID(), t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var hold = ToastHold()
        hold.set(true, for: a, now: t0)
        let heldA = hold.isHeld(a) && !hold.isHeld(b) && hold.sinceRelease(a, now: t0) == nil
        hold.set(false, for: a, now: t0.addingTimeInterval(2))
        let released = !hold.isHeld(a) && hold.sinceRelease(a, now: t0.addingTimeInterval(3)) == 1
        hold.set(false, for: b, now: t0.addingTimeInterval(4))
        check("motion: a toast's hold and release are its own; a new toast starts unheld",
              heldA && released && !hold.isHeld(b) && hold.sinceRelease(b, now: t0.addingTimeInterval(5)) == nil && hold.sinceRelease(a) == nil)

        // ⌘Z runs a toast's Undo, and nothing else.
        let U = ToastUndo.self
        check("motion: ⌘Z runs a toast's Undo",
              U.commandZRuns(action: "Undo", key: "z", command: true, shift: false, option: false, control: false, editingText: false)
              && U.commandZRuns(action: "Undo", key: "Z", command: true, shift: false, option: false, control: false, editingText: false))
        check("motion: ⌘Z leaves text editing, Redo, other keys, and other actions alone",
              !U.commandZRuns(action: "Undo", key: "z", command: true, shift: false, option: false, control: false, editingText: true)
              && !U.commandZRuns(action: "Undo", key: "z", command: true, shift: true, option: false, control: false, editingText: false)
              && !U.commandZRuns(action: "Undo", key: "z", command: true, shift: false, option: true, control: false, editingText: false)
              && !U.commandZRuns(action: "Undo", key: "z", command: false, shift: false, option: false, control: false, editingText: false)
              && !U.commandZRuns(action: "Undo", key: "x", command: true, shift: false, option: false, control: false, editingText: false)
              && !U.commandZRuns(action: "Open", key: "z", command: true, shift: false, option: false, control: false, editingText: false)
              && !U.commandZRuns(action: nil, key: "z", command: true, shift: false, option: false, control: false, editingText: false))

        // Keyboard navigation doesn't slide; clicks do; Limit animation fades.
        check("motion: a navigation from the keyboard shows the screen at once, even with Limit animation",
              NavEntrance.of(launch: false, keyboard: true, limited: false) == .still
              && NavEntrance.of(launch: false, keyboard: true, limited: true) == .still)
        check("motion: a click slides the screen in, Limit animation fades it, and launch doesn't move",
              NavEntrance.of(launch: false, keyboard: false, limited: false) == .slide
              && NavEntrance.of(launch: false, keyboard: false, limited: true) == .fade
              && NavEntrance.of(launch: true, keyboard: false, limited: false) == .still)

        check("motion: a keyboard action's fade is 0.1 s at most", KeyMotion.recallFade <= 0.1 && KeyMotion.listeningFade <= 0.1)

        // The swipe hint's loop.
        let L = SwipeHintLoop.self
        check("motion: the swipe hint rests, travels, and starts again",
              L.progress(at: 0) == 0 && L.progress(at: L.hold) == 0
              && abs(L.progress(at: L.hold + L.travel / 2) - 0.5) < 0.0001
              && L.progress(at: L.period - 0.0001) > 0.99
              && L.progress(at: L.period) == 0 && L.progress(at: L.period * 3 + L.hold + L.travel / 2) > 0.49)
        var rising = true, last = -1.0
        for i in 0..<160 { let p = L.progress(at: Double(i) / 100); if p < last { rising = false }; last = p }
        check("motion: the swipe hint only moves forward within a pass", rising)

        // The Live Activity's bars keep still with Limit animation or Reduce Motion.
        let A = ActivityLevel.self
        check("motion: the Live Activity gets the microphone's level, clamped, unless the bars keep still",
              A.shown(0.8, still: false) == 0.8 && A.shown(3, still: false) == 1 && A.shown(-1, still: false) == 0 && A.shown(.nan, still: false) == 0)
        check("motion: with Limit animation or Reduce Motion the Live Activity gets one resting level",
              A.shown(0.8, still: true) == A.resting && A.shown(0.1, still: true) == A.resting
              && A.keepsStill(systemReduceMotion: true, limitAnimation: false) && A.keepsStill(systemReduceMotion: false, limitAnimation: true)
              && !A.keepsStill(systemReduceMotion: false, limitAnimation: false))

        // Limit animation's copy in the App Group.
        let suite = "motion-checks-\(UUID().uuidString)"
        if let group = UserDefaults(suiteName: suite) {
            let neverCopied = !MotionMirror.limited(in: group)
            MotionMirror.mirror(true, into: group)
            let on = MotionMirror.limited(in: group)
            MotionMirror.mirror(false, into: group)
            let off = !MotionMirror.limited(in: group)
            check("motion: Limit animation copies into the App Group, off until copied", neverCopied && on && off)
            MotionMirror.mirror(true, into: group)
            check("motion: the keyboard stills with Limit animation (Full Access) or Reduce Motion",
                  MotionMirror.keyboardStill(systemReduceMotion: false, fullAccess: true, group: group)
                  && !MotionMirror.keyboardStill(systemReduceMotion: false, fullAccess: false, group: group)
                  && MotionMirror.keyboardStill(systemReduceMotion: true, fullAccess: false, group: nil)
                  && !MotionMirror.keyboardStill(systemReduceMotion: false, fullAccess: true, group: nil))
            group.removePersistentDomain(forName: suite)
        } else {
            check("motion: a scratch defaults suite for the App Group checks", false)
        }
    }
}
