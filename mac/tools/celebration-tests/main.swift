import Foundation

// Celebrations (Verbatim/Model/CelebrationRules.swift, DESIGN.md §7): the rules (CelebrationChecks.swift, which both
// self-tests also run), then the sources that use them. Reads the Swift sources from the mac/ folder given as the
// first argument. Not part of any app target; run mac/tools/test-celebrations.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

CelebrationChecks.run { check($0, $1) }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
