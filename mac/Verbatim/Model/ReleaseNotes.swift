import Foundation

// What each build added (What's new): mac/ReleaseNotes/ReleaseNotes.json, bundled in the Mac and iPhone apps. The
// newest entry comes first; its build is "next" until CI stamps it with the run number, in the build's checkout only
// (mac/ReleaseNotes/README.md). Foundation only, so mac/tools/test-release-notes.sh compiles it on Linux.
//
// After an update to a build with an entry, Home shows "What's new in build N" once (a banner on iPhone, a line on
// the Mac). The last build shown is in UserDefaults (`lastSeenKey`); dismissing the note or opening What's new sets it.
// What's new groups the builds by version ("Version 1.0 beta"), newest first (mac/VERSIONING.md), and each build's
// items by platform, this device's first (`ReleaseNotes.summary`, which release_notes.py's `summary` matches for
// Sparkle, GitHub, and TestFlight).

/// A device an item is about. The order is the GitHub release's: Mac, iPhone, Apple Watch.
enum ReleasePlatform: String, CaseIterable, Hashable, Sendable {
    case mac, iphone, watch

    /// "Mac", "iPhone", "Apple Watch": the section header.
    var name: String {
        switch self {
        case .mac: return "Mac"
        case .iphone: return "iPhone"
        case .watch: return "Apple Watch"
        }
    }
}

/// Which app shows What's new: its own platforms lead, and the rest fold under "Also on …".
enum ReleaseApp: Sendable {
    case phone, mac

    /// The iPhone app leads with iPhone, then Apple Watch; the Mac app with Mac.
    var own: [ReleasePlatform] { self == .phone ? [.iphone, .watch] : [.mac] }
    var other: [ReleasePlatform] { self == .phone ? [.mac] : [.iphone, .watch] }
}

/// One change: the platforms it's for, a line of about 12 words, and an optional one-sentence detail that shows when
/// the line is tapped or clicked. In the file it's an object, `{"platforms": ["iphone"], "text": "…", "detail": "…"}`,
/// or, in builds from before platforms were recorded, a string whose "Mac:", "iPhone:", "Apple Watch:", or "Mac and
/// iPhone:" style prefix gives its platforms (no prefix: both apps). The prefix is taken off the text.
struct ReleaseItem: Decodable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// The platforms as written, including any that aren't valid (`problems` reports them).
    var platformNames: [String]
    var text: String
    var detail: String?
    /// Written as a string (an older build).
    var isLegacy = false

    /// The valid platforms in the file's order; none counts as both apps.
    var platforms: [ReleasePlatform] {
        let found = platformNames.compactMap(ReleasePlatform.init(rawValue:))
        return found.isEmpty ? [.iphone, .mac] : found
    }

    init(platforms: [ReleasePlatform], text: String, detail: String? = nil) {
        self.platformNames = platforms.map(\.rawValue)
        self.text = text
        self.detail = detail
    }

    /// An item from an older build's string, its platform prefix read and taken off.
    init(legacy raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        isLegacy = true
        detail = nil
        if let found = ReleaseNotes.legacyPrefix(s) {
            platformNames = found.platforms.map(\.rawValue)
            text = found.text
        } else {
            platformNames = [ReleasePlatform.iphone.rawValue, ReleasePlatform.mac.rawValue]
            text = s
        }
    }

    init(stringLiteral value: String) { self.init(legacy: value) }

    private enum Key: String, CodingKey { case platforms, text, detail }

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = ReleaseItem(legacy: s)
            return
        }
        // Lenient: a wrong type reads as missing, so one bad item never empties What's new; `problems` reports it.
        let c = try decoder.container(keyedBy: Key.self)
        platformNames = ((try? c.decodeIfPresent([String].self, forKey: .platforms)) ?? nil) ?? []
        text = (((try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = (((try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        detail = d.isEmpty ? nil : d
        hasDetailKey = c.contains(.detail)
    }

    /// The object had a "detail" key, even an empty one (`problems` reports an empty detail).
    var hasDetailKey = false
}

/// One platform's items in a build: "iPhone" over its lines.
struct ReleaseSection: Identifiable, Hashable, Sendable {
    var platform: ReleasePlatform
    var items: [ReleaseItem]
    var id: String { platform.rawValue }
    var title: String { platform.name }
}

/// A build's items for one app: its own platforms' sections, then the other platforms' sections under one collapsed
/// row ("Also on Mac", "Also on iPhone and Apple Watch").
struct ReleaseSummary: Hashable, Sendable {
    var sections: [ReleaseSection]
    var also: [ReleaseSection]
    /// "Also on Mac", "Also on iPhone and Apple Watch", or empty when nothing folds.
    var alsoTitle: String {
        let names = also.map(\.title)
        return names.isEmpty ? "" : "Also on " + ReleaseNotes.joined(names)
    }
    var alsoCount: Int { also.reduce(0) { $0 + $1.items.count } }
}

/// One build's notes: "Build 203 · Oct 25", a title, and items sorted by platform.
struct ReleaseNote: Decodable, Identifiable, Hashable, Sendable {
    /// The run number as a string ("203"), or "next" in a build that wasn't stamped (one from Xcode).
    var build: String
    /// YYYY-MM-DD; absent on "next".
    var date: String?
    var title: String
    var items: [ReleaseItem]
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

    /// This app's build number (CFBundleVersion), when it's a number. The public TestFlight track's "250.1" counts as
    /// 250, whose notes it carries.
    static var currentBuild: Int? {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(buildNumber)
    }

    /// "250" and "250.1" are 250; anything else is nil.
    static func buildNumber(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return Int(parts[0])
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
            if n.items.isEmpty { out.append("build \(n.build) needs one or more items") }
            for (j, item) in n.items.enumerated() {
                out += itemProblems(item, where: "build \(n.build), item \(j + 1)", inNext: n.isNext)
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

    /// The longest line and detail (characters, as Python counts them: Unicode scalars).
    static let textMax = 90, detailMax = 200

    /// What's wrong with one item, as sentences. Mirrors release_notes.py's `item_problems`: strings are fine only in
    /// numbered entries; objects need valid platforms, a line of at most 90 characters, an optional detail of at most
    /// 200, each ending with a period, no platform prefix, and no em dash or exclamation point.
    static func itemProblems(_ item: ReleaseItem, where at: String, inNext: Bool) -> [String] {
        if item.isLegacy {
            if inNext { return ["\(at) is a string; write it as {\"platforms\": [...], \"text\": \"...\"} (README.md)"] }
            return item.text.isEmpty ? ["\(at) is empty"] : []
        }
        var out: [String] = []
        if item.platformNames.isEmpty {
            out.append("\(at) needs platforms, a list of mac, iphone, watch")
        } else {
            let bad = item.platformNames.filter { ReleasePlatform(rawValue: $0) == nil }
            if !bad.isEmpty { out.append("\(at): platforms must be mac, iphone, watch, not \(bad.joined(separator: ", "))") }
            if Set(item.platformNames).count != item.platformNames.count { out.append("\(at) names a platform twice") }
        }
        if item.text.isEmpty {
            out.append("\(at) has no text")
        } else {
            out += lineProblems(item.text, where: "\(at)'s text", limit: textMax)
            if legacyPrefix(item.text) != nil { out.append("\(at) starts with a platform; platforms say that") }
        }
        if let d = item.detail {
            out += lineProblems(d, where: "\(at)'s detail", limit: detailMax)
        } else if item.hasDetailKey {
            out.append("\(at): detail must be a sentence; leave it out when there's nothing to add")
        }
        return out
    }

    private static func lineProblems(_ s: String, where at: String, limit: Int) -> [String] {
        var out: [String] = []
        let n = s.unicodeScalars.count
        if n > limit { out.append("\(at) is \(n) characters; keep it to \(limit)") }
        if s.contains("\u{2014}") { out.append("\(at) has an em dash") }
        if s.contains("!") { out.append("\(at) has an exclamation point") }
        if !(s.hasSuffix(".") || s.hasSuffix(".)")) { out.append("\(at) doesn't end with a period") }
        return out
    }

    /// The prefixes older items name their platforms with, longest first: "Mac and iPhone:", and so on.
    private static let legacyPrefixes: [(String, [ReleasePlatform])] = [
        ("Mac and iPhone", [.iphone, .mac]), ("iPhone and Mac", [.iphone, .mac]), ("Apple Watch", [.watch]),
        ("iPhone", [.iphone]), ("Mac", [.mac]),
    ]

    /// An older item's platforms and its text without the prefix: "Mac: press ⌘K" is the Mac's "Press ⌘K", and "Mac
    /// Home: the tile" (a platform and an area) the Mac's "Home: the tile". Nil without a prefix. Matches
    /// release_notes.py's `legacy_prefix`: the prefix, an optional ASCII word, a colon, then at least one space.
    static func legacyPrefix(_ s: String) -> (platforms: [ReleasePlatform], text: String)? {
        for (prefix, platforms) in legacyPrefixes where s.hasPrefix(prefix) {
            var rest = Substring(s.dropFirst(prefix.count))
            var area = ""
            if rest.first == " " {
                let word = rest.dropFirst().prefix { $0.isASCII && $0.isLetter }
                guard !word.isEmpty else { continue }
                area = String(word)
                rest = rest.dropFirst(1 + word.count)
            }
            guard rest.first == ":", let next = rest.dropFirst().first, next.isWhitespace else { continue }
            let text = String(rest.dropFirst().drop { $0.isWhitespace })
            if !area.isEmpty { return (platforms, area.prefix(1).uppercased() + area.dropFirst() + ": " + text) }
            return (platforms, capitalized(text))
        }
        return nil
    }

    /// The first letter in capitals, unless the first word already has one ("iPhone", "⌘K").
    static func capitalized(_ s: String) -> String {
        let word = s.prefix { $0 != " " }
        guard let first = s.first, !word.contains(where: \.isUppercase) else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// "Mac", "iPhone and Apple Watch", or "Mac, iPhone, and Apple Watch".
    static func joined(_ names: [String]) -> String {
        guard names.count > 2 else { return names.joined(separator: " and ") }
        return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
    }

    /// A build's items for one app, the one order every renderer uses (release_notes.py's `summary` matches it): the
    /// app's own platforms in order (iPhone, then Apple Watch; or Mac), then the other platforms under "Also on …".
    /// Each item appears once, under the first of the app's platforms it names, or else the first other platform it
    /// names, in the file's order within each section. Empty sections are left out.
    static func summary(_ items: [ReleaseItem], for app: ReleaseApp) -> ReleaseSummary {
        func first(_ item: ReleaseItem, in order: [ReleasePlatform]) -> ReleasePlatform? {
            order.first { item.platforms.contains($0) }
        }
        let sections = app.own.map { p in ReleaseSection(platform: p, items: items.filter { first($0, in: app.own) == p }) }
        let also = app.other.map { p in
            ReleaseSection(platform: p, items: items.filter { first($0, in: app.own) == nil && first($0, in: app.other) == p })
        }
        return ReleaseSummary(sections: sections.filter { !$0.items.isEmpty }, also: also.filter { !$0.items.isEmpty })
    }

    /// Every platform with its items, Mac, iPhone, then Apple Watch (the GitHub release): an item for two is in both.
    static func byPlatform(_ items: [ReleaseItem]) -> [ReleaseSection] {
        ReleasePlatform.allCases.map { p in ReleaseSection(platform: p, items: items.filter { $0.platforms.contains(p) }) }
            .filter { !$0.items.isEmpty }
    }

    /// The UI self-tests' hook to open a line's detail or the "Also on" row in What's new, for their screenshots.
    /// The notification's object is "detail" or "also".
    static let showForTest = Notification.Name("releaseNotes.showForTest")

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
    static func selfTest(app: ReleaseApp, _ check: (String, Bool) -> Void) {
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
        // Platforms: this app's own items lead, the rest fold under one "Also on" row, and nothing is lost or repeated.
        let device = app == .phone ? "iPhone" : "Mac"
        if let top = bundled.first {
            let sum = summary(top.items, for: app)
            let placed = sum.sections.flatMap(\.items) + sum.also.flatMap(\.items)
            check("release notes: What's new on the \(device) shows each of build \(top.build)'s items once", placed.count == top.items.count && Set(placed) == Set(top.items))
            if let own = sum.sections.first {
                check("release notes: What's new on the \(device) leads with \(own.title), one of its own platforms", app.own.contains(own.platform))
            }
            check("release notes: the other platforms fold under one row (\(sum.alsoTitle.isEmpty ? "none" : sum.alsoTitle))",
                  sum.also.allSatisfy { app.other.contains($0.platform) } && (sum.also.isEmpty == sum.alsoTitle.isEmpty))
            if top.isNext || top.items.contains(where: { !$0.isLegacy }) {
                check("release notes: build \(top.build)'s items name their platforms", top.items.allSatisfy { !$0.isLegacy })
            }
        }
        let sample: [ReleaseItem] = [ReleaseItem(platforms: [.mac], text: "M."), ReleaseItem(platforms: [.iphone, .mac], text: "B.", detail: "D."),
                                     ReleaseItem(platforms: [.watch], text: "W."), ReleaseItem(platforms: [.iphone], text: "I.")]
        let mine = summary(sample, for: app)
        check("release notes: a change for both apps is in the \(device)'s own section", mine.sections.first?.items.contains(sample[1]) == true)
        check("release notes: the fold reads \(app == .phone ? "Also on Mac" : "Also on iPhone and Apple Watch")",
              mine.alsoTitle == (app == .phone ? "Also on Mac" : "Also on iPhone and Apple Watch"))
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
