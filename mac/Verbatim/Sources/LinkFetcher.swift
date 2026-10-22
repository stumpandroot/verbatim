import Foundation
import AppKit
import AVFoundation

/// Fetches the audio track of a video link with the bundled yt-dlp (Contents/Helpers/yt-dlp).
/// Cloud share links (Dropbox, Google Drive, OneDrive, SharePoint, iCloud Drive) skip yt-dlp: CloudShareFetch
/// resolves and downloads them, and MediaImport prepares the audio.
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

    /// Whether this build can fetch a link: cloud share links need no helper; everything else needs yt-dlp.
    static func canFetch(_ link: String) -> Bool { helperURL != nil || CloudShareLink.isCloudLink(link) }

    /// yt-dlp failed. `message` is its last ERROR line, shown as is; `output` is the rest of what it printed, kept
    /// only to recognize sign-in and permission errors (LinkSignIn). Neither is logged in full, and neither holds
    /// cookie values: yt-dlp never prints them.
    struct HelperError: LocalizedError, CustomStringConvertible {
        let message: String
        let output: String
        let status: Int32
        var errorDescription: String? { message }
        var description: String { "yt-dlp status \(status): \(message)" }

        /// The video needs a signed-in viewer (private, members-only, age-restricted, login required).
        var needsSignIn: Bool { LinkSignIn.needsSignIn(message + "\n" + output) }
        /// yt-dlp couldn't read Safari's cookies without Full Disk Access.
        var safariAccessDenied: Bool { LinkSignIn.safariAccessDenied(message + "\n" + output) }
    }

    /// The browser whose sign-in fetched a link, so keeping its video later uses the same sign-in. Browser names
    /// only, never cookies; in memory for this session.
    private static let signInByLink = SignInMemory()
    private final class SignInMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: LinkSignIn.Browser] = [:]
        subscript(_ link: String) -> LinkSignIn.Browser? {
            get { lock.lock(); defer { lock.unlock() }; return map[link] }
            set { lock.lock(); map[link] = newValue; lock.unlock() }
        }
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
    /// `signIn` borrows that browser's sign-in for this one link (`--cookies-from-browser`).
    static func fetch(_ link: String, signIn: LinkSignIn.Browser? = nil, progress: @escaping @Sendable (String) -> Void,
                      events: (@Sendable (Event) -> Void)? = nil) async throws -> Fetched {
        if let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let plan = try CloudShareLink.plan(u) {
            return try await fetchCloud(link, plan: plan, progress: progress, events: events)
        }
        guard let helper = helperURL else {
            throw NSError(domain: "Verbatim", code: 10, userInfo: [NSLocalizedDescriptionKey: "The link helper is missing from this build."])
        }
        try FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let template = Paths.downloads.appendingPathComponent("\(stamp).%(ext)s").path
        progress("Fetching audio")
        Log.note("yt-dlp fetch \(link)" + (signIn.map { " with the \($0.name) sign-in" } ?? ""))
        func removePartials() {
            let fm = FileManager.default
            for f in (try? fm.contentsOfDirectory(atPath: Paths.downloads.path)) ?? [] where f.hasPrefix(stamp) {
                try? fm.removeItem(at: Paths.downloads.appendingPathComponent(f))
            }
        }
        let out: String
        do {
            out = try await run(helper, YtDlpCommand.audio(link: link, template: template, signIn: LinkSignIn.arguments(signIn)),
                                progress: progress, events: events)
        } catch {
            if error is CancellationError { removePartials() }
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
        if let signIn { signInByLink[link] = signIn }
        // Every download goes through MediaImport, like cloud links: WebM and Opus (and anything else AVFoundation
        // can't read) are decoded by FFmpeg, and video keeps only its sound.
        let downloaded = URL(fileURLWithPath: path)
        progress("Preparing the audio")
        let prepared: MediaImport.Prepared
        do {
            prepared = try await MediaImport.prepare(downloaded, into: Paths.downloads.appendingPathComponent("\(stamp)-audio.m4a"))
        } catch {
            removePartials()
            throw error
        }
        if prepared.url != downloaded { try? FileManager.default.removeItem(at: downloaded) }
        return Fetched(url: prepared.url, title: parts[0], uploader: part(1),
                       pageURL: part(3), site: part(4).map(siteName), uploadDate: part(5), thumbnail: part(6))
    }

    /// A cloud share link: resolve it, download the file with progress, and prepare its audio (video files keep
    /// only their sound). The title is the original file name, without its extension.
    private static func fetchCloud(_ link: String, plan: CloudShareLink.Plan, progress: @escaping @Sendable (String) -> Void,
                                   events: (@Sendable (Event) -> Void)?) async throws -> Fetched {
        try FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        progress("Finding the file")
        Log.note("cloud link fetch (\(plan.service.name))")
        let target = try await CloudShareFetch.resolve(plan)
        events?(.meta(title: target.title, uploader: nil, site: plan.service.name, thumbnail: nil, duration: nil))
        if let ext = target.ext, !MediaImport.isMedia(URL(fileURLWithPath: "file.\(ext)")) {
            throw NSError(domain: "Verbatim", code: 14, userInfo: [NSLocalizedDescriptionKey: "“\(target.fileName ?? "This file")” isn't audio or video. Share an audio or video file."])
        }
        progress("Downloading")
        let downloaded: (file: URL, fileName: String?)
        do {
            downloaded = try await CloudShareFetch.download(target, into: Paths.downloads, stamp: stamp) { fraction in
                guard let fraction else { return }
                progress("Downloading \(Int(fraction * 100))%")
                events?(.progress(fraction))
            }
        } catch {
            let fm = FileManager.default
            for f in (try? fm.contentsOfDirectory(atPath: Paths.downloads.path)) ?? [] where f.hasPrefix(stamp) {
                try? fm.removeItem(at: Paths.downloads.appendingPathComponent(f))
            }
            throw error
        }
        let name = downloaded.fileName ?? target.fileName
        progress("Preparing the audio")
        let prepared: MediaImport.Prepared
        do {
            prepared = try await MediaImport.prepare(downloaded.file, into: Paths.downloads.appendingPathComponent("\(stamp)-audio.m4a"))
        } catch {
            try? FileManager.default.removeItem(at: downloaded.file)
            throw error
        }
        if prepared.url != downloaded.file { try? FileManager.default.removeItem(at: downloaded.file) }
        let title = name.map(CloudShareLink.title(fromFileName:)) ?? plan.service.name
        return Fetched(url: prepared.url, title: title, uploader: nil, pageURL: link, site: plan.service.name)
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
        let out = try await run(helper, YtDlpCommand.keep(link: link, template: template, signIn: LinkSignIn.arguments(signInByLink[link])),
                                progress: { p in progress(p.replacingOccurrences(of: "Fetching audio", with: "Keeping video")) })
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
    private static let metaTag = YtDlpCommand.metaTag

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

    /// Runs yt-dlp with only the environment it needs (YtDlpCommand.environment) and waits until it has exited and
    /// both of its outputs are read to the end (HelperProcess). Cancelling the Task stops it.
    private static func run(_ exe: URL, _ args: [String], progress: @escaping @Sendable (String) -> Void,
                            events: (@Sendable (Event) -> Void)? = nil) async throws -> String {
        let env = YtDlpCommand.environment(from: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        // --print implies --quiet, so with --progress the progress lines can arrive on either stream.
        let r = try await HelperProcess.run(exe, args, environment: env,
                                            onStdoutLine: { scan($0, progress: progress, events: events) },
                                            onStderrLine: { l in
                                                guard l.contains("[download]") else { return false }
                                                scan(l, progress: progress, events: events)
                                                return true
                                            })
        guard r.status == 0 else {
            throw HelperError(message: YtDlpCommand.errorMessage(stderr: r.stderr, status: r.status),
                              output: String(r.stderr.suffix(8000)), status: r.status)
        }
        return r.stdout
    }
}
