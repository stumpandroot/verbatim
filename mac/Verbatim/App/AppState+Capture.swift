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
        let url = store.newRecordingURL()
        recorder.begin(to: url) { [weak self] error in
            guard let self else { return }
            if let error {
                self.pendingContinue = nil
                self.verbiePose = .interrupted
                self.toast = Toast(error.localizedDescription)
                return
            }
            self.continuing = self.pendingContinue
            self.pendingContinue = nil
            // If Verbatim quits mid-recording, recovery adds it to this transcript (RecordingSafety.swift).
            if let target = self.continuing { Store.markContinuation(url, to: target) }
            self.verbiePose = .listening
            Sounds.start()
            if let warning = Store.lowSpaceWarning() { self.toast = Toast(warning) }
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
        Task { await finishRecording() }
    }

    /// Stop: capture ends at once, then the recording is saved off the main thread ("Saving…" on Home) and
    /// joins the queue. Nothing that reached the disk is thrown away: only a recording with no audio at all is
    /// removed, with a toast saying so.
    func finishRecording() async {
        // Stop while the mic is still starting cancels the start: nothing was recorded.
        let wasStarting = recorder.isStarting
        let target = continuing
        continuing = nil
        if recorder.isRecording, !wasStarting { savingRecording = true; verbiePose = .working }
        let stopped = await recorder.stopAndSave()
        savingRecording = false
        guard let r = stopped else {
            if wasStarting { pendingContinue = nil }
            verbiePose = .ready
            return
        }
        if r.joinFailed {
            // Every part stays in the recordings folder; launch recovery joins it into one recording (and the
            // continuation marker sends it to the right transcript).
            toast = Toast(Store.joinFailedNotice)
            verbiePose = .ready
            return
        }
        Store.clearContinuation(r.startedAs ?? r.url)
        guard r.framesWritten > 0 else {
            try? FileManager.default.removeItem(at: r.url)
            toast = Toast(Store.nothingRecordedNotice)
            verbiePose = .ready
            return
        }
        if let target {
            appendRecording(r.url, to: target, skipped: r.skipped)
            return
        }
        guard let name = store.adoptRecording(r.url) else { toast = Toast("Couldn't save the recording."); verbiePose = .ready; return }
        var t = Transcript(title: "Voice memo", source: .voiceMemo, sourceLabel: "Voice memo",
                           duration: r.duration, audioFileName: name, model: "")
        t.waveform = r.envelope
        t.notes = Store.skippedNotes(r.skipped)
        enqueue(t)
    }

    /// Queues a new recording to be transcribed and joined onto the end of `id`.
    private func appendRecording(_ url: URL, to id: UUID, skipped: [ClosedRange<Double>] = []) {
        let offset = store.transcript(id)?.duration ?? 0
        guard coordinator.queueAppend(recording: url, to: id) else { toast = Toast("Couldn't save the recording."); verbiePose = .ready; return }
        for n in Store.skippedNotes(skipped, offset: offset) { store.addNote(n, to: id) }
        verbiePose = .working
        go(.transcript(id))
    }

    /// Recordings recovered after launch: transcribed now (or added to the transcript they continued).
    func queueRecovered(_ ids: [UUID]) {
        for id in ids where !queue.contains(id) && runningID != id { coordinator.enqueueExisting(id) }
        toast = Toast(ids.count == 1 ? "Recovered a recording. Transcribing it now." : "Recovered \(ids.count) recordings. Transcribing them now.")
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
        Task { await finishCapture() }
    }

    func finishCapture() async {
        guard let (url, duration) = await capture.stop() else { return }
        guard let name = store.adoptRecording(url) else { toast = Toast("Couldn't save the capture."); return }
        let t = Transcript(title: capture.appName.isEmpty ? "App audio" : capture.appName, source: .app, sourceLabel: capture.appName,
                           duration: duration, audioFileName: name, model: "")
        enqueue(t)
    }

    // MARK: Quitting while recording

    /// Whether quitting now would cut off a recording, an app capture, or a recording still being saved.
    var recordingNeedsSaveBeforeQuit: Bool {
        (recorder.isRecording && !recorder.isStarting) || capture.isCapturing || savingRecording
    }

    /// Quit's Save: stops and saves whatever is recording, then waits for the transcript files to be written.
    func saveRecordingsForQuit() async {
        if recorder.isRecording { await finishRecording() }
        if capture.isCapturing { await finishCapture() }
        while savingRecording { try? await Task.sleep(nanoseconds: 100_000_000) }
        store.flush()
        store.waitForWrites()
    }
}
