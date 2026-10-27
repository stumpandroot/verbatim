import Foundation

// Mark a moment (Verbatim/Model/Marks.swift): dedupe while recording and on Stop, marks as bookmarks with their
// source, snapping to the line being said, quotes, the words on each surface, the file beside the recording, and the
// source surviving sync. The same checks run in both self-tests (MarkChecks.swift). Not part of any app target; run
// mac/tools/test-marks.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name)") }
}

MarkChecks.run { check($0, $1) }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
