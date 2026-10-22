import Foundation

// Cloud share links (CloudShareLinkChecks) and private-video sign-in (LinkSignInChecks). Not part of any app
// target; run mac/tools/test-cloudlinks.sh. The Mac and iPhone self-tests run the same checks.
var passed = 0, failed = 0
for r in CloudShareLinkChecks.run() + LinkSignInChecks.run() {
    if r.ok { passed += 1; print("PASS  \(r.name)") }
    else { failed += 1; print("FAIL  \(r.name)" + (r.detail.isEmpty ? "" : "\n    " + r.detail)) }
}
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
