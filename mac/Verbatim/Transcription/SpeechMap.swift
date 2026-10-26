import Foundation
import FluidAudio

/// Where people talk in a recording: Silero VAD's speech probability for every 256 ms (FluidAudio's `VadManager`),
/// read five minutes at a time so a long file never sits in memory whole. Whisper hears only the speech it finds
/// (UnclearRules.speechClips), and every new transcript's unclear spans come from it (UnclearRules.unclearSpans).
/// Fails open: when the detector can't load or read the file, the caller carries on without it.
actor SpeechMap {
    static let shared = SpeechMap()

    private var manager: VadManager?
    private var retryAt: Date?

    /// Five minutes of 16 kHz audio, a whole number of the detector's 4,096-sample frames.
    private static let section = (5 * 60 * 16_000 / VadManager.chunkSize) * VadManager.chunkSize

    /// The detector, loaded once (a small download the first time, shared with dictation's). nil when it can't load,
    /// trying again a minute later.
    private func detector() async -> VadManager? {
        if let manager { return manager }
        if let r = retryAt, Date() < r { return nil }
        do {
            if !LocalOnly.modelReady("vad") { try NetworkGate.begin(.modelDownload, host: "huggingface.co") }
            let m = try await VadManager(config: VadConfig(defaultThreshold: UnclearRules.vadThreshold))
            LocalOnly.markModelReady("vad")
            manager = m
            retryAt = nil
            return m
        } catch {
            retryAt = Date().addingTimeInterval(60)
            Log.note("speech map: detector unavailable (\(error.localizedDescription))")
            return nil
        }
    }

    /// The recording's speech probabilities, or nil when the detector or the file can't be read.
    func probabilities(url: URL) async -> SpeechProbabilities? {
        guard let vad = await detector() else { return nil }
        let started = Date()
        do {
            let audio = try SectionAudio(url: url)
            var values: [Float] = []
            values.reserveCapacity(audio.totalSamples / VadManager.chunkSize + 1)
            var start = 0
            while start < audio.totalSamples {
                try Task.checkCancellation()
                let samples = try audio.read(start: start, count: Self.section)
                if samples.isEmpty { break }
                values += try await vad.process(samples).map(\.probability)
                start += Self.section
            }
            let p = SpeechProbabilities(frame: Double(VadManager.chunkSize) / Double(VadManager.sampleRate), values: values)
            let speech = UnclearRules.coverage(UnclearRules.speechClips(p), duration: p.duration)
            Log.note("speech map: \(Int(p.duration)) s, speech \(Int(speech * 100))%, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            return p
        } catch is CancellationError {
            return nil
        } catch {
            Log.note("speech map: couldn't read the audio (\(error.localizedDescription))")
            return nil
        }
    }
}
