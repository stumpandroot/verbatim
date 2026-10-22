import Foundation
import FluidAudio

/// Vector helpers for speaker embeddings.
enum VoiceMath {
    static func norm(_ v: [Float]) -> Float { sqrt(v.reduce(0) { $0 + $1 * $1 }) }

    static func normalized(_ v: [Float]) -> [Float]? {
        let n = norm(v)
        guard n > 1e-6, n.isFinite else { return nil }
        return v.map { $0 / n }
    }

    /// Cosine similarity in -1…1; nil when the sizes differ or a vector is empty or zero.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 1e-12, nb > 1e-12 else { return nil }
        let c = dot / (na.squareRoot() * nb.squareRoot())
        return c.isFinite ? c : nil
    }

    /// The normalized mean of normalized vectors (all the same size), optionally weighted.
    static func mean(_ vectors: [[Float]], weights: [Float]? = nil) -> [Float]? {
        guard let dim = vectors.first?.count, dim > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        var total: Float = 0
        for (i, v) in vectors.enumerated() where v.count == dim {
            guard let u = normalized(v) else { continue }
            let w = weights.map { i < $0.count ? $0[i] : 1 } ?? 1
            guard w > 0 else { continue }
            for j in 0..<dim { sum[j] += u[j] * w }
            total += w
        }
        guard total > 0 else { return nil }
        return normalized(sum)
    }
}

/// Your voice, so Verbatim can tell you apart from other people: labels your lines "You" in transcripts and, with
/// Settings › "Only keep my voice in dictation", drops words other people say during a dictation.
///
/// Enrollment runs FluidAudio's offline diarizer (the same Pyannote segmentation and WeSpeaker embedding model that
/// finds speakers in transcripts) over a few clips of you reading, takes the main voice's 256-dimension embeddings,
/// and keeps their average. Comparisons are cosine similarity against that average, so the profile and every
/// transcript's speakers live in the same embedding space.
///
/// Stored on this device only (Application Support, excluded from backups), never in iCloud, even with sync on: a
/// voiceprint is biometric, and each device enrolls on its own microphone. `reset()` deletes it.
///
/// Thread-safe; enrollment and comparison never run on the main thread's time (enroll is async and detached).
enum VoiceProfile {
    /// What's saved.
    struct Stored: Codable, Equatable {
        var version = 1
        /// The averaged, normalized embedding.
        var embedding: [Float]
        /// Seconds of your speech behind it, across every enrollment.
        var seconds: Double
        /// How alike the enrollment chunks were (mean cosine to the average), 0…1.
        var consistency: Float
        var chunks: Int
        var updatedAt = Date()
        /// The embedding model, so a future model change can ask you to enroll again.
        var model = VoiceProfile.modelID
    }

    /// The outcome of an enrollment, for the enrollment screen.
    struct Enrollment: Sendable, Equatable {
        enum Hint: String, Sendable { case good, readMore, noSpeech, otherVoices }
        /// 0…1. At `goodQuality` or above, with `minSeconds` of speech, the profile is ready to use.
        var quality: Float
        var seconds: Double
        var needsMore: Bool
        var hint: Hint
        /// A sentence for people: "Read a little more", and why.
        var message: String
        /// Whether the profile is now saved and in use.
        var isEnrolled: Bool
    }

    enum Failure: LocalizedError {
        case unsupported, noSpeech, silent, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unsupported:
                #if os(macOS)
                return "Recognizing your voice needs macOS 15 or later."
                #else
                return "Recognizing your voice isn't available on this device."
                #endif
            case .noSpeech: return "Verbose didn't hear a voice in that recording. Read a little more, close to the microphone."
            case .silent: return "Verbose heard only silence. Check that your microphone isn't muted, then try again."
            case .unreadable(let name): return "Verbose couldn't read \(name)."
            }
        }
    }

    static let modelID = "fluidaudio-offline-wespeaker-256"
    /// Speech that makes a reliable profile, and the least that counts as enrolled.
    static let targetSeconds: Double = 30
    static let minSeconds: Double = 15
    static let goodQuality: Float = 0.7

    /// Settings › "Only keep my voice in dictation". Off by default, and off in effect until you've enrolled.
    static let dictationFilterKey = "voice.dictationOnlyMe"
    static var dictationFilterEnabled: Bool { UserDefaults.standard.bool(forKey: dictationFilterKey) && isEnrolled }
    /// Label your speaker "You" in new transcripts (no switch yet). On by default; does nothing until you enroll.
    static let labelYouKey = "voice.labelYou"
    static var labelYouEnabled: Bool { (UserDefaults.standard.object(forKey: labelYouKey) as? Bool ?? true) && isEnrolled }
    /// The cosine similarity at which a voice counts as yours. Not yet tuned on real recordings; overridable with
    /// the `voice.threshold` default.
    static let defaultThreshold: Float = 0.5
    static var threshold: Float {
        let v = UserDefaults.standard.float(forKey: "voice.threshold")
        return v > 0 && v < 1 ? v : defaultThreshold
    }

    /// The name given to your speaker in transcripts.
    static let youName = "You"

    // MARK: Storage

    static var fileURL: URL { Paths.local.appendingPathComponent("voice", isDirectory: true).appendingPathComponent("voice-profile.json") }

    private static let lock = NSLock()
    private static var cache: Stored??

    /// The saved profile, read once and cached.
    static var stored: Stored? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let s = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        let valid = s.flatMap { $0.model == modelID && !$0.embedding.isEmpty ? $0 : nil }
        cache = .some(valid)
        return valid
    }

    static var isEnrolled: Bool {
        guard let s = stored else { return false }
        return s.seconds >= minSeconds
    }

    /// The saved profile's quality, 0…1; nil before enrollment.
    static var currentQuality: Float? { stored.map { quality(seconds: $0.seconds, consistency: $0.consistency) } }

    /// Deletes the profile from this device.
    static func reset() {
        lock.lock()
        try? FileManager.default.removeItem(at: fileURL)
        cache = .some(nil)
        lock.unlock()
        Log.note("voice profile: reset")
    }

    private static func save(_ s: Stored) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(s)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        lock.lock(); cache = .some(s); lock.unlock()
    }

    // MARK: Scoring

    /// Cosine similarity between a voice embedding and yours (-1…1, higher is more alike); nil before enrollment or
    /// when the embedding comes from a different model (wrong size).
    static func score(_ embedding: [Float]) -> Float? {
        guard isEnrolled, let s = stored else { return nil }
        return VoiceMath.cosine(embedding, s.embedding)
    }

    /// Whether a voice embedding (from `FluidDiarizer`, 256 values) sounds like you.
    static func isUser(_ embedding: [Float]) -> Bool {
        guard let s = score(embedding) else { return false }
        return s >= threshold
    }

    /// Which of a recording's speakers is you: the best match at or above the threshold, nil when none is.
    static func userSpeaker(in embeddings: [String: [Float]]) -> String? {
        guard isEnrolled else { return nil }
        let scored = embeddings.compactMap { id, e in score(e).map { (id, $0) } }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= threshold else { return nil }
        return best.0
    }

    // MARK: Enrollment

    static func quality(seconds: Double, consistency: Float) -> Float {
        let coverage = Float(min(1, seconds / targetSeconds))
        // WeSpeaker chunks of one clean voice usually sit well above 0.8 to their mean; noise and other voices pull it down.
        let alike = max(0, min(1, (consistency - 0.55) / 0.3))
        return (0.6 * coverage + 0.4 * alike * min(1, coverage * 2)).rounded(toPlaces: 2)
    }

    /// Enrolls from recordings of you reading (any format AVFoundation reads). Adds to the existing profile unless
    /// `replacing`. Runs off the main thread; takes about a second per minute of audio once the diarizer models are
    /// downloaded (the first run downloads them). Always saves what it heard; the profile is used once it holds
    /// `minSeconds` of your voice.
    static func enroll(from urls: [URL], replacing: Bool = false) async throws -> Enrollment {
        let work = Task.detached(priority: .userInitiated) {
            try await VoiceProfile.enrollNow(urls, replacing: replacing)
        }
        // Cancelling the enrollment (closing the sheet) cancels the work too, so nothing is saved after you leave.
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Samples the diarizer can use: nothing that isn't finite, at least a second long (padded with silence), or a
    /// reason not to run it at all (no audio, or nothing but silence).
    static func prepareSamples(_ raw: [Float]) -> Result<[Float], Failure> {
        guard !raw.isEmpty else { return .failure(.noSpeech) }
        var peak: Float = 0
        var samples = raw
        for i in samples.indices {
            let v = samples[i]
            if !v.isFinite { samples[i] = 0; continue }
            peak = max(peak, abs(v))
        }
        // About -66 dBFS: a muted mic, or one that's asleep. A quiet room is well above it.
        guard peak >= 0.0005 else { return .failure(.silent) }
        // The diarizer needs about a second of audio; pad short clips with silence.
        if samples.count < 16_000 { samples += [Float](repeating: 0, count: 16_000 - samples.count) }
        return .success(samples)
    }

    private static func enrollNow(_ urls: [URL], replacing: Bool) async throws -> Enrollment {
        guard FluidDiarizer.isSupported else { throw Failure.unsupported }
        var chunks: [[Float]] = []
        var seconds: Double = 0
        var otherVoices = false
        var silentClips = 0
        for url in urls {
            try Task.checkCancellation()
            let raw: [Float]
            do { raw = try AudioConverter().resampleAudioFile(url) } catch {
                Log.noteNow("voice profile: couldn't read the recording (\(String(describing: type(of: error))))")
                throw Failure.unreadable(url.lastPathComponent)
            }
            let padded: [Float]
            switch prepareSamples(raw) {
            case .success(let s): padded = s
            case .failure(let reason):
                Log.noteNow("voice profile: skipped a clip of \(raw.count) samples (\(reason))")
                if case .silent = reason { silentClips += 1 }
                continue
            }
            try Task.checkCancellation()
            Log.noteNow("voice profile: embedding start, \(raw.count) samples (\(String(format: "%.1f", Double(raw.count) / 16_000)) s)")
            let out: DiarizationOutput
            do { out = try await FluidDiarizer.shared.diarize(samples: padded) } catch {
                Log.noteNow("voice profile: a clip had no usable speech (\(String(describing: type(of: error))))")
                continue
            }
            Log.noteNow("voice profile: embedding end, \(out.turns.count) turn(s), \(out.chunks.values.reduce(0) { $0 + $1.count }) chunk(s)")
            let time = out.seconds
            // The main voice in each clip is you; anyone else talking (a TV, a room) is left out and noted.
            guard let main = time.max(by: { $0.value < $1.value })?.key, let mine = out.chunks[main], !mine.isEmpty else { continue }
            let total = time.values.reduce(0, +)
            if total > 0, (total - (time[main] ?? 0)) / total > 0.2 { otherVoices = true }
            chunks += mine
            seconds += time[main] ?? 0
        }
        try Task.checkCancellation()
        guard let mean = VoiceMath.mean(chunks) else {
            if silentClips == urls.count, !urls.isEmpty { throw Failure.silent }
            guard !replacing, let old = stored else { throw Failure.noSpeech }
            return result(for: old, otherVoices: false, heardNothing: true)
        }
        let consistency = chunks.isEmpty ? 0 : chunks.compactMap { VoiceMath.cosine($0, mean) }.reduce(0, +) / Float(chunks.count)
        var next = Stored(embedding: mean, seconds: seconds, consistency: consistency, chunks: chunks.count)
        if !replacing, let old = stored {
            // Weighted by speech time, so a short top-up nudges the profile instead of replacing it.
            if let combined = VoiceMath.mean([old.embedding, mean], weights: [Float(old.seconds), Float(seconds)]) {
                let total = old.seconds + seconds
                next = Stored(embedding: combined, seconds: total,
                              consistency: Float((Double(old.consistency) * old.seconds + Double(consistency) * seconds) / max(total, 1)),
                              chunks: old.chunks + chunks.count)
            }
        }
        // Saved even when short, so "Read a little more" adds to it; it's used only from `minSeconds` (`isEnrolled`).
        try Task.checkCancellation()
        try save(next)
        Log.note("voice profile: \(Int(next.seconds)) s, \(next.chunks) chunks, quality \(quality(seconds: next.seconds, consistency: next.consistency))")
        return result(for: next, otherVoices: otherVoices, heardNothing: false)
    }

    private static func result(for s: Stored, otherVoices: Bool, heardNothing: Bool) -> Enrollment {
        let q = quality(seconds: s.seconds, consistency: s.consistency)
        let enough = s.seconds >= minSeconds
        let needsMore = !enough || q < goodQuality
        let hint: Enrollment.Hint
        let message: String
        if heardNothing {
            hint = .noSpeech; message = Failure.noSpeech.errorDescription ?? ""
        } else if otherVoices && needsMore {
            hint = .otherVoices; message = "Verbose heard another voice. Read a little more somewhere quieter."
        } else if needsMore {
            hint = .readMore; message = "Read a little more so Verbose knows your voice."
        } else {
            hint = .good; message = "Verbose knows your voice."
        }
        return Enrollment(quality: q, seconds: s.seconds, needsMore: needsMore, hint: hint, message: message,
                          isEnrolled: enough && isEnrolled)
    }

    // MARK: Using it

    /// After speaker detection: names the speaker who sounds like you "You", unless the person already renamed them.
    /// `embeddings` is keyed by the diarizer's labels; `map` turns those into the transcript's speaker ids ("S1").
    static func labelYou(_ speakers: inout [Speaker], embeddings: [String: [Float]], map: [String: String]) {
        guard labelYouEnabled, let raw = userSpeaker(in: embeddings), let id = map[raw],
              let i = speakers.firstIndex(where: { $0.id == id }) else { return }
        // Only Verbatim's own placeholder names ("Speaker 2") are replaced.
        guard speakers[i].name.isEmpty || speakers[i].name.hasPrefix("Speaker ") else { return }
        speakers[i].name = youName
    }

    /// Dictation: when another voice is heard, keeps only the words you said. Returns nil to keep the dictation as it
    /// is: the filter is off, nobody else spoke, none of the voices sounds like you, or nothing would be left. Fails
    /// open: any problem keeps every word.
    static func filterDictation(url: URL, segments: [Segment]) async -> [Segment]? {
        guard dictationFilterEnabled, FluidDiarizer.isSupported, !segments.isEmpty else { return nil }
        // Too short to tell voices apart.
        guard let end = segments.map(\.end).max(), end >= 2 else { return nil }
        do {
            let out = try await FluidDiarizer.shared.diarizeDetailed(url: url, progress: { _ in })
            return keepUserWords(segments, turns: out.turns, embeddings: out.embeddings)
        } catch {
            Log.note("voice filter: kept every word (\(String(describing: type(of: error))))")
            return nil
        }
    }

    /// The pure part of `filterDictation`: drops words (or, without word timings, whole lines) that fall mostly in
    /// turns of voices that aren't yours. Words in no turn are kept.
    static func keepUserWords(_ segments: [Segment], turns: [(speaker: String, start: Double, end: Double)],
                              embeddings: [String: [Float]]) -> [Segment]? {
        let voices = Set(turns.map(\.speaker))
        guard voices.count >= 2 else { return nil }
        var mine = Set<String>(), others = Set<String>()
        for v in voices {
            if let e = embeddings[v], isUser(e) { mine.insert(v) } else { others.insert(v) }
        }
        guard !mine.isEmpty, !others.isEmpty else { return nil }

        func owner(_ start: Double, _ end: Double) -> String? {
            var overlap: [String: Double] = [:]
            for t in turns {
                let o = min(end, t.end) - max(start, t.start)
                if o > 0 { overlap[t.speaker, default: 0] += o }
            }
            return overlap.max(by: { $0.value < $1.value })?.key
        }

        let out: [Segment]
        var dropped = 0
        let timed = segments.allSatisfy { !($0.words ?? []).isEmpty }
        if timed {
            let words = segments.flatMap { $0.words ?? [] }
            let kept = words.filter { w in
                guard let o = owner(w.start, max(w.end, w.start + 0.05)) else { return true }
                return !others.contains(o)
            }
            dropped = words.count - kept.count
            guard dropped > 0 else { return nil }
            out = Engines.segments(fromWords: kept)
        } else {
            let kept = segments.filter { s in
                guard let o = owner(s.start, max(s.end, s.start + 0.05)) else { return true }
                return !others.contains(o)
            }
            dropped = segments.count - kept.count
            guard dropped > 0 else { return nil }
            out = kept
        }
        guard !out.isEmpty else { return nil }
        Log.note("voice filter: dropped \(dropped) \(timed ? "word" : "line")(s) from other voices")
        return out
    }
}

private extension Float {
    func rounded(toPlaces p: Int) -> Float {
        let m = Float(pow(10.0, Double(p)))
        return (self * m).rounded() / m
    }
}
