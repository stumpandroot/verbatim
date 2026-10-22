import Foundation

/// Imports in progress on this device: transcript ID → the file it's made from and the audio file being written. An
/// import placeholder ("Importing") has no audio until the file is prepared; if the app quits first, launch removes
/// the half-written audio and starts the import again, or removes the placeholder when its file is gone
/// (`Store.cleanUpStuckImports`). In Application Support, never synced (the paths name this device's folders).
/// Thread-safe.
enum PendingImports {
    struct Entry: Codable, Equatable {
        var source: String
        /// The audio file the import writes, once it has picked one (in the audio folder).
        var dest: String? = nil
    }

    private static let lock = NSLock()
    private static var file: URL { Paths.local.appendingPathComponent("pending-imports.json") }
    private static var cache: [UUID: Entry]? = nil

    private static func load() -> [UUID: Entry] {
        if let c = cache { return c }
        let m = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([UUID: Entry].self, from: $0) } ?? [:]
        cache = m
        return m
    }

    private static func save(_ m: [UUID: Entry]) {
        cache = m
        try? FileManager.default.createDirectory(at: Paths.local, withIntermediateDirectories: true)
        if m.isEmpty { try? FileManager.default.removeItem(at: file) }
        else if let d = try? JSONEncoder().encode(m) { try? d.write(to: file, options: .atomic) }
    }

    static func record(_ id: UUID, source: URL) {
        lock.lock(); defer { lock.unlock() }
        var m = load(); m[id] = Entry(source: source.path); save(m)
    }

    /// The audio file the import is about to write, so launch can remove it if the app quits before it's done.
    static func writing(_ id: UUID, to dest: URL) {
        lock.lock(); defer { lock.unlock() }
        var m = load()
        guard var e = m[id] else { return }
        e.dest = dest.lastPathComponent
        m[id] = e
        save(m)
    }

    static func clear(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        var m = load()
        guard m.removeValue(forKey: id) != nil else { return }
        save(m)
    }

    static func entry(_ id: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return load()[id]
    }

    /// Drops entries for transcripts that no longer exist.
    static func keep(only ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        let m = load()
        let kept = m.filter { ids.contains($0.key) }
        if kept.count != m.count { save(kept) }
    }

    /// The placeholder's stage while an import prepares its audio.
    static let stage = "Importing"
}
