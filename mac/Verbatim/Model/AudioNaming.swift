import Foundation

/// Names for new audio files, and claiming them. Pure Foundation, so mac/tools/test-naming.sh checks it on Linux.
///
/// Every new recording, import, link download, and mix gets "<stamp> <suffix>.<ext>", where the suffix is four
/// random characters: two imports in the same second can't land on one name, and no writer ever replaces a file it
/// didn't create (`claim`).
enum AudioNaming {
    /// Lowercase letters and digits without the easily confused ones (0/o, 1/l/i).
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    static func randomSuffix() -> String {
        var g = SystemRandomNumberGenerator()
        return randomSuffix(using: &g)
    }

    static func randomSuffix<G: RandomNumberGenerator>(using g: inout G) -> String {
        String((0..<4).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
    }

    /// "2026-10-22 14.03.07 k3f9.m4a"
    static func fileName(stamp: String, suffix: String, ext: String) -> String {
        ext.isEmpty ? "\(stamp) \(suffix)" : "\(stamp) \(suffix).\(ext)"
    }

    /// Extensions a new file's name may end up with: what the caller asked for, plus what an import may switch to
    /// (a copied audio file keeps its own; AAC falls back to WAV).
    static let siblingExts = ["m4a", "wav"]

    /// A name no file uses: `isTaken` gets each candidate's stem ("<stamp> <suffix>") and the extension asked for,
    /// and answers whether any file of that stem exists or is in use. Tries fresh suffixes until one is free.
    static func uniqueName(stamp: String, ext: String, isTaken: (_ stem: String, _ ext: String) -> Bool,
                           suffix: () -> String = { randomSuffix() }) -> String {
        for _ in 0..<64 {
            let stem = "\(stamp) \(suffix())"
            if !isTaken(stem, ext) { return ext.isEmpty ? stem : "\(stem).\(ext)" }
        }
        // 64 collisions in a row can't happen with a random suffix; a UUID can't collide either way.
        let stem = "\(stamp) \(UUID().uuidString.prefix(8).lowercased())"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// Whether a file named `stem` with `ext` (or one of `siblingExts`) exists in `folder`, or is in `used`.
    static func taken(stem: String, ext: String, in folder: URL, used: Set<String> = [], fileManager fm: FileManager = .default) -> Bool {
        for e in Set([ext] + siblingExts) {
            let name = e.isEmpty ? stem : "\(stem).\(e)"
            if used.contains(name) || fm.fileExists(atPath: folder.appendingPathComponent(name).path) { return true }
        }
        return false
    }

    struct AlreadyExists: LocalizedError {
        let url: URL
        var errorDescription: String? { "“\(url.lastPathComponent)” already exists, so it wasn't replaced." }
    }

    /// Creates the file with `contents`, failing if anything is already at `url`, atomically: a writer that claims
    /// its file first can delete it later knowing it made it.
    static func claim(_ url: URL, contents: Data = Data()) throws {
        if FileManager.default.fileExists(atPath: url.path) { throw AlreadyExists(url: url) }
        do {
            try contents.write(to: url, options: .withoutOverwriting)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { throw AlreadyExists(url: url) }
            throw error
        }
    }
}
