import Foundation

// Transcript files from a newer build: unknown enum values read as a fallback and are written back as they were,
// unknown keys survive a save, and schemaVersion is kept. Compiles the real Transcript.swift with stand-ins for the
// app types it touches (Stubs.swift). Not part of any app target; run mac/tools/test-transcript.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
func object(_ data: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }
/// Compares JSON values by their canonical serialization (NSDictionary equality mishandles booleans on Linux).
func same(_ a: Any?, _ b: Any?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    func canon(_ x: Any) -> Data? { try? JSONSerialization.data(withJSONObject: ["v": x], options: [.sortedKeys]) }
    return canon(a) != nil && canon(a) == canon(b)
}

let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let fixture = try? Data(contentsOf: fixtureURL) else { print("FAIL  can't read \(fixtureURL.path)"); exit(1) }
let original = object(fixture)

// Reading
var t: Transcript
do { t = try dec.decode(Transcript.self, from: fixture) } catch { print("FAIL  the newer file decodes: \(error)"); exit(1) }
check("the newer file decodes", t.title == "Crew call from a newer build" && t.segments.count == 1 && t.duration == 42.5)
check("an unknown source reads as the fallback", t.source == .file)
check("an unknown status reads as ready", t.status == .ready)
check("an unknown kind reads as unlabeled", t.kind == nil)
check("an unknown cleanup source reads as the fallback", t.documentCleanedBy == .model)
check("unknown nested enum values read as fallbacks", t.flow?.category == .other && t.flow?.style == .casual && t.flow?.raw == "ahoy")
check("schemaVersion is read", t.schemaVersion == 3)
check("unknown keys are kept", Set(t.unknown.keys.keys) == ["chapters", "translation", "rating", "starred", "colorLabel"],
      "\(t.unknown.keys.keys.sorted())")

// Writing back unchanged
guard let saved = try? enc.encode(t) else { print("FAIL  re-encodes"); exit(1) }
let out = object(saved)
for k in ["chapters", "translation", "rating", "starred", "colorLabel"] {
    check("unknown key \(k) is written back as it was", same(out[k], original[k]), "\(String(describing: out[k])) vs \(String(describing: original[k]))")
}
check("unknown enum values are written back", out["source"] as? String == "screenRecording" && out["status"] as? String == "archived"
      && out["kind"] as? String == "podcast" && out["documentCleanedBy"] as? String == "cloudModel")
check("a newer schemaVersion is kept", out["schemaVersion"] as? Int == 3)
check("known fields round-trip", out["title"] as? String == original["title"] as? String && same(out["segments"], original["segments"])
      && same(out["speakers"], original["speakers"]) && same(out["tags"], original["tags"]) && out["pinned"] as? Bool == true)
let again = try? dec.decode(Transcript.self, from: saved)
check("a second read equals the first", again == t)
check("no key is lost", Set(original.keys).subtracting(out.keys).isEmpty, "\(Set(original.keys).subtracting(out.keys).sorted())")

// Changing a field this build understands replaces the newer value; the rest stays.
var edited = t
edited.status = .failed
edited.kind = .meeting
edited.title = "Renamed here"
let out2 = object((try? enc.encode(edited)) ?? Data())
check("a status set here is written", out2["status"] as? String == "failed")
check("a kind set here is written", out2["kind"] as? String == "meeting")
check("an unchanged unknown source is still written back", out2["source"] as? String == "screenRecording")
check("unknown keys survive an edit", same(out2["chapters"], original["chapters"]) && out2["title"] as? String == "Renamed here")

// Unknown keys never shadow a field this build writes.
var clash = t
clash.unknown.keys["title"] = .string("from the future")
let out3 = object((try? enc.encode(clash)) ?? Data())
check("a kept key never replaces a known one", out3["title"] as? String == t.title)

// Older files: no schemaVersion, no unknown keys.
let oldFile = Data(#"{"id":"9A1B2C3D-0000-4000-8000-000000000001","title":"Voice memo","createdAt":"2026-01-01T10:00:00Z","source":"voiceMemo","sourceLabel":"Voice memo","duration":3,"model":"","status":"ready"}"#.utf8)
if let old = try? dec.decode(Transcript.self, from: oldFile) {
    let o = object((try? enc.encode(old)) ?? Data())
    check("an older file reads as schema 1 and has nothing unknown", old.schemaVersion == 1 && old.unknown.isEmpty)
    check("an older file is written as the current schema", o["schemaVersion"] as? Int == Transcript.currentSchema)
    check("an older file writes no extra keys", Set(o.keys).isSubset(of: Transcript.knownKeys))
} else { check("an older file decodes", false) }

// A new transcript
var fresh = Transcript(title: "New", source: .voiceMemo, sourceLabel: "Voice memo", duration: 1, audioFileName: nil, model: "")
fresh.createdAt = Date(timeIntervalSince1970: 1_800_000_000)   // whole seconds: the file keeps ISO 8601 seconds
let o4 = object((try? enc.encode(fresh)) ?? Data())
check("a new transcript writes the current schema and no kind", o4["schemaVersion"] as? Int == Transcript.currentSchema && o4["kind"] == nil)
check("a new transcript round-trips", (try? dec.decode(Transcript.self, from: try enc.encode(fresh))) == fresh)

// JSONValue keeps every JSON shape.
let shapes = Data(#"{"a":"s","b":1.5,"c":true,"d":null,"e":[1,"x",{"f":false}],"g":{"h":[]}}"#.utf8)
if let v = try? dec.decode(JSONValue.self, from: shapes), let back = try? enc.encode(v) {
    check("JSONValue round-trips every shape", same(object(back), object(shapes)))
} else { check("JSONValue round-trips every shape", false) }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
