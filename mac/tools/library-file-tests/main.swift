import Foundation

// LibraryFile: file names from transcript records (synced, so written by any device on the account) are used only
// as bare names inside their folder. Not part of any app target; run mac/tools/test-library-file.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

/// Stand-in for the app's log: counts lines, so "logged once" can be checked.
enum Log {
    nonisolated(unsafe) static var lines: [String] = []
    static func note(_ message: String) { lines.append(message) }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("library-file-tests-\(UUID().uuidString)", isDirectory: true)
let audio = root.appendingPathComponent("audio", isDirectory: true)
try? fm.createDirectory(at: audio, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

// Names
for good in ["2026-10-23 10.15.32 ab12.m4a", "track-1.wav", "frame-6E1C4D0A.jpg", "Interview..final.m4a", "a:b.m4a", "café.m4a"] {
    check("safe: \(good)", LibraryFile.isSafeName(good))
}
for bad in ["", ".", "..", "../x.m4a", "../../../../../../Documents/Taxes", "/etc/passwd", "a/b.m4a", "a\\b.m4a", "..\\x.jpg",
            ".hidden.m4a", ".x.m4a.icloud", "x.m4a/", "nul\u{0}.m4a", String(repeating: "a", count: 256)] {
    check("unsafe: \(bad.debugDescription.prefix(60))", !LibraryFile.isSafeName(bad))
}

// Joins
let ok = LibraryFile.url("take 1.m4a", in: audio, field: "audio")
check("a bare name joins inside its folder", ok?.path == audio.standardizedFileURL.appendingPathComponent("take 1.m4a").path, ok?.path ?? "nil")
check("no name, no URL", LibraryFile.url(nil, in: audio, field: "audio") == nil)
check("a traversing name joins nothing", LibraryFile.url("../../../../../../Documents/Taxes", in: audio, field: "audio") == nil)
check("an absolute name joins nothing", LibraryFile.url("/Users/Shared/a.m4a", in: audio, field: "audio") == nil)
check("a folder given with .. still works for a bare name",
      LibraryFile.url("x.m4a", in: audio.appendingPathComponent("../audio", isDirectory: true), field: "audio")?.path == audio.standardizedFileURL.appendingPathComponent("x.m4a").path)

// A symbolic link in the folder is never followed (reading or deleting through it could leave the folder).
let outside = root.appendingPathComponent("outside.m4a")
_ = fm.createFile(atPath: outside.path, contents: Data("secret".utf8))
try? fm.createSymbolicLink(at: audio.appendingPathComponent("link.m4a"), withDestinationURL: outside)
check("a symbolic link is refused", LibraryFile.url("link.m4a", in: audio, field: "audio") == nil)

// Decoding
check("checked keeps a bare name", LibraryFile.checked("a.m4a", field: "audio") == "a.m4a")
check("checked drops a bad name", LibraryFile.checked("../a.m4a", field: "audio") == nil && LibraryFile.checked(nil, field: "audio") == nil)

// Logged once per field and name, and the name itself never goes in the log.
Log.lines = []
for _ in 0..<5 { _ = LibraryFile.url("../secret-name.m4a", in: audio, field: "thumbnail") }
check("a rejected name is logged once", Log.lines.count == 1, "\(Log.lines)")
check("the log line doesn't contain the name", !(Log.lines.first ?? "").contains("secret-name"), Log.lines.first ?? "")
_ = LibraryFile.checked("../secret-name.m4a", field: "audio")
check("another field logs again", Log.lines.count == 2)

// Nothing outside was touched.
check("the file outside is still there", fm.fileExists(atPath: outside.path))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
