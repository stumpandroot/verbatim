import Foundation

// A muted microphone (DESIGN.md §6.10, A muted microphone). Touch-mute USB mics (a Shure MV7, a Rode NT-USB+) are easy to mute by
// accident, and a recording made through a muted mic is silent. Two parts:
//
// - When a recording counts its mic as muted (`MuteRules`): exact digital silence for a moment, which a muted USB mic
//   sends and a quiet room never does. On the Mac, also when the built-in mic hears speech while the chosen mic stays
//   near silent, for mics that send faint noise when muted.
// - On the Mac, the backup (`MuteSplice`): the built-in mic runs beside the chosen mic, keeping its last 15 seconds.
//   Quiet audio from the chosen mic is held back for up to 12 seconds instead of written at once. Sound from the chosen
//   mic writes what was held; a mute drops what was held and writes the built-in mic's audio for the same span in its
//   place, so the seconds before the mute was noticed aren't lost. The iPhone can record from one input at a time, so
//   it moves to its own microphone when it notices the mute instead.
//
// Plain Foundation and generic over the audio, so mac/tools/test-mute-backup.sh runs it on Linux with strings for audio.

enum MuteRules {
    // MARK: Exact digital silence

    /// Exact digital silence this long from the start (or after the input changed) counts as muted.
    static let startWindow: Double = 0.6
    /// Partway through, a mic's noise gate can send zeros between words, so silence counts as muted only after this long.
    static let midWindow: Double = 3
    /// The iPhone's mid window. A move there doesn't undo itself (the iPhone can't hear the muted mic while recording
    /// from its own), and a wireless mic's receiver can send zeros through a pause, so it waits longer than the Mac,
    /// whose move undoes itself when the mic is heard again.
    static let phoneMidWindow: Double = 6

    /// Whether exact digital silence has lasted long enough to count as muted. `lastSignal`: uptime of the last audio
    /// that wasn't exact silence, nil when none has arrived. `since`: uptime when the recording (or this input, or the
    /// capture after a restart) started.
    static func silent(lastSignal: Double?, since: Double, now: Double, midWindow: Double = midWindow) -> Bool {
        if let last = lastSignal { return now - max(last, since) >= midWindow }
        return now - since >= startWindow
    }

    // MARK: Levels (RMS of a buffer, 0…1)

    /// Below this (about -74 dBFS) the chosen mic sends what a muted mic sends, and the backup holds its audio back. A
    /// working mic's own noise in a quiet room is above it, so its quiet passages (the end of a phrase) are written at
    /// once and live words never wait for them; only near-silence waits.
    static let quietLevel: Float = 0.0002
    /// The built-in mic hearing speech: someone talking near the Mac.
    static let speechLevel: Float = 0.02
    /// The chosen mic is back after a comparison moved the recording: clearly above a muted mic's floor (about -54 dBFS),
    /// which speech into any working mic is, at any gain.
    static let backLevel: Float = 0.002

    static func quiet(_ rms: Float) -> Bool { rms < quietLevel }

    /// The meter's height for a buffer's RMS. Speech sits around 0.02–0.15 on a Mac mic; this maps it onto most of the bar.
    static func meterLevel(_ rms: Float) -> Float { min(1, pow(max(0, rms - 0.004) * 6, 0.5)) }

    // MARK: Comparing the two mics (Mac)

    /// How long the chosen mic must have stayed near silent, and for how much of that the built-in mic heard speech,
    /// before the chosen mic counts as muted even though it isn't sending exact silence. Not for a meeting's mic track
    /// or Audio only (`Recorder.comparesMics`).
    static let compareHold: Double = 4
    static let compareSpeech: Double = 2

    static func mutedByComparison(heldSeconds: Double, backupSpeechSeconds: Double) -> Bool {
        heldSeconds >= compareHold && backupSpeechSeconds >= compareSpeech
    }

    // MARK: The backup (Mac)

    /// The built-in mic's audio kept, in seconds.
    static let backupSeconds: Double = 15
    /// The chosen mic's quiet audio held back at most, in seconds. Shorter than the backup, so the backup always covers it.
    static let holdLimit: Double = 12

    /// Settings › Recording and transcription › Speakers › Back up a muted mic (on unless turned off).
    static let backupKey = "recording.micBackup"
    static func backupEnabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: backupKey) as? Bool ?? true }

    // MARK: iPhone

    /// The inputs the iPhone watches for a mute: wired and USB mics. Not Bluetooth: AirPods send silence while their
    /// link switches at the start of a recording, and their mute only exists on calls. Not the iPhone's own microphone,
    /// which has nowhere better to go.
    static func watchesForMute(_ kind: RecordingInput.Kind) -> Bool { kind == .usb || kind == .wired }
}

/// Which audio reaches the recording's file while the Mac's built-in mic backs up the chosen mic. A value type with no
/// clock and no audio of its own: the caller passes each buffer with its arrival time (the end of the buffer, in
/// seconds of uptime), its length, and its level, and writes what comes back, in order. `Payload` is the audio buffer
/// (strings in the tests).
struct MuteSplice<Payload> {
    struct Piece {
        var payload: Payload
        /// Uptime when it arrived: the end of its audio.
        var at: Double
        var seconds: Double
        /// Backup pieces: the built-in mic heard speech in it.
        var speech: Bool = false
        var start: Double { at - seconds }
    }

    /// The chosen mic's quiet audio, held back. Oldest first.
    private(set) var held: [Piece] = []
    private(set) var heldSeconds: Double = 0
    /// The built-in mic's last `MuteRules.backupSeconds`. Oldest first.
    private(set) var ring: [Piece] = []
    private var ringSeconds: Double = 0
    /// The built-in mic is being written instead of the chosen mic.
    private(set) var onBackup = false
    /// Uptime of the last buffer from the chosen mic at `MuteRules.backLevel` or louder.
    private(set) var primaryLoudAt: Double?
    /// The chosen mic's first buffer is written at once, however quiet: a meeting's mic track takes its start time
    /// from when its first audio is written (MeetingAlign's TrackClock), so it must not wait.
    private var wroteFirst = false

    /// When the held audio starts.
    var holdStart: Double? { held.first?.start }

    /// Seconds of the held span in which the built-in mic heard speech.
    var backupSpeechSeconds: Double {
        guard let start = holdStart else { return 0 }
        return ring.reduce(0) { $1.speech && $1.at > start ? $0 + $1.seconds : $0 }
    }

    /// A buffer from the chosen mic. Loud: what was held, then this. Quiet: held, and the oldest held audio past
    /// `MuteRules.holdLimit` comes back to write. On the backup: nothing (the chosen mic is only listened to).
    mutating func primary(_ p: Payload, at: Double, seconds: Double, rms: Float) -> [Payload] {
        if rms >= MuteRules.backLevel { primaryLoudAt = at }
        if onBackup { return [] }
        if !MuteRules.quiet(rms) || !wroteFirst {
            wroteFirst = true
            let out = held.map(\.payload) + [p]
            clearHold()
            return out
        }
        held.append(Piece(payload: p, at: at, seconds: seconds))
        heldSeconds += seconds
        var out: [Payload] = []
        while heldSeconds > MuteRules.holdLimit, held.count > 1 {
            let first = held.removeFirst()
            heldSeconds -= first.seconds
            out.append(first.payload)
        }
        return out
    }

    /// A buffer from the built-in mic: kept for the last `MuteRules.backupSeconds`, and written while on the backup.
    mutating func backup(_ p: Payload, at: Double, seconds: Double, rms: Float) -> [Payload] {
        ring.append(Piece(payload: p, at: at, seconds: seconds, speech: rms >= MuteRules.speechLevel))
        ringSeconds += seconds
        while ringSeconds > MuteRules.backupSeconds, ring.count > 1 { ringSeconds -= ring.removeFirst().seconds }
        return onBackup ? [p] : []
    }

    /// The chosen mic is muted: from now on the built-in mic is written. What was held is replaced by the built-in
    /// mic's audio for the same span. Held audio from before the backup's oldest audio (the built-in mic opened after
    /// the recording started) is written as it was, so the recording keeps its length.
    mutating func useBackup() -> [Payload] {
        guard !onBackup else { return [] }
        onBackup = true
        guard let start = holdStart else { return [] }
        let backupStart = ring.first?.start ?? .infinity
        let before = held.filter { $0.at <= backupStart }.map(\.payload)
        // A backup buffer counts when most of it falls after the held audio began, so none is written twice.
        let covered = ring.filter { $0.at - $0.seconds / 2 > start }.map(\.payload)
        clearHold()
        return before + covered
    }

    /// The chosen mic is back: its audio is written again.
    mutating func usePrimary() {
        onBackup = false
        clearHold()
    }

    /// Everything held, to write now (before a pause, a stop, or a change of mic).
    mutating func flush() -> [Payload] {
        let out = held.map(\.payload)
        clearHold()
        return out
    }

    private mutating func clearHold() {
        held = []
        heldSeconds = 0
    }
}
