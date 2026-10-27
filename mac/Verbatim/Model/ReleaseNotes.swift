import Foundation

// What each build added (What's new): mac/ReleaseNotes/ReleaseNotes.json, bundled in the Mac and iPhone apps. The
// newest entry comes first; its build is "next" until CI stamps it with the run number, in the build's checkout only
// (mac/ReleaseNotes/README.md). Foundation only, so mac/tools/test-release-notes.sh compiles it on Linux.
//
// After an update to a build with an entry, Home shows "What's new in build N" once (a banner on iPhone, a line on
// the Mac). The last build shown is in UserDefaults (`lastSeenKey`); dismissing the note or opening What's new sets it.
// What's new groups the builds by version ("Version 1.0 beta"), newest first (mac/VERSIONING.md).

/// One build's notes: "Build 203 · Oct 25", a title, and bullet items.
struct ReleaseNote: Decodable, Identifiable, Hashable, Sendable {
    /// The run number as a string ("203"), or "next" in a build that wasn't stamped (one from Xcode).
    var build: String
    /// YYYY-MM-DD; absent on "next".
    var date: String?
    var title: String
    var items: [String]
    /// The version the build belongs to ("1.0 beta"), stamped by CI with the build number. Absent on "next" and on
    /// every entry from before versions were recorded, which count as `ReleaseNotes.firstVersion`.
    var version: String? = nil

    var id: String { build }
    /// "1.0 beta": the version this build is grouped under in What's new.
    var versionName: String {
        let v = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? ReleaseNotes.firstVersion : v
    }
    var number: Int? { Int(build) }
    var isNext: Bool { build == ReleaseNotes.next }

    /// "Build 203 · Oct 25", "Build 203" with no date, or "Next build" before CI stamps it.
    var heading: String {
        guard let number else { return "Next build" }
        guard let day = ReleaseNotes.day(date, format: "MMM d") else { return "Build \(number)" }
        return "Build \(number) · \(day)"
    }

    /// What VoiceOver reads for the heading: "Build 203, October 25".
    var spokenHeading: String {
        guard let number else { return "Next build" }
        guard let day = ReleaseNotes.day(date, format: "MMMM d") else { return "Build \(number)" }
        return "Build \(number), \(day)"
    }
}

/// One version's builds in What's new: "Version 1.0 beta" over its builds, newest first.
struct ReleaseVersion: Identifiable, Hashable, Sendable {
    var name: String
    var notes: [ReleaseNote]
    var id: String { name }
    /// "Version 1.0 beta"
    var heading: String { "Version \(name)" }
    /// "Version 1.0 beta, 40 builds": the header's VoiceOver label.
    var spokenHeading: String { "Version \(name), \(notes.count) build\(notes.count == 1 ? "" : "s")" }
}

/// The version people see (mac/VERSIONING.md): the marketing version (CFBundleShortVersionString, kept numeric for
/// App Store Connect), the channel (VerboseChannel: "beta" until launch, empty for the App Store release), and the
/// build number (CFBundleVersion). Settings, About, and What's new show "Version 1.0 beta (217)".
enum AppVersion {
    static let channelKey = "VerboseChannel"

    static var marketing: String { info("CFBundleShortVersionString") ?? "1.0" }
    static var channel: String { info(channelKey) ?? "" }
    static var build: String { info("CFBundleVersion") ?? "1" }
    /// "1.0 beta", or "1.0" with no channel.
    static var name: String { name(marketing: marketing, channel: channel) }
    /// "1.0 beta (217)"
    static var label: String { label(marketing: marketing, channel: channel, build: build) }
    /// "1.0 beta, build 217", for VoiceOver.
    static var spoken: String { "\(name), build \(build)" }

    static func name(marketing: String, channel: String) -> String {
        let c = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? marketing : "\(marketing) \(c)"
    }

    static func label(marketing: String, channel: String, build: String) -> String {
        "\(name(marketing: marketing, channel: channel)) (\(build))"
    }

    /// App Store Connect takes only numbers and dots ("1.0", "1.2.3") as CFBundleShortVersionString.
    static func isNumeric(_ marketing: String) -> Bool {
        let parts = marketing.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    private static func info(_ key: String) -> String? {
        guard let s = (Bundle.main.infoDictionary?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }
}

enum ReleaseNotes {
    static let next = "next"
    /// Every build before versions were recorded in the file was 1.0 beta.
    static let firstVersion = "1.0 beta"
    /// The highest build whose note was shown or dismissed (an Int), per device.
    static let lastSeenKey = "releaseNotes.lastSeenBuild"

    private struct File: Decodable { var notes: [ReleaseNote] }

    static func parse(_ data: Data) throws -> [ReleaseNote] {
        try JSONDecoder().decode(File.self, from: data).notes
    }

    /// The bundled notes, newest first; empty if the file is missing or broken (What's new then says so).
    static let bundled: [ReleaseNote] = {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url), let notes = try? parse(data) else { return [] }
        return notes
    }()

    /// This app's build number (CFBundleVersion), when it's a number.
    static var currentBuild: Int? {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap { Int($0) }
    }

    /// The rules CI and the Linux test hold the file to, as sentences; empty when it's fine. Mirrors
    /// release_notes.py's `check`.
    static func problems(_ notes: [ReleaseNote]) -> [String] {
        var out: [String] = []
        if notes.isEmpty { out.append("there are no entries") }
        var last: Int? = nil
        var nexts = 0
        for (i, n) in notes.enumerated() {
            if n.isNext {
                nexts += 1
                if i != 0 { out.append("the \"next\" entry must come first") }
            } else if let number = n.number, number > 0, String(number) == n.build {
                if let last, number >= last { out.append("build \(number) comes after \(last); builds must go down, newest first") }
                last = number
                if n.date == nil { out.append("build \(number) has no date") }
            } else {
                out.append("entry \(i + 1): build must be \"next\" or a run number, not \"\(n.build)\"")
            }
            if let v = n.version, v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("build \(n.build): version must be a name such as \"1.0 beta\", not empty") }
            if let date = n.date, day(date, format: "MMM d") == nil { out.append("build \(n.build): date must be YYYY-MM-DD, not \"\(date)\"") }
            if n.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("build \(n.build) has no title") }
            if n.items.isEmpty || n.items.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                out.append("build \(n.build) needs one or more items, none empty")
            }
        }
        if nexts > 1 { out.append("there are \(nexts) \"next\" entries; keep one") }
        return out
    }

    /// What's new's sections: the builds grouped by version, in the file's order (newest first), each build once.
    static func byVersion(_ notes: [ReleaseNote]) -> [ReleaseVersion] {
        var out: [ReleaseVersion] = []
        for n in notes {
            if let i = out.firstIndex(where: { $0.name == n.versionName }) { out[i].notes.append(n) }
            else { out.append(ReleaseVersion(name: n.versionName, notes: [n])) }
        }
        return out
    }

    /// A build's items for one device, in the file's order within each part: first the ones for this device ("iPhone:"
    /// on iPhone, and "Mac and iPhone:"), then the ones with no device named, and apart from them the ones only for the
    /// other device ("Mac:" on iPhone), which What's new folds under "On your Mac".
    static func split(_ items: [String], phone: Bool) -> (here: [String], other: [String]) {
        let mine = phone ? "iPhone:" : "Mac:", theirs = phone ? "Mac:" : "iPhone:"
        var first: [String] = [], unnamed: [String] = [], other: [String] = []
        for item in items {
            let t = item.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(theirs) { other.append(item) }
            else if t.hasPrefix(mine) || t.hasPrefix("Mac and iPhone:") || t.hasPrefix("iPhone and Mac:") { first.append(item) }
            else { unnamed.append(item) }
        }
        return (first + unnamed, other)
    }

    /// The entry for a build number.
    static func note(for build: Int, in notes: [ReleaseNote]) -> ReleaseNote? {
        notes.first { $0.number == build }
    }

    /// The build Home's note is about, or nil: this build has an entry and is newer than the last one shown.
    static func pending(current: Int?, lastSeen: Int, notes: [ReleaseNote]) -> ReleaseNote? {
        guard let current, current > lastSeen else { return nil }
        return note(for: current, in: notes)
    }

    /// What to store as the last build seen at launch, or nil to leave it. A new install starts at its own build, so
    /// it shows no note until the next update; an install that ran before this setting existed stores nothing, so it
    /// sees this build's note once.
    static func firstLastSeen(stored: Int?, current: Int?, ranBefore: Bool) -> Int? {
        guard stored == nil, !ranBefore, let current else { return nil }
        return current
    }

    /// Run once at launch, before Home shows.
    static func settleLastSeen(ranBefore: Bool, defaults: UserDefaults = .standard) {
        let stored = defaults.object(forKey: lastSeenKey) == nil ? nil : defaults.integer(forKey: lastSeenKey)
        if let first = firstLastSeen(stored: stored, current: currentBuild, ranBefore: ranBefore) {
            defaults.set(first, forKey: lastSeenKey)
        }
    }

    /// Marks this build's note as shown (dismissed, or What's new opened). Never moves back.
    static func markSeen(defaults: UserDefaults = .standard) {
        guard let current = currentBuild, current > defaults.integer(forKey: lastSeenKey) else { return }
        defaults.set(current, forKey: lastSeenKey)
    }

    /// The self-tests' checks (UITest.swift, PhoneUITest.swift): the notes are in the app, follow the rules, and Home's
    /// note shows once after an update.
    static func selfTest(_ check: (String, Bool) -> Void) {
        check("release notes: ReleaseNotes.json is in the app", !bundled.isEmpty)
        let found = problems(bundled)
        check("release notes: they follow the rules\(found.isEmpty ? "" : " (" + found.joined(separator: "; ") + ")")", found.isEmpty)
        if let newest = bundled.first(where: { $0.number != nil }), let n = newest.number {
            check("release notes: the newest build reads Build \(n) · <date>", newest.heading.hasPrefix("Build \(n) · "))
            check("release notes: Home's note shows after an update to build \(n)", pending(current: n, lastSeen: n - 1, notes: bundled) == newest)
            check("release notes: and not again once seen", pending(current: n, lastSeen: n, notes: bundled) == nil)
        }
        check("release notes: a new install starts at its own build", firstLastSeen(stored: nil, current: 300, ranBefore: false) == 300)
        let versions = byVersion(bundled)
        check("release notes: grouped by version, the newest build in the first group", versions.first?.notes.first == bundled.first)
        check("release notes: every build in exactly one version", versions.flatMap(\.notes).count == bundled.count && Set(versions.map(\.name)).count == versions.count)
        check("version: CFBundleShortVersionString \(AppVersion.marketing) is numbers only (App Store Connect)", AppVersion.isNumeric(AppVersion.marketing))
        check("version: this build reads Version \(AppVersion.label)",
              AppVersion.label == "\(AppVersion.marketing)\(AppVersion.channel.isEmpty ? "" : " " + AppVersion.channel) (\(AppVersion.build))")
    }

    /// "Oct 25" (or another `format`) from "2026-10-25"; nil when the date isn't YYYY-MM-DD.
    static func day(_ date: String?, format: String) -> String? {
        guard let date, date.count == 10 else { return nil }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(identifier: "UTC")
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: date) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = format
        return out.string(from: d)
    }
}
