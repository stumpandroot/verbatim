import Foundation

// Verbose's interface sounds (DESIGN.md §7, Sounds): which moments have one, how long each file runs, the rule that
// drops a second sound within 150 ms of the first, and when the microphone starts keeping audio after a start sound.
// Pure, so the Linux tests (mac/tools/test-sounds.sh) and both apps' self-tests check it (SoundChecks.swift). Both apps
// play through `Sounds` (Audio/SoundPlayer.swift); the files are in Resources/Sounds, with their sources in its README.

/// A moment that plays a sound. The raw value is the file's name in Resources/Sounds (`.caf`).
enum SoundMoment: String, CaseIterable {
    /// Dictation starts listening (and a thought starts: a quick capture, like dictation).
    case dictationStart = "dictation-start"
    /// Dictation stops listening.
    case dictationStop = "dictation-stop"
    /// Dictation's words were pasted or inserted.
    case dictationPasted = "dictation-pasted"
    /// Dictation was cancelled.
    case dictationCancel = "dictation-cancel"
    /// A thought was saved.
    case thoughtSaved = "thought-saved"
    /// A recording you started by hand: a voice note, a meeting, a call, Live captions.
    case recordingStart = "recording-start"
    /// A recording stops.
    case recordingStop = "recording-stop"
    /// A call recording started on its own (the call you set up to wait for began).
    case autoCall = "auto-call"
    /// A recording's transcript is ready (never a dictation or a thought).
    case transcriptionDone = "transcription-done"
    /// A summary is written.
    case summaryReady = "summary-ready"
    /// Something failed that you need to act on: a recording or dictation that couldn't start or hear the mic, words
    /// that weren't pasted, a transcription that failed.
    case error

    static let fileExtension = "caf"
    var fileName: String { rawValue }

    /// Each file's length in seconds (48 kHz, 16-bit mono).
    var seconds: Double {
        switch self {
        case .dictationStart: return 0.091
        case .dictationStop: return 0.091
        case .dictationPasted: return 0.187
        case .dictationCancel: return 0.094
        case .thoughtSaved: return 0.204
        case .recordingStart: return 0.383
        case .recordingStop: return 0.395
        case .autoCall: return 0.465
        case .transcriptionDone: return 0.615
        case .summaryReady: return 0.798
        case .error: return 0.262
        }
    }

    /// Played just before the microphone takes anything in: the recording is armed when it ends (`MicArm`).
    var opensMic: Bool { self == .dictationStart || self == .recordingStart || self == .autoCall }

    /// Heard many times a day: short and quiet (the calm tier).
    var frequent: Bool { [.dictationStart, .dictationStop, .dictationPasted, .dictationCancel].contains(self) }
}

/// Where dictation's words went, for its last sound.
enum PasteResult {
    case pasted
    /// No text field had focus, so the words went to the clipboard.
    case copiedOnly
    /// The app didn't take the paste, Accessibility is off, typing stopped part way, or a password field had focus.
    case notPasted
}

enum SoundRules {
    /// The last sound of a dictation: pasted when the words landed; otherwise the words are on the clipboard and you
    /// have to paste them, which is the error sound.
    static func afterPaste(_ r: PasteResult) -> SoundMoment {
        r == .pasted ? .dictationPasted : .error
    }

    /// Transcription done plays for recordings only: a dictation pastes, and a thought fills in its words on its page.
    static func transcriptDone(isDictation: Bool, isThought: Bool) -> SoundMoment? {
        isDictation || isThought ? nil : .transcriptionDone
    }

    /// The start of a recording: a thought is a quick capture (dictation's tick), a call that starts on its own has its
    /// own sound, and everything else is a recording you started.
    static func start(thought: Bool = false, automatic: Bool = false) -> SoundMoment {
        thought ? .dictationStart : (automatic ? .autoCall : .recordingStart)
    }

    /// The end of a recording: a thought saved, or a recording stopped.
    static func stop(thought: Bool) -> SoundMoment { thought ? .thoughtSaved : .recordingStop }

    /// The iPhone plays a sound only with Verbose in front, as it does haptics (DESIGN.md §7).
    static func phonePlays(foreground: Bool) -> Bool { foreground }
}

/// Two sounds never play within 150 ms of each other: the second is dropped, so a stop and an error (or two
/// results) never run together.
struct SoundSpacing {
    static let minimumGap: Double = 0.15
    private(set) var lastPlayed: Double?

    /// True when a sound may play at `now` (system uptime, seconds), and counts it as played.
    mutating func allows(at now: Double) -> Bool {
        if let last = lastPlayed, now >= last, now - last < Self.minimumGap { return false }
        lastPlayed = now
        return true
    }
}

/// The start sound plays before the microphone takes anything in (Tim, November 7, 2026). Dictation's tick, a
/// recording's start, and a call's start play first; the recording is armed when the sound ends, plus a little for the
/// speakers' latency, and keeps every sample from then on. Samples the microphone delivers before that (it may already
/// be opening while the sound plays) are never written, tapped for live words, or counted: the recording starts after
/// the sound. No sample is ever replaced with silence. With the sound off, nothing waits: the recording keeps
/// everything from its first sample.
enum MicArm {
    /// Added after the sound ends: the speakers' output latency and the input's delivery, both well under this.
    static let slack: Double = 0.08

    /// System uptime when the recording starts keeping samples, for a sound asked to play at `playedAt`.
    static func at(playedAt: Double, seconds: Double) -> Double { playedAt + max(0, seconds) + slack }

    /// The samples of one buffer to keep: `frames` samples at `rate` that arrived at `arrival` (system uptime), so
    /// sample `i` was heard at about `arrival - (frames - i) / rate`. Those heard at or after `armAt` are kept, always
    /// a tail of the buffer (`lo..<frames`). Nil when every sample came before it (the buffer is dropped).
    static func kept(frames: Int, rate: Double, arrival: Double, armAt: Double) -> Range<Int>? {
        guard frames > 0 else { return nil }
        guard rate > 0 else { return 0..<frames }
        let n = Double(frames)
        // Heard at or after `armAt`: i >= n - (arrival - armAt) * rate
        let low = n - (arrival - armAt) * rate
        let lo = max(0, Int(low.rounded(.up)))
        return lo < frames ? lo..<frames : nil
    }

    /// Once the first buffer that arrived after `armAt` has been kept, the arm is over and can be forgotten.
    static func isOver(_ armAt: Double, at now: Double) -> Bool { now > armAt + 1 }
}
