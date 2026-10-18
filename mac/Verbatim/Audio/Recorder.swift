import Foundation
import AVFoundation
import Combine
#if os(macOS)
import AppKit
#endif

/// Records the microphone with an AVAudioEngine tap: 16 kHz mono 16-bit WAV written as it goes (so a crash
/// loses nothing), real RMS levels from the samples (so the meter is your voice, not a smoothed power
/// reading), and a waveform envelope kept for the transcript.
/// Audio-thread side: converts and writes each tap buffer immediately (the engine reuses the buffer after
/// the callback returns), and keeps the envelope. Guarded by a lock; the main actor only reads snapshots.
/// 16 kHz mono 16-bit: what the engines want and a quarter of the disk of 48 kHz float.
let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

final class RecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var frames: Int64 = 0
    private(set) var envelope: [Float] = []
    private var envAccum: Float = 0, envCount = 0
    var paused = false
    /// Pre-roll: audio converted before the file is open (the mic starts first), written first on `attach`.
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: Int64 = 0
    private var holding = false
    /// A memory guard only: the file normally opens within milliseconds of the first buffer.
    private static let preRollCap = Int64(recordingFormat.sampleRate * 10)
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private var firstBufferAt: TimeInterval?
    /// Long recordings: every `segmentFrames` the file is closed (so its header is final) and the recording
    /// continues in the next segment file beside it. A crash then loses at most the open segment's header,
    /// not the whole recording. `segments[0]` is the recording's own URL; Recorder joins them at stop.
    private let segmentLimit: Int64?
    private var framesInSegment: Int64 = 0
    /// Only touched with `lock` held (the audio thread appends to it); read through `segments`.
    private var segmentURLs: [URL] = []
    var segments: [URL] { lock.lock(); defer { lock.unlock() }; return segmentURLs }

    /// `segmented`: roll to a new file every `RecordingSegments.seconds` (normal recordings, not dictation).
    init(url: URL, inputFormat: AVAudioFormat, segmented: Bool = false) throws {
        file = try AVAudioFile(forWriting: url, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        converter = AVAudioConverter(from: inputFormat, to: recordingFormat)
        segmentLimit = segmented ? Int64(recordingFormat.sampleRate * RecordingSegments.seconds) : nil
        segmentURLs = [url]
    }

    /// Converts from the first buffer and holds the audio until `attach(url:)` opens the file.
    init(inputFormat: AVAudioFormat) throws {
        guard let c = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw NSError(domain: "Verbatim", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone's format can't be converted."])
        }
        converter = c
        holding = true
        segmentLimit = nil
    }

    /// Opens the file and writes the held pre-roll into it, so nothing heard before now is lost.
    func attach(url: URL) throws {
        let f = try AVAudioFile(forWriting: url, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        lock.lock(); defer { lock.unlock() }
        for b in preRoll {
            try? f.write(from: b)
            frames += Int64(b.frameLength)
        }
        preRoll = []; preRollFrames = 0
        holding = false
        file = f
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
        // Speech RMS sits around 0.02–0.15 on a Mac mic; map that onto most of the bar height.
        let v = min(1, pow(max(0, rms - 0.004) * 6, 0.5))
        lock.lock(); defer { lock.unlock() }
        if firstBufferAt == nil { firstBufferAt = ProcessInfo.processInfo.systemUptime }
        guard !paused, let converter, file != nil || holding else { return 0 }
        let ratio = recordingFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: cap) else { return v }
        var fed = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 {
            if let file {
                try? file.write(from: out)
                frames += Int64(out.frameLength)
                framesInSegment += Int64(out.frameLength)
                if let limit = segmentLimit, framesInSegment >= limit { rollSegment() }
            } else {
                preRoll.append(out)
                preRollFrames += Int64(out.frameLength)
                while preRollFrames > Self.preRollCap, !preRoll.isEmpty { preRollFrames -= Int64(preRoll.removeFirst().frameLength) }
            }
        }
        envAccum += v; envCount += 1
        if envCount >= 2 { envelope.append(envAccum / Float(envCount)); envAccum = 0; envCount = 0 }
        return v
    }

    var seconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(frames + preRollFrames) / recordingFormat.sampleRate }

    /// Opens the next segment file, then closes the current one (finalizing its header). Called with `lock`
    /// held, on the audio thread. If the next file can't be opened, keeps writing the current one.
    private func rollSegment() {
        framesInSegment = 0
        guard let first = segmentURLs.first else { return }
        let next = RecordingSegments.url(for: first, index: segmentURLs.count + 1)
        guard let f = try? AVAudioFile(forWriting: next, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true) else {
            Log.note("recorder: couldn't open segment \(segmentURLs.count + 1); continuing in the current file")
            return
        }
        if #available(macOS 15, iOS 18, *) { file?.close() }
        file = f
        segmentURLs.append(next)
        Log.note("recorder: segment \(segmentURLs.count) started")
    }

    /// Converts from a new input format (the recording moved to a fresh engine). False if it can't be converted.
    func replaceInput(_ format: AVAudioFormat) -> Bool {
        guard let c = AVAudioConverter(from: format, to: recordingFormat) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard converter != nil else { return false }
        converter = c
        return true
    }

    /// Milliseconds from creating the writer to the first buffer (how long the mic took to wake), if any arrived.
    var firstBufferDelay: Int? {
        lock.lock(); defer { lock.unlock() }
        return firstBufferAt.map { Int(($0 - createdAt) * 1000) }
    }

    /// Flushes the converter (its resampler holds the last few milliseconds) and closes the file.
    func close() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if let converter, let file, !paused { drain(converter, into: file) }
        if #available(macOS 15, iOS 18, *) { file?.close() }
        file = nil; converter = nil; preRoll = []; preRollFrames = 0; holding = false
        return envelope
    }

    private func drain(_ converter: AVAudioConverter, into file: AVAudioFile) {
        for _ in 0..<8 {
            guard let out = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: 4096) else { return }
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, s in s.pointee = .endOfStream; return nil }
            if err == nil, out.frameLength > 0 {
                try? file.write(from: out)
                frames += Int64(out.frameLength)
            }
            if err != nil || status != .haveData || out.frameLength == 0 { return }
        }
    }
}

/// Hands tap buffers to the current recording. The tap stays installed on a kept engine between recordings;
/// with no writer set, buffers are dropped (and the engine isn't running then anyway).
final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: RecordingWriter?
    private var onLevel: (@Sendable (Float, TimeInterval) -> Void)?

    func set(_ writer: RecordingWriter?, onLevel: (@Sendable (Float, TimeInterval) -> Void)?) {
        lock.lock(); self.writer = writer; self.onLevel = onLevel; lock.unlock()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let w = writer, cb = onLevel; lock.unlock()
        guard let w else { return }
        let v = w.write(buffer)
        cb?(v, w.seconds)
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    let live = LiveMeter()
    /// The last `stop()` couldn't join a long recording's segments. The caller must not adopt the file then:
    /// every part stays in the recordings folder, and launch recovery joins it.
    private(set) var lastJoinFailed = false
    /// Called when a normal recording pauses itself (a phone call, or a microphone change it couldn't follow),
    /// with a short reason to show. Resume carries on in the same file.
    var onAutoPaused: ((String) -> Void)?
    var elapsed: TimeInterval { live.elapsed }

    /// Called when the input device changes or drops out mid-recording. The recording isn't moved to another
    /// device: the owner should stop and keep what was recorded. Without a handler, the recorder restarts
    /// the same device if it can.
    var onInterrupted: (() -> Void)?

    /// Normal recordings get a fresh engine per recording, released on Stop: a running engine holds the input
    /// device open, and on Bluetooth headphones that leaves them in the low-quality call profile.
    /// Dictation (`keepWarm`) keeps one engine *prepared but stopped* between recordings, with its tap
    /// installed, so key-down only calls start(). The mic runs only while recording. The engine is released
    /// after 10 minutes unused and when the Mac sleeps, and prepared again on wake.
    private let keepWarm: Bool
    private var engine: AVAudioEngine?
    private var writer: RecordingWriter?
    private var url: URL?
    private let sink = TapSink()
    private var configObserver: NSObjectProtocol?
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    #endif
    private var prepared = false
    /// The tap's format on the kept engine; a different input format at start means the engine is stale.
    private var tapFormat: AVAudioFormat?
    private var preparedSelection: String?
    private var stale = false
    /// Dictation wants the engine kept ready (dictation is on).
    private var armed = false
    private var idleTimer: Timer?
    private var startedAt: TimeInterval = 0
    private var builtAt: TimeInterval = 0
    private static let idleLimit: TimeInterval = 600
    #if os(macOS)
    private var workspaceObservers: [NSObjectProtocol] = []
    #endif

    static var targetFormat: AVAudioFormat { recordingFormat }

    init(keepWarm: Bool = false) {
        self.keepWarm = keepWarm
        #if os(macOS)
        if keepWarm {
            let ws = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.willSleep() }
            })
            workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.didWake() }
            })
        }
        #endif
    }

    private static var noInput: NSError {
        NSError(domain: "Verbatim", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
    }

    func start(to url: URL) throws {
        #if os(iOS)
        // iPhone: a record session that keeps going with the screen locked (background audio mode).
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif
        if keepWarm { try startWarm(to: url); return }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        #if os(macOS)
        if let id = AudioDevices.selectedInputID { AudioDevices.setInput(id, on: input) }
        #endif
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            self.engine = nil
            throw Self.noInput
        }
        let w = try RecordingWriter(url: url, inputFormat: inFormat, segmented: true)
        writer = w
        self.url = url
        live.reset()
        installRecordingTap(on: input, format: inFormat, writer: w)
        tapFormat = inFormat
        observeConfiguration(of: engine)
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0); removeConfigObserver()
            _ = w.close(); writer = nil; self.url = nil; self.engine = nil; tapFormat = nil
            throw error
        }
        RecordingSegments.setActive(url, true)
        observeInterruptions()
        startedAt = ProcessInfo.processInfo.systemUptime
        isRecording = true
        isPaused = false
    }

    private func installRecordingTap(on input: AVAudioInputNode, format: AVAudioFormat, writer w: RecordingWriter) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let v = w.write(buffer)
            let secs = w.seconds
            Task { @MainActor [weak self] in self?.meter(v, seconds: secs) }
        }
    }

    private func meter(_ v: Float, seconds: TimeInterval) {
        guard isRecording else { return }
        live.push(v, seconds: seconds, paused: isPaused)
    }

    func togglePause() {
        // Resuming after the recorder paused itself (a call, a device change): the engine stopped, start it again.
        if isPaused, !keepWarm, let engine, !engine.isRunning {
            guard restartCapture() else {
                Log.note("recorder: couldn't resume; still paused")
                onAutoPaused?("Couldn't restart the microphone. Stop to keep what was recorded.")
                return
            }
        }
        isPaused.toggle()
        writer?.paused = isPaused
        if isPaused { live.reset(); live.setElapsed(writer?.seconds ?? 0) }
    }

    /// Pauses a normal recording on the recorder's own initiative; what was recorded stays, Resume continues it.
    private func autoPause(_ reason: String) {
        guard isRecording, !keepWarm else { return }
        if !isPaused {
            isPaused = true
            writer?.paused = true
            live.reset(); live.setElapsed(writer?.seconds ?? 0)
        }
        Log.note("recorder: paused itself (\(reason))")
        onAutoPaused?(reason)
    }

    /// Normal recordings: points the tap at the input's current format (a new device, a new sample rate) and
    /// starts the engine again. The writer converts whatever arrives, so the file keeps one format.
    private func restartCapture() -> Bool {
        guard !keepWarm, let engine, let w = writer else { return false }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        #if os(macOS)
        if let id = AudioDevices.selectedInputID { AudioDevices.setInput(id, on: input) }
        #endif
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, w.replaceInput(format) else { return false }
        installRecordingTap(on: input, format: format, writer: w)
        tapFormat = format
        engine.prepare()
        do { try engine.start() } catch {
            Log.note("recorder: restart failed: \(error.localizedDescription)"); return false
        }
        Log.note("recorder: capture restarted at \(Int(format.sampleRate)) Hz")
        return true
    }

    /// Returns the file URL, its duration, and the waveform envelope. A long recording's segments are joined into
    /// that file first; if that fails, `lastJoinFailed` is set and the caller must leave the file where it is.
    func stop() -> (URL, TimeInterval, [Float])? {
        lastJoinFailed = false
        guard let (w, url) = endCapture() else { return nil }
        let firstDelay = w.firstBufferDelay
        let env = Waveform.resample(w.close(), to: 120)   // close() flushes the converter's last frames first
        let d = w.seconds
        let parts = w.segments
        if parts.count > 1 {
            if RecordingSegments.join(parts) != nil {
                Log.note("recorder: joined \(parts.count) segments")
            } else {
                lastJoinFailed = true
                Log.note("recorder: couldn't join \(parts.count) segments; all kept for recovery at next launch")
            }
        }
        RecordingSegments.setActive(url, false)
        Log.note("recorder: stopped \(String(format: "%.2f", d))s, first audio \(firstDelay.map { "\($0) ms" } ?? "never") after start, warm=\(keepWarm)")
        finishStop()
        return (url, d, env)
    }

    /// Stops and deletes the recording and its segments without joining them.
    func discard() {
        lastJoinFailed = false
        guard let (w, url) = endCapture() else { return }
        _ = w.close()
        let fm = FileManager.default
        for u in w.segments { try? fm.removeItem(at: u) }
        RecordingSegments.removeSegments(of: url)
        RecordingSegments.setActive(url, false)
        Log.note("recorder: discarded")
        finishStop()
    }

    /// Stops capture and hands back the writer (not yet closed) and the recording's URL.
    private func endCapture() -> (RecordingWriter, URL)? {
        guard isRecording, let url, let w = writer else { return nil }
        if keepWarm {
            sink.set(nil, onLevel: nil)
            engine?.stop()
            prepared = false
        } else {
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine?.reset()
            removeConfigObserver()
            removeInterruptionObserver()
            engine = nil
            tapFormat = nil
        }
        return (w, url)
    }

    private func finishStop() {
        writer = nil
        isRecording = false; isPaused = false
        live.reset()
        self.url = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if keepWarm {
            // Ready for the next dictation: prepared again, mic off.
            if stale || !armed { teardown() }
            if armed { warmUp() }
        }
    }

    // MARK: Kept engine (dictation)

    /// Prepares the kept engine (mic off) so the next start is quick. Dictation calls this when it's on.
    func warmUp() {
        guard keepWarm else { return }
        armed = true
        guard !isRecording else { return }
        if engine == nil || stale || selectionChanged() { rebuild() }
        if let engine, !prepared { engine.prepare(); prepared = true }
        scheduleIdleRelease()
    }

    /// Releases the kept engine (dictation turned off).
    func coolDown() {
        guard keepWarm else { return }
        armed = false
        guard !isRecording else { return }
        teardown()
    }

    private func startWarm(to url: URL) throws {
        idleTimer?.invalidate(); idleTimer = nil
        armed = true
        if engine == nil || stale || selectionChanged() { rebuild() }
        do {
            try beginCapture(to: url)
        } catch {
            // A Bluetooth route change can leave a kept engine's format stale: starting fails or records
            // nothing. One retry on a fresh engine.
            Log.note("recorder: warm start failed (\(error.localizedDescription)); retrying on a fresh engine")
            rebuild()
            try beginCapture(to: url)
        }
    }

    private func beginCapture(to url: URL) throws {
        guard let engine, let tapFormat else { throw Self.noInput }
        let now = engine.inputNode.outputFormat(forBus: 0)
        guard now.sampleRate > 0, now.channelCount > 0 else { throw Self.noInput }
        if now.sampleRate != tapFormat.sampleRate || now.channelCount != tapFormat.channelCount {
            throw NSError(domain: "Verbatim", code: 3, userInfo: [NSLocalizedDescriptionKey: "The microphone's format changed."])
        }
        let w = try RecordingWriter(inputFormat: tapFormat)
        live.reset()
        sink.set(w, onLevel: levelHandler())
        do {
            if !prepared { engine.prepare(); prepared = true }
            try engine.start()
        } catch {
            sink.set(nil, onLevel: nil)
            prepared = false
            _ = w.close()
            throw error
        }
        // The mic is already running; audio heard while the file opens is held and written first.
        do {
            try w.attach(url: url)
        } catch {
            sink.set(nil, onLevel: nil)
            engine.stop(); prepared = false
            _ = w.close()
            throw error
        }
        writer = w
        self.url = url
        RecordingSegments.setActive(url, true)
        startedAt = ProcessInfo.processInfo.systemUptime
        isRecording = true
        isPaused = false
        watchFirstBuffer(w)
    }

    private func levelHandler() -> @Sendable (Float, TimeInterval) -> Void {
        { [weak self] v, secs in
            Task { @MainActor [weak self] in self?.meter(v, seconds: secs) }
        }
    }

    /// A kept engine whose route went stale can start without error and deliver nothing. No audio at all
    /// 2.5 s after start (longer than a Bluetooth mic takes to wake) means that: move this recording to a
    /// fresh engine on the same device setting. If that fails, the owner finishes with what it has.
    private func watchFirstBuffer(_ w: RecordingWriter) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.isRecording, self.writer === w, w.firstBufferDelay == nil else { return }
            Log.note("recorder: no audio 2.5 s after start; restarting on a fresh engine")
            self.rebuild()
            guard let engine = self.engine, let format = self.tapFormat, w.replaceInput(format) else {
                Log.note("recorder: couldn't restart capture")
                self.onInterrupted?()
                return
            }
            self.sink.set(w, onLevel: self.levelHandler())
            do {
                try engine.start()
            } catch {
                Log.note("recorder: restart failed: \(error.localizedDescription)")
                self.sink.set(nil, onLevel: nil)
                self.onInterrupted?()
            }
        }
    }

    /// A new engine on the chosen device, tap installed, prepared, not started.
    private func rebuild() {
        teardown()
        let e = AVAudioEngine()
        let input = e.inputNode
        #if os(macOS)
        if let id = AudioDevices.selectedInputID { AudioDevices.setInput(id, on: input) }
        preparedSelection = AudioDevices.selectedUID
        #endif
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.note("recorder: no input to prepare")
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [sink = self.sink] buffer, _ in sink.feed(buffer) }
        engine = e
        tapFormat = format
        observeConfiguration(of: e)
        e.prepare()
        prepared = true
        stale = false
        builtAt = ProcessInfo.processInfo.systemUptime
    }

    private func teardown() {
        idleTimer?.invalidate(); idleTimer = nil
        removeConfigObserver()
        if let engine {
            sink.set(nil, onLevel: nil)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        tapFormat = nil
        prepared = false
        stale = false
    }

    private func selectionChanged() -> Bool {
        #if os(macOS)
        return preparedSelection != AudioDevices.selectedUID
        #else
        return false
        #endif
    }

    private func scheduleIdleRelease() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleLimit, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRecording, self.engine != nil else { return }
                Log.note("recorder: released after \(Int(Self.idleLimit / 60)) minutes unused")
                self.teardown()
            }
        }
        idleTimer?.tolerance = 30
    }

    private func willSleep() {
        guard keepWarm, !isRecording else { return }
        teardown()
    }

    private func didWake() {
        guard keepWarm, armed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.armed, !self.isRecording else { return }
            self.stale = true
            self.warmUp()
        }
    }

    // MARK: Interruptions (iPhone)

    /// A phone call or another app taking the audio session stops the engine. The recording pauses (it never
    /// silently stops while it says it's recording) and Resume continues it in the same file.
    private func observeInterruptions() {
        #if os(iOS)
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { self.autoPause("Paused for an interruption. Tap Resume to keep recording.") }
            }
        }
        #endif
    }

    private func removeInterruptionObserver() {
        #if os(iOS)
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        interruptionObserver = nil
        #endif
    }

    // MARK: Device changes

    private func observeConfiguration(of engine: AVAudioEngine) {
        removeConfigObserver()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configurationChanged() }
        }
    }

    private func removeConfigObserver() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
    }

    /// The input device changed or dropped out. The engine stops itself; a recording keeps what it has.
    private func configurationChanged() {
        guard let engine else { return }
        if isRecording {
            // Some routes post a change at start while the engine keeps running: nothing to do then.
            if engine.isRunning {
                Log.note("recorder: configuration change while running; ignored")
                return
            }
            Log.note("recorder: input changed mid-recording after \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt))s")
            stale = true
            if let onInterrupted {
                onInterrupted()
            } else if isPaused {
                // Already paused: Resume restarts capture on whatever input is there then.
                Log.note("recorder: configuration change while paused")
            } else if !restartCapture() {
                // Normal recordings: follow the new input (a new sample rate is fine, the writer converts). If that
                // can't start, pause visibly instead of recording nothing.
                autoPause("The microphone changed. Tap Resume to keep recording.")
            }
        } else if keepWarm {
            // Building an engine can post a change of its own; don't rebuild in a loop.
            guard ProcessInfo.processInfo.systemUptime - builtAt > 2 else { return }
            Log.note("recorder: configuration changed while idle; preparing again")
            teardown()
            if armed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.armed, !self.isRecording else { return }
                    self.warmUp()
                }
            }
        }
    }
}

/// Segment files of a long recording: "<name>.seg002.wav", "<name>.seg003.wav"… beside "<name>.wav" (segment 1).
enum RecordingSegments {
    /// A new segment every 5 minutes.
    static let seconds: Double = 300
    private static let marker = ".seg"

    static func url(for base: URL, index: Int) -> URL {
        let stem = base.deletingPathExtension().lastPathComponent
        return base.deletingLastPathComponent().appendingPathComponent("\(stem)\(marker)\(String(format: "%03d", index)).\(base.pathExtension)")
    }

    /// For "<name>.seg002.wav" (seg1000 and up too): the base URL "<name>.wav" and 2. nil for anything else.
    static func parse(_ url: URL) -> (base: URL, index: Int)? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let r = stem.range(of: marker, options: .backwards) else { return nil }
        let digits = stem[r.upperBound...]
        guard digits.count >= 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 2 else { return nil }
        let baseName = String(stem[..<r.lowerBound]) + "." + url.pathExtension
        return (url.deletingLastPathComponent().appendingPathComponent(baseName), n)
    }

    // MARK: Recordings in progress

    private static let activeLock = NSLock()
    private static var active = Set<String>()

    /// A recording being written right now (its base file name): launch recovery leaves it and its segments alone.
    static func setActive(_ base: URL, _ on: Bool) {
        activeLock.lock(); defer { activeLock.unlock() }
        if on { active.insert(base.lastPathComponent) } else { active.remove(base.lastPathComponent) }
    }

    static func isActive(_ url: URL) -> Bool {
        let name = parse(url)?.base.lastPathComponent ?? url.lastPathComponent
        activeLock.lock(); defer { activeLock.unlock() }
        return active.contains(name)
    }

    // MARK: Joining

    /// Written beside the base before a join appends anything; removed once the appended segments are deleted.
    /// If the app dies in between, `finishInterrupted` reads it at launch: a base that already holds every byte
    /// keeps them (the listed segments are deleted); otherwise the base is cut back to `originalLength` (and
    /// renamed back if it was renamed) so the segments, all still on disk, are joined again.
    struct JoinMarker: Codable {
        var base: String
        /// Sample bytes in the base before appending.
        var originalLength: UInt64
        /// Sample bytes in the base once every listed segment is appended.
        var expectedLength: UInt64
        /// Appended segments, in order.
        var segments: [String]
        /// The first part had already been adopted: this segment was renamed to `base` to start the file.
        var renamedFrom: String?
    }

    static func markerURL(for base: URL) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(".\(base.deletingPathExtension().lastPathComponent).joined")
    }

    static func writeMarker(_ m: JoinMarker, in folder: URL) throws {
        let data = try JSONEncoder().encode(m)
        try data.write(to: markerURL(for: folder.appendingPathComponent(m.base)), options: .atomic)
    }

    /// Appends segments 2… onto segment 1 (the recording's URL) in place, then deletes them. Every part is checked
    /// first (a readable WAV, all in one format); if any fails, nothing is touched. When segment 1 is missing
    /// (already adopted elsewhere), the next segment is renamed to a fresh name nobody uses (`isTaken`) and becomes
    /// the file. Returns the joined file's URL, or nil when it couldn't join (every file is then as it was).
    @discardableResult
    static func join(_ urls: [URL], isTaken: ((String) -> Bool)? = nil) -> URL? {
        let fm = FileManager.default
        guard let first = urls.first else { return nil }
        let folder = first.deletingLastPathComponent()
        let existing = urls.filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        // Check every part before changing anything. (Header repair only rewrites sizes to match the file's length.)
        var layouts: [URL: WavRepair.Layout] = [:]
        for part in existing {
            WavRepair.fixHeader(part)
            guard let l = WavRepair.layout(part) else {
                Log.note("recorder: segment \(part.lastPathComponent) unreadable; join skipped, every file kept")
                return nil
            }
            layouts[part] = l
        }
        guard Set(existing.compactMap { layouts[$0]?.format }).count == 1 else {
            Log.note("recorder: segments differ in format; join skipped"); return nil
        }

        var base = first
        var renamedFrom: URL?
        if !fm.fileExists(atPath: first.path) {
            base = uniqueURL(near: first, isTaken: isTaken)
            renamedFrom = existing[0]
        }
        let rest = Array(existing.dropFirst())
        let start = layouts[renamedFrom ?? base]!
        if rest.isEmpty && renamedFrom == nil { return base }
        let expected = rest.reduce(start.dataLength) { $0 + (layouts[$1]?.dataLength ?? 0) }
        guard start.dataOffset + expected <= UInt64(UInt32.max) else {
            Log.note("recorder: recording too long for one WAV file; segments kept"); return nil
        }
        let m = JoinMarker(base: base.lastPathComponent, originalLength: start.dataLength, expectedLength: expected,
                           segments: rest.map(\.lastPathComponent), renamedFrom: renamedFrom?.lastPathComponent)
        do { try writeMarker(m, in: folder) } catch {
            Log.note("recorder: couldn't write the join marker; join skipped"); return nil
        }
        if let from = renamedFrom {
            do { try fm.moveItem(at: from, to: base) } catch {
                try? fm.removeItem(at: markerURL(for: base))
                Log.note("recorder: couldn't rename \(from.lastPathComponent); join skipped"); return nil
            }
        }
        do {
            try append(rest, layouts: layouts, to: base, layout: start, total: expected)
        } catch {
            Log.note("recorder: join failed (\(error.localizedDescription)); rolled back, segments kept")
            rollBack(m, in: folder)
            return nil
        }
        // Every byte is in the base and on disk: now the segments can go, then the marker.
        for u in rest { try? fm.removeItem(at: u) }
        try? fm.removeItem(at: markerURL(for: base))
        return base
    }

    /// Appends each segment's sample bytes after the base's, then writes the final header sizes.
    private static func append(_ parts: [URL], layouts: [URL: WavRepair.Layout], to base: URL, layout: WavRepair.Layout, total: UInt64) throws {
        let out = try FileHandle(forUpdating: base)
        defer { try? out.close() }
        try out.truncate(atOffset: layout.dataOffset + layout.dataLength)
        try out.seekToEnd()
        for part in parts {
            guard let l = layouts[part] else { continue }
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            try input.seek(toOffset: l.dataOffset)
            var remaining = l.dataLength
            while remaining > 0 {
                guard let chunk = try input.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else {
                    throw NSError(domain: "Verbatim", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(part.lastPathComponent) ended early"])
                }
                try out.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
        try out.synchronize()
        try WavRepair.writeSizes(out, layout: layout, dataLength: total)
        try out.synchronize()
    }

    /// Puts the files back as they were before the join described by `m` started.
    private static func rollBack(_ m: JoinMarker, in folder: URL) {
        let fm = FileManager.default
        let base = folder.appendingPathComponent(m.base)
        if let l = WavRepair.layout(base), let h = try? FileHandle(forUpdating: base) {
            try? h.truncate(atOffset: l.dataOffset + min(m.originalLength, l.dataLength))
            try? WavRepair.writeSizes(h, layout: l, dataLength: min(m.originalLength, l.dataLength))
            try? h.synchronize()
            try? h.close()
        }
        if let from = m.renamedFrom, fm.fileExists(atPath: base.path) {
            try? fm.moveItem(at: base, to: folder.appendingPathComponent(from))
        }
        try? fm.removeItem(at: markerURL(for: base))
    }

    /// A join the app didn't live to finish (its marker is still there): rolls forward when the base already holds
    /// every byte, otherwise rolls back so the segments are joined again.
    static func finishInterrupted(in folder: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        for f in files where f.lastPathComponent.hasPrefix(".") && f.pathExtension == "joined" {
            guard let data = try? Data(contentsOf: f), let m = try? JSONDecoder().decode(JoinMarker.self, from: data) else {
                try? fm.removeItem(at: f); continue
            }
            let base = folder.appendingPathComponent(m.base)
            // No base: the app died before the rename (or before anything), so the segments are untouched.
            guard let l = WavRepair.layout(base) else { try? fm.removeItem(at: f); continue }
            if l.dataLength >= m.expectedLength {
                if let h = try? FileHandle(forUpdating: base) {
                    try? h.truncate(atOffset: l.dataOffset + m.expectedLength)
                    try? WavRepair.writeSizes(h, layout: l, dataLength: m.expectedLength)
                    try? h.synchronize()
                    try? h.close()
                }
                for s in m.segments { try? fm.removeItem(at: folder.appendingPathComponent(s)) }
                try? fm.removeItem(at: f)
                Log.note("recorder: finished an interrupted join of \(m.segments.count) segments")
            } else {
                rollBack(m, in: folder)
                Log.note("recorder: rolled back an interrupted join of \(m.segments.count) segments")
            }
        }
    }

    /// "<stem> 2.wav", "<stem> 3.wav"…: the first name not on disk here and not taken elsewhere.
    private static func uniqueURL(near url: URL, isTaken: ((String) -> Bool)?) -> URL {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while true {
            let u = folder.appendingPathComponent("\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: u.path), !(isTaken?(u.lastPathComponent) ?? false) { return u }
            n += 1
        }
    }

    /// Deletes a recording's segment files (and any join marker) without joining them: a discarded recording.
    static func removeSegments(of base: URL) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: base.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        where parse(f)?.base.lastPathComponent == base.lastPathComponent { try? fm.removeItem(at: f) }
        try? fm.removeItem(at: markerURL(for: base))
    }

    /// Anything for `joinLeftovers` to do: segment files (of recordings not in progress) or an unfinished join.
    static func hasLeftovers(in folder: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        return files.contains { (parse($0) != nil && !isActive($0)) || ($0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "joined") }
    }

    /// At launch, before orphaned recordings are recovered: finishes or rolls back an interrupted join, then joins
    /// leftover segments onto their first file. When the first file was already adopted (it's gone from here), the
    /// segments become a new recording under a name `isTaken` says is free. Recordings in progress are left alone.
    static func joinLeftovers(in folder: URL, isTaken: ((String) -> Bool)? = nil) {
        let fm = FileManager.default
        finishInterrupted(in: folder)
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        // Temp files from the earlier join method.
        for f in files where f.lastPathComponent.hasPrefix(".") && f.deletingPathExtension().lastPathComponent.hasSuffix(".joining") { try? fm.removeItem(at: f) }
        var groups: [URL: [(Int, URL)]] = [:]
        for f in files where !isActive(f) { if let p = parse(f) { groups[p.base, default: []].append((p.index, f)) } }
        for (base, parts) in groups {
            let ordered = [base] + parts.sorted { $0.0 < $1.0 }.map(\.1)
            let joined = join(ordered, isTaken: isTaken)
            Log.note("recorder: recovered \(parts.count + 1) segments of an interrupted recording (\(joined.map { "joined into \($0.lastPathComponent)" } ?? "join failed, kept"))")
        }
    }
}

/// A WAV whose writer never closed it (the app quit mid-recording) has zero sizes in its header, so nothing can
/// read it. This sets the RIFF and data chunk sizes from the file's length. Only touches WAV files whose
/// sizes are wrong.
enum WavRepair {
    /// Where a WAV's sample bytes start and how many there are (from the file's length, not the header, which may
    /// be stale), the offset of the data chunk's size field, and the fmt chunk's fields (to check parts match).
    struct Layout {
        var dataOffset: UInt64
        var dataLength: UInt64
        var dataSizeField: UInt64
        var format: Data
    }

    static func layout(_ url: URL) -> Layout? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let len = try? h.seekToEnd() else { return nil }
        try? h.seek(toOffset: 0)
        guard let head = try? h.read(upToCount: 65536), head.count >= 12,
              String(data: head[0..<4], encoding: .ascii) == "RIFF", String(data: head[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        func u32(_ o: Int) -> UInt32 { head[o..<o + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        var o = 12
        var fmt: Data?
        while o + 8 <= head.count {
            let id = String(data: head[o..<o + 4], encoding: .ascii) ?? ""
            let size = Int(u32(o + 4))
            if id == "fmt " {
                guard o + 8 + 16 <= head.count else { return nil }
                fmt = head.subdata(in: (o + 8)..<(o + 8 + 16))
            } else if id == "data" {
                guard let fmt else { return nil }
                let start = UInt64(o + 8)
                guard len >= start else { return nil }
                return Layout(dataOffset: start, dataLength: (len - start) & ~1, dataSizeField: UInt64(o + 4), format: fmt)
            }
            o += 8 + size + (size & 1)
        }
        return nil
    }

    /// Writes the RIFF and data chunk sizes for `dataLength` sample bytes.
    static func writeSizes(_ h: FileHandle, layout: Layout, dataLength: UInt64) throws {
        func le(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]) }
        try h.seek(toOffset: 4)
        try h.write(contentsOf: le(UInt32(clamping: layout.dataOffset + dataLength - 8)))
        try h.seek(toOffset: layout.dataSizeField)
        try h.write(contentsOf: le(UInt32(clamping: dataLength)))
    }

    static func fixHeader(_ url: URL) {
        guard url.pathExtension.lowercased() == "wav",
              let h = try? FileHandle(forUpdating: url) else { return }
        defer { try? h.close() }
        guard let len = try? h.seekToEnd(), len > 44 else { return }
        try? h.seek(toOffset: 0)
        guard let head = try? h.read(upToCount: 4096), head.count >= 12,
              String(data: head[0..<4], encoding: .ascii) == "RIFF", String(data: head[8..<12], encoding: .ascii) == "WAVE" else { return }
        func u32(_ o: Int) -> UInt32 { head[o..<o + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        func le(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]) }
        var o = 12
        while o + 8 <= head.count {
            let id = String(data: head[o..<o + 4], encoding: .ascii) ?? ""
            let size = u32(o + 4)
            if id == "data" {
                let dataStart = UInt64(o + 8)
                guard len > dataStart else { return }
                let actual = UInt32(clamping: (len - dataStart) & ~1)
                let riff = UInt32(clamping: len - 8)
                guard size != actual || u32(4) != riff else { return }
                try? h.seek(toOffset: 4); h.write(le(riff))
                try? h.seek(toOffset: UInt64(o + 4)); h.write(le(actual))
                Log.note("recorder: repaired the header of \(url.lastPathComponent)")
                return
            }
            o += 8 + Int(size) + Int(size & 1)
        }
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
