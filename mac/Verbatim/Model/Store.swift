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
}

/// Transcripts live as one JSON file each in ~/Library/Application Support/Verbatim/transcripts,
/// with their audio beside them in /audio. Nothing leaves the Mac.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var transcripts: [Transcript] = []

    static var transcriptsDir: URL { Paths.transcripts }
    static var audioDir: URL { Paths.audio }

    init() {
        for d in [Paths.transcripts, Paths.audio, Paths.models] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        load()
    }

    func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.transcriptsDir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        transcripts = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Transcript.self, from: Data(contentsOf: $0)) }
            .map { t in
                // A transcript left mid-processing by a crash is marked failed so it never spins forever.
                var t = t; if t.status == .processing { t.status = .failed; t.error = "Interrupted. Open the file again to retry." }; return t
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ t: Transcript) {
        transcripts.insert(t, at: 0)
        save(t)
    }

    func update(_ id: UUID, _ change: (inout Transcript) -> Void) {
        guard let i = transcripts.firstIndex(where: { $0.id == id }) else { return }
        change(&transcripts[i])
        save(transcripts[i])
    }

    func delete(_ t: Transcript) {
        transcripts.removeAll { $0.id == t.id }
        try? FileManager.default.removeItem(at: Self.transcriptsDir.appendingPathComponent("\(t.id.uuidString).json"))
        if let a = audioURL(for: t) { try? FileManager.default.removeItem(at: a) }
    }

    func save(_ t: Transcript) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(t) {
            try? data.write(to: Self.transcriptsDir.appendingPathComponent("\(t.id.uuidString).json"), options: .atomic)
        }
    }

    func transcript(_ id: UUID) -> Transcript? { transcripts.first { $0.id == id } }

    func audioURL(for t: Transcript) -> URL? {
        guard let name = t.audioFileName else { return nil }
        return Self.audioDir.appendingPathComponent(name)
    }

    func newAudioURL(ext: String) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return Self.audioDir.appendingPathComponent("\(f.string(from: Date())).\(ext)")
    }

    /// Transcripts grouped for the history feed: Today, Yesterday, then by date.
    var grouped: [(label: String, items: [Transcript])] { Self.group(transcripts) }

    static func group(_ list: [Transcript]) -> [(label: String, items: [Transcript])] {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        var out: [(String, [Transcript])] = []
        for t in list {
            let label = cal.isDateInToday(t.createdAt) ? "Today" : cal.isDateInYesterday(t.createdAt) ? "Yesterday" : f.string(from: t.createdAt)
            if let i = out.firstIndex(where: { $0.0 == label }) { out[i].1.append(t) } else { out.append((label, [t])) }
        }
        return out.map { (label: $0.0, items: $0.1) }
    }
}
