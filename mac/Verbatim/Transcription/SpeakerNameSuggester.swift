import Foundation

/// Runs speaker name suggestions (SpeakerNames) for a finished transcript with two or more speakers: what people say,
/// the link's title and channel, names you've used before, Apple's on-device model where it can run, and voices
/// you've named. Saves them as suggestions on the transcript; nothing is renamed until you choose Use. Nothing leaves
/// the device.
@MainActor
enum SpeakerNameSuggester {
    /// Transcripts with suggestions under way, so a second finish doesn't start another run.
    private static var running: Set<UUID> = []

    /// After transcription and after the speaker pass. Dismissed and used suggestions stay as they are.
    static func runIfNeeded(_ id: UUID, store: Store) {
        guard !running.contains(id), let t = store.transcript(id), t.status == .ready, t.source != .dictation,
              t.speakers.count >= 2, t.speakers.contains(where: \.isPlaceholder), !t.segments.isEmpty else { return }
        let isLink = t.source == .link || t.link != nil
        let base = SpeakerNames.Input(segments: t.segments, speakers: t.speakers,
                                       title: isLink ? t.title : "", channel: isLink ? t.link?.channel : nil,
                                       pastNames: SpeakerNames.pastNames(store.live, excluding: id))
        let named = SpeakerVoices.enabled ? SpeakerVoices.named() : []
        let voices = SpeakerVoices.enabled ? SpeakerVoices.voices(for: id) : [:]
        let snapshot = t.segments
        running.insert(id)
        Task.detached(priority: .utility) {
            var input = base
            input.extra = SpeakerNames.voiceEvidence(voices: voices, named: named)
            input.extra += await modelEvidence(input)
            let found = SpeakerNames.suggest(input)
            await MainActor.run {
                running.remove(id)
                // The words changed since (transcribed again): that run suggests for its own speakers.
                guard let now = store.transcript(id), now.segments == snapshot else { return }
                // An empty list marks a transcript as checked, so opening it doesn't run this again.
                let merged = SpeakerNames.merge(existing: now.speakerSuggestions, new: found) ?? []
                if merged != now.speakerSuggestions { store.update(id) { $0.speakerSuggestions = merged } }
                Log.note("speaker names: \(found.count) suggested from \(Set(found.flatMap(\.sources)).sorted().joined(separator: ", "))")
            }
        }
    }

    /// A transcript opened that has never had suggestions (transcribed before this build): runs them once.
    static func openedIfNeeded(_ id: UUID, store: Store) {
        guard let t = store.transcript(id), t.speakerSuggestions == nil, t.status == .ready, t.stage == nil, t.pendingAppend == nil else { return }
        runIfNeeded(id, store: store)
    }

    /// Apple Intelligence's names, behind the same checks as titles and summaries, from the turn openings and
    /// closings only; names that aren't in the transcript or the link's details are dropped.
    nonisolated private static func modelEvidence(_ input: SpeakerNames.Input) async -> [SpeakerNames.Evidence] {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), case .ready = Polish.status {
            let excerpt = SpeakerNames.modelExcerpt(input.segments, speakers: input.speakers)
            let prompt = SpeakerNames.modelPrompt(excerpt: excerpt, title: input.title, channel: input.channel)
            guard let answer = try? await OnDeviceText.respond(instructions: SpeakerNames.modelInstructions, prompt: prompt, temperature: 0),
                  !OnDeviceTextRefusal.isRefusal(answer) else { return [] }
            return SpeakerNames.modelEvidence(answer, speakers: input.speakers, segments: input.segments, title: input.title, channel: input.channel)
        }
        #endif
        return []
    }
}

/// Voices you've named, so a new transcript can suggest the name when a speaker sounds like one of them
/// (Settings › "Recognize voices I've named", on by default). Each transcript's speaker embeddings from FluidDiarizer
/// are kept until you name a speaker; naming one adds its voice to the named voices.
///
/// Stored on this device only (Application Support, excluded from backups), never in iCloud, even with sync on: a
/// voiceprint is biometric. `clear()` deletes it all.
enum SpeakerVoices {
    static let enabledKey = "voice.recognizeNamed"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    struct Named: Codable, Equatable {
        var name: String
        /// The normalized mean of every voice given this name.
        var embedding: [Float]
        var count: Int
        var updatedAt: Date
    }

    struct Recent: Codable, Equatable {
        var transcript: UUID
        /// Speaker id ("S1") → embedding.
        var voices: [String: [Float]]
        var at: Date
    }

    struct Saved: Codable, Equatable {
        var version = 1
        var model: String
        var named: [Named] = []
        var recent: [Recent] = []
    }

    /// Transcripts whose voices are kept for naming later; older ones drop off.
    static let recentLimit = 100

    static var fileURL: URL { Paths.local.appendingPathComponent("voice", isDirectory: true).appendingPathComponent("named-voices.json") }

    private static let lock = NSLock()
    private static var cache: Saved?
    private static let writer = DispatchQueue(label: "co.stumpandroot.verbatim.speaker-voices", qos: .utility)

    private static func load() -> Saved {
        if let c = cache { return c }
        let s = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        let valid = s.flatMap { $0.model == VoiceProfile.modelID ? $0 : nil } ?? Saved(model: VoiceProfile.modelID)
        cache = valid
        return valid
    }

    private static func change(_ edit: (inout Saved) -> Void) {
        lock.lock()
        var s = load()
        edit(&s)
        cache = s
        lock.unlock()
        let data = try? JSONEncoder().encode(s)
        writer.async {
            guard let data else { return }
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? data.write(to: url, options: .atomic)
            #endif
            var u = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? u.setResourceValues(values)
        }
    }

    /// After speaker detection on this device: each speaker's voice, until you name them.
    static func keep(_ id: UUID, voices: [String: [Float]]) {
        guard enabled, !voices.isEmpty else { return }
        change { s in
            s.recent.removeAll { $0.transcript == id }
            s.recent.append(Recent(transcript: id, voices: voices, at: Date()))
            if s.recent.count > recentLimit { s.recent.removeFirst(s.recent.count - recentLimit) }
        }
    }

    /// The transcript's speakers changed (a continued recording joined on): their saved voices may not fit anymore.
    static func forget(_ id: UUID) {
        lock.lock(); let has = load().recent.contains { $0.transcript == id }; lock.unlock()
        if has { change { $0.recent.removeAll { $0.transcript == id } } }
    }

    static func voices(for id: UUID) -> [String: [Float]] {
        lock.lock(); defer { lock.unlock() }
        return load().recent.first { $0.transcript == id }?.voices ?? [:]
    }

    /// Voices you've named (not "You": your voice profile handles that).
    static func named() -> [(name: String, embedding: [Float])] {
        lock.lock(); defer { lock.unlock() }
        return load().named.map { ($0.name, $0.embedding) }
    }

    static var namedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return load().named.count
    }

    /// You named speaker `sid` (typed, or Use on a suggestion): their voice joins the voices you've named.
    static func remember(transcript id: UUID, speaker sid: String, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !clean.isEmpty, clean.lowercased() != VoiceProfile.youName.lowercased(),
              let v = voices(for: id)[sid], let unit = VoiceMath.normalized(v) else { return }
        change { s in
            if let i = s.named.firstIndex(where: { $0.name.lowercased() == clean.lowercased() }) {
                let n = s.named[i]
                s.named[i].embedding = VoiceMath.mean([n.embedding, unit], weights: [Float(n.count), 1]) ?? n.embedding
                s.named[i].count = n.count + 1
                s.named[i].updatedAt = Date()
            } else {
                s.named.append(Named(name: clean, embedding: unit, count: 1, updatedAt: Date()))
            }
        }
        Log.note("speaker voices: remembered a named voice (\(namedCount) in all)")
    }

    /// Deletes every saved voice from this device.
    static func clear() {
        lock.lock()
        cache = Saved(model: VoiceProfile.modelID)
        lock.unlock()
        writer.async { try? FileManager.default.removeItem(at: fileURL) }
        Log.note("speaker voices: cleared")
    }
}
