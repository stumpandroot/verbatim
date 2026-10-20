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
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
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
        guard let converter, let f = inputFormat,
              buffer.format.sampleRate == f.sampleRate, buffer.format.channelCount == f.channelCount else { return }
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
