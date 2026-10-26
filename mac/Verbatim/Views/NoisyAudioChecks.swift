import SwiftUI
import AVFoundation

/// Self-test checks for the noisy-recording work, run by both apps' self-tests (UITest, PhoneUITest): Transcribe
/// again with Whisper Turbo is offered and starts a job (simulated: its audio is missing, so nothing downloads or
/// runs, and the transcript comes back as it was), the unclear chips and low-confidence marks render, and Reduce
/// background noise toggles without touching the transcript. Synthetic data only.
@MainActor
enum NoisyAudioChecks {
    /// `start` starts Transcribe again with Whisper Turbo the way the app's menu does (the Mac runs it; the iPhone's
    /// request needs a Mac, so its self-test passes nil and checks the request instead). `cancel` stops a job.
    static func run(store: Store, player: Player, start: ((UUID) -> Void)?, cancel: @escaping (UUID) -> Void,
                    check: (String, Bool) -> Void) async {
        check("turbo: the action's model is Whisper Large v3 Turbo",
              Engines.displayName(engine: Transcript.turboEngine, model: Transcript.turboModel) == Transcript.turboName
                && Engines.options.contains { $0.engine == Transcript.turboEngine && $0.model == Transcript.turboModel })

        var t = Transcript(title: "Self-test lawn", source: .voiceMemo, sourceLabel: "Voice memo", duration: 60,
                           audioFileName: "selftest-noisy-\(UUID().uuidString.prefix(8)).m4a", model: "Parakeet TDT v2")
        t.engine = "fluid"
        // Labeled and summarized already, so nothing that runs after a job changes it while the checks compare.
        t.kind = .note; t.kindIsAuto = false; t.titleIsAuto = false
        t.summary = TranscriptSummary(overview: "A self-test recording."); t.summaryByModel = false
        t.segments = [Segment(start: 0, end: 8, text: "Mowing the back now.", words: [
                        WordSpan(text: "Mowing", start: 0.2, end: 0.8, confidence: 0.9), WordSpan(text: "the", start: 0.9, end: 1.1, confidence: 0.2),
                        WordSpan(text: "back", start: 1.2, end: 1.6, confidence: 0.25), WordSpan(text: "now.", start: 1.7, end: 2.1, confidence: 0.8)]),
                      Segment(start: 14, end: 20, text: "Her name's a kid in Alien.")]
        t.original = t.segments
        t.unclear = [UnclearSpan(start: 9, end: 13)]
        check("turbo: offered for a ready transcript with audio", TurboRerun.unavailableReason(t) == nil)
        var busy = t; busy.status = .processing
        check("turbo: not offered while it's being made", TurboRerun.unavailableReason(busy) != nil)
        store.add(t)
        let id = t.id
        let words = t.segments

        if let start {
            start(id)
            let started = store.transcript(id).map { $0.rerunRequest?.model == Transcript.turboModel && $0.status == .processing } ?? false
            check("turbo: Transcribe again starts a Whisper Turbo job", started)
            // The audio is missing on purpose: the job stops before any model loads, and the words stay.
            for _ in 0..<50 {
                if let x = store.transcript(id), x.status == .ready, x.rerunRequest == nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if store.transcript(id)?.status == .processing { cancel(id) }   // still queued behind another job
            let back = store.transcript(id)
            check("turbo: a job that can't run leaves the transcript as it was",
                  back?.status == .ready && back?.segments == words && back?.rerunRequest == nil && back?.previousVersion == nil)
        } else {
            store.update(id) { $0.rerunRequest = RerunRequest(engine: Transcript.turboEngine, model: Transcript.turboModel, device: Device.id) }
            check("turbo: the iPhone's request says \"Waiting for your Mac\"", store.transcript(id)?.stageText == "Waiting for your Mac")
            store.update(id) { $0.rerunRequest = nil }
        }

        // Switching between the kept words and the new ones.
        store.update(id) { x in
            let old = x.currentVersion
            x.segments = [Segment(start: 0, end: 20, text: "Mowing the back now. Her name's a kid in Alien.")]; x.original = x.segments
            x.engine = Transcript.turboEngine; x.model = Transcript.turboName
            x.previousVersion = old
        }
        check("turbo: Switch to … names the kept words", store.transcript(id).flatMap(TurboRerun.switchTitle) == "Switch to Parakeet TDT v2")
        store.update(id) { _ = $0.switchVersion() }
        check("turbo: switching brings the kept words back", store.transcript(id)?.segments == words)

        // The unclear chip and the low-confidence marks.
        if let x = store.transcript(id) {
            let chips = UnclearStyle.chips(x, lines: x.segments)
            check("unclear: a chip sits before the line after the gap", chips[1]?.first?.start == 9)
            let plain = AttributedString(x.segments[0].text)
            check("unclear: low-confidence words are underlined", UnclearStyle.marked(plain, x.segments[0]) != plain)
            let confident = AttributedString(x.segments[1].text)
            check("unclear: confident lines aren't", UnclearStyle.marked(confident, x.segments[1]) == confident)
        }
        let renderer = ImageRenderer(content: UnclearChip(span: UnclearSpan(start: 130, end: 133), onPlay: {}).padding(4))
        let image = renderer.cgImage
        check("unclear: the chip renders (\(image.map { "\($0.width)×\($0.height)" } ?? "nothing"))", (image?.width ?? 0) > 20 && (image?.height ?? 0) > 10)
        check("unclear: the chip reads \"unclear 2:10\"", UnclearRules.label(130) == "unclear 2:10")

        // Reduce background noise: listening only.
        let before = store.transcript(id)
        let was = player.reduceNoise
        player.setReduceNoise(true)
        let on = player.reduceNoise
        check("listening: the switch turns on, or says it's unavailable and stays off (voice isolation here: \(ListeningCleanup.isAvailable))",
              on == ListeningCleanup.isOn && (on || !ListeningCleanup.isAvailable || player.loadedURL != nil))
        player.setReduceNoise(false)
        check("listening: the switch turns off and is remembered", !player.reduceNoise && !ListeningCleanup.isOn)
        check("listening: the transcript doesn't change", store.transcript(id) == before)
        if ListeningCleanup.isAvailable, let tone = toneFile() {
            check("listening: voice isolation opens for a recording", player.cleanPlaybackOpens(tone))
            try? FileManager.default.removeItem(at: tone)
        }
        player.setReduceNoise(was)

        if let x = store.transcript(id) { store.delete(x) }
    }

    /// One second of a 220 Hz tone, 16 kHz mono, in a temporary file.
    private static func toneFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-tone-\(UUID().uuidString.prefix(6)).caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return nil }
        buf.frameLength = 16_000
        for i in 0..<16_000 { buf.floatChannelData?[0][i] = 0.2 * sin(Float(i) * 2 * .pi * 220 / 16_000) }
        do { try file.write(from: buf) } catch { return nil }
        return url
    }
}
