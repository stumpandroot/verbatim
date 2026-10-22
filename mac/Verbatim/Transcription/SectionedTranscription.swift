import Foundation
import AVFoundation

// Long recordings, one section at a time: read about 5 minutes of 16 kHz mono audio, transcribe it, release it,
// read the next. Peak memory stays near one section's samples (about 19 MB) however long the recording is, and each
// finished section is saved on this device, so a job iOS stops (or the app being closed) picks up at the last
// finished section the next time it runs. Section boundaries and stitching are in LongFilePlan.swift.

/// Reads stretches of an audio file as 16 kHz mono float samples, without loading the whole file.
final class SectionAudio {
    static let sampleRate = 16_000
    let file: AVAudioFile
    /// Frames in the file, at its own rate (checkpoints compare it to tell the file hasn't changed).
    let frames: Int64
    /// The recording's length at 16 kHz.
    let totalSamples: Int
    private let sourceRate: Double
    private let native: Bool

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        frames = file.length
        sourceRate = file.processingFormat.sampleRate
        guard sourceRate > 0 else { throw SectionError.unreadable }
        native = sourceRate == Double(Self.sampleRate) && file.processingFormat.channelCount == 1
        totalSamples = Int((Double(frames) * Double(Self.sampleRate) / sourceRate).rounded(.down))
    }

    /// Up to `count` samples starting at sample `start` (16 kHz). Fewer at the end of the file.
    func read(start: Int, count: Int) throws -> [Float] {
        guard count > 0, start < totalSamples else { return [] }
        return try autoreleasepool { () throws -> [Float] in
            if native { return try readNative(start: start, count: count) }
            return try readConverted(start: start, count: count)
        }
    }

    /// Verbatim's own recordings: 16 kHz mono already, so frames are read as they are, 64k at a time.
    private func readNative(start: Int, count: Int) throws -> [Float] {
        file.framePosition = AVAudioFramePosition(start)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { throw SectionError.unreadable }
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count {
            buf.frameLength = 0
            let want = AVAudioFrameCount(min(Int(chunk), count - out.count))
            try file.read(into: buf, frameCount: want)
            guard buf.frameLength > 0, let ch = buf.floatChannelData?[0] else { break }
            out.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        }
        return out
    }

    /// Any other file (imports): reads the source a chunk at a time, resamples to 16 kHz, and averages the channels.
    private func readConverted(start: Int, count: Int) throws -> [Float] {
        let src = file.processingFormat
        let channels = src.channelCount
        guard let mid = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate), channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: src, to: mid),
              let input = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 1 << 15),
              let output = AVAudioPCMBuffer(pcmFormat: mid, frameCapacity: 1 << 14) else { throw SectionError.unreadable }
        file.framePosition = AVAudioFramePosition((Double(start) * sourceRate / Double(Self.sampleRate)).rounded(.down))
        // A little extra source so the resampler's tail reaches `count`.
        var sourceLeft = AVAudioFrameCount((Double(count) * sourceRate / Double(Self.sampleRate)).rounded(.up)) + 64
        var finished = false
        var readError: Error? = nil
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { wanted, status in
                if finished || sourceLeft == 0 { status.pointee = .endOfStream; return nil }
                input.frameLength = 0
                let n = min(wanted, input.frameCapacity, sourceLeft)
                do { try self.file.read(into: input, frameCount: n) } catch { readError = error; finished = true; status.pointee = .endOfStream; return nil }
                if input.frameLength == 0 { finished = true; status.pointee = .endOfStream; return nil }
                sourceLeft -= min(sourceLeft, input.frameLength)
                status.pointee = .haveData
                return input
            }
            if status == .error { throw (error as Error?) ?? readError ?? SectionError.unreadable }
            let n = min(Int(output.frameLength), count - out.count)
            if n > 0, let data = output.floatChannelData {
                if channels == 1 {
                    out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
                } else {
                    let scale = 1 / Float(channels)
                    for i in 0..<n {
                        var sum: Float = 0
                        for c in 0..<Int(channels) { sum += data[c][i] }
                        out.append(sum * scale)
                    }
                }
            }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        if let readError, out.isEmpty { throw readError }
        return out
    }
}

enum SectionError: LocalizedError {
    case unreadable
    var errorDescription: String? { "Verbatim couldn't read this recording's audio." }
}

/// Finished sections of one recording, saved on this device (never synced: the audio folder can be in iCloud, and
/// a half-done job is this device's business). Mirrors the recorder's JoinMarker: small JSON files written
/// atomically, checked before they're trusted. A header says what the job was (file, engine, model, language,
/// section sizes); each finished section is its own file, so a crash mid-write loses at most that section.
struct SectionCheckpoint {
    struct Header: Codable, Equatable {
        var version = 1
        /// The recording's file name in the audio folder.
        var audio: String
        /// Its length in frames; a different length means a different file, and the saved sections are dropped.
        var frames: Int64
        var engine: String
        var model: String
        var language: String?
        var window: Int
        var overlap: Int
    }

    struct Saved: Codable {
        var index: Int
        /// Samples at 16 kHz.
        var start: Int
        var end: Int
        /// The recording's time, in seconds.
        var words: [SectionWord]
    }

    let folder: URL
    let header: Header

    static var root: URL { Paths.local.appendingPathComponent("sections", isDirectory: true) }

    static func folder(for audio: String) -> URL {
        root.appendingPathComponent(audio + ".sections", isDirectory: true)
    }

    private static func headerURL(_ folder: URL) -> URL { folder.appendingPathComponent("job.json") }

    /// The saved job for this recording, if any.
    static func savedHeader(audio: String) -> Header? {
        guard let data = try? Data(contentsOf: headerURL(folder(for: audio))),
              let h = try? JSONDecoder().decode(Header.self, from: data), h.version == 1, h.audio == audio else { return nil }
        return h
    }

    /// Opens this job's checkpoint: the saved sections stay when the saved header matches, else they're cleared
    /// and the header is written fresh. Nil when the folder can't be written (the job then runs without one).
    static func open(_ header: Header) -> SectionCheckpoint? {
        let dir = folder(for: header.audio)
        let fm = FileManager.default
        if savedHeader(audio: header.audio) != header { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: headerURL(dir).path) {
                try JSONEncoder().encode(header).write(to: headerURL(dir), options: .atomic)
            }
        } catch {
            Log.note("sections: couldn't save progress for \(header.audio): \(error.localizedDescription)")
            return nil
        }
        return SectionCheckpoint(folder: dir, header: header)
    }

    private func url(_ index: Int) -> URL { folder.appendingPathComponent(String(format: "%05d.json", index)) }

    /// Saved sections in order from the first, stopping at the first one missing or unreadable.
    func load() -> [Saved] {
        var out: [Saved] = []
        while let data = try? Data(contentsOf: url(out.count)), let s = try? JSONDecoder().decode(Saved.self, from: data),
              s.index == out.count, s.end > s.start, s.start >= 0, out.last.map({ s.start < $0.end && s.start > $0.start }) ?? (s.start == 0) {
            out.append(s)
        }
        return out
    }

    func save(_ s: Saved) {
        do { try JSONEncoder().encode(s).write(to: url(s.index), options: .atomic) }
        catch { Log.note("sections: couldn't save section \(s.index + 1): \(error.localizedDescription)") }
    }

    static func remove(audio: String) {
        try? FileManager.default.removeItem(at: folder(for: audio))
    }

    /// Removes saved sections for every recording not in `keeping` (finished, deleted, or cancelled elsewhere).
    static func sweep(keeping: Set<String>) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for item in items where item.hasSuffix(".sections") {
            let audio = String(item.dropLast(".sections".count))
            if !keeping.contains(audio) { try? fm.removeItem(at: root.appendingPathComponent(item)) }
        }
    }
}

/// Transcribes a recording section by section with one engine, stitching the sections' words together.
enum SectionedTranscriber {
    struct Engine {
        /// "fluid" or "apple" (saved in the checkpoint).
        var id: String
        var plan: SectionPlan
        /// Words for one section's samples, timed from the section's start.
        var transcribe: @Sendable ([Float]) async throws -> [SectionWord]
    }

    /// Words for the whole recording, in its time. `checkpoint` (when given) supplies finished sections and saves
    /// new ones. Progress is the share of the recording done, after each section.
    static func run(url: URL, audio: SectionAudio? = nil, engine: Engine, checkpoint: SectionCheckpoint?,
                    progress: @escaping @Sendable (EngineProgress) -> Void) async throws -> [SectionWord] {
        let audio = try audio ?? SectionAudio(url: url)
        let plan = engine.plan
        let rate = Double(SectionAudio.sampleRate)
        var total = audio.totalSamples
        var words: [SectionWord] = []
        var previous: (start: Int, end: Int)? = nil
        var index = 0
        if let checkpoint {
            for s in checkpoint.load() {
                words = previous.map { SectionStitcher.stitch(words, s.words, overlapStart: Double(s.start) / rate, overlapEnd: Double($0.end) / rate) } ?? s.words
                previous = (s.start, s.end)
                index += 1
            }
            if index > 0 { Log.note("sections: resuming \(url.lastPathComponent) after section \(index)") }
        }
        let count = plan.estimatedCount(total: total)
        while let r = plan.next(after: previous?.end, total: total) {
            try Task.checkCancellation()
            progress(.transcribing(Double(r.lowerBound) / Double(max(1, total))))
            var samples = try audio.read(start: r.lowerBound, count: r.count)
            if samples.count < r.count {
                // The file is shorter than its header said: this is the last section.
                total = r.lowerBound + samples.count
            }
            if r.lowerBound + samples.count < total, let cut = plan.quietCut(in: samples) {
                samples.removeLast(samples.count - cut)
            }
            guard !samples.isEmpty else { break }
            let end = r.lowerBound + samples.count
            let heard = try await engine.transcribe(samples)
            samples = []   // released before the next section is read
            // Cancelled mid-section (or started again in another language): nothing more is saved.
            try Task.checkCancellation()
            let placed = SectionStitcher.offset(heard, by: Double(r.lowerBound) / rate)
            words = previous.map { SectionStitcher.stitch(words, placed, overlapStart: Double(r.lowerBound) / rate, overlapEnd: Double($0.end) / rate) } ?? placed
            checkpoint?.save(SectionCheckpoint.Saved(index: index, start: r.lowerBound, end: end, words: placed))
            previous = (r.lowerBound, end)
            index += 1
            if index % 6 == 0 || end >= total { Log.note("sections: \(index) of about \(count) done") }
            if end >= total { break }
        }
        progress(.transcribing(1))
        return words
    }
}
