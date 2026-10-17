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
    private(set) var segments: [URL] = []

    /// `segmented`: roll to a new file every `RecordingSegments.seconds` (normal recordings, not dictation).
    init(url: URL, inputFormat: AVAudioFormat, segmented: Bool = false) throws {
        file = try AVAudioFile(forWriting: url, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        converter = AVAudioConverter(from: inputFormat, to: recordingFormat)
        segmentLimit = segmented ? Int64(recordingFormat.sampleRate * RecordingSegments.seconds) : nil
        segments = [url]
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
        guard let first = segments.first else { return }
        let next = RecordingSegments.url(for: first, index: segments.count + 1)
        guard let f = try? AVAudioFile(forWriting: next, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true) else {
            Log.note("recorder: couldn't open segment \(segments.count + 1); continuing in the current file")
            return
        }
        if #available(macOS 15, iOS 18, *) { file?.close() }
        file = f
        segments.append(next)
        Log.note("recorder: segment \(segments.count) started")
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
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            let v = w.write(buffer)
            let secs = w.seconds
            Task { @MainActor [weak self] in self?.meter(v, seconds: secs) }
        }
        tapFormat = inFormat
        observeConfiguration(of: engine)
        engine.prepare()
        try engine.start()
        startedAt = ProcessInfo.processInfo.systemUptime
        isRecording = true
        isPaused = false
    }

    private func meter(_ v: Float, seconds: TimeInterval) {
        guard isRecording else { return }
        live.push(v, seconds: seconds, paused: isPaused)
    }

    func togglePause() {
        isPaused.toggle()
        writer?.paused = isPaused
        if isPaused { live.reset(); live.setElapsed(writer?.seconds ?? 0) }
    }

    /// Returns the file URL, its duration, and the waveform envelope.
    func stop() -> (URL, TimeInterval, [Float])? {
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
            engine = nil
            tapFormat = nil
        }
        let firstDelay = w.firstBufferDelay
        let env = Waveform.resample(w.close(), to: 120)   // close() flushes the converter's last frames first
        let d = w.seconds
        if w.segments.count > 1 {
            // Long recording: one file again. On failure the segments stay on disk and are joined at next launch.
            if RecordingSegments.join(w.segments) {
                Log.note("recorder: joined \(w.segments.count) segments")
            } else {
                Log.note("recorder: couldn't join \(w.segments.count) segments; first segment kept, the rest recovered at next launch")
            }
        }
        writer = nil
        isRecording = false; isPaused = false
        live.reset()
        self.url = nil
        Log.note("recorder: stopped \(String(format: "%.2f", d))s, first audio \(firstDelay.map { "\($0) ms" } ?? "never") after start, warm=\(keepWarm)")
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if keepWarm {
            // Ready for the next dictation: prepared again, mic off.
            if stale || !armed { teardown() }
            if armed { warmUp() }
        }
        return (url, d, env)
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
            } else {
                // Normal recordings: carry on with the same device if its format is unchanged.
                let now = engine.inputNode.outputFormat(forBus: 0)
                if let was = tapFormat, now.sampleRate > 0, now.sampleRate == was.sampleRate, now.channelCount == was.channelCount {
                    do { try engine.start(); Log.note("recorder: restarted after configuration change") }
                    catch { Log.note("recorder: couldn't restart after configuration change: \(error.localizedDescription)") }
                }
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

    /// For "<name>.seg002.wav": the base URL "<name>.wav" and 2. nil for anything else.
    static func parse(_ url: URL) -> (base: URL, index: Int)? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let r = stem.range(of: marker, options: .backwards),
              let n = Int(stem[r.upperBound...]), n >= 2, stem[r.upperBound...].count == 3 else { return nil }
        let baseName = String(stem[..<r.lowerBound]) + "." + url.pathExtension
        return (url.deletingLastPathComponent().appendingPathComponent(baseName), n)
    }

    /// Appends segments 2… onto segment 1 (the recording's URL), in order, then deletes them. Written to a
    /// temporary file first and swapped in, so a failure leaves every segment as it was. Segment 1 may be
    /// missing (already adopted elsewhere): the remaining segments then become the file at that URL.
    @discardableResult
    static func join(_ urls: [URL]) -> Bool {
        let fm = FileManager.default
        guard let base = urls.first, urls.count > 1 else { return true }
        // Hidden and named ".joining.<ext>" (AVAudioFile picks the file type from the extension); launch recovery
        // skips hidden files and removes leftovers of this name.
        let tmp = base.deletingLastPathComponent().appendingPathComponent(".\(base.deletingPathExtension().lastPathComponent).joining.\(base.pathExtension)")
        try? fm.removeItem(at: tmp)
        let parts = urls.filter { fm.fileExists(atPath: $0.path) }
        guard !parts.isEmpty else { return false }
        var read = Set<URL>()
        do {
            let out = try AVAudioFile(forWriting: tmp, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            var any = false
            for part in parts {
                WavRepair.fixHeader(part)
                guard let src = try? AVAudioFile(forReading: part, commonFormat: .pcmFormatInt16, interleaved: true) else {
                    // Left on disk (not deleted below) rather than lost.
                    Log.note("recorder: segment \(part.lastPathComponent) unreadable; kept, not joined")
                    continue
                }
                read.insert(part)
                guard let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 1 << 16) else { continue }
                while src.framePosition < src.length {
                    try src.read(into: buf, frameCount: 1 << 16)
                    if buf.frameLength == 0 { break }
                    try out.write(from: buf)
                    any = true
                }
            }
            if #available(macOS 15, iOS 18, *) { out.close() }
            guard any else { try? fm.removeItem(at: tmp); return false }
        } catch {
            Log.note("recorder: join failed: \(error.localizedDescription)")
            try? fm.removeItem(at: tmp)
            return false
        }
        do {
            if fm.fileExists(atPath: base.path) { _ = try fm.replaceItemAt(base, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: base) }
        } catch {
            Log.note("recorder: couldn't replace the joined file: \(error.localizedDescription)")
            try? fm.removeItem(at: tmp)
            return false
        }
        for u in urls.dropFirst() where read.contains(u) { try? fm.removeItem(at: u) }
        return true
    }

    /// Deletes any segment files left beside `base` (a discarded recording whose join failed).
    static func removeSegments(of base: URL) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: base.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        where parse(f)?.base.lastPathComponent == base.lastPathComponent { try? fm.removeItem(at: f) }
    }

    /// At launch, before orphaned recordings are recovered: joins any leftover segments in `folder` onto their
    /// first file (or into a file at that name if the first was already adopted), and removes stale temp files.
    static func joinLeftovers(in folder: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        for f in files where f.lastPathComponent.hasPrefix(".") && f.deletingPathExtension().lastPathComponent.hasSuffix(".joining") { try? fm.removeItem(at: f) }
        var groups: [URL: [(Int, URL)]] = [:]
        for f in files { if let p = parse(f) { groups[p.base, default: []].append((p.index, f)) } }
        for (base, parts) in groups {
            let ordered = [base] + parts.sorted { $0.0 < $1.0 }.map(\.1)
            let ok = join(ordered)
            Log.note("recorder: recovered \(parts.count + 1) segments of an interrupted recording (\(ok ? "joined" : "join failed"))")
        }
    }
}

/// A WAV whose writer never closed it (the app quit mid-recording) has zero sizes in its header, so nothing can
/// read it. This sets the RIFF and data chunk sizes from the file's length. Only touches WAV files whose
/// sizes are wrong.
enum WavRepair {
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
