import SwiftUI
import AppKit
import AVFoundation
import Combine

/// Live captions on the Mac: a floating panel of live words from the microphone, an app's audio, or both.
/// The audio is recorded the whole time (the microphone through its own `Recorder`, an app through its own
/// `AppAudioCapture`), so "Save as transcript" hands the main engine the full recording, mixed when there are two
/// sources. Closing without saving deletes it. Two `LiveTranscriber`s run side by side for "both".
@MainActor
final class LiveCaptions: ObservableObject {
    static let shared = LiveCaptions()

    enum Source: Equatable {
        case mic
        case app(id: String, name: String)
        case both(id: String, name: String)

        var appID: String? { switch self { case .mic: return nil; case .app(let id, _), .both(let id, _): return id } }
        var appName: String? { switch self { case .mic: return nil; case .app(_, let n), .both(_, let n): return n } }
        var usesMic: Bool { if case .app = self { return false }; return true }

        /// "MICROPHONE", "ZOOM", "ZOOM + MIC" (the header) and "Microphone", "Zoom", "Zoom + Mic" (the chip).
        var title: String {
            switch self {
            case .mic: return "Microphone"
            case .app(_, let n): return n
            case .both(_, let n): return "\(n) + Mic"
            }
        }

        fileprivate var saved: String {
            switch self { case .mic: return "mic"; case .app(let id, let n): return "app\t\(id)\t\(n)"; case .both(let id, let n): return "both\t\(id)\t\(n)" }
        }
        fileprivate init?(saved: String) {
            let p = saved.components(separatedBy: "\t")
            switch (p.first, p.count) {
            case ("mic", _): self = .mic
            case ("app", 3): self = .app(id: p[1], name: p[2])
            case ("both", 3): self = .both(id: p[1], name: p[2])
            default: return nil
            }
        }
    }

    /// One recorded file and where it starts in its piece.
    struct Track: Sendable { var url: URL; var offset: TimeInterval }

    @Published private(set) var isOpen = false
    @Published private(set) var source: Source = .mic
    @Published private(set) var startedAt = Date()
    /// A short line under the captions: getting ready, not available, a capture that failed, saved.
    @Published private(set) var status: String?
    /// Close was pressed with more than a few seconds recorded: the controls ask Discard or Save.
    @Published var confirmingClose = false
    @Published private(set) var saving = false
    @Published private(set) var runningApps: [AppAudioCapture.RunningApp] = []
    @Published private(set) var language = CaptionLanguage.current

    let feed = CaptionFeed()
    let micWords = LiveTranscriber()
    let appWords = LiveTranscriber()
    private let recorder = Recorder()
    private let capture = AppAudioCapture()
    private weak var app: AppState?
    private var panel: LiveCaptionsPanel?

    /// Finished pieces (a source change ends one); each is mixed, then the pieces are joined in order.
    private var pieces: [[Track]] = []
    private var micStart: Date?
    private var micURL: URL?
    private var appStart: Date?
    private var appURL: URL?
    private var pieceCount = 0
    /// Set while this controller stops the app capture itself (so it isn't reported as the app's audio ending).
    private var stoppingApp = false
    /// Source changes, starts, stops, and saves run one after another.
    private var work: Task<Void, Never>?
    private var ticker: Timer?
    private var retries = 0
    private var bag = Set<AnyCancellable>()
    private static let sourceKey = "captions.source"

    private init() {
        feed.maxLineLength = 140
        feed.onFinished = { CaptionPermission.announce($0) }
        // Lower other audio only when captioning the microphone: never with app audio, which is what's being captioned.
        AudioDucker.shared.follow(.captions, recorder.$isRecording.combineLatest(recorder.$isPaused, recorder.$isStarting, $source).map { $0.0 && !$0.1 && !$0.2 && $0.3 == Source.mic })
        recorder.onInputSwitched = { [weak self] note in self?.status = note }
        micWords.$words.sink { [weak self] w in self?.feed.update("mic", words: w) }.store(in: &bag)
        appWords.$words.sink { [weak self] w in self?.feed.update("app", words: w) }.store(in: &bag)
        // App audio can end on its own (the app quit): say so, and keep what was recorded.
        capture.$isCapturing.dropFirst().sink { [weak self] on in
            guard let self, !on, self.isOpen, self.appURL != nil, !self.saving, !self.stoppingApp else { return }
            Task { @MainActor in
                guard self.appURL != nil, !self.stoppingApp else { return }
                self.status = "\(self.source.appName ?? "The app")'s audio stopped. Pick a source to keep captioning."
            }
        }.store(in: &bag)
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    var showsSpeakers: Bool { if case .both = source { return true }; return false }

    // MARK: Open and close

    func toggle(app: AppState) { isOpen ? close() : open(app: app) }

    func open(app: AppState) {
        self.app = app
        guard !isOpen else { panel?.show(); return }
        isOpen = true
        confirmingClose = false
        status = nil
        startedAt = Date()
        feed.reset()
        language = CaptionLanguage.current
        if panel == nil { panel = LiveCaptionsPanel(controller: self) }
        panel?.show()
        if UITest.enabled { seedForScreenshots(); return }
        source = Source(saved: UserDefaults.standard.string(forKey: Self.sourceKey) ?? "") ?? .mic
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        micWords.locale = CaptionLanguage.locale
        appWords.locale = CaptionLanguage.locale
        chain { [weak self] in
            await CaptionPermission.ensureSpeech()
            guard let self else { return }
            // Listing apps asks for Screen & System Audio Recording, so only when the saved source is an app.
            // A saved app that isn't running any more: captions start on the microphone.
            if let id = self.source.appID {
                await self.refreshApps()
                if !self.runningApps.contains(where: { $0.id == id }) { self.source = .mic }
            }
            await self.startPiece()
        }
    }

    /// Close. With more than a few seconds recorded, asks first (Discard or Save) unless `force`.
    func close(force: Bool = false) {
        guard isOpen else { return }
        if !force, !UITest.enabled, elapsed > 20, !saving { confirmingClose = true; return }
        confirmingClose = false
        finishSession()
        chain { [weak self] in
            guard let self else { return }
            await self.endPiece(keep: false)
            for piece in self.pieces { for t in piece { Self.remove(t.url) } }
            self.pieces = []
        }
        panel?.hide()
    }

    private func finishSession() {
        isOpen = false
        ticker?.invalidate(); ticker = nil
        feed.finishAll()
        retries = 0
    }

    // MARK: Source and language

    func choose(_ next: Source) {
        guard next != source, !saving else { return }
        UserDefaults.standard.set(next.saved, forKey: Self.sourceKey)
        status = nil
        chain { [weak self] in
            guard let self else { return }
            await self.endPiece(keep: true)
            self.source = next
            await self.startPiece()
        }
    }

    /// The menu's "Also caption my microphone": app audio alone, or app audio and the microphone.
    func toggleMic() {
        switch source {
        case .mic: return
        case .app(let id, let n): choose(.both(id: id, name: n))
        case .both(let id, let n): choose(.app(id: id, name: n))
        }
    }

    func setLanguage(_ id: String) {
        guard id != language else { return }
        CaptionLanguage.current = id
        language = id
        guard isOpen, !UITest.enabled else { return }
        feed.finishAll()
        micWords.locale = CaptionLanguage.locale
        appWords.locale = CaptionLanguage.locale
        retries = 0
        // The recording carries on; only the live words start over in the new language.
        if micStart != nil { micWords.start(format: Recorder.targetFormat) }
        if appStart != nil { appWords.start(format: Self.appFormat) }
    }

    func refreshApps() async {
        if let apps = try? await AppAudioCapture.runningApps() { runningApps = apps }
    }

    // MARK: Save

    func save() {
        guard isOpen, !saving else { return }
        confirmingClose = false
        if UITest.enabled { close(force: true); return }
        saving = true
        status = "Saving…"
        let title = source.appName.map { "Live captions · \($0)" } ?? "Live captions"
        chain { [weak self] in
            guard let self, let app = self.app else { return }
            await self.endPiece(keep: true)
            let pieces = self.pieces.filter { !$0.isEmpty }
            self.pieces = []
            let hadApp = pieces.contains { $0.contains { $0.url.lastPathComponent.contains("-app") } }
            guard !pieces.isEmpty else {
                self.saving = false
                self.status = "Nothing was recorded."
                return
            }
            let out = app.store.newRecordingURL()
            let mixed: (URL, TimeInterval)? = await Task.detached(priority: .userInitiated) {
                try? CaptionAudio.render(pieces, to: out)
            }.value
            // The parts go once the mix is written; if it couldn't be, they stay in the recordings folder.
            if let mixed { for piece in pieces { for t in piece where t.url.standardizedFileURL != mixed.0.standardizedFileURL { Self.remove(t.url) } } }
            self.saving = false
            // Read before it's handed to the Store: with iCloud the move into the audio folder finishes later.
            let wave = mixed.map { Waveform.envelope(of: $0.0) } ?? []
            guard let (url, duration) = mixed, duration >= 0.5, let name = app.store.adoptRecording(url) else {
                if let mixed { Self.remove(mixed.0) }
                self.status = "Couldn't save the recording."
                return
            }
            var t = Transcript(title: title, source: hadApp ? .app : .voiceMemo, sourceLabel: "Live captions",
                               duration: duration, audioFileName: name, model: "")
            t.waveform = wave
            app.enqueue(t)
            app.toast = Toast("Saved. Transcribing in your Library.")
            self.status = "Saved. Transcribing in your Library."
            self.finishSession()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !self.isOpen { self.panel?.hide() }
        }
    }

    // MARK: Capture

    private static var appFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    /// Runs `job` after everything queued before it.
    private func chain(_ job: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { @MainActor in
            await previous?.value
            await job()
        }
    }

    private func newURL(_ kind: String) -> URL {
        pieceCount += 1
        let base = app?.store.newRecordingURL() ?? FileManager.default.temporaryDirectory.appendingPathComponent("captions.wav")
        let stem = base.deletingPathExtension().lastPathComponent
        return base.deletingLastPathComponent().appendingPathComponent("\(stem) captions\(pieceCount)-\(kind).wav")
    }

    private func startPiece() async {
        guard isOpen else { return }
        let both = showsSpeakers
        if source.usesMic {
            feed.addSource("mic", speaker: both ? "You" : nil)
            await startMic()
        } else {
            feed.removeSource("mic")
        }
        if let id = source.appID {
            feed.addSource("app", speaker: both ? source.appName : nil)
            await startApp(id)
        } else {
            feed.removeSource("app")
        }
    }

    private func startMic() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            guard ok else { status = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."; return }
        default:
            status = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
            return
        }
        guard isOpen else { return }
        let url = newURL("mic")
        recorder.liveTap = micWords.tap
        micWords.start(format: Recorder.targetFormat)
        let error: Error? = await withCheckedContinuation { c in
            Task { @MainActor in self.recorder.begin(to: url) { c.resume(returning: $0) } }
        }
        if let error {
            recorder.liveTap = nil
            micWords.stop()
            status = error.localizedDescription
            return
        }
        micURL = url
        micStart = Date()
    }

    private func startApp(_ id: String) async {
        if !runningApps.contains(where: { $0.id == id }) { await refreshApps() }
        guard isOpen else { return }
        guard let target = runningApps.first(where: { $0.id == id }) else {
            status = "\(source.appName ?? "That app") isn't running."
            return
        }
        let url = newURL("app")
        capture.liveTap.set(appWords.tap)
        appWords.start(format: Self.appFormat)
        do {
            try await capture.start(app: target, to: url)
            appURL = url
            appStart = Date()
        } catch {
            capture.liveTap.set(nil)
            appWords.stop()
            Self.remove(url)
            status = "Couldn't capture \(target.name). Allow Verbatim under System Settings › Privacy & Security › Screen & System Audio Recording."
        }
    }

    /// Stops both captures. With `keep`, their files become a piece of the recording; otherwise they're deleted.
    private func endPiece(keep: Bool) async {
        feed.finishAll()
        var tracks: [(URL, Date)] = []
        if micStart != nil || recorder.isRecording {
            let stopped = recorder.stop()
            recorder.liveTap = nil
            micWords.stop()
            if let (url, duration, _) = stopped, !recorder.lastJoinFailed {
                if keep, duration >= 0.3, let start = micStart { tracks.append((url, start)) } else { Self.remove(url) }
            }
            micStart = nil; micURL = nil
        }
        if let url = appURL {
            stoppingApp = true
            // The capture may have ended on its own already; `stop` then hands back what that saved.
            let stopped = await capture.stop()
            stoppingApp = false
            capture.liveTap.set(nil)
            appWords.stop()
            // A failed join keeps every part for launch recovery: nothing to add, nothing to remove.
            let joinFailed = stopped?.joinFailed == true
            let saved: URL = stopped?.url ?? url
            if keep, !joinFailed, let start = appStart, FileManager.default.fileExists(atPath: saved.path) { tracks.append((saved, start)) }
            else if !joinFailed { Self.remove(saved) }
            appStart = nil; appURL = nil
        }
        guard !tracks.isEmpty else { return }
        let first = tracks.map(\.1).min() ?? Date()
        pieces.append(tracks.map { Track(url: $0.0, offset: $0.1.timeIntervalSince(first)) })
    }

    /// Twice a second: pauses end lines, and live words that couldn't start (a speech model still installing)
    /// are tried again for a while.
    private func tick() {
        feed.tick()
        guard isOpen, !saving else { return }
        let micOff = micStart != nil && micWords.state == .off
        let appOff = appStart != nil && appWords.state == .off
        guard micOff || appOff else {
            if status == Self.unavailable || status == Self.preparing { status = nil }
            return
        }
        retries += 1
        if retries % 8 == 0, retries <= 240 {
            if micOff { micWords.start(format: Recorder.targetFormat) }
            if appOff { appWords.start(format: Self.appFormat) }
        }
        if status == nil || status == Self.preparing || status == Self.unavailable {
            status = retries > 240 ? Self.unavailable : Self.preparing
        }
    }

    private static let preparing = "Getting live captions ready… The recording has started."
    private static let unavailable = "Live captions aren't available on this Mac for this language. The recording continues; Save as transcript still works."

    private static func remove(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        RecordingSegments.removeSegments(of: url)
    }

    // MARK: Screenshots

    private func seedForScreenshots() {
        source = .both(id: "us.zoom.xos", name: "Zoom")
        feed.seed(history: [
            CaptionLine(id: UUID(), text: "Then the crew call is at seven, and we start lighting by eight.", speaker: "Zoom"),
            CaptionLine(id: UUID(), text: "We can move the shoot to Monday if the location is still free.", speaker: "Zoom"),
        ], current: [
            CaptionLine(id: UUID(), text: "Monday works. Let me check with the crew about the morning call", speaker: "You"),
        ])
        startedAt = Date().addingTimeInterval(-724)
    }
}

extension AppState {
    /// ⌥⌘C, the menu bar item, and Home's Live captions tile.
    func toggleLiveCaptions() { LiveCaptions.shared.toggle(app: self) }
}

// MARK: - Mixing and joining

/// Writes the captions recording: each piece's tracks mixed (aligned by their offsets), pieces one after another,
/// as one 16 kHz mono WAV. A single track is moved into place as it is.
enum CaptionAudio {
    static func render(_ pieces: [[LiveCaptions.Track]], to out: URL) throws -> (URL, TimeInterval) {
        let sr = 16_000.0
        if pieces.count == 1, pieces[0].count == 1 {
            let only = pieces[0][0].url
            let f = try AVAudioFile(forReading: only)
            let d = Double(f.length) / f.processingFormat.sampleRate
            return (only, d)
        }
        let float = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var written: Int64 = 0
        let chunk: AVAudioFrameCount = 16_000
        for piece in pieces {
            // Tracks are read a chunk at a time. Both recorders write 16 kHz mono; anything else is converted whole.
            let tracks: [TrackReader] = piece.compactMap { try? TrackReader($0.url, offset: Int($0.offset * sr), rate: sr) }
            let total = tracks.map { $0.offset + $0.length }.max() ?? 0
            var pos = 0
            while pos < total {
                let n = min(Int(chunk), total - pos)
                guard let buf = AVAudioPCMBuffer(pcmFormat: float, frameCapacity: AVAudioFrameCount(n)), let dst = buf.floatChannelData?[0] else { break }
                buf.frameLength = AVAudioFrameCount(n)
                for i in 0..<n { dst[i] = 0 }
                for t in tracks {
                    let a = max(pos, t.offset), b = min(pos + n, t.offset + t.length)
                    guard b > a else { continue }
                    let samples = t.read(from: a - t.offset, count: b - a)
                    for (k, v) in samples.enumerated() { dst[a - pos + k] += v }
                }
                if tracks.count > 1 { for i in 0..<n { dst[i] = max(-1, min(1, dst[i])) } }
                try file.write(from: buf)
                pos += n
            }
            written += Int64(total)
        }
        return (out, Double(written) / sr)
    }

    /// One track of a piece, read in order.
    private final class TrackReader {
        let offset: Int
        let length: Int
        private let file: AVAudioFile?
        private let whole: [Float]?

        init(_ url: URL, offset: Int, rate: Double) throws {
            self.offset = offset
            let f = try AVAudioFile(forReading: url)
            let p = f.processingFormat
            if p.sampleRate == rate, p.channelCount == 1, p.commonFormat == .pcmFormatFloat32 {
                file = f; whole = nil; length = Int(f.length)
            } else {
                let all = try CaptionAudio.readMono(url, rate: rate)
                file = nil; whole = all; length = all.count
            }
        }

        func read(from start: Int, count: Int) -> [Float] {
            if let whole { return Array(whole[start..<min(whole.count, start + count)]) }
            guard let file, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return [] }
            file.framePosition = AVAudioFramePosition(start)
            guard (try? file.read(into: buf, frameCount: AVAudioFrameCount(count))) != nil, let ch = buf.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        }
    }

    fileprivate static func readMono(_ url: URL, rate: Double) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let n = AVAudioFrameCount(f.length)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n) else { return [] }
        try f.read(into: buf)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let mono: AVAudioPCMBuffer
        if f.processingFormat.sampleRate == rate, f.processingFormat.channelCount == 1, f.processingFormat.commonFormat == .pcmFormatFloat32 {
            mono = buf
        } else {
            guard let c = LiveConverter(output: target).convert(buf) else { return [] }
            mono = c
        }
        guard let ch = mono.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(mono.frameLength)))
    }
}
