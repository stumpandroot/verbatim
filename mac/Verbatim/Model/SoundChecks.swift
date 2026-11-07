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
        check("sounds: only the starts play before the microphone takes anything in",
              Set(all.filter(\.opensMic)) == [.dictationStart, .recordingStart, .autoCall])

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

        // The start sound first; the recording keeps every sample from when it ends (MicArm). Nothing is silenced.
        let arm = MicArm.at(playedAt: 100, seconds: 0.091)
        check("arm: the recording starts keeping samples when the sound ends, plus the slack", abs(arm - (100 + 0.091 + MicArm.slack)) < 1e-9)
        func near(_ a: Int?, _ b: Int) -> Bool { a.map { abs($0 - b) <= 1 } ?? false }
        // A 4,800-sample buffer at 48 kHz (0.1 s) that arrived 0.05 s after the arm: its second half was heard after it.
        let straddle = MicArm.kept(frames: 4800, rate: 48_000, arrival: arm + 0.05, armAt: arm)
        check("arm: a buffer straddling the arm keeps only what was heard after it, as a tail",
              near(straddle?.lowerBound, 2400) && straddle?.upperBound == 4800)
        check("arm: a buffer heard during the sound is dropped, not silenced", MicArm.kept(frames: 4800, rate: 48_000, arrival: arm - 0.01, armAt: arm) == nil)
        check("arm: a buffer heard after the arm is kept whole", MicArm.kept(frames: 4800, rate: 48_000, arrival: arm + 0.2, armAt: arm) == 0..<4800)
        check("arm: an arm already past keeps everything (sounds off, or a slow microphone)",
              MicArm.kept(frames: 1600, rate: 16_000, arrival: 500, armAt: MicArm.at(playedAt: 0, seconds: 0.383)) == 0..<1600)
        check("arm: a kept range always runs to the buffer's end, so nothing inside the recording is cut",
              stride(from: arm - 0.2, through: arm + 0.2, by: 0.013).allSatisfy { t in MicArm.kept(frames: 4800, rate: 48_000, arrival: t, armAt: arm).map { $0.upperBound == 4800 } ?? true })
        check("arm: dictation waits at most about 170 ms after its tick", arm - 100 < 0.18)
        check("arm: a recording's start waits under half a second", MicArm.at(playedAt: 0, seconds: SoundMoment.recordingStart.seconds) < 0.5)
        check("arm: a call's own start waits under 0.55 s", MicArm.at(playedAt: 0, seconds: SoundMoment.autoCall.seconds) < 0.55)
        check("arm: forgotten a second after it", !MicArm.isOver(arm, at: arm + 0.5) && MicArm.isOver(arm, at: arm + 1.1))
        check("arm: empty buffers keep nothing; a broken rate keeps everything",
              MicArm.kept(frames: 0, rate: 48_000, arrival: arm + 1, armAt: arm) == nil
              && MicArm.kept(frames: 480, rate: 0, arrival: arm - 1, armAt: arm) == 0..<480)
    }
}
