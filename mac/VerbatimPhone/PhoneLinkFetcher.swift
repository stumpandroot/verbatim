import Foundation
import UIKit
#if YOUTUBE_ON_DEVICE
import YouTubeKit
#endif

/// Fetches a link's audio on the iPhone itself, so links work without a Mac.
///
/// What runs here:
/// - Direct links to audio or video files (MP3, M4A, WAV, AAC, MP4, MOV, …), found by extension or Content-Type.
/// - Apple Podcasts episode and show links (iTunes Lookup API), and podcast RSS feeds (the latest episode).
/// - Web pages that name their audio in an `og:audio` or `og:video` tag (many podcast hosts do).
/// - Vimeo, when the public player config offers a progressive MP4.
/// - YouTube (watch, youtu.be, Shorts, Live, YouTube Music) through YouTubeKit, only in builds with the
///   YOUTUBE_ON_DEVICE flag (project.yml explains why it can be switched off).
///
/// Anything else throws `LinkFetchError.needsMac`; the app then hands the link to the Mac (yt-dlp) when one syncs.
enum PhoneLinkFetcher {
    /// What a link points at, before any audio is downloaded.
    struct Resolved: Sendable {
        var media: URL
        var title: String?
        var site: String
        var channel: String?
        var thumbnail: URL?
        var pageURL: String
        /// File extension for the download, when the media URL doesn't carry one.
        var ext: String?
        /// Download in ranged chunks (YouTube's servers throttle one long request).
        var chunked = false
    }

    // MARK: Resolving

    static func resolve(_ link: URL) async throws -> Resolved {
        let host = (link.host ?? "").lowercased()
        if youTubeID(link) != nil {
            #if YOUTUBE_ON_DEVICE
            return try await resolveYouTube(link)
            #else
            throw LinkFetchError.needsMac
            #endif
        }
        if let v = vimeoID(link) { return try await resolveVimeo(link, id: v.id, hash: v.hash) }
        if host == "podcasts.apple.com" || host == "itunes.apple.com" { return try await resolveApplePodcasts(link) }
        return try await probe(link)
    }

    /// Looks at the response itself: a media file, a feed, or a page that names its audio.
    private static func probe(_ link: URL) async throws -> Resolved {
        let ext = link.pathExtension.lowercased()
        let site = siteName(link)
        if ext == "m3u8" { throw LinkFetchError.needsMac }   // HLS streams can't be saved with AVFoundation on iPhone
        if mediaExts.contains(ext) {
            return Resolved(media: link, title: titleFromPath(link), site: site, pageURL: link.absoluteString)
        }
        var req = URLRequest(url: link, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LinkFetchError.message("No response from that link.") }
        guard (200..<300).contains(http.statusCode) else { bytes.task.cancel(); throw LinkFetchError.http(http.statusCode) }
        let final = http.url ?? link
        let mime = (http.mimeType ?? "").lowercased()
        let finalExt = final.pathExtension.lowercased()
        if mime == "application/vnd.apple.mpegurl" || mime == "application/x-mpegurl" || finalExt == "m3u8" {
            bytes.task.cancel(); throw LinkFetchError.needsMac
        }
        if mime.hasPrefix("audio/") || mime.hasPrefix("video/") || mediaExts.contains(finalExt) {
            bytes.task.cancel()
            return Resolved(media: final, title: titleFromPath(final), site: site, pageURL: link.absoluteString,
                            ext: mediaExts.contains(finalExt) ? finalExt : extFor(mime: mime))
        }
        // A page or a feed: read it (up to 8 MB; feeds with years of episodes get big).
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > 8_000_000 { bytes.task.cancel(); break }
        }
        if mime.contains("xml") || mime.contains("rss") || looksLikeFeed(data) {
            return try resolveFeed(data, page: link)
        }
        if mime.contains("html"), let r = resolvePage(data, page: final, site: site) { return r }
        throw LinkFetchError.needsMac
    }

    // MARK: Podcasts

    /// podcasts.apple.com/…/id<show>?i=<episode>: the episode's audio from the iTunes Lookup API. A show link
    /// without an episode gets the latest episode.
    private static func resolveApplePodcasts(_ link: URL) async throws -> Resolved {
        guard let show = link.path.range(of: #"id(\d+)"#, options: .regularExpression).map({ String(link.path[$0].dropFirst(2)) }) else {
            throw LinkFetchError.message("That Apple Podcasts link doesn't name a show.")
        }
        let episode = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "i" }?.value
        var results = try await lookup(id: show)
        var item: [String: Any]?
        if let episode {
            item = results.first { "\($0["trackId"] ?? "")" == episode && $0["episodeUrl"] != nil }
            if item == nil {
                // Older than the newest 200 episodes: ask for the episode itself.
                results = (try? await lookup(id: episode)) ?? []
                item = results.first { "\($0["trackId"] ?? "")" == episode && $0["episodeUrl"] != nil }
            }
        } else {
            item = results.filter { $0["episodeUrl"] != nil }
                .max { ($0["releaseDate"] as? String ?? "") < ($1["releaseDate"] as? String ?? "") }
        }
        guard let item, let s = item["episodeUrl"] as? String, let media = URL(string: s) else {
            throw LinkFetchError.message("Couldn't find that episode's audio.")
        }
        let ext = (item["episodeFileExtension"] as? String)?.lowercased()
        return Resolved(media: media, title: item["trackName"] as? String, site: "Apple Podcasts",
                        channel: item["collectionName"] as? String,
                        thumbnail: (item["artworkUrl600"] as? String ?? item["artworkUrl160"] as? String).flatMap(URL.init(string:)),
                        pageURL: link.absoluteString, ext: ext.flatMap { mediaExts.contains($0) ? $0 : nil })
    }

    private static func lookup(id: String) async throws -> [[String: Any]] {
        guard let u = URL(string: "https://itunes.apple.com/lookup?id=\(id)&entity=podcastEpisode&limit=200") else { return [] }
        let (data, resp) = try await URLSession.shared.data(from: u)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) { throw LinkFetchError.http(code) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [[String: Any]] ?? []
    }

    private static func looksLikeFeed(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        return head.contains("<rss") || head.contains("<feed") || head.contains("<channel")
    }

    /// A podcast feed: the latest item with an audio or video enclosure.
    private static func resolveFeed(_ data: Data, page: URL) throws -> Resolved {
        let feed = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = feed
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        guard let item = feed.latest, let media = URL(string: item.enclosure) else {
            throw LinkFetchError.message("That feed has no episodes with audio.")
        }
        return Resolved(media: media, title: item.title ?? feed.channelTitle, site: siteName(page), channel: feed.channelTitle,
                        thumbnail: (item.image ?? feed.channelImage).flatMap(URL.init(string:)), pageURL: page.absoluteString,
                        ext: mediaExts.contains(media.pathExtension.lowercased()) ? nil : item.type.flatMap(extFor(mime:)))
    }

    /// A web page that names its own audio (og:audio, og:video, twitter:player:stream).
    private static func resolvePage(_ data: Data, page: URL, site: String) -> Resolved? {
        let html = String(decoding: data, as: UTF8.self)
        func meta(_ names: [String]) -> String? {
            for n in names {
                let pattern = #"<meta[^>]+(?:property|name)\s*=\s*["']"# + NSRegularExpression.escapedPattern(for: n) + #"["'][^>]*>"#
                guard let r = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
                let tag = String(html[r])
                if let c = tag.range(of: #"content\s*=\s*["']([^"']+)["']"#, options: [.regularExpression, .caseInsensitive]) {
                    let raw = String(tag[c]).replacingOccurrences(of: #"^content\s*=\s*["']"#, with: "", options: [.regularExpression, .caseInsensitive]).dropLast()
                    return String(raw).replacingOccurrences(of: "&amp;", with: "&")
                }
            }
            return nil
        }
        guard let src = meta(["og:audio:secure_url", "og:audio:url", "og:audio", "og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"]),
              let media = URL(string: src, relativeTo: page)?.absoluteURL else { return nil }
        let ext = media.pathExtension.lowercased()
        // A player page or a stream isn't a file this iPhone can download.
        guard mediaExts.contains(ext) || meta(["og:audio:type", "og:video:type"])?.lowercased().hasPrefix("audio/") == true else { return nil }
        return Resolved(media: media, title: meta(["og:title", "twitter:title"]).map(decodeEntities), site: meta(["og:site_name"]) ?? site,
                        thumbnail: meta(["og:image:secure_url", "og:image"]).flatMap { URL(string: $0, relativeTo: page)?.absoluteURL },
                        pageURL: page.absoluteString, ext: mediaExts.contains(ext) ? nil : "mp3")
    }

    // MARK: Vimeo

    /// vimeo.com/<id> (and unlisted vimeo.com/<id>/<hash>, player.vimeo.com/video/<id>).
    static func vimeoID(_ u: URL) -> (id: String, hash: String?)? {
        let host = (u.host ?? "").lowercased()
        guard host == "vimeo.com" || host.hasSuffix(".vimeo.com") else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(where: { $0.count >= 6 && $0.allSatisfy(\.isNumber) }) else { return nil }
        let hash = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "h" }?.value
            ?? (parts.count > i + 1 && parts[i + 1].allSatisfy(\.isHexDigit) ? parts[i + 1] : nil)
        return (parts[i], hash)
    }

    /// The public player config: a progressive MP4 when Vimeo offers one. HLS-only videos need the Mac.
    private static func resolveVimeo(_ link: URL, id: String, hash: String?) async throws -> Resolved {
        var s = "https://player.vimeo.com/video/\(id)/config"
        if let hash { s += "?h=\(hash)" }
        guard let u = URL(string: s) else { throw LinkFetchError.needsMac }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://vimeo.com/", forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LinkFetchError.needsMac }
        let files = (json["request"] as? [String: Any])?["files"] as? [String: Any]
        let progressive = (files?["progressive"] as? [[String: Any]] ?? []).filter { $0["url"] is String }
        // The smallest file: the audio is the same in every size.
        guard let pick = progressive.min(by: { ($0["width"] as? Int ?? .max) < ($1["width"] as? Int ?? .max) }),
              let media = (pick["url"] as? String).flatMap(URL.init(string:)) else { throw LinkFetchError.needsMac }
        let video = json["video"] as? [String: Any]
        let thumbs = video?["thumbs"] as? [String: Any]
        let thumb = (thumbs?["640"] ?? thumbs?["base"] ?? thumbs?.values.first) as? String
        return Resolved(media: media, title: video?["title"] as? String, site: "Vimeo",
                        channel: (video?["owner"] as? [String: Any])?["name"] as? String,
                        thumbnail: thumb.flatMap(URL.init(string:)), pageURL: link.absoluteString, ext: "mp4")
    }

    // MARK: YouTube

    /// The video ID in a YouTube link: watch?v=, youtu.be/, /shorts/, /live/, /embed/, music.youtube.com.
    static func youTubeID(_ u: URL) -> String? {
        let host = (u.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let parts = u.path.split(separator: "/").map(String.init)
        var id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" {
            if let v = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { id = v }
            else if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0]) { id = parts[1] }
        }
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    #if YOUTUBE_ON_DEVICE
    /// YouTubeKit, extracting on this iPhone only (no remote fallback, so nothing goes to a third-party server).
    /// Picks the best audio-only M4A stream, which AVFoundation reads as is.
    private static func resolveYouTube(_ link: URL) async throws -> Resolved {
        guard let id = youTubeID(link) else { throw LinkFetchError.needsMac }
        let video = YouTube(videoID: id, methods: [.local])
        let streams: [YouTubeKit.Stream]
        do { streams = try await video.streams } catch {
            Log.note("YouTubeKit streams failed: \(error)")
            throw LinkFetchError.message("YouTube didn't hand over this video's audio. It may be private, age-restricted, or a live stream.")
        }
        let audio = streams.filterAudioOnly()
        guard let pick = audio.filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream()
                ?? streams.filterVideoAndAudio().filter({ $0.fileExtension == .mp4 }).lowestResolutionStream() else {
            throw LinkFetchError.message("This YouTube video has no audio Verbatim can read.")
        }
        let meta = try? await video.metadata
        return Resolved(media: pick.url, title: meta?.title, site: "YouTube", thumbnail: meta?.thumbnail?.url,
                        pageURL: "https://www.youtube.com/watch?v=\(id)", ext: pick.fileExtension == .m4a ? "m4a" : "mp4", chunked: true)
    }
    #endif

    // MARK: Downloading

    /// Downloads the media into Paths.downloads (local, never synced). Progress is 0…1, or nil when the size is unknown.
    static func download(_ r: Resolved, progress report: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let gate = PercentGate(report)
        let progress: @Sendable (Double?) -> Void = { gate.send($0) }
        try FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        let urlExt = r.media.pathExtension.lowercased()
        let ext = r.ext ?? (mediaExts.contains(urlExt) ? urlExt : "mp4")
        let dest = Paths.downloads.appendingPathComponent("link-\(UUID().uuidString).\(ext)")
        if r.chunked {
            try await downloadChunked(r.media, to: dest, progress: progress)
        } else {
            var req = URLRequest(url: r.media, timeoutInterval: 60)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            try await Downloader(dest: dest, progress: progress).run(req)
        }
        return dest
    }

    /// Ranged requests of 8 MB each, appended to one file.
    private static func downloadChunked(_ url: URL, to dest: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        let chunk = 8 * 1024 * 1024
        var offset = 0
        var total: Int?
        do {
            while total.map({ offset < $0 }) ?? true {
                try Task.checkCancellation()
                var req = URLRequest(url: url, timeoutInterval: 60)
                req.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw LinkFetchError.message("No response from the server.") }
                guard http.statusCode == 200 || http.statusCode == 206 else { throw LinkFetchError.http(http.statusCode) }
                if total == nil {
                    if http.statusCode == 200 { total = data.count }
                    else if let cr = http.value(forHTTPHeaderField: "Content-Range"), let t = cr.split(separator: "/").last.flatMap({ Int($0) }) { total = t }
                }
                if data.isEmpty { break }
                try handle.write(contentsOf: data)
                offset += data.count
                progress(total.map { min(1, Double(offset) / Double(max(1, $0))) })
                if http.statusCode == 200 { break }   // the server sent everything at once
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    /// The link's thumbnail, saved into Paths.thumbs (synced, like the Mac's). Returns the file name.
    static func saveThumbnail(_ remote: URL, as name: String) async -> String? {
        guard let (data, resp) = try? await URLSession.shared.data(from: remote),
              (resp as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else { return nil }
        let ext = ["jpg", "jpeg", "png", "webp"].contains(remote.pathExtension.lowercased()) ? remote.pathExtension.lowercased() : "jpg"
        let file = name + "." + ext
        do {
            try FileManager.default.createDirectory(at: Paths.thumbs, withIntermediateDirectories: true)
            try data.write(to: Paths.thumbs.appendingPathComponent(file)); return file
        } catch { return nil }
    }

    // MARK: Helpers

    static let mediaExts: Set<String> = ["mp3", "m4a", "wav", "aac", "aif", "aiff", "caf", "flac", "mp4", "m4v", "mov"]
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func extFor(mime: String) -> String? {
        switch mime.lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }) ?? "" {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac", "audio/aacp": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/flac", "audio/x-flac": return "flac"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        default: return nil
        }
    }

    /// The site as people say it.
    static func siteName(_ u: URL) -> String {
        let host = (u.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        if host.contains("youtu") { return "YouTube" }
        if host.contains("vimeo") { return "Vimeo" }
        if host == "podcasts.apple.com" { return "Apple Podcasts" }
        return host
    }

    private static func titleFromPath(_ u: URL) -> String? {
        let name = u.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? u.deletingPathExtension().lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// Why a link couldn't be fetched on the iPhone.
enum LinkFetchError: LocalizedError {
    /// The site needs the Mac's yt-dlp helper (or this build has YouTube switched off).
    case needsMac
    case http(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .needsMac: return "This site needs your Mac to fetch it."
        case .http(let code):
            switch code {
            case 401, 403: return "The site didn't allow the download (error \(code))."
            case 404, 410: return "Nothing is at that link anymore (error \(code))."
            default: return "The site returned error \(code)."
            }
        case .message(let s): return s
        }
    }
}

/// Passes progress on only when the whole percent changes (downloads report many times a second).
private final class PercentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Int.min
    private let forward: @Sendable (Double?) -> Void
    init(_ forward: @escaping @Sendable (Double?) -> Void) { self.forward = forward }
    func send(_ fraction: Double?) {
        let pct = fraction.map { Int($0 * 100) } ?? -1
        lock.lock()
        let changed = pct != last
        last = pct
        lock.unlock()
        if changed { forward(fraction) }
    }
}

/// One URLSession download with progress, as an async call that stops when its Task is cancelled.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(dest: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.dest = dest; self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); continuation = c; lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so it moves now.
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            lock.lock(); failure = LinkFetchError.http(code); lock.unlock(); return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            lock.lock(); failure = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation; continuation = nil
        let err = error ?? failure
        lock.unlock()
        if let err {
            try? FileManager.default.removeItem(at: dest)
            if (err as? URLError)?.code == .cancelled { c?.resume(throwing: CancellationError()) } else { c?.resume(throwing: err) }
        } else {
            c?.resume()
        }
    }
}

/// Reads a podcast feed: the channel's title and artwork, and the newest item that has an enclosure.
private final class FeedParser: NSObject, XMLParserDelegate {
    struct Item { var title: String?; var enclosure: String; var type: String?; var image: String?; var date: Date? }
    private(set) var channelTitle: String?
    private(set) var channelImage: String?
    private var items: [Item] = []
    private var inItem = false
    private var text = ""
    private var itemTitle: String?, itemEnclosure: String?, itemType: String?, itemImage: String?, itemDate: Date?
    private var inChannelImage = false

    private static let dates: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"].map {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = $0; return f
    }

    /// Newest by date when every item has one; otherwise the first (feeds list newest first).
    var latest: Item? {
        if !items.isEmpty, items.allSatisfy({ $0.date != nil }) { return items.max { $0.date! < $1.date! } }
        return items.first
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        let n = name.lowercased()
        switch n {
        case "item", "entry":
            inItem = true; itemTitle = nil; itemEnclosure = nil; itemType = nil; itemImage = nil; itemDate = nil
        case "enclosure":
            if inItem, itemEnclosure == nil, let u = attributes["url"] { itemEnclosure = u; itemType = attributes["type"] }
        case "link":
            // Atom: <link rel="enclosure" href="…" type="audio/mpeg"/>
            if inItem, attributes["rel"] == "enclosure", itemEnclosure == nil, let u = attributes["href"] { itemEnclosure = u; itemType = attributes["type"] }
        case "itunes:image":
            if let h = attributes["href"] { if inItem { itemImage = h } else if channelImage == nil { channelImage = h } }
        case "image":
            if !inItem { inChannelImage = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "title":
            if inItem { if itemTitle == nil, !value.isEmpty { itemTitle = value } }
            else if channelTitle == nil, !inChannelImage, !value.isEmpty { channelTitle = value }
        case "url":
            if inChannelImage, channelImage == nil, !value.isEmpty { channelImage = value }
        case "image":
            inChannelImage = false
        case "pubdate", "published", "updated":
            if inItem, itemDate == nil { itemDate = Self.dates.lazy.compactMap { $0.date(from: value) }.first }
        case "item", "entry":
            if let e = itemEnclosure, itemType.map({ $0.hasPrefix("audio") || $0.hasPrefix("video") }) ?? true {
                items.append(Item(title: itemTitle, enclosure: e, type: itemType, image: itemImage, date: itemDate))
            }
            inItem = false
        default: break
        }
        text = ""
    }
}
