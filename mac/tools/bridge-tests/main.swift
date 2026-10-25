import Foundation

// What the iPhone app trusts from outside its process (VerbatimKeyboard/BridgeTrust.swift). Not part of any app
// target; run mac/tools/test-bridge.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let now = 1_800_000_000.0

// MARK: Commands from the widget's process

let c = BridgeTrust.Command(id: UUID(), name: "toggle", at: now - 1)
check("a command round-trips through its stored form", BridgeTrust.decode(BridgeTrust.encode(c)) == c)
check("nothing stored: nothing to do", BridgeTrust.decode(nil) == nil)
check("a bare word isn't a command (what a Darwin notification alone would be)", BridgeTrust.decode("toggle") == nil)
check("no ID: not a command", BridgeTrust.decode("|toggle|\(now)") == nil)
check("a bad ID: not a command", BridgeTrust.decode("not-a-uuid|toggle|\(now)") == nil)
check("no time: not a command", BridgeTrust.decode("\(UUID().uuidString)|toggle|") == nil)
check("an endless time: not a command", BridgeTrust.decode("\(UUID().uuidString)|toggle|inf") == nil)
check("no name: not a command", BridgeTrust.decode("\(UUID().uuidString)||\(now)") == nil)
check("extra parts: not a command", BridgeTrust.decode("\(UUID().uuidString)|toggle|\(now)|x") == nil)
check("a fresh, unhandled command is accepted", BridgeTrust.acceptCommand(c, consumed: [], now: now) == c)
check("a handled command isn't accepted again", BridgeTrust.acceptCommand(c, consumed: [c.id], now: now) == nil)
check("no command: nothing", BridgeTrust.acceptCommand(nil, consumed: [], now: now) == nil)
var old = c; old.at = now - BridgeTrust.commandFresh - 0.1
check("a stale command is ignored", BridgeTrust.acceptCommand(old, consumed: [], now: now) == nil)
var edge = c; edge.at = now - BridgeTrust.commandFresh
check("freshness edge: exactly 10 s still counts", BridgeTrust.acceptCommand(edge, consumed: [], now: now) == edge)
var future = c; future.at = now + 30
check("a command from the future is ignored", BridgeTrust.acceptCommand(future, consumed: [], now: now) == nil)
var skew = c; skew.at = now + 1
check("a second of clock skew is tolerated", BridgeTrust.acceptCommand(skew, consumed: [], now: now) == skew)

// MARK: Session links

let r = UUID(), d = UUID()
let fresh = BridgeTrust.StoredRequest(id: r, at: now - 2, host: "com.apple.MobileSMS", startID: d, answered: false)
check("the keyboard's fresh request starts the session, with its dictation and host",
      BridgeTrust.decide(linkRequest: r, linkDictation: d, stored: fresh, consumed: [], now: now) == .start(host: "com.apple.MobileSMS", dictation: d))
check("no dictation in the link: the session starts without one",
      BridgeTrust.decide(linkRequest: r, linkDictation: nil, stored: fresh, consumed: [], now: now) == .start(host: "com.apple.MobileSMS", dictation: nil))
check("a dictation the keyboard didn't ask for isn't started",
      BridgeTrust.decide(linkRequest: r, linkDictation: UUID(), stored: fresh, consumed: [], now: now) == .start(host: "com.apple.MobileSMS", dictation: nil))
check("a link with no request asks first (the widget, another app)",
      BridgeTrust.decide(linkRequest: nil, linkDictation: d, stored: fresh, consumed: [], now: now) == .confirm)
check("a request the keyboard didn't write asks first",
      BridgeTrust.decide(linkRequest: UUID(), linkDictation: d, stored: fresh, consumed: [], now: now) == .confirm)
var stale = fresh; stale.at = now - BridgeTrust.requestFresh - 1
check("a stale request asks first", BridgeTrust.decide(linkRequest: r, linkDictation: d, stored: stale, consumed: [], now: now) == .confirm)
var undated = fresh; undated.at = 0
check("a request with no time (an older keyboard) asks first",
      BridgeTrust.decide(linkRequest: r, linkDictation: d, stored: undated, consumed: [], now: now) == .confirm)
var answered = fresh; answered.answered = true
check("an answered request asks first (a replayed link)",
      BridgeTrust.decide(linkRequest: r, linkDictation: d, stored: answered, consumed: [], now: now) == .confirm)
check("a request already used asks first",
      BridgeTrust.decide(linkRequest: r, linkDictation: d, stored: fresh, consumed: [r], now: now) == .confirm)
var futureReq = fresh; futureReq.at = now + 60
check("a request from the future asks first",
      BridgeTrust.decide(linkRequest: r, linkDictation: d, stored: futureReq, consumed: [], now: now) == .confirm)
var noStored = fresh; noStored.id = nil
check("no stored request asks first", BridgeTrust.decide(linkRequest: r, linkDictation: d, stored: noStored, consumed: [], now: now) == .confirm)
var badHost = fresh; badHost.host = "evil app/../x"
check("a stored host that isn't a bundle ID isn't switched to",
      BridgeTrust.decide(linkRequest: r, linkDictation: d, stored: badHost, consumed: [], now: now) == .start(host: nil, dictation: d))
var noHost = fresh; noHost.host = nil
check("no host from the keyboard: none (the breadcrumb may still lead back)",
      BridgeTrust.decide(linkRequest: r, linkDictation: d, stored: noHost, consumed: [], now: now) == .start(host: nil, dictation: d))

// MARK: The session route (the keyboard's Start a session opens Verbose straight into the session)

typealias Route = BridgeTrust.SessionRoute
let kbURL = Route.url(request: r, host: "com.apple.MobileSMS", dictation: d)
check("the keyboard's link uses verbatim://session", kbURL.scheme == "verbatim" && kbURL.host == "session", kbURL.absoluteString)
check("the keyboard's link asks to start", kbURL.absoluteString.contains("start=1"), kbURL.absoluteString)
check("the keyboard's link round-trips request, host, and dictation",
      Route.parse(kbURL) == Route.Link(request: r, host: "com.apple.MobileSMS", dictation: d, source: nil))
check("App Store builds send no host: the link leaves it out",
      Route.parse(Route.url(request: r, host: nil)) == Route.Link(request: r, host: nil) && !Route.url(request: r, host: "").absoluteString.contains("host="))
check("each start source round-trips",
      [Route.StartSource.control, .shortcut, .widget, .app, .island].allSatisfy { Route.parse(Route.url(from: $0)) == Route.Link(request: nil, host: nil, source: $0) })
check("Restart in the Dynamic Island names its source", Route.url(from: .island).absoluteString == "verbatim://session?start=1&from=island")
check("the Lock Screen widget's link still parses", Route.parse(URL(string: "verbatim://session?start=1&from=widget")!)?.source == .widget)
check("the first keyboard's dictate link still parses",
      Route.parse(URL(string: "verbatim://dictate?session=\(r.uuidString)")!)?.request == r)
check("another host isn't a session link", Route.parse(URL(string: "verbatim://open")!) == nil)
check("another scheme isn't a session link", Route.parse(URL(string: "https://session?request=\(r.uuidString)")!) == nil)
check("a malformed request reads as none, never a match", Route.parse(URL(string: "verbatim://session?request=nope")!)?.request == nil)
check("an unknown source reads as none", Route.parse(URL(string: "verbatim://session?from=elsewhere")!)?.source == nil)
check("an empty host reads as none", Route.parse(URL(string: "verbatim://session?request=\(r.uuidString)&host=")!)?.host == nil)
check("a parsed link still needs the App Group's request to start",
      BridgeTrust.decide(linkRequest: Route.parse(kbURL)?.request, linkDictation: Route.parse(kbURL)?.dictation, stored: fresh, consumed: [], now: now)
        == .start(host: "com.apple.MobileSMS", dictation: d)
      && BridgeTrust.decide(linkRequest: Route.parse(Route.url(from: .island))?.request, linkDictation: nil, stored: fresh, consumed: [], now: now) == .confirm)

// MARK: Bundle IDs

check("a bundle ID passes", BridgeTrust.validHost("net.whatsapp.WhatsApp") == "net.whatsapp.WhatsApp")
check("hyphens and digits pass", BridgeTrust.validHost("com.example-2.app1") == "com.example-2.app1")
check("empty fails", BridgeTrust.validHost("") == nil && BridgeTrust.validHost(nil) == nil)
check("spaces fail", BridgeTrust.validHost("com.apple Mobile") == nil)
check("slashes fail", BridgeTrust.validHost("com.apple/../x") == nil)
check("a scheme fails", BridgeTrust.validHost("https://x.com") == nil)
check("non-ASCII letters fail", BridgeTrust.validHost("com.äpple.x") == nil)
check("a leading dot fails", BridgeTrust.validHost(".com.apple") == nil)
check("155 characters pass, 156 fail",
      BridgeTrust.validHost(String(repeating: "a", count: 155)) != nil && BridgeTrust.validHost(String(repeating: "a", count: 156)) == nil)

// MARK: Recent

struct Item: Equatable { var n: Int; var date: Date }
let t = Date(timeIntervalSince1970: now)
let items = (0..<15).map { Item(n: $0, date: t.addingTimeInterval(-Double($0) * 3600)) }   // newest first, an hour apart
let kept = BridgeTrust.keepRecent(items, date: \.date, now: t)
check("recent keeps at most 10", kept.count == 10 && kept.first?.n == 0 && kept.last?.n == 9)
let day = BridgeTrust.keepRecent(items, date: \.date, now: t, cap: 100)
check("recent keeps a day: 24 h in, 25 h out", day.map(\.n) == Array(0...14).filter { $0 <= 24 } && !day.contains { $0.n > 24 })
let older = (0..<5).map { Item(n: $0, date: t.addingTimeInterval(-BridgeTrust.recentMaxAge - 1 - Double($0))) }
check("entries older than a day all go", BridgeTrust.keepRecent(older, date: \.date, now: t).isEmpty)
check("a slightly future date (another clock) stays", BridgeTrust.keepRecent([Item(n: 1, date: t.addingTimeInterval(20))], date: \.date, now: t).count == 1)
check("the clipboard keeps a dictation for 2 minutes", BridgeTrust.clipboardLifetime == 120)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
