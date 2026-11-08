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
        try await Self.run { then in try await continueInVerbose(then) }
        #endif
        return .result()
    }
}

/// Control Center's Record voice note, as a switch (iOS 18, SF-18): on while a recording other than a thought runs
/// (`RecordingMirror.recordingOn`). Turned on, it starts a voice note as Record does; turned off, it stops the
/// recording and saves it, as the Live Activity's Stop does. A switch that was out of date does nothing
/// (`RecordingMirror.switchActs`), and off never stops a thought: that's New thought's switch.
@available(iOS 18.0, *)
struct SetRecordingIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Record a voice note"
    static var description = IntentDescription("Starts a Verbose voice note, or stops the recording and saves it.")
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = false
    /// As for Record: unlock first on a locked iPhone. The Live Activity's Stop stays open, so a recording can always
    /// be stopped.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Recording")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        #if !VERBATIM_WIDGETS
        let on = value
        let running = await MainActor.run { RecordingControl.recordingOtherThanThought() }
        guard RecordingMirror.switchActs(on: on, running: running) else {
            Log.note("record switch: already \(running ? "recording" : "stopped"); nothing to do")
            return .result()
        }
        if on {
            try await RecordVoiceNoteIntent.run { then in try await continueInVerbose(then) }
        } else {
            await MainActor.run { RecordingControl.fire(.stop) }
        }
        #endif
        return .result()
    }
}

#if !VERBATIM_WIDGETS
extension RecordVoiceNoteIntent {
    /// What `perform` does, with the way Verbose comes forward passed in (the Record switch runs it too): a voice note in
    /// place behind its Live Activity when iOS allows it, else Verbose opens to record.
    static func run(openVerbose: (@escaping @MainActor () -> Void) async throws -> Void) async throws {
        if #available(iOS 18.0, *) {
            let started = await MainActor.run { ActionButtonSignal.startVoiceNoteInPlace() }
            Log.note("widget record: \(started ? "recording in place behind the Live Activity" : "opening Verbose to record")")
            if started { return }
        } else {
            Log.note("widget record: iOS 17 can't record from a widget in place; opening Verbose to record")
        }
        try await openVerbose { ActionButtonSignal.fire(.voiceNote) }
    }
}

extension RecordVoiceNoteIntent: ForegroundContinuableIntent {
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

/// iOS 18 and later: this intent may start recording audio from the background (see above).
@available(iOS 18.0, *)
extension RecordVoiceNoteIntent: AudioRecordingIntent {}

@available(iOS 18.0, *)
extension SetRecordingIntent: ForegroundContinuableIntent {
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

/// The Record switch turned on starts a voice note in place, as Record does.
@available(iOS 18.0, *)
extension SetRecordingIntent: AudioRecordingIntent {}
#endif
