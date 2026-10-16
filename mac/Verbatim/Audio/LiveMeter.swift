import Foundation
import Combine

/// The fast-changing part of a recording: level bars and elapsed time. Its own object so only the views that
/// show it re-render (about 14 times a second); nothing else in the app hears about it.
@MainActor
final class LiveMeter: ObservableObject {
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    private var pendingPeak: Float = 0
    private var last = Date.distantPast

    /// Called per audio buffer. Coalesces into one publish every 70 ms.
    func push(_ v: Float, seconds: TimeInterval, paused: Bool) {
        pendingPeak = max(pendingPeak, paused ? 0 : v)
        let now = Date()
        guard now.timeIntervalSince(last) > 0.07 else { return }
        last = now
        elapsed = seconds
        if !paused {
            level = pendingPeak
            var l = levels; l.removeFirst(); l.append(pendingPeak); levels = l
        }
        pendingPeak = 0
    }
    func reset() { levels = Array(repeating: 0, count: 28); level = 0; elapsed = 0; pendingPeak = 0 }
    func setElapsed(_ s: TimeInterval) { elapsed = s }
}

