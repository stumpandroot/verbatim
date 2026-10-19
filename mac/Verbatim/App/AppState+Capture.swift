import SwiftUI
import AVFoundation

/// Recording from the microphone, continuing a recording, and capturing another app's audio.
extension AppState {
    // MARK: Recording (microphone)

    func requestRecord(appendTo target: UUID? = nil) {
        pendingContinue = target
        goHome()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startRecording()
        case .notDetermined:
            verbiePose = .permission
            showMicSheet = true
        default:
            verbiePose = .interrupted
            toast = Toast("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
        }
    }

    func allowMic() {
        showMicSheet = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in if ok { self.startRecording() } else { self.pendingContinue = nil; self.verbiePose = .ready } }
        }
    }

    /// Returns at once: the recorder opens the mic off the main thread and the record panel says "Starting…"
    /// until it's running. A mic that fails or doesn't answer within 3 seconds is released, with a toast naming it.
    func startRecording() {
        Log.note("startRecording")
        guard !recorder.isRecording else { return }
        recorder.begin(to: store.newRecordingURL()) { [weak self] error in
            guard let self else { return }
            if let error {
                self.pendingContinue = nil
                self.verbiePose = .interrupted
                self.toast = Toast(error.localizedDescription)
                return
            }
            self.continuing = self.pendingContinue
            self.pendingContinue = nil
            self.verbiePose = .listening
            Sounds.start()
        }
    }

    func togglePause() {
        recorder.togglePause()
        verbiePose = recorder.isPaused ? .paused : .listening
    }

    /// Starts a recording that's added to the end of an existing transcript when you stop.
    func continueRecording(_ id: UUID) {
        guard coordinator.canContinue(id) else {
            toast = Toast("This transcript can't take more recording right now."); return
        }
        guard !recorder.isRecording, !capture.isCapturing else { toast = Toast("Stop the current recording first."); return }
        requestRecord(appendTo: id)
    }

    func stopRecording() {
        // Stop while the mic is still starting cancels the start: nothing was recorded.
        let wasStarting = recorder.isStarting
        guard let stopped = recorder.stop() else {
            continuing = nil
            if wasStarting { pendingContinue = nil; verbiePose = .ready }
            return
        }
        let (url, duration, env) = stopped
        if recorder.lastJoinFailed {
            // Every part stays in the recordings folder; launch recovery joins it into one recording.
            continuing = nil
            toast = Toast("Couldn't finish saving. Verbatim will recover the recording the next time it opens.")
            verbiePose = .ready
            return
        }
        if let target = continuing {
            continuing = nil
            guard duration >= 0.5 else { try? FileManager.default.removeItem(at: url); verbiePose = .ready; return }
            appendRecording(url, to: target)
            return
        }
        guard duration >= 0.5 else { try? FileManager.default.removeItem(at: url); verbiePose = .ready; return }
        guard let name = store.adoptRecording(url) else { toast = Toast("Couldn't save the recording."); return }
        var t = Transcript(title: "Voice memo", source: .voiceMemo, sourceLabel: "Voice memo",
                           duration: duration, audioFileName: name, model: "")
        t.waveform = env
        enqueue(t)
    }

    /// Queues a new recording to be transcribed and joined onto the end of `id`.
    private func appendRecording(_ url: URL, to id: UUID) {
        guard coordinator.queueAppend(recording: url, to: id) else { toast = Toast("Couldn't save the recording."); return }
        verbiePose = .working
        go(.transcript(id))
    }

    // MARK: App audio

    func pickApp() { goHome(); showAppPicker = true }

    func startCapture(_ app: AppAudioCapture.RunningApp) {
        showAppPicker = false
        Task {
            do {
                try await capture.start(app: app, to: store.newRecordingURL())
                verbiePose = .listening
            } catch {
                verbiePose = .interrupted
                toast = Toast("Could not capture \(app.name): \(error.localizedDescription). Allow Verbatim under System Settings › Privacy & Security › Screen & System Audio Recording.")
            }
        }
    }

    func stopCapture() {
        Task {
            guard let (url, duration) = await capture.stop() else { return }
            guard let name = store.adoptRecording(url) else { toast = Toast("Couldn't save the capture."); return }
            let t = Transcript(title: capture.appName.isEmpty ? "App audio" : capture.appName, source: .app, sourceLabel: capture.appName,
                               duration: duration, audioFileName: name, model: "")
            enqueue(t)
        }
    }
}
