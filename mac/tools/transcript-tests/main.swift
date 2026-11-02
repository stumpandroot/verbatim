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
      && out["kind"] as? String == "webinar" && out["documentCleanedBy"] as? String == "cloudModel")
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

// File names from a record: only bare names survive decoding (LibraryFile), so nothing joins outside a folder.
let unsafe = Data(#"""
{"id":"6E1C4D0A-3B57-4C39-9C55-2D3A8C3E9F11","title":"Synced","audioFileName":"../../../../../../Documents/Taxes",
 "pendingAppend":"/etc/passwd","link":{"url":"https://e.com/v","thumbnailFile":".hidden.jpg"},
 "notes":[{"id":"0B9C6A55-8A43-4E51-9B1E-1C7C8B2D7E40","text":"n","isBookmark":false,"createdAt":"2026-01-01T00:00:00Z","frameFile":"..\\x.jpg"},
          {"id":"1B9C6A55-8A43-4E51-9B1E-1C7C8B2D7E40","text":"m","isBookmark":false,"createdAt":"2026-01-01T00:00:00Z","frameFile":"frame-1.jpg"}]}
"""#.utf8)
if let u = try? dec.decode(Transcript.self, from: unsafe) {
    check("a traversing audio name decodes as none", u.audioFileName == nil)
    check("an absolute continued-recording name decodes as none", u.pendingAppend == nil)
    check("a hidden thumbnail name decodes as none, the link stays", u.link?.thumbnailFile == nil && u.link?.url == "https://e.com/v")
    check("a bad note still is dropped, a good one kept", u.notes.map(\.frameFile) == [nil, "frame-1.jpg"], "\(u.notes.map(\.frameFile))")
} else { check("a record with unsafe names still decodes", false) }
let safe = Data(#"{"title":"OK","audioFileName":"2026-10-23 10.15.32 ab12.m4a","pendingAppend":"part 2.wav"}"#.utf8)
let s2 = try? dec.decode(Transcript.self, from: safe)
check("bare names decode unchanged", s2?.audioFileName == "2026-10-23 10.15.32 ab12.m4a" && s2?.pendingAppend == "part 2.wav")

// The kinds added in October 2026 read and write as themselves here; a build before them reads them as unlabeled
// and writes the raw value back (the "webinar" checks above are that path), so synced files stay safe both ways.
for k in [RecordingKind.podcast, .video, .talk, .interview] {
    var x = fresh; x.kind = k
    let o = object((try? enc.encode(x)) ?? Data())
    let back = try? dec.decode(Transcript.self, from: try enc.encode(x))
    check("kind \(k.rawValue) round-trips", o["kind"] as? String == k.rawValue && back?.kind == k)
}
check("every new kind is pickable, none is a model kind",
      [RecordingKind.podcast, .video, .talk, .interview].allSatisfy { RecordingKind.pickable.contains($0) && !RecordingKind.modelKinds.contains($0) })
check("labels", [RecordingKind.podcast, .video, .talk, .interview].map(\.label) == ["Podcast", "Video", "Talk", "Interview"])

// Background voices (Settings › Main speaker only): a voice memo with people nearby folds them; a podcast's host,
// a meeting, a link, or an imported file never does.
func voices(_ source: SourceKind, _ lines: [(String, Double)], kind: RecordingKind? = nil) -> Transcript {
    var x = Transcript(title: "v", source: source, sourceLabel: "", duration: 60, audioFileName: nil, model: "")
    var at = 0.0
    x.segments = lines.map { l in defer { at += l.1 }; return Segment(start: at, end: at + l.1, text: "line", speaker: l.0) }
    x.speakers = [Speaker(id: "S1", name: "Speaker 1"), Speaker(id: "S2", name: "Speaker 2")]
    x.kind = kind
    return x
}
// The self-test's "Errands and a long walk": S2 talks about 22% of the time.
let walk = voices(.voiceMemo, [("S1", 8), ("S2", 3.2), ("S1", 6.8), ("S2", 2.8), ("S1", 6)])
check("a voice memo with a few lines nearby folds them", walk.hasBackgroundVoices && walk.backgroundSegments.count == 2)
check("the main speaker is the one who talks most", walk.mainSpeaker == "S1")
// A podcast: the guest talks most, the host asks short questions (the 1:01:59 YouTube report).
let host = voices(.link, [("S2", 4), ("S1", 30), ("S2", 5), ("S1", 40), ("S2", 3), ("S1", 25)])
check("a link's host is never a background voice", !host.hasBackgroundVoices && host.backgroundSegments.isEmpty)
check("the guest is still the main speaker", host.mainSpeaker == "S1")
check("an imported file's voices never fold", voices(.file, [("S1", 50), ("S2", 3)]).backgroundSegments.isEmpty)
check("app audio's voices never fold", voices(.app, [("S1", 50), ("S2", 3)]).backgroundSegments.isEmpty)
check("a meeting's voices never fold", voices(.voiceMemo, [("S1", 50), ("S2", 3)], kind: .meeting).backgroundSegments.isEmpty)
check("an interview's voices never fold", voices(.voiceMemo, [("S1", 50), ("S2", 3)], kind: .interview).backgroundSegments.isEmpty)
check("a voice memo conversation doesn't fold the other half",
      voices(.voiceMemo, [("S1", 20), ("S2", 15), ("S1", 20), ("S2", 15)]).backgroundSegments.isEmpty)
var linkMemo = voices(.voiceMemo, [("S1", 50), ("S2", 3)]); linkMemo.sourceURL = "https://youtu.be/x"
check("a voice-memo record with a link doesn't fold", linkMemo.backgroundSegments.isEmpty)

// One device at a time: a job another device has taken over (Retry or a claimed link there) is never written back
// by this one, so two devices never each keep their own words for one transcript.
var job = fresh
check("a job with no device is anyone's", job.jobIsMine("phone") && job.jobIsMine("mac"))
job.processingDevice = "phone"
check("a job is its device's", job.jobIsMine("phone"))
check("another device's job is not this one's", !job.jobIsMine("mac"))
check("the default is this device", job.jobIsMine() == (Device.id == "phone"))

// JSONValue keeps every JSON shape.
let shapes = Data(#"{"a":"s","b":1.5,"c":true,"d":null,"e":[1,"x",{"f":false}],"g":{"h":[]}}"#.utf8)
if let v = try? dec.decode(JSONValue.self, from: shapes), let back = try? enc.encode(v) {
    check("JSONValue round-trips every shape", same(object(back), object(shapes)))
} else { check("JSONValue round-trips every shape", false) }

// Imported files: a made-up name (a download's ID, a camera's number) gets an automatic title; a name you gave it stays.
for made in ["v12044gd0000db8m6m7og65g3h4k8r50", "IMG_4821", "VID_20261102_180512", "PXL_20261102_230512345", "DJI_0042",
             "Screen Recording 2026-11-02 at 6.05.12 PM", "RPReplay_Final1730581512", "video", "Video (1)", "download",
             "8F2C6A1E-4B7D-4E21-9C3A-2D5B6E7F8A90", "20261102_180512", "WhatsApp Video 2026-11-02 at 18.05.12",
             "snaptik_7432189054321", "Untitled", "New Recording 12", "audio-2"] {
    check("a made-up file name gets a title: \(made)", Transcript.isMadeUpFileName(made))
}
for named in ["Client interview, March", "Kickoff with the print shop", "Episode 12 recap", "2026 budget review",
              "Q3 plan", "Sermon on Psalm 23", "Tim and Anka walkthrough", "Final cut notes from Ian"] {
    check("a name someone gave a file stays: \(named)", !Transcript.isMadeUpFileName(named))
}
var tiktok = fresh; tiktok.source = .file; tiktok.title = "v12044gd0000db8m6m7og65g3h4k8r50"; tiktok.titleIsAuto = true
check("an imported TikTok download may be retitled", tiktok.mayAutoTitle([.voiceMemo]))
tiktok.title = "Client interview, March"
check("an imported file with a real name keeps it", !tiktok.mayAutoTitle([.voiceMemo]))
tiktok.title = "Have you given up"; tiktok.titleByModel = true
check("once its made-up name is replaced by a model's title, a summary can still improve it", tiktok.mayAutoTitle([.voiceMemo]))
tiktok.title = "IMG_4821"; tiktok.titleIsAuto = false
check("a file you renamed is never retitled", !tiktok.mayAutoTitle([.voiceMemo, .file]))

// Video stills: one where the picture changes, at most one per 10 seconds and 30 per video.
func gray(_ v: UInt8) -> [UInt8] { Array(repeating: v, count: 256) }
let cuts = (0..<60).map { i in VideoStill.Sample(at: Double(i), gray: gray(UInt8((i / 3) % 2 == 0 ? 40 : 200))) }
let picked = VideoStill.pick(cuts)
check("a fast-cut video gets at most one still per 10 seconds", picked.first == 0 && zip(picked, picked.dropFirst()).allSatisfy { $1 - $0 >= 10 })
check("a fast-cut minute gets 5 to 6 stills", (5...6).contains(picked.count), "\(picked)")
let steady = (0..<120).map { i in VideoStill.Sample(at: Double(i), gray: gray(UInt8(100 + i % 3))) }
check("one steady camera gets one still", VideoStill.pick(steady) == [0])
let slides = (0..<100).map { i in VideoStill.Sample(at: Double(i), gray: gray(UInt8(i < 25 ? 30 : i < 60 ? 220 : 90))) }
check("a slideshow gets a still per slide", VideoStill.pick(slides) == [0, 25, 60])
let long = (0..<2000).map { i in VideoStill.Sample(at: Double(i) * 2, gray: gray(UInt8(i % 2 == 0 ? 0 : 255))) }
check("never more than 30 stills", VideoStill.pick(long).count == 30)
check("a 10-minute video is sampled once a second", VideoStill.sampleTimes(duration: 600).count == 600)
check("an hour is sampled 600 times", VideoStill.sampleTimes(duration: 3600).count == 600)
check("difference runs from 0 to 1", VideoStill.difference(gray(0), gray(0)) == 0 && VideoStill.difference(gray(0), gray(255)) == 1)
let l1 = Segment(start: 0, end: 3, text: "a"), l2 = Segment(start: 3, end: 7, text: "b"), l3 = Segment(start: 7, end: 9, text: "c")
let map = VideoStill.byLine([VideoStill(at: 0, file: "a", aspect: 0.56), VideoStill(at: 7.1, file: "b", aspect: 0.56),
                             VideoStill(at: 8, file: "c", aspect: 0.56)], lines: [l1, l2, l3])
check("each still sits on the line playing then, one per line", map[l1.id]?.file == "a" && map[l2.id] == nil && map[l3.id]?.file == "b")
let tall = VideoStill.size(aspect: 9.0 / 16, tallWidth: 44), wide = VideoStill.size(aspect: 16.0 / 9, tallWidth: 44)
check("a tall still is 44 by 78; a wide one 66 by 37", Int(tall.width) == 44 && Int(tall.height) == 78 && Int(wide.width) == 66 && Int(wide.height) == 37)
var withStills = fresh; withStills.stills = [VideoStill(at: 7, file: "still-x-7000.jpg", aspect: 0.5625)]
if let d = try? enc.encode(withStills), let back = try? dec.decode(Transcript.self, from: d) {
    check("stills survive a save", back.stills == withStills.stills)
} else { check("stills survive a save", false) }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
