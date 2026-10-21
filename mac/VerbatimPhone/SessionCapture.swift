import AVFoundation

/// The keyboard session's microphone: one AVAudioEngine that runs for the whole session, converting the input to
/// 16 kHz mono floats (what the speech model reads) on the audio thread.
///
/// Privacy: outside a dictation, nothing is kept except a half-second rolling pre-roll in memory, overwritten as
/// it goes, so the first word of a dictation isn't clipped. Nothing is written to disk here at all; the session
/// saves a dictation's audio only after it ends (`KeyboardSession.save`).
final class SessionCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Pre-roll kept in memory: the time between your tap and the app hearing about it, plus a little.
    private static let preRollSamples = Int(sampleRate * 0.5)
    /// A memory guard only (5 minutes of floats is about 19 MB).
    private static let maxTakeSamples = Int(sampleRate * (KeyboardBridge.maxSeconds + 5))

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var preRoll: [Float] = []
    /// The current dictation's samples; nil when not dictating.
    private var take: [Float]?
    private var lastLevel: Float = 0
    private var configObserver: NSObjectProtocol?
    private(set) var running = false

    /// The newest buffer's perceptual level (0…1).
    var level: Float { lock.lock(); defer { lock.unlock() }; return lastLevel }
    /// Seconds in the current dictation.
    var takeSeconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(take?.count ?? 0) / Self.sampleRate }
    var isTaking: Bool { lock.lock(); defer { lock.unlock() }; return take != nil }

    /// Starts the engine. The audio session must already be active with a record category.
    func start() throws {
        guard !running else { return }
        try installTap()
        engine.prepare()
        try engine.start()
        running = true
        // A route change (headphones, Bluetooth) stops the engine and may change the input format.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        }
    }

    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        lock.lock()
        preRoll = []
        take = nil
        lastLevel = 0
        converter = nil
        lock.unlock()
    }

    /// Restarts after a configuration change, keeping a dictation in progress.
    private func restart() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Let the new route settle (AirPods out, the built-in mic coming up) before reading its format.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.restartNow() }
    }

    private func restartNow() {
        guard running else { return }
        do {
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            Log.note("session capture restart failed: \(error)")
            running = false
            onFailure?()
        }
    }

    /// Called on the main queue when the engine can't keep running.
    var onFailure: (() -> Void)?

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Verbatim", code: 3, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        guard let c = AVAudioConverter(from: format, to: outFormat) else {
            throw NSError(domain: "Verbatim", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone's format can't be converted."])
        }
        lock.lock()
        converter = c
        inputFormat = format
        lock.unlock()
        // nil: the tap takes whatever the input delivers, so a stale format after a route change can't crash it.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
    }

    // MARK: Dictations

    /// Starts a dictation with the pre-roll, so it includes the half second before the tap reached the app.
    func beginTake() {
        lock.lock()
        take = preRoll
        preRoll = []
        lock.unlock()
    }

    /// Ends the dictation and hands back its samples.
    func endTake() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = take ?? []
        take = nil
        return out
    }

    func cancelTake() {
        lock.lock()
        take = nil
        lock.unlock()
    }

    // MARK: Trimming

    /// Trims leading and trailing quiet from a dictation by loudness, keeping 250 ms around the speech. The keyboard
    /// uses it until the speech detector (Silero VAD, `FluidEngine`) has loaded. Conservative: when speech can't be
    /// told from the room (no frame clearly above the noise floor), the samples come back whole.
    static func trimQuiet(_ samples: [Float]) -> (samples: [Float], start: Double) {
        let frame = 320                       // 20 ms at 16 kHz
        let pad = 4_000                       // 250 ms
        let n = samples.count / frame
        guard n >= 10 else { return (samples, 0) }
        var rms = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { p in
            for f in 0..<n {
                var sum: Float = 0
                let base = f * frame
                for i in base..<(base + frame) { sum += p[i] * p[i] }
                rms[f] = sqrt(sum / Float(frame))
            }
        }
        let sorted = rms.sorted()
        let noise = sorted[n / 10]
        let peak = sorted[n - 1]
        guard peak > max(0.01, noise * 4) else { return (samples, 0) }
        let threshold = min(max(noise * 2.5, 0.004), peak * 0.25)
        guard let first = rms.firstIndex(where: { $0 >= threshold }), let last = rms.lastIndex(where: { $0 >= threshold }) else {
            return (samples, 0)
        }
        let start = max(0, first * frame - pad)
        let end = min(samples.count, (last + 1) * frame + pad)
        guard end > start, start > 0 || end < samples.count else { return (samples, 0) }
        return (Array(samples[start..<end]), Double(start) / sampleRate)
    }

    // MARK: Audio thread

    private func feed(_ buffer: AVAudioPCMBuffer) {
        var rms: Float = 0
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            rms = sqrt(sum / Float(n))
        }
        let v = min(1, pow(max(0, rms - 0.004) * 6, 0.5))

        lock.lock()
        defer { lock.unlock() }
        lastLevel = v
        // A route change (AirPods out, Bluetooth in) can change the format mid-stream: convert from the new one.
        if let f = inputFormat, buffer.format.sampleRate != f.sampleRate || buffer.format.channelCount != f.channelCount {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            inputFormat = buffer.format
        }
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        if take != nil {
            if take!.count < Self.maxTakeSamples { take!.append(contentsOf: samples) }
        } else {
            preRoll.append(contentsOf: samples)
            let excess = preRoll.count - Self.preRollSamples
            if excess > 0 { preRoll.removeFirst(excess) }
        }
    }
}
