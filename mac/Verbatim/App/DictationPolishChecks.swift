import Foundation

/// Mac self-tests for dictation polish (`UITest` runs them): the pure checks in `DictationTimingChecks` (also run by
/// `mac/tools/test-formatter.sh`), cleanup's time limit against work that ignores cancellation, and how long the
/// Ribbon shows "Cancelled".
@MainActor
enum DictationPolishChecks {
    static func run(_ check: (String, Bool) -> Void) async {
        for r in DictationTimingChecks.run() {
            check(r.name, r.ok)
            if !r.ok { Log.note("UITEST detail: " + r.detail.replacingOccurrences(of: "\n", with: "⏎")) }
        }

        // A model call that ignores cancellation (it waits 2 s no matter what) still ends at the 0.3 s limit.
        let t0 = Date()
        let stalled: Int? = await FlowCleanup.withTimeout(seconds: 0.3) { () -> Int? in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { c.resume() }
            }
            return 1
        }
        let took = Date().timeIntervalSince(t0)
        check("cleanup time limit: returns at the limit when the work ignores cancellation", stalled == nil && took < 0.8)
        if took >= 0.8 { Log.note("UITEST detail: the stalled work held the limit for \(String(format: "%.2f", took)) s") }
        let quick: Int? = await FlowCleanup.withTimeout(seconds: 2) { () -> Int? in 7 }
        check("cleanup time limit: fast work keeps its result", quick == 7)

        check("Ribbon: Cancelled shows for 1.5 s; other notices stay long enough to read",
              FlowBarController.noticeSeconds("Cancelled", hasAction: false, requested: 1.5, exact: true) == 1.5
                && FlowBarController.noticeSeconds("Learned “Lititz”", hasAction: false, requested: 3.5) >= 6)
    }
}
