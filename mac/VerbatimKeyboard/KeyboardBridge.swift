import Foundation

/// The channel between the Verbatim keyboard and the Verbatim iPhone app. Compiled into both targets.
///
/// A keyboard can't use the microphone or run the speech model (it has a memory limit of about 60 MB and no
/// background time), so the app does both. To make dictation instant, the app holds a *session*:
///
/// 1. Session start (once): the keyboard writes a session request and opens
///    `verbatim://session?start=1&request=<id>&host=<bundle ID>`. The app turns the microphone on, keeps one
///    capture engine running (audio stays in memory; nothing is written to disk), loads the speech model, starts
///    a Live Activity, and switches back to the app you came from. With Start dictating when you come back on
///    (`autoStart`, the default), the link also carries `dictate=<id>`: the keyboard has already written that id as
///    `startID`, and the app begins that dictation the moment the microphone is on, so you can talk as soon as
///    you're back. The keyboard writes `seenID` once it shows that dictation as listening.
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

    /// The App Group's shared defaults, made once per process: each `UserDefaults(suiteName:)` is a new object,
    /// and the keyboard reads these about 10 times a second.
    static let defaults: UserDefaults? = UserDefaults(suiteName: appGroup)

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
        static let seenID = "kb.d.seen"                   // the dictation a keyboard has shown as listening
        static let keyboardVisibleAt = "kb.k.visible"     // Double: when a keyboard was last on screen (about once a second), 0 when it left

        // Dictation state (written by the app)
        static let dictation = "kb.d.id"                  // String UUID: the dictation the fields below describe
        static let phase = "kb.d.phase"                   // Phase.rawValue
        static let level = "kb.d.level"                   // Double 0…1
        static let elapsed = "kb.d.elapsed"               // Double seconds
        static let text = "kb.d.text"                     // String: the text to insert
        static let raw = "kb.d.raw"                       // String: the transcript as spoken
        static let message = "kb.d.message"               // String: why it failed
        // The recording ribbon (the Action button, Control Center, the Dynamic Island; written by the app)
        static let ribbonID = "kb.d.ribbon"               // String UUID: a take the app started itself; a keyboard on screen picks it up
        static let routedAway = "kb.d.routedAway"         // String UUID: a ribbon take that went to the clipboard, so no keyboard inserts it later
        static let levelLabel = "kb.levelLabel"           // "Polished": the cleanup the app applies
        static let snippets = "kb.snippets"               // Data: JSON [Snippet] (trigger and expansion), written by the app
        // Live words while listening (written by the app about 10 times a second, read by the keyboard)
        static let liveSettled = "kb.d.liveSettled"       // String: words that won't change
        static let liveVolatile = "kb.d.liveVolatile"     // String: the newest words, which may still change

        // Polish after inserting (written by the app; the keyboard writes `polishOutcome`)
        static let polishing = "kb.p.pending"             // String UUID: the dictation whose polished text is on its way
        static let polishedID = "kb.p.id"                 // String UUID: the dictation `polishedInserted`/`polishedText` belong to
        static let polishedInserted = "kb.p.inserted"     // String: the text the app handed over first (the rule-based text)
        static let polishedText = "kb.p.text"             // String: the cleaned-up text to swap in
        static let polishOutcome = "kb.p.outcome"         // String: "<id> swapped" or "<id> kept: <why>", for the app's log

        // Settings (written by the app's Settings › Keyboard, read by both)
        static let autoStart = "kb.autoStart"             // Bool, on unless set: the first tap also starts a dictation
        static let polishAfter = "kb.polishAfter"         // Bool, on unless set: insert the fast text, then swap in the polished text
        static let liveWords = "kb.liveWords"             // Bool, on unless set: show words in the keyboard while you talk
    }

    /// Settings › Keyboard › Polish after inserting. On unless turned off.
    static var polishAfter: Bool {
        get { defaults?.object(forKey: Key.polishAfter) as? Bool ?? true }
        set { defaults?.set(newValue, forKey: Key.polishAfter) }
    }

    /// Settings › Keyboard › Show words as you speak. On unless turned off.
    static var liveWords: Bool {
        get { defaults?.object(forKey: Key.liveWords) as? Bool ?? true }
        set { defaults?.set(newValue, forKey: Key.liveWords) }
    }

    // MARK: Polish after inserting

    /// How long after inserting the keyboard still swaps in polished text. Later than this, you've moved on.
    static let polishWindow: TimeInterval = 30

    /// The most time the model gets to polish a dictation in the background: 2 seconds plus 0.05 seconds a word,
    /// at most 10 seconds.
    static func polishBudget(words: Int) -> Double {
        min(10, 2 + 0.05 * Double(max(0, words)))
    }

    enum SwapDecision: Equatable {
        case replace
        case keep(String)
    }

    /// Whether the keyboard may replace the text it inserted with the polished text. Pure, so it's testable.
    ///
    /// - `inserted`: exactly what went into the field (including a leading space).
    /// - `before`: `documentContextBeforeInput` now. iOS can cut it short (often at a paragraph), so a context
    ///   that is itself the end of `inserted` also counts, when it's long enough to be sure (16 characters) or
    ///   starts right after a line break in `inserted`.
    /// - `sameField`: the field's `documentIdentifier` is the one the text went into.
    /// - `age`: seconds since the text went in.
    ///
    /// Anything typed after the inserted text, a moved cursor, another field, or a late answer keeps your text.
    static func polishSwap(inserted: String, polished: String, before: String?, sameField: Bool, age: TimeInterval) -> SwapDecision {
        let clean = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return .keep("the polished text is empty") }
        if inserted.trimmingCharacters(in: .whitespacesAndNewlines) == clean { return .keep("nothing changed") }
        if !sameField { return .keep("a different text field") }
        if age > polishWindow { return .keep("it arrived after \(Int(polishWindow)) s") }
        guard let before, !before.isEmpty else { return .keep("the field doesn't show the text before the cursor") }
        if before.hasSuffix(inserted) { return .replace }
        if inserted.hasSuffix(before) {
            let cut = inserted.index(inserted.endIndex, offsetBy: -before.count)
            let afterBreak = cut > inserted.startIndex && inserted[inserted.index(before: cut)].isNewline
            if before.count >= 16 || afterBreak { return .replace }
            return .keep("too little text before the cursor to be sure")
        }
        return .keep("the text before the cursor changed")
    }

    /// Settings › Keyboard › Start dictating when you come back. On unless turned off.
    static var autoStart: Bool {
        get { defaults?.object(forKey: Key.autoStart) as? Bool ?? true }
        set { defaults?.set(newValue, forKey: Key.autoStart) }
    }

    /// A dictation the app started on its own (the first tap) stops after this long if no keyboard has shown it,
    /// so a microphone you walked away from doesn't keep a take open.
    static let unseenTakeLimit: TimeInterval = 60

    /// True when a dictation the app started from the first tap should stop: no keyboard has shown it yet, and it
    /// has waited `unseenTakeLimit`.
    static func shouldStopUnseenTake(startedAt: Date, seen: Bool, now: Date) -> Bool {
        !seen && now.timeIntervalSince(startedAt) >= unseenTakeLimit
    }

    /// The dictation a keyboard should show when it appears, from the shared state: one that's listening,
    /// transcribing, or done, and that no keyboard has inserted or cancelled yet, and that didn't already go to the
    /// clipboard (a ribbon take with no keyboard on screen, `routedAway`). Nil otherwise.
    static func runningDictation(id: UUID?, phase: Phase?, insertedID: String?, cancelID: UUID?, routedAway: String? = nil) -> (id: UUID, phase: Phase)? {
        guard let id, let phase, [.listening, .transcribing, .done].contains(phase),
              insertedID != id.uuidString, cancelID != id, routedAway != id.uuidString else { return nil }
        return (id, phase)
    }

    /// `runningDictation` read from the App Group.
    static var currentRunningDictation: (id: UUID, phase: Phase)? {
        runningDictation(id: uuid(Key.dictation), phase: phase, insertedID: defaults?.string(forKey: Key.insertedID), cancelID: uuid(Key.cancelID),
                         routedAway: defaults?.string(forKey: Key.routedAway))
    }

    /// A ribbon take a keyboard on screen should pick up and show (then insert): the running dictation is the one
    /// the app started from the Action button, Control Center, or the Dynamic Island. Pure, so it's testable.
    static func ribbonTakeToAdopt(ribbonID: UUID?, running: (id: UUID, phase: Phase)?) -> (id: UUID, phase: Phase)? {
        guard let r = ribbonID, let running, running.id == r else { return nil }
        return running
    }

    /// A snippet as the keyboard sees it: the trigger shown on its chip and the text it inserts. The app writes the
    /// synced list (Store.snippets) here whenever it changes; the keyboard only reads it.
    struct Snippet: Codable, Equatable, Identifiable {
        var id: UUID
        var trigger: String
        var expansion: String
    }

    static func writeSnippets(_ list: [Snippet]) {
        guard let d = defaults else { return }
        let usable = list.filter { !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty && !$0.expansion.isEmpty }
        let data = try? JSONEncoder().encode(usable)
        if d.data(forKey: Key.snippets) == data { return }
        d.set(data, forKey: Key.snippets)
        post(Note.state)
    }

    static func readSnippets() -> [Snippet] {
        guard let data = defaults?.data(forKey: Key.snippets) else { return [] }
        return (try? JSONDecoder().decode([Snippet].self, from: data)) ?? []
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

    static func sessionURL(request: UUID, host: String?, dictation: UUID? = nil) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = sessionHost
        var items = [URLQueryItem(name: "start", value: "1"), URLQueryItem(name: "request", value: request.uuidString)]
        if let host, !host.isEmpty { items.append(URLQueryItem(name: "host", value: host)) }
        if let dictation { items.append(URLQueryItem(name: "dictate", value: dictation.uuidString)) }
        c.queryItems = items
        return c.url!
    }

    struct SessionLink: Equatable { var request: UUID?; var host: String?; var dictation: UUID? = nil; var source: StartSource? = nil }

    /// The request in a `verbatim://session?…` link (or the first keyboard's `verbatim://dictate?…`), or nil for any other link.
    static func sessionLink(in url: URL) -> SessionLink? {
        guard url.scheme == scheme, url.host == sessionHost || url.host == legacyDictateHost else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let request = items.first(where: { $0.name == "request" || $0.name == "session" })?.value.flatMap(UUID.init(uuidString:))
        let host = items.first(where: { $0.name == "host" })?.value
        let dictation = items.first(where: { $0.name == "dictate" })?.value.flatMap(UUID.init(uuidString:))
        let source = items.first(where: { $0.name == "from" })?.value.flatMap(StartSource.init(rawValue:))
        return SessionLink(request: request, host: host?.isEmpty == false ? host : nil, dictation: dictation, source: source)
    }

    /// Where a session start came from when it wasn't the keyboard: Control Center, the Action button or
    /// Shortcuts, the Lock Screen widget, or a button in Verbatim.
    enum StartSource: String { case control, shortcut, widget, app }

    /// `verbatim://session?start=1&from=<source>`: a session with no keyboard request, so nothing switches back
    /// and the start screen tells you how to go back to your app.
    static func sessionURL(from source: StartSource) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = sessionHost
        c.queryItems = [URLQueryItem(name: "start", value: "1"), URLQueryItem(name: "from", value: source.rawValue)]
        return c.url!
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

// MARK: - Recent dictations and copying

/// The keyboard's Recent row and Settings › Keyboard › Also copy each dictation. The app writes each keyboard
/// dictation here as it delivers it (and again when the polished text arrives); the keyboard only reads the list.
/// Small on purpose: at most 10 items of about 2 KB each, so the keyboard's memory limit is never at risk.
extension KeyboardBridge {
    struct Recent: Codable, Equatable, Identifiable {
        var id: UUID
        var text: String
        var date: Date
    }

    static let recentCap = 10
    static let recentMaxBytes = 2_048

    static let recentKey = "kb.recent"              // Data: JSON [Recent], newest first, written by the app
    static let alwaysCopyKey = "kb.alwaysCopy"      // Bool, off unless set: copy each keyboard dictation
    static let copiedKey = "kb.copiedID"            // String UUID: the dictation the app already put on the clipboard

    /// Settings › Keyboard › Also copy each dictation. Off unless turned on.
    static var alwaysCopy: Bool {
        get { defaults?.bool(forKey: alwaysCopyKey) ?? false }
        set { defaults?.set(newValue, forKey: alwaysCopyKey) }
    }

    /// `text` cut to at most `maxBytes` of UTF-8, on a character boundary, with "…" when cut.
    static func clip(_ text: String, maxBytes: Int = recentMaxBytes) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var out = ""
        var bytes = 0
        let budget = maxBytes - "…".utf8.count
        for ch in text {
            let n = String(ch).utf8.count
            if bytes + n > budget { break }
            out.append(ch)
            bytes += n
        }
        return out + "…"
    }

    /// The list with `item` first (replacing an older copy of the same dictation), clipped and capped. Pure.
    static func addingRecent(_ list: [Recent], _ item: Recent, cap: Int = recentCap) -> [Recent] {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return list }
        let clipped = Recent(id: item.id, text: clip(text), date: item.date)
        return Array(([clipped] + list.filter { $0.id != item.id }).prefix(cap))
    }

    /// The list with one dictation's text replaced (the polished text), in place. Pure.
    static func replacingRecent(_ list: [Recent], id: UUID, text: String) -> [Recent] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return list }
        return list.map { $0.id == id ? Recent(id: id, text: clip(clean), date: $0.date) : $0 }
    }

    static func readRecent() -> [Recent] {
        guard let data = defaults?.data(forKey: recentKey) else { return [] }
        return (try? JSONDecoder().decode([Recent].self, from: data)) ?? []
    }

    private static func writeRecent(_ list: [Recent]) {
        guard let d = defaults, let data = try? JSONEncoder().encode(list) else { return }
        d.set(data, forKey: recentKey)
    }

    /// Called by the app as it delivers a keyboard dictation.
    static func addRecent(id: UUID, text: String, date: Date = Date()) {
        writeRecent(addingRecent(readRecent(), Recent(id: id, text: text, date: date)))
    }

    /// Called by the app when the polished text for a dictation arrives.
    static func updateRecent(id: UUID, text: String) {
        let list = readRecent()
        let updated = replacingRecent(list, id: id, text: text)
        if updated != list { writeRecent(updated) }
    }
}
