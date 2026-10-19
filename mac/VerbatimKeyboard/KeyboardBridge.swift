import Foundation

/// The channel between the Verbatim keyboard and the Verbatim iPhone app. Compiled into both targets.
///
/// A keyboard can't record in the background or run the speech model (it has a memory limit of about 60 MB and
/// no background time), so the keyboard hands dictation to the app:
///
/// 1. The keyboard writes a new session ID and opens `verbatim://dictate?session=<id>`.
/// 2. The app starts recording in the foreground. You switch back; recording keeps going in the background
///    (background audio mode). About 10 times a second the app writes the level and elapsed time here.
/// 3. You tap Done on the keyboard: it writes a `done` command and posts a Darwin notification.
/// 4. The app stops, transcribes, and writes the text here with `phase = done`; the keyboard inserts it.
///
/// Storage is the App Group's shared UserDefaults, so it needs Allow Full Access on the keyboard. Darwin
/// notifications carry no data; they only say "look again". Both sides also poll, so a missed notification
/// costs at most a tenth of a second.
enum KeyboardBridge {
    /// Must match `com.apple.security.application-groups` in both entitlements (project.yml).
    static let appGroup = "group.co.stumpandroot.verbatim.ios"
    static let scheme = "verbatim"
    static let dictateHost = "dictate"

    /// Recording stops on its own after this long (a keyboard dictation, not a meeting).
    static let maxSeconds: TimeInterval = 5 * 60

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    enum Key {
        static let session = "kb.session"          // String UUID: the current dictation
        static let phase = "kb.phase"              // Phase.rawValue
        static let level = "kb.level"              // Double 0…1
        static let elapsed = "kb.elapsed"          // Double seconds
        static let text = "kb.text"                // String: the text to insert
        static let raw = "kb.raw"                  // String: the transcript as spoken
        static let message = "kb.message"          // String: why it failed
        static let updated = "kb.updated"          // Double: time of the app's last write
        static let command = "kb.command"          // Command.rawValue, from the keyboard
        static let commandSession = "kb.commandSession"
        static let insertedSession = "kb.insertedSession" // the session whose text a keyboard already inserted
        static let levelLabel = "kb.levelLabel"    // "Polished": the cleanup the app applies
    }

    enum Phase: String {
        /// The keyboard asked; the app hasn't answered yet.
        case requested
        /// The app is recording.
        case listening
        /// Recording stopped; the app is transcribing.
        case transcribing
        /// `text` and `raw` hold the result.
        case done
        case failed
        case cancelled
    }

    enum Command: String { case done, cancel }

    enum Note {
        /// Posted by the app whenever phase, level, or result changes.
        static let state = "co.stumpandroot.verbatim.keyboard.state"
        /// Posted by the keyboard after writing a command.
        static let command = "co.stumpandroot.verbatim.keyboard.command"
    }

    static func dictateURL(session: UUID) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = dictateHost
        c.queryItems = [URLQueryItem(name: "session", value: session.uuidString)]
        return c.url!
    }

    /// The session in a `verbatim://dictate?session=…` link, or nil for any other link.
    static func session(in url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == dictateHost,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let v = c.queryItems?.first(where: { $0.name == "session" })?.value else { return nil }
        return UUID(uuidString: v)
    }

    // MARK: Reading

    static var currentSession: UUID? { defaults?.string(forKey: Key.session).flatMap(UUID.init(uuidString:)) }
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
