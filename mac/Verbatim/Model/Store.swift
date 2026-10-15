import Foundation
import Combine

/// Everything lives under ~/Library/Application Support/Verbatim. Nothing leaves the Mac.
enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Verbatim", isDirectory: true)
    }()
    static let transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
    static let audio = root.appendingPathComponent("audio", isDirectory: true)
    static let models = root.appendingPathComponent("models", isDirectory: true)
    static let downloads = root.appendingPathComponent("downloads", isDirectory: true)
    static let thumbs = root.appendingPathComponent("thumbs", isDirectory: true)
    static let projectsFile = root.appendingPathComponent("projects.json")
    static let dictionaryFile = root.appendingPathComponent("dictionary.json")
}

/// Transcripts live as one JSON file each in /transcripts, with audio beside them in /audio.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var transcripts: [Transcript] = []
    @Published var projects: [Project] = [] { didSet { saveProjects() } }
    @Published var dictionary: [DictionaryEntry] = [] { didSet { saveDictionary() } }

    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private var loading = true
    private var pendingSaves: [UUID: DispatchWorkItem] = [:]

    init() {
        for d in [Paths.transcripts, Paths.audio, Paths.models, Paths.downloads, Paths.thumbs] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        load()
        loading = false
    }

    func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.transcripts, includingPropertiesForKeys: nil)) ?? []
        transcripts = files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.dec.decode(Transcript.self, from: Data(contentsOf: $0)) }
            .map { t in
                var t = t
                if t.status == .processing { t.stage = "Queued" }   // AppState resumes these
                return t
            }
            .sorted { $0.createdAt > $1.createdAt }
        projects = (try? Self.dec.decode([Project].self, from: Data(contentsOf: Paths.projectsFile))) ?? []
        dictionary = (try? Self.dec.decode([DictionaryEntry].self, from: Data(contentsOf: Paths.dictionaryFile))) ?? []
        recoverOrphans()
        purgeExpired()
    }

    /// Transcripts that aren't in Recently Deleted.
    var live: [Transcript] { transcripts.filter { $0.deletedAt == nil } }
    /// Recently Deleted, newest first.
    var trash: [Transcript] { transcripts.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) } }

    func moveToTrash(_ id: UUID) { update(id) { $0.deletedAt = Date(); $0.pinned = false } }
    func restore(_ id: UUID) { update(id) { $0.deletedAt = nil } }

    /// Recently Deleted keeps things for 30 days.
    private func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for t in transcripts where (t.deletedAt ?? .distantFuture) < cutoff { delete(t) }
    }

    /// A recording whose app died before the transcript was saved still has its WAV on disk. Surface it.
    private func recoverOrphans() {
        let fm = FileManager.default
        let known = Set(transcripts.compactMap(\.audioFileName))
        let files = (try? fm.contentsOfDirectory(at: Paths.audio, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where !known.contains(f.lastPathComponent) && ["wav", "m4a", "mp3", "mp4", "mov", "aiff"].contains(f.pathExtension.lowercased()) {
            let dur = Player.duration(of: f)
            guard dur > 1 else { continue }
            let when = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            var t = Transcript(title: "Recovered recording", source: .voiceMemo, sourceLabel: "Recovered", duration: dur, audioFileName: f.lastPathComponent, model: "")
            t.createdAt = when
            t.status = .failed
            t.error = "This recording was saved but never transcribed. Right-click to retry."
            transcripts.append(t)
            save(t)
        }
        transcripts.sort { $0.createdAt > $1.createdAt }
    }

    // MARK: Transcripts

    func add(_ t: Transcript) { transcripts.insert(t, at: 0); save(t) }

    func update(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let i = transcripts.firstIndex(where: { $0.id == id }) else { return }
        change(&transcripts[i])
        save(transcripts[i])
    }

    /// Like `update`, but writes to disk a second after the last change: for typing.
    func updateDeferred(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let i = transcripts.firstIndex(where: { $0.id == id }) else { return }
        change(&transcripts[i])
        pendingSaves[id]?.cancel()
        let w = DispatchWorkItem { [weak self] in if let t = self?.transcript(id) { self?.save(t) } }
        pendingSaves[id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    /// Permanent: removes the transcript, its audio, and its thumbnail.
    func delete(_ t: Transcript) {
        transcripts.removeAll { $0.id == t.id }
        try? FileManager.default.removeItem(at: Paths.transcripts.appendingPathComponent("\(t.id.uuidString).json"))
        if let a = audioURL(for: t) { try? FileManager.default.removeItem(at: a) }
        if let th = t.link?.thumbnailFile { try? FileManager.default.removeItem(at: Paths.thumbs.appendingPathComponent(th)) }
        // Note stills go too. Kept MP4/M4A files in the Keep folder are yours and stay.
        for f in t.notes.compactMap(\.frameFile) { try? FileManager.default.removeItem(at: Paths.thumbs.appendingPathComponent(f)) }
    }

    func save(_ t: Transcript) {
        if let data = try? Self.enc.encode(t) {
            try? data.write(to: Paths.transcripts.appendingPathComponent("\(t.id.uuidString).json"), options: .atomic)
        }
    }

    func transcript(_ id: UUID) -> Transcript? { transcripts.first { $0.id == id } }

    /// Display-only progress text; not written to disk.
    func setStage(_ id: UUID, _ stage: String) {
        guard let i = transcripts.firstIndex(where: { $0.id == id }), transcripts[i].stage != stage else { return }
        transcripts[i].stage = stage
    }

    func audioURL(for t: Transcript) -> URL? {
        guard let name = t.audioFileName else { return nil }
        return Paths.audio.appendingPathComponent(name)
    }

    func newAudioURL(ext: String) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return Paths.audio.appendingPathComponent("\(f.string(from: Date())).\(ext)")
    }

    // MARK: Projects and dictionary

    private func saveProjects() {
        guard !loading, let d = try? Self.enc.encode(projects) else { return }
        try? d.write(to: Paths.projectsFile, options: .atomic)
    }

    private func saveDictionary() {
        guard !loading, let d = try? Self.enc.encode(dictionary) else { return }
        try? d.write(to: Paths.dictionaryFile, options: .atomic)
    }

    func addProject(_ name: String) -> Project {
        let p = Project(name: name, colorIndex: projects.count % 3); projects.append(p); return p
    }

    func addNote(_ note: Note, to id: UUID) {
        update(id) { $0.notes.insert(note, at: 0) }
    }

    /// Adds a dictionary entry or extends an existing one with a new "heard as" form.
    func remember(preferred: String, heardAs: String, from source: String, project: UUID? = nil) {
        if let i = dictionary.firstIndex(where: { $0.preferred.caseInsensitiveCompare(preferred) == .orderedSame && $0.projectId == project }) {
            if !dictionary[i].heardAs.contains(where: { $0.caseInsensitiveCompare(heardAs) == .orderedSame }) {
                dictionary[i].heardAs.append(heardAs)
            }
        } else {
            dictionary.append(DictionaryEntry(preferred: preferred, heardAs: [heardAs], learnedFrom: source, projectId: project))
        }
    }

    // MARK: Grouping

    static func group(_ list: [Transcript]) -> [(label: String, items: [Transcript])] {
        let list = list.filter { $0.deletedAt == nil }
        let cal = Calendar.current
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        var out: [(String, [Transcript])] = []
        let pinned = list.filter(\.pinned)
        if !pinned.isEmpty { out.append(("Pinned", pinned)) }
        for t in list where !t.pinned {
            let label = cal.isDateInToday(t.createdAt) ? "Today" : cal.isDateInYesterday(t.createdAt) ? "Yesterday" : f.string(from: t.createdAt)
            if let i = out.firstIndex(where: { $0.0 == label }) { out[i].1.append(t) } else { out.append((label, [t])) }
        }
        return out.map { (label: $0.0, items: $0.1) }
    }
}
