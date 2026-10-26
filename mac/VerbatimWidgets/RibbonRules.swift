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
/// - An idle session ends itself after 2 hours unless you choose 10 or 30 minutes, 1 or 4 hours, or Until I end it
///   (October 2026; it was 30 minutes, and anyone who never changed that moves to 2 hours).
/// - A phone or FaceTime call (or Siri) pauses the session instead of ending it; it picks up when the call ends.
/// - A session that ends by itself stays in the Dynamic Island and on the Lock Screen for 15 minutes as Session
///   ended, with Restart.
/// - A clipboard write that fails in the background is reported in the Live Activity, never silent.
/// - The Lock Screen never shows transcript text: only state, counts, times, and the app the words go to. The
///   expanded Dynamic Island may show the last few words while you talk, only with Show words in the Dynamic
///   Island on (off by default).
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
        /// The session ended by itself (idle, a lost microphone, the 8-hour limit); Restart turns it back on.
        case ended
        /// A phone or FaceTime call, or Siri, has the audio; the session picks up when it ends.
        case paused
    }

    /// How long Copied, Inserted, or a failure shows before the activity goes back to ready.
    static let resultHold: TimeInterval = 4
    /// How long "Session ended" stays in the Dynamic Island and on the Lock Screen, with Restart, after a session
    /// ends by itself (not when you end it).
    static let endedHold: TimeInterval = 15 * 60

    /// While a dictation starts before the speech model is loaded (the first one after launch): the keyboard's
    /// Listening and the Dynamic Island say so instead of looking stuck. The audio is captured from the start.
    static let gettingReadyTitle = "Getting ready"
    static let gettingReadyDetail = "The first one takes a few seconds"
    static let gettingReadyLine = "Getting ready · the first one takes a few seconds"

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
        case .paused: return "Paused for a call"
        }
    }

    /// The headline while listening, or "Getting ready" while the speech model loads for the first dictation.
    static func headline(_ phase: Phase, words: Int, gettingReady: Bool) -> String {
        phase == .listening && gettingReady ? gettingReadyTitle : headline(phase, words: words)
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
        case .ended: return message ?? "Your last take is saved in Dictations. Tap Restart to turn it back on."
        case .paused: return "Verbose picks up again when the call ends."
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

    /// Settings › Keyboard › End keyboard sessions after and Settings › Action button: 10 or 30 minutes, 1, 2, or
    /// 4 hours, or Until I end it (0: no idle timeout; the 8-hour Live Activity limit still ends it, `sessionCap`).
    static let timeoutChoices: [Int] = [600, 1800, 3600, 7200, 14_400, 0]
    /// 2 hours for new installs, and for anyone who never chose (owner decision, October 2026).
    static let defaultTimeout = 7200
    /// The old default (30 minutes). The app never wrote it on its own, so a stored value always came from a pick.
    static let oldDefaultTimeout = 1800

    /// A stored timeout as one of the choices: missing means the default; 0 (and below) is Until I end it; any
    /// other old value moves to the nearest choice (1 and 5 minutes become 10; 15 becomes 10, ties go shorter).
    static func normalizedTimeout(_ stored: Int?) -> Int {
        guard let s = stored else { return defaultTimeout }
        if s <= 0 { return 0 }
        let timed = timeoutChoices.filter { $0 > 0 }
        return timed.min { abs($0 - s) < abs($1 - s) || (abs($0 - s) == abs($1 - s) && $0 < $1) }!
    }

    /// The timeout to use at launch, from the stored seconds and whether you picked them (`userSet`, written with
    /// each pick since October 2026; nil before). Never chose: the default (2 hours), which also moves anyone who
    /// was on the old 30-minute default. A pick always stays. Before the flag existed the app wrote the value only
    /// when you picked one, so a stored value without the flag counts as a pick; `userSet == false` follows the
    /// default.
    static func launchTimeout(stored: Int?, userSet: Bool?) -> Int {
        guard let stored else { return defaultTimeout }
        if userSet == false { return defaultTimeout }
        return normalizedTimeout(stored)
    }

    /// "10 minutes", "1 hour", "2 hours", "Until I end it".
    static func timeoutLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return "Until I end it" }
        if seconds % 3600 == 0 { let h = seconds / 3600; return h == 1 ? "1 hour" : "\(h) hours" }
        return "\(seconds / 60) minutes"
    }

    /// The short form for a settings row's value: "10 min", "2 hr", "Until I end it".
    static func timeoutShortLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return "Until I end it" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) hr" }
        return "\(seconds / 60) min"
    }

    /// A Live Activity lasts at most 8 hours; a session ends 10 minutes before that, so the microphone is never
    /// on without one.
    static let activityLimit: TimeInterval = 8 * 3600
    static let sessionCap: TimeInterval = activityLimit - 600

    enum EndCheck: Equatable { case keep, idle, cap }

    /// Whether a session should end now. Never during a take; never for idleness while a call has it paused (the
    /// idle timer starts over when it resumes), though the 8-hour limit still applies.
    static func endCheck(now: Date, startedAt: Date?, endsAt: Date?, dictating: Bool, paused: Bool = false) -> EndCheck {
        guard !dictating else { return .keep }
        if let s = startedAt, now.timeIntervalSince(s) >= sessionCap { return .cap }
        if paused { return .keep }
        if let e = endsAt, now >= e { return .idle }
        return .keep
    }

    // MARK: Calls (audio interruptions)

    /// Where the session's audio stands. A call, FaceTime, or Siri interrupts it; iOS hands it back afterwards.
    enum AudioState: Equatable {
        case running
        /// Interrupted: the microphone is iOS's until the interruption ends.
        case paused
        /// The interruption ended; Verbose is turning the audio session and the capture back on.
        case resuming
    }

    enum AudioEvent: Equatable {
        /// `AVAudioSession.interruptionNotification`, type began.
        case interruptionBegan
        /// Type ended, with or without `.shouldResume`: Verbose resumes either way (owner decision).
        case interruptionEnded(shouldResume: Bool)
        /// Turning the audio back on worked, or didn't.
        case reactivated(ok: Bool)
    }

    enum AudioAction: Equatable {
        /// Stop the capture and show "Paused for a call". `saveTake`: a take was running; save it as it is.
        case pause(saveTake: Bool)
        /// Reactivate the audio session and restart the engine (background audio allows it).
        case reactivate
        /// Back on: reset the idle timer and show the session as ready.
        case resumed
        /// Reactivation failed: end the session with the call message.
        case end
        case none
    }

    /// The session's answer to an audio interruption. Pure, so the Linux tests walk every path.
    static func audio(_ state: AudioState, _ event: AudioEvent, dictating: Bool) -> (AudioState, AudioAction) {
        switch (state, event) {
        case (.running, .interruptionBegan): return (.paused, .pause(saveTake: dictating))
        case (.paused, .interruptionBegan), (.resuming, .interruptionBegan): return (.paused, .none)
        case (.paused, .interruptionEnded): return (.resuming, .reactivate)
        case (.running, .interruptionEnded), (.resuming, .interruptionEnded): return (state, .none)
        case (.resuming, .reactivated(let ok)): return ok ? (.running, .resumed) : (.running, .end)
        case (.running, .reactivated), (.paused, .reactivated): return (state, .none)
        }
    }

    /// The message when a session couldn't come back after a call.
    static let callEndedMessage = "The session ended for a call or another app's audio. Tap to start a new one."

    // MARK: Action button

    /// Settings › Action button: what Verbose does when the Action button runs "Verbose action" (one control or
    /// shortcut, assigned once in iOS Settings › Action Button; `ActionButtonIntent` follows the stored choice).
    enum ActionChoice: String, CaseIterable, Identifiable {
        case dictate, voiceNote, captions, whatsPlaying, quickCapture
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dictate: return "Dictate"
            case .voiceNote: return "Record a voice note"
            case .captions: return "Live captions"
            case .whatsPlaying: return "What's playing"
            case .quickCapture: return "New thought"
            }
        }
        /// The value on Settings' Action button row.
        var shortTitle: String {
            switch self {
            case .dictate: return "Dictate"
            case .voiceNote: return "Voice note"
            case .captions: return "Captions"
            case .whatsPlaying: return "What's playing"
            case .quickCapture: return "New thought"
            }
        }
        /// The line under the title: whether it works in place or opens Verbose (or why it can't be chosen).
        var detail: String {
            switch self {
            case .dictate: return "Starts or stops a take, in place."
            case .voiceNote, .captions: return "Opens Verbose."
            case .whatsPlaying: return "Opens the iOS broadcast sheet first."
            case .quickCapture: return "Starts a thought, in place when iOS allows it."
            }
        }
        /// Whether it can be chosen on this iPhone. Every choice can be, now that Thoughts has a page on the iPhone
        /// (New thought keeps the stored value `quickCapture` from when it was the Mac's Quick capture).
        var available: Bool { true }
        /// Only dictation runs without bringing Verbose forward (it reuses the session's microphone). A voice note and
        /// a thought try to start in place first on iOS 18 and later (`AudioRecordingIntent`), and open Verbose when
        /// they can't.
        var needsForeground: Bool { self != .dictate }
    }

    static let actionChoiceKey = "ribbon.actionButton"

    /// The stored choice; Dictate unless you chose something else that this iPhone can do.
    static func actionChoice(_ raw: String?) -> ActionChoice {
        guard let c = raw.flatMap(ActionChoice.init(rawValue:)), c.available else { return .dictate }
        return c
    }

    // MARK: The expanded Dynamic Island's words and target

    /// Settings › Keyboard › Show words in the Dynamic Island: off unless you turn it on. In the App Group, read
    /// by the app (the widget extension only draws what the app sends).
    static let islandWordsKey = "ribbon.islandWords"
    /// The words line holds about this many characters (two lines at most in the expanded Island).
    static let islandWordsLimit = 80
    /// ActivityKit's cap on a Live Activity's content state, in bytes.
    static let contentStateLimit = 4096

    /// The end of the live words for the expanded Island: at most `limit` characters, starting at a word
    /// boundary, on one line. Nil when there's nothing to show.
    static func islandWords(_ text: String, limit: Int = islandWordsLimit) -> String? {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        guard flat.count > limit else { return flat }
        var cut = Substring(flat.suffix(limit))
        if let space = cut.firstIndex(of: " ") { cut = cut[cut.index(after: space)...] }
        return cut.isEmpty ? String(flat.suffix(limit)) : String(cut)
    }

    /// The words line split for drawing: older words (dimmed) and the newest `newest` words (bright).
    static func splitWords(_ line: String, newest: Int = 3) -> (older: String, newest: String) {
        let words = line.split(separator: " ")
        guard words.count > newest else { return ("", line) }
        return (words.dropLast(newest).joined(separator: " ") + " ", words.suffix(newest).joined(separator: " "))
    }

    /// Where a take's words go, as the Island and the Lock Screen name it: the app you're typing in when the build
    /// can read it ("Messages"), otherwise the Verbose keyboard. App Store builds never read the host app.
    static func target(hostName: String?, appStore: Bool) -> String {
        guard !appStore, let n = hostName?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return keyboardTarget }
        return n
    }

    static let keyboardTarget = "the Verbose keyboard"

    /// "Into Messages", "Into the Verbose keyboard".
    static func intoLine(_ target: String?) -> String { "Into " + (target ?? keyboardTarget) }

    /// The Lock Screen's line under the level: "Into Messages · take 3 of this session". Never any words.
    static func lockLine(target: String?, take: Int) -> String {
        intoLine(target) + " · take \(max(1, take)) of this session"
    }

    // MARK: Session ended

    /// The "Session ended" screen's line for why it ended.
    static func endedReason(call: Bool) -> String {
        call ? "A phone call or another app's audio ended your session." : "Your session ended."
    }

    // MARK: The start screen's way back

    /// After a session starts, the start screen shows how to go back to your app: the full coach card (two
    /// illustrated ways back) for your first `coachFullStarts` session starts, then a one-line reminder.
    static let coachFullStarts = 5
    /// UserDefaults key (the app's own): how many session starts have shown the full way back.
    static let coachCountKey = "keyboard.returnCoachShown"

    enum Coach: Equatable { case full, reminder }

    /// The coach for a session start, given how many starts already showed the full card.
    static func coach(shown: Int) -> Coach { max(0, shown) < coachFullStarts ? .full : .reminder }

    /// The count after one more start showed the coach (it stops at `coachFullStarts`).
    static func coachCount(after shown: Int) -> Int { min(max(0, shown) + 1, coachFullStarts) }

    /// How the start screen names the app you came from when it isn't known (App Store builds never know it).
    static let unknownSourceApp = "the app you were in"

    static func sourceName(_ sourceApp: String?) -> String {
        guard let n = sourceApp?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return unknownSourceApp }
        return n
    }

    /// "Go back to Messages to dictate."
    static func coachTitle(sourceApp: String?) -> String { "Go back to \(sourceName(sourceApp)) to dictate." }

    /// "or tap ◀ Messages at the top left"; unnamed: "or tap ◀ and the app's name at the top left".
    static func breadcrumbLine(sourceApp: String?) -> String {
        guard let n = sourceApp?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "or tap ◀ and the app's name at the top left" }
        return "or tap ◀ \(n) at the top left"
    }

    // MARK: The first dictation note

    /// Shown on Settings › Keyboard and the start screen until the first keyboard dictation succeeds, then never
    /// again. The flag lives in the app's own defaults.
    static let firstDictationDoneKey = "keyboard.firstDictationDone"
    static let firstDictationNote = "Your first dictation takes a few seconds longer while Verbose gets ready. After that it's quick."

    static func showsFirstDictationNote(done: Bool) -> Bool { !done }

    /// The flag after a dictation finished: set by the first one that produced words, and never cleared.
    static func firstDictationDone(was: Bool, words: Int) -> Bool { was || words > 0 }
}
