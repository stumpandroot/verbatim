import Foundation

// Meeting capture: the pure parts of noticing a call (App/MeetingCoordinator.swift, Audio/MeetingDetector.swift).
// Which app a microphone user is, when a call has gone on long enough to ask about, one prompt per call, and the
// per-app consent counts. Foundation only, so mac/tools/test-meeting-detect.sh compiles it on Linux with no Xcode.
// Nothing here records, listens to audio, or uses the network: detection only reads which process is using the
// microphone, and every recording starts from a click.

/// An app that holds calls, as Verbose names it in the prompt and the consent sheet.
struct MeetingAppInfo: Equatable {
    /// The app's own bundle ID, lowercased: the key for counts and settings.
    var key: String
    /// The bundle ID as the app spells it, for the process tap (it matches helpers by prefix).
    var bundleID: String
    var name: String
    /// A browser: Verbose can't know it's a meeting, so the prompt names the browser ("Chrome is using your
    /// microphone").
    var isBrowser = false
    /// Its call sound comes from system processes (FaceTime's call daemons, Safari's WebKit processes), so the
    /// meeting's system track taps all system audio except Verbose.
    var globalTap = false
}

enum MeetingApps {
    /// Verbose itself (and any helper it starts): never a call.
    static let ownBundleID = "co.stumpandroot.verbatim"

    /// Known meeting apps, in the order they're preferred when several are running. Browsers come last.
    static let known: [MeetingAppInfo] = [
        MeetingAppInfo(key: "us.zoom.xos", bundleID: "us.zoom.xos", name: "Zoom"),
        MeetingAppInfo(key: "com.microsoft.teams2", bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        MeetingAppInfo(key: "com.microsoft.teams", bundleID: "com.microsoft.teams", name: "Microsoft Teams"),
        MeetingAppInfo(key: "com.apple.facetime", bundleID: "com.apple.FaceTime", name: "FaceTime", globalTap: true),
        MeetingAppInfo(key: "cisco-systems.spark", bundleID: "Cisco-Systems.Spark", name: "Webex"),
        MeetingAppInfo(key: "com.webex.meetingmanager", bundleID: "com.webex.meetingmanager", name: "Webex"),
        MeetingAppInfo(key: "com.tinyspeck.slackmacgap", bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        MeetingAppInfo(key: "com.hnc.discord", bundleID: "com.hnc.Discord", name: "Discord"),
        MeetingAppInfo(key: "com.google.chrome", bundleID: "com.google.Chrome", name: "Chrome", isBrowser: true),
        MeetingAppInfo(key: "company.thebrowser.browser", bundleID: "company.thebrowser.Browser", name: "Arc", isBrowser: true),
        MeetingAppInfo(key: "com.microsoft.edgemac", bundleID: "com.microsoft.edgemac", name: "Edge", isBrowser: true),
        MeetingAppInfo(key: "com.brave.browser", bundleID: "com.brave.Browser", name: "Brave", isBrowser: true),
        MeetingAppInfo(key: "org.mozilla.firefox", bundleID: "org.mozilla.firefox", name: "Firefox", isBrowser: true),
        MeetingAppInfo(key: "com.apple.safari", bundleID: "com.apple.Safari", name: "Safari", isBrowser: true, globalTap: true),
    ]

    /// Processes that use the microphone on another app's behalf, lowercased. `needsRunning`: the process is shared
    /// by every app of its kind (any WebKit app has a GPU process), so it only counts while that app is running.
    static let standIns: [String: (key: String, needsRunning: Bool)] = [
        "com.apple.webkit.gpu": ("com.apple.safari", true),
        "com.apple.webkit.webcontent": ("com.apple.safari", true),
        "com.apple.avconferenced": ("com.apple.facetime", false),
        "org.mozilla.plugincontainer": ("org.mozilla.firefox", false),
    ]

    private static let byKey: [String: MeetingAppInfo] = Dictionary(known.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

    static func info(key: String) -> MeetingAppInfo? { byKey[key.lowercased()] }

    /// Verbose or one of its helpers.
    static func isOwn(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return id == ownBundleID || id.hasPrefix(ownBundleID + ".")
    }

    /// The meeting app a microphone process belongs to: the app itself, a helper whose bundle ID starts with the
    /// app's plus a dot ("com.google.Chrome.helper"), or a stand-in process. `running` holds the lowercased bundle
    /// IDs of running apps; a shared stand-in counts only when its app is among them. Nil for Verbose and for apps
    /// that don't hold calls.
    static func resolve(_ bundleID: String, running: Set<String>) -> MeetingAppInfo? {
        let id = bundleID.lowercased().trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !isOwn(id) else { return nil }
        if let app = byKey[id] { return app }
        if let s = stand(in: id) {
            if s.needsRunning, !running.contains(s.key) { return nil }
            return byKey[s.key]
        }
        return known.first { id.hasPrefix($0.key + ".") }
    }

    private static func stand(in id: String) -> (key: String, needsRunning: Bool)? {
        if let s = standIns[id] { return s }
        return standIns.first { id.hasPrefix($0.key + ".") }?.value
    }

    /// macOS before 14.4 only says the microphone is in use somewhere, not by whom: the frontmost app if it holds
    /// calls, else the first running meeting app that isn't a browser. A browser in the background isn't guessed.
    static func guess(frontmost: String?, running: [String]) -> MeetingAppInfo? {
        let set = Set(running.map { $0.lowercased() })
        if let f = frontmost, let app = resolve(f, running: set) { return app }
        return known.first { !$0.isBrowser && set.contains($0.key) }
    }
}

/// Calls in progress, from which meeting apps are using the microphone over time. Decides when to ask: once an
/// app has held the microphone for `debounce` seconds, once per call, never while Verbose is busy with the mic or
/// already recording a meeting. A call ends when its app has let go of the microphone for `endGrace` seconds, so a
/// moment of mute or a device switch doesn't count as a new call.
struct MeetingCallTracker: Equatable {
    static let debounce: Double = 2
    static let endGrace: Double = 4

    struct Call: Equatable {
        var key: String
        var since: Double
        var lastSeen: Double
        /// Asked about, or settled without asking (recorded, turned off for this app, or noticing is off).
        var handled = false
    }

    struct Context: Equatable {
        /// Settings › Meetings › Notice calls and ask to record.
        var enabled = true
        /// Verbose is recording, capturing, dictating, or showing captions: wait; ask once it's done.
        var busy = false
        /// A meeting recording is running: every call now is settled without asking.
        var recordingMeeting = false
        /// Apps you said not to ask about.
        var muted: Set<String> = []
    }

    enum Event: Equatable {
        /// Ask whether to record this app's call.
        case prompt(String)
        /// The call ended (its app let go of the microphone): a prompt still showing for it goes away.
        case ended(String)
    }

    private(set) var calls: [String: Call] = [:]

    /// Feeds the meeting apps holding the microphone right now (keys from `MeetingApps`), at `now` seconds.
    /// Returns at most one prompt: when two apps start together (a browser tab during a Zoom call), the one
    /// preferred in `MeetingApps.known` is asked about and the other is settled with it.
    mutating func update(using: Set<String>, now: Double, context: Context) -> [Event] {
        var events: [Event] = []
        for key in using {
            if calls[key] == nil { calls[key] = Call(key: key, since: now, lastSeen: now) } else { calls[key]?.lastSeen = now }
        }
        for (key, call) in calls where !using.contains(key) && now - call.lastSeen >= Self.endGrace {
            calls[key] = nil
            events.append(.ended(key))
        }
        if context.recordingMeeting || !context.enabled {
            for k in calls.keys { calls[k]?.handled = true }
            return events.sorted(by: Self.order)
        }
        for k in calls.keys where context.muted.contains(k) { calls[k]?.handled = true }
        guard !context.busy else { return events.sorted(by: Self.order) }
        let ready = calls.values.filter { !$0.handled && using.contains($0.key) && now - $0.since >= Self.debounce }
        if let first = ready.sorted(by: { Self.rank($0.key) < Self.rank($1.key) }).first {
            for c in calls.values where !c.handled && using.contains(c.key) { calls[c.key]?.handled = true }
            events.append(.prompt(first.key))
        }
        return events.sorted(by: Self.order)
    }

    /// Marks every call in progress as settled (a meeting recording started from the menu, say).
    mutating func settleAll() { for k in calls.keys { calls[k]?.handled = true } }

    var isIdle: Bool { calls.isEmpty }

    private static func rank(_ key: String) -> Int { MeetingApps.known.firstIndex { $0.key == key } ?? Int.max }
    private static func order(_ a: Event, _ b: Event) -> Bool {
        switch (a, b) {
        case (.ended(let x), .ended(let y)): return x < y
        case (.ended, .prompt): return true
        case (.prompt, .ended): return false
        case (.prompt(let x), .prompt(let y)): return x < y
        }
    }
}

/// What Verbose remembers about each meeting app it noticed: calls seen, recordings started, and your choices.
struct MeetingAppRecord: Codable, Equatable {
    var name: String
    var calls = 0
    var recorded = 0
    var lastSeen: Date? = nil
    /// Settings › Meetings: don't ask when this app uses the microphone.
    var dontAsk = false
    /// The consent sheet's "Don't ask again for <App>", offered after `MeetingAppBook.skipAfter` recordings.
    var skipConsent = false
}

/// Every meeting app's record, by key. Stored as JSON in UserDefaults ("meetings.apps").
struct MeetingAppBook: Codable, Equatable {
    /// Recordings with an app before the consent sheet offers "Don't ask again for <App>".
    static let skipAfter = 5
    var apps: [String: MeetingAppRecord] = [:]

    mutating func noticed(_ key: String, name: String, at date: Date) {
        var r = apps[key] ?? MeetingAppRecord(name: name)
        r.name = name; r.calls += 1; r.lastSeen = date
        apps[key] = r
    }

    mutating func recorded(_ key: String, name: String) {
        var r = apps[key] ?? MeetingAppRecord(name: name)
        r.name = name; r.recorded += 1
        apps[key] = r
    }

    /// The consent sheet shows "Don't ask again for <App>" once you've recorded five calls with it.
    func canOfferSkip(_ key: String) -> Bool { (apps[key]?.recorded ?? 0) >= Self.skipAfter }

    /// The consent sheet shows the first time for each app and on every start after, unless you chose "Don't ask
    /// again" (only possible after five recordings).
    func needsConsent(_ key: String) -> Bool { !(canOfferSkip(key) && (apps[key]?.skipConsent ?? false)) }

    /// Turns the consent sheet off (or back on) for an app. Turning it off is refused before five recordings.
    @discardableResult
    mutating func setSkipConsent(_ key: String, _ on: Bool) -> Bool {
        guard var r = apps[key] else { return false }
        if on && !canOfferSkip(key) { return false }
        r.skipConsent = on
        apps[key] = r
        return true
    }

    mutating func setDontAsk(_ key: String, name: String, _ on: Bool) {
        var r = apps[key] ?? MeetingAppRecord(name: name)
        r.dontAsk = on
        apps[key] = r
    }

    var muted: Set<String> { Set(apps.filter { $0.value.dontAsk }.map(\.key)) }

    /// For Settings: most recently seen first, then by name.
    var sorted: [(key: String, record: MeetingAppRecord)] {
        apps.map { ($0.key, $0.value) }.sorted { a, b in
            let da = a.record.lastSeen ?? .distantPast, db = b.record.lastSeen ?? .distantPast
            return da != db ? da > db : a.record.name < b.record.name
        }
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data?) -> MeetingAppBook {
        guard let data, let b = try? JSONDecoder().decode(MeetingAppBook.self, from: data) else { return MeetingAppBook() }
        return b
    }
}

/// The words of meeting capture (mac/DESIGN.md §8: Google developer documentation style, no exclamation points).
/// Starting points from the meetings report (§8); have a lawyer review them before release.
enum MeetingCopy {
    static let chatNotice = "Heads-up: I'm recording the audio of this call on my computer so I can keep accurate notes. Let me know if you'd rather I didn't."
    static let consentTitle = "Record this meeting?"
    static let consentLaw = "In some places, including California, Florida, Illinois, Pennsylvania, and Washington, everyone on the call must agree before you record."
    static let tellEveryone = "Tell everyone: copy a notice to paste in the chat"
    static let promptDetail = "Record this meeting? Verbose asks every time."
    static let silentDetail = "Check System Settings › Privacy & Security › Screen & System Audio Recording, or keep recording only your mic."
    static let sleptTitle = "Your Mac went to sleep, so the recording paused"
    static let sleptDetail = "Everything before that is saved."

    static func promptTitle(_ app: String) -> String { "\(app) is using your microphone" }
    static func silentTitle(_ app: String) -> String { "Verbose isn't hearing anything from \(app)" }
    static func dontAskAgain(_ app: String) -> String { "Don't ask again for \(app)" }

    /// The consent sheet's first line. `app` is nil when the system track is everything the Mac plays.
    static func consentBody(_ app: String?) -> String {
        if let app { return "Verbose records your microphone and the sound from \(app) on this Mac. Nothing leaves this Mac." }
        return "Verbose records your microphone and the sound other apps play on this Mac. Nothing leaves this Mac."
    }

    /// The recording panel's header: "Recording · Zoom + your mic".
    static func recordingHeader(_ app: String?, paused: Bool, micOnly: Bool) -> String {
        let state = paused ? "Paused" : "Recording"
        if micOnly || app == nil { return micOnly ? "\(state) · your mic" : "\(state) · other apps + your mic" }
        return "\(state) · \(app!) + your mic"
    }

    /// "12:04", or "1:02:03" past an hour. Mono in the menu bar and the panel (a running timer).
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
}
