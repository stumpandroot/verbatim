import Foundation
import AppKit
import AVFoundation

/// Fetches the audio track of a video link with the bundled yt-dlp (Contents/Helpers/yt-dlp).
/// Internet is required for this step; transcription afterwards runs on this Mac.
enum LinkFetcher {
    struct Fetched {
        let url: URL; let title: String; let uploader: String?
        var pageURL: String? = nil, site: String? = nil, uploadDate: String? = nil, thumbnail: String? = nil
    }

    static var helperURL: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/yt-dlp")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    static func looksLikeLink(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let h = u.host else { return false }
        return ["http", "https"].contains(u.scheme ?? "") && h.contains(".")
    }

    /// What yt-dlp says while it works, for the "link added" card.
    enum Event: Sendable {
        /// The video's details, known before the download starts. Any of them can be missing.
        case meta(title: String?, uploader: String?, site: String?, thumbnail: String?, duration: Double?)
        /// 0…1 through the download.
        case progress(Double)
    }

    /// Downloads a link's audio. Cancelling the calling Task stops yt-dlp and removes its partial files.
    static func fetch(_ link: String, progress: @escaping @Sendable (String) -> Void,
                      events: (@Sendable (Event) -> Void)? = nil) async throws -> Fetched {
        guard let helper = helperURL else {
            throw NSError(domain: "Verbatim", code: 10, userInfo: [NSLocalizedDescriptionKey: "The link helper is missing from this build."])
        }
        try FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let template = Paths.downloads.appendingPathComponent("\(stamp).%(ext)s").path
        progress("Fetching audio")
        Log.note("yt-dlp fetch \(link)")
        let out: String
        do {
            out = try await run(helper, [
                "--no-playlist", "--no-warnings", "--newline", "--progress",
                "-f", "bestaudio[ext=m4a]/bestaudio/best",
                // Printed once the video's details are known, before the download starts.
                "--print", "video:\(metaTag)\t%(title)s\t%(uploader)s\t%(extractor_key)s\t%(thumbnail)s\t%(duration)s",
                "--print", "after_move:%(title)s\t%(uploader)s\t%(filepath)s\t%(webpage_url)s\t%(extractor_key)s\t%(upload_date)s\t%(thumbnail)s",
                "--no-simulate",
                "-o", template, link,
            ], progress: progress, events: events)
        } catch {
            if error is CancellationError {
                let fm = FileManager.default
                for f in (try? fm.contentsOfDirectory(atPath: Paths.downloads.path)) ?? [] where f.hasPrefix(stamp) {
                    try? fm.removeItem(at: Paths.downloads.appendingPathComponent(f))
                }
            }
            throw error
        }
        guard let line = out.split(separator: "\n").last(where: { $0.contains("\t") && !$0.hasPrefix(metaTag) }) else {
            throw NSError(domain: "Verbatim", code: 11, userInfo: [NSLocalizedDescriptionKey: "No audio came back for that link."])
        }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let path = parts.count > 2 ? parts[2] : ""
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "Verbatim", code: 12, userInfo: [NSLocalizedDescriptionKey: "The download finished but the file is missing."])
        }
        func part(_ i: Int) -> String? { parts.count > i && parts[i] != "NA" && !parts[i].isEmpty ? parts[i] : nil }
        return Fetched(url: URL(fileURLWithPath: path), title: parts[0], uploader: part(1),
                       pageURL: part(3), site: part(4).map(siteName), uploadDate: part(5), thumbnail: part(6))
    }

    /// yt-dlp's extractor key ("Youtube", "Vimeo", "TwitchVod") as people say it (the shared `Platform` mapping).
    static func siteName(_ key: String) -> String { Platform.name(key) ?? key }

    /// Saves the page's thumbnail beside the transcripts. Best effort; no thumbnail is fine.
    static func saveThumbnail(_ remote: String, as name: String) async -> String? {
        guard let u = URL(string: remote), let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil else { return nil }
        let file = name + "." + (u.pathExtension.isEmpty ? "jpg" : u.pathExtension.lowercased())
        do { try data.write(to: Paths.thumbs.appendingPathComponent(file)); return file } catch { return nil }
    }

    /// Downloads a link's best H.264 video (up to 1080p) and AAC audio as separate files. When the site offers
    /// only a combined file, `audio` is nil and `video` already has sound.
    static func downloadStreams(_ link: String, progress: @escaping @Sendable (String) -> Void) async throws -> (video: URL, audio: URL?) {
        guard let helper = helperURL else { throw NSError(domain: "Verbatim", code: 10, userInfo: [NSLocalizedDescriptionKey: "The link helper is missing from this build."]) }
        try FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let template = Paths.downloads.appendingPathComponent("keep-\(stamp).%(format_id)s.%(ext)s").path
        progress("Keeping video")
        Log.note("yt-dlp keep \(link)")
        // "," downloads each format separately (no merging needed). Falls back to one combined MP4.
        let format = "bv*[ext=mp4][vcodec^=avc1][height<=1080],ba[ext=m4a]/b[ext=mp4][height<=1080]/b[ext=mp4]"
        let out = try await run(helper, [
            "--no-playlist", "--no-warnings", "--newline",
            "-f", format,
            "--print", "after_move:%(filepath)s\t%(vcodec)s\t%(acodec)s",
            "--no-simulate", "-o", template, link,
        ], progress: { p in progress(p.replacingOccurrences(of: "Fetching audio", with: "Keeping video")) })
        var video: URL?, audio: URL?
        for line in out.split(separator: "\n") where line.contains("\t") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard FileManager.default.fileExists(atPath: f[0]) else { continue }
            let u = URL(fileURLWithPath: f[0])
            let vcodec = f.count > 1 ? f[1] : "none", acodec = f.count > 2 ? f[2] : "none"
            if vcodec != "none" { video = u; if acodec != "none" { audio = nil } }
            else if acodec != "none" { audio = u }
        }
        guard let v = video else { throw NSError(domain: "Verbatim", code: 13, userInfo: [NSLocalizedDescriptionKey: "That link has no video Verbatim can keep as MP4."]) }
        // If the video file already carries sound, the separate audio isn't needed.
        let hasSound = !((try? await AVURLAsset(url: v).loadTracks(withMediaType: .audio)) ?? []).isEmpty
        if hasSound, let a = audio { try? FileManager.default.removeItem(at: a); audio = nil }
        return (v, audio)
    }

    /// Marks the metadata line in yt-dlp's output.
    private static let metaTag = "VBMETA"

    /// Reads one line of yt-dlp output: progress percentages and the metadata line.
    private static func scan(_ line: Substring, progress: @Sendable (String) -> Void, events: (@Sendable (Event) -> Void)?) {
        if line.hasPrefix(metaTag) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            func part(_ i: Int) -> String? { f.count > i && f[i] != "NA" && !f[i].isEmpty ? f[i] : nil }
            events?(.meta(title: part(1), uploader: part(2), site: part(3).map(siteName), thumbnail: part(4), duration: part(5).flatMap(Double.init)))
        } else if line.contains("[download]"), let r = line.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) {
            progress("Fetching audio " + line[r])
            if let v = Double(line[r].dropLast()) { events?(.progress(min(1, max(0, v / 100)))) }
        }
    }

    /// The running yt-dlp, so cancelling the Task can stop it.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private(set) var cancelled = false
        func attach(_ p: Process) { lock.lock(); process = p; let c = cancelled; lock.unlock(); if c, p.isRunning { p.terminate() } }
        func cancel() { lock.lock(); cancelled = true; let p = process; lock.unlock(); if let p, p.isRunning { p.terminate() } }
    }

    /// Splits a byte stream into lines (pipes deliver arbitrary chunks).
    private final class LineBuffer: @unchecked Sendable {
        private var pending = ""
        func feed(_ s: String, _ each: (Substring) -> Void) {
            pending += s
            while let nl = pending.firstIndex(where: \.isNewline) {
                let line = pending[..<nl]
                if !line.isEmpty { each(line) }
                pending = String(pending[pending.index(after: nl)...])
            }
        }
    }

    private static func run(_ exe: URL, _ args: [String], progress: @escaping @Sendable (String) -> Void,
                            events: (@Sendable (Event) -> Void)? = nil) async throws -> String {
        let running = Running()
        return try await withTaskCancellationHandler {
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
            // --print implies --quiet, so with --progress the progress lines can arrive on either stream.
            let outLines = LineBuffer(), errLines = LineBuffer()
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                collected.append(d)
                if let s = String(data: d, encoding: .utf8) { outLines.feed(s) { scan($0, progress: progress, events: events) } }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                if let s = String(data: h.availableData, encoding: .utf8) {
                    errLines.feed(s) { l in
                        if l.contains("[download]") { scan(l, progress: progress, events: events) } else { errText += l + "\n" }
                    }
                }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if running.cancelled {
                    cont.resume(throwing: CancellationError())
                } else if proc.terminationStatus == 0 {
                    cont.resume(returning: String(data: collected, encoding: .utf8) ?? "")
                } else {
                    let msg = errText.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init) ?? "yt-dlp exited with status \(proc.terminationStatus)."
                    cont.resume(throwing: NSError(domain: "Verbatim", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg.replacingOccurrences(of: "ERROR: ", with: "")]))
                }
            }
            do { try p.run(); running.attach(p) } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            running.cancel()
        }
    }
}
