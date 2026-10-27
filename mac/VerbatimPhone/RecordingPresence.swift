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
    /// The running activity is a thought's (PhoneThoughts.swift): your voice and words about once a second, and
    /// "Added to Thoughts" for two seconds when it's saved.
    private var activityIsThought = false
    private var thoughtTicker: Timer?

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
        // Moments marked so far, and "Marked 4:12" for two seconds after each (Model/Marks.swift).
        let marks = app.recordingMoments
        if app.recordingThought {
            // Words travel in the content state (4 KB at most), so only their end, and only when asked for.
            let words = ThoughtRules.islandWords() ? Ribbon.islandWords(app.recordingWords.shown.text) : nil
            return VerbatimRecordingAttributes.ContentState.thought(elapsed: lastElapsed, isPaused: app.recorder.isPaused, pausedReason: reason,
                                                                    level: Double(app.recorder.live.level), words: words)
                .marked(count: marks.count, lastAt: app.lastMark?.at ?? marks.last?.at, just: app.lastMark != nil)
        }
        // A voice note's Lock Screen draws your voice too (mockup "Library features", section 3a): the level, every
        // two seconds.
        var state = VerbatimRecordingAttributes.ContentState.make(elapsed: lastElapsed, isPaused: app.recorder.isPaused, pausedReason: reason)
        state.level = app.recorder.isPaused ? 0 : min(1, max(0, Double(app.recorder.live.level)))
        return state.marked(count: marks.count, lastAt: app.lastMark?.at ?? marks.last?.at, just: app.lastMark != nil)
    }

    /// A mark was made, or its "Marked 4:12" ran out: the Island and the Lock Screen catch up at once.
    func marked() { update(quiet: true) }

    /// Starts the recording's Live Activity. True when one is running afterward.
    @discardableResult
    private func startActivity() -> Bool {
        guard activity == nil else { return true }
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let state = currentState() else {
            if !ActivityAuthorizationInfo().areActivitiesEnabled { Log.note("recording presence: Live Activities are off") }
            return false
        }
        let thought = app?.recordingThought ?? false
        return request(thought: thought, startedAt: app?.thoughtStartedAt ?? Date(), state: state)
    }

    /// A recording's Live Activity, started before the microphone (`PhoneState.startRecording`, and first of all for
    /// an in-place start, `InPlaceRecording`). A recording New thought, Record from a widget, or the Action button
    /// starts belongs to their `AudioRecordingIntent`, and iOS 27 closes the app when the audio session turns on
    /// during such an intent with no Live Activity showing; earlier versions stop the recording. False when iOS
    /// refused it (Live Activities off, or Verbose not allowed to start one from the background) and in the self-test.
    func startActivityBeforeRecording(thought: Bool) -> Bool {
        guard activity == nil else { return true }
        guard !PhoneUITest.enabled else { return false }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Log.note("recording presence: Live Activities are off")
            return false
        }
        let state: VerbatimRecordingAttributes.ContentState = thought
            ? .thought(elapsed: 0, isPaused: false, pausedReason: nil, level: 0, words: nil)
            : .make(elapsed: 0, isPaused: false, pausedReason: nil)
        return request(thought: thought, startedAt: Date(), state: state)
    }

    /// The recording `startActivityBeforeRecording` was for didn't start: its Live Activity goes at once.
    func cancelActivityBeforeRecording() {
        guard let a = activity, app?.recorder.isRecording != true else { return }
        activity = nil
        activityIsThought = false
        thoughtTicker?.invalidate(); thoughtTicker = nil
        Log.note("recording presence: the recording didn't start; its Live Activity ended")
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    private func request(thought: Bool, startedAt: Date, state: VerbatimRecordingAttributes.ContentState) -> Bool {
        endLeftovers()
        var attributes = VerbatimRecordingAttributes(title: thought ? ThoughtRules.activityTitle : "Voice note")
        if thought, let app {
            let day = DayPages.pageDay(for: startedAt, hour: app.newPageHour)
            attributes.thought = true
            attributes.page = PhoneState.thoughtPageTitle(day)
        }
        do {
            activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            activityIsThought = thought
            startTicker(every: thought ? 1 : 2)
            Log.note("recording presence: Live Activity started\(thought ? " for a thought" : "")")
            return true
        } catch {
            Log.note("recording presence: Live Activity unavailable: \(error)")
            return false
        }
    }

    private func update(quiet: Bool = false) {
        guard let a = activity, let state = currentState() else { return }
        if !quiet { Log.note("recording presence: \(state.status) at \(Int(state.elapsed)) s") }
        Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// A thought's voice bars and words about once a second, and a voice note's voice bars every two seconds (the time
    /// counts on its own).
    private func startTicker(every seconds: TimeInterval) {
        thoughtTicker?.invalidate()
        thoughtTicker = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            Task { @MainActor in RecordingPresence.shared.update(quiet: true) }
        }
    }

    private func endActivity(saved: Bool) {
        guard let a = activity else { return }
        activity = nil
        thoughtTicker?.invalidate(); thoughtTicker = nil
        if activityIsThought {
            activityIsThought = false
            endThoughtActivity(a, saved: !(app?.lastStopDiscarded ?? false))
            return
        }
        if saved {
            let state = VerbatimRecordingAttributes.ContentState.make(elapsed: lastElapsed, isPaused: true, pausedReason: nil, saved: true)
            Task { await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(4))) }
        } else {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// A thought's activity: "Added to Thoughts" and the time for two seconds, as an alert when Verbose isn't in front
    /// (the Dynamic Island expands to show it), then it ends. Discarded, it ends at once.
    private func endThoughtActivity(_ a: Activity<VerbatimRecordingAttributes>, saved: Bool) {
        guard saved else {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let now = Date()
        let state = VerbatimRecordingAttributes.ContentState.thought(elapsed: lastElapsed, isPaused: false, pausedReason: nil,
                                                                     level: 0, words: nil, saved: true, now: now)
        let content = ActivityContent(state: state, staleDate: nil)
        let inFront = UIApplication.shared.applicationState == .active
        let time = Formats.style(date: .none, time: .short).string(from: now)
        Task {
            if !inFront {
                await a.update(content, alertConfiguration: AlertConfiguration(title: "\(ThoughtRules.savedTitle)", body: "\(time)", sound: .default))
            }
            await a.end(content, dismissalPolicy: inFront ? .immediate : .after(now.addingTimeInterval(ThoughtRules.savedSeconds)))
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
        case .mark(let source):
            return app.markMoment(source: MarkSource(rawValue: source) ?? .island)
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
        // A recording the Action button started in the background without its Live Activity gets one now.
        if activity == nil { startActivity() }
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

    /// verbatim://record, from the recording's Live Activity, or a widget's link (PhoneWidgetLinks.swift). True when it
    /// was one of those.
    func handleRecorderLink(_ url: URL) -> Bool {
        guard url.scheme == "verbatim", url.host == "record" else { return handleWidgetLink(url) }
        openRecorder()
        return true
    }
}
