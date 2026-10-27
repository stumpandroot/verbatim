import SwiftUI
import AVFoundation

/// Recording from the microphone, continuing a recording, and capturing another app's audio.
extension AppState {
    // MARK: Recording (microphone)

    func requestRecord(appendTo target: UUID? = nil, kind: RecordingKind? = nil) {
        pendingContinue = target
        // A plain Record leaves the kind to AutoLabel; a picked one (Record a meeting) is yours.
        if !recorder.isRecording { recordKind = target == nil ? kind : nil }
        goHome()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startRecording()
        case .notDetermined:
            showMicSheet = true
        default:
            toast = Toast("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
        }
    }

    func allowMic() {
        showMicSheet = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in if ok { self.startRecording() } else { self.pendingContinue = nil } }
        }
    }

    /// Returns at once: the recorder opens the mic off the main thread and the record panel says "Starting…"
    /// until it's running. A mic that fails or doesn't answer within 3 seconds is released, with a toast naming it.
    func startRecording() {
        Log.note("startRecording")
        guard !recorder.isRecording else { return }
        let url = store.newRecordingURL()
        recordingWords.begin(recorder)   // before the mic opens, so live words hear the first word
        recorder.begin(to: url) { [weak self] error in
            guard let self else { return }
            if let error {
                self.pendingContinue = nil
                self.toast = Toast(error.localizedDescription)
                return
            }
            self.continuing = self.pendingContinue
            self.pendingContinue = nil
            // If Verbatim quits mid-recording, recovery adds it to this transcript (RecordingSafety.swift).
            if let target = self.continuing { Store.markContinuation(url, to: target) }
            Sounds.start()
            if let warning = Store.lowSpaceWarning() { self.toast = Toast(warning) }
        }
    }

    func togglePause() {
        recorder.togglePause()
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
        let kind = recordKind
        recordKind = nil
        if recorder.isRecording, !wasStarting { savingRecording = true }
        let stopped = await recorder.stopAndSave()
        savingRecording = false
        guard let r = stopped else {
            if wasStarting { pendingContinue = nil }
            return
        }
        if r.joinFailed {
            // Every part stays in the recordings folder; launch recovery joins it into one recording (and the
            // continuation marker sends it to the right transcript).
            toast = Toast(Store.joinFailedNotice)
            return
        }
        Store.clearContinuation(r.startedAs ?? r.url)
        guard r.framesWritten > 0 else {
            try? FileManager.default.removeItem(at: r.url)
            toast = Toast(Store.nothingRecordedNotice)
            return
        }
        if let target {
            appendRecording(r.url, to: target, skipped: r.skipped)
            return
        }
        guard let name = store.adoptRecording(r.url) else { toast = Toast("Couldn't save the recording."); return }
        var t = Transcript(title: "Voice memo", source: .voiceMemo, sourceLabel: "Voice memo",
                           duration: r.duration, audioFileName: name, model: "")
        t.waveform = r.envelope
        t.notes = Store.skippedNotes(r.skipped)
        t.pickKindAtStart(kind)
        enqueue(t)
    }

    /// Queues a new recording to be transcribed and joined onto the end of `id`.
    private func appendRecording(_ url: URL, to id: UUID, skipped: [ClosedRange<Double>] = []) {
        let offset = store.transcript(id)?.duration ?? 0
        guard coordinator.queueAppend(recording: url, to: id) else { toast = Toast("Couldn't save the recording."); return }
        for n in Store.skippedNotes(skipped, offset: offset) { store.addNote(n, to: id) }
        go(.transcript(id))
    }

    /// Recordings recovered after launch: transcribed now (or added to the transcript they continued).
    func queueRecovered(_ ids: [UUID], announce: Bool = true) {
        for id in ids where !queue.contains(id) && runningID != id { coordinator.enqueueExisting(id) }
        guard announce else { return }
        toast = Toast(ids.count == 1 ? "Recovered a recording. Transcribing it now." : "Recovered \(ids.count) recordings. Transcribing them now.")
    }

    // MARK: App audio

    func pickApp() { goHome(); showAppPicker = true }

    func startCapture(_ app: AppAudioCapture.RunningApp) {
        showAppPicker = false
        capture.onNotice = { [weak self] note in self?.toast = Toast(note) }
        // The stream can end on its own (the app quit, permission withdrawn): keep what was captured and say so.
        capture.onStreamError = { [weak self] stopped, reason in
            guard let self else { return }
            let name = self.capture.appName.isEmpty ? "the app" : self.capture.appName
            let kept = self.adoptCapture(stopped)
            self.toast = Toast(kept ? "Capturing \(name) stopped (\(reason)). What was captured is saved and transcribing."
                                    : "Capturing \(name) stopped (\(reason)).")
        }
        Task {
            do {
                try await capture.start(app: app, to: store.newRecordingURL())
            } catch {
                toast = Toast("Could not capture \(app.name): \(error.localizedDescription). Allow Verbose under System Settings › Privacy & Security › Screen & System Audio Recording.")
            }
        }
    }

    func stopCapture() {
        Task { await finishCapture() }
    }

    func finishCapture() async {
        guard let r = await capture.stop() else { return }
        _ = adoptCapture(r)
    }

    /// Adopts a stopped capture and queues it. False when nothing was kept (a toast says why).
    @discardableResult
    private func adoptCapture(_ stopped: StoppedCapture?) -> Bool {
        guard let r = stopped else { return false }
        if r.joinFailed { toast = Toast(Store.joinFailedNotice); return false }
        guard r.framesWritten > 0 else {
            try? FileManager.default.removeItem(at: r.url)
            toast = Toast(Store.nothingRecordedNotice)
            return false
        }
        guard let name = store.adoptRecording(r.url) else { toast = Toast("Couldn't save the capture."); return false }
        var t = Transcript(title: capture.appName.isEmpty ? "App audio" : capture.appName, source: .app, sourceLabel: capture.appName,
                           duration: r.duration, audioFileName: name, model: "")
        t.notes = Store.skippedNotes(r.skipped)
        enqueue(t)
        return true
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
