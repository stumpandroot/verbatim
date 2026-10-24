import Foundation

/// How long launch may wait on iCloud file coordination before the first frame. iOS kills an app whose scene takes
/// 10 seconds to appear, and iCloud (bird, cloudd) can hold coordination claims for longer than that, for example
/// right after an iOS update. Every coordinated read or write that runs before the first frame shares one deadline:
/// until it passes, files are read through the coordinator; after it, a file whose bytes are on this device is read
/// directly, and the rest are left for a background pass after the first frame (`Store.readLate`).
/// Pure logic, so mac/tools/test-launch.sh runs it on Linux.
struct LaunchBudget: Sendable {
    /// About two seconds from the start of `Store.init`.
    static let allowance: TimeInterval = 2
    /// The deadline, in `ProcessInfo.systemUptime` seconds (monotonic: a clock change can't stretch it).
    let deadline: TimeInterval

    init(start: TimeInterval = ProcessInfo.processInfo.systemUptime, allowance: TimeInterval = LaunchBudget.allowance) {
        deadline = start + max(0, allowance)
    }

    /// Seconds left, never negative.
    func remaining(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval { max(0, deadline - now) }
    var isSpent: Bool { remaining() <= 0 }

    /// Where a file's bytes are, from `ubiquitousItemDownloadingStatus`.
    enum Local: Equatable, Sendable { case current, downloaded, notDownloaded, unknown }
    /// What to do with a file once coordination is out of time.
    enum Fallback: Equatable, Sendable { case readDirectly, skip }

    /// Only a file whose bytes are on this device is read without coordination: reading one that isn't would ask
    /// iCloud to download it and wait, which is the wait this avoids. A torn read just fails to decode and is
    /// skipped, as an unreadable file always has been.
    static func fallback(_ local: Local) -> Fallback {
        switch local {
        case .current, .downloaded: return .readDirectly
        case .notDownloaded, .unknown: return .skip
        }
    }
}

/// One coordinated access that launch may stop waiting for. The accessor calls `enter()` before touching the file
/// and `leave()` after; launch calls `wait(_:)`. Once launch gives up (the accessor hadn't started), the accessor
/// never runs; once the accessor has started, launch waits for it to finish, so a file is never read twice at once
/// and nothing runs after launch has moved on.
final class LaunchGate: @unchecked Sendable {
    private enum State { case waiting, running, finished, abandoned }
    private let lock = NSLock()
    private var state = State.waiting
    private let done = DispatchSemaphore(value: 0)

    init() {}

    /// The accessor may run: true unless launch already gave up on it.
    func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .waiting else { return false }
        state = .running
        return true
    }

    /// The accessor finished.
    func leave() {
        lock.lock(); state = .finished; lock.unlock()
        done.signal()
    }

    /// Waits for the accessor until the budget runs out. True: it ran and finished. False: it hadn't started, and
    /// now never will (the caller cancels the coordinator and falls back).
    func wait(_ budget: LaunchBudget) -> Bool {
        let left = budget.remaining()
        if left > 0, done.wait(timeout: .now() + left) == .success { return true }
        lock.lock()
        if state == .waiting { state = .abandoned; lock.unlock(); return false }
        let finished = state == .finished
        lock.unlock()
        // Started just before the deadline: it's reading now, so let it finish.
        if !finished { done.wait() }
        return true
    }
}

/// A value handed from a file coordinator's accessor back to the waiting thread (the gate orders the two).
final class LaunchBox<T>: @unchecked Sendable {
    var value: T?
    init() {}
}
