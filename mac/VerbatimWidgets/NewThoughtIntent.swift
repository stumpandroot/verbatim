import Foundation
import AppIntents

/// New thought on the iPhone (mockup "Thoughts", sections 05–06): the small New thought widget, Today's thoughts, the
/// Lock Screen's circular widget, the New thought control (Control Center, the Action button, the Lock Screen's
/// corners), Siri's "New thought in Verbose", and Shortcuts (Back Tap runs it through a shortcut). Compiled into the app
/// and into the VerbatimWidgets extension, which shows the buttons. The Mac's desktop widget has its own intent
/// (HomeWidgets.swift).
///
/// A `LiveActivityIntent`, so iOS runs `perform` in the app's process. On iOS 18 and later the app also declares it an
/// `AudioRecordingIntent`, so the thought records in place, behind its Live Activity, without opening Verbose
/// (`PhoneState.startThoughtInPlace`). Its Live Activity starts before the microphone (iOS 27 closes the app when an
/// audio recording intent turns the microphone on with no Live Activity showing), so when one can't start, when Record without opening Verbose is off, when something needs asking first, and on iOS 17, Verbose
/// opens straight to the recorder instead (`ThoughtRules.start`). Run while a thought records, it stops that thought.
struct NewThoughtIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "New thought"
    static var description = IntentDescription("Starts a thought in Verbose that lands on today's Thoughts page. It records in place behind a Live Activity when iOS allows it, or opens Verbose to record. Run it again to stop.")
    static var openAppWhenRun: Bool = false
    /// As for Record: on a locked iPhone, Face ID, Touch ID, or the passcode comes first, so nobody holding it can
    /// turn the microphone on.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    init() {}

    func perform() async throws -> some IntentResult {
        #if !VERBATIM_WIDGETS
        try await Self.run { then in try await continueInVerbose(then) }
        #endif
        return .result()
    }
}

#if !VERBATIM_WIDGETS
extension NewThoughtIntent {
    /// What `perform` does, with the way Verbose comes forward passed in, so the self-test runs it as a widget tap
    /// does (`PhoneUITest.newThoughtIntentChecks`). Stops a recording thought, or starts one in place (its Live
    /// Activity first, `InPlaceRecording`), or brings Verbose forward to the recorder. Nothing here can trap: on a cold
    /// launch the request waits for the app (`ThoughtSignal`), and anything that can't start in place opens Verbose.
    static func run(openVerbose: (@escaping @MainActor () -> Void) async throws -> Void) async throws {
        let start = await MainActor.run { ThoughtSignal.decide() }
        switch start {
        case .stop:
            await MainActor.run { ThoughtSignal.stop() }
            return
        case .inPlace:
            if #available(iOS 18.0, *) {
                let started = await MainActor.run { ThoughtSignal.startInPlace() }
                Log.note("new thought: \(started ? "recording in place behind the Live Activity" : "opening Verbose to record")")
                if started { return }
            }
        case .openVerbose(let why):
            Log.note("new thought: opening Verbose to record (\(why))")
        }
        try await openVerbose { ThoughtSignal.fire() }
    }
}

extension NewThoughtIntent: ForegroundContinuableIntent {
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

/// iOS 18 and later: this intent may start recording audio from the background (see above).
@available(iOS 18.0, *)
extension NewThoughtIntent: AudioRecordingIntent {}
#endif
