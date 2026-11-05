import Foundation

/// The sound rules (SoundRules.swift), checked by the Linux tests (`mac/tools/test-sounds.sh`) and by both apps'
/// self-tests. `check` logs PASS or FAIL.
enum SoundChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let all = SoundMoment.allCases
        check("sounds: eleven moments, one file each, all different",
              all.count == 11 && Set(all.map(\.fileName)).count == all.count && SoundMoment.fileExtension == "caf")
        check("sounds: the dictation sounds are short (under 200 ms)", all.filter(\.frequent).allSatisfy { $0.seconds < 0.2 })
        check("sounds: frequent means dictation's four", Set(all.filter(\.frequent)) == [.dictationStart, .dictationStop, .dictationPasted, .dictationCancel])
        check("sounds: every file is under a second", all.allSatisfy { $0.seconds > 0 && $0.seconds < 1 })
        check("sounds: only the starts play into an open microphone",
              Set(all.filter(\.playsIntoMic)) == [.dictationStart, .recordingStart, .autoCall])

        // The moment for each path.
        check("sounds: a paste that landed is pasted; anything else is the error",
              SoundRules.afterPaste(.pasted) == .dictationPasted && SoundRules.afterPaste(.copiedOnly) == .error
              && SoundRules.afterPaste(.notPasted) == .error)
        check("sounds: transcription done is for recordings, never a dictation or a thought",
              SoundRules.transcriptDone(isDictation: false, isThought: false) == .transcriptionDone
              && SoundRules.transcriptDone(isDictation: true, isThought: false) == nil
              && SoundRules.transcriptDone(isDictation: false, isThought: true) == nil)
        check("sounds: a thought starts with dictation's tick and ends saved",
              SoundRules.start(thought: true) == .dictationStart && SoundRules.stop(thought: true) == .thoughtSaved)
        check("sounds: a recording starts and stops with its own pair; a call that starts on its own has its sound",
              SoundRules.start() == .recordingStart && SoundRules.stop(thought: false) == .recordingStop
              && SoundRules.start(automatic: true) == .autoCall)
        check("sounds: the iPhone plays only in front", SoundRules.phonePlays(foreground: true) && !SoundRules.phonePlays(foreground: false))

        // Two sounds within 150 ms: the second is dropped.
        var spacing = SoundSpacing()
        let first = spacing.allows(at: 10)
        let tooSoon = spacing.allows(at: 10.149)
        let later = spacing.allows(at: 10.15)
        let afterLater = spacing.allows(at: 10.2)
        check("sounds: a second sound within 150 ms is dropped, one at 150 ms plays", first && !tooSoon && later && !afterLater)
        var dropped = SoundSpacing()
        _ = dropped.allows(at: 5)
        _ = dropped.allows(at: 5.1)   // dropped: doesn't move the clock
        check("sounds: a dropped sound doesn't push the next one back", dropped.allows(at: 5.16))
        var backwards = SoundSpacing()
        _ = backwards.allows(at: 100)
        check("sounds: a clock that went back doesn't silence everything", backwards.allows(at: 50))

        // Keeping the start sound out of the recording.
        let w = MicKeepOut.window(playedAt: 100, seconds: 0.091)
        check("keep out: the window runs from the sound to its end plus the slack",
              w.from == 100 && abs(w.until - (100 + 0.091 + MicKeepOut.slack)) < 1e-9)
        // A 4,800-sample buffer at 48 kHz (0.1 s) that arrived 0.05 s after the sound: its second half was heard after it.
        func near(_ a: Int?, _ b: Int) -> Bool { a.map { abs($0 - b) <= 1 } ?? false }
        let mid = MicKeepOut.silenced(frames: 4800, rate: 48_000, arrival: 100.05, window: w)
        check("keep out: a buffer straddling the start silences only what was heard after the sound",
              near(mid?.lowerBound, 2400) && mid?.upperBound == 4800)
        // Arriving after the window: the start of the buffer is in it, the rest is kept.
        let tail = MicKeepOut.silenced(frames: 4800, rate: 48_000, arrival: w.until + 0.05, window: w)
        check("keep out: a buffer straddling the end keeps what was heard after the window",
              tail?.lowerBound == 0 && near(tail?.upperBound, 2400))
        check("keep out: a buffer heard before the sound is untouched",
              MicKeepOut.silenced(frames: 4800, rate: 48_000, arrival: 99.99, window: w) == nil)
        check("keep out: a buffer heard after the window is untouched",
              MicKeepOut.silenced(frames: 4800, rate: 48_000, arrival: w.until + 0.2, window: w) == nil)
        check("keep out: a buffer inside the window is silenced whole",
              MicKeepOut.silenced(frames: 1600, rate: 16_000, arrival: 100.15, window: w) == 0..<1600)
        check("keep out: dictation silences at most about 170 ms after its tick", w.until - w.from < 0.18)
        let rec = MicKeepOut.window(playedAt: 0, seconds: SoundMoment.recordingStart.seconds)
        check("keep out: a recording's start silences under half a second", rec.until - rec.from < 0.5)
        check("keep out: the window is forgotten a second after it ends", !MicKeepOut.isOver(w, at: w.until + 0.5) && MicKeepOut.isOver(w, at: w.until + 1.1))
        check("keep out: empty buffers and broken rates silence nothing",
              MicKeepOut.silenced(frames: 0, rate: 48_000, arrival: 100.05, window: w) == nil
              && MicKeepOut.silenced(frames: 480, rate: 0, arrival: 100.05, window: w) == nil)
    }
}
