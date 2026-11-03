import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import Vision

/// Stills of shared screens (November 3, 2026, mockup "Verbose Call Recording", board 8). Settings › Meetings › Keep
/// stills of shared screens, off by default, needs Screen Recording. While a call records with it on, the call app's
/// largest window is captured every 2 seconds (ScreenCaptureKit's screenshot, no stream and no sound); a frame that
/// differs enough from the last one kept is measured with the Mac's own text and face detection (Vision), and kept
/// when it looks like a shared screen or slide (`CallStillRules`, tested on Linux). Kept frames are JPEGs in the thumbs
/// folder, the same as an imported video's stills (`VideoStill`), timed to the recording, so they show in the
/// transcript's margin and are deleted with it. Nothing leaves the Mac.
@MainActor
final class CallStillCapture {
    static let enabledKey = "meetings.stills"
    /// Settings › Meetings › Keep stills of shared screens. Off by default.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// Screen Recording is allowed (System Settings › Privacy & Security › Screen & System Audio Recording).
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }
    /// On and allowed: stills are kept, so the consent sheet and the chat notice say so.
    static var active: Bool { enabled && allowed }

    /// The longest side of a kept still, in pixels: enough to read a slide when it's opened full size.
    static let stillPixels: CGFloat = 1280
    /// The longest side of a captured frame (the comparison and Vision don't need more).
    static let framePixels: CGFloat = 1440

    /// The stills kept so far, in time order.
    private(set) var stills: [MeetingStill] = []
    /// Called on the main actor when a still is kept (the session writes its sidecar).
    var onKept: (([MeetingStill]) -> Void)?

    private let bundleID: String
    private let sessionID: UUID
    private let elapsed: () -> Double
    private let paused: () -> Bool
    private var timer: Timer?
    private var busy = false
    private var last: (gray: [UInt8], at: Double)?
    private var window: SCWindow?
    private var windowCheckedAt: Double = -100
    private var loggedNoWindow = false

    /// `bundleID`: the call app's (helpers and windows match by prefix). `elapsed`: seconds into the recording, pauses
    /// left out. `paused`: nothing is captured while the recording is paused.
    init(bundleID: String, sessionID: UUID, elapsed: @escaping () -> Double, paused: @escaping () -> Bool) {
        self.bundleID = bundleID.lowercased()
        self.sessionID = sessionID
        self.elapsed = elapsed
        self.paused = paused
    }

    func start() {
        guard timer == nil else { return }
        Log.note("meeting stills: looking at the call window every \(Int(CallStillRules.interval)) s")
        timer = Timer.scheduledTimer(withTimeInterval: CallStillRules.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops looking; returns the stills kept.
    func stop() -> [MeetingStill] {
        timer?.invalidate(); timer = nil
        Log.note("meeting stills: \(stills.count) kept")
        return stills
    }

    private func tick() {
        guard !busy, !paused(), stills.count < CallStillRules.limit else { return }
        busy = true
        let at = elapsed()
        Task { await capture(at: at); busy = false }
    }

    private func capture(at: Double) async {
        guard let w = await callWindow() else { return }
        let scale = min(1, Self.framePixels / max(1, max(w.frame.width * 2, w.frame.height * 2)))
        let config = SCStreamConfiguration()
        config.width = max(64, Int(w.frame.width * 2 * scale))
        config.height = max(64, Int(w.frame.height * 2 * scale))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config),
              let gray = VideoStills.grid(image) else { return }
        guard CallStillRules.changed(gray: gray, at: at, last: last, kept: stills.count) else { return }
        let measure = await Task.detached(priority: .utility) { Self.measure(image) }.value
        guard CallStillRules.keep(gray: gray, at: at, measure: measure, last: last, kept: stills.count) else { return }
        let file = "still-\(sessionID.uuidString)-\(Int((at * 1000).rounded())).jpg"
        let aspect = Double(image.width) / Double(max(1, image.height))
        let saved = await Task.detached(priority: .utility) { Self.save(image, as: file) }.value
        guard saved else { return }
        last = (gray, at)
        stills.append(MeetingStill(at: at, file: file, aspect: aspect))
        Log.note("meeting stills: kept one at \(Int(at)) s (\(measure.characters) characters, \(measure.faces) faces)")
        onKept?(stills)
    }

    /// The call app's largest on-screen window, looked up again every 10 seconds (a window opened for screen sharing).
    private func callWindow() async -> SCWindow? {
        let now = ProcessInfo.processInfo.systemUptime
        if let window, now - windowCheckedAt < 10 { return window }
        windowCheckedAt = now
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            window = nil
            return nil
        }
        let mine = content.windows.filter { w in
            guard let id = w.owningApplication?.bundleIdentifier.lowercased() else { return false }
            return w.windowLayer == 0 && (id == bundleID || id.hasPrefix(bundleID + "."))
        }
        let pick = CallStillRules.pickWindow(mine.map { (id: $0.windowID, width: Double($0.frame.width), height: Double($0.frame.height), onScreen: $0.isOnScreen) })
        window = mine.first { $0.windowID == pick }
        if window == nil, !loggedNoWindow { loggedNoWindow = true; Log.note("meeting stills: no call window on screen to look at") }
        if window != nil { loggedNoWindow = false }
        return window
    }

    /// What Vision finds in a frame: recognized text (fast, no language correction) and faces.
    nonisolated private static func measure(_ image: CGImage) -> CallStillRules.Measure {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([text, faces])
        let lines = text.results ?? []
        let chars = lines.reduce(0) { $0 + ($1.topCandidates(1).first?.string.count ?? 0) }
        let textCover = lines.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
        let found = faces.results ?? []
        let faceCover = found.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
        return CallStillRules.Measure(characters: chars, textCover: min(1, textCover), faces: found.count, faceCover: min(1, faceCover))
    }

    /// The frame as a JPEG in the thumbs folder, at most `stillPixels` on its longest side.
    nonisolated private static func save(_ image: CGImage, as file: String) -> Bool {
        let longest = CGFloat(max(image.width, image.height))
        var out = image
        if longest > stillPixels {
            let s = stillPixels / longest
            let w = Int(CGFloat(image.width) * s), h = Int(CGFloat(image.height) * s)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let small = ctx.makeImage() { out = small }
            }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        do {
            try FileManager.default.createDirectory(at: Paths.thumbs, withIntermediateDirectories: true)
            try (data as Data).write(to: Paths.thumbs.appendingPathComponent(file), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
