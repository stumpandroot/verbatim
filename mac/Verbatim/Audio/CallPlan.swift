import Foundation

// Recording a call before it starts (mockup "Verbose Call Recording", November 3, 2026): the pure parts. Which call
// apps a wait is for and when it fires, which calendar events have a call link and which one is next, and when a call
// has ended. Foundation only, so mac/tools/test-calls.sh compiles it with Audio/MeetingDetect.swift on Linux with no
// Xcode. Nothing here records, reads a calendar, or uses the network: App/MeetingCoordinator.swift and
// App/CallCalendar.swift feed it, and every wait starts from a click (Verbose never records on its own).

// MARK: - Call services and their links

/// A call service a calendar event can link to.
enum CallService: String, CaseIterable, Codable, Sendable {
    case zoom, meet, teams, webex, facetime

    /// The name on Home and in the menu bar ("Zoom · 4 people").
    var name: String {
        switch self {
        case .zoom: return "Zoom"
        case .meet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .webex: return "Webex"
        case .facetime: return "FaceTime"
        }
    }

    /// Google Meet runs in a browser: Verbose sees the browser using the microphone, not Meet.
    var runsInBrowser: Bool { self == .meet }

    /// The meeting apps (`MeetingApps` keys) a wait for this service is for: the app, or every known browser for Meet.
    var appKeys: [String] {
        switch self {
        case .zoom: return ["us.zoom.xos"]
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .webex: return ["cisco-systems.spark", "com.webex.meetingmanager"]
        case .facetime: return ["com.apple.facetime"]
        case .meet: return MeetingApps.known.filter(\.isBrowser).map(\.key)
        }
    }
}

enum CallLinks {
    /// The first call link in an event's fields, read in the order given (its URL, then location, then notes). Links
    /// wrapped by a mail filter ("…safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams…") are read through.
    static func find(in fields: [String?]) -> (service: CallService, link: String)? {
        for field in fields {
            guard let text = field, !text.isEmpty else { continue }
            if let hit = scan(text) { return hit }
            if let decoded = text.removingPercentEncoding, decoded != text, let hit = scan(decoded) { return hit }
        }
        return nil
    }

    /// Every http(s) address in the text, checked in order.
    private static func scan(_ text: String) -> (service: CallService, link: String)? {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>"'()\[\]]+"#, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var whole = ns.substring(with: m.range)
            while let last = whole.last, ".,;:!?".contains(last) { whole.removeLast() }
            // The address itself, then any address inside it (a redirect's "?url=https://…").
            var starts = [whole.startIndex]
            var from = whole.index(after: whole.startIndex)
            while let r = whole.range(of: "http", options: .caseInsensitive, range: from..<whole.endIndex) {
                starts.append(r.lowerBound); from = r.upperBound
            }
            for st in starts {
                var link = String(whole[st...])
                if st != whole.startIndex, let amp = link.firstIndex(of: "&") { link = String(link[..<amp]) }
                if let service = service(of: link) { return (service, link) }
            }
        }
        return nil
    }

    /// The service a link joins, from its host and path; nil for anything else (a Zoom marketing page, a calendar link).
    static func service(of link: String) -> CallService? {
        guard let comps = URLComponents(string: link), let host = comps.host?.lowercased() else { return nil }
        let path = comps.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("zoom.us") || on("zoomgov.com") {
            return ["/j/", "/my/", "/w/", "/s/", "/wc/"].contains { path.hasPrefix($0) } ? .zoom : nil
        }
        if host == "meet.google.com" {
            // A meeting code ("abc-defg-hij") or a lookup link, not the landing page.
            let code = path.split(separator: "/").first.map(String.init) ?? ""
            return code.count >= 8 || path.hasPrefix("/lookup/") ? .meet : nil
        }
        if on("teams.microsoft.com") || on("teams.live.com") {
            return path.contains("meetup-join") || path.hasPrefix("/meet/") || path.contains("/l/meet") ? .teams : nil
        }
        if on("webex.com") {
            return path.hasPrefix("/meet/") || path.hasPrefix("/join/") || path.contains("j.php") || path.hasPrefix("/wbxmjs/")
                || path.hasPrefix("/webappng/sites/") ? .webex : nil
        }
        if host == "facetime.apple.com" { return path.hasPrefix("/join") ? .facetime : nil }
        return nil
    }
}

// MARK: - Calendar calls

/// A calendar event with a call link, as App/CallCalendar.swift reads it.
struct CallEvent: Equatable, Sendable, Identifiable {
    /// The event's identifier plus its start, so each occurrence of a repeating event is its own.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var service: CallService
    var link: String
    /// Other people's display names (you and anyone without a name left out), for the recording's speaker names.
    var attendees: [String] = []
    /// Everyone invited, you included, for "4 people".
    var people: Int = 0

    /// "Zoom · 4 people · 45 min" (Home's Next call card).
    var detail: String {
        var parts = [service.name]
        if people > 1 { parts.append("\(people) people") }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        if minutes > 0 { parts.append(CallSchedule.length(minutes)) }
        return parts.joined(separator: " · ")
    }
}

enum CallSchedule {
    /// The Next call card shows an event from this long before it starts until it ends.
    static let lead: TimeInterval = 30 * 60

    /// Showing now: from `lead` before the start until the end. All-day events never get here (CallCalendar skips them).
    static func showing(_ e: CallEvent, now: Date) -> Bool {
        e.end > now && e.start.addingTimeInterval(-lead) <= now && e.end > e.start
    }

    /// The call for the Next call card: of the events showing now, the one starting closest to now (an earlier start
    /// wins a tie), so at 10:25 a call at 10:30 comes before one that started at 10:00.
    static func next(_ events: [CallEvent], now: Date) -> CallEvent? {
        events.filter { showing($0, now: now) }.min { a, b in
            let da = abs(a.start.timeIntervalSince(now)), db = abs(b.start.timeIntervalSince(now))
            return da != db ? da < db : a.start < b.start
        }
    }

    /// The rest of today's calls after `shown`: not yet started, starting before tomorrow, in start order ("2 more
    /// calls today").
    static func laterToday(_ events: [CallEvent], shown: CallEvent?, now: Date, calendar: Calendar = .current) -> [CallEvent] {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return [] }
        return events.filter { $0.id != shown?.id && $0.start > now && $0.start < tomorrow }.sorted { $0.start < $1.start }
    }

    /// "2 more calls today", "1 more call today".
    static func moreLine(_ n: Int) -> String { n == 1 ? "1 more call today" : "\(n) more calls today" }

    /// "in 12 min", "in 1 hr 5 min", "now" (started up to a minute ago), "started 8 min ago".
    static func relative(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes > 0 { return "in \(length(minutes))" }
        let ago = Int((now.timeIntervalSince(start) / 60).rounded(.down))
        return ago < 1 ? "now" : "started \(length(ago)) ago"
    }

    /// "45 min", "1 hr", "1 hr 30 min".
    static func length(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// The call happening now that a recording started without an event belongs to (the Call tile, or a call app
    /// already on the microphone): of the events from `joinLead` before their start until their end, the one starting
    /// closest to now, and when an app is known (`appKey`), only an event whose service that app holds (any browser
    /// for Meet). Nil when none fits, so an unrelated call never takes a calendar event's title.
    static func current(_ events: [CallEvent], now: Date, appKey: String? = nil) -> CallEvent? {
        events.filter { e in
            e.end > now && e.start.addingTimeInterval(-joinLead) <= now && e.end > e.start
                && (appKey.map { e.service.appKeys.contains($0.lowercased()) } ?? true)
        }.min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    /// How early you can join a call and still have the recording take its event.
    static let joinLead: TimeInterval = 10 * 60

    /// An attendee's name for a speaker name: the calendar's name, else one read from the email address when it holds
    /// a first and last name ("priya.shah@…" is Priya Shah; "info@…" and "pshah@…" give nothing). Calendars that sync
    /// over CalDAV often leave the name out.
    static func displayName(name: String?, email: String?) -> String? {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), n.count >= 2, !n.contains("@") { return n }
        guard var e = (email ?? name)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !e.isEmpty else { return nil }
        if e.hasPrefix("mailto:") { e.removeFirst("mailto:".count) }
        guard let at = e.firstIndex(of: "@") else { return nil }
        let local = e[..<at].split(separator: "+").first.map(String.init) ?? ""
        let parts = local.split(whereSeparator: { ".-_".contains($0) }).map(String.init)
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) else { return nil }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Attendee names for speaker names: trimmed, not an email address, not you, each once (first spelling kept).
    static func attendeeNames(_ names: [String?]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for n in names {
            guard let t = n?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 2, !t.contains("@"),
                  t.lowercased() != "you", seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }
}

// MARK: - Waiting for a call

/// A wait you set up: recording starts, with no prompt, when one of `keys` starts using the microphone. You said yes
/// at setup (the consent sheet showed then, when it needed to), so the start is still your choice.
struct CallWait: Equatable, Sendable {
    /// The meeting apps it waits for (`MeetingApps` keys); every known call app for "Any call app".
    var keys: [String]
    /// "Zoom", "Chrome", "a call app" ("Recording starts when Zoom joins the call").
    var appName: String
    var anyApp: Bool
    /// The calendar event it's for: its title names the recording, its attendees become speaker names.
    var eventID: String? = nil
    var title: String? = nil
    var attendees: [String] = []
    var start: Date? = nil
    var copyNotice: Bool = true
    var armedAt: Date
    /// When it gives up without a call: the event's end, or `CallWait.openLimit` after setup for a call that isn't on
    /// the calendar. Verbose never records hours later on an old yes.
    var expires: Date

    /// How long a wait without an event stays set up.
    static let openLimit: TimeInterval = 3 * 3600

    func expired(now: Date) -> Bool { now >= expires }

    /// "Recording starts when Zoom joins the call." / "…when a call app starts using the microphone."
    var startsLine: String {
        anyApp ? "Recording starts when a call app starts using the microphone." : "Recording starts when \(appName) joins the call."
    }
}

/// One entry in the wait's app picker ("Any call app ⌄").
struct CallWaitChoice: Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var keys: [String]
    var isAny = false
}

enum CallWaitChoices {
    /// Any call app (every app Verbose knows holds calls, in its preferred order), each app once (Teams' and Webex's
    /// two apps together), Google Meet (any browser), then each browser on its own.
    static var all: [CallWaitChoice] {
        var out = [CallWaitChoice(id: "any", name: "Any call app", keys: MeetingApps.known.map(\.key), isAny: true)]
        var byName: [String: Int] = [:]
        for app in MeetingApps.known where !app.isBrowser {
            if let i = byName[app.name] { out[i].keys.append(app.key); continue }
            byName[app.name] = out.count
            out.append(CallWaitChoice(id: app.key, name: app.name, keys: [app.key]))
        }
        out.append(meet)
        for app in MeetingApps.known where app.isBrowser { out.append(CallWaitChoice(id: app.key, name: app.name, keys: [app.key])) }
        return out
    }

    /// Google Meet: Verbose sees the browser using the microphone, so this waits for any browser.
    static let meet = CallWaitChoice(id: "meet", name: "Google Meet", keys: CallService.meet.appKeys)

    /// The choice for a calendar event's service: Zoom's app, or any browser for Google Meet.
    static func forService(_ service: CallService) -> CallWaitChoice {
        if service == .meet { return meet }
        let key = service.appKeys.first ?? ""
        return all.first { !$0.isAny && $0.keys.contains(key) } ?? CallWaitChoice(id: key, name: service.name, keys: service.appKeys)
    }

    /// The wait a choice sets up: for a calendar event until it ends, else for `CallWait.openLimit`.
    static func wait(_ choice: CallWaitChoice, event: CallEvent?, copyNotice: Bool, now: Date) -> CallWait {
        CallWait(keys: choice.keys, appName: choice.isAny ? "a call app" : choice.name, anyApp: choice.isAny,
                 eventID: event?.id, title: event?.title, attendees: event?.attendees ?? [], start: event?.start,
                 copyNotice: copyNotice, armedAt: now,
                 expires: event.map { max($0.end, now.addingTimeInterval(60)) } ?? now.addingTimeInterval(CallWait.openLimit))
    }
}

/// When a wait fires: the first of its apps that has held the microphone for `CallWaitTracker.debounce` seconds, the
/// way the call prompt waits (`MeetingCallTracker.debounce`), so a moment's sound check doesn't start a recording.
struct CallWaitTracker: Equatable {
    static let debounce = MeetingCallTracker.debounce
    /// When each app was first seen holding the microphone, while it still does.
    private(set) var since: [String: Double] = [:]

    /// Feeds who's using the microphone (keys) at `now` seconds; returns the app to record, if the wait fires. Busy:
    /// Verbose is recording or dictating, so it waits until that's done (the call is still on then).
    mutating func update(wait: CallWait?, using: Set<String>, now: Double, busy: Bool = false) -> String? {
        for k in since.keys where !using.contains(k) { since[k] = nil }
        for k in using where since[k] == nil { since[k] = now }
        guard let wait, !busy else { return nil }
        let ready = wait.keys.filter { k in since[k].map { now - $0 >= Self.debounce } ?? false }
        // The wait's own order (Zoom before a browser for "Any call app").
        return ready.first
    }

    mutating func reset() { since = [:] }
}

// MARK: - Stopping when the call ends

/// Settings › Meetings › Stop when the call ends (on by default): while a call records, its app letting go of the
/// microphone for `noticeAfter` seconds shows "Zoom left the call" with Keep recording and Stop now; `grace` seconds
/// later the recording stops and saves. The app coming back to the microphone first takes the banner away. Keep
/// recording stops the watch until the app uses the microphone again and leaves again (a call that dropped and is
/// reconnecting).
struct CallEndWatch: Equatable {
    /// A moment off the microphone (a device switch, a mute that closes the input) isn't the end.
    static let noticeAfter = MeetingCallTracker.endGrace
    /// The banner's countdown: "Recording stops in 15 seconds".
    static let grace: Double = 15

    enum Event: Equatable {
        /// Show "Zoom left the call".
        case left
        /// The app is back on the microphone: hide the banner.
        case back
        /// Stop and save.
        case stop
    }

    /// The call app being recorded (`MeetingApps` key).
    var key: String
    /// The app has used the microphone during this recording. Until it has (a recording started from the menu before
    /// the call joined), its silence says nothing about the call ending.
    private(set) var seen = false
    private(set) var goneSince: Double? = nil
    private(set) var announced = false
    /// Keep recording: no stop until the app comes back and leaves again.
    private(set) var kept = false
    /// Stop was returned; nothing more.
    private(set) var done = false

    init(key: String) { self.key = key }

    mutating func update(using: Set<String>, now: Double) -> Event? {
        guard !done else { return nil }
        if using.contains(key) {
            seen = true
            goneSince = nil
            kept = false
            if announced { announced = false; return .back }
            return nil
        }
        guard seen, !kept else { return nil }
        let gone = goneSince ?? now
        goneSince = gone
        if !announced, now - gone >= Self.noticeAfter { announced = true; return .left }
        if announced, now - gone >= Self.noticeAfter + Self.grace { done = true; return .stop }
        return nil
    }

    /// Keep recording on the banner.
    mutating func keep() { kept = true; announced = false; goneSince = nil }
}

// MARK: - Stills of shared screens

/// Settings › Meetings › Keep stills of shared screens (off by default): while a call records, the call app's window is
/// looked at every `interval` seconds. A frame is kept when it differs enough from the last one kept and looks like a
/// shared screen or slide: a fair amount of text the Mac recognizes, and faces covering little of it, so gallery and
/// speaker views are skipped. App/CallStills.swift measures each frame (ScreenCaptureKit, then Vision); this decides.
enum CallStillRules {
    static let interval: Double = 2
    /// Mean difference of two 16 by 16 gray frames (0 to 1) that counts as a new picture. Lower than an imported
    /// video's (0.12): a new slide often keeps the same layout and background.
    static let threshold = 0.06
    /// Seconds between two kept stills at the least, so scrolling a document doesn't keep every step.
    static let minGap: Double = 6
    /// Stills one recording keeps at most.
    static let limit = 120
    /// Recognized characters a shared screen has at the least (a slide title and a line or two).
    static let minCharacters = 40
    /// Share of the frame the recognized text's boxes cover at the least.
    static let minTextCover = 0.015
    /// Share of the frame faces may cover at the most (one face in a corner thumbnail is fine; a speaker view isn't).
    static let maxFaceCover = 0.08
    /// Faces a frame may hold at the most (a gallery of small faces covers little but is still a gallery).
    static let maxFaces = 2

    /// What Vision found in one frame.
    struct Measure: Equatable, Sendable {
        var characters: Int
        /// Sum of the text boxes' areas over the frame's (0 to 1).
        var textCover: Double
        var faces: Int
        /// Sum of the face boxes' areas over the frame's (0 to 1).
        var faceCover: Double
    }

    /// Text enough, and few, small faces.
    static func looksShared(_ m: Measure) -> Bool {
        m.characters >= minCharacters && m.textCover >= minTextCover && m.faces <= maxFaces && m.faceCover <= maxFaceCover
    }

    /// Worth measuring at all: the first frame, or one that differs enough from the last kept, at least `minGap`
    /// seconds after it, under the limit. Cheap, so Vision runs only on frames that pass.
    static func changed(gray: [UInt8], at: Double, last: (gray: [UInt8], at: Double)?, kept: Int) -> Bool {
        guard kept < limit else { return false }
        guard let last else { return true }
        return at - last.at >= minGap && difference(gray, last.gray) >= threshold
    }

    /// Keep this frame: it changed and looks like a shared screen.
    static func keep(gray: [UInt8], at: Double, measure: Measure, last: (gray: [UInt8], at: Double)?, kept: Int) -> Bool {
        changed(gray: gray, at: at, last: last, kept: kept) && looksShared(measure)
    }

    /// Mean absolute difference of two gray frames, 0 (same) to 1 (black against white). As `VideoStill.difference`.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 1 }
        var sum = 0
        for i in 0..<n { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(n) / 255
    }

    /// The window to look at: the largest of the app's windows that's on screen and big enough to hold a shared
    /// screen (at least 320 by 200 points). Nil when it has none.
    static func pickWindow(_ windows: [(id: UInt32, width: Double, height: Double, onScreen: Bool)]) -> UInt32? {
        windows.filter { $0.onScreen && $0.width >= 320 && $0.height >= 200 }.max { $0.width * $0.height < $1.width * $1.height }?.id
    }
}
