import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Stills from an imported video for the transcript's margin (VideoStill in Model/Transcript.swift; mockup "Verbose
/// Video Stills", option B). On this device: samples small gray frames across the video, keeps one where the picture
/// changes (`VideoStill.pick`), and saves each kept moment as a small JPEG in Paths.thumbs, which syncs with the
/// library. A file with no video track gets none. Shared by the Mac and the iPhone.
enum VideoStills {
    /// The longest side of a saved still, in pixels: about three times the 44 pt margin still on iPhone.
    static let stillPixels: CGFloat = 360

    /// The stills for transcript `id` from the video at `url`, in time order, or [] when it has no picture or can't be
    /// read. Takes a few seconds for a short video; runs off the main thread.
    static func capture(from url: URL, id: UUID) async -> [VideoStill] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return [] }
        let aspect = await shape(track)
        let samples = await gray(asset, times: VideoStill.sampleTimes(duration: duration))
        let times = VideoStill.pick(samples)
        guard !times.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: Paths.thumbs, withIntermediateDirectories: true)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: stillPixels, height: stillPixels)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        var out: [VideoStill] = []
        for at in times {
            guard let image = try? await gen.image(at: CMTime(seconds: at, preferredTimescale: 600)).image,
                  let data = jpeg(image) else { continue }
            let file = "still-\(id.uuidString)-\(Int((at * 1000).rounded())).jpg"
            do { try data.write(to: Paths.thumbs.appendingPathComponent(file), options: .atomic) } catch { continue }
            out.append(VideoStill(at: at, file: file, aspect: aspect))
        }
        Log.note("stills: \(out.count) from \(samples.count) samples over \(Int(duration)) s")
        return out
    }

    /// Width over height as the video plays, its rotation included.
    private static func shape(_ track: AVAssetTrack) async -> Double {
        guard let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) else { return 9.0 / 16 }
        let r = CGRect(origin: .zero, size: size).applying(t)
        return r.height > 0 ? Double(abs(r.width) / abs(r.height)) : 9.0 / 16
    }

    /// A 16 by 16 gray frame at each time, for comparing pictures.
    private static func gray(_ asset: AVAsset, times: [Double]) async -> [VideoStill.Sample] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 48, height: 48)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        var out: [VideoStill.Sample] = []
        for await result in gen.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            guard let image = try? result.image, let g = grid(image) else { continue }
            out.append(VideoStill.Sample(at: result.requestedTime.seconds, gray: g))
        }
        return out
    }

    /// The image drawn into 16 by 16 gray pixels.
    static func grid(_ image: CGImage) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: 256)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        return ok ? px : nil
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.74] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
