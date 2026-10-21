import AppKit
import CoreServices

// Where you dictate, by website: when you dictate into a supported browser, Verbatim asks it for the front tab's
// address through Apple Events, keeps only the host ("mail.google.com"), and files it next to that dictation's
// Activity numbers (`SiteLog`). Never the full address, never the page's text. Off with Settings › General ›
// Count websites. The ask runs off the main thread with a short timeout, so dictation never waits on it.

/// The host of a web address, or nil when it isn't an http or https address with a host.
enum SiteHost {
    static func host(from raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = s.range(of: "://") else { return nil }
        let scheme = s[s.startIndex..<sep.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        var authority = Substring(s[sep.upperBound...])
        if let end = authority.firstIndex(where: { "/?#\\".contains($0) }) { authority = authority[authority.startIndex..<end] }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var host: String
        if authority.hasPrefix("[") {
            // An IPv6 literal keeps its brackets; the port after them goes.
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.startIndex...close])
        } else {
            host = String(authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
        host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host != "[]",
              !host.contains(where: { $0.isWhitespace || $0 == "%" || $0 == "<" || $0 == ">" || $0 == "\"" }),
              host.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return host
    }
}

/// Browsers Verbatim can ask for the front tab's address. Firefox has no scripting for it, so it counts as one app.
enum BrowserTabs {
    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "company.thebrowser.Browser",                                   // Arc
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    static func isSupported(_ bundleID: String?) -> Bool { bundleID.map { safari.contains($0) || chromium.contains($0) } ?? false }

    /// The AppleScript that returns the front tab's address, with its own two-second timeout.
    static func script(for bundleID: String) -> String? {
        let expr: String
        if safari.contains(bundleID) { expr = "URL of current tab of front window" }
        else if chromium.contains(bundleID) { expr = "URL of active tab of front window" }
        else { return nil }
        return "with timeout of 2 seconds\ntell application id \"\(bundleID)\" to return \(expr)\nend timeout"
    }
}

/// One dictation's website, filled in off the main thread. Finishes once: with a host, or nil.
final class SiteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var host: String?
    private var waiters: [(String?) -> Void] = []

    func finish(_ value: String?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true; host = value
        let w = waiters; waiters = []
        lock.unlock()
        DispatchQueue.main.async { for f in w { f(value) } }
    }

    /// Calls `f` on the main thread with the result, now or when it arrives.
    func whenDone(_ f: @escaping (String?) -> Void) {
        lock.lock()
        if done { let v = host; lock.unlock(); DispatchQueue.main.async { f(v) }; return }
        waiters.append(f)
        lock.unlock()
    }
}

enum SiteCapture {
    /// Settings › General › Count websites. On by default.
    static let countKey = "activity.countSites"
    static var isOn: Bool { UserDefaults.standard.object(forKey: countKey) as? Bool ?? true }

    private static let queue = DispatchQueue(label: "co.stumpandroot.verbatim.site-capture", qos: .utility)
    private static let lock = NSLock()
    private static var busy = false
    /// Browsers macOS hasn't asked about yet; asked once, after a dictation has pasted (never mid-dictation, where the
    /// permission dialog could take focus from the app you're writing in).
    private static var needsConsent: Set<String> = []
    private static var asked: Set<String> = []

    /// Starts asking the front browser for its tab's host. Nil when the app isn't a supported browser or counting
    /// is off. Never blocks: a second ask while one is in flight finishes empty.
    @MainActor static func probe(bundleID: String?) -> SiteProbe? {
        guard isOn, !UITest.enabled, let bid = bundleID, let source = BrowserTabs.script(for: bid) else { return nil }
        let p = SiteProbe()
        lock.lock()
        let wasBusy = busy
        if !wasBusy { busy = true }
        lock.unlock()
        if wasBusy { p.finish(nil); return p }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { p.finish(nil) }
        queue.async {
            defer { lock.lock(); busy = false; lock.unlock() }
            switch permission(bid, ask: false) {
            case 0:
                var error: NSDictionary?
                let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { Log.note("site capture: error \(error[NSAppleScript.errorNumber] ?? "?")") }
                p.finish(out?.stringValue.flatMap(SiteHost.host(from:)))
            case -1744:   // errAEEventWouldRequireUserConsent: ask after this dictation pastes
                lock.lock(); needsConsent.insert(bid); lock.unlock()
                p.finish(nil)
            default:      // denied (-1743) or gone: the browser counts as one app
                p.finish(nil)
            }
        }
        return p
    }

    /// Shows macOS's "control this browser" question for browsers it hasn't asked about, once each per launch.
    static func askPendingConsent() {
        lock.lock()
        let pending = needsConsent.subtracting(asked)
        asked.formUnion(pending); needsConsent = []
        lock.unlock()
        guard !pending.isEmpty else { return }
        queue.asyncAfter(deadline: .now() + 1.5) {
            for bid in pending { _ = permission(bid, ask: true) }
        }
    }

    /// 0 when allowed, -1743 when denied, -1744 when macOS hasn't asked yet, -600 when the app isn't running.
    private static func permission(_ bundleID: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }
}

/// Each dictation's website host, by dictation ID: a sidecar to `ActivityLog` so its records stay as they are.
/// Stored on this Mac only (activity-sites.json), cleared with Activity.
@MainActor
final class SiteLog: ObservableObject {
    static let shared = SiteLog()
    @Published private(set) var hosts: [UUID: String] = [:]
    private let file = Paths.local.appendingPathComponent(ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1" ? "activity-sites-uitest.json" : "activity-sites.json")

    private init() {
        if let data = try? Data(contentsOf: file), let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            var h: [UUID: String] = [:]
            for (k, v) in raw { if let id = UUID(uuidString: k) { h[id] = v } }
            hosts = h
        }
    }

    /// Files the probe's host under the dictation once it arrives, then lets macOS ask about a new browser.
    func attach(_ id: UUID, _ probe: SiteProbe?) {
        guard let probe else { return }
        probe.whenDone { host in
            if let host { SiteLog.shared.set(id, host) }
            SiteCapture.askPendingConsent()
        }
    }

    func set(_ id: UUID, _ host: String) { hosts[id] = host; save() }

    /// Many at once with one save (the screenshot tour).
    func setAll(_ list: [UUID: String]) { hosts.merge(list) { _, new in new }; save() }

    func reset() { hosts = [:]; save() }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.local, withIntermediateDirectories: true)
        let raw = Dictionary(uniqueKeysWithValues: hosts.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { try? data.write(to: file, options: .atomic) }
    }
}
