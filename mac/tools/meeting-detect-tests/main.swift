import Foundation

// Test cases for MeetingDetect (noticing a call: which app, when to ask, one prompt per call, consent counts).
// Not part of any app target; run mac/tools/test-meeting-detect.sh.

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name) \(detail())") }
}

let zoom = "us.zoom.xos", chrome = "com.google.chrome", safari = "com.apple.safari", facetime = "com.apple.facetime"

// MARK: Which app

do {
    let none: Set<String> = []
    check("resolve: Zoom by its bundle ID", MeetingApps.resolve("us.zoom.xos", running: none)?.name == "Zoom")
    check("resolve: case doesn't matter", MeetingApps.resolve("US.ZOOM.XOS", running: none)?.key == zoom)
    check("resolve: Chrome's helper is Chrome", MeetingApps.resolve("com.google.Chrome.helper", running: none)?.key == chrome)
    check("resolve: Chrome is a browser", MeetingApps.resolve("com.google.Chrome", running: none)?.isBrowser == true)
    check("resolve: Zoom isn't a browser", MeetingApps.resolve("us.zoom.xos", running: none)?.isBrowser == false)
    check("resolve: Teams helper", MeetingApps.resolve("com.microsoft.teams2.helper", running: none)?.name == "Microsoft Teams")
    check("resolve: Arc helper", MeetingApps.resolve("company.thebrowser.Browser.helper", running: none)?.name == "Arc")
    check("resolve: Slack helper", MeetingApps.resolve("com.tinyspeck.slackmacgap.helper", running: none)?.name == "Slack")
    check("resolve: Discord", MeetingApps.resolve("com.hnc.Discord", running: none)?.name == "Discord")
    check("resolve: Webex", MeetingApps.resolve("Cisco-Systems.Spark", running: none)?.name == "Webex")
    check("resolve: Edge, Brave, Firefox",
          MeetingApps.resolve("com.microsoft.edgemac.helper", running: none)?.name == "Edge"
          && MeetingApps.resolve("com.brave.Browser.helper", running: none)?.name == "Brave"
          && MeetingApps.resolve("org.mozilla.firefox", running: none)?.name == "Firefox")
    check("resolve: Firefox's content process is Firefox", MeetingApps.resolve("org.mozilla.plugincontainer", running: none)?.name == "Firefox")
    check("resolve: FaceTime's call daemon is FaceTime", MeetingApps.resolve("com.apple.avconferenced", running: none)?.key == facetime)
    check("resolve: FaceTime taps all system audio", MeetingApps.info(key: facetime)?.globalTap == true)
    check("resolve: WebKit's GPU process is Safari while Safari runs",
          MeetingApps.resolve("com.apple.WebKit.GPU", running: [safari])?.key == safari)
    check("resolve: WebKit's GPU process is nobody when Safari isn't running",
          MeetingApps.resolve("com.apple.WebKit.GPU", running: ["com.apple.mail"]) == nil)
    check("resolve: Verbose itself is never a call", MeetingApps.resolve("co.stumpandroot.verbatim", running: none) == nil)
    check("resolve: Verbose's helpers aren't either", MeetingApps.resolve("co.stumpandroot.verbatim.helper", running: none) == nil)
    check("resolve: apps that don't hold calls", MeetingApps.resolve("com.apple.VoiceMemos", running: none) == nil
          && MeetingApps.resolve("com.apple.QuickTimePlayerX", running: none) == nil)
    check("resolve: empty bundle ID", MeetingApps.resolve("", running: none) == nil)
    check("resolve: a prefix without the dot isn't a helper", MeetingApps.resolve("us.zoom.xosfake", running: none) == nil)
    check("every known app has a key that is its bundle ID lowercased", MeetingApps.known.allSatisfy { $0.key == $0.bundleID.lowercased() })
    check("browsers come after meeting apps", {
        guard let firstBrowser = MeetingApps.known.firstIndex(where: \.isBrowser) else { return false }
        return MeetingApps.known[firstBrowser...].allSatisfy(\.isBrowser)
    }())
}

// MARK: Guessing on macOS before 14.4

do {
    check("guess: the frontmost meeting app", MeetingApps.guess(frontmost: "com.google.Chrome", running: ["us.zoom.xos", "com.google.Chrome"])?.key == chrome)
    check("guess: else the first meeting app running", MeetingApps.guess(frontmost: "com.apple.finder", running: ["com.google.Chrome", "us.zoom.xos"])?.key == zoom)
    check("guess: a browser in the background isn't guessed", MeetingApps.guess(frontmost: "com.apple.finder", running: ["com.google.Chrome"]) == nil)
    check("guess: nothing running", MeetingApps.guess(frontmost: nil, running: []) == nil)
}

// MARK: When to ask

do {
    var t = MeetingCallTracker()
    let ctx = MeetingCallTracker.Context()
    check("debounce: nothing at once", t.update(using: [zoom], now: 100, context: ctx).isEmpty)
    check("debounce: nothing at 1.9 s", t.update(using: [zoom], now: 101.9, context: ctx).isEmpty)
    check("debounce: asks at 2 s", t.update(using: [zoom], now: 102, context: ctx) == [.prompt(zoom)])
    check("one prompt per call", t.update(using: [zoom], now: 110, context: ctx).isEmpty)
    // A short mute (the app lets go of the mic for 2 s) is the same call.
    check("short release: same call", t.update(using: [], now: 111, context: ctx).isEmpty)
    check("short release: no second prompt", t.update(using: [zoom], now: 113, context: ctx).isEmpty)
    // Letting go for longer ends the call; the next use is a new call.
    _ = t.update(using: [zoom], now: 118, context: ctx)
    check("end: not before the grace period", t.update(using: [], now: 121, context: ctx).isEmpty)
    check("end: reported after the grace period", t.update(using: [], now: 122, context: ctx) == [.ended(zoom)])
    check("end: idle afterward", t.isIdle)
    _ = t.update(using: [zoom], now: 200, context: ctx)
    check("new call: asks again", t.update(using: [zoom], now: 202.5, context: ctx) == [.prompt(zoom)])
}

do {
    var t = MeetingCallTracker()
    let ctx = MeetingCallTracker.Context()
    _ = t.update(using: [zoom], now: 0, context: ctx)
    check("flicker: under 2 s, then gone", t.update(using: [], now: 1, context: ctx).isEmpty)
    check("flicker: ends quietly, never asked", t.update(using: [], now: 5, context: ctx) == [.ended(zoom)])
}

do {
    var t = MeetingCallTracker()
    var ctx = MeetingCallTracker.Context()
    ctx.busy = true
    _ = t.update(using: [zoom], now: 0, context: ctx)
    check("busy: no prompt while Verbose dictates or records", t.update(using: [zoom], now: 5, context: ctx).isEmpty)
    ctx.busy = false
    check("busy: asks once Verbose is done, if the call goes on", t.update(using: [zoom], now: 6, context: ctx) == [.prompt(zoom)])
}

do {
    var t = MeetingCallTracker()
    var ctx = MeetingCallTracker.Context()
    ctx.recordingMeeting = true
    _ = t.update(using: [zoom], now: 0, context: ctx)
    check("recording: no prompt during a meeting recording", t.update(using: [zoom], now: 5, context: ctx).isEmpty)
    ctx.recordingMeeting = false
    check("recording: the call stays settled after it stops", t.update(using: [zoom], now: 60, context: ctx).isEmpty)
}

do {
    var t = MeetingCallTracker()
    var ctx = MeetingCallTracker.Context()
    ctx.enabled = false
    _ = t.update(using: [zoom], now: 0, context: ctx)
    check("off: never asks", t.update(using: [zoom], now: 5, context: ctx).isEmpty)
    ctx.enabled = true
    check("off: turning it on mid-call doesn't ask about that call", t.update(using: [zoom], now: 6, context: ctx).isEmpty)
}

do {
    var t = MeetingCallTracker()
    var ctx = MeetingCallTracker.Context()
    ctx.muted = [zoom]
    _ = t.update(using: [zoom, chrome], now: 0, context: ctx)
    check("muted: asks about the other app only", t.update(using: [zoom, chrome], now: 3, context: ctx) == [.prompt(chrome)])
}

do {
    var t = MeetingCallTracker()
    let ctx = MeetingCallTracker.Context()
    _ = t.update(using: [chrome, zoom], now: 0, context: ctx)
    check("two apps: asks about the meeting app, not the browser", t.update(using: [chrome, zoom], now: 2, context: ctx) == [.prompt(zoom)])
    check("two apps: the browser is settled with it", t.update(using: [chrome, zoom], now: 10, context: ctx).isEmpty)
}

do {
    var t = MeetingCallTracker()
    let ctx = MeetingCallTracker.Context()
    _ = t.update(using: [zoom], now: 0, context: ctx)
    _ = t.update(using: [zoom], now: 2, context: ctx)
    // Chrome joins later (a Meet tab): a new call of its own.
    _ = t.update(using: [zoom, chrome], now: 30, context: ctx)
    check("later app: asked about on its own", t.update(using: [zoom, chrome], now: 32, context: ctx) == [.prompt(chrome)])
    t.settleAll()
    check("settleAll: nothing pending", t.calls.values.allSatisfy(\.handled))
}

// MARK: Consent counts

do {
    var b = MeetingAppBook()
    check("consent: first time shows the sheet", b.needsConsent(zoom))
    check("consent: no skip offered before any recording", !b.canOfferSkip(zoom))
    b.noticed(zoom, name: "Zoom", at: Date(timeIntervalSince1970: 10))
    check("consent: noticing counts calls", b.apps[zoom]?.calls == 1 && b.apps[zoom]?.recorded == 0)
    for _ in 0..<4 { b.recorded(zoom, name: "Zoom") }
    check("consent: four recordings, no skip yet", !b.canOfferSkip(zoom) && b.needsConsent(zoom))
    check("consent: skipping is refused before five", !b.setSkipConsent(zoom, true) && b.needsConsent(zoom))
    b.recorded(zoom, name: "Zoom")
    check("consent: five recordings offer the skip", b.canOfferSkip(zoom))
    check("consent: still asks until you choose", b.needsConsent(zoom))
    check("consent: skip accepted after five", b.setSkipConsent(zoom, true) && !b.needsConsent(zoom))
    check("consent: per app", b.needsConsent(chrome))
    b.setSkipConsent(zoom, false)
    check("consent: turning the sheet back on", b.needsConsent(zoom))
    b.setDontAsk(chrome, name: "Chrome", true)
    check("dont ask: muted set", b.muted == [chrome])
    let round = MeetingAppBook.decode(b.encoded())
    check("book: survives JSON", round == b)
    check("book: damaged JSON is an empty book", MeetingAppBook.decode(Data("nope".utf8)) == MeetingAppBook())
    b.noticed(safari, name: "Safari", at: Date(timeIntervalSince1970: 99))
    check("book: most recent first", b.sorted.first?.key == safari)
}

// MARK: Words

do {
    check("copy: prompt title", MeetingCopy.promptTitle("Zoom") == "Zoom is using your microphone")
    check("copy: consent names the app", MeetingCopy.consentBody("Zoom").contains("the sound from Zoom"))
    check("copy: consent without an app", MeetingCopy.consentBody(nil).contains("other apps"))
    check("copy: header", MeetingCopy.recordingHeader("Zoom", paused: false, micOnly: false) == "Recording · Zoom + your mic")
    check("copy: header paused, mic only", MeetingCopy.recordingHeader("Zoom", paused: true, micOnly: true) == "Paused · your mic")
    check("copy: clock", MeetingCopy.clock(724) == "12:04" && MeetingCopy.clock(3723) == "1:02:03" && MeetingCopy.clock(-3) == "0:00")
    let all = [MeetingCopy.chatNotice, MeetingCopy.consentTitle, MeetingCopy.consentLaw, MeetingCopy.tellEveryone, MeetingCopy.promptDetail,
               MeetingCopy.silentDetail, MeetingCopy.sleptTitle, MeetingCopy.sleptDetail, MeetingCopy.silentTitle("Zoom"), MeetingCopy.dontAskAgain("Zoom")]
    check("copy: no exclamation points", all.allSatisfy { !$0.contains("!") })
    let banned = ["simply", "just ", "easily", "currently", "soon"]
    check("copy: no banned words", all.allSatisfy { s in banned.allSatisfy { !s.lowercased().contains($0) } })
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
