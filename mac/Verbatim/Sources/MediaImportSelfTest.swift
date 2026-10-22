import Foundation
import AVFoundation

/// Import checks for the UI self-tests (Mac UITest, iPhone PhoneUITest), on the tiny files in
/// Resources/TestFixtures: an Opus MKV (1 s, 440 Hz), and an MKV and a MOV with two AAC tracks (track 1: English,
/// 440 Hz for the first half second; track 2: titled "Commentary" in both, 660 Hz for the second
/// half). Made with FFmpeg's sine and aevalsrc sources; no recordings of anyone.
enum MediaImportSelfTest {
    @MainActor
    static func run(_ check: (String, Bool) -> Void) async {
        guard let opus = Bundle.main.url(forResource: "tone-opus", withExtension: "mkv"),
              let mkv2 = Bundle.main.url(forResource: "two-tracks", withExtension: "mkv"),
              let mov2 = Bundle.main.url(forResource: "two-tracks", withExtension: "mov") else {
            // The iPhone app leaves the test files out (they'd ship to the App Store); the Mac's self-test runs these.
            #if os(macOS)
            check("test files are in the app", false)
            #else
            Log.note("UITEST SKIP import: the test files aren't in this build")
            #endif
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        check("FFmpeg \(FFmpegAudio.version) is loaded under the LGPL",
              FFmpegAudio.version.hasPrefix("7.1") && FFmpegAudio.license.contains("LGPL") && !FFmpegAudio.configuration.contains("--enable-gpl"))
        check("Acknowledgements has FFmpeg's notice and license",
              Acknowledgements.ffmpegNotice.contains("LGPL") && Acknowledgements.ffmpegLicense.contains("LESSER GENERAL PUBLIC LICENSE"))
        check("track names", MediaImport.trackLabels([("", "eng"), ("", "eng"), ("Commentary", "eng"), ("", "und")])
              == ["English", "English 2", "Commentary", "Track 4"])

        // FFmpeg on its own: an Opus MKV to a 16 kHz mono WAV.
        do {
            let wav = dir.appendingPathComponent("opus.wav")
            let d = try FFmpegAudio.decodeToWAV(opus, dest: wav)
            let level = rms(wav, from: 0, to: 1)
            Log.note("UITEST import opus mkv: \(String(format: "%.3f", d)) s, rms \(String(format: "%.3f", level))")
            check("FFmpeg decodes an Opus MKV to about 1 second", abs(d - 1) < 0.1)
            check("FFmpeg's WAV of the MKV isn't silent", level > 0.02)
        } catch {
            Log.note("UITEST import opus mkv failed: \(error.localizedDescription)")
            check("FFmpeg decodes an Opus MKV", false)
        }

        // The import path: MKV goes to FFmpeg; both formats with two tracks are mixed, or kept apart.
        for (name, src, secondLabel) in [("MKV", mkv2, "Commentary"), ("MOV", mov2, "Commentary")] {
            do {
                let p = try await MediaImport.prepare(src, into: dir.appendingPathComponent("mix-\(name).m4a"))
                let first = rms(p.url, from: 0.05, to: 0.45), second = rms(p.url, from: 0.6, to: 0.95)
                Log.note("UITEST import two-track \(name) mixed: \(String(format: "%.3f", p.duration)) s, rms \(String(format: "%.3f / %.3f", first, second))")
                check("two-track \(name): the mix lasts about 1 second", abs(p.duration - 1) < 0.15)
                check("two-track \(name): the mix has both tracks (neither half is silent)", first > 0.05 && second > 0.05)
                check("two-track \(name): mixing makes no separate tracks", p.tracks.isEmpty && p.multitrack == nil)
            } catch {
                Log.note("UITEST import two-track \(name) mix failed: \(error.localizedDescription)")
                check("two-track \(name) mixes", false)
            }
            do {
                let folder = dir.appendingPathComponent("tracks-\(name)", isDirectory: true)
                let p = try await MediaImport.prepare(src, into: dir.appendingPathComponent("sep-\(name).m4a"), separateTracksInto: folder)
                let names = p.tracks.map(\.speaker)
                Log.note("UITEST import two-track \(name) separate: \(names)")
                check("two-track \(name): two tracks named \(["English", secondLabel])", names == ["English", secondLabel])
                let files = p.tracks.map { folder.appendingPathComponent($0.fileName) }
                check("two-track \(name): each track has its own 16 kHz WAV of about 1 second",
                      files.count == 2 && files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                      && p.tracks.allSatisfy { abs($0.duration - 1) < 0.15 })
                if files.count == 2 {
                    // Track 1 sounds in the first half only, track 2 in the second half only.
                    check("two-track \(name): the tracks stay apart",
                          rms(files[0], from: 0.05, to: 0.45) > 0.05 && rms(files[0], from: 0.6, to: 0.95) < 0.02
                          && rms(files[1], from: 0.05, to: 0.45) < 0.02 && rms(files[1], from: 0.6, to: 0.95) > 0.05)
                }
                check("two-track \(name): the transcript becomes multi-track", p.multitrack?.tracks.count == 2)
            } catch {
                Log.note("UITEST import two-track \(name) separate failed: \(error.localizedDescription)")
                check("two-track \(name) keeps tracks apart", false)
            }
        }

        // A file that isn't media at all still fails with the plain message.
        let junk = dir.appendingPathComponent("not-a-video.mkv")
        try? Data("not a video".utf8).write(to: junk)
        do {
            _ = try await MediaImport.prepare(junk, into: dir.appendingPathComponent("junk.m4a"))
            check("a broken MKV fails clearly", false)
        } catch {
            check("a broken MKV fails clearly", error.localizedDescription == "“not-a-video.mkv” has no audio Verbose can read.")
        }
    }

    /// RMS level between two times (seconds) of any audio file AVAudioFile reads, as mono.
    static func rms(_ url: URL, from: Double, to: Double) -> Float {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = f.processingFormat.sampleRate
        let start = AVAudioFramePosition(from * rate), end = min(f.length, AVAudioFramePosition(to * rate))
        guard end > start, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(end - start)) else { return 0 }
        f.framePosition = start
        guard (try? f.read(into: buf, frameCount: AVAudioFrameCount(end - start))) != nil, let ch = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return (sum / Float(n)).squareRoot()
    }
}
