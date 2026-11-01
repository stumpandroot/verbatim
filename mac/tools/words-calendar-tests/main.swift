import Foundation

// Your words calendar (Verbatim/Model/WordsCalendar.swift): shading, the month and its rhythm, a day opened, the year,
// lengths and the bookshelf, and the cards under the month. The same checks run in both self-tests
// (WordsCalendarChecks.swift). Not part of any app target; run mac/tools/test-words-calendar.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name)") }
}

WordsCalendarChecks.run { check($0, $1) }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
