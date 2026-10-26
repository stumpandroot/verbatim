import Foundation

/// Transcribe again with Whisper Turbo: the words both apps show for it, and when it's offered. The Mac runs it
/// (WhisperKit, Whisper Large v3 Turbo, on the original audio, never a denoised copy: the noise report found
/// denoising made Whisper worse); the iPhone asks its Mac through the synced transcript (`rerunRequest`).
enum TurboRerun {
    static let title = "Transcribe again with Whisper Turbo"

    /// Why the action can't run on this transcript right now, or nil when it can.
    static func unavailableReason(_ t: Transcript) -> String? {
        if t.status != .ready { return "The transcript is still being made." }
        if t.audioFileName == nil { return "This transcript has no audio to transcribe again." }
        if t.pendingAppend != nil { return "A new recording is still being added." }
        if t.multitrack != nil { return "Multi-track recordings can't be transcribed again with Whisper Turbo yet." }
        if t.rerunRequest != nil { return "It's already being transcribed again." }
        return nil
    }

    /// The question before it runs. `onMac` false: the iPhone, where the Mac does the work.
    static func message(_ t: Transcript, onMac: Bool, needsDownload: Bool) -> String {
        var parts = ["Whisper Turbo listens to the original audio again. It's slower, and it often hears names and noisy stretches better."]
        if onMac {
            if needsDownload { parts.append("It downloads once (\(Transcript.turboSize)).") }
        } else {
            parts.append("Your Mac does this, so the transcript says “Waiting for your Mac” until it's done. The first time, your Mac downloads Whisper Turbo (\(Transcript.turboSize)).")
        }
        if t.hasHandEdits {
            parts.append("Your edits stay with the current words, and you can switch back to them.")
        } else {
            parts.append("You can switch back to the current words.")
        }
        return parts.joined(separator: " ")
    }

    /// The confirm button.
    static func confirm(needsDownload: Bool) -> String { needsDownload ? "Download and transcribe" : "Transcribe again" }

    /// "Switch to Parakeet TDT v2": the menu item that swaps in the kept words. nil when none are kept.
    static func switchTitle(_ t: Transcript) -> String? {
        guard let v = t.previousVersion else { return nil }
        return "Switch to " + (v.model.isEmpty ? "the earlier words" : v.model)
    }

    /// No Mac works on this library: what the iPhone says instead of waiting.
    static let needsMac = "Whisper Turbo runs on a Mac. Set up Verbose on your Mac with the same iCloud account, and this transcript can go there."
}
