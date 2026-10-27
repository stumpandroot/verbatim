import Foundation

// Apple Watch capture (Verbatim/Model/WatchTransfer.swift and WatchImport.swift): the transfer metadata, encoded and
// decoded (including a newer watch's), the watch's marks and words, the context the iPhone sends, and what the iPhone
// makes of a recording from the watch (kind, marks, source). The same checks run in the iPhone's self-test
// (WatchChecks.swift), which also receives a simulated watch file. Then the project switch that leaves the watch app
// out (tools/generate-project.sh). Not part of any app target; run mac/tools/test-watch.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name)") }
}

WatchChecks.run { check($0, $1) }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
