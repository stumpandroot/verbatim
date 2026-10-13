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

    init() {
        for d in [Paths.transcripts, Paths.audio, Paths.models, Paths.downloads] {
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
                if t.status == .processing { t.status = .failed; t.error = "Interrupted before it finished. Choose Retry to run it again." }
                return t
            }
            .sorted { $0.createdAt > $1.createdAt }
        projects = (try? Self.dec.decode([Project].self, from: Data(contentsOf: Paths.projectsFile))) ?? []
        dictionary = (try? Self.dec.decode([DictionaryEntry].self, from: Data(contentsOf: Paths.dictionaryFile))) ?? []
    }

    // MARK: Transcripts

    func add(_ t: Transcript) { transcripts.insert(t, at: 0); save(t) }

    func update(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let i = transcripts.firstIndex(where: { $0.id == id }) else { return }
        change(&transcripts[i])
        save(transcripts[i])
    }

    func delete(_ t: Transcript) {
        transcripts.removeAll { $0.id == t.id }
        try? FileManager.default.removeItem(at: Paths.transcripts.appendingPathComponent("\(t.id.uuidString).json"))
        if let a = audioURL(for: t) { try? FileManager.default.removeItem(at: a) }
    }

    func save(_ t: Transcript) {
        if let data = try? Self.enc.encode(t) {
            try? data.write(to: Paths.transcripts.appendingPathComponent("\(t.id.uuidString).json"), options: .atomic)
        }
    }

    func transcript(_ id: UUID) -> Transcript? { transcripts.first { $0.id == id } }

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
        let p = Project(name: name); projects.append(p); return p
    }

    /// Adds a dictionary entry or extends an existing one with a new "heard as" form.
    func remember(preferred: String, heardAs: String, from source: String) {
        if let i = dictionary.firstIndex(where: { $0.preferred.caseInsensitiveCompare(preferred) == .orderedSame }) {
            if !dictionary[i].heardAs.contains(where: { $0.caseInsensitiveCompare(heardAs) == .orderedSame }) {
                dictionary[i].heardAs.append(heardAs)
            }
        } else {
            dictionary.append(DictionaryEntry(preferred: preferred, heardAs: [heardAs], learnedFrom: source))
        }
    }

    // MARK: Grouping

    static func group(_ list: [Transcript]) -> [(label: String, items: [Transcript])] {
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
