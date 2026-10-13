import Foundation

/// Fetches the audio track of a video link with the bundled yt-dlp (Contents/Helpers/yt-dlp).
/// Internet is required for this step; transcription afterwards runs on this Mac.
enum LinkFetcher {
    struct Fetched { let url: URL; let title: String; let uploader: String? }

    static var helperURL: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/yt-dlp")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    static func looksLikeLink(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let h = u.host else { return false }
        return ["http", "https"].contains(u.scheme ?? "") && h.contains(".")
    }

    static func fetch(_ link: String, progress: @escaping @Sendable (String) -> Void) async throws -> Fetched {
        guard let helper = helperURL else {
            throw NSError(domain: "Verbatim", code: 10, userInfo: [NSLocalizedDescriptionKey: "The link helper is missing from this build."])
        }
        try FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let template = Paths.downloads.appendingPathComponent("\(stamp).%(ext)s").path
        progress("Fetching audio")
        Log.note("yt-dlp fetch \(link)")
        let out = try await run(helper, [
            "--no-playlist", "--no-warnings", "--newline",
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "--print", "after_move:%(title)s\t%(uploader)s\t%(filepath)s",
            "--no-simulate",
            "-o", template, link,
        ], progress: progress)
        guard let line = out.split(separator: "\n").last(where: { $0.contains("\t") }) else {
            throw NSError(domain: "Verbatim", code: 11, userInfo: [NSLocalizedDescriptionKey: "No audio came back for that link."])
        }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let path = parts.count > 2 ? parts[2] : ""
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "Verbatim", code: 12, userInfo: [NSLocalizedDescriptionKey: "The download finished but the file is missing."])
        }
        return Fetched(url: URL(fileURLWithPath: path), title: parts[0], uploader: parts.count > 1 && parts[1] != "NA" ? parts[1] : nil)
    }

    private static func run(_ exe: URL, _ args: [String], progress: @escaping @Sendable (String) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = NSHomeDirectory()
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            var collected = Data()
            var errText = ""
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                collected.append(d)
                if let s = String(data: d, encoding: .utf8) {
                    for l in s.split(separator: "\n") where l.hasPrefix("[download]") {
                        if let r = l.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) { progress("Fetching audio " + l[r]) }
                    }
                }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                if let s = String(data: h.availableData, encoding: .utf8) { errText += s }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    cont.resume(returning: String(data: collected, encoding: .utf8) ?? "")
                } else {
                    let msg = errText.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init) ?? "yt-dlp exited with status \(proc.terminationStatus)."
                    cont.resume(throwing: NSError(domain: "Verbatim", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg.replacingOccurrences(of: "ERROR: ", with: "")]))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
