import Foundation
import AVFoundation
import AppKit

/// Keep: save a link's video (MP4) or audio (M4A) to a folder you choose, and grab stills from video you have.
/// Video comes down as separate H.264 and AAC streams and is joined by AVFoundation without re-encoding,
/// so no FFmpeg is involved.
enum Keep {
    static let folderKey = "keepFolder"
    static var folder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: folderKey) { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Verbatim", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: folderKey) }
    }

    /// A file name from a title, unique in the Keep folder.
    static func destination(title: String, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var base = title.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Verbatim" }
        if base.count > 120 { base = String(base.prefix(120)) }
        var name = base, n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).\(ext)").path) { name = "\(base) \(n)"; n += 1 }
        return folder.appendingPathComponent("\(name).\(ext)")
    }

    /// Downloads the video of a link and returns the merged MP4 in the Keep folder.
    static func video(link: String, title: String, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let parts = try await LinkFetcher.downloadStreams(link, progress: progress)
        let out = try destination(title: title, ext: "mp4")
        progress("Saving video")
        if let audio = parts.audio {
            try await merge(video: parts.video, audio: audio, to: out)
            try? FileManager.default.removeItem(at: parts.video)
            try? FileManager.default.removeItem(at: audio)
        } else {
            // One file that already carries its sound (Vimeo, X, progressive MP4).
            let ext = parts.video.pathExtension.lowercased()
            let target = ext == "mp4" ? out : out.deletingPathExtension().appendingPathExtension(ext)
            try FileManager.default.moveItem(at: parts.video, to: target)
            return target
        }
        return out
    }

    /// Joins a video-only and an audio-only file into one MP4, passthrough (no re-encode).
    static func merge(video: URL, audio: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let va = AVURLAsset(url: video), aa = AVURLAsset(url: audio)
        guard let vt = try await va.loadTracks(withMediaType: .video).first else { throw err("The download had no video track.") }
        let duration = try await va.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try cv?.insertTimeRange(range, of: vt, at: .zero)
        cv?.preferredTransform = try await vt.load(.preferredTransform)
        if let at = try await aa.loadTracks(withMediaType: .audio).first {
            let ad = try await aa.load(.duration)
            let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try ca?.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(ad, duration)), of: at, at: .zero)
        }
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw err("Couldn't join the video and audio.") }
        ex.outputURL = out
        ex.outputFileType = .mp4
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            ex.exportAsynchronously {
                if ex.status == .completed { c.resume() } else { c.resume(throwing: ex.error ?? err("Couldn't save the video.")) }
            }
        }
    }

    /// A JPEG still at `seconds`, saved in Paths.thumbs. Returns the file name.
    static func frame(from video: URL, at seconds: Double, name: String) async -> String? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 960)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        guard let result = try? await gen.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) else { return nil }
        let rep = NSBitmapImageRep(cgImage: result.image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        let file = "frame-\(name).jpg"
        do { try data.write(to: Paths.thumbs.appendingPathComponent(file)); return file } catch { return nil }
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "Verbatim", code: 20, userInfo: [NSLocalizedDescriptionKey: s]) }
}
