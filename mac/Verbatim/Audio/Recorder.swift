import Foundation
import AVFoundation
import Combine

/// Records the microphone with an AVAudioEngine tap: 16 kHz mono 16-bit WAV written as it goes (so a crash
/// loses nothing), real RMS levels from the samples (so the meter is your voice, not a smoothed power
/// reading), and a waveform envelope kept for the transcript.
/// Audio-thread side: converts and writes each tap buffer immediately (the engine reuses the buffer after
/// the callback returns), and keeps the envelope. Guarded by a lock; the main actor only reads snapshots.
final class RecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var frames: Int64 = 0
    private(set) var envelope: [Float] = []
    private var envAccum: Float = 0, envCount = 0
    var paused = false

    init(url: URL, inputFormat: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: url, settings: Recorder.targetFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        converter = AVAudioConverter(from: inputFormat, to: Recorder.targetFormat)
    }

    /// Returns the perceptual level (0…1) of this buffer.
    func write(_ buffer: AVAudioPCMBuffer) -> Float {
        var rms: Float = 0
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            rms = sqrt(sum / Float(n))
        }
        let v = min(1, pow(rms * 4, 0.6))
        lock.lock(); defer { lock.unlock() }
        guard !paused, let file, let converter else { return 0 }
        let ratio = Recorder.targetFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Recorder.targetFormat, frameCapacity: cap) else { return v }
        var fed = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 {
            try? file.write(from: out)
            frames += Int64(out.frameLength)
        }
        envAccum += v; envCount += 1
        if envCount >= 2 { envelope.append(envAccum / Float(envCount)); envAccum = 0; envCount = 0 }
        return v
    }

    var seconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(frames) / Recorder.targetFormat.sampleRate }
    func close() -> [Float] { lock.lock(); defer { lock.unlock() }; file = nil; converter = nil; return envelope }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var writer: RecordingWriter?
    private var url: URL?
    private var lastMeter = Date.distantPast
    private var pendingPeak: Float = 0

    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    func start(to url: URL) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Verbatim", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        let w = try RecordingWriter(url: url, inputFormat: inFormat)
        writer = w
        self.url = url
        elapsed = 0
        levels = Array(repeating: 0, count: 28)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            let v = w.write(buffer)
            let secs = w.seconds
            Task { @MainActor [weak self] in self?.meter(v, seconds: secs) }
        }
        engine.prepare()
        try engine.start()
        isRecording = true
        isPaused = false
    }

    private func meter(_ v: Float, seconds: TimeInterval) {
        guard isRecording else { return }
        elapsed = seconds
        guard !isPaused else { return }
        pendingPeak = max(pendingPeak, v)
        if Date().timeIntervalSince(lastMeter) > 0.07 {
            level = pendingPeak
            levels.removeFirst(); levels.append(pendingPeak)
            pendingPeak = 0; lastMeter = Date()
        }
    }

    func togglePause() {
        isPaused.toggle()
        writer?.paused = isPaused
        if isPaused { levels = Array(repeating: 0, count: 28); level = 0 }
    }

    /// Returns the file URL, its duration, and the waveform envelope.
    func stop() -> (URL, TimeInterval, [Float])? {
        guard isRecording, let url, let w = writer else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let d = w.seconds
        let env = Waveform.resample(w.close(), to: 120)
        writer = nil
        isRecording = false; isPaused = false
        levels = Array(repeating: 0, count: 28); level = 0
        self.url = nil
        return (url, d, env)
    }
}

enum Waveform {
    /// Reads an audio file and returns `buckets` RMS values in 0…1, for thumbnails and the player track.
    static func envelope(of url: URL, buckets: Int = 120) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url) else { return [] }
        let format = f.processingFormat
        let total = Int(f.length)
        guard total > 0 else { return [] }
        let per = max(1, total / buckets)
        var out: [Float] = []
        out.reserveCapacity(buckets)
        let chunk = AVAudioFrameCount(min(per, 1 << 16))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return [] }
        var acc: Float = 0, n = 0, inBucket = 0
        while f.framePosition < f.length, out.count < buckets {
            buf.frameLength = 0
            guard (try? f.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData?[0] else { break }
            let len = Int(buf.frameLength)
            for i in 0..<len {
                acc += ch[i] * ch[i]; n += 1; inBucket += 1
                if inBucket >= per { out.append(sqrt(acc / Float(max(n, 1)))); acc = 0; n = 0; inBucket = 0 }
            }
        }
        if n > 0, out.count < buckets { out.append(sqrt(acc / Float(n))) }
        let peak = out.max() ?? 1
        return out.map { peak > 0 ? min(1, pow($0 / peak, 0.7)) : 0 }
    }

    static func resample(_ v: [Float], to n: Int) -> [Float] {
        guard !v.isEmpty else { return [] }
        guard v.count != n else { return v }
        return (0..<n).map { i in
            let a = Int(Double(i) / Double(n) * Double(v.count)), b = max(a + 1, Int(Double(i + 1) / Double(n) * Double(v.count)))
            let slice = v[a..<min(b, v.count)]
            return slice.isEmpty ? 0 : slice.max() ?? 0
        }
    }
}
