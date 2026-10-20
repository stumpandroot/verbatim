import Foundation

/// The channel between the Verbatim keyboard and the Verbatim iPhone app. Compiled into both targets.
///
/// A keyboard can't use the microphone or run the speech model (it has a memory limit of about 60 MB and no
/// background time), so the app does both. To make dictation instant, the app holds a *session*:
///
/// 1. Session start (once): the keyboard writes a session request and opens
///    `verbatim://session?start=1&request=<id>&host=<bundle ID>`. The app turns the microphone on, keeps one
///    capture engine running (audio stays in memory; nothing is written to disk), loads the speech model, starts
///    a Live Activity, and switches back to the app you came from.
/// 2. While the session is on, the app writes a heartbeat here every 2 seconds, plus when the session ends.
/// 3. Dictation (no app switch): the keyboard writes `startID` and posts `Note.command`; the app marks where the
///    dictation starts in the running capture and streams level and time here about 10 times a second. Done writes
///    `doneID`; the app transcribes at once with the warm model and writes the text with `phase = done`.
/// 4. The session ends after an idle timeout, from the Live Activity, from the app, or for a call. The microphone
///    turns off then. A keyboard that sees no heartbeat starts a new session on its next tap.
///
/// Storage is the App Group's shared UserDefaults, so it needs Allow Full Access on the keyboard. Darwin
/// notifications carry no data; they only say "look again". Both sides also poll, so a missed notification costs
/// at most a fraction of a second.
enum KeyboardBridge {
    /// Must match `com.apple.security.application-groups` in both entitlements (project.yml).
    static let appGroup = "group.co.stumpandroot.verbatim.ios"
    static let scheme = "verbatim"
    static let sessionHost = "session"
    /// The first keyboard's per-dictation link. The app treats it as a session request.
    static let legacyDictateHost = "dictate"

    /// A dictation stops on its own after this long (a keyboard dictation, not a meeting).
    static let maxSeconds: TimeInterval = 5 * 60
    /// The app writes a heartbeat this often during a session.
    static let heartbeatInterval: TimeInterval = 2
    /// A session whose heartbeat is older than this is gone (the app was closed or crashed).
    static let heartbeatStale: TimeInterval = 6

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    enum Key {
        // Session (written by the app)
        static let sessionActive = "kb.s.active"          // Bool
        static let heartbeat = "kb.s.heartbeat"           // Double: time of the last heartbeat
        static let endsAt = "kb.s.endsAt"                 // Double: idle timeout, 0 when it runs until you end it
        static let micName = "kb.s.mic"                   // String: "iPhone Microphone"
        static let endReason = "kb.s.endReason"           // String: why the last session ended, when it matters
        // Session request (keyboard writes `request`; the app answers with `requestDone` or `requestFailed`)
        static let request = "kb.s.request"               // String UUID
        static let requestDone = "kb.s.requestDone"       // String UUID
        static let requestFailed = "kb.s.requestFailed"   // String UUID
        static let requestMessage = "kb.s.requestMessage" // String: why it failed

        // Dictation commands (written by the keyboard; separate keys so a quick Start then Done never overwrite each other)
        static let startID = "kb.d.start"                 // String UUID
        static let doneID = "kb.d.done"                   // String UUID
        static let cancelID = "kb.d.cancel"               // String UUID
        static let insertedID = "kb.d.inserted"           // the dictation whose text a keyboard already inserted

        // Dictation state (written by the app)
        static let dictation = "kb.d.id"                  // String UUID: the dictation the fields below describe
        static let phase = "kb.d.phase"                   // Phase.rawValue
        static let level = "kb.d.level"                   // Double 0…1
        static let elapsed = "kb.d.elapsed"               // Double seconds
        static let text = "kb.d.text"                     // String: the text to insert
        static let raw = "kb.d.raw"                       // String: the transcript as spoken
        static let message = "kb.d.message"               // String: why it failed
        static let levelLabel = "kb.levelLabel"           // "Polished": the cleanup the app applies
    }

    enum Phase: String {
        /// The app is capturing this dictation.
        case listening
        /// Capture stopped; the app is transcribing.
        case transcribing
        /// `text` and `raw` hold the result.
        case done
        case failed
        case cancelled
    }

    enum Note {
        /// Posted by the app whenever the session or a dictation changes.
        static let state = "co.stumpandroot.verbatim.keyboard.state"
        /// Posted by the keyboard after writing a command.
        static let command = "co.stumpandroot.verbatim.keyboard.command"
    }

    // MARK: Links

    static func sessionURL(request: UUID, host: String?) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = sessionHost
        var items = [URLQueryItem(name: "start", value: "1"), URLQueryItem(name: "request", value: request.uuidString)]
        if let host, !host.isEmpty { items.append(URLQueryItem(name: "host", value: host)) }
        c.queryItems = items
        return c.url!
    }

    struct SessionLink { var request: UUID?; var host: String? }

    /// The request in a `verbatim://session?…` link (or the first keyboard's `verbatim://dictate?…`), or nil for any other link.
    static func sessionLink(in url: URL) -> SessionLink? {
        guard url.scheme == scheme, url.host == sessionHost || url.host == legacyDictateHost else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let request = items.first(where: { $0.name == "request" || $0.name == "session" })?.value.flatMap(UUID.init(uuidString:))
        let host = items.first(where: { $0.name == "host" })?.value
        return SessionLink(request: request, host: host?.isEmpty == false ? host : nil)
    }

    // MARK: Reading

    /// True while the app holds a session: it says so, and its heartbeat is recent.
    static var sessionLive: Bool {
        guard let d = defaults, d.bool(forKey: Key.sessionActive) else { return false }
        return Date().timeIntervalSince1970 - d.double(forKey: Key.heartbeat) < heartbeatStale
    }

    static func uuid(_ key: String) -> UUID? { defaults?.string(forKey: key).flatMap(UUID.init(uuidString:)) }
    static var phase: Phase? { defaults?.string(forKey: Key.phase).flatMap(Phase.init(rawValue:)) }

    // MARK: Darwin notifications

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    private static var handlers: [String: [() -> Void]] = [:]
    private static let lock = NSLock()
    /// A stable, non-null observer pointer for the Darwin center.
    private final class Token {}
    private static let token = Token()

    /// Calls `handler` on the main queue whenever `name` is posted, from either process. Lives for the process.
    static func observe(_ name: String, _ handler: @escaping () -> Void) {
        lock.lock()
        let first = handlers[name] == nil
        handlers[name, default: []].append(handler)
        lock.unlock()
        guard first else { return }
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(token).toOpaque())
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, _, cfName, _, _ in
            guard let n = cfName?.rawValue as String? else { return }
            DispatchQueue.main.async { KeyboardBridge.fire(n) }
        }, name as CFString, nil, .deliverImmediately)
    }

    private static func fire(_ name: String) {
        lock.lock()
        let list = handlers[name] ?? []
        lock.unlock()
        list.forEach { $0() }
    }
}
