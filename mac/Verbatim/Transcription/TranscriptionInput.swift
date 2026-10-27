import Foundation
import AVFoundation

/// The file a transcription job reads. Audio only keeps the input's own rate in 24-bit (`SoundFormat`, Recorder.swift);
/// the engines, speech detection, and speaker finding all work at 16 kHz mono. A sound file is first copied to 16 kHz
/// mono, the same working copy multi-track makes of each track (`MultitrackAudio.prepareTrack`), and the copy is removed
/// when the job ends. Every other file (16 kHz recordings, imports) is read as it is. Times are the same in both, so
/// the words line up with the original.
enum TranscriptionInput {
    /// A WAV above 16 kHz: Audio only's file, before or after Transcribe later.
    static func needsCopy(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "wav", let f = try? AVAudioFile(forReading: url) else { return false }
        return SoundFormat.isSoundFile(url, rate: f.processingFormat.sampleRate)
    }

    /// `url` itself, or a 16 kHz mono copy of it in the temporary folder. Call `finish` with the result when done.
    static func prepare(_ url: URL) throws -> URL {
        guard needsCopy(url) else { return url }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-\(UUID().uuidString).wav")
        let started = Date()
        do {
            let made = try MultitrackAudio.prepareTrack(url, to: dest)
            Log.note("transcribe: 16 kHz copy of \(url.lastPathComponent) (\(String(format: "%.1f", made.duration)) s) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return dest
    }

    /// Removes the copy `prepare` made (nothing when it handed back the original).
    static func finish(_ used: URL, original: URL) {
        guard used != original else { return }
        try? FileManager.default.removeItem(at: used)
    }
}

/// Self-test checks for Audio only's file (`SoundFormat`), run by both self-tests (UITest on Mac, PhoneUITest on
/// iPhone): the rate and depth it's written at, sound above 8 kHz surviving, crash repair and joining of 24-bit
/// segments, and Transcribe later's 16 kHz copy. Writes only to a temporary folder, removed at the end.
enum SoundFormatChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sound-checks-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // One second (and one frame, so 24-bit data ends on an odd byte) through the recorder's writer.
        func record(_ name: String, inputRate: Double, sound: Bool, frames: Int? = nil) -> (url: URL, seconds: Double)? {
            let url = dir.appendingPathComponent(name)
            guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
                  let w = try? RecordingWriter(url: url, inputFormat: input, sound: sound),
                  let buf = tone(rate: inputRate, frames: frames ?? Int(inputRate) + 1) else { return nil }
            _ = w.write(buf)
            let seconds = w.seconds
            _ = w.close()
            return (url, seconds)
        }
        func file(_ url: URL?) -> AVAudioFile? { url.flatMap { try? AVAudioFile(forReading: $0) } }
        func bits(_ f: AVAudioFile?) -> UInt32 { f?.fileFormat.streamDescription.pointee.mBitsPerChannel ?? 0 }

        let at48 = record("a48.wav", inputRate: 48_000, sound: true)
        let f48 = file(at48?.url)
        check("audio only: a 48 kHz mic makes a 48 kHz, 24-bit mono file", f48?.fileFormat.sampleRate == 48_000
              && f48?.fileFormat.channelCount == 1 && bits(f48) == 24)
        check("audio only: the length uses the file's own rate", abs((at48?.seconds ?? 0) - 1) < 0.02
              && abs(Double(f48?.length ?? 0) / 48_000 - 1) < 0.02)
        let f44 = file(record("a44.wav", inputRate: 44_100, sound: true)?.url)
        check("audio only: a 44.1 kHz mic stays 44.1 kHz", f44?.fileFormat.sampleRate == 44_100 && bits(f44) == 24)
        let f16 = file(record("a16.wav", inputRate: 16_000, sound: true)?.url)
        check("audio only: a 16 kHz mic (AirPods on the call link) is saved at 48 kHz, never under 44.1 kHz",
              (f16?.fileFormat.sampleRate ?? 0) >= SoundFormat.minimumRate && abs(Double(f16?.length ?? 0) / 48_000 - 1) < 0.02)
        let speech = record("v48.wav", inputRate: 48_000, sound: false)
        let fv = file(speech?.url)
        check("voice notes stay 16 kHz, 16-bit", fv?.fileFormat.sampleRate == 16_000 && bits(fv) == 16)
        check("audio only: sound above 8 kHz is kept (a 12 kHz tone), and a voice note drops it",
              level(file(at48?.url), hz: 12_000) > 0.1 && level(file(speech?.url), hz: 12_000) < 0.01)

        // A long Audio only recording the app quit in: the second segment's header was never written and it ends part
        // way through a frame. Repair and joining keep whole 3-byte frames, so the joined audio isn't shifted into noise.
        if let one = record("long.wav", inputRate: 48_000, sound: true, frames: 48_001) {
            let two = RecordingSegments.url(for: one.url, index: 2)
            let made = record(two.lastPathComponent, inputRate: 48_000, sound: true, frames: 48_001)
            var damaged = false
            if made != nil, let h = try? FileHandle(forUpdating: two), let l = WavRepair.layout(two) {
                try? WavRepair.writeSizes(h, layout: l, dataLength: 0)
                _ = try? h.seekToEnd(); try? h.write(contentsOf: Data([0x7f]))   // a frame cut short
                try? h.close()
                damaged = true
            }
            let joined = damaged ? RecordingSegments.join([one.url, two]) : nil
            let f = file(joined?.url)
            check("audio only: a 24-bit recording the app quit in is repaired and joined whole", f?.length == 96_002
                  && abs((joined?.seconds ?? 0) - 96_002.0 / 48_000) < 0.001 && peak(f) < 0.6 && !fm.fileExists(atPath: two.path))
        } else {
            check("audio only: a 24-bit recording the app quit in is repaired and joined whole", false)
        }

        // Transcribe later: the engines hear a 16 kHz mono copy of the same length; nothing is left behind.
        if let sound = at48?.url, let voice = speech?.url, let copy = try? TranscriptionInput.prepare(sound) {
            let fc = file(copy)
            let same = abs(Double(fc?.length ?? 0) / 16_000 - Double(f48?.length ?? 0) / 48_000) < 0.01
            TranscriptionInput.finish(copy, original: sound)
            check("transcribe later: an Audio only file is heard through a 16 kHz mono copy of the same length, then removed",
                  TranscriptionInput.needsCopy(sound) && !TranscriptionInput.needsCopy(voice) && copy != sound
                  && fc?.fileFormat.sampleRate == 16_000 && fc?.fileFormat.channelCount == 1 && same && !fm.fileExists(atPath: copy.path)
                  && fm.fileExists(atPath: sound.path) && abs(Double((try? SectionAudio(url: sound))?.totalSamples ?? 0) - 16_000) < 20)
            let dest = dir.appendingPathComponent("continued.wav")
            let joined = try? Continuation.join(sound, voice, to: dest)
            check("continue: a transcribed Audio only recording keeps its rate when more is added", file(dest)?.fileFormat.sampleRate == 48_000
                  && abs((joined?.total ?? 0) - 2) < 0.05 && abs((joined?.first ?? 0) - 1) < 0.02)
        } else {
            check("transcribe later: an Audio only file is heard through a 16 kHz mono copy of the same length, then removed", false)
        }
    }

    /// A 440 Hz tone at 0.3 plus, where the rate can carry it, a 12 kHz tone at 0.2.
    static func tone(rate: Double, frames: Int) -> AVAudioPCMBuffer? {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)), let ch = b.floatChannelData?[0] else { return nil }
        b.frameLength = AVAudioFrameCount(frames)
        let high = rate > 24_000
        for i in 0..<frames {
            let t = Double(i) / rate
            ch[i] = Float(0.3 * sin(2 * .pi * 440 * t) + (high ? 0.2 * sin(2 * .pi * 12_000 * t) : 0))
        }
        return b
    }

    /// The amplitude of `hz` in the file (Goertzel over its first second); 0 when the rate can't carry it.
    private static func level(_ f: AVAudioFile?, hz: Double) -> Double {
        guard let f, let s = samples(f), hz < f.processingFormat.sampleRate / 2 else { return 0 }
        let n = min(s.count, Int(f.processingFormat.sampleRate))
        let w = 2 * Double.pi * hz / f.processingFormat.sampleRate
        let c = 2 * cos(w)
        var a = 0.0, b = 0.0
        for i in 0..<n { let x = Double(s[i]) + c * a - b; b = a; a = x }
        let power = a * a + b * b - c * a * b
        return 2 * sqrt(max(0, power)) / Double(max(1, n))
    }

    private static func peak(_ f: AVAudioFile?) -> Float {
        guard let f, let s = samples(f) else { return 1 }
        return s.map { abs($0) }.max() ?? 1
    }

    private static func samples(_ f: AVAudioFile) -> [Float]? {
        f.framePosition = 0
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil, let ch = b.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(b.frameLength)))
    }

    /// Transcribe later on a real Audio only file, through the queue and the engine (both self-tests): a 48 kHz,
    /// 24-bit recording kept as Audio only, then transcribed. Speech-like noise, so the words may be few or none; the
    /// check is that the job reads the file (through its 16 kHz copy) and finishes, the recording becomes a voice note
    /// with its title and moments, the file stays at its own rate, and no copy is left. Waits up to 2 minutes; a job
    /// still running then (a model downloading, a busy queue) is logged, not counted. Returns the transcript's ID.
    @MainActor
    static func transcribeLater(store: Store, coordinator: TranscriptionCoordinator, check: (String, Bool) -> Void) async -> UUID? {
        let fm = FileManager.default
        func copies() -> Int {
            ((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("transcribe-") && $0.hasSuffix(".wav") }.count
        }
        let before = copies()
        guard let made = soundFile(at: store.newRecordingURL()), let name = store.adoptRecording(made) else {
            check("transcribe later: an Audio only recording at 48 kHz is transcribed", false); return nil
        }
        var t = PlanChecks.audioOnly(at: Date().addingTimeInterval(-700))
        t.title = "Hummed chorus, take 2"
        t.audioFileName = name
        t.duration = 4
        coordinator.keepAudioOnly(t)
        coordinator.transcribeLater(t.id)
        var waited = 0.0
        while store.transcript(t.id)?.status == .processing, waited < 120 {
            try? await Task.sleep(nanoseconds: 500_000_000); waited += 0.5
        }
        let done = store.transcript(t.id)
        guard done?.status != .processing else {
            Log.note("UITEST NOTE transcribe later on a 48 kHz file still running after 2 minutes; not counted")
            return t.id
        }
        let rate = done.flatMap { store.audioURL(for: $0) }.flatMap { try? AVAudioFile(forReading: $0) }?.fileFormat.sampleRate ?? 0
        check("transcribe later: an Audio only recording at 48 kHz is transcribed, and its file keeps its rate", done?.status == .ready
              && done?.isAudioOnly == false && done?.kind == nil && done?.title == "Hummed chorus, take 2" && done?.notes.count == 2
              && rate >= SoundFormat.minimumRate && copies() <= before)
        if done?.status == .failed { Log.note("UITEST NOTE transcribe later failed: \(done?.error ?? "no error")") }
        return t.id
    }

    /// A short Audio only file for the self-tests' Transcribe later run: speech-like noise at 48 kHz, through the
    /// recorder's writer. Nil when it couldn't be written.
    static func soundFile(at url: URL, seconds: Double = 4) -> URL? {
        let rate = 48_000.0
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let w = try? RecordingWriter(url: url, inputFormat: input, sound: true) else { return nil }
        let n = Int(rate * seconds)
        guard let b = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(n)), let ch = b.floatChannelData?[0] else { _ = w.close(); return nil }
        b.frameLength = AVAudioFrameCount(n)
        var seed: UInt32 = 2026
        for i in 0..<n {
            let t = Double(i) / rate
            seed = seed &* 1664525 &+ 1013904223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let syllable = max(0, sin(t * 2 * .pi * 4.2))
            ch[i] = Float((sin(t * 2 * .pi * 180) * 0.6 + noise * 0.4) * syllable * 0.4)
        }
        _ = w.write(b)
        _ = w.close()
        return url
    }
}
