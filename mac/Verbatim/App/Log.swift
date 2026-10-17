import Foundation
import os

/// Milestones go to ~/Library/Logs/Verbatim/native.log, so a hang or crash leaves a trail the user can choose to
/// send (Settings › Send Diagnostic Log). Privacy rules, matching the privacy policy:
/// - Lines older than 7 days are dropped at launch.
/// - Links become "<link>" and the home folder becomes "~", so the file has no pasted URLs or macOS user name.
/// - The unified log (Console.app) gets the line marked private, so it is redacted there unless a developer
///   profile is installed.
enum Log {
    static let logger = Logger(subsystem: "co.stumpandroot.verbatim", category: "app")
    static let retentionDays = 7
    static let file: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Verbatim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("native.log")
        trimOldLines(f)
        return f
    }()
    private static let queue = DispatchQueue(label: "co.stumpandroot.verbatim.log", qos: .utility)
    private static let t0 = Date()
    /// One formatter for every line (ISO8601DateFormatter is thread-safe).
    private static let stamp = ISO8601DateFormatter()
    /// Kept open between lines; only touched on `queue`.
    private static var handle: FileHandle?
    private static let linkPattern = try! NSRegularExpression(pattern: #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+"#)
    private static let userPattern = try! NSRegularExpression(pattern: #"/(Users|home)/[^/\s"']+"#)
    private static let home = NSHomeDirectory()

    /// Removes links and user-identifying paths from a log line.
    static func redact(_ message: String) -> String {
        var s = message
        if !home.isEmpty, home != "/" { s = s.replacingOccurrences(of: home, with: "~") }
        var r = NSRange(s.startIndex..., in: s)
        s = linkPattern.stringByReplacingMatches(in: s, range: r, withTemplate: "<link>")
        r = NSRange(s.startIndex..., in: s)
        s = userPattern.stringByReplacingMatches(in: s, range: r, withTemplate: "/$1/…")
        return s
    }

    /// When lines were last trimmed; only touched on `queue`. The Mac app can stay open for weeks.
    private static var lastTrim = Date()

    /// Trims now, before the file is sent (Settings › Send Diagnostic Log). Waits until it's done.
    static func trimNow() {
        _ = file
        queue.sync { try? handle?.close(); handle = nil; trimOldLines(file); lastTrim = Date() }
    }

    static func note(_ message: String) {
        let clean = redact(message)
        logger.info("\(clean, privacy: .private)")
        let line = String(format: "%@ +%.3fs %@\n", stamp.string(from: Date()), Date().timeIntervalSince(t0), clean)
        queue.async {
            if Date().timeIntervalSince(lastTrim) > 86_400 { try? handle?.close(); handle = nil; trimOldLines(file); lastTrim = Date() }
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

    /// Drops lines older than `retentionDays` (each line starts with an ISO 8601 time). Lines without a time
    /// (continuations) stay with the line before them.
    private static func trimOldLines(_ f: URL) {
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let fmt = ISO8601DateFormatter()
        var keep = false, out: [Substring] = [], dropped = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let sp = line.firstIndex(of: " "), let d = fmt.date(from: String(line[..<sp])) { keep = d >= cutoff }
            if keep { out.append(line) } else if !line.isEmpty { dropped += 1 }
        }
        guard dropped > 0 else { return }
        try? out.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    }
}
