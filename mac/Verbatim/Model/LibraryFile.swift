import Foundation

/// File names that come from transcript records (audio, a continued recording, a link's thumbnail, note stills,
/// multi-track working copies). Records sync through iCloud, so any device on the account (or a damaged file) can
/// write them: a name is used only when it's a bare file name, and only inside the folder it belongs to. Every join
/// of a record's file name to a library folder goes through `url(_:in:field:)`. Pure Foundation, so
/// mac/tools/test-library-file.sh checks it on Linux.
enum LibraryFile {
    /// A bare last path component: not empty, no "/", "\", or NUL, doesn't start with "." (so never "." or "..",
    /// and never a hidden file or an iCloud placeholder), and at most 255 bytes.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix(".") else { return false }
        if name.contains("/") || name.contains("\\") || name.contains("\u{0}") { return false }
        return (name as NSString).lastPathComponent == name
    }

    /// `name` inside `folder`, or nil when the name isn't a bare file name, the joined path leaves the folder, or
    /// the item there is a symbolic link. A rejected name is logged once (by field, never the name itself), and
    /// nothing is read or deleted for it.
    static func url(_ name: String?, in folder: URL, field: String) -> URL? {
        guard let name else { return nil }
        guard isSafeName(name) else { reject(field, name); return nil }
        let dir = folder.standardizedFileURL
        let u = dir.appendingPathComponent(name).standardizedFileURL
        guard u.deletingLastPathComponent().path == dir.path, u.lastPathComponent == name else { reject(field, name); return nil }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) != nil { reject(field, name); return nil }
        return u
    }

    /// The name as decoded from a record, or nil when it isn't a bare file name (logged once).
    static func checked(_ name: String?, field: String) -> String? {
        guard let name else { return nil }
        guard isSafeName(name) else { reject(field, name); return nil }
        return name
    }

    private static let lock = NSLock()
    private static var reported = Set<String>()

    private static func reject(_ field: String, _ name: String) {
        lock.lock()
        let first = reported.insert(field + "\u{0}" + name).inserted
        lock.unlock()
        if first { Log.note("library: ignored an unsafe \(field) file name in a transcript record (\(name.utf8.count) bytes)") }
    }
}
