import Foundation

/// Motion's rules (MotionRules.swift), checked by the Linux tests (`mac/tools/test-motion.sh`) and by both apps'
/// self-tests. `check` logs PASS or FAIL.
enum MotionChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let T = ToastTiming.self
        // A message alone keeps its old time, held or not.
        check("motion: a message alone stays 4.5 s on the Mac and 3 s on iPhone",
              T.remaining(elapsed: 0, hasAction: false, plain: T.macPlain, held: false, sinceRelease: nil) == 4.5
              && T.remaining(elapsed: 0, hasAction: false, plain: T.phonePlain, held: false, sinceRelease: nil) == 3
              && T.remaining(elapsed: 3.2, hasAction: false, plain: T.phonePlain, held: true, sinceRelease: nil) == 0)
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

        // The Ribbon and the notch (DESIGN.md §12).
        check("motion: the surfaces morph with motion on and hold their shape still under Reduce Motion or Limit animation",
              SurfaceMotion.morphs(still: false) && !SurfaceMotion.morphs(still: true) && SurfaceMotion.stillFade <= 0.15)
        check("motion: the Ribbon slides 12 pt in from its edge, and not at all when held still",
              SurfaceMotion.shownOffset(shown: false, still: false) == 12 && SurfaceMotion.shownOffset(shown: true, still: false) == 0
              && SurfaceMotion.shownOffset(shown: false, still: true) == 0)

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
