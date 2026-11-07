import Foundation

// Motion's pure rules (DESIGN.md §7), for the Mac, the iPhone, and the keyboard: how long a toast stays, when ⌘Z runs
// a toast's Undo, how a new screen arrives given where the navigation came from, the fade that keyboard actions get,
// the swipe hint's loop, and Limit animation's copy in the App Group. Foundation only, so the Linux tests
// (mac/tools/test-motion.sh) and both self-tests check them (MotionChecks.swift). The views read them; nothing here
// draws.

/// How long a toast stays (DESIGN.md §7, Toasts). A message alone stays by its length: at least its floor (4.5 s on
/// the Mac, 3 s on iPhone), 1.5 s plus a quarter second a word above that, and never more than 10 s. A toast with an
/// action (Undo, Open, Review) stays at least 8 s, and stays a moment more after you let go. Any toast stays while the
/// pointer (Mac) or a finger (iPhone) is on it, so a timer never takes a message or its action out from under you.
/// While VoiceOver runs, a toast with an action stays until it's dismissed or replaced.
enum ToastTiming {
    /// The least a message alone shows on the Mac.
    static let macPlain: TimeInterval = 4.5
    /// The least a message alone shows on iPhone.
    static let phonePlain: TimeInterval = 3
    /// The least time a toast with an action shows.
    static let withAction: TimeInterval = 8
    /// How long a toast stays after the pointer or the finger leaves it.
    static let afterRelease: TimeInterval = 3
    /// The longest a message alone shows.
    static let plainCap: TimeInterval = 10
    /// The reading time for a message alone: a base, plus this much a word.
    static let readBase: TimeInterval = 1.5
    static let perWord: TimeInterval = 0.25

    /// The words in `message`, for its reading time.
    static func words(in message: String) -> Int {
        message.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// How long a message alone shows: `max(floor, 1.5 + 0.25 × words)`, at most 10 s.
    static func plain(for message: String, floor: TimeInterval) -> TimeInterval {
        min(plainCap, max(floor, readBase + perWord * Double(words(in: message))))
    }

    /// The least time this toast shows.
    static func minimum(hasAction: Bool, plain: TimeInterval) -> TimeInterval {
        hasAction ? max(withAction, plain) : plain
    }

    /// How long from now until the toast goes: 0 when it should go now, nil while it's held or, with an action, while
    /// VoiceOver runs (it waits and asks again). `elapsed` is the time since it appeared, `sinceRelease` the time since
    /// the last hold ended (nil if it was never held).
    static func remaining(elapsed: TimeInterval, hasAction: Bool, plain: TimeInterval, held: Bool, sinceRelease: TimeInterval?,
                          voiceOver: Bool = false) -> TimeInterval? {
        if held { return nil }
        if hasAction && voiceOver { return nil }
        var left = minimum(hasAction: hasAction, plain: plain) - elapsed
        if let sinceRelease { left = max(left, afterRelease - sinceRelease) }
        return max(0, left)
    }
}

/// What VoiceOver says when a toast appears (WCAG 4.1.3, DESIGN.md §7): its message, and its action when it has one
/// ("Moved to Recently Deleted. Undo available.").
enum ToastSpeech {
    static func announcement(message: String, action: String?) -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let action, !action.isEmpty else { return m }
        let end = m.last.map { ".!?".contains($0) } ?? true
        return m + (end ? " " : ". ") + "\(action) available."
    }
}

/// Whether a toast is held, for the toast showing now: the pointer over it (Mac) or a finger on it (iPhone), and when
/// the last hold ended. A new toast starts unheld, whatever the last one was.
struct ToastHold: Equatable {
    private(set) var id: UUID?
    private(set) var held = false
    private(set) var releasedAt: Date?

    /// The pointer or finger arrived (true) or left (false) on the toast `id`.
    mutating func set(_ on: Bool, for id: UUID, now: Date = Date()) {
        if self.id != id { self = ToastHold(); self.id = id }
        if held && !on { releasedAt = now }
        held = on
    }

    func isHeld(_ id: UUID) -> Bool { self.id == id && held }

    /// Seconds since the last hold of toast `id` ended; nil if it was never let go.
    func sinceRelease(_ id: UUID, now: Date = Date()) -> TimeInterval? {
        guard self.id == id, let releasedAt else { return nil }
        return now.timeIntervalSince(releasedAt)
    }
}

/// ⌘Z while a toast offers Undo (Mac): it runs the toast's Undo, the same as clicking it. Text you're editing keeps its
/// own ⌘Z, and ⇧⌘Z (Redo) or another modifier is left alone.
enum ToastUndo {
    /// The action's title that ⌘Z runs. Only Undo: Open, Review, and the rest aren't an undo.
    static let title = "Undo"

    static func offersUndo(_ action: String?) -> Bool { action == title }

    /// Whether this key press is ⌘Z for the toast: Z with Command and nothing else but Caps Lock, while the toast shows
    /// Undo and no text field or text view has the keyboard.
    static func commandZRuns(action: String?, key: String?, command: Bool, shift: Bool, option: Bool, control: Bool, editingText: Bool) -> Bool {
        guard offersUndo(action), command, !shift, !option, !control, !editingText else { return false }
        return key?.lowercased() == "z"
    }
}

/// How a new screen arrives in the Mac's window (DESIGN.md §7). A navigation from the keyboard (⌘[ and ⌘], Return
/// on a selected row, Space to play, Return in Search, ⌘N and ⌘O) shows the screen at once: keyboard actions never
/// animate. A click or a tap slides it in on `Motion.page`; Limit animation fades it instead. The screen at launch
/// is just there.
enum NavEntrance: String, Equatable {
    /// At once, no movement and no fade.
    case still
    /// Fades in over `Motion.fade` (Limit animation).
    case fade
    /// Slides in on `Motion.page`.
    case slide

    static func of(launch: Bool, keyboard: Bool, limited: Bool) -> NavEntrance {
        if launch || keyboard { return .still }
        return limited ? .fade : .slide
    }
}

/// Motion that a keyboard action is allowed (DESIGN.md §7): none, or a fade this short, never movement or scale.
enum KeyMotion {
    /// Recent dictations opened from its shortcut (⌥⌘V): it fades in over at most this, with no drop.
    static let recallFade: TimeInterval = 0.1
    /// The Ribbon's and the notch's contents when the dictation key starts listening: they fade in over this, with no
    /// delay and no scale, while the shape morphs as before.
    static let listeningFade: TimeInterval = 0.1
}

/// The keyboard session screen's swipe hint (iPhone): the dot rests at the start, then travels along the phone's edge
/// as it fades, and starts again. Drawn from the time by a `LoopTimeline`, never a repeating animation (DESIGN.md §7).
enum SwipeHintLoop {
    /// The rest at the start of each pass.
    static let hold: TimeInterval = 0.3
    /// The travel.
    static let travel: TimeInterval = 1.3
    static var period: TimeInterval { hold + travel }

    /// How far along the dot is at time `t`, 0 to 1, eased in and out.
    static func progress(at t: TimeInterval) -> Double {
        let phase = t.truncatingRemainder(dividingBy: period)
        let p = phase < 0 ? phase + period : phase
        guard p > hold else { return 0 }
        let x = min(1, (p - hold) / travel)
        return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
}

/// Limit animation in the App Group (iPhone), so the keyboard extension follows it. The setting itself lives in the
/// app's own defaults under the same key (`MotionPreference.key`); the app copies it here at launch and whenever it
/// changes, as the haptics switch is shared. The keyboard reads it only with Allow Full Access (without it nothing in
/// the App Group is read) and stills its motion when it's on or the system's Reduce Motion is.
enum MotionMirror {
    static let key = "motion.limited"

    /// Limit animation as the App Group has it. Off when it was never copied.
    static func limited(in group: UserDefaults?) -> Bool { group?.bool(forKey: key) ?? false }

    /// Copies the setting into the App Group. Writes only a change, so it's cheap to call on every launch, and says
    /// whether it wrote one (the iPhone then sends the watch its context again, `WatchContext.limitMotion`).
    @discardableResult
    static func mirror(_ on: Bool, into group: UserDefaults?) -> Bool {
        guard let group, group.object(forKey: key) as? Bool != on else { return false }
        group.set(on, forKey: key)
        return true
    }

    /// Whether the keyboard keeps still: the system's Reduce Motion, or Limit animation (Full Access only).
    static func keyboardStill(systemReduceMotion: Bool, fullAccess: Bool, group: UserDefaults?) -> Bool {
        systemReduceMotion || (fullAccess && limited(in: group))
    }
}

/// The Live Activity's voice bars (iPhone, DESIGN.md §7): the system animates every content update, so under Limit
/// animation or the system's Reduce Motion the app sends one still level instead of the microphone's, and the bars
/// hold their resting shape (SF-03). The Live Activity can't read either setting itself.
enum ActivityLevel {
    /// The level the bars rest at when they keep still.
    static let resting: Double = 0.5

    static func keepsStill(systemReduceMotion: Bool, limitAnimation: Bool) -> Bool { systemReduceMotion || limitAnimation }

    /// The level to send: the microphone's, clamped to 0...1, or the resting level when the bars keep still.
    static func shown(_ level: Double, still: Bool) -> Double {
        if still { return resting }
        return level.isFinite ? min(1, max(0, level)) : 0
    }
}
