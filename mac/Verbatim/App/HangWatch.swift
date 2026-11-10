import Foundation

/// Notes in the diagnostic log (native.log) when the main thread stops responding for more than 1.5 seconds,
/// with what a recording was doing at the time (`CaptureStep`), so a reported freeze leaves a trail.
///
/// A timer on its own queue sends the main queue a ping every quarter second. A ping unanswered for 1.5 s is
/// logged right away (in case the app never recovers), and again with the full length once it's answered.
enum HangWatch {
    private static let limit: TimeInterval = 1.5
    private static let queue = DispatchQueue(label: "co.stumpandroot.verbatim.hangwatch", qos: .utility)
    // Only touched on `queue`.
    private static var timer: DispatchSourceTimer?
    private static var pingSentAt: TimeInterval?
    private static var stallStep: String?
    private static var reported = false

    /// Starts watching. Safe to call more than once.
    static func start() {
        queue.async {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: 0.25, leeway: .milliseconds(50))
            t.setEventHandler { tick() }
            t.resume()
            timer = t
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func tick() {
        guard let sent = pingSentAt else {
            let at = now
            pingSentAt = at
            DispatchQueue.main.async { queue.async { answered(at) } }
            return
        }
        let waited = now - sent
        if !reported, waited > limit {
            reported = true
            stallStep = CaptureStep.current
            Log.note("hang: main thread not responding for \(String(format: "%.1f", waited)) s so far (recording step: \(stallStep ?? "none"))")
        }
    }

    private static func answered(_ sent: TimeInterval) {
        guard pingSentAt == sent else { return }
        let waited = now - sent
        pingSentAt = nil
        if reported || waited > limit {
            let step = stallStep ?? CaptureStep.current
            Log.note("hang: main thread was blocked for \(String(format: "%.1f", waited)) s (recording step: \(step ?? "none"))")
        }
        reported = false
        stallStep = nil
    }
}

/// The longest the main thread went without answering, between `start()` and `stop()`, in ms (the self-test's
/// stress steps). A timer on its own queue pings the main queue every 20 ms; each answer's wait is a sample, and a
/// ping still unanswered at `stop()` counts up to then.
final class StallMeter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.stallmeter", qos: .userInitiated)
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var sentAt: TimeInterval?
    private var longest: TimeInterval = 0

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        queue.sync {
            longest = 0; sentAt = nil
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 0.02, leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    private func tick() {
        guard sentAt == nil else { return }
        let at = now
        sentAt = at
        DispatchQueue.main.async { [weak self] in self?.queue.async { self?.answered(at) } }
    }

    private func answered(_ at: TimeInterval) {
        guard sentAt == at else { return }
        longest = max(longest, now - at)
        sentAt = nil
    }

    /// Stops the meter and returns the longest wait in ms.
    func stop() -> Int {
        queue.sync {
            timer?.cancel(); timer = nil
            if let at = sentAt { longest = max(longest, now - at) }
            sentAt = nil
            return Int((longest * 1000).rounded())
        }
    }
}
