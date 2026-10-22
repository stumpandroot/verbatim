import Foundation

// New audio file names (AudioNaming): unique within a second, never a file that's there, and claiming refuses to
// replace one. Not part of any app target; run mac/tools/test-naming.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("naming-tests-\(UUID().uuidString)", isDirectory: true)
try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
let stamp = "2026-10-22 14.03.07"

// Suffixes
var g = SeededGenerator(state: 1)
let suffixes = (0..<2_000).map { _ in AudioNaming.randomSuffix(using: &g) }
check("suffixes are four characters from the alphabet",
      suffixes.allSatisfy { $0.count == 4 && $0.allSatisfy { AudioNaming.alphabet.contains($0) } })
check("suffixes skip confusable characters", !suffixes.joined().contains { "01ilo".contains($0) })
check("2,000 suffixes are nearly all distinct", Set(suffixes).count > 1_990, "\(Set(suffixes).count) distinct")
check("file name format", AudioNaming.fileName(stamp: stamp, suffix: "k3f9", ext: "m4a") == "2026-10-22 14.03.07 k3f9.m4a")

// The old per-second names collided: two imports in the same second now get two names.
var names = Set<String>()
for _ in 0..<500 {
    let n = AudioNaming.uniqueName(stamp: stamp, ext: "m4a") { stem, e in AudioNaming.taken(stem: stem, ext: e, in: dir, used: names) }
    names.insert(n)
    _ = fm.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data())
}
check("500 names in one second are all different", names.count == 500)
check("names keep the stamp and extension", names.allSatisfy { $0.hasPrefix(stamp + " ") && $0.hasSuffix(".m4a") })

// A taken candidate is skipped: the suffix source repeats a name already on disk, then a free one.
let onDisk = AudioNaming.fileName(stamp: stamp, suffix: "aaaa", ext: "m4a")
_ = fm.createFile(atPath: dir.appendingPathComponent(onDisk).path, contents: Data("keep".utf8))
var queue = ["aaaa", "aaaa", "bbbb"]
let picked = AudioNaming.uniqueName(stamp: stamp, ext: "m4a", isTaken: { AudioNaming.taken(stem: $0, ext: $1, in: dir) },
                                    suffix: { queue.removeFirst() })
check("a name on disk is skipped", picked == AudioNaming.fileName(stamp: stamp, suffix: "bbbb", ext: "m4a"), picked)

// A sibling with another extension counts as taken (an import may switch .m4a to the source's extension or .wav).
_ = fm.createFile(atPath: dir.appendingPathComponent("\(stamp) cccc.wav").path, contents: Data())
check("a sibling .wav makes the stem taken", AudioNaming.taken(stem: "\(stamp) cccc", ext: "m4a", in: dir))
check("a name a transcript uses is taken", AudioNaming.taken(stem: "\(stamp) dddd", ext: "mp3", in: dir, used: ["\(stamp) dddd.mp3"]))
check("a free stem is free", !AudioNaming.taken(stem: "\(stamp) eeee", ext: "m4a", in: dir))
var q2 = ["cccc", "dddd", "ffff"]
let picked2 = AudioNaming.uniqueName(stamp: stamp, ext: "mp3",
                                     isTaken: { AudioNaming.taken(stem: $0, ext: $1, in: dir, used: ["\(stamp) dddd.mp3"]) },
                                     suffix: { q2.removeFirst() })
check("siblings and used names are both skipped", picked2 == "\(stamp) ffff.mp3", picked2)
var always = 0
let fallback = AudioNaming.uniqueName(stamp: stamp, ext: "m4a", isTaken: { _, _ in always += 1; return always <= 64 }, suffix: { "zzzz" })
check("endless collisions fall back to a UUID name", fallback.hasPrefix(stamp + " ") && !fallback.contains("zzzz") && fallback.hasSuffix(".m4a"), fallback)

// Claiming: a writer creates its own file and refuses one that's there, leaving it untouched.
let existing = dir.appendingPathComponent(onDisk)
var refused = false
do { try AudioNaming.claim(existing, contents: Data("new".utf8)) } catch is AudioNaming.AlreadyExists { refused = true } catch {}
check("claim refuses an existing file", refused)
check("the existing file is untouched", (try? Data(contentsOf: existing)) == Data("keep".utf8))
let fresh = dir.appendingPathComponent("\(stamp) gggg.wav")
var claimed = false
do { try AudioNaming.claim(fresh, contents: Data("RIFF".utf8)); claimed = true } catch {}
check("claim creates a new file with its contents", claimed && (try? Data(contentsOf: fresh)) == Data("RIFF".utf8))
var second = false
do { try AudioNaming.claim(fresh) } catch is AudioNaming.AlreadyExists { second = true } catch {}
check("a second claim of the same name is refused", second)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
