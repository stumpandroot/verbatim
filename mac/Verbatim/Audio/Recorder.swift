import Foundation
import AVFoundation
import Combine

/// Records 16 kHz mono WAV, which is what Whisper wants, so no conversion step later.
@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0        // 0…1, smoothed
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 28)

    private var rec: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?

    func start(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw NSError(domain: "Verbatim", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone did not start."]) }
        rec = r
        self.url = url
        elapsed = 0
        isRecording = true
        isPaused = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let r = rec else { return }
        r.updateMeters()
        elapsed = r.currentTime
        // -60 dB…0 dB mapped to 0…1 with a little curve so quiet rooms still move
        let db = max(-60, r.averagePower(forChannel: 0))
        let lin = pow(10, db / 20)
        let v = isPaused ? 0 : Float(min(1, pow(Double(lin), 0.6) * 1.6))
        level = level * 0.6 + v * 0.4
        levels.removeFirst()
        levels.append(level)
    }

    func togglePause() {
        guard let r = rec else { return }
        if isPaused { r.record() } else { r.pause() }
        isPaused.toggle()
    }

    /// Returns the file URL and its duration.
    func stop() -> (URL, TimeInterval)? {
        guard let r = rec, let url = url else { return nil }
        let d = r.currentTime
        r.stop()
        timer?.invalidate(); timer = nil
        rec = nil
        isRecording = false
        isPaused = false
        level = 0
        levels = Array(repeating: 0, count: 28)
        return (url, d)
    }
}
