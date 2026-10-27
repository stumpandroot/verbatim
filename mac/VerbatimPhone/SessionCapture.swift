import AVFoundation
import UIKit

/// The keyboard session's microphone: an AVAudioEngine that runs for the whole session, converting the input to
/// 16 kHz mono floats (what the speech model reads) on the audio thread.
///
/// Privacy: outside a dictation, nothing is kept except a half-second rolling pre-roll in memory, overwritten as
/// it goes, so the first word of a dictation isn't clipped. Nothing is written to disk here at all; the session
/// saves a dictation's audio only after it ends (`KeyboardSession.save`).
///
/// Route changes (AirPods in or out, a headset, a car): the engine is rebuilt from scratch on the new input once
/// the route settles, and the capture checks that buffers really arrive afterwards. An engine that keeps the old
/// route's state can run without error and deliver nothing, which left a warm session deaf after AirPods went
/// back in their case. If the new input still delivers nothing after a second rebuild, the session ends with a
/// message instead of listening to nothing.
final class SessionCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Pre-roll kept in memory: the time between your tap and the app hearing about it, plus a little.
    private static let preRollSamples = Int(sampleRate * 0.5)
    /// A memory guard only (5 minutes of floats is about 19 MB).
    private static let maxTakeSamples = Int(sampleRate * (KeyboardBridge.maxSeconds + 5))
    /// How long a route gets to settle before the engine is rebuilt on it.
    private static let settleDelay: TimeInterval = 0.4
    /// After a (re)start, buffers must arrive within this long.
    private static let verifyDelay: TimeInterval = 1.0
    /// Rebuilds in a row that may deliver nothing before the capture gives up.
    private static let maxRebuilds = 2
    /// Seconds of exact digital silence (every sample 0.0) that count as a dead input. A real microphone always
    /// has some noise, so this never trips on a quiet room.
    private static let deadSilence: TimeInterval = 2.0

    /// A fresh engine for every start and every rebuild; never reused across routes or sessions.
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var preRoll: [Float] = []
    /// The current dictation's samples; nil when not dictating.
    private var take: [Float]?
    private var lastLevel: Float = 0
    /// Audio thread bookkeeping (under `lock`): buffers since the last (re)start, and how long the input has been
    /// exactly silent.
    private var buffers = 0
    private var firstBufferLogged = false
    private var zeroSeconds: TimeInterval = 0
    private var configObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var pendingRebuild: DispatchWorkItem?
    private var verifyWork: DispatchWorkItem?
    private var failedRebuilds = 0
    /// The input the current engine was built on (`inputKey()`).
    private var builtOn = ""
    private var background: UIBackgroundTaskIdentifier = .invalid
    private(set) var running = false
    /// Live words (`LiveTranscriber.tap`): gets each converted 16 kHz buffer of a dictation, starting with its
    /// pre-roll. Called on the audio thread, outside `lock`.
    private var liveTap: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Sets or clears the live words tap. Set it before `beginTake` so the pre-roll goes to it too.
    func setLiveTap(_ tap: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); liveTap = tap; lock.unlock()
    }

    /// The newest buffer's perceptual level (0…1).
    var level: Float { lock.lock(); defer { lock.unlock() }; return lastLevel }
    /// Seconds in the current dictation.
    var takeSeconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(take?.count ?? 0) / Self.sampleRate }
    var isTaking: Bool { lock.lock(); defer { lock.unlock() }; return take != nil }

    /// Called on the main queue when the capture can't keep running, with the reason to show.
    var onFailure: ((String) -> Void)?

    /// Starts the engine. The audio session must already be active with a record category. Main queue only.
    func start() throws {
        guard !running else { return }
        failedRebuilds = 0
        try startEngine(reason: "start")
        running = true
        // Route changes: the engine's own notification, plus the session's, since the engine one doesn't always
        // arrive (for example when the app is in the background as AirPods disconnect).
        let s = AVAudioSession.sharedInstance()
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard let self, let reason else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable:
                self.scheduleRebuild(why: "route change (\(Self.describe(reason)))")
            case .override, .routeConfigurationChange, .categoryChange:
                // These also follow our own activation; rebuild only when the input really changed or stopped.
                if Self.inputKey() != self.builtOn || !(self.engine?.isRunning ?? false) {
                    self.scheduleRebuild(why: "route change (\(Self.describe(reason)))")
                }
            default:
                Log.note("session capture: route change ignored (\(Self.describe(reason))), input \(Self.routeDescription())")
            }
        }
        scheduleVerify()
    }

    func stop() {
        removeObservers()
        pendingRebuild?.cancel(); pendingRebuild = nil
        verifyWork?.cancel(); verifyWork = nil
        endBackground()
        guard running else { return }
        tearDownEngine()
        running = false
        lock.lock()
        preRoll = []
        take = nil
        lastLevel = 0
        converter = nil
        inputFormat = nil
        lock.unlock()
    }

    private func removeObservers() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let o = routeObserver { NotificationCenter.default.removeObserver(o); routeObserver = nil }
    }

    // MARK: Engine

    /// Builds a new engine on the current input, installs the tap, and starts it.
    private func startEngine(reason: String) throws {
        tearDownEngine()
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        builtOn = Self.inputKey()
        Log.note("session capture \(reason): input \(Self.routeDescription()), tap format \(Self.describe(format))")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Verbatim", code: 3, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        guard let c = AVAudioConverter(from: format, to: outFormat) else {
            throw NSError(domain: "Verbatim", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone's format can't be converted."])
        }
        lock.lock()
        converter = c
        inputFormat = format
        buffers = 0
        firstBufferLogged = false
        zeroSeconds = 0
        lock.unlock()
        // nil: the tap takes whatever the input delivers, so a stale format after a route change can't crash it.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
        e.prepare()
        do {
            try e.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        engine = e
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            self?.scheduleRebuild(why: "engine configuration change")
        }
    }

    private func tearDownEngine() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
    }

    /// Rebuilds after the route settles. Several notifications for one change collapse into one rebuild. A take in
    /// progress keeps going; it only misses the moment of the switch.
    private func scheduleRebuild(why: String) {
        guard running else { return }
        Log.note("session capture: \(why); input now \(Self.routeDescription()), rebuilding in \(Self.settleDelay) s")
        // The app may be in the background with no audio running for a moment: keep it awake for the rebuild.
        beginBackground()
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(why: why) }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func rebuild(why: String) {
        pendingRebuild = nil
        guard running else { endBackground(); return }
        do {
            RecordingRoute.allowHaptics()
            try? AVAudioSession.sharedInstance().setActive(true)
            try startEngine(reason: "rebuild after \(why)")
            scheduleVerify()
        } catch {
            Log.note("session capture: rebuild failed: \(error)")
            fail("The microphone stopped after the audio route changed. Tap to start a new session.")
        }
        endBackground()
    }

    /// Checks that buffers arrive after a (re)start: one more rebuild if not, then gives up with a message.
    private func scheduleVerify() {
        verifyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.verify() }
        verifyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.verifyDelay, execute: work)
    }

    private func verify() {
        verifyWork = nil
        guard running, pendingRebuild == nil else { return }
        lock.lock(); let n = buffers; lock.unlock()
        if n > 0 {
            failedRebuilds = 0
            return
        }
        failedRebuilds += 1
        Log.note("session capture: no audio \(Self.verifyDelay) s after starting (attempt \(failedRebuilds)), input \(Self.routeDescription())")
        if failedRebuilds > Self.maxRebuilds {
            fail("The microphone isn't sending sound. Tap to start a new session.")
        } else {
            scheduleRebuild(why: "no audio arrived")
        }
    }

    /// Called by the session about 4 times a second: catches an input that runs but delivers only exact zeros.
    func checkHealth() {
        guard running, pendingRebuild == nil, verifyWork == nil else { return }
        lock.lock(); let dead = zeroSeconds >= Self.deadSilence; if dead { zeroSeconds = 0 }; lock.unlock()
        guard dead else { return }
        failedRebuilds += 1
        Log.note("session capture: \(Self.deadSilence) s of digital silence (attempt \(failedRebuilds)), input \(Self.routeDescription())")
        if failedRebuilds > Self.maxRebuilds {
            fail("The microphone isn't sending sound. Tap to start a new session.")
        } else {
            scheduleRebuild(why: "the input went silent")
        }
    }

    private func fail(_ message: String) {
        Log.note("session capture: giving up: \(message)")
        // The handler takes the dictation in progress first (endTake); then everything stops.
        onFailure?(message)
        stop()
    }

    /// Main queue only, like everything outside the audio thread here.
    private func beginBackground() {
        guard background == .invalid else { return }
        background = MainActor.assumeIsolated {
            UIApplication.shared.beginBackgroundTask(withName: "Microphone route change") { [weak self] in self?.endBackground() }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        let id = background
        background = .invalid
        MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(id) }
    }

    // MARK: Descriptions for the log

    /// "MicrophoneBuiltIn iPhone Microphone (Bottom), 48000 Hz, 1 ch": the session's current input.
    static func routeDescription() -> String {
        let s = AVAudioSession.sharedInstance()
        let inputs = s.currentRoute.inputs.map { p -> String in
            let source = p.selectedDataSource?.dataSourceName ?? ""
            return "\(p.portType.rawValue) \(p.portName)\(source.isEmpty ? "" : " (\(source))")"
        }
        let preferred = s.preferredInput.map { " preferred \($0.portType.rawValue)" } ?? ""
        return "\(inputs.isEmpty ? "none" : inputs.joined(separator: ", ")), \(Int(s.sampleRate)) Hz, \(s.inputNumberOfChannels) ch\(preferred)"
    }

    /// Identifies the current input port and rate, to tell a real input change from a repeated notification.
    static func inputKey() -> String {
        let s = AVAudioSession.sharedInstance()
        return (s.currentRoute.inputs.first?.uid ?? "none") + "@\(Int(s.sampleRate))"
    }

    static func describe(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate)) Hz \(f.channelCount) ch \(f.commonFormat == .pcmFormatFloat32 ? "float32" : "format \(f.commonFormat.rawValue)")\(f.isInterleaved ? " interleaved" : "")"
    }

    static func describe(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .newDeviceAvailable: return "new device"
        case .oldDeviceUnavailable: return "device gone"
        case .categoryChange: return "category change"
        case .override: return "override"
        case .wakeFromSleep: return "wake"
        case .noSuitableRouteForCategory: return "no suitable route"
        case .routeConfigurationChange: return "configuration change"
        default: return "reason \(r.rawValue)"
        }
    }

    // MARK: Dictations

    /// Starts a dictation with the pre-roll, so it includes the half second before the tap reached the app.
    func beginTake() {
        lock.lock()
        take = preRoll
        let start = preRoll
        preRoll = []
        let tap = liveTap
        lock.unlock()
        if let tap, !start.isEmpty, let b = Self.buffer(start, format: outFormat) { tap(b) }
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = b.floatChannelData?[0] else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress!, count: samples.count) }
        return b
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
        var allZero = true
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            rms = sqrt(sum / Float(n))
            allZero = sum == 0
        }
        let v = min(1, pow(max(0, rms - 0.004) * 6, 0.5))
        let seconds = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0

        var forward: (tap: @Sendable (AVAudioPCMBuffer) -> Void, buffer: AVAudioPCMBuffer)?
        do {   // under `lock`; the live words tap is called after it
            lock.lock()
            defer { lock.unlock() }
            lastLevel = v
            buffers += 1
            zeroSeconds = allZero ? zeroSeconds + seconds : 0
            if !firstBufferLogged {
                firstBufferLogged = true
                let line = "session capture: first buffer \(Self.describe(buffer.format)), \(buffer.frameLength) frames"
                DispatchQueue.main.async { Log.note(line) }
            }
            // A route change (AirPods out, Bluetooth in) can change the format mid-stream: convert from the new one.
            if inputFormat == nil || buffer.format.sampleRate != inputFormat!.sampleRate || buffer.format.channelCount != inputFormat!.channelCount {
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
                // `out` is a new buffer on every call, so live words may keep it.
                if let tap = liveTap { forward = (tap, out) }
            } else {
                preRoll.append(contentsOf: samples)
                let excess = preRoll.count - Self.preRollSamples
                if excess > 0 { preRoll.removeFirst(excess) }
            }
        }
        if let forward { forward.tap(forward.buffer) }
    }
}
