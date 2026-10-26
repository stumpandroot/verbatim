import SwiftUI

/// Transcribe again with Whisper Turbo on the Mac (TurboRerun.swift), switching between the two sets of words, and
/// the iPhone's requests this Mac picks up through sync.
extension AppState {
    /// Whisper Turbo's files are already on this Mac (no download before it runs).
    var turboDownloaded: Bool { WhisperEngine.localFolder(Transcript.turboModel) != nil }

    /// Runs it, once the screen has asked (and offered the download when the model isn't here: the job downloads it).
    func transcribeAgainWithTurbo(_ id: UUID) {
        guard let t = store.transcript(id), TurboRerun.unavailableReason(t) == nil else { return }
        player.stop()
        Log.note("turbo: transcribe again (model \(turboDownloaded ? "on this Mac" : "downloads first"))")
        coordinator.rerun(id, engine: Transcript.turboEngine, model: Transcript.turboModel)
    }

    /// Swaps the words with the kept version (Switch to …). Notes and moments follow by time.
    func switchTranscriptVersion(_ id: UUID) {
        guard store.transcript(id)?.previousVersion != nil else { return }
        store.update(id) { _ = $0.switchVersion() }
        toast = Toast("Switched to \(store.transcript(id)?.model ?? "the other words")")
    }

    /// An iPhone asked for Whisper Turbo: this Mac takes the job (`processingDevice`), and the iPhone shows
    /// "Transcribing on" this Mac until the words are in.
    func claimIfPendingRerun(_ t: Transcript) {
        guard let req = t.rerunRequest, t.status == .ready, t.processingDevice == nil, t.deletedAt == nil,
              t.audioFileName != nil, t.pendingAppend == nil, t.multitrack == nil, req.engine == Transcript.turboEngine else { return }
        Log.note("turbo: picking up a request from \(req.deviceName.isEmpty ? "another device" : req.deviceName)")
        coordinator.rerun(t.id, engine: req.engine, model: req.model)
    }
}
