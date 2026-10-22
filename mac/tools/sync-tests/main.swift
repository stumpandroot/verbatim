import Foundation

// Merging synced lists (projects, the Dictionary, snippets) entry by entry: SyncMerge. Not part of any app target;
// run mac/tools/test-sync.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

/// Shaped like DictionaryEntry: an ID, a few fields, and `updatedAt`.
struct Entry: SyncEntry {
    var id = UUID()
    var preferred: String
    var heardAs: [String] = []
    var updatedAt: Date? = nil
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
func names(_ xs: [Entry]) -> [String] { xs.map(\.preferred) }
let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

// The bug this replaces: a device that couldn't read the file wrote its empty list over it.
check("a file that isn't downloaded is never written", !SyncMerge.mayWrite(after: ListRead<[Entry]>.unavailable("not downloaded yet")))
check("a missing file may be written", SyncMerge.mayWrite(after: ListRead<[Entry]>.missing))
check("a file that read may be written", SyncMerge.mayWrite(after: ListRead<[Entry]>.ok([])))
check("an undecodable file isn't a list", SyncMerge.decode(Entry.self, from: Data("{\"oops\":1}".utf8), decoder: dec) == nil
      && SyncMerge.decode(Entry.self, from: Data("not json".utf8), decoder: dec) == nil)

// Files from older builds: no updatedAt, extra keys from newer builds ignored.
let legacy = Data(#"[{"id":"7D3F5E7A-1111-4C7B-9A4B-111111111111","preferred":"Lititz","heardAs":["Lit it's"],"future":true}]"#.utf8)
let decoded = SyncMerge.decode(Entry.self, from: legacy, decoder: dec)
check("an older build's file decodes with no updatedAt", decoded?.count == 1 && decoded?.first?.updatedAt == nil && decoded?.first?.preferred == "Lititz")

// Union: each device added its own.
let a1 = Entry(preferred: "Ephrata", updatedAt: at(10)), b1 = Entry(preferred: "Lititz", updatedAt: at(20))
let u = SyncMerge.merge(local: [a1], remote: [b1], localTombstones: [], remoteTombstones: [], now: at(100))
check("entries added on two devices are both kept", names(u.items) == ["Ephrata", "Lititz"])
check("an empty local copy takes the file as it is", SyncMerge.merge(local: [Entry](), remote: [a1, b1], localTombstones: [], remoteTombstones: [], now: at(100)).items == [a1, b1])
check("an empty file doesn't empty the local copy", SyncMerge.merge(local: [a1, b1], remote: [], localTombstones: [], remoteTombstones: [], now: at(100)).items == [a1, b1])

// The newer edit wins, whichever side it's on.
var a1edit = a1; a1edit.heardAs = ["Effrata"]; a1edit.updatedAt = at(30)
check("the newer edit wins (local)", SyncMerge.merge(local: [a1edit], remote: [a1], localTombstones: [], remoteTombstones: [], now: at(100)).items == [a1edit])
check("the newer edit wins (remote)", SyncMerge.merge(local: [a1], remote: [a1edit], localTombstones: [], remoteTombstones: [], now: at(100)).items == [a1edit])

// Ties and legacy entries pick the same version on both devices.
var tieA = a1; tieA.heardAs = ["x"]
var tieB = a1; tieB.heardAs = ["y"]
let m1 = SyncMerge.merge(local: [tieA], remote: [tieB], localTombstones: [], remoteTombstones: [], now: at(100)).items
let m2 = SyncMerge.merge(local: [tieB], remote: [tieA], localTombstones: [], remoteTombstones: [], now: at(100)).items
check("a tie resolves the same way on both devices", m1 == m2 && m1.count == 1)
var legacyA = Entry(id: a1.id, preferred: "Ephrata", heardAs: ["a"]), legacyB = legacyA; legacyB.heardAs = ["b"]
check("legacy entries without dates converge", SyncMerge.merge(local: [legacyA], remote: [legacyB], localTombstones: [], remoteTombstones: [], now: at(100)).items
      == SyncMerge.merge(local: [legacyB], remote: [legacyA], localTombstones: [], remoteTombstones: [], now: at(100)).items)
check("a dated edit beats a legacy entry", SyncMerge.merge(local: [legacyA], remote: [a1edit], localTombstones: [], remoteTombstones: [], now: at(100)).items == [a1edit])

// Deletes: a tombstone removes the entry on the device that still has it, unless it was edited after.
let gone = Tombstone(id: b1.id, deletedAt: at(40))
let d1 = SyncMerge.merge(local: [a1, b1], remote: [a1], localTombstones: [], remoteTombstones: [gone], now: at(100))
check("a delete on the other device removes the entry here", names(d1.items) == ["Ephrata"] && d1.tombstones == [gone])
let d2 = SyncMerge.merge(local: [a1], remote: [a1, b1], localTombstones: [gone], remoteTombstones: [], now: at(100))
check("a delete here isn't undone by the file that still has it", names(d2.items) == ["Ephrata"])
var b1later = b1; b1later.updatedAt = at(50)
check("an edit made after the delete brings the entry back",
      names(SyncMerge.merge(local: [a1], remote: [a1, b1later], localTombstones: [gone], remoteTombstones: [], now: at(100)).items) == ["Ephrata", "Lititz"])
check("a delete removes a legacy entry", SyncMerge.merge(local: [Entry(id: b1.id, preferred: "Lititz")], remote: [], localTombstones: [],
                                                        remoteTombstones: [gone], now: at(100)).items.isEmpty)

// Tombstones: union keeping the latest delete, pruned after 90 days, sorted for a stable file.
let older = Tombstone(id: b1.id, deletedAt: at(5)), other = Tombstone(id: a1.id, deletedAt: at(6))
let tm = SyncMerge.mergeTombstones([older, other], [gone], now: at(100))
check("tombstones keep the latest delete per entry", tm.count == 2 && tm.contains(gone) && tm.contains(other))
check("tombstones are sorted by ID", tm == tm.sorted { $0.id.uuidString < $1.id.uuidString })
check("tombstones older than 90 days are dropped", SyncMerge.mergeTombstones([older], [], now: at(5 + 91 * 86_400)).isEmpty
      && SyncMerge.mergeTombstones([older], [], now: at(5 + 89 * 86_400)).count == 1)

// Order: local's, then the file's new ones in its order.
let c1 = Entry(preferred: "C", updatedAt: at(1)), c2 = Entry(preferred: "D", updatedAt: at(1))
check("order is local's, then new remote entries in order",
      names(SyncMerge.merge(local: [b1, a1], remote: [c1, a1, c2], localTombstones: [], remoteTombstones: [], now: at(100)).items) == ["Lititz", "Ephrata", "C", "D"])
check("duplicate IDs collapse to one", SyncMerge.merge(local: [a1, a1], remote: [a1], localTombstones: [], remoteTombstones: [], now: at(100)).items == [a1])

// Local edits: stamping and tombstones.
let s0 = [a1, b1]
var edited = s0; edited[0].heardAs = ["Effrata"]
let st = SyncMerge.stamp(old: s0, new: edited, now: at(200))
check("a changed entry is stamped now", st.items[0].updatedAt == at(200) && st.items[1].updatedAt == at(20) && st.deleted.isEmpty)
let added = SyncMerge.stamp(old: s0, new: s0 + [Entry(preferred: "New")], now: at(200))
check("a new entry is stamped now", added.items[2].updatedAt == at(200) && added.items[0] == a1)
let removed = SyncMerge.stamp(old: s0, new: [a1], now: at(200))
check("a removed entry gets a tombstone", removed.deleted == [Tombstone(id: b1.id, deletedAt: at(200))] && removed.items == [a1])
var preset = edited; preset[0].updatedAt = at(150)
check("an edit that sets its own date keeps it", SyncMerge.stamp(old: s0, new: preset, now: at(200)).items[0].updatedAt == at(150))
check("no change stamps nothing", SyncMerge.stamp(old: s0, new: s0, now: at(200)).items == s0)
check("emptying the list tombstones everything", SyncMerge.stamp(old: s0, new: [], now: at(200)).deleted.count == 2)

// Round trip through a file: a merged list encodes and decodes to the same entries.
if let data = try? enc.encode(u.items), let back = SyncMerge.decode(Entry.self, from: data, decoder: dec) {
    check("a merged list round-trips through JSON", back == u.items)
} else { check("a merged list round-trips through JSON", false) }

// Two devices, several rounds: they end with the same list.
var devA: [Entry] = [a1], devB: [Entry] = [b1]
var tombA: [Tombstone] = [], tombB: [Tombstone] = []
var file: [Entry] = [], fileTombs: [Tombstone] = []
func sync(_ list: inout [Entry], _ tombs: inout [Tombstone]) {
    let m = SyncMerge.merge(local: list, remote: file, localTombstones: tombs, remoteTombstones: fileTombs, now: at(1_000))
    list = m.items; tombs = m.tombstones; file = m.items; fileTombs = m.tombstones
}
sync(&devA, &tombA); sync(&devB, &tombB); sync(&devA, &tombA)
check("both devices have both entries", Set(names(devA)) == ["Ephrata", "Lititz"] && Set(names(devB)) == ["Ephrata", "Lititz"])
// A deletes Lititz; B edits Ephrata and adds C; neither has seen the other's change.
var e = SyncMerge.stamp(old: devA, new: devA.filter { $0.id != b1.id }, now: at(300)); devA = e.items; tombA = SyncMerge.mergeTombstones(tombA, e.deleted)
var ed = devB.map { x -> Entry in var x = x; if x.id == a1.id { x.heardAs = ["Efrata"] }; return x }
e = SyncMerge.stamp(old: devB, new: ed + [c1], now: at(310)); devB = e.items
sync(&devA, &tombA); sync(&devB, &tombB); sync(&devA, &tombA)
func byID(_ xs: [Entry]) -> [Entry] { xs.sorted { $0.id.uuidString < $1.id.uuidString } }
check("two devices converge after edits, adds, and deletes", byID(devA) == byID(devB) && Set(names(devA)) == ["Ephrata", "C"]
      && devA.first { $0.id == a1.id }?.heardAs == ["Efrata"], "\(names(devA)) vs \(names(devB))")

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
