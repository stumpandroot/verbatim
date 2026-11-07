import Foundation

/// Names and a meeting's title from what a call app's windows show, read while a call records (Mac,
/// App/CallWindowReader.swift walks the windows through Accessibility and hands the strings here). Pure Foundation, so
/// mac/tools/test-meeting-names.sh checks it on Linux.
///
/// Why: a FaceTime call with no calendar event kept "FaceTime" as the other speaker's name and "Meeting · FaceTime ·
/// <date>" as its title, though the call window showed the person's name the whole time, and the name was never said
/// out loud.
///
/// - FaceTime and Zoom: the call window's text (static text, titles, and descriptions) and, for FaceTime, its title.
///   A window that shows exactly one name besides yours names the other side; a window showing several (a gallery,
///   FaceTime's list of recent calls) names nobody. Generic interface words ("Mute", "Effects", "12:04",
///   "Connecting…") are never names.
/// - Zoom, Teams, Webex, Slack huddles, and Google Meet or Teams in a browser tab: the window title can carry the
///   meeting's own name ("Meet - Weekly design sync"), which becomes the recording's title. Only a title in the form
///   "Call with Dana Reyes" names a person.
/// - A phone number or an email shown instead of a name is passed on (`handles`) for Contacts to resolve; it's never
///   kept as a name.
enum CallWindowNames {
    /// One window as Accessibility shows it: its title and the strings inside it, in tree order.
    struct Window: Equatable, Sendable {
        var title: String
        var texts: [String] = []
    }

    /// What one read found: at most one other person's name, a phone number or email to look up when no name showed,
    /// and the meeting's name from a window title.
    struct Reading: Equatable, Sendable {
        var names: [String] = []
        var handles: [String] = []
        var meetingTitle: String? = nil
        var isEmpty: Bool { names.isEmpty && handles.isEmpty && meetingTitle == nil }
    }

    enum App: Equatable { case faceTime, zoom, teams, webex, slack, browser, other }

    static func app(_ bundleID: String) -> App {
        switch bundleID.lowercased() {
        case "com.apple.facetime": return .faceTime
        case "us.zoom.xos": return .zoom
        case "com.microsoft.teams", "com.microsoft.teams2": return .teams
        case "cisco-systems.spark", "com.webex.meetingmanager": return .webex
        case "com.tinyspeck.slackmacgap": return .slack
        case "com.google.chrome", "company.thebrowser.browser", "com.microsoft.edgemac", "com.brave.browser", "org.mozilla.firefox",
             "com.apple.safari": return .browser
        default: return .other
        }
    }

    /// Whether the reader walks this app's windows for text. Only FaceTime and Zoom: the others are web views or
    /// Electron, where walking costs the app more and shows chat and documents rather than the call.
    static func readsWindowText(_ bundleID: String) -> Bool { [.faceTime, .zoom].contains(app(bundleID)) }

    /// What the windows of the app with `bundleID` show. `selfNames` (MeetingNames.selfNames) are never the other side.
    static func read(bundleID: String, windows: [Window], selfNames: [String]) -> Reading {
        let kind = app(bundleID)
        var out = Reading()
        var singles: [String] = []
        var handles: [String] = []
        for w in windows {
            if out.meetingTitle == nil, let t = meetingTitle(w.title, app: kind) {
                out.meetingTitle = t
                if let n = nameInTitle(t), !MeetingNames.isSelf(n, selfNames: selfNames) { singles.append(n) }
            }
            guard kind == .faceTime || kind == .zoom, isCallWindow(w, app: kind) else { continue }
            var strings = w.texts
            if kind == .faceTime { strings.insert(w.title, at: 0) }
            let found = candidates(strings, selfNames: selfNames)
            if found.names.count == 1 { singles.append(found.names[0]) }
            else if found.names.isEmpty, found.handles.count == 1 { handles.append(found.handles[0]) }
        }
        let names = merged(singles)
        if names.count == 1 { out.names = names }
        else if names.isEmpty, Set(handles).count == 1 { out.handles = [handles[0]] }
        return out
    }

    /// A window that holds the call, not the app's home: FaceTime's list of calls ("New FaceTime", "Create Link") and
    /// Zoom's Workplace window are left out.
    static func isCallWindow(_ w: Window, app: App) -> Bool {
        switch app {
        case .faceTime:
            let markers = ["new facetime", "create link", "facetime link", "recents"]
            return !w.texts.contains { t in markers.contains(t.trimmingCharacters(in: .whitespaces).lowercased()) }
        case .zoom:
            let t = w.title.lowercased()
            return t.contains("zoom meeting") || t.contains("zoom webinar") || t.trimmingCharacters(in: .whitespaces) == "meeting"
        default:
            return false
        }
    }

    // MARK: Names

    /// The names (yours left out) and phone numbers or emails in a window's strings, each once. A string can hold
    /// several parts ("Dana Reyes, FaceTime Video"); each part is judged on its own. A first name that starts a full
    /// name found too ("Dana" beside "Dana Reyes") is the same person.
    static func candidates(_ strings: [String], selfNames: [String]) -> (names: [String], handles: [String]) {
        var names: [String] = [], handles: [String] = []
        for raw in strings {
            let s = collapse(raw)
            guard !s.isEmpty, s.count <= 200 else { continue }
            let lower = s.lowercased()
            // Your own tile: "Dana Reyes (Me)", "Dana (you)".
            if lower.contains("(me)") || lower.contains("(you)") { continue }
            for part in parts(s) {
                if let h = handle(part) {
                    if !handles.contains(h) { handles.append(h) }
                    continue
                }
                guard let n = name(part), !MeetingNames.isSelf(n, selfNames: selfNames) else { continue }
                names.append(n)
            }
        }
        return (merged(names), handles)
    }

    /// A string as a person's name, with a role marker after it dropped ("Dana Reyes (Host)"), or nil: one to four
    /// words of letters (and ' - .), each capitalized but for name particles inside ("Anna de la Cruz"), some
    /// lowercase somewhere, 2 to 40 characters, and no interface word, app name, or common word among them.
    static func name(_ s: String) -> String? {
        var t = collapse(s)
        t = t.replacingOccurrences(of: #"\s*\((?i:host|co-host|cohost|guest|external|unverified|organizer|presenter)\)$"#, with: "",
                                   options: .regularExpression)
        let words = t.split(separator: " ").map(String.init)
        guard (1...4).contains(words.count), (2...40).contains(t.count), t.contains(where: \.isLowercase) else { return nil }
        for (i, w) in words.enumerated() {
            guard w.allSatisfy({ $0.isLetter || "'’-.".contains($0) }), w.contains(where: \.isLetter) else { return nil }
            let l = w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if i > 0, particles.contains(l) { continue }
            guard let f = w.first, f.isUppercase else { return nil }
            if interfaceWords.contains(l) || functionWords.contains(l) || MeetingNames.genericTitleWords.contains(l) { return nil }
        }
        if words.count == 1, words[0].count < 2 { return nil }
        return t
    }

    /// A phone number (7 to 15 digits, with + ( ) - . and spaces) or an email, tidied; nil otherwise.
    static func handle(_ s: String) -> String? {
        let t = collapse(s)
        if t.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil { return t.lowercased() }
        guard t.range(of: #"^\+?[\d\s().-]+$"#, options: .regularExpression) != nil else { return nil }
        let digits = t.filter(\.isNumber).count
        return (7...15).contains(digits) ? t : nil
    }

    /// A string's parts: split at ", ", " – ", " — ", " - ", " · ", " | ", and new lines.
    private static func parts(_ s: String) -> [String] {
        var out = [s]
        for sep in [", ", " – ", " — ", " - ", " · ", " | ", "\n"] { out = out.flatMap { $0.components(separatedBy: sep) } }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Names each once (ignoring case), a first name alone folded into a full name that starts with it.
    static func merged(_ names: [String]) -> [String] {
        var out: [String] = []
        for n in names {
            let l = n.lowercased()
            if out.contains(where: { $0.lowercased() == l || $0.lowercased().hasPrefix(l + " ") }) { continue }
            if let i = out.firstIndex(where: { l.hasPrefix($0.lowercased() + " ") }) { out[i] = n; continue }
            out.append(n)
        }
        return out
    }

    /// The person in a title like "Call with Dana Reyes" or "Huddle with Dana": one name, not a list.
    static func nameInTitle(_ title: String) -> String? {
        let ns = title as NSString
        guard let m = withName.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let rest = ns.substring(with: m.range(at: 1))
        guard !rest.contains(","), !rest.contains("&"), rest.range(of: #"\band\b"#, options: .regularExpression) == nil else { return nil }
        return name(rest)
    }

    private static let withName = try! NSRegularExpression(pattern: #"^(?i:call|meeting|huddle|chat|facetime|video call)\s+(?i:with)\s+(.+)$"#)

    /// When Contacts has the person, their name as the contact has it: the one contact spelled the same, or the one
    /// whose name holds every word shown ("Dana" with only "Dana Reyes" among `matches`, Contacts' own search for the
    /// name). Otherwise the name as shown.
    static func preferContact(_ name: String, matches: [String]) -> String {
        let l = name.lowercased()
        if let same = matches.first(where: { $0.lowercased() == l }) { return same }
        let words = l.split(separator: " ").map(String.init)
        let fits = matches.filter { m in
            let mw = m.lowercased().split(separator: " ").map(String.init)
            return words.allSatisfy { mw.contains($0) } && mw.first == words.first
        }
        let distinct = Set(fits.map { $0.lowercased() })
        return distinct.count == 1 ? fits[0] : name
    }

    // MARK: Over a call

    /// The reads over one call, folded together: each name with how many reads showed it (a first name joins the full
    /// name it starts), and each meeting title likewise. `names` is most seen first, at most three; `title` is the
    /// one seen most (the first on a tie).
    struct Tally: Equatable {
        private(set) var reads = 0
        private var nameList: [String] = [], nameCounts: [Int] = []
        private var titleList: [String] = [], titleCounts: [Int] = []

        init() {}

        mutating func add(_ r: Reading) {
            reads += 1
            for n in r.names {
                let l = n.lowercased()
                if let i = nameList.firstIndex(where: { $0.lowercased() == l || $0.lowercased().hasPrefix(l + " ") }) {
                    nameCounts[i] += 1
                } else if let i = nameList.firstIndex(where: { l.hasPrefix($0.lowercased() + " ") }) {
                    nameList[i] = n; nameCounts[i] += 1
                } else {
                    nameList.append(n); nameCounts.append(1)
                }
            }
            if let t = r.meetingTitle {
                if let i = titleList.firstIndex(of: t) { titleCounts[i] += 1 } else { titleList.append(t); titleCounts.append(1) }
            }
        }

        var names: [String] {
            Array(nameList.indices.sorted { nameCounts[$0] != nameCounts[$1] ? nameCounts[$0] > nameCounts[$1] : $0 < $1 }.prefix(3).map { nameList[$0] })
        }

        var title: String? {
            titleList.indices.max { titleCounts[$0] != titleCounts[$1] ? titleCounts[$0] < titleCounts[$1] : $0 > $1 }.map { titleList[$0] }
        }
    }

    // MARK: Meeting titles

    /// The meeting's own name in a call app's window title, or nil when the title is only the app's ("Zoom Meeting",
    /// "Microsoft Teams"), a page ("Chat | Dana | Microsoft Teams"), a meeting code ("Meet - abc-defg-hij"), or any
    /// other browser tab.
    static func meetingTitle(_ raw: String, app: App) -> String? {
        let t = tidy(raw)
        guard !t.isEmpty, t.count <= 160 else { return nil }
        switch app {
        case .browser:
            let page = dropping(split(t, by: [" - ", " — ", " – "]), from: browserNames, trailingOnly: true)
            guard let first = page.first else { return nil }
            if first.lowercased() == "meet" || first.lowercased() == "google meet" {
                return usable(page.dropFirst().joined(separator: " - "))
            }
            let joined = page.joined(separator: " - ")
            if joined.lowercased().contains("microsoft teams") { return meetingTitle(joined, app: .teams) }
            return nil
        case .teams:
            let rest = dropping(split(t, by: [" | "]), from: [], trailingOnly: false).filter { !$0.lowercased().hasPrefix("microsoft teams") }
                .filter { !["compact view", "meeting compact view", "meeting view"].contains($0.lowercased()) }
            guard rest.count == 1, !teamsPages.contains(rest[0].lowercased()) else { return nil }
            return usable(rest[0])
        case .zoom:
            let rest = split(t, by: [" - ", " | "]).filter { !zoomPages.contains($0.lowercased()) }
            guard rest.count == 1 else { return nil }
            return usable(rest[0])
        case .webex:
            let rest = split(t, by: [" - ", " | "]).filter { !webexPages.contains($0.lowercased()) }
            guard rest.count == 1, !rest[0].lowercased().contains("personal room") else { return nil }
            return usable(rest[0])
        case .slack:
            guard t.lowercased().contains("huddle") else { return nil }
            let part = split(t, by: [" | ", " - ", " – ", " — "]).first { $0.lowercased().contains("huddle") } ?? ""
            guard !["huddle", "huddles", "huddle in progress"].contains(part.lowercased()) else { return nil }
            return usable(part)
        case .faceTime, .other:
            return nil
        }
    }

    /// A title worth keeping: some letters, not a meeting code, a link, or a word the app shows anyway.
    private static func usable(_ s: String) -> String? {
        let t = tidy(s)
        let l = t.lowercased()
        guard t.filter(\.isLetter).count >= 2, t.count <= 120 else { return nil }
        if t.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil { return nil }
        if l.hasPrefix("http") || l.contains("://") || l.range(of: #"\.(com|org|net|us|io)(/|$)"#, options: .regularExpression) != nil { return nil }
        if genericTitles.contains(l) || zoomPages.contains(l) || teamsPages.contains(l) || webexPages.contains(l) || browserNames.contains(l) { return nil }
        return t
    }

    /// Whitespace collapsed, a tab's unread count ("(3) ") and stray marks at either end dropped.
    private static func tidy(_ s: String) -> String {
        var t = collapse(s)
        t = t.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " •●·|:-–—🔴🔊🔇").union(.whitespaces))
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace && $0 != "\n" }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func split(_ s: String, by seps: [String]) -> [String] {
        var out = [s]
        for sep in seps { out = out.flatMap { $0.components(separatedBy: sep) } }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `parts` without the ones in `names`: from the end only (`trailingOnly`, a browser's name and profile after the
    /// page), or anywhere.
    private static func dropping(_ parts: [String], from names: Set<String>, trailingOnly: Bool) -> [String] {
        guard trailingOnly else { return parts.filter { !names.contains($0.lowercased()) } }
        // The browser's name and anything after it (a profile's name) go.
        if let i = parts.firstIndex(where: { names.contains($0.lowercased()) }), i > 0 { return Array(parts[..<i]) }
        return parts
    }

    // MARK: Word lists

    private static let browserNames: Set<String> = [
        "google chrome", "chrome", "microsoft edge", "edge", "brave", "brave browser", "mozilla firefox", "firefox", "arc", "safari",
    ]
    private static let teamsPages: Set<String> = [
        "chat", "calendar", "activity", "teams", "calls", "files", "apps", "assignments", "onedrive", "communities", "meet", "home",
        "copilot", "people", "approvals", "meeting", "microsoft teams", "teams and channels",
    ]
    private static let zoomPages: Set<String> = [
        "zoom", "zoom meeting", "zoom webinar", "zoom workplace", "zoom.us", "meeting", "webinar", "home", "team chat", "meetings",
        "contacts", "whiteboards", "mail", "calendar", "docs", "scheduler", "clips", "notes", "apps", "settings", "phone", "hub",
        "chat", "participants", "share screen", "zoom meeting controls",
    ]
    private static let webexPages: Set<String> = [
        "webex", "cisco webex", "cisco webex meetings", "webex meetings", "webex app", "meetings", "home", "messaging", "calling",
        "meeting", "contacts", "whiteboards", "vidcast", "webex meeting",
    ]
    private static let genericTitles: Set<String> = [
        "meet", "google meet", "meeting", "new meeting", "untitled", "untitled meeting", "call", "video call", "huddle", "facetime",
        "slack", "teams", "zoom", "webex", "waiting room", "lobby", "joining", "connecting", "home", "new tab", "start page",
    ]

    /// Name particles that stay lowercase inside a name.
    private static let particles: Set<String> = ["de", "da", "del", "della", "di", "van", "von", "der", "den", "la", "le", "du", "bin", "al", "dos", "das", "y", "e"]

    /// Words a call window shows that never make a name.
    static let interfaceWords: Set<String> = [
        "facetime", "zoom", "teams", "microsoft", "webex", "cisco", "slack", "meet", "google", "discord", "mute", "unmute", "muted",
        "camera", "video", "audio", "end", "leave", "effects", "share", "shareplay", "screen", "add", "people", "info",
        "participants", "participant", "chat", "reactions", "react", "record", "recording", "captions", "caption", "live",
        "speaker", "speakers", "microphone", "mic", "grid", "view", "full", "minimize", "close", "hide", "show", "message",
        "messages", "more", "details", "settings", "call", "calling", "calls", "connecting", "ringing", "waiting", "reconnecting",
        "ended", "accept", "decline", "join", "joined", "joining", "left", "recents", "recent", "missed", "incoming", "outgoing",
        "today", "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "mon", "tue", "wed",
        "thu", "fri", "sat", "sun", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "link",
        "copy", "invite", "new", "create", "cancel", "done", "ok", "button", "menu", "toolbar", "window", "sidebar", "back",
        "forward", "filter", "search", "edit", "delete", "remove", "unknown", "portrait", "studio", "light", "background", "blur",
        "gallery", "active", "hand", "raise", "lower", "apps", "whiteboard", "notes", "security", "host", "cohost", "co-host",
        "guest", "me", "you", "picture", "pip", "pause", "resume", "stop", "start", "switch", "flip", "keypad", "contacts",
        "favorites", "voicemail", "phone", "mobile", "work", "iphone", "ipad", "mac", "hd", "connected", "poor",
        "connection", "network", "signal", "bluetooth", "airpods", "headphones", "sound", "volume", "enabled", "disabled",
        "available", "busy", "away", "offline", "online", "status", "open", "play", "everyone", "room", "lobby", "breakout",
        "rooms", "timer", "clock", "duration", "elapsed", "minutes", "seconds", "hours", "minute", "second", "hour",
        "transcript", "companion", "summary", "assistant", "control", "controls", "center", "focus", "presenter", "presenting",
        "hold", "transfer", "dial", "keyboard", "options", "unavailable", "answer", "answered", "declined", "camera's", "ready",
        "spotlight", "pin", "unpin", "rename", "report", "attendees", "attendee", "admit", "allow", "deny",
    ]

    /// Short words that make a string a sentence or a label, not a name.
    private static let functionWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "by", "at", "from", "is", "are", "was", "be", "this",
        "that", "it", "your", "my", "our", "their", "his", "her", "not", "no", "yes", "off", "up", "out", "now", "here", "there",
    ]
}
