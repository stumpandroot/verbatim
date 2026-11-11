import Foundation

/// Mac self-tests for dictation polish (`UITest` runs them): the pure checks in `DictationTimingChecks` (also run by
/// `mac/tools/test-formatter.sh`), clean while you talk (`PreCleanChecks`), Only keep my voice's decision and the
/// numbers kept about it (`VoiceShadowChecks`), cleanup's time limit against work that ignores cancellation, and how
/// long the Ribbon shows "Cancelled".
@MainActor
enum DictationPolishChecks {
    static func run(_ check: (String, Bool) -> Void) async {
        for r in DictationTimingChecks.run() {
            check(r.name, r.ok)
            if !r.ok { Log.note("UITEST detail: " + r.detail.replacingOccurrences(of: "\n", with: "⏎")) }
        }

        // Clean while you talk: sealing, matching, the switch, and one dictation's session with a stand-in for the
        // model, including a cancel part way (PreCleanChecks, also run by mac/tools/test-preclean.sh).
        for r in PreCleanChecks.run() + (await PreCleanChecks.runSession()) {
            check("pre-clean " + r.name, r.ok)
            if !r.ok { Log.note("UITEST detail: " + r.detail.replacingOccurrences(of: "\n", with: "⏎")) }
        }

        // Only keep my voice: the decision the filter and shadow mode share, the numbers kept per dictation, the list's
        // cap, and the threshold report (VoiceShadowChecks, also run by mac/tools/test-voice-shadow.sh), then the file
        // itself, in the temporary folder.
        VoiceShadowChecks.run { name, ok in check("voice " + name, ok) }
        VoiceShadowStore.selfCheck(check)

        // What ties parts cleaned ahead to the cleanup that may reuse them, and cleanup with none to reuse.
        let said = "um so I sent the draft to the client this morning. They want two more rounds of changes"
        let work = FlowCleanup.Request(raw: said, level: .polished, style: .casual, category: .work, context: nil, vocabulary: [], useContext: false)
        var email = work; email.category = .email
        var clean = work; clean.level = .clean
        var named = work; named.vocabulary = ["Lititz"]
        var literal = work; literal.level = .literal
        var code = work; code.category = .code
        let key = FlowCleanup.preCleanKey(work)
        check("pre-clean: parts are tied to the destination, the level, and your Dictionary terms",
              key == FlowCleanup.preCleanKey(work) && key != FlowCleanup.preCleanKey(email) && key != FlowCleanup.preCleanKey(clean)
                && key != FlowCleanup.preCleanKey(named))
        check("pre-clean: snapshots get the same rule-based text as cleanup, and none at Literal or in code apps",
              FlowCleanup.preCleanInput(work) == CleanupPrepass.clean(said, corrections: work.spokenCorrections)
                && FlowCleanup.preCleanInput(literal) == nil && FlowCleanup.preCleanInput(code) == nil)
        var idle = work
        idle.preClean = PreCleanSession { _, _ in nil }
        check("pre-clean: with nothing cleaned ahead, the rules give the same text", FlowCleanup.rulesOnly(idle) == FlowCleanup.rulesOnly(work))

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
