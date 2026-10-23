import Foundation

/// The recording ribbon's rules: dictate from any app with the Action button, Control Center, Shortcuts, the
/// Dynamic Island, or the Lock Screen while a keyboard session holds the microphone. Pure Foundation, so the logic
/// tests (mac/tools/test-ribbon.sh) compile it on Linux. Compiled into the app (KeyboardSession uses it) and into
/// the VerbatimWidgets extension (the Live Activity's words).
///
/// Owner decisions (October 2026):
/// - The first press (no session) opens Verbose for a moment, turns on the microphone, and starts a take. Later
///   presses start and stop takes without switching apps.
/// - When the Verbose keyboard is open in the app you're typing in, the words go straight into the text field and
///   the clipboard is left alone. Otherwise they go on the clipboard and into the keyboard's Recent row.
/// - An idle session ends itself after 30 minutes unless you choose 10 or 60.
/// - A clipboard write that fails in the background is reported in the Live Activity, never silent.
/// - The Lock Screen never shows transcript text: only state, counts, and times.
enum Ribbon {
    // MARK: Live Activity phases

    /// What the session's Live Activity shows.
    enum Phase: String, Codable, Hashable {
        /// Session on, no take running.
        case ready
        /// A take is running: timer and level.
        case listening
        /// The take stopped; Verbose is writing the words.
        case transcribing
        /// The words went on the clipboard (and into the keyboard's Recent row).
        case copied
        /// The Verbose keyboard put the words into the text field.
        case inserted
        /// Something went wrong; `message` says what, without any transcript text.
        case failed
        /// A call or another app's audio ended the session; Restart session opens Verbose.
        case ended
    }

    /// How long Copied, Inserted, or a failure shows before the activity goes back to ready.
    static let resultHold: TimeInterval = 4
    /// How long "Session ended" stays on the Lock Screen after a call, with Restart session.
    static let endedHold: TimeInterval = 120

    static let copyFailedMessage = "Couldn't copy. Open Verbose to get your words."
    static let nothingHeardMessage = "No words were heard."

    /// "1 word", "42 words".
    static func wordsLabel(_ n: Int) -> String { n == 1 ? "1 word" : "\(max(0, n)) words" }

    /// The same count the keyboard shows: runs of letters or digits, so punctuation alone isn't a word.
    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// The Live Activity's headline. Never transcript text.
    static func headline(_ phase: Phase, words: Int) -> String {
        switch phase {
        case .ready: return "Verbose session on"
        case .listening: return "Listening"
        case .transcribing: return "Writing your words…"
        case .copied: return "Copied · " + wordsLabel(words)
        case .inserted: return "Inserted · " + wordsLabel(words)
        case .failed: return "Didn't finish"
        case .ended: return "Session ended"
        }
    }

    /// The line under the headline on the Lock Screen and in the expanded Dynamic Island.
    static func detail(_ phase: Phase, takes: Int, message: String?) -> String {
        switch phase {
        case .ready:
            let hint = "Press the Action button to dictate."
            switch takes {
            case 0: return hint
            case 1: return hint + " 1 take so far."
            default: return hint + " \(takes) takes so far."
            }
        case .listening: return "Press the Action button again or tap Done."
        case .transcribing: return "On this iPhone."
        case .copied: return "Paste it anywhere, or tap it in the keyboard's Recent row."
        case .inserted: return "In the text field you're typing in."
        case .failed: return message ?? copyFailedMessage
        case .ended: return message ?? "Your last take is saved in Dictations. Tap to restart."
        }
    }

    // MARK: Where a finished take goes

    enum Route: Equatable {
        /// The Verbose keyboard is up and showing this take: it inserts the words.
        case keyboard
        /// No keyboard showing it: the clipboard and the Recent row.
        case clipboard
    }

    /// The keyboard writes when it was last on screen about once a second; older than this, it's gone.
    static let keyboardFresh: TimeInterval = 2.5

    /// True when the keyboard said it was on screen within `keyboardFresh` seconds (times since 1970; 0 = never).
    /// A time from the future (a clock change) doesn't count.
    static func keyboardUp(visibleAt: Double, now: Double) -> Bool {
        guard visibleAt > 0 else { return false }
        let age = now - visibleAt
        return age >= -1 && age < keyboardFresh
    }

    /// The owner's rule: straight into the field when the Verbose keyboard is up and has picked the take up,
    /// otherwise the clipboard and the Recent row.
    static func route(keyboardVisibleAt: Double, keyboardShowsTake: Bool, now: Double) -> Route {
        keyboardUp(visibleAt: keyboardVisibleAt, now: now) && keyboardShowsTake ? .keyboard : .clipboard
    }

    /// Whether the app writes the clipboard: always for the clipboard route; for the keyboard route only when you
    /// turned on Settings › Keyboard › Also copy each dictation.
    static func copies(_ route: Route, alwaysCopy: Bool) -> Bool { route == .clipboard || alwaysCopy }

    /// What the Live Activity shows once the words are out: Copied, Inserted, or the copy failure.
    static func resultPhase(_ route: Route, copied: Bool?) -> Phase {
        switch route {
        case .keyboard: return .inserted
        case .clipboard: return copied == false ? .failed : .copied
        }
    }

    // MARK: Takes

    enum TakeState: Equatable {
        case idle
        case listening(UUID)
    }

    enum TakeEvent: Equatable {
        /// The Action button, the Dictate control, Shortcuts, or the Lock Screen's Dictate.
        case toggle
        case start
        /// Done in the Dynamic Island.
        case stop
        /// Cancel in the Dynamic Island.
        case cancel
    }

    enum TakeAction: Equatable {
        /// No session: iOS won't turn the microphone on from the background, so Verbose must come forward.
        case needsForeground
        case begin
        case finish(UUID)
        case cancel(UUID)
        /// Nothing to do (Done with no take, Start during a take).
        case none
    }

    /// The take state machine. A take that's transcribing doesn't block the next one.
    static func decide(_ state: TakeState, _ event: TakeEvent, sessionOn: Bool) -> TakeAction {
        switch (state, event) {
        case (.idle, .toggle), (.idle, .start):
            return sessionOn ? .begin : .needsForeground
        case (.listening(let id), .toggle), (.listening(let id), .stop):
            return .finish(id)
        case (.listening(let id), .cancel):
            return .cancel(id)
        case (.idle, .stop), (.idle, .cancel), (.listening, .start):
            return .none
        }
    }

    // MARK: Session length

    /// Settings › Action button and Settings › Keyboard › End the session after (idle): 10, 30, or 60 minutes.
    static let timeoutChoices: [Int] = [600, 1800, 3600]
    static let defaultTimeout = 1800

    /// A stored timeout as one of the choices: missing means 30 minutes; an older choice moves to the nearest one
    /// (1 and 5 minutes become 10; 15 becomes 10; "until I end it", 0, becomes 60, because a Live Activity can't
    /// outlast 8 hours).
    static func normalizedTimeout(_ stored: Int?) -> Int {
        guard let s = stored else { return defaultTimeout }
        if s <= 0 { return timeoutChoices.last! }
        return timeoutChoices.min { abs($0 - s) < abs($1 - s) || (abs($0 - s) == abs($1 - s) && $0 < $1) }!
    }

    static func timeoutLabel(_ seconds: Int) -> String { "\(seconds / 60) minutes" }

    /// A Live Activity lasts at most 8 hours; a session ends 10 minutes before that, so the microphone is never
    /// on without one.
    static let activityLimit: TimeInterval = 8 * 3600
    static let sessionCap: TimeInterval = activityLimit - 600

    enum EndCheck: Equatable { case keep, idle, cap }

    /// Whether a session should end now. Never during a take.
    static func endCheck(now: Date, startedAt: Date?, endsAt: Date?, dictating: Bool) -> EndCheck {
        guard !dictating else { return .keep }
        if let s = startedAt, now.timeIntervalSince(s) >= sessionCap { return .cap }
        if let e = endsAt, now >= e { return .idle }
        return .keep
    }

    // MARK: Action button

    /// Settings › Action button: what Verbose does when the Action button runs it.
    enum ActionChoice: String, CaseIterable, Identifiable {
        case dictate, voiceNote, captions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dictate: return "Dictate a take"
            case .voiceNote: return "Record a voice note"
            case .captions: return "Live captions"
            }
        }
        var detail: String {
            switch self {
            case .dictate: return "Each press starts or stops a take. The first one opens Verbose to turn on the microphone."
            case .voiceNote: return "Opens Verbose and starts recording. Stop it from the Lock Screen or the Dynamic Island."
            case .captions: return "Opens Verbose with live captions."
            }
        }
        /// Only dictation can run without bringing Verbose forward (it reuses the session's microphone).
        var needsForeground: Bool { self != .dictate }
    }

    static let actionChoiceKey = "ribbon.actionButton"

    /// The stored choice; Dictate a take unless you chose something else.
    static func actionChoice(_ raw: String?) -> ActionChoice { raw.flatMap(ActionChoice.init(rawValue:)) ?? .dictate }

    // MARK: Session ended

    /// The "Session ended" screen's line for why it ended.
    static func endedReason(call: Bool) -> String {
        call ? "A phone call or another app's audio ended your session." : "Your session ended."
    }
}
