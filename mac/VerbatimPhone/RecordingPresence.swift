import Foundation
import ActivityKit
import UserNotifications
import UIKit
import Combine

/// A voice note recording outside the app: its Live Activity (Lock Screen and Dynamic Island, drawn by
/// VerbatimWidgets/RecordingLiveActivity.swift) and the notification when a call leaves it paused.
///
/// - The activity starts with the recording, follows Pause, Resume, and pauses for interruptions, and ends on Stop
///   or Discard. Stopped from the Lock Screen, it shows "Saved" for a few seconds first. It respects the system
///   Live Activities setting; there's no setting of its own.
/// - Notification permission is asked once, when the first recording starts (the moment it's useful). Turned
///   off, the recording still pauses honestly, and the Live Activity and the in-app banner still say so.
/// - When the recording stays paused after a call while Verbatim is in the background, a notification says so;
///   tapping it opens the recorder. Coming back to Verbatim opens the recorder on its paused banner.
@MainActor
final class RecordingPresence: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RecordingPresence()
    nonisolated static let notificationID = "co.stumpandroot.verbatim.recording.paused"
    static let notificationsAskedKey = "recording.notificationsAsked"

    private weak var app: PhoneState?
    private var activity: Activity<VerbatimRecordingAttributes>?
    private var bag = Set<AnyCancellable>()
    private var lastElapsed: TimeInterval = 0
    /// Stop came from the Live Activity: it shows "Saved" before it goes.
    private var stoppingFromActivity = false

    func attach(_ app: PhoneState) {
        guard self.app == nil else { return }
        self.app = app
        guard !PhoneUITest.enabled else { return }
        UNUserNotificationCenter.current().delegate = self
        endLeftovers()
        let recorder = app.recorder
        recorder.onNeedsAttention = { [weak self] reason in self?.needsAttention(reason) }
        RecordingControl.handler = { [weak self] command in self?.perform(command) ?? false }
        // @Published sends before the value changes, so each change is read on the next turn of the run loop.
        recorder.$isRecording.removeDuplicates().dropFirst().sink { [weak self] on in
            DispatchQueue.main.async { self?.recordingChanged(on) }
        }.store(in: &bag)
        recorder.$isPaused.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &bag)
        app.$autoPauseReason.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.cameBack()
        }.store(in: &bag)
    }

    // MARK: Recording state

    private func recordingChanged(_ on: Bool) {
        guard let app else { return }
        if on, app.recorder.isRecording {
            Log.note("recording presence: recording started")
            askForNotificationsOnce()
            startActivity()
        } else if !on, !app.recorder.isRecording {
            Log.note("recording presence: recording ended")
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
            endActivity(saved: stoppingFromActivity)
            stoppingFromActivity = false
        }
    }

    private func currentState() -> VerbatimRecordingAttributes.ContentState? {
        guard let app, app.recorder.isRecording else { return nil }
        lastElapsed = app.recorder.elapsed
        let reason = app.recorder.isPaused ? VerbatimRecordingAttributes.shortReason(app.autoPauseReason) : nil
        return .make(elapsed: lastElapsed, isPaused: app.recorder.isPaused, pausedReason: reason)
    }

    private func startActivity() {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled, let state = currentState() else {
            if !ActivityAuthorizationInfo().areActivitiesEnabled { Log.note("recording presence: Live Activities are off") }
            return
        }
        endLeftovers()
        do {
            activity = try Activity.request(attributes: VerbatimRecordingAttributes(title: "Voice note"),
                                            content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            Log.note("recording presence: Live Activity started")
        } catch {
            Log.note("recording presence: Live Activity unavailable: \(error)")
        }
    }

    private func update() {
        guard let a = activity, let state = currentState() else { return }
        Log.note("recording presence: \(state.status) at \(Int(state.elapsed)) s")
        Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endActivity(saved: Bool) {
        guard let a = activity else { return }
        activity = nil
        if saved {
            let state = VerbatimRecordingAttributes.ContentState.make(elapsed: lastElapsed, isPaused: true, pausedReason: nil, saved: true)
            Task { await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(4))) }
        } else {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Activities left from a recording Verbatim didn't get to end (it was closed); launch recovery keeps the audio.
    private func endLeftovers() {
        for a in Activity<VerbatimRecordingAttributes>.activities where a.id != activity?.id {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Pause, Resume, and Stop from the Live Activity. False when no recording is running.
    private func perform(_ command: RecordingControl.Command) -> Bool {
        guard let app, app.recorder.isRecording else {
            Log.note("recording presence: \(command) from the Live Activity with nothing recording")
            return false
        }
        switch command {
        case .togglePause:
            Log.note("recording presence: \(app.recorder.isPaused ? "Resume" : "Pause") from the Live Activity")
            app.togglePause()
        case .stop:
            Log.note("recording presence: Stop from the Live Activity")
            lastElapsed = app.recorder.elapsed
            stoppingFromActivity = true
            app.stopRecording()
        }
        return true
    }

    // MARK: Notifications

    private func askForNotificationsOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.notificationsAskedKey) else { return }
        d.set(true, forKey: Self.notificationsAskedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.note("recording presence: notifications \(granted ? "allowed" : "not allowed")\(error.map { " (\($0.localizedDescription))" } ?? "")")
        }
    }

    /// The recording stays paused after an interruption. In the background, a notification says so; in the
    /// foreground, the recorder's banner already does.
    private func needsAttention(_ reason: String) {
        guard let app else { return }
        let state = UIApplication.shared.applicationState
        Log.note("recording presence: paused and needs you (app \(state == .active ? "active" : "in the background"))")
        if state == .active {
            app.openRecorder()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Verbose"
        content.body = reason
        content.sound = .default
        content.interruptionLevel = .active
        content.userInfo = ["link": "record"]
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Log.note(error.map { "recording presence: notification not posted (\($0.localizedDescription))" } ?? "recording presence: notification posted")
        }
    }

    /// Back in Verbatim with a recording that paused itself: the recorder opens on its paused banner with Resume.
    private func cameBack() {
        guard let app, app.recorder.isRecording else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        guard app.recorder.isPaused, app.recorder.awaitingResume || app.autoPauseReason != nil else { return }
        if app.autoPauseReason == nil { app.autoPauseReason = Recorder.callPausedNotice }
        Log.note("recording presence: back in Verbatim with the recording paused; showing Resume")
        app.openRecorder()
        update()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // In Verbatim, the recorder's banner says it; no banner on top.
        completionHandler([])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isOurs = response.notification.request.identifier == Self.notificationID
        Task { @MainActor in
            if isOurs {
                Log.note("recording presence: notification opened")
                self.app?.openRecorder()
            }
            completionHandler()
        }
    }
}

extension PhoneState {
    /// Brings up the recorder while a recording runs (from the paused notification, the Live Activity, or coming
    /// back to Verbatim).
    // openRecorder() lives in MiniRecorder.swift (it also handles the minimized bar and Reduce Motion).

    /// verbatim://record, from the recording's Live Activity. True when it was that link.
    func handleRecorderLink(_ url: URL) -> Bool {
        guard url.scheme == "verbatim", url.host == "record" else { return false }
        openRecorder()
        return true
    }
}
