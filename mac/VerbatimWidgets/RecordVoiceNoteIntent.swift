import Foundation
import AppIntents

/// Record from a widget: the Record and Quick capture widgets, the Lock Screen's Record, and the Record voice note
/// control in Control Center (HomeWidgets.swift, StartSessionWidgets.swift). Compiled into the app and into the
/// VerbatimWidgets extension, which shows the buttons.
///
/// A `LiveActivityIntent`, so iOS runs `perform` in the app's process. On iOS 18 and later the app also declares it an
/// `AudioRecordingIntent`, so the voice note can start in place, behind the recording's Live Activity, without
/// opening Verbose (`PhoneState.startVoiceNoteInPlace`, as the Action button's Record a voice note does). iOS stops
/// such a recording unless a Live Activity starts with it, so when one can't start (activities turned off, or iOS
/// refused it from the background), when a recording is already running, and on iOS 17, Verbose opens to the
/// recorder instead (`continueInVerbose`).
struct RecordVoiceNoteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Record a voice note"
    static var description = IntentDescription("Starts a Verbose voice note. It records in place behind its Live Activity when iOS allows it, or opens Verbose to record.")
    static var openAppWhenRun: Bool = false
    /// As for Dictate: on a locked iPhone, Face ID, Touch ID, or the passcode comes first, so nobody holding it can
    /// turn the microphone on.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    init() {}

    func perform() async throws -> some IntentResult {
        #if !VERBATIM_WIDGETS
        if #available(iOS 18.0, *) {
            let started = await MainActor.run { ActionButtonSignal.startVoiceNoteInPlace() }
            Log.note("widget record: \(started ? "recording in place behind the Live Activity" : "opening Verbose to record")")
            if started { return .result() }
        } else {
            Log.note("widget record: iOS 17 can't record from a widget in place; opening Verbose to record")
        }
        try await continueInVerbose { ActionButtonSignal.fire(.voiceNote) }
        #endif
        return .result()
    }
}

#if !VERBATIM_WIDGETS
extension RecordVoiceNoteIntent: ForegroundContinuableIntent {
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

/// iOS 18 and later: this intent may start recording audio from the background (see above).
@available(iOS 18.0, *)
extension RecordVoiceNoteIntent: AudioRecordingIntent {}
#endif
