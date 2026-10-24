import Foundation

// The launch budget for iCloud reads (LaunchBudget, LaunchGate). Not part of any app target; run
// mac/tools/test-launch.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// Deadline math: one deadline from the start, shared by every read.
let b = LaunchBudget(start: 100, allowance: 2)
check("the deadline is start plus the allowance", b.deadline == 102)
check("time left counts down", b.remaining(at: 100.5) == 1.5, "\(b.remaining(at: 100.5))")
check("time left is never negative", b.remaining(at: 500) == 0)
check("a negative allowance is no time at all", LaunchBudget(start: 100, allowance: -5).remaining(at: 100) == 0)
check("the default allowance is about two seconds", LaunchBudget.allowance == 2)
check("a fresh budget isn't spent", !LaunchBudget().isSpent)
check("a budget from long ago is spent", LaunchBudget(start: ProcessInfo.processInfo.systemUptime - 10).isSpent)

// Out of time: only bytes already on this device are read directly; reading anything else would wait on iCloud.
check("a current file is read directly", LaunchBudget.fallback(.current) == .readDirectly)
check("a downloaded file is read directly", LaunchBudget.fallback(.downloaded) == .readDirectly)
check("a file that isn't downloaded is skipped", LaunchBudget.fallback(.notDownloaded) == .skip)
check("a file with no download status is skipped", LaunchBudget.fallback(.unknown) == .skip)

// The gate: the accessor runs, or launch gives up, never both.
let q = DispatchQueue(label: "accessor", attributes: .concurrent)

// Granted in time: launch gets the accessor's result.
do {
    let g = LaunchGate(), box = LaunchBox<Int>()
    q.asyncAfter(deadline: .now() + 0.05) { if g.enter() { box.value = 7; g.leave() } }
    let ran = g.wait(LaunchBudget(allowance: 2))
    check("access granted in time: launch waits for it and gets the result", ran && box.value == 7)
}

// Never granted: launch stops at the deadline, and a grant after that never runs the accessor.
do {
    let g = LaunchGate(), box = LaunchBox<Int>()
    let start = Date()
    let ran = g.wait(LaunchBudget(allowance: 0.2))
    let waited = Date().timeIntervalSince(start)
    check("access never granted: launch stops waiting at the deadline", !ran && waited < 1.5, "waited \(waited) s")
    let late = g.enter()
    if late { box.value = 1; g.leave() }
    check("a grant after launch gave up never runs", !late && box.value == nil)
}

// Started just before the deadline: launch waits for it to finish rather than reading the file a second time.
do {
    let g = LaunchGate(), box = LaunchBox<Int>()
    let entered = DispatchSemaphore(value: 0)
    q.async {
        guard g.enter() else { entered.signal(); return }
        entered.signal()
        Thread.sleep(forTimeInterval: 0.4)
        box.value = 3
        g.leave()
    }
    entered.wait()
    let ran = g.wait(LaunchBudget(allowance: 0.05))
    check("an accessor that started in time is waited for, past the deadline", ran && box.value == 3)
}

// A spent budget doesn't wait at all, but still takes an accessor that already finished.
do {
    let g = LaunchGate()
    _ = g.enter(); g.leave()
    check("a finished accessor counts even with no time left", g.wait(LaunchBudget(start: 0, allowance: 0)))
    let g2 = LaunchGate()
    let start = Date()
    check("no time left and no accessor: gives up at once", !g2.wait(LaunchBudget(start: 0, allowance: 0)) && Date().timeIntervalSince(start) < 0.5)
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
