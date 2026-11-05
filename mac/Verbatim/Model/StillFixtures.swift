#if VERBOSE_SELFTEST
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// Self-test builds only: the stills viewer's fixture for both apps' tours (App/UITest.swift, PhoneUITest.swift). A
/// short transcript, "Slide review", with three slide stills as real JPEGs in the thumbs folder and a silent recording,
/// so the viewer opens on pictures with text (Live Text has something to find) and Play from here is live. Made-up
/// words, no names. `remove` deletes the transcript with its stills and audio.
@MainActor
enum StillFixtures {
    static let title = "Slide review"

    /// Each slide's moment, heading, and bullets.
    static let slides: [(at: Double, heading: String, lines: [String])] = [
        (0, "Quarterly roadmap", ["Ship the stills viewer", "Tidy the transcript margin", "Plan the next release"]),
        (30, "Launch checklist", ["Screenshots for review", "Release notes drafted", "Accessibility pass"]),
        (60, "Open questions", ["How many stills a call keeps", "Stills on iPhone", "Search inside slide text"]),
    ]

    /// Adds the transcript and its files, and returns its id (the one already there, when a tour runs twice).
    static func add(to store: Store) -> UUID {
        if let t = store.transcripts.first(where: { $0.title == title }) { return t.id }
        let audio = silentAudio(seconds: 90)
        var t = Transcript(title: title, source: .voiceMemo, sourceLabel: "Voice memo", duration: 90, audioFileName: audio, model: "Parakeet TDT v3")
        t.segments = [
            Segment(start: 0, end: 12, text: "Let's start with the roadmap for the quarter."),
            Segment(start: 12, end: 30, text: "The viewer comes first, then the margin gets a tidy pass."),
            Segment(start: 30, end: 45, text: "Here's the checklist we use before every launch."),
            Segment(start: 45, end: 60, text: "Screenshots go to review, and the notes get drafted early."),
            Segment(start: 60, end: 75, text: "A few questions are still open."),
            Segment(start: 75, end: 90, text: "We'll pick those up next week."),
        ]
        t.original = t.segments
        try? FileManager.default.createDirectory(at: Paths.thumbs, withIntermediateDirectories: true)
        var stills: [VideoStill] = []
        for (i, slide) in slides.enumerated() {
            let file = "uitest-slide-\(i + 1)-\(t.id.uuidString.prefix(8)).jpg"
            if let data = jpeg(heading: slide.heading, lines: slide.lines) {
                try? data.write(to: Paths.thumbs.appendingPathComponent(file))
                stills.append(VideoStill(at: slide.at, file: file, aspect: 16.0 / 9))
            }
        }
        t.stills = stills
        store.add(t)
        return t.id
    }

    /// Deletes the transcript, its stills, and its audio.
    static func remove(from store: Store) {
        for t in store.transcripts where t.title == title { store.delete(t) }
    }

    /// A 1,280 by 720 slide: a heading and three bullets in dark gray on white, as a JPEG.
    private static func jpeg(heading: String, lines: [String]) -> Data? {
        let w = 1280, h = 720
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 96, y: h - 228, width: 120, height: 8))
        func draw(_ text: String, size: CGFloat, bold: Bool, x: CGFloat, y: CGFloat) {
            let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        draw(heading, size: 72, bold: true, x: 96, y: CGFloat(h) - 180)
        for (i, line) in lines.enumerated() {
            draw("•  " + line, size: 40, bold: false, x: 112, y: CGFloat(h) - 330 - CGFloat(i) * 80)
        }
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// A silent 16 kHz recording in the audio folder, so the player opens and Play from here works. Its name, or nil.
    private static func silentAudio(seconds: Int) -> String? {
        try? FileManager.default.createDirectory(at: Paths.audio, withIntermediateDirectories: true)
        let name = "uitest-slide-review-\(UUID().uuidString.prefix(8)).caf"
        let url = Paths.audio.appendingPathComponent(name)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        if let data = buffer.int16ChannelData { memset(data[0], 0, Int(buffer.frameLength) * 2) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        } catch { return nil }
        return name
    }
}
#endif
