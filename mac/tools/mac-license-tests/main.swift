import Foundation

// Verbose for Mac's license (Verbatim/Model/MacLicense.swift): the Mac's trial and license as the iPhone's
// entitlement, check-ins with Polar, Polar's answers and errors, and the copy. Run mac/tools/test-mac-license.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}
let day: TimeInterval = 86_400
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func lic(_ validated: Date, status: String = "granted", failed: Date? = nil) -> MacLicenseRecord {
    MacLicenseRecord(key: "VRBS-AAAA-BBBB-7Q2M", activationID: "act-1", displayKey: "****-7Q2M", status: status, lastValidated: validated, lastFailedAttempt: failed)
}
func json(_ s: String) -> Data { Data(s.utf8) }

// The entitlement
check("nothing: the free version", MacEntitlement.state(trialStartedAt: nil, license: nil, now: t0) == .free)
check("the trial: 7 days, the same rule as the iPhone", MacEntitlement.state(trialStartedAt: t0, license: nil, now: t0) == .trial(ends: t0.addingTimeInterval(7 * day), daysLeft: 7))
check("after the trial: trial ended", MacEntitlement.state(trialStartedAt: t0, license: nil, now: t0.addingTimeInterval(8 * day)) == .trialEnded(ended: t0.addingTimeInterval(7 * day)))
check("a granted license unlocks", MacEntitlement.state(trialStartedAt: nil, license: lic(t0), now: t0.addingTimeInterval(10 * day)) == .unlocked)
check("a license beats an ended trial", MacEntitlement.state(trialStartedAt: t0, license: lic(t0.addingTimeInterval(9 * day)), now: t0.addingTimeInterval(10 * day)) == .unlocked)
check("a revoked license doesn't unlock", MacEntitlement.state(trialStartedAt: nil, license: lic(t0, status: "revoked"), now: t0) == .free)
check("offline for 59 days: still licensed", MacEntitlement.state(trialStartedAt: nil, license: lic(t0), now: t0.addingTimeInterval(59 * day)) == .unlocked)
check("offline past 60 days: back to free until a check-in gets through", MacEntitlement.state(trialStartedAt: nil, license: lic(t0), now: t0.addingTimeInterval(61 * day)) == .free)

check("with Local Only on, check-ins pause and the license keeps working", MacEntitlement.state(trialStartedAt: nil, license: lic(t0), now: t0.addingTimeInterval(400 * day), checksPaused: true) == .unlocked)

// Check-ins
check("no check-in before 30 days", !MacEntitlement.needsValidation(lic(t0), now: t0.addingTimeInterval(29 * day)))
check("a check-in at 30 days", MacEntitlement.needsValidation(lic(t0), now: t0.addingTimeInterval(30 * day)))
check("after a failed check-in, wait a day", !MacEntitlement.needsValidation(lic(t0, failed: t0.addingTimeInterval(31 * day)), now: t0.addingTimeInterval(31.5 * day))
      && MacEntitlement.needsValidation(lic(t0, failed: t0.addingTimeInterval(31 * day)), now: t0.addingTimeInterval(32.1 * day)))

// Enforcement
check("beta builds never enforce", !MacEntitlement.enforces(channel: "beta", configured: true))
check("the public build enforces once Polar is set up", MacEntitlement.enforces(channel: "", configured: true) && !MacEntitlement.enforces(channel: "", configured: false))

// Requests
let a = PolarRequest.activate(key: "K", label: "Anka's MacBook Pro", org: "org")
check("activate sends the key, organization, and label only", Set(a.keys) == ["key", "organization_id", "label"] && a["label"] as? String == "Anka's MacBook Pro")
check("validate and deactivate send the activation", Set(PolarRequest.validate(key: "K", activationID: "x", org: "o").keys) == ["key", "organization_id", "activation_id"]
      && Set(PolarRequest.deactivate(key: "K", activationID: "x", org: "o").keys) == ["key", "organization_id", "activation_id"])
check("pasted keys are trimmed of spaces and quotes", MacLicense.normalized("  \u{201C}VRBS-1234\u{201D}\n") == "VRBS-1234")
check("the label is the Mac's name, or Mac", MacLicense.label(computerName: " ") == "Mac" && MacLicense.label(computerName: "Studio") == "Studio")

// Answers
let ok = json(#"{"id":"act-9","license_key_id":"lk","label":"Studio","license_key":{"id":"lk","display_key":"****-7Q2M","status":"granted","limit_activations":3}}"#)
if case .activated(let r) = MacLicenseParse.activation(status: 200, body: ok, key: "K", now: t0) {
    check("activate: the record keeps the activation and masked key", r.activationID == "act-9" && r.displayKey == "****-7Q2M" && r.keyEnding == "7Q2M" && r.lastValidated == t0)
} else { check("activate: parses a 200", false) }
check("activate: 403 NotPermitted is all 3 Macs in use", MacLicenseParse.activation(status: 403, body: json(#"{"error":"NotPermitted","detail":"limit"}"#), key: "K", now: t0) == .problem(.limitReached))
check("activate: 404 is an unknown key", MacLicenseParse.activation(status: 404, body: json(#"{"error":"ResourceNotFound"}"#), key: "K", now: t0) == .problem(.notFound))
check("activate: 422 is a malformed key", MacLicenseParse.activation(status: 422, body: json(#"{"detail":[]}"#), key: "K", now: t0) == .problem(.invalid))
check("activate: no answer is offline", MacLicenseParse.activation(status: nil, body: nil, key: "K", now: t0) == .problem(.offline))
check("activate: a revoked key is refused", MacLicenseParse.activation(status: 200, body: json(#"{"id":"a","license_key":{"status":"revoked"}}"#), key: "K", now: t0) == .problem(.revoked))
let v = MacLicenseParse.validation(status: 200, body: json(#"{"display_key":"****-7Q2M","status":"granted","activation":{"id":"act-1"}}"#), record: lic(t0, failed: t0), now: t0.addingTimeInterval(30 * day))
check("check-in: a 200 renews and clears the failure", v?.lastValidated == t0.addingTimeInterval(30 * day) && v?.lastFailedAttempt == nil)
check("check-in: revoked ends the license", MacLicenseParse.validation(status: 200, body: json(#"{"status":"revoked"}"#), record: lic(t0), now: t0) == nil)
check("check-in: 404 (removed in Polar) ends the license", MacLicenseParse.validation(status: 404, body: nil, record: lic(t0), now: t0) == nil)
let off = MacLicenseParse.validation(status: nil, body: nil, record: lic(t0), now: t0.addingTimeInterval(30 * day))
check("check-in: offline keeps the license and notes the try", off?.lastValidated == t0 && off?.lastFailedAttempt == t0.addingTimeInterval(30 * day))

// Copy
let lines = MacLicenseCopy.allLines
check("copy: no em dash or exclamation point", lines.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("!") })
check("copy: the price and Mac count", MacLicenseCopy.pitch.contains("$49") && MacLicenseCopy.pitch.contains("$39") && MacLicenseCopy.pitch.contains("3 Macs"))
check("copy: trial days, singular and plural", MacLicenseCopy.trialLeft(1) == "Free trial: 1 day left" && MacLicenseCopy.trialLeft(5) == "Free trial: 5 days left")
check("not configured until the organization ID is set", MacLicense.isConfigured == !MacLicense.organizationID.isEmpty)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
