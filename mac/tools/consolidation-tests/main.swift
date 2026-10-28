import Foundation

// The consolidation (October 28, 2026; Verbatim/Model/Consolidation.swift): the one-time moves that keep everything
// a merged or retired feature made, and put its settings where they belong now. Not part of any app target; run
// mac/tools/test-consolidation.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}
func suite() -> UserDefaults { UserDefaults(suiteName: "consolidation-tests-\(UUID().uuidString)")! }

// MARK: Once per device

let fresh = suite()
check("a new install isn't an existing one", !Consolidation.isExistingInstall(fresh))
var sawExisting: Bool? = nil
Consolidation.once(fresh) { sawExisting = $0 }
check("the moves run once, as a new install", sawExisting == false && fresh.bool(forKey: Consolidation.doneKey))
var ranAgain = false
Consolidation.once(fresh) { _ in ranAgain = true }
check("and never again", !ranAgain)
let old = suite()
old.set(1, forKey: "onboarding.seenVersion")
check("an install that finished the tour is an existing one", Consolidation.isExistingInstall(old))
let seen = suite()
seen.set(236, forKey: "releaseNotes.lastSeenBuild")
check("so is one that saw What's new", Consolidation.isExistingInstall(seen))
Consolidation.once(old) { sawExisting = $0 }
check("an existing install's moves know it", sawExisting == true)

// MARK: Text actions (the Mac's flow.actions)

let mk = TranscriptActions.anySpec(TranscriptActions.makeAPlanID)!, je = TranscriptActions.anySpec(TranscriptActions.journalEntryID)!
let kp = TranscriptActions.anySpec(TranscriptActions.keyPointsID)!
check("an untouched Make a plan becomes Plan my day", Consolidation.textActionMove(id: mk.id, name: mk.name, instruction: mk.instruction) == .replace(TemplateLibrary.planMyDayID))
check("an untouched Journal entry becomes Daily reflection", Consolidation.textActionMove(id: je.id, name: je.name, instruction: je.instruction + "\n") == .replace(TemplateLibrary.dailyReflectionID))
check("an untouched Key points goes", Consolidation.textActionMove(id: kp.id, name: kp.name, instruction: kp.instruction) == .remove)
check("a renamed Make a plan stays yours", Consolidation.textActionMove(id: mk.id, name: "Shed plan", instruction: mk.instruction) == .keep)
check("a rewritten Key points stays yours", Consolidation.textActionMove(id: kp.id, name: kp.name, instruction: "Quotes only.") == .keep)
let draft = TranscriptActions.builtIn[0]
check("a current action stays", Consolidation.textActionMove(id: draft.id, name: draft.name, instruction: draft.instruction) == .keep
      && Consolidation.textActionMove(id: UUID(), name: "Client email", instruction: "x") == .keep)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
