import SwiftUI

/// The transcription queue lives in TranscriptionCoordinator (shared with the iPhone). These keep the
/// names views and UI tests already use; the host hooks below drive Verbie, the chime, and toasts.
extension AppState {
    // MARK: Pipeline

    func retry(_ t: Transcript) {
        // A link whose audio never arrived (one the iPhone couldn't fetch): this Mac fetches it.
        if t.source == .link, t.audioFileName == nil, let link = t.sourceURL ?? t.link?.url, LinkFetcher.canFetch(link) {
            store.update(t.id) { $0.pendingLink = true; $0.status = .processing; $0.error = nil; $0.stage = nil }
            if let fresh = store.transcript(t.id) { claimIfPendingLink(fresh, userStarted: true) }
            return
        }
        coordinator.retry(t)
    }

    /// Adds a new transcript to the Store and queues it.
    func enqueue(_ t: Transcript) { coordinator.enqueue(t) }

    /// Starts the next queued transcript if nothing is running.
    func pump() { coordinator.pump() }

    /// Stops a queued or running transcript. It stays in Library as "Cancelled" with Retry.
    func cancel(_ id: UUID) {
        multitrackTasks.removeValue(forKey: id)?.cancel()
        coordinator.cancel(id)
    }

    func cancelAll() {
        for (id, task) in multitrackTasks { task.cancel(); coordinator.cancel(id) }
        multitrackTasks = [:]
        coordinator.cancelAll()
    }

    /// Throws away a continued recording that hasn't been added; the transcript stays as it was.
    func discardPendingAppend(_ id: UUID) { coordinator.discardPendingAppend(id) }
}

extension AppState: TranscriptionHost {
    func jobSettings() -> TranscriptionSettings {
        let (engineId, model) = engineChoice
        return TranscriptionSettings(engineId: engineId, model: model, wantSpeakers: identifySpeakers, applyDictionary: applyDictionary)
    }

    func prepareNew(_ t: inout Transcript) {
        if let p = projectFilter { t.projectId = p }
    }

    func didEnqueue(_ id: UUID) {
        verbiePose = .saved
        Task { try? await Task.sleep(nanoseconds: 700_000_000); if verbiePose == .saved { verbiePose = .working } }
    }

    func jobStarted(_ id: UUID) {}
    func runWillBegin(_ id: UUID) {}
    func queueDrained() {}
    func progress(_ id: UUID, label: String) {}

    func transcriptReady(_ id: UUID, corrections n: Int, queueEmpty: Bool) {
        verbiePose = .saved
        FolderWatcher.shared.transcriptReady(id)   // auto-export, if it came from a watched folder
        // In a batch, stay quiet until the last one; then one chime and one toast.
        if queueEmpty {
            Sounds.done()
            toast = Toast(n > 0 ? "Transcript ready · Dictionary fixed \(n) word\(n == 1 ? "" : "s")" : "Transcript ready", action: "Open") { [weak self] in self?.go(.transcript(id)) }
        }
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); if self.verbiePose == .saved { self.verbiePose = .ready } }
    }

    func jobFailed(_ id: UUID, error: Error) {
        verbiePose = .interrupted
        FolderWatcher.shared.transcriptFailed(id, error: error)
        toast = Toast("Transcription failed: \(error.localizedDescription)")
    }

    func appendReady(_ id: UUID, queueEmpty: Bool) {
        verbiePose = .saved
        if queueEmpty { Sounds.done(); toast = Toast("New recording added") }
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); if self.verbiePose == .saved { self.verbiePose = .ready } }
    }

    func appendFailed(_ id: UUID, error: Error) {
        verbiePose = .interrupted
        toast = Toast("Couldn't add the new recording: \(error.localizedDescription)")
    }

    func notify(_ message: String) { toast = Toast(message) }

    /// A recording in a language the English-only model can't hear: a toast with Download, which transcribes it
    /// again with Parakeet v3 (v3 downloads as part of that job).
    func offerParakeetV3(_ id: UUID, language: String?) {
        let message = language.map { "This recording sounds like \(LanguageDetection.name($0)). Parakeet v3 can transcribe it (about 480 MB)." }
            ?? "This recording might not be in English. Parakeet v3 can check the language and transcribe it (about 480 MB)."
        toast = Toast(message, action: "Download") { [weak self] in
            self?.coordinator.rerun(id, language: language, checkWithV3: language == nil)
        }
    }
}
