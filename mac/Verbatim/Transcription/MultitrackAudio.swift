import Foundation
import AVFoundation

/// Reads any audio file as mono float samples at a chosen rate, a block at a time.
final class PCMStream {
    let sourceRate: Double
    let duration: Double
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let input: AVAudioPCMBuffer
    private var inputDone = false
    private(set) var finished = false

    init(url: URL, sampleRate: Double) throws {
        file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        sourceRate = inFormat.sampleRate
        duration = inFormat.sampleRate > 0 ? Double(file.length) / inFormat.sampleRate : 0
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: out),
              let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 16384) else {
            throw MultitrackAudio.err("Couldn't read “\(url.lastPathComponent)”.")
        }
        conv.downmix = true
        format = out; converter = conv; input = buf
    }

    /// Up to `count` samples; fewer only at the end of the file.
    func read(_ count: Int) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count, !finished {
            let want = AVAudioFrameCount(min(count - out.count, 65536))
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: want) else { finished = true; break }
            var error: NSError?
            let status = converter.convert(to: buf, error: &error) { [self] packets, inStatus in
                if inputDone { inStatus.pointee = .endOfStream; return nil }
                input.frameLength = 0
                let n = min(AVAudioFrameCount(packets), input.frameCapacity)
                do { try file.read(into: input, frameCount: n) } catch { inputDone = true }
                if input.frameLength == 0 { inputDone = true; inStatus.pointee = .endOfStream; return nil }
                inStatus.pointee = .haveData
                return input
            }
            if buf.frameLength > 0, let ch = buf.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
            }
            if status == .error || status == .endOfStream || (buf.frameLength == 0 && inputDone) { finished = true }
        }
        return out
    }
}

/// The audio side of multi-track transcription: working copies, envelopes for lining up and bleed, and the
/// mixed file for playback. Synchronous and cancellable (checks `Task.isCancelled`); call it off the main thread.
enum MultitrackAudio {
    /// Working copies are 16 kHz mono, what the engines use anyway.
    static let workRate: Double = 16_000
    static var hop: Int { Int(workRate / MultitrackMath.frameRate) }
    static let mixRate: Double = 44_100

    static func err(_ s: String) -> NSError { NSError(domain: "Verbatim", code: 31, userInfo: [NSLocalizedDescriptionKey: s]) }

    /// What the sheet shows for a picked file.
    struct Analysis {
        var duration: Double
        var sampleRate: Double
        /// 64 bars, 0…1.
        var wave: [Float]
        /// RMS envelope of the first five minutes, for lining up.
        var alignEnvelope: [Float]
    }

    static func analyze(_ url: URL) throws -> Analysis {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let stream = try PCMStream(url: url, sampleRate: workRate)
        guard stream.duration > 0 else { throw err("“\(url.lastPathComponent)” has no audio Verbose can read.") }
        // One pass over the whole file at 16 kHz: the 100 Hz envelope, from which both the bars and the first
        // five minutes for lining up come.
        var env: [Float] = []
        while !stream.finished {
            try Task.checkCancellation()
            let block = stream.read(Int(workRate) * 10)
            env += MultitrackMath.envelope(block, hop: hop)
        }
        let align = Array(env.prefix(Int(MultitrackMath.alignWindow * MultitrackMath.frameRate)))
        return Analysis(duration: stream.duration, sampleRate: stream.sourceRate, wave: bars(env, count: 64), alignEnvelope: align)
    }

    /// Peak per bar, shaped for display like `Waveform.envelope`.
    static func bars(_ env: [Float], count: Int) -> [Float] {
        let peaks = Waveform.resample(env, to: count)
        let top = peaks.max() ?? 0
        return peaks.map { top > 0 ? min(1, pow($0 / top, 0.7)) : 0 }
    }

    /// Writes a 16 kHz mono working copy of `src` to `dest` and returns its 100 Hz envelope and duration.
    static func prepareTrack(_ src: URL, to dest: URL) throws -> (envelope: [Float], duration: Double) {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let stream = try PCMStream(url: src, sampleRate: workRate)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: workRate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        var env: [Float] = []
        var frames = 0
        do {
            let out = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            while !stream.finished {
                try Task.checkCancellation()
                let block = stream.read(Int(workRate) * 10)
                guard !block.isEmpty else { break }
                env += MultitrackMath.envelope(block, hop: hop)
                try out.write(from: buffer(block, format: out.processingFormat))
                frames += block.count
            }
        }
        guard frames > 0 else { throw err("“\(src.lastPathComponent)” has no audio Verbose can read.") }
        return (env, Double(frames) / workRate)
    }

    /// The 100 Hz envelope of a working copy.
    static func envelope(of url: URL) throws -> [Float] {
        let stream = try PCMStream(url: url, sampleRate: workRate)
        var env: [Float] = []
        while !stream.finished {
            try Task.checkCancellation()
            env += MultitrackMath.envelope(stream.read(Int(workRate) * 10), hop: hop)
        }
        return env
    }

    /// Mixes the original files into one mono AAC file for playback and export, each starting at its place on
    /// the timeline (`starts`, seconds, earliest 0). A gentle limiter keeps crosstalk from clipping.
    static func mix(_ sources: [URL], starts: [Double], to dest: URL, progress: (Double) -> Void = { _ in }) throws -> Double {
        let accesses = sources.map { $0.startAccessingSecurityScopedResource() }
        defer { for (u, a) in zip(sources, accesses) where a { u.stopAccessingSecurityScopedResource() } }
        let streams = try sources.map { try PCMStream(url: $0, sampleRate: mixRate) }
        let startFrames = starts.map { Int(($0 * mixRate).rounded()) }
        let lengths = streams.map { Int($0.duration * mixRate) }
        let total = zip(startFrames, lengths).map { $0 + $1 }.max() ?? 0
        guard total > 0 else { throw err("The tracks have no audio to mix.") }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: mixRate, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 128_000]
        let block = Int(mixRate) * 2
        var written = 0
        do {
            let out = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            var pos = 0
            while pos < total {
                try Task.checkCancellation()
                let n = min(block, total - pos)
                var acc = [Float](repeating: 0, count: n)
                for (i, s) in streams.enumerated() where pos + n > startFrames[i] && !s.finished {
                    let skip = max(0, startFrames[i] - pos)
                    let samples = s.read(n - skip)
                    for k in 0..<samples.count { acc[skip + k] += samples[k] }
                }
                for k in 0..<n { acc[k] = limit(acc[k]) }
                try out.write(from: buffer(acc, format: out.processingFormat))
                pos += n; written += n
                progress(Double(pos) / Double(total))
            }
        }
        return Double(written) / mixRate
    }

    /// Unity below 0.8, then a soft knee that never passes 1.
    static func limit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.8 else { return x }
        let y = 0.8 + 0.2 * Float(tanh(Double((a - 0.8) / 0.2)))
        return x < 0 ? -y : y
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let ch = buf.floatChannelData else { throw err("Couldn't write the audio.") }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for c in 0..<Int(format.channelCount) { ch[c].update(from: base, count: samples.count) }
        }
        return buf
    }

    /// Everything a multi-track transcript needs before it can join the queue.
    struct Prepared {
        /// Seconds each track starts after track 1.
        var offsets: [Double]
        var durations: [Double]
        var mixDuration: Double
        var wave: [Float]
    }

    /// Working copies into `folder` (as `fileNames`), offsets (found by sound when `align`, unless already known),
    /// and the mix at `mixDest`.
    static func prepare(sources: [URL], fileNames: [String], folder: URL, align: Bool, knownOffsets: [Double?],
                        mixDest: URL, stage: (String) -> Void) throws -> Prepared {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let n = sources.count
        var envelopes: [[Float]] = [], durations: [Double] = []
        for (i, src) in sources.enumerated() {
            stage("Preparing track \(i + 1) of \(n)")
            let r = try prepareTrack(src, to: folder.appendingPathComponent(fileNames[i]))
            envelopes.append(r.envelope); durations.append(r.duration)
        }
        var offsets = [Double](repeating: 0, count: n)
        if align {
            stage("Lining up tracks")
            let found = MultitrackMath.offsets(envelopes: envelopes)
            for i in 1..<max(1, n) { offsets[i] = (i < knownOffsets.count ? knownOffsets[i] : nil) ?? found[i] }
        }
        try Task.checkCancellation()
        let gate = ProgressGate()
        let mixDuration = try mix(sources, starts: MultitrackMath.timeline(offsets), to: mixDest) { f in
            let label = "Mixing tracks \(Int(f * 100))%"
            if gate.shouldPublish(label) { stage(label) }
        }
        let wave = Waveform.envelope(of: mixDest)
        return Prepared(offsets: offsets, durations: durations, mixDuration: mixDuration, wave: wave)
    }
}

/// Transcribes each track of a multi-track transcript on its own, then weaves them together. Shared queue code
/// (TranscriptionCoordinator) runs it off the main thread.
enum MultitrackJob {
    /// The working copies are all still on this device, so the tracks can be transcribed one by one.
    static func canRun(_ t: Transcript) -> Bool {
        guard let mt = t.multitrack, mt.tracks.count >= 2 else { return false }
        let folder = Paths.tracks(t.id)
        return mt.tracks.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
    }

    static func progressLabel(_ p: EngineProgress, track: Int, of n: Int) -> String {
        switch p {
        case .transcribing(let f): return "Track \(track + 1) of \(n) · " + (f.map { String(format: "%.0f%%", $0 * 100) } ?? "Transcribing")
        case .applyingDictionary: return "Track \(track + 1) of \(n) · Applying Dictionary"
        default: return p.label
        }
    }

    static func run(id: UUID, info: MultitrackInfo, engineId: String, model: String, dictionary: [DictionaryEntry], project: UUID?,
                    progress: @escaping @Sendable (String) -> Void) async throws -> JobOutcome {
        let folder = Paths.tracks(id)
        let n = info.tracks.count
        let starts = info.timeline
        var placed: [TrackSegment] = [], originals: [UUID: Segment] = [:]
        var corrections: [Correction] = [], envelopes: [[Float]] = []
        var engine = "", usedModel = model, language: String? = nil
        for (i, track) in info.tracks.enumerated() {
            try Task.checkCancellation()
            let url = folder.appendingPathComponent(track.fileName)
            progress(progressLabel(.transcribing(0), track: i, of: n))
            let out = try await TranscriptionJob.run(url: url, engineId: engineId, model: model, wantSpeakers: false, dictionary: dictionary,
                                                     project: project, needWave: false) { p in progress(progressLabel(p, track: i, of: n)) }
            try Task.checkCancellation()
            placed += MultitrackMath.place(out.fixed, track: i, offset: starts[i])
            for s in MultitrackMath.place(out.original, track: i, offset: starts[i]) { originals[s.segment.id] = s.segment }
            corrections += out.corrections
            engine = out.engine; usedModel = out.model
            if language == nil { language = out.language }
            if info.ignoreBleed { envelopes.append((try? MultitrackAudio.envelope(of: url)) ?? []) }
            Log.note("multitrack: track \(i + 1)/\(n) segments=\(out.fixed.count)")
        }
        progress("Weaving tracks together")
        let kept = info.ignoreBleed ? MultitrackMath.filterBleed(placed, envelopes: envelopes, offsets: starts) : placed
        let fixed = MultitrackMath.merge(kept)
        let ids = Set(fixed.map(\.id))
        let original = fixed.map { originals[$0.id] ?? $0 }
        Log.note("multitrack: merged \(placed.count) → \(fixed.count) segments")
        return JobOutcome(original: original, fixed: fixed, speakers: MultitrackMath.speakers(names: info.tracks.map(\.speaker)),
                          corrections: corrections.filter { ids.contains($0.segmentId) }, wave: [],
                          engine: engine, model: usedModel, language: language)
    }
}
