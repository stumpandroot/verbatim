import Foundation
import AppIntents

// The recording ribbon's App Intents: Dictate (the Action button, Shortcuts, Siri, the Lock Screen's Dictate), Done
// and Cancel in the Dynamic Island, the Action button's own intent (Settings › Action button), and the Control
// Center session switch. Compiled into the app and into the VerbatimWidgets extension, which shows the buttons.
//
// Each one is a `LiveActivityIntent`, so iOS runs `perform` in the app's process without opening the app. While a
// session holds the microphone, a take starts and stops there through `RibbonSignal`. With no session, iOS won't
// turn the microphone on from the background, so the intent brings Verbose forward (`continueInVerbose`) and the
// app starts a session, as the Start dictation session control does. Public APIs only, in every build.

/// What an intent asks the session to do.
enum RibbonCommand: String {
    /// Start a take, or stop the running one (the Action button, Shortcuts, the Lock Screen's Dictate).
    case toggle
    /// Done in the Dynamic Island: stop the take and deliver the words.
    case finish
    /// Cancel in the Dynamic Island: drop the take.
    case cancel
    /// Control Center switch off: end the session.
    case endSession
    /// Control Center switch on: start a session (Verbose comes forward when none is on).
    case startSession
}

enum RibbonOutcome: Equatable {
    /// The session did what was asked.
    case done
    /// Nothing to do (Done with no take running).
    case ignored
    /// No session holds the microphone: Verbose must come forward to start one.
    case needsForeground
    /// Left in the App Group from the widget's process; the app acts on it if it's running.
    case forwarded
}

/// Hands an intent's command to the keyboard session, in the app's process.
///
/// From the widget's process, the command goes into the App Group with a one-time ID and the time
/// (`KeyboardBridge.sendCommand`), and a Darwin notification with no data wakes the app. Any app can post a Darwin
/// notification, so the app acts only on a fresh, unhandled command it reads from the App Group, which only
/// Verbose's own processes can write (`BridgeTrust`).
enum RibbonSignal {
    /// Set by `KeyboardSession`; nil in the widget extension and before the session exists.
    @MainActor static var handler: ((RibbonCommand) -> RibbonOutcome)?

    @MainActor static func send(_ c: RibbonCommand) -> RibbonOutcome {
        if let handler { return handler(c) }
        #if VERBATIM_WIDGETS
        KeyboardBridge.sendCommand(c.rawValue)
        return .forwarded
        #else
        // In the app before the session exists: nothing holds the microphone.
        switch c {
        case .toggle, .startSession: return .needsForeground
        case .finish, .cancel, .endSession: return .ignored
        }
        #endif
    }
}

// Bringing Verbose forward is the app's business only: the widget extension never runs these intents' foreground
// path, so the conformances and modes below are compiled into the app alone.
#if !VERBATIM_WIDGETS
extension ForegroundContinuableIntent {
    /// Brings Verbose forward, then runs `then` in the app. iOS 26 and later: without asking when iOS allows it
    /// (`continueInForeground(alwaysConfirm: false)`). Earlier: iOS asks to continue in Verbose first.
    func continueInVerbose(_ then: @escaping @MainActor () -> Void) async throws {
        if #available(iOS 26.0, *) {
            try await continueInForeground(alwaysConfirm: false)
            await MainActor.run { then() }
        } else {
            throw needsToContinueInForegroundError(continuation: then)
        }
    }
}

extension DictateIntent: ForegroundContinuableIntent {
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

extension ActionButtonIntent: ForegroundContinuableIntent {
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

@available(iOS 18.0, *)
extension SetSessionIntent: ForegroundContinuableIntent {
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}
#endif

/// Dictate: starts a take, or stops the running one and delivers the words (into the text field when the Verbose
/// keyboard is up, otherwise to the clipboard and the keyboard's Recent row). With no session, Verbose opens for
/// a moment, turns on the microphone, and starts listening.
struct DictateIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Dictate"
    static var description = IntentDescription("Starts or stops a Verbose dictation from any app. Your words go into the Verbose keyboard when it's open, or on the clipboard.")
    static var openAppWhenRun: Bool = false
    init() {}

    func perform() async throws -> some IntentResult {
        let outcome = await MainActor.run { RibbonSignal.send(.toggle) }
        #if !VERBATIM_WIDGETS
        if outcome == .needsForeground {
            try await continueInVerbose { SessionStartSignal.fire(.shortcut, take: true) }
        }
        #endif
        _ = outcome
        return .result()
    }
}

/// Done in the Dynamic Island and on the Lock Screen: stops the take and delivers the words.
struct FinishTakeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop and copy"
    static var description = IntentDescription("Stops the Verbose dictation and delivers your words.")
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        _ = await MainActor.run { RibbonSignal.send(.finish) }
        return .result()
    }
}

/// Cancel in the Dynamic Island and on the Lock Screen: drops the take. Nothing is saved.
struct CancelTakeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Cancel dictation"
    static var description = IntentDescription("Stops the Verbose dictation without keeping it.")
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        _ = await MainActor.run { RibbonSignal.send(.cancel) }
        return .result()
    }
}

/// What the Action button does when Verbose is its shortcut or control: the choice in Settings › Action button
/// (Dictate a take unless you change it). A voice note and live captions always open Verbose.
struct ActionButtonIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Verbose action button"
    static var description = IntentDescription("Does what you chose in Verbose › Settings › Action button: dictate a take, record a voice note, or open live captions.")
    static var openAppWhenRun: Bool = false
    init() {}

    func perform() async throws -> some IntentResult {
        #if !VERBATIM_WIDGETS
        let choice = Ribbon.actionChoice(UserDefaults.standard.string(forKey: Ribbon.actionChoiceKey))
        if choice.needsForeground {
            try await continueInVerbose { ActionButtonSignal.fire(choice) }
            return .result()
        }
        let outcome = await MainActor.run { RibbonSignal.send(.toggle) }
        if outcome == .needsForeground {
            try await continueInVerbose { SessionStartSignal.fire(.shortcut, take: true) }
        }
        #else
        _ = await MainActor.run { RibbonSignal.send(.toggle) }
        #endif
        return .result()
    }
}

/// The Control Center switch ("Verbose · Session on"). On with no session opens Verbose for a moment and starts
/// one; off ends the session without opening Verbose.
@available(iOS 18.0, *)
struct SetSessionIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Verbose session"
    static var description = IntentDescription("Turns the Verbose dictation session on or off.")
    static var isDiscoverable: Bool = false
    @Parameter(title: "Session on")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        let outcome = await MainActor.run { RibbonSignal.send(value ? .startSession : .endSession) }
        #if !VERBATIM_WIDGETS
        if outcome == .needsForeground {
            try await continueInVerbose { SessionStartSignal.fire(.control) }
        }
        #endif
        _ = outcome
        return .result()
    }
}
