import Foundation

// What's new (Verbatim/Model/ReleaseNotes.swift, mac/ReleaseNotes/ReleaseNotes.json). Arguments: the bundled JSON,
// then optionally a copy with a "next" entry, that copy after CI's stamping, and the build number it was stamped
// with (test-release-notes.sh makes them).

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) {
    if ok { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

func load(_ path: String) -> [ReleaseNote]? {
    guard let data = FileManager.default.contents(atPath: path) else { print("FAIL can't read \(path)"); return nil }
    do { return try ReleaseNotes.parse(data) } catch { print("FAIL \(path) doesn't parse: \(error)"); return nil }
}

let args = CommandLine.arguments
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
      notes.allSatisfy { n in ([n.title] + n.items).allSatisfy { !$0.contains("\u{2014}") && !$0.contains("!") } })
check("items are sentences that end with a period", notes.allSatisfy { $0.items.allSatisfy { $0.hasSuffix(".") || $0.hasSuffix(".)") } })

// MARK: Headings

let b203 = ReleaseNote(build: "203", date: "2026-10-25", title: "Automatic updates on Mac", items: ["The Mac app updates itself."])
check("heading: Build 203 · Oct 25", b203.heading == "Build 203 · Oct 25")
check("spoken heading: Build 203, October 25", b203.spokenHeading == "Build 203, October 25")
check("heading without a date: Build 203", ReleaseNote(build: "203", date: nil, title: "t", items: ["i."]).heading == "Build 203")
check("heading for next: Next build", ReleaseNote(build: "next", date: nil, title: "t", items: ["i."]).heading == "Next build")
check("a bad date reads as no date", ReleaseNote(build: "9", date: "Oct 25", title: "t", items: ["i."]).heading == "Build 9")

// MARK: The rules catch mistakes

func bad(_ list: [ReleaseNote]) -> Bool { !ReleaseNotes.problems(list).isEmpty }
let next = ReleaseNote(build: "next", date: nil, title: "Next", items: ["A change."])
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
    check("stamped: the title and items are next's", before.first.map { $0.isNext && $0.title == stamped.first?.title && $0.items == stamped.first?.items } ?? false)
    check("stamped: the rest is unchanged", Array(stamped.dropFirst()) == Array(before.drop(while: \.isNext)))
    check("stamped: still follows the rules", ReleaseNotes.problems(stamped).isEmpty)
    check("stamped: Home's note finds build \(n)", ReleaseNotes.pending(current: n, lastSeen: n - 1, notes: stamped)?.build == String(n))
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
