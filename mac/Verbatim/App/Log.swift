import Foundation
import os

/// Milestones go to the unified log (Console.app, subsystem co.stumpandroot.verbatim) and to
/// ~/Library/Logs/Verbatim/native.log, so a hang or crash leaves a trail that can be sent back.
enum Log {
    static let logger = Logger(subsystem: "co.stumpandroot.verbatim", category: "app")
    static let file: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Verbatim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("native.log")
    }()
    private static let queue = DispatchQueue(label: "co.stumpandroot.verbatim.log", qos: .utility)
    private static let t0 = Date()
    /// One formatter for every line (ISO8601DateFormatter is thread-safe).
    private static let stamp = ISO8601DateFormatter()
    /// Kept open between lines; only touched on `queue`.
    private static var handle: FileHandle?

    static func note(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = String(format: "%@ +%.3fs %@\n", stamp.string(from: Date()), Date().timeIntervalSince(t0), message)
        queue.async {
            // Reopened if the file was removed meanwhile, so lines keep landing in native.log as before.
            if handle != nil, !FileManager.default.fileExists(atPath: file.path) { try? handle?.close(); handle = nil }
            if handle == nil { handle = try? FileHandle(forWritingTo: file) }
            if let h = handle {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!)
            } else {
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }
}
