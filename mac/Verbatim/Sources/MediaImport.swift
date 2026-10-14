import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Turns whatever someone drops or picks into an audio file Verbatim can transcribe.
enum MediaImport {
    static let audioExts: Set<String> = ["wav", "m4a", "mp3", "aif", "aiff", "caf", "flac", "aac", "ogg", "opus"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "3gp"]

    /// Files as given, plus every media file inside any folder (recursively), in name order.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
                out += items.filter { isMedia($0) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if isMedia(u) {
                out.append(u)
            }
        }
        return out
    }

    static func isMedia(_ u: URL) -> Bool {
        let e = u.pathExtension.lowercased()
        if audioExts.contains(e) || videoExts.contains(e) { return true }
        if let t = UTType(filenameExtension: e) { return t.conforms(to: .audio) || t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) }
        return false
    }

    struct Prepared { let url: URL; let duration: Double }

    /// Audio files are copied as they are. Anything with video has its audio track exported to M4A (no video kept).
    static func prepare(_ src: URL, into m4aDest: URL) async throws -> Prepared {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: src)
        let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        guard hasAudio else { throw err("“\(src.lastPathComponent)” has no audio track Verbatim can read.") }
        let ext = src.pathExtension.lowercased()
        let dest: URL
        if !hasVideo && audioExts.contains(ext) {
            dest = m4aDest.deletingPathExtension().appendingPathExtension(ext)
            try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: src, to: dest) }.value
        } else {
            dest = m4aDest
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw err("Couldn't read the audio in “\(src.lastPathComponent)”.") }
            session.outputURL = dest
            session.outputFileType = .m4a
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed: c.resume()
                    default: c.resume(throwing: session.error ?? err("Couldn't extract the audio from “\(src.lastPathComponent)”."))
                    }
                }
            }
        }
        let d = (try? await AVURLAsset(url: dest).load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard d > 0 else { try? FileManager.default.removeItem(at: dest); throw err("“\(src.lastPathComponent)” has no audio Verbatim can read.") }
        return Prepared(url: dest, duration: d)
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "Verbatim", code: 3, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// Gathers file URLs from several drag providers, then calls back once on the main thread.
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let done: ([URL]) -> Void
    init(expected: Int, done: @escaping ([URL]) -> Void) { remaining = expected; self.done = done }
    func add(_ u: URL?) {
        lock.lock()
        if let u { urls.append(u) }
        remaining -= 1
        let finished = remaining == 0
        let all = urls
        lock.unlock()
        if finished { DispatchQueue.main.async { self.done(all) } }
    }
}
