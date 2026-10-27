import Foundation

// Audio only (approved mockup "Verbose Brain Dump", sections 2 to 4, October 27, 2026): a recording kind that keeps
// the sound and never makes a transcript, for a melody hummed into the phone, a guitar part, or a room to remember.
// It records with voice processing off, saves as it goes, and stops there: the transcription queue, AutoLabel, Ask's
// index, and Run automatically leave it alone. Transcribe (Transcribe later) makes a transcript from the same audio
// and files it as a voice note, or as the kind you pick with Transcribe as; the title, notes, moments, and audio stay.
//
// Pure Foundation, so mac/tools/test-templates.sh checks these rules on Linux.

enum AudioOnlyRules {
    /// The transcription queue leaves an Audio only recording alone until you ask for its transcript (Transcribe sets
    /// it to processing). A recovered or synced Audio only recording is never queued on its own.
    static func skipsQueue(_ t: Transcript) -> Bool { t.isAudioOnly && t.status != .processing }

    /// What AutoLabel may label: never Audio only (it has no words, and its kind is yours).
    static func labels(_ t: Transcript) -> Bool { !t.isAudioOnly }

    /// What Ask's index reads: never Audio only.
    static func indexes(_ t: Transcript) -> Bool { !t.isAudioOnly }

    /// Transcribe offers each kind, like Record as, without Audio only itself (and without Thought, which is a flow,
    /// not a kind you transcribe as): Voice note (nil: Verbose picks), then the kinds in Record as's order.
    static let transcribeChoices: [RecordingKind?] = [nil, .meeting, .interview, .journal, .talk, .idea, .brainDump]

    /// A Transcribe choice's name: "Voice note", "Meeting", …, "Thought", "Brain dump".
    static func choiceName(_ k: RecordingKind?) -> String {
        guard let k else { return "Voice note" }
        switch k {
        case .journal: return "Journal entry"
        case .idea: return "Thought"
        default: return k.label
        }
    }

    /// "Transcribe as a meeting", for the menu's VoiceOver and the Mac's title-case menus.
    static func menuTitle(_ k: RecordingKind?) -> String { "Transcribe as \(choiceName(k).lowercased())" }

    /// Can Transcribe run on it: an Audio only recording with audio, not already transcribing.
    static func canTranscribe(_ t: Transcript) -> Bool {
        t.isAudioOnly && t.audioFileName != nil && t.status != .processing && t.pendingAppend == nil && t.deletedAt == nil
    }

    /// The line under the player on the detail screen and in the Library row: "No transcript", or the progress.
    static func statusLine(_ t: Transcript) -> String {
        switch t.status {
        case .processing: return t.stageText.isEmpty ? "Transcribing" : t.stageText
        case .failed: return "Couldn't transcribe. Your audio is safe."
        case .ready: return "No transcript"
        }
    }

    /// VoiceOver's label for a Library row: "Melody for the second verse, Audio only, 1 minute 12 seconds, no
    /// transcript, 2 moments".
    static func accessibilityLabel(_ t: Transcript) -> String {
        var parts = [t.title, "Audio only", spokenLength(t.duration), "no transcript"]
        let n = t.notes.filter { $0.at != nil }.count
        if n > 0 { parts.append(n == 1 ? "1 moment" : "\(n) moments") }
        return parts.joined(separator: ", ")
    }

    /// "1 minute 12 seconds".
    static func spokenLength(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        var out: [String] = []
        if h > 0 { out.append(h == 1 ? "1 hour" : "\(h) hours") }
        if m > 0 { out.append(m == 1 ? "1 minute" : "\(m) minutes") }
        if sec > 0 || out.isEmpty { out.append(sec == 1 ? "1 second" : "\(sec) seconds") }
        return out.joined(separator: " ")
    }
}

extension Transcript {
    /// Transcribe on an Audio only recording, as its job starts: it stays Audio only (and on its detail screen, with
    /// the progress where Transcribe was) until the words are in.
    mutating func beginTranscribeLater() {
        guard isAudioOnly else { return }
        status = .processing
        error = nil
        stage = "Queued"
    }

    /// The words are in: no longer Audio only. With no kind picked it's a plain voice note (kind empty, so AutoLabel
    /// may suggest one); a kind picked with Transcribe as is yours, and its Run automatically template follows the
    /// normal rules. The title you typed, the notes, the moments, and the audio stay. Anything that isn't Audio only
    /// is left alone.
    mutating func finishTranscribeLater(as picked: RecordingKind?) {
        guard isAudioOnly else { return }
        if let picked, picked != .audio {
            kind = picked
            kindIsAuto = false
        } else {
            kind = nil
            kindIsAuto = true
        }
    }
}

/// Audio only's words, the same on both apps.
enum AudioOnlyCopy {
    /// After Stop.
    static let saved = "Saved. No transcript."
    /// The recorder's headline (Verbose style).
    static let headline = "Go ahead, I\u{2019}ll keep the sound."
    /// Stop's name on the recorder.
    static let stop = "Stop and save"
    /// Under Transcribe on the detail screen.
    static let transcribeFooter = "Adds a transcript and files it as a voice note. The audio, title, notes, and moments stay."
    /// Settings › Templates, beside Audio only in Run automatically.
    static let noTemplate = "No transcript, so no template runs"
}
