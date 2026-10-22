import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine

/// What an app capture saved when it stopped (`AppAudioCapture.stop`), like `StoppedRecording` for the mic.
struct StoppedCapture: Sendable {
    var url: URL
    var duration: TimeInterval
    /// Audio frames that reached the disk. Zero means nothing was captured.
    var framesWritten: Int64
    /// The segments couldn't be joined: every part stays in the recordings folder for launch recovery, and the
    /// caller must not adopt `url`.
    var joinFailed = false
    /// Parts that couldn't be read, in seconds of the recording. Silence stands in for each one.
    var skipped: [ClosedRange<Double>] = []
}

/// The capture queue's side of an app capture. Copies each sample buffer's audio into memory it owns (the sample
/// buffer's block is released once the callback returns), then writes it through a segmented `RecordingWriter`
/// on that same serial queue, so app captures get segments, a stop on a write failure, and crash safety like mic
/// recordings. Also feeds live captions and the meter. Thread-safe; `consume` runs on one serial queue.
final class AppAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: RecordingWriter?
    /// Live captions: a copy of every buffer, first channel only.
    let liveTap = LiveTapSlot()
    private var onLevel: (@Sendable (Float) -> Void)?

    func set(writer: RecordingWriter?, onLevel: (@Sendable (Float) -> Void)?) {
        lock.lock(); self.writer = writer; self.onLevel = onLevel; lock.unlock()
    }

    /// Copies a sample buffer's PCM audio into a new buffer that owns its memory. Nil for anything that isn't
    /// linear PCM or can't be copied.
    static func ownedCopy(of sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid, let desc = sampleBuffer.formatDescription,
              let asbd = desc.audioStreamBasicDescription, asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0 else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return pcm
    }

    /// Called on the capture queue for each audio sample buffer. Nothing keeps a pointer into the sample
    /// buffer's memory after the copy.
    func consume(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.ownedCopy(of: sampleBuffer) else { return }
        lock.lock()
        let w = writer, cb = onLevel
        lock.unlock()
        if let tap = liveTap.current, let copy = pcm.captionCopy() { tap(copy) }
        _ = w?.write(pcm)
        guard let cb else { return }
        var peak: Float = 0
        if let ch = pcm.floatChannelData?[0] {
            let stride = pcm.stride
            for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(ch[i * stride])) }
        }
        cb(min(1, pow(peak, 0.6) * 1.4))
    }
}

/// Records the audio of one running app with ScreenCaptureKit. macOS asks for Screen & System Audio
/// Recording permission the first time; no video frames are kept.
@MainActor
final class AppAudioCapture: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    struct RunningApp: Identifiable, Hashable {
        let id: String         // bundle identifier
        let name: String
        let app: SCRunningApplication
        static func == (a: RunningApp, b: RunningApp) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    @Published private(set) var isCapturing = false
    @Published private(set) var appName = ""
    /// The disk refused a write: the capture takes no audio until a retry (every 5 seconds) can write again.
    @Published private(set) var cantSave = false
    let live = LiveMeter()
    var elapsed: TimeInterval { live.elapsed }
    /// Live captions: every buffer of the app's audio also goes here, from the capture queue. Set before `start`.
    nonisolated var liveTap: LiveTapSlot { sink.liveTap }
    /// The stream ended on its own (the app quit, permission was withdrawn): what was captured is saved and handed
    /// here with the reason. Without a handler, the next `stop()` returns it instead.
    var onStreamError: ((StoppedCapture?, String) -> Void)?
    /// Short notices for the person (audio can't be saved; saving again).
    var onNotice: ((String) -> Void)?

    static let cantSaveNotice = "Verbatim can't save the app's audio. Free up space; it keeps trying."

    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var url: URL?
    private var stopTask: Task<StoppedCapture?, Never>?
    /// A capture the stream ended on its own, saved, and not yet handed to anyone.
    private var unclaimed: StoppedCapture?
    private var retryTimer: Timer?
    private nonisolated let sink = AppAudioSink()
    private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.capture")

    static func runningApps() async throws -> [RunningApp] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = Bundle.main.bundleIdentifier ?? ""
        return content.applications
            .filter { !$0.applicationName.isEmpty && $0.bundleIdentifier != me }
            .map { RunningApp(id: $0.bundleIdentifier, name: $0.applicationName, app: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .reduce(into: [RunningApp]()) { acc, a in if !acc.contains(a) { acc.append(a) } }
    }

    /// The format ScreenCaptureKit is asked for. The writer converts buffers that arrive in any other format.
    nonisolated static let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func start(app: RunningApp, to url: URL) async throws {
        unclaimed = nil
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Verbatim", code: 20, userInfo: [NSLocalizedDescriptionKey: "No display found to attach the capture to."])
        }
        let filter = SCContentFilter(display: display, including: [app.app], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16_000
        cfg.channelCount = 1
        // Keep video negligible: one tiny frame per second, discarded.
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false

        let w = try RecordingWriter(url: url, inputFormat: Self.captureFormat, segmented: true)
        RecordingSegments.setActive(url, true)
        w.setOnFailure { [weak self] in Task { @MainActor in self?.writeFailed() } }
        let startedAt = Date()
        sink.set(writer: w, onLevel: { [weak self] v in
            Task { @MainActor in self?.live.push(v, seconds: Date().timeIntervalSince(startedAt), paused: false) }
        })
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await s.startCapture()
        } catch {
            sink.set(writer: nil, onLevel: nil)
            _ = w.close()
            for u in w.segments { try? FileManager.default.removeItem(at: u) }
            RecordingSegments.setActive(url, false)
            throw error
        }
        writer = w
        self.url = url
        stream = s
        appName = app.name
        cantSave = false
        live.reset()
        isCapturing = true
        Log.note("app capture started: \(app.name)")
    }

    /// Stops and saves; a long capture's segments are joined off the main thread. Nil when nothing was capturing.
    /// After the stream ended on its own with no `onStreamError` handler, returns what that saved.
    func stop() async -> StoppedCapture? {
        if stream != nil, stopTask == nil { return await finish().value }
        if let t = stopTask { _ = await t.value }
        defer { unclaimed = nil }
        return unclaimed
    }

    private func finish() -> Task<StoppedCapture?, Never> {
        if let t = stopTask { return t }
        let t = Task { @MainActor [weak self] () -> StoppedCapture? in
            guard let self else { return nil }
            let r = await self.stopAndSave()
            self.stopTask = nil
            return r
        }
        stopTask = t
        return t
    }

    private func stopAndSave() async -> StoppedCapture? {
        guard let s = stream, let url, let w = writer else { return nil }
        try? await s.stopCapture()
        // Buffers already handed to the capture queue are written before the file closes.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
        sink.set(writer: nil, onLevel: nil)
        stream = nil
        writer = nil
        self.url = nil
        retryTimer?.invalidate(); retryTimer = nil
        cantSave = false
        isCapturing = false
        live.reset()
        _ = w.close()
        var result = StoppedCapture(url: url, duration: w.seconds, framesWritten: w.framesWritten)
        let parts = w.segments
        if parts.count > 1 {
            let joined = await Task.detached(priority: .userInitiated) { RecordingSegments.join(parts) }.value
            if let joined {
                result.url = joined.url
                result.skipped = joined.skipped
                result.duration = joined.seconds
            } else {
                result.joinFailed = true
                Log.note("app capture: couldn't join \(parts.count) segments; all kept for recovery at next launch")
            }
        }
        RecordingSegments.setActive(url, false)
        Log.note("app capture stopped: \(String(format: "%.2f", result.duration))s in \(parts.count) part\(parts.count == 1 ? "" : "s")")
        return result
    }

    /// The writer stopped taking audio (a full disk, usually). A fresh segment is tried every 5 seconds.
    private func writeFailed() {
        guard isCapturing, !cantSave else { return }
        cantSave = true
        onNotice?(Self.cantSaveNotice)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let w = self.writer, w.retryAfterFailure() else { return }
                self.retryTimer?.invalidate(); self.retryTimer = nil
                self.cantSave = false
                self.onNotice?("Saving the app's audio again.")
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        sink.consume(sampleBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let reason = error.localizedDescription
        Task { @MainActor in
            guard self.stream != nil, self.stopTask == nil else { return }
            Log.note("app capture stopped by the system: \(reason)")
            let r = await self.finish().value
            if let h = self.onStreamError { h(r, reason) } else { self.unclaimed = r }
        }
    }

    /// Self-test: feeds sample buffers through the live capture's path into a segmented writer at `url`.
    /// `afterEach` runs right after each buffer is consumed (the self-test scribbles over its memory there).
    /// Returns the frames written, or nil if the file couldn't be opened.
    nonisolated static func selfTestWrite(_ buffers: [CMSampleBuffer], to url: URL, afterEach: (CMSampleBuffer) -> Void) -> Int64? {
        guard let w = try? RecordingWriter(url: url, inputFormat: captureFormat, segmented: true) else { return nil }
        let sink = AppAudioSink()
        sink.set(writer: w, onLevel: nil)
        for b in buffers { sink.consume(b); afterEach(b) }
        sink.set(writer: nil, onLevel: nil)
        _ = w.close()
        return w.framesWritten
    }
}

/// A live-words tap that the audio side reads and the main actor sets. Thread-safe.
final class LiveTapSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var tap: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var current: (@Sendable (AVAudioPCMBuffer) -> Void)? { lock.lock(); defer { lock.unlock() }; return tap }
    func set(_ t: (@Sendable (AVAudioPCMBuffer) -> Void)?) { lock.lock(); tap = t; lock.unlock() }
}

extension AVAudioPCMBuffer {
    /// A copy with its own memory, first channel only (float formats). Nil for other formats.
    func captionCopy() -> AVAudioPCMBuffer? {
        guard let src = floatChannelData, frameLength > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameLength), let dst = out.floatChannelData else { return nil }
        out.frameLength = frameLength
        if stride == 1 {
            dst[0].update(from: src[0], count: Int(frameLength))
        } else {
            for i in 0..<Int(frameLength) { dst[0][i] = src[0][i * stride] }
        }
        return out
    }
}
