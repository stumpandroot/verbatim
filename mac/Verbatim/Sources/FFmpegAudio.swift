import Foundation
import AVFoundation

/// Reads the audio in files AVFoundation can't open (MKV, WebM, AVI, FLV, WMV, Ogg) with the bundled audio-only
/// FFmpeg (mac/ffmpeg/build.sh, LGPL 2.1, linked dynamically). VBFFmpeg.c does the decoding; this side writes files.
/// Everything here is synchronous, stream-based (constant memory), and stops when the calling task is cancelled.
/// Call it off the main thread.
enum FFmpegAudio {
    /// One audio track as the file describes it.
    struct Track: Equatable {
        var title: String
        var language: String
        var codec: String
    }

    struct Probe {
        var tracks: [Track]
        var duration: Double
    }

    /// The linked FFmpeg's version, configure options, and license, for Settings › About › Acknowledgements.
    static var version: String { String(cString: vbff_version()) }
    static var configuration: String { String(cString: vbff_configuration()) }
    static var license: String { String(cString: vbff_license()) }

    /// The track number `decode`'s sink gets for the mix of every track (VBFF_MIX).
    static let mixTrack = -1

    static func err(_ s: String) -> NSError { NSError(domain: "Verbatim", code: 41, userInfo: [NSLocalizedDescriptionKey: s]) }

    private static func noAudio(_ src: URL) -> NSError { err("“\(src.lastPathComponent)” has no audio Verbatim can read.") }

    private static func string(_ buf: [CChar]) -> String {
        buf.withUnsafeBufferPointer { p in p.baseAddress.map { String(cString: $0) } ?? "" }
    }

    private static func open(_ src: URL) throws -> OpaquePointer {
        var message = [CChar](repeating: 0, count: 256)
        guard let d = vbff_open(src.path, &message, Int32(message.count)) else {
            Log.note("ffmpeg: couldn't open \(src.pathExtension) file: \(string(message))")
            throw noAudio(src)
        }
        return d
    }

    private static func tracks(_ d: OpaquePointer) -> [Track] {
        (0..<Int(vbff_track_count(d))).map { i in
            var title = [CChar](repeating: 0, count: 256), lang = [CChar](repeating: 0, count: 64), codec = [CChar](repeating: 0, count: 64)
            vbff_track_title(d, Int32(i), &title, Int32(title.count))
            vbff_track_language(d, Int32(i), &lang, Int32(lang.count))
            vbff_track_codec(d, Int32(i), &codec, Int32(codec.count))
            return Track(title: string(title), language: string(lang), codec: string(codec))
        }
    }

    /// The audio tracks FFmpeg can decode in `src`, and the file's duration.
    static func probe(_ src: URL) throws -> Probe {
        let d = try open(src)
        defer { vbff_close(d) }
        return Probe(tracks: tracks(d), duration: vbff_duration(d))
    }

    // MARK: Decoding

    /// What the C callbacks reach: the sink for samples, the progress handler, and the first error a sink threw.
    private final class Context {
        let sink: (Int, UnsafeBufferPointer<Float>) throws -> Void
        let progress: ((Double) -> Void)?
        var error: Error?
        init(sink: @escaping (Int, UnsafeBufferPointer<Float>) throws -> Void, progress: ((Double) -> Void)?) {
            self.sink = sink; self.progress = progress
        }
    }

    /// Decodes every audio track of `src` to mono float samples at `sampleRate`. `sink` gets track -1 for the mix of
    /// all tracks, and 0…n-1 for each track on its own when `separate` is true. Returns the tracks.
    @discardableResult
    static func decode(_ src: URL, sampleRate: Int = 16_000, separate: Bool = false,
                       progress: ((Double) -> Void)? = nil,
                       sink: @escaping (Int, UnsafeBufferPointer<Float>) throws -> Void) throws -> [Track] {
        try Task.checkCancellation()
        let d = try open(src)
        defer { vbff_close(d) }
        let found = tracks(d)
        Log.note("ffmpeg: \(src.pathExtension) file, \(found.count) audio track(s): \(found.map(\.codec).joined(separator: ", "))")
        let context = Context(sink: sink, progress: progress)
        let ctx = Unmanaged.passUnretained(context).toOpaque()
        let onSamples: vbff_samples_fn = { ctx, track, samples, count in
            guard let ctx = ctx, let samples = samples else { return 0 }
            let c = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
            if Task.isCancelled { c.error = CancellationError(); return 1 }
            do { try c.sink(Int(track), UnsafeBufferPointer(start: samples, count: Int(count))) } catch { c.error = error; return 1 }
            return 0
        }
        let onProgress: vbff_progress_fn = { ctx, fraction in
            guard let ctx = ctx else { return 0 }
            let c = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
            if Task.isCancelled { c.error = CancellationError(); return 1 }
            c.progress?(fraction)
            return 0
        }
        var message = [CChar](repeating: 0, count: 256)
        let result = withExtendedLifetime(context) {
            vbff_decode(d, Int32(sampleRate), separate ? 1 : 0, ctx, onSamples, onProgress, &message, Int32(message.count))
        }
        if let e = context.error { throw e }
        if result == 1 { throw CancellationError() }
        if result < 0 {
            Log.note("ffmpeg: decode failed: \(string(message))")
            throw noAudio(src)
        }
        return found
    }

    /// The audio of `src` as a 16-bit mono WAV at `sampleRate`, every track mixed. Returns the duration in seconds.
    static func decodeToWAV(_ src: URL, dest: URL, sampleRate: Int = 16_000, progress: ((Double) -> Void)? = nil) throws -> Double {
        let out = try WAVWriter(url: dest, sampleRate: sampleRate)
        do {
            try decode(src, sampleRate: sampleRate, progress: progress) { track, samples in
                if track == mixTrack { try out.write(samples) }
            }
            try out.finish()
        } catch {
            out.abandon()
            throw error
        }
        guard out.frames > 0 else { try? FileManager.default.removeItem(at: dest); throw noAudio(src) }
        return Double(out.frames) / Double(sampleRate)
    }
}

/// A 16-bit PCM mono WAV written as samples arrive. The header's sizes are filled in by `finish()`.
final class WAVWriter {
    let url: URL
    let sampleRate: Int
    private(set) var frames = 0
    private let handle: FileHandle
    private var pending = Data()

    init(url: URL, sampleRate: Int) throws {
        self.url = url; self.sampleRate = sampleRate
        // Never replaces a file: the writer creates its own (failing if the name is taken), so `abandon` and the
        // callers' cleanup only ever delete what this writer made.
        do { try AudioNaming.claim(url, contents: WAVWriter.header(dataBytes: 0, sampleRate: sampleRate)) }
        catch let e as AudioNaming.AlreadyExists { throw e }
        catch { throw FFmpegAudio.err("Couldn't write the audio.") }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func write(_ samples: UnsafeBufferPointer<Float>) throws {
        var ints = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() where s.isFinite {
            ints[i] = Int16(max(-1, min(1, s)) * 32767).littleEndian
        }
        ints.withUnsafeBufferPointer { pending.append($0) }
        frames += samples.count
        if pending.count >= 1 << 18 { try flush() }
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        try handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    func finish() throws {
        try flush()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVWriter.header(dataBytes: frames * 2, sampleRate: sampleRate))
        try handle.close()
    }

    /// Closes and deletes a half-written file.
    func abandon() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    static func header(dataBytes: Int, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}

/// Mono float samples into an AAC .m4a (AVAudioFile encodes), a second at a time. Falls back to a WAV next to it
/// when this system can't encode AAC at the rate asked for.
final class MonoAudioWriter {
    private(set) var url: URL
    let sampleRate: Int
    private(set) var frames = 0
    private var file: AVAudioFile?
    private var wav: WAVWriter?
    private var pending: [Float] = []

    init(m4a: URL, sampleRate: Int) throws {
        self.sampleRate = sampleRate
        url = m4a
        // Claims the name first (fails if a file is there), so this writer never replaces or deletes a file it
        // didn't create. AVAudioFile then writes over the empty file it just made.
        try AudioNaming.claim(m4a)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(sampleRate), AVNumberOfChannelsKey: 1]
        if let f = try? AVAudioFile(forWriting: m4a, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
            file = f
        } else {
            try? FileManager.default.removeItem(at: m4a)
            url = m4a.deletingPathExtension().appendingPathExtension("wav")
            wav = try WAVWriter(url: url, sampleRate: sampleRate)
            Log.note("audio writer: AAC at \(sampleRate) Hz unavailable; writing WAV")
        }
    }

    func write(_ samples: UnsafeBufferPointer<Float>) throws {
        frames += samples.count
        if let wav { try wav.write(samples); return }
        pending.append(contentsOf: samples)
        if pending.count >= sampleRate { try flush() }
    }

    private func flush() throws {
        guard let file, !pending.isEmpty else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(pending.count)),
              let ch = buf.floatChannelData else { throw FFmpegAudio.err("Couldn't write the audio.") }
        buf.frameLength = AVAudioFrameCount(pending.count)
        pending.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for c in 0..<Int(file.processingFormat.channelCount) { ch[c].update(from: base, count: pending.count) }
        }
        try file.write(from: buf)
        pending.removeAll(keepingCapacity: true)
    }

    /// Writes what's left and closes the file.
    func finish() throws {
        if let wav { try wav.finish(); return }
        try flush()
        file = nil   // AVAudioFile finishes the file when it's released
    }

    func abandon() {
        wav?.abandon()
        file = nil
        try? FileManager.default.removeItem(at: url)
    }

    var duration: Double { Double(frames) / Double(sampleRate) }
}
