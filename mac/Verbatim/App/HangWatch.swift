import Foundation

/// Notes in the diagnostic log (native.log) when the main thread stops responding for more than 1.5 seconds,
/// with what a recording was doing at the time (`CaptureStep`), so a reported freeze leaves a trail.
///
/// A timer on its own queue sends the main queue a ping every quarter second. A ping unanswered for 1.5 s is
/// logged right away (in case the app never recovers), and again with the full length once it's answered. The
/// length is measured to when the main thread ran the ping, so a busy machine that keeps this queue waiting
/// doesn't add to it.
///
/// In the self-test, each quarter second of a stall also logs what the main thread was running (`MainStack`).
enum HangWatch {
    private static let limit: TimeInterval = 1.5
    private static let queue = DispatchQueue(label: "co.stumpandroot.verbatim.hangwatch", qos: .utility)
    // Only touched on `queue`.
    private static var timer: DispatchSourceTimer?
    private static var pingSentAt: TimeInterval?
    private static var stallStep: String?
    private static var reported = false
    private static var stacks = 0

    /// Starts watching. Safe to call more than once. Call on the main thread.
    static func start() {
        #if os(macOS) && arch(arm64)
        if UITest.enabled { MainStack.arm() }
        #endif
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
            DispatchQueue.main.async { let ran = now; queue.async { answered(at, ran: ran) } }
            return
        }
        let waited = now - sent
        if !reported, waited > limit {
            reported = true
            stacks = 0
            stallStep = CaptureStep.current
            Log.note("hang: main thread not responding for \(String(format: "%.1f", waited)) s so far (recording step: \(stallStep ?? "none"))")
        }
        #if os(macOS) && arch(arm64)
        if reported, UITest.enabled, stacks < 40 {
            stacks += 1
            Log.note("hang stack \(stacks) at \(String(format: "%.2f", waited)) s: \(MainStack.describe(MainStack.capture()))")
        }
        #endif
    }

    private static func answered(_ sent: TimeInterval, ran: TimeInterval) {
        guard pingSentAt == sent else { return }
        let waited = ran - sent
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

#if os(macOS) && arch(arm64)
import Darwin

@_silgen_name("swift_demangle")
private func swiftDemangle(_ name: UnsafePointer<CChar>?, _ length: UInt, _ out: UnsafeMutablePointer<CChar>?,
                           _ outLength: UnsafeMutablePointer<UInt>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

/// What the main thread is running right now, read from another thread: the self-test's stall log (`HangWatch`).
/// Self-test only. The main thread is paused for the few microseconds it takes to copy its return addresses;
/// nothing allocates or takes a lock while it's paused, and names are looked up after it runs again.
enum MainStack {
    private static var mainThread: thread_act_t = 0

    /// Remembers the main thread. Call on it.
    static func arm() { if mainThread == 0 { mainThread = mach_thread_self() } }

    /// The main thread's return addresses, innermost first.
    static func capture(limit: Int = 600) -> [UInt] {
        guard mainThread != 0 else { return [] }
        var frames = [UInt](repeating: 0, count: limit)
        var n = 0
        frames.withUnsafeMutableBufferPointer { buf in
            var state = arm_thread_state64_t()
            var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            var pair: (UInt, UInt) = (0, 0)
            guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
            let got = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                    thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
                }
            }
            if got == KERN_SUCCESS {
                buf[0] = UInt(state.__pc); n = 1
                var fp = UInt(state.__fp)
                while n < limit, fp != 0, fp & 0xF == 0 {
                    var size: vm_size_t = 0
                    let read = withUnsafeMutablePointer(to: &pair) {
                        vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16, vm_address_t(UInt(bitPattern: $0)), &size)
                    }
                    guard read == KERN_SUCCESS, size == 16, pair.1 != 0 else { break }
                    buf[n] = pair.1 & 0x0000_7FFF_FFFF_FFFF; n += 1
                    guard pair.0 > fp else { break }
                    fp = pair.0
                }
            }
            thread_resume(mainThread)
        }
        return Array(frames.prefix(n))
    }

    /// The innermost frames as names, then every frame of the app's own, innermost first.
    static func describe(_ frames: [UInt]) -> String {
        var names: [String] = []
        for a in frames {
            var info = Dl_info()
            var name = "?"
            if dladdr(UnsafeRawPointer(bitPattern: a), &info) != 0 {
                let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                if let sym = info.dli_sname {
                    if let d = swiftDemangle(sym, UInt(strlen(sym)), nil, nil, 0) { name = String(cString: d); free(d) }
                    else { name = String(cString: sym) }
                    if name.count > 110 { name = String(name.prefix(110)) + "…" }
                } else {
                    name = "\(image)+\(String(a - UInt(bitPattern: info.dli_fbase), radix: 16))"
                }
                if image == "Verbatim" { name = "[app] " + name }
            }
            if names.last != name { names.append(name) }
        }
        if let i = names.firstIndex(where: { $0.contains("CFRunLoopRun") || $0.contains("NSApplication run") }) { names = Array(names.prefix(i)) }
        // Layout stacks run to hundreds of frames: the innermost few say what is running, the app's own say where from.
        var seen = Set<String>()
        let ours = names.filter { $0.hasPrefix("[app] ") && seen.insert($0).inserted }.map { String($0.dropFirst(6)) }
        return "\(frames.count) frames: " + names.prefix(16).joined(separator: " < ")
            + " | app: " + (ours.isEmpty ? "none" : ours.prefix(30).joined(separator: " < "))
    }
}
#endif
