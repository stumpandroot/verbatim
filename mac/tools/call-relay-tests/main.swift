import Foundation

// Record a call from the iPhone (Verbatim/Model/CallRelay.swift): the Mac's state, which requests the Mac acts on,
// the files' round trip, and the copy. Run mac/tools/test-call-relay.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool) { if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name)") } }
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let mac = CallRelayMac(device: "m", name: "your Mac", seen: t0,
                       next: CallRelayEvent(id: "e1", title: "Catalog review with the printer", start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(3300), service: "Zoom"),
                       wait: CallRelayWait(appName: "Zoom", title: "Catalog review with the printer", expires: t0.addingTimeInterval(3300), requestID: "r1"))
func req(_ id: String, _ at: Date, _ a: CallRelayRequest.Action = .wait) -> CallRelayRequest {
    CallRelayRequest(id: id, action: a, eventID: "e1", created: at, device: "p", deviceName: "iPhone")
}

check("no file: no Mac", CallRelay.macState(nil, now: t0) == .none)
check("seen today: ready", CallRelay.macState(mac, now: t0.addingTimeInterval(3600)) == .ready(name: "your Mac"))
check("not seen for 3 days: stale, with the days", CallRelay.macState(mac, now: t0.addingTimeInterval(3.2 * 86_400)) == .stale(name: "your Mac", days: 3))
check("a new, fresh request is handled", CallRelay.shouldHandle(req("r2", t0), lastHandled: "r1", now: t0.addingTimeInterval(60)))
check("the same request isn't handled twice", !CallRelay.shouldHandle(req("r1", t0), lastHandled: "r1", now: t0.addingTimeInterval(60)))
check("a request older than 10 minutes is ignored", !CallRelay.shouldHandle(req("r3", t0), lastHandled: nil, now: t0.addingTimeInterval(601)))
check("a request from a clock far ahead is ignored", !CallRelay.shouldHandle(req("r4", t0.addingTimeInterval(3600)), lastHandled: nil, now: t0))
check("the next call shows until it ends", CallRelay.nextCall(mac, now: t0.addingTimeInterval(3000)) != nil && CallRelay.nextCall(mac, now: t0.addingTimeInterval(3400)) == nil)
check("the wait shows until it expires", CallRelay.activeWait(mac, now: t0.addingTimeInterval(100)) != nil && CallRelay.activeWait(mac, now: t0.addingTimeInterval(4000)) == nil)
var rec = mac; rec.wait?.recording = true
check("a recording wait shows past its expiry", CallRelay.activeWait(rec, now: t0.addingTimeInterval(4000)) != nil)
let data = try! CallRelay.encoder().encode(mac)
check("the Mac's file round-trips", CallRelay.decodeMac(data) == mac)
let rd = try! CallRelay.encoder().encode(req("r5", t0, .cancel))
check("a request round-trips", CallRelay.decodeRequest(rd) == req("r5", t0, .cancel))
check("a broken file reads as nothing", CallRelay.decodeMac(Data("{".utf8)) == nil)
check("copy: no em dash or exclamation point", CallRelay.allLines.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("!") })
check("copy: the Mac line names the call and the Mac", CallRelay.onMacDetail(next: mac.next, macName: "your Mac", time: { _ in "10:30" })
      == "Catalog review with the printer · 10:30 · Zoom. Your Mac records your mic and the call as two tracks.")
check("copy: stale days, singular", CallRelay.staleMac("your Mac", days: 1).contains("1 day"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
