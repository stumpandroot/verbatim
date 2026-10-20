import Foundation
import Combine
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// One link on its way into the Library: what the source says about itself and how far along the fetch is.
/// A "link added" view can observe it on either platform; the iPhone drives it from `PhoneLinkFetcher`.
/// It holds no platform types, so the Mac can drive the same object later.
@MainActor
final class LinkImport: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// Working out what the link points at (the page, the feed, the stream).
        case resolving
        /// Downloading the audio; `progress` moves from 0 to 1.
        case downloading
        /// The audio is in the Library and waiting for (or in) the transcription queue.
        case queued
        /// Handed to the Mac, which fetches the audio the next time it's open.
        case waitingForMac
        /// Stopped with a message you can show as is.
        case failed(String)
    }

    /// The transcript this link fills in.
    let id: UUID
    /// The link as pasted.
    let url: String
    @Published var title: String?
    /// The site as people say it: "YouTube", "Vimeo", "Apple Podcasts", or the host name.
    @Published var site: String?
    @Published var thumbnailURL: URL?
    /// 0…1 while downloading; nil when the size isn't known yet.
    @Published var progress: Double?
    /// Seconds, once the source says (yt-dlp's metadata) or the audio is prepared.
    @Published var duration: TimeInterval?
    @Published var phase: Phase = .resolving

    init(id: UUID, url: String, site: String? = nil) {
        self.id = id; self.url = url; self.site = site
    }

    var isFinished: Bool {
        switch phase {
        case .queued, .waitingForMac, .failed: return true
        case .resolving, .downloading: return false
        }
    }
}

// MARK: - Thumbnails before the metadata

extension LinkImport {
    /// The video ID in a YouTube link: watch?v=, youtu.be/, /shorts/, /live/, /embed/, music.youtube.com.
    nonisolated static func youTubeID(_ u: URL) -> String? {
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

    /// A thumbnail that's known from the link alone, before anything is fetched: YouTube's, from the video ID.
    nonisolated static func quickThumbnail(_ u: URL) -> URL? {
        youTubeID(u).flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg") }
    }

    /// The site as people say it, from the link alone.
    nonisolated static func siteName(_ u: URL) -> String {
        let host = (u.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        if host.contains("youtu") { return "YouTube" }
        if host.contains("vimeo") { return "Vimeo" }
        if host == "podcasts.apple.com" { return "Apple Podcasts" }
        return host
    }

    /// A still from a downloaded video file (a direct link to an MP4 or MOV), saved into Paths.thumbs as a JPEG.
    /// Returns the file name, or nil for audio-only files and anything that can't be read.
    nonisolated static func saveFrameThumbnail(from file: URL, as name: String) async -> String? {
        let asset = AVURLAsset(url: file)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 960)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let at = CMTime(seconds: seconds.isFinite && seconds > 4 ? min(seconds * 0.1, 30) : 0, preferredTimescale: 600)
        guard let image = try? await gen.image(at: at).image else { return nil }
        let out = name + ".jpg"
        let url = Paths.thumbs.appendingPathComponent(out)
        try? FileManager.default.createDirectory(at: Paths.thumbs, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out : nil
    }
}
