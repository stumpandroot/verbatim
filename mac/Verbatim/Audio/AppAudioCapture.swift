import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine

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
    let live = LiveMeter()
    var elapsed: TimeInterval { live.elapsed }
    /// Live captions: every buffer of the app's audio also goes here, from the capture queue. Set before `start`.
    nonisolated let liveTap = LiveTapSlot()

    private var stream: SCStream?
    private var file: AVAudioFile?
    private var url: URL?
    private var startedAt: Date?
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

    func start(app: RunningApp, to url: URL) async throws {
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

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: format.commonFormat, interleaved: false)
        self.url = url

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        appName = app.name
        startedAt = Date()
        live.reset()
        isCapturing = true
        Log.note("app capture started: \(app.name)")
    }

    /// Returns the file URL and duration.
    func stop() async -> (URL, TimeInterval)? {
        guard let s = stream, let url else { return nil }
        try? await s.stopCapture()
        stream = nil
        file = nil
        let d = elapsed
        isCapturing = false
        live.reset()
        self.url = nil
        return (url, d)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let fmt = sampleBuffer.formatDescription else { return }
        guard let asbd = fmt.audioStreamBasicDescription else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        var blockBuffer: CMBlockBuffer?
        let abl = pcm.mutableAudioBufferList
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size + Int(asbd.mChannelsPerFrame - 1) * MemoryLayout<AudioBuffer>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr else { return }
        // A copy for live captions: the buffer's data lives in the sample buffer's block, released after this call.
        if let tap = liveTap.current, let copy = pcm.captionCopy() { tap(copy) }
        // Peak level for the meter
        var peak: Float = 0
        if let ch = pcm.floatChannelData?[0] {
            for i in 0..<Int(frames) { peak = max(peak, abs(ch[i])) }
        }
        let v = min(1, pow(peak, 0.6) * 1.4)
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? self.file?.write(from: pcm)
            self.live.push(v, seconds: self.startedAt.map { Date().timeIntervalSince($0) } ?? 0, paused: false)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in Log.note("app capture stopped: \(error.localizedDescription)"); _ = await self.stop() }
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
        dst[0].update(from: src[0], count: Int(frameLength))
        return out
    }
}
