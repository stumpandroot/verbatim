import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// What happens to a file with more than one audio track (Settings › Speakers, iPhone Settings › Transcription).
enum AudioTracksPreference: String, CaseIterable, Identifiable {
    /// Every track mixed into one transcript (the default).
    case mix
    /// Each track transcribed on its own as a speaker, merged by time (the multi-track pipeline).
    case separate

    static let key = "import.audioTracks"
    static var current: AudioTracksPreference {
        AudioTracksPreference(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .mix
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mix: return "Mix all tracks"
        case .separate: return "Keep tracks as separate speakers"
        }
    }
}

/// Turns whatever someone drops or picks into an audio file Verbatim can transcribe.
enum MediaImport {
    static let audioExts: Set<String> = ["wav", "m4a", "mp3", "aif", "aiff", "caf", "flac", "aac", "ogg", "opus"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "3gp", "flv", "wmv", "asf", "ts", "mts", "m2ts", "vob", "ogv"]
    /// Audio-only formats AVFoundation can't play; the bundled FFmpeg reads them. Not in `audioExts`, so the
    /// multi-track sheet (which reads tracks with AVAudioFile) doesn't offer them.
    static let otherAudioExts: Set<String> = ["mka", "oga", "wma", "amr", "spx"]
    /// Containers AVFoundation can't read: these go straight to FFmpeg.
    static let ffmpegExts: Set<String> = ["mkv", "mka", "webm", "avi", "flv", "wmv", "wma", "asf", "ogg", "oga", "ogv", "opus", "ts", "mts", "m2ts", "vob"]

    /// The types the file pickers allow, beyond `.audio` and `.movie`: the formats FFmpeg reads, by extension.
    static var pickerTypes: [UTType] {
        var types: [UTType] = [.audio, .movie, .audiovisualContent, .mpeg4Movie, .mp3, .wav, .aiff, .quickTimeMovie, .avi]
        if let m4a = UTType("public.mpeg-4-audio") { types.append(m4a) }
        for id in ["org.matroska.mkv", "org.matroska.mka", "org.webmproject.webm", "com.microsoft.windows-media-wmv",
                   "com.microsoft.windows-media-wma", "com.microsoft.advanced-systems-format", "org.xiph.ogg",
                   "org.xiph.ogg-audio", "org.xiph.ogg-video", "org.xiph.opus", "com.adobe.flash.video", "public.mpeg-2-transport-stream"] {
            if let t = UTType(id) { types.append(t) }
        }
        for e in ffmpegExts.union(otherAudioExts).sorted() {
            if let t = UTType(filenameExtension: e), !types.contains(t) { types.append(t) }
        }
        return types
    }

    /// Files as given, plus every media file inside any folder (recursively), in name order.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
                out += items.filter { isMedia($0) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if isMedia(u) {
                out.append(u)
            }
        }
        return out
    }

    static func isMedia(_ u: URL) -> Bool {
        let e = u.pathExtension.lowercased()
        if audioExts.contains(e) || videoExts.contains(e) || otherAudioExts.contains(e) { return true }
        if let t = UTType(filenameExtension: e) { return t.conforms(to: .audio) || t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) }
        return false
    }

    struct Prepared {
        let url: URL
        let duration: Double
        /// Two or more when the file's audio tracks were kept apart (`AudioTracksPreference.separate`): 16 kHz mono
        /// WAVs in the folder passed to `prepare`, ready for the multi-track pipeline (MultitrackJob). Empty otherwise.
        var tracks: [AudioTrack] = []
        /// The mix's waveform, when there are tracks (a multi-track job doesn't make one).
        var wave: [Float] = []

        /// The multi-track record for a transcript, or nil for a plain import.
        var multitrack: MultitrackInfo? {
            tracks.count >= 2 ? MultitrackInfo(tracks: tracks, ignoreBleed: false, alignAutomatically: false) : nil
        }
    }

    /// Audio files AVFoundation reads are copied as they are, and anything with video has its audio exported to
    /// M4A (no video kept), as before. A file with several audio tracks gets every track mixed, or, with
    /// `separateTracksInto` (the multi-track working folder, `Paths.tracks(id)`), each track as its own WAV there
    /// too. Formats AVFoundation can't read (MKV, WebM, AVI, FLV, WMV, Ogg), or a file it can't find audio in, go
    /// to the bundled FFmpeg. `stage` gets progress text for long files.
    static func prepare(_ src: URL, into m4aDest: URL, separateTracksInto folder: URL? = nil,
                        stage: (@Sendable (String) -> Void)? = nil) async throws -> Prepared {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let ext = src.pathExtension.lowercased()
        // Every path below may delete its output when it fails, so it must never be a file that's already there.
        for e in Set([m4aDest.pathExtension, ext, "wav"]) where !e.isEmpty {
            let u = m4aDest.deletingPathExtension().appendingPathExtension(e)
            if FileManager.default.fileExists(atPath: u.path) { throw AudioNaming.AlreadyExists(url: u) }
        }
        if ffmpegExts.contains(ext) {
            return try await viaFFmpeg(src, into: m4aDest, separateTracksInto: folder, stage: stage)
        }
        let asset = AVURLAsset(url: src)
        let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else {
            Log.note("import: AVFoundation found no audio in a .\(ext) file; trying FFmpeg")
            return try await viaFFmpeg(src, into: m4aDest, separateTracksInto: folder, stage: stage)
        }
        if audioTracks.count > 1 {
            do {
                return try await severalTracks(src, asset: asset, tracks: audioTracks, into: m4aDest, separateTracksInto: folder, stage: stage)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.note("import: AVFoundation couldn't mix \(audioTracks.count) tracks (\(error.localizedDescription)); trying FFmpeg")
                return try await viaFFmpeg(src, into: m4aDest, separateTracksInto: folder, stage: stage)
            }
        }
        let dest: URL
        if !hasVideo && audioExts.contains(ext) {
            dest = m4aDest.deletingPathExtension().appendingPathExtension(ext)
            try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: src, to: dest) }.value
        } else {
            dest = m4aDest
            do {
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw err("Couldn't read the audio in “\(src.lastPathComponent)”.") }
                session.outputURL = dest
                session.outputFileType = .m4a
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    session.exportAsynchronously {
                        switch session.status {
                        case .completed: c.resume()
                        default: c.resume(throwing: session.error ?? err("Couldn't extract the audio from “\(src.lastPathComponent)”."))
                        }
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                try Task.checkCancellation()
                Log.note("import: AVFoundation export failed for a .\(ext) file (\(error.localizedDescription)); trying FFmpeg")
                return try await viaFFmpeg(src, into: m4aDest, separateTracksInto: folder, stage: stage)
            }
        }
        let d = (try? await AVURLAsset(url: dest).load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard d > 0 else {
            try? FileManager.default.removeItem(at: dest)
            Log.note("import: AVFoundation's copy of a .\(ext) file has no duration; trying FFmpeg")
            return try await viaFFmpeg(src, into: m4aDest, separateTracksInto: folder, stage: stage)
        }
        return Prepared(url: dest, duration: d)
    }

    // MARK: FFmpeg

    /// Every audio track through FFmpeg in one pass: the mix to M4A (16 kHz mono), and each track to a WAV when
    /// they're kept apart.
    private static func viaFFmpeg(_ src: URL, into m4aDest: URL, separateTracksInto folder: URL?,
                                  stage: (@Sendable (String) -> Void)?) async throws -> Prepared {
        try await offMain {
            let probe = try FFmpegAudio.probe(src)
            let separate = folder != nil && probe.tracks.count >= 2
            let labels = MediaImport.trackLabels(probe.tracks.map { (title: $0.title, language: $0.language) })
            let rate = Int(MultitrackAudio.workRate)
            let mix = try MonoAudioWriter(m4a: m4aDest, sampleRate: rate)
            var writers: [WAVWriter] = []
            do {
                if separate, let folder {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    writers = try probe.tracks.indices.map { try WAVWriter(url: folder.appendingPathComponent("track-\($0 + 1).wav"), sampleRate: rate) }
                }
                let gate = ProgressGate()
                let trackWriters = writers
                let long = probe.duration > 120
                try FFmpegAudio.decode(src, sampleRate: rate, separate: separate, progress: { f in
                    guard let stage, long else { return }
                    let label = "Reading the audio \(Int(f * 100))%"
                    if gate.shouldPublish(label) { stage(label) }
                }) { track, samples in
                    if track == FFmpegAudio.mixTrack { try mix.write(samples) } else if track < trackWriters.count { try trackWriters[track].write(samples) }
                }
                try mix.finish()
                for w in writers { try w.finish() }
            } catch {
                mix.abandon()
                for w in writers { w.abandon() }
                throw error
            }
            guard mix.frames > 0 else { mix.abandon(); throw MediaImport.err("“\(src.lastPathComponent)” has no audio Verbatim can read.") }
            var out = Prepared(url: mix.url, duration: mix.duration)
            if separate {
                out.tracks = writers.enumerated().map { i, w in
                    AudioTrack(fileName: w.url.lastPathComponent, sourceName: src.lastPathComponent, speaker: labels[i],
                               duration: Double(w.frames) / Double(rate))
                }
                out.wave = Waveform.envelope(of: mix.url)
            }
            Log.note("import: FFmpeg read \(probe.tracks.count) track(s), \(String(format: "%.1f", out.duration)) s\(separate ? ", kept apart" : "")")
            return out
        }
    }

    // MARK: Several tracks with AVFoundation

    /// A file AVFoundation reads with two or more audio tracks: every track mixed (AVAssetReaderAudioMixOutput),
    /// plus each track on its own when they're kept apart.
    private static func severalTracks(_ src: URL, asset: AVURLAsset, tracks: [AVAssetTrack], into m4aDest: URL,
                                      separateTracksInto folder: URL?, stage: (@Sendable (String) -> Void)?) async throws -> Prepared {
        var described: [(title: String, language: String)] = []
        for t in tracks { described.append(await describe(t)) }
        let labels = trackLabels(described)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        return try await offMain {
            let rate = MultitrackAudio.workRate
            var trackFiles: [AudioTrack] = []
            if let folder {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (i, t) in tracks.enumerated() {
                    stage?("Preparing track \(i + 1) of \(tracks.count)")
                    let url = folder.appendingPathComponent("track-\(i + 1).wav")
                    // A failure removes the tracks this pass already wrote, so the FFmpeg fallback starts clean.
                    let made = trackFiles.map { folder.appendingPathComponent($0.fileName) }
                    let w: WAVWriter
                    do { w = try WAVWriter(url: url, sampleRate: Int(rate)) } catch { made.forEach { try? FileManager.default.removeItem(at: $0) }; throw error }
                    do {
                        try MediaImport.readPCM(asset, output: AVAssetReaderTrackOutput(track: t, outputSettings: MediaImport.pcmSettings(rate))) { try w.write($0) }
                        try w.finish()
                    } catch {
                        w.abandon()
                        made.forEach { try? FileManager.default.removeItem(at: $0) }
                        throw error
                    }
                    trackFiles.append(AudioTrack(fileName: url.lastPathComponent, sourceName: src.lastPathComponent, speaker: labels[i],
                                                 duration: Double(w.frames) / rate))
                }
                stage?("Mixing tracks")
            }
            let mix = try MonoAudioWriter(m4a: m4aDest, sampleRate: Int(rate))
            do {
                let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: MediaImport.pcmSettings(rate))
                try MediaImport.readPCM(asset, output: output) { samples in
                    // The mix output sums tracks; keep loud passages from clipping, like the multi-track mix.
                    var limited = Array(samples)
                    for k in limited.indices { limited[k] = MultitrackAudio.limit(limited[k]) }
                    try limited.withUnsafeBufferPointer { try mix.write($0) }
                }
                try mix.finish()
            } catch {
                mix.abandon()
                if let folder { try? FileManager.default.removeItem(at: folder) }
                throw error
            }
            guard mix.frames > 0 else { mix.abandon(); throw MediaImport.err("“\(src.lastPathComponent)” has no audio Verbatim can read.") }
            var out = Prepared(url: mix.url, duration: mix.duration > 0 ? mix.duration : duration)
            if trackFiles.count >= 2 {
                out.tracks = trackFiles
                out.wave = Waveform.envelope(of: mix.url)
            }
            Log.note("import: mixed \(tracks.count) audio tracks with AVFoundation\(trackFiles.count >= 2 ? ", kept apart" : "")")
            return out
        }
    }

    private static func pcmSettings(_ rate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
    }

    /// Reads `output` to the end as mono float samples, a buffer at a time.
    private static func readPCM(_ asset: AVAsset, output: AVAssetReaderOutput, _ sink: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw err("Couldn't read the audio tracks.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? err("Couldn't read the audio tracks.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var scratch: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            let status = scratch.withUnsafeMutableBytes { p in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: p.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            try scratch.withUnsafeBufferPointer { try sink(UnsafeBufferPointer(rebasing: $0[0..<count])) }
        }
        if reader.status == .failed { throw reader.error ?? err("Couldn't read the audio tracks.") }
    }

    /// A track's title and language, from its metadata.
    private static func describe(_ track: AVAssetTrack) async -> (title: String, language: String) {
        var title = ""
        var items = (try? await track.load(.commonMetadata)) ?? []
        items += (try? await track.load(.metadata)) ?? []
        for item in items where item.commonKey == .commonKeyTitle || item.identifier == .quickTimeUserDataTrackName
            || item.identifier == .quickTimeMetadataTitle {
            if let s = try? await item.load(.stringValue), !s.trimmingCharacters(in: .whitespaces).isEmpty { title = s; break }
        }
        var language = ""
        if let tag = try? await track.load(.extendedLanguageTag), !tag.isEmpty {
            language = tag
        } else if let code = try? await track.load(.languageCode), !code.isEmpty {
            language = code
        }
        return (title, language)
    }

    // MARK: Track names

    /// Speaker names for a file's tracks: the title ("Commentary"), else the language ("English"), else "Track 2".
    /// Repeats get a number ("English 2").
    static func trackLabels(_ tracks: [(title: String, language: String)]) -> [String] {
        var names = tracks.enumerated().map { i, t -> String in
            let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
            if let lang = languageName(t.language) { return lang }
            return "Track \(i + 1)"
        }
        var seen: [String: Int] = [:]
        for name in names { seen[name, default: 0] += 1 }
        var counter: [String: Int] = [:]
        for i in names.indices where (seen[names[i]] ?? 0) > 1 {
            counter[names[i], default: 0] += 1
            let n = counter[names[i]]!
            if n > 1 { names[i] += " \(n)" }
        }
        return names
    }

    /// "eng", "en", or "en-US" as a language name in the person's language; nil for none or "und".
    static func languageName(_ code: String) -> String? {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, c.lowercased() != "und", c.lowercased() != "mul", c.lowercased() != "zxx" else { return nil }
        // ISO 639-2 (Matroska's usual form): Locale doesn't always know these, so the common ones first.
        let iso639_2: [String: String] = ["eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "ita": "it",
                                          "por": "pt", "jpn": "ja", "zho": "zh", "chi": "zh", "kor": "ko", "rus": "ru", "nld": "nl",
                                          "dut": "nl", "ara": "ar", "hin": "hi", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi",
                                          "pol": "pl", "tur": "tr", "ukr": "uk", "heb": "he", "ell": "el", "gre": "el", "ces": "cs",
                                          "cze": "cs", "hun": "hu", "ron": "ro", "rum": "ro", "vie": "vi", "tha": "th", "ind": "id"]
        let base = c.split(separator: "-").first.map(String.init)?.lowercased() ?? c.lowercased()
        let short = iso639_2[base] ?? base
        let locale = Locale.current
        if let name = locale.localizedString(forLanguageCode: short), name.lowercased() != short {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return nil
    }

    // MARK: Helpers

    /// Runs `work` as a child task (it inherits cancellation) off the main thread.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .utility) { try work() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "Verbatim", code: 3, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// Gathers file URLs from several drag providers, then calls back once on the main thread.
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let done: ([URL]) -> Void
    init(expected: Int, done: @escaping ([URL]) -> Void) { remaining = expected; self.done = done }
    func add(_ u: URL?) {
        lock.lock()
        if let u { urls.append(u) }
        remaining -= 1
        let finished = remaining == 0
        let all = urls
        lock.unlock()
        if finished { DispatchQueue.main.async { self.done(all) } }
    }
}
