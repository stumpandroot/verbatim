import Foundation
import AVFoundation
import Combine

/// The playhead, ticking 20× a second while playing. Its own object so only the dock, the wave track, and
/// the reading lines re-render during playback, never the whole window.
@MainActor
final class PlayerClock: ObservableObject {
    @Published var time: TimeInterval = 0
}

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    let clock = PlayerClock()
    var time: TimeInterval {
        get { clock.time }
        set { if clock.time != newValue { clock.time = newValue } }
    }
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadedURL: URL?
    @Published private(set) var rate: Float = 1

    private var player: AVAudioPlayer?
    private var timer: Timer?
    /// A seek asked for while the file was still opening; applied once it opens.
    private var pendingStart: Double?

    /// True once the audio is open and can play.
    var canPlay: Bool { player != nil }

    /// Opens the file off the main thread so a long recording doesn't hold up the screen that shows it.
    func loadAsync(_ url: URL, startAt: Double? = nil) {
        if loadedURL == url, player != nil { return }
        if player != nil || isPlaying { stop() }   // no redundant publishes when nothing is loaded
        if loadedURL != url { loadedURL = url }
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
                self.player = p
                if self.duration != p.duration { self.duration = p.duration }
                defer { self.pendingStart = nil }
                if let s = startAt ?? self.pendingStart { p.currentTime = min(s, p.duration); self.time = p.currentTime } else { self.time = 0 }
            }
        }
    }

    func load(_ url: URL) {
        if loadedURL == url, player != nil { return }
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.enableRate = true
        player?.rate = rate
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        time = 0
        loadedURL = url
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; timer?.invalidate() }
        else {
            p.play(); isPlaying = true
            // Scheduled on the main run loop (this is main-actor code), so the block is already on main: no Task per tick.
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.time = self?.player?.currentTime ?? 0 }
            }
        }
    }

    func seek(to t: TimeInterval) {
        guard let p = player else { if loadedURL != nil { pendingStart = max(0, t) }; return }
        p.currentTime = max(0, min(t, p.duration))
        time = p.currentTime
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
