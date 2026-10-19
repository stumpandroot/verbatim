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
