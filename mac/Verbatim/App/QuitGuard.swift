import AppKit

/// Quitting while recording (or capturing an app's audio) asks first: Save stops and saves the recording, then
/// quits; Cancel keeps recording. Quitting while a stopped recording is still being saved waits for it.
final class QuitGuard: NSObject, NSApplicationDelegate {
    @MainActor static weak var app: AppState?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app = Self.app, app.recordingNeedsSaveBeforeQuit else { return .terminateNow }
        // Only saving is left (Stop was already pressed): finish it, then quit.
        if !app.recorder.isRecording, !app.capture.isCapturing {
            Log.note("quit: waiting for a recording to finish saving")
            Task { @MainActor in
                await app.saveRecordingsForQuit()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = "Stop and save the recording?"
        alert.informativeText = "Verbatim saves what you recorded and transcribes it the next time it opens."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.note("quit: cancelled to keep recording")
            return .terminateCancel
        }
        Log.note("quit: saving the recording first")
        Task { @MainActor in
            await app.saveRecordingsForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
