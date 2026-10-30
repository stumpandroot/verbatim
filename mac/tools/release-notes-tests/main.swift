import Foundation

// What's new (Verbatim/Model/ReleaseNotes.swift, mac/ReleaseNotes/ReleaseNotes.json). Arguments: the bundled JSON,
// then optionally a copy with a "next" entry, that copy after CI's stamping, the build number it was stamped with,
// and the version it was stamped with (test-release-notes.sh makes them).

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) {
    if ok { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

func load(_ path: String) -> [ReleaseNote]? {
    guard let data = FileManager.default.contents(atPath: path) else { print("FAIL can't read \(path)"); return nil }
    do { return try ReleaseNotes.parse(data) } catch { print("FAIL \(path) doesn't parse: \(error)"); return nil }
}

let args = CommandLine.arguments

// `--summary <json>`: every build's items sorted for the iPhone app, the Mac app, and GitHub, one line each, for
// test-release-notes.sh to compare with release_notes.py's `summary` and `by_platform` (they must agree).
if args.count >= 3, args[1] == "--summary" {
    guard let notes = load(args[2]) else { exit(1) }
    for n in notes {
        for (app, name) in [(ReleaseApp.phone, "iphone"), (ReleaseApp.mac, "mac")] {
            let sum = ReleaseNotes.summary(n.items, for: app)
            for sec in sum.sections { for i in sec.items { print([n.build, name, "own", sec.platform.rawValue, i.text, i.detail ?? ""].joined(separator: "\t")) } }
            for sec in sum.also { for i in sec.items { print([n.build, name, sum.alsoTitle, sec.platform.rawValue, i.text, i.detail ?? ""].joined(separator: "\t")) } }
        }
        for sec in ReleaseNotes.byPlatform(n.items) { for i in sec.items { print([n.build, "github", "", sec.platform.rawValue, i.text, i.detail ?? ""].joined(separator: "\t")) } }
    }
    exit(0)
}

guard args.count >= 2, let notes = load(args[1]) else { exit(1) }

// MARK: The bundled file

let found = ReleaseNotes.problems(notes)
for p in found { print("  problem: \(p)") }
check("ReleaseNotes.json follows the rules (titles, items, builds descending, one \"next\" at most, first)", found.isEmpty)
check("it has at least one numbered build", notes.contains { $0.number != nil })
check("at most one \"next\"", notes.filter(\.isNext).count <= 1)
let numbers = notes.compactMap(\.number)
check("builds go down, newest first", zip(numbers, numbers.dropFirst()).allSatisfy { $0 > $1 })
check("numbered builds have a date", notes.filter { !$0.isNext }.allSatisfy { $0.date != nil })
check("no em dashes or exclamation points (Google developer style)",
      notes.allSatisfy { n in ([n.title] + n.items.flatMap { [$0.text] + ($0.detail.map { [$0] } ?? []) }).allSatisfy { !$0.contains("\u{2014}") && !$0.contains("!") } })
check("items are sentences that end with a period", notes.allSatisfy { $0.items.allSatisfy { $0.text.hasSuffix(".") || $0.text.hasSuffix(".)") } })
if let first = notes.first, first.isNext {
    check("every item in \"next\" is an object with its platforms", first.items.allSatisfy { !$0.isLegacy })
}

// MARK: Headings

let b203 = ReleaseNote(build: "203", date: "2026-10-25", title: "Automatic updates on Mac", items: ["The Mac app updates itself."])
check("heading: Build 203 · Oct 25", b203.heading == "Build 203 · Oct 25")
check("spoken heading: Build 203, October 25", b203.spokenHeading == "Build 203, October 25")
check("heading without a date: Build 203", ReleaseNote(build: "203", date: nil, title: "t", items: ["i."]).heading == "Build 203")
check("heading for next: Next build", ReleaseNote(build: "next", date: nil, title: "t", items: ["i."]).heading == "Next build")
check("a bad date reads as no date", ReleaseNote(build: "9", date: "Oct 25", title: "t", items: ["i."]).heading == "Build 9")

// MARK: The rules catch mistakes

func bad(_ list: [ReleaseNote]) -> Bool { !ReleaseNotes.problems(list).isEmpty }
let next = ReleaseNote(build: "next", date: nil, title: "Next", items: [ReleaseItem(platforms: [.iphone, .mac], text: "A change.")])
let b202 = ReleaseNote(build: "202", date: "2026-10-25", title: "t", items: ["i."])
check("rules: a good list passes", !bad([next, b203, b202]))
check("rules: two \"next\" entries fail", bad([next, next, b203]))
check("rules: \"next\" not first fails", bad([b203, next]))
check("rules: builds going up fail", bad([b202, b203]))
check("rules: a repeated build fails", bad([b203, b203]))
check("rules: a numbered build without a date fails", bad([ReleaseNote(build: "5", date: nil, title: "t", items: ["i."])]))
check("rules: no items fails", bad([ReleaseNote(build: "5", date: "2026-10-01", title: "t", items: [])]))
check("rules: an empty title fails", bad([ReleaseNote(build: "5", date: "2026-10-01", title: " ", items: ["i."])]))
check("rules: a build that isn't a number fails", bad([ReleaseNote(build: "v5", date: "2026-10-01", title: "t", items: ["i."])]))
check("rules: an empty list fails", bad([]))

// MARK: Versions (mac/VERSIONING.md)

check("version: 1.0 beta (217)", AppVersion.label(marketing: "1.0", channel: "beta", build: "217") == "1.0 beta (217)")
check("version: no channel reads 1.0 (217)", AppVersion.label(marketing: "1.0", channel: "", build: "217") == "1.0 (217)")
check("version: a blank channel counts as none", AppVersion.name(marketing: "1.2", channel: "  ") == "1.2")
check("version: 1.0 and 1.2.3 are numeric", AppVersion.isNumeric("1.0") && AppVersion.isNumeric("1.2.3"))
check("version: 1.0 beta, 1.0.0.1, and 1..0 aren't", !AppVersion.isNumeric("1.0 beta") && !AppVersion.isNumeric("1.0.0.1") && !AppVersion.isNumeric("1..0") && !AppVersion.isNumeric(""))
check("version: an entry without one is 1.0 beta", b203.versionName == "1.0 beta" && ReleaseNotes.firstVersion == "1.0 beta")
let v11a = ReleaseNote(build: "310", date: "2026-12-02", title: "t", items: ["i."], version: "1.1")
let v11b = ReleaseNote(build: "305", date: "2026-12-01", title: "t", items: ["i."], version: "1.1")
let v10 = ReleaseNote(build: "300", date: "2026-11-20", title: "t", items: ["i."], version: "1.0")
let groups = ReleaseNotes.byVersion([next, v11a, v11b, v10, b203, b202])
check("groups: in file order, newest first", groups.map(\.name) == ["1.0 beta", "1.1", "1.0"])
check("groups: an unstamped next counts as 1.0 beta", groups.first?.notes.first == next)
check("groups: each build once, under its version",
      groups.flatMap(\.notes).count == 6 && groups[1].notes == [v11a, v11b] && groups[0].notes == [next, b203, b202])
check("groups: headings", groups[1].heading == "Version 1.1" && groups[1].spokenHeading == "Version 1.1, 2 builds" && groups[2].spokenHeading == "Version 1.0, 1 build")
check("groups: the bundled file groups every build", ReleaseNotes.byVersion(notes).flatMap(\.notes) == notes)
check("rules: an empty version fails", bad([ReleaseNote(build: "5", date: "2026-10-01", title: "t", items: ["i."], version: " ")]))
check("rules: a version passes", !bad([v11a, v10]))
if let data = #"{"notes": [{"build": "9", "date": "2026-10-01", "version": "1.0 beta", "title": "t", "items": ["i."]}, {"build": "8", "date": "2026-10-01", "title": "t", "items": ["i."]}]}"#.data(using: .utf8),
   let parsed = try? ReleaseNotes.parse(data) {
    check("parse: version is read, and optional", parsed.first?.version == "1.0 beta" && parsed.last?.version == nil)
} else { check("parse: version is read, and optional", false) }

// MARK: Home's note

let list = [b203, b202]
check("note: an update to 203 from 202 shows 203", ReleaseNotes.pending(current: 203, lastSeen: 202, notes: list)?.build == "203")
check("note: once seen, it's gone", ReleaseNotes.pending(current: 203, lastSeen: 203, notes: list) == nil)
check("note: a build with no entry shows nothing", ReleaseNotes.pending(current: 210, lastSeen: 203, notes: list) == nil)
check("note: an older build than the last seen shows nothing", ReleaseNotes.pending(current: 202, lastSeen: 203, notes: list) == nil)
check("note: no build number (Xcode) shows nothing", ReleaseNotes.pending(current: nil, lastSeen: 0, notes: list) == nil)
check("first launch of a new install stores its own build", ReleaseNotes.firstLastSeen(stored: nil, current: 203, ranBefore: false) == 203)
check("an install that ran before stores nothing, so it sees this build's note once",
      ReleaseNotes.firstLastSeen(stored: nil, current: 203, ranBefore: true) == nil
      && ReleaseNotes.pending(current: 203, lastSeen: 0, notes: list) != nil)
check("a stored value is never replaced at launch", ReleaseNotes.firstLastSeen(stored: 190, current: 203, ranBefore: false) == nil)
if let d = UserDefaults(suiteName: "release-notes-tests-\(UUID().uuidString)") {
    ReleaseNotes.settleLastSeen(ranBefore: true, defaults: d)
    check("settle: an earlier install leaves the key unset", d.object(forKey: ReleaseNotes.lastSeenKey) == nil)
    d.set(500, forKey: ReleaseNotes.lastSeenKey)
    ReleaseNotes.markSeen(defaults: d)
    check("markSeen never moves back", d.integer(forKey: ReleaseNotes.lastSeenKey) == 500)
}

// MARK: The stamped copy

if args.count >= 5, let before = load(args[2]), let stamped = load(args[3]), let n = Int(args[4]) {
    let today: String = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }()
    check("stamped: no \"next\" left", !stamped.contains(where: \.isNext))
    check("stamped: the top entry is build \(n), dated today (UTC)", stamped.first?.build == String(n) && stamped.first?.date == today)
    if args.count >= 6 {
        check("stamped: the top entry is in version \(args[5])", stamped.first?.version == args[5] && stamped.first?.versionName == args[5])
    }
    check("stamped: the title and items are next's", before.first.map { $0.isNext && $0.title == stamped.first?.title && $0.items == stamped.first?.items } ?? false)
    check("stamped: the rest is unchanged", Array(stamped.dropFirst()) == Array(before.drop(while: \.isNext)))
    check("stamped: still follows the rules", ReleaseNotes.problems(stamped).isEmpty)
    check("stamped: Home's note finds build \(n)", ReleaseNotes.pending(current: n, lastSeen: n - 1, notes: stamped)?.build == String(n))
}

// MARK: Platforms (What's new leads with this device's platforms; Sparkle, GitHub, and TestFlight sort the same way)

let mItem = ReleaseItem(platforms: [.mac], text: "Mac one.")
let mItem2 = ReleaseItem(platforms: [.mac], text: "Mac two.", detail: "More about it.")
let both = ReleaseItem(platforms: [.iphone, .mac], text: "Both.")
let pItem = ReleaseItem(platforms: [.iphone], text: "Phone.")
let wItem = ReleaseItem(platforms: [.watch], text: "Watch.")
let pw = ReleaseItem(platforms: [.watch, .iphone], text: "Phone and watch.")
let mixed = [mItem, wItem, both, pItem, mItem2, pw]
let onPhone = ReleaseNotes.summary(mixed, for: .phone)
check("summary on iPhone: iPhone first, then Apple Watch, in the file's order",
      onPhone.sections.map(\.platform) == [.iphone, .watch] && onPhone.sections[0].items == [both, pItem, pw] && onPhone.sections[1].items == [wItem])
check("summary on iPhone: the Mac's items fold under Also on Mac", onPhone.also.map(\.platform) == [.mac] && onPhone.also[0].items == [mItem, mItem2]
      && onPhone.alsoTitle == "Also on Mac" && onPhone.alsoCount == 2)
let onMac = ReleaseNotes.summary(mixed, for: .mac)
check("summary on Mac: Mac first, with the change for both", onMac.sections.map(\.platform) == [.mac] && onMac.sections[0].items == [mItem, both, mItem2])
check("summary on Mac: iPhone, then Apple Watch, under Also on iPhone and Apple Watch",
      onMac.also.map(\.platform) == [.iphone, .watch] && onMac.also[0].items == [pItem, pw] && onMac.also[1].items == [wItem]
      && onMac.alsoTitle == "Also on iPhone and Apple Watch")
check("summary: each item once per app", onPhone.sections.flatMap(\.items).count + onPhone.alsoCount == mixed.count
      && onMac.sections.flatMap(\.items).count + onMac.alsoCount == mixed.count)
check("summary: no Mac items, no fold on iPhone", ReleaseNotes.summary([pItem, wItem], for: .phone).also.isEmpty && ReleaseNotes.summary([pItem, wItem], for: .phone).alsoTitle.isEmpty)
check("summary: only iPhone items on the Mac read Also on iPhone", ReleaseNotes.summary([pItem], for: .mac).alsoTitle == "Also on iPhone" && ReleaseNotes.summary([pItem], for: .mac).sections.isEmpty)
check("by platform (GitHub): Mac, iPhone, Apple Watch, a change for two in both",
      ReleaseNotes.byPlatform(mixed).map(\.platform) == [.mac, .iphone, .watch] && ReleaseNotes.byPlatform(mixed)[1].items == [both, pItem, pw])
check("joined: two with and, three with a serial comma", ReleaseNotes.joined(["iPhone", "Apple Watch"]) == "iPhone and Apple Watch"
      && ReleaseNotes.joined(["Mac", "iPhone", "Apple Watch"]) == "Mac, iPhone, and Apple Watch")

// Older builds' strings: the prefix gives the platforms and comes off the line.
func legacy(_ s: String) -> ([ReleasePlatform], String) { let i = ReleaseItem(legacy: s); return (i.platforms, i.text) }
check("legacy: Mac: is the Mac's, capitalized", legacy("Mac: press ⌘K anywhere.") == ([.mac], "Press ⌘K anywhere."))
check("legacy: iPhone: and Apple Watch:", legacy("iPhone: smaller fixes.") == ([.iphone], "Smaller fixes.") && legacy("Apple Watch: tap Mark.") == ([.watch], "Tap Mark."))
check("legacy: Mac and iPhone: and iPhone and Mac: are both", legacy("Mac and iPhone: ask.") == ([.iphone, .mac], "Ask.") && legacy("iPhone and Mac: in the Native look, x.") == ([.iphone, .mac], "In the Native look, x."))
check("legacy: Mac Home: keeps its area", legacy("Mac Home: the Dictate tile wraps.") == ([.mac], "Home: the Dictate tile wraps.") && legacy("Mac transcripts: sage.") == ([.mac], "Transcripts: sage."))
check("legacy: no prefix is both apps, as written", legacy("Edit Home: drag tiles.") == ([.iphone, .mac], "Edit Home: drag tiles.") && legacy("The Mac app updates itself.") == ([.iphone, .mac], "The Mac app updates itself."))
check("legacy: a first word with a capital stays", legacy("Mac: iCloud works.") == ([.mac], "iCloud works.") && legacy("Mac: ⌘K opens it.") == ([.mac], "⌘K opens it."))
check("legacy: no space after the colon isn't a prefix", legacy("Mac:x.") == ([.iphone, .mac], "Mac:x."))
check("legacy: a string literal is a legacy item", ({ () -> Bool in let i: ReleaseItem = "iPhone: a."; return i.isLegacy && i.platforms == [.iphone] })())

// Items as objects, and the rules for them
if let data = #"{"notes": [{"build": "next", "title": "t", "items": [{"platforms": ["iphone", "watch"], "text": "Tap Record.", "detail": "Touch and hold opens Record as."}, {"platforms": ["mac"], "text": "Press ⌘K."}]}, {"build": "8", "date": "2026-10-01", "title": "t", "items": ["Mac: old.", {"platforms": ["mac"], "text": "New."}]}]}"#.data(using: .utf8),
   let parsed = try? ReleaseNotes.parse(data) {
    let a = parsed[0].items[0], b = parsed[0].items[1]
    check("parse: an object item's platforms, text, and detail", a.platforms == [.iphone, .watch] && a.text == "Tap Record." && a.detail == "Touch and hold opens Record as." && !a.isLegacy)
    check("parse: detail is optional", b.detail == nil && b.platforms == [.mac])
    check("parse: strings and objects mix in a numbered entry", parsed[1].items[0].isLegacy && parsed[1].items[0].text == "Old." && !parsed[1].items[1].isLegacy)
    check("rules: a file with objects passes", ReleaseNotes.problems(parsed).isEmpty)
} else { check("parse: object items", false) }
func itemBad(_ json: String, next: Bool = true) -> Bool {
    let entry = next ? #"{"build": "next", "title": "t", "items": [\#(json)]}"# : #"{"build": "8", "date": "2026-10-01", "title": "t", "items": [\#(json)]}"#
    guard let data = #"{"notes": [\#(entry)]}"#.data(using: .utf8), let parsed = try? ReleaseNotes.parse(data) else { return true }
    return !ReleaseNotes.problems(parsed).isEmpty
}
check("rules: a string in next fails", itemBad(#""iPhone: a.""#))
check("rules: a string in a numbered build passes", !itemBad(#""iPhone: a.""#, next: false))
check("rules: no platforms fails", itemBad(#"{"text": "A."}"#) && itemBad(#"{"platforms": [], "text": "A."}"#))
check("rules: an unknown platform fails", itemBad(#"{"platforms": ["ipad"], "text": "A."}"#))
check("rules: a platform twice fails", itemBad(#"{"platforms": ["mac", "mac"], "text": "A."}"#))
check("rules: a line over 90 characters fails, 90 passes",
      itemBad(#"{"platforms": ["mac"], "text": "\#(String(repeating: "a", count: 90))."}"#) && !itemBad(#"{"platforms": ["mac"], "text": "\#(String(repeating: "a", count: 89))."}"#))
check("rules: a detail over 200 characters fails, 200 passes",
      itemBad(#"{"platforms": ["mac"], "text": "A.", "detail": "\#(String(repeating: "a", count: 200))."}"#) && !itemBad(#"{"platforms": ["mac"], "text": "A.", "detail": "\#(String(repeating: "a", count: 199))."}"#))
check("rules: an empty detail fails", itemBad(#"{"platforms": ["mac"], "text": "A.", "detail": " "}"#))
check("rules: a platform prefix in an object fails", itemBad(#"{"platforms": ["mac"], "text": "Mac: press it."}"#) && itemBad(#"{"platforms": ["iphone", "mac"], "text": "Mac and iPhone: ask."}"#))
check("rules: an em dash or exclamation point fails", itemBad(#"{"platforms": ["mac"], "text": "A \#u{2014} b."}"#) && itemBad(#"{"platforms": ["mac"], "text": "A.", "detail": "Wow!"}"#))
check("rules: no period fails", itemBad(#"{"platforms": ["mac"], "text": "A"}"#))

check("build number: 250 and the public track's 250.1 are 250", ReleaseNotes.buildNumber("250") == 250 && ReleaseNotes.buildNumber("250.1") == 250)
check("build number: anything else is nil", [ "", "250.", ".1", "250.x", "1.2.3.4", "beta" ].allSatisfy { ReleaseNotes.buildNumber($0) == nil })

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
