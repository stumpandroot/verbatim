import Foundation
import AVFoundation
import Combine

/// The playhead, ticking 20× a second while playing. Its own object so only the dock, the wave track, and
/// the reading lines re-render during playback, never the whole window. It also carries the open file and its length,
/// which only the player bar and dock draw: in Player's own publishes they re-rendered the whole app twice on every
/// transcript open (once inside the screen's `onAppear`, again when the file opened).
@MainActor
final class PlayerClock: ObservableObject {
    @Published var time: TimeInterval = 0
    /// The audio being played or opening (`Player.loadedURL`).
    @Published fileprivate(set) var loadedURL: URL?
    /// The open file's length in seconds; 0 until one opens (`Player.duration`).
    @Published fileprivate(set) var duration: TimeInterval = 0
    /// A moment's status for the dock, such as "Skipped sponsor"; nil the rest of the time.
    @Published private(set) var note: String? = nil
    private var noteTask: Task<Void, Never>?

    /// Shows `text` in the dock for a few seconds.
    func flash(_ text: String, seconds: Double = 2.5) {
        note = text
        noteTask?.cancel()
        noteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.note = nil }
        }
    }
}

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    let clock = PlayerClock()
    var time: TimeInterval {
        get { clock.time }
        set { if clock.time != newValue { clock.time = newValue } }
    }
    /// The open file's length; published on `clock`, so only the views that observe it (the dock, the player bar)
    /// re-render when it changes.
    var duration: TimeInterval { clock.duration }
    /// The audio being played or opening; published on `clock`, like `duration`.
    var loadedURL: URL? { clock.loadedURL }
    @Published private(set) var rate: Float = 1

    private var player: AVAudioPlayer?
    private var timer: Timer?
    /// A seek asked for while the file was still opening; applied once it opens.
    private var pendingStart: Double?
    /// Sponsor reads to jump past (Settings › Skip sponsor reads), set by the transcript screen (`skipsSponsors`).
    var skipSpans: [(start: Double, end: Double)] = []
    /// The playhead at the last tick or seek: playback that crosses into a read skips it; a seek into one doesn't.
    private var lastTick: TimeInterval = 0

    /// True once the audio is open and can play. Opening a file announces it on Player (`opened`), so the lines' and
    /// sponsor folds' play actions appear; closing it (`stop()`, as the screen leaves) doesn't, as before.
    var canPlay: Bool { player != nil }

    private func setDuration(_ d: TimeInterval) { if clock.duration != d { clock.duration = d } }
    private func setLoadedURL(_ u: URL?) { if clock.loadedURL != u { clock.loadedURL = u } }

    /// The file is open: one publish, for the views that offer play only when it can (`canPlay`).
    private func opened(_ p: AVAudioPlayer) {
        objectWillChange.send()
        player = p
    }

    /// Opens the file off the main thread so a long recording doesn't hold up the screen that shows it.
    func loadAsync(_ url: URL, startAt: Double? = nil) {
        if loadedURL == url, player != nil { return }
        if player != nil || isPlaying { stop() }   // no redundant publishes when nothing is loaded
        setLoadedURL(url)
        pendingStart = nil
        let r = rate
        Task.detached(priority: .userInitiated) {
            // Audio recorded on the other device downloads from iCloud on first play.
            _ = await Cloud.ensureDownloaded(url)
            let p = try? AVAudioPlayer(contentsOf: url)
            p?.enableRate = true
            p?.rate = r
            p?.prepareToPlay()
            await MainActor.run {
                guard self.loadedURL == url, let p else { return }
                p.delegate = self
                self.opened(p)
                self.setDuration(p.duration)
                defer { self.pendingStart = nil }
                if let s = startAt ?? self.pendingStart { p.currentTime = min(s, p.duration); self.time = p.currentTime } else { self.time = 0 }
                self.lastTick = self.time
            }
        }
    }

    func load(_ url: URL) {
        if loadedURL == url, player != nil { return }
        stop()
        let p = try? AVAudioPlayer(contentsOf: url)
        p?.delegate = self
        p?.enableRate = true
        p?.rate = rate
        p?.prepareToPlay()
        if let p { opened(p) }
        setDuration(p?.duration ?? 0)
        time = 0
        setLoadedURL(url)
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; timer?.invalidate() }
        else {
            p.play(); isPlaying = true
            lastTick = p.currentTime
            // Scheduled on the main run loop (this is main-actor code), so the block is already on main: no Task per tick.
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// Moves the playhead with playback, jumping past a sponsor read it just crossed into.
    private func tick() {
        guard let p = player else { time = 0; return }
        let now = p.currentTime
        if let to = SponsorSkip.target(from: lastTick, to: now, spans: skipSpans) {
            p.currentTime = min(to, p.duration)
            lastTick = p.currentTime; time = p.currentTime
            clock.flash("Skipped sponsor")
            return
        }
        lastTick = now
        time = now
    }

    func seek(to t: TimeInterval) {
        guard let p = player else { if loadedURL != nil { pendingStart = max(0, t) }; return }
        p.currentTime = max(0, min(t, p.duration))
        time = p.currentTime
        lastTick = time
    }

    /// Seeks and plays (tap a line, Play from here).
    func play(from t: TimeInterval) {
        seek(to: t)
        if player != nil, !isPlaying { toggle() }
    }

    func setRate(_ r: Float) { rate = r; player?.rate = r }

    func stop() {
        player?.stop(); player = nil
        timer?.invalidate(); timer = nil
        if isPlaying { isPlaying = false }
        time = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.timer?.invalidate()
            self.time = 0
        }
    }

    nonisolated static func duration(of url: URL) -> TimeInterval {
        (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
    }
}
