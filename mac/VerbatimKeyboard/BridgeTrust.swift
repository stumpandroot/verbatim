import Foundation

/// What the app trusts from outside its own process. Pure (Foundation only), so the Linux tests run it
/// (mac/tools/test-bridge.sh). Compiled into the app, the keyboard, and the widget extension.
///
/// Any app on the iPhone can post a Darwin notification or open a `verbatim://` link, and Verbose can't tell who
/// did. Only Verbose's own processes (the app, the keyboard, the widgets and their intents, all signed by the same
/// team) can write the App Group. So the App Group carries the real command or request, with a one-time ID and the
/// time it was written; a notification or a link only says "look again", and the app acts only on a fresh,
/// unhandled command it reads there.
enum BridgeTrust {
    // MARK: Commands from the widget's process (the ribbon's Dictate, Done, Cancel, and End session)

    /// A command one of Verbose's processes wrote to the App Group.
    struct Command: Equatable {
        var id: UUID
        var name: String
        /// When it was written, in seconds since 1970.
        var at: Double
    }

    /// A command older than this is ignored: the tap that wrote it was long enough ago that acting now would surprise you.
    static let commandFresh: TimeInterval = 10
    /// How far in the future a time may be (two processes reading the same clock) before it doesn't count.
    static let clockSkew: TimeInterval = 2

    /// "<id>|<name>|<time>", the form stored in the App Group.
    static func encode(_ c: Command) -> String { "\(c.id.uuidString)|\(c.name)|\(c.at)" }

    static func decode(_ s: String?) -> Command? {
        guard let s else { return nil }
        let parts = s.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let id = UUID(uuidString: String(parts[0])), !parts[1].isEmpty,
              let at = Double(parts[2]), at.isFinite else { return nil }
        return Command(id: id, name: String(parts[1]), at: at)
    }

    /// True when `at` is no older than `window` and not in the future (beyond `clockSkew`).
    static func isFresh(_ at: Double, now: Double, window: TimeInterval) -> Bool {
        at <= now + clockSkew && now - at <= window
    }

    /// The command to act on, or nil: none was written, it's stale or from the future, or it was handled already.
    static func acceptCommand(_ c: Command?, consumed: Set<UUID>, now: Double) -> Command? {
        guard let c, !consumed.contains(c.id), isFresh(c.at, now: now, window: commandFresh) else { return nil }
        return c
    }

    // MARK: Session links (verbatim://session and verbatim://dictate)

    /// The keyboard opens the session link right after writing its request, so a request older than this didn't
    /// come with the link in hand (a cold launch takes a few seconds, never this long).
    static let requestFresh: TimeInterval = 30

    /// The session request the keyboard wrote to the App Group just before opening the link.
    struct StoredRequest: Equatable {
        var id: UUID?
        /// When the keyboard wrote it, in seconds since 1970 (0 when it didn't say).
        var at: Double
        /// The app the keyboard was in, as the keyboard read it (nil when it couldn't).
        var host: String?
        /// The dictation the keyboard asked to start with the session (`KeyboardBridge.Key.startID`).
        var startID: UUID?
        /// The app already answered this request (done or failed).
        var answered: Bool
    }

    enum LinkDecision: Equatable {
        /// A request the keyboard made just now: start the session at once, begin `dictation` if there is one, and
        /// switch back to `host` (the keyboard's, never the link's).
        case start(host: String?, dictation: UUID?)
        /// Anything else: ask first ("Start a keyboard session?"), and never turn on the microphone by itself.
        case confirm
    }

    /// What to do with a session link. Pure, so it's testable.
    static func decide(linkRequest: UUID?, linkDictation: UUID?, stored: StoredRequest, consumed: Set<UUID>, now: Double) -> LinkDecision {
        guard let r = linkRequest, stored.id == r, !stored.answered, !consumed.contains(r),
              isFresh(stored.at, now: now, window: requestFresh) else { return .confirm }
        let dictation = linkDictation.flatMap { $0 == stored.startID ? $0 : nil }
        return .start(host: validHost(stored.host), dictation: dictation)
    }

    /// `s` when it looks like a bundle ID (letters, digits, dots, and hyphens, at most 155 characters), else nil.
    static func validHost(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.utf8.count <= 155,
              s.unicodeScalars.allSatisfy({ ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || $0 == "." || $0 == "-" }),
              s.first != ".", s.last != "." else { return nil }
        return s
    }

    // MARK: Recent dictations and the clipboard

    /// The keyboard's Recent row keeps a dictation this long, and at most `recentCap` of them.
    static let recentMaxAge: TimeInterval = 24 * 60 * 60
    static let recentCap = 10

    /// The newest `cap` items no older than `maxAge`, in their order. Pure.
    static func keepRecent<T>(_ list: [T], date: (T) -> Date, now: Date, cap: Int = recentCap, maxAge: TimeInterval = recentMaxAge) -> [T] {
        Array(list.filter { now.timeIntervalSince(date($0)) <= maxAge }.prefix(cap))
    }

    /// A dictation Verbose puts on the clipboard by itself stays this long, on this iPhone only.
    static let clipboardLifetime: TimeInterval = 2 * 60
}
