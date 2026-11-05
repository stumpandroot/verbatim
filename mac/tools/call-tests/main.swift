import Foundation

// Test cases for CallPlan (recording a call before it starts). Not part of any app target; run mac/tools/test-calls.sh.
// Event titles and names are invented.

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name) \(detail())") }
}

let zoom = "us.zoom.xos", chrome = "com.google.chrome", safari = "com.apple.safari", teams = "com.microsoft.teams2", slack = "com.tinyspeck.slackmacgap"

// MARK: Call links

do {
    func svc(_ fields: [String?]) -> CallService? { CallLinks.find(in: fields)?.service }
    check("links: a Zoom meeting link", svc(["https://us02web.zoom.us/j/81234567890?pwd=abc"]) == .zoom)
    check("links: a Zoom personal room", svc(["Join: https://zoom.us/my/printshop"]) == .zoom)
    check("links: Zoom for government", svc(["https://agency.zoomgov.com/j/1601234567"]) == .zoom)
    check("links: Zoom's home page isn't a call", svc(["https://zoom.us/pricing"]) == nil)
    check("links: a Meet code", svc(["https://meet.google.com/abc-defg-hij"]) == .meet)
    check("links: Meet's landing page isn't a call", svc(["https://meet.google.com/"]) == nil)
    check("links: a Teams meeting", svc(["https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x"]) == .teams)
    check("links: Teams for home", svc(["https://teams.live.com/meet/9876543210"]) == .teams)
    check("links: a Webex meeting", svc(["https://printshop.webex.com/meet/anka"]) == .webex)
    check("links: a Webex j.php link", svc(["https://printshop.webex.com/printshop/j.php?MTID=m123"]) == .webex)
    check("links: a FaceTime link", svc(["https://facetime.apple.com/join#v=1&p=abc"]) == .facetime)
    check("links: none in plain notes", svc(["Bring the proofs.", nil, ""]) == nil)
    check("links: Teams through a mail filter",
          svc(["https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_x&data=1"]) == .teams)
    check("links: the URL field comes before the notes",
          svc(["https://meet.google.com/abc-defg-hij", "Backup: https://zoom.us/j/123456789"]) == .meet)
    check("links: notes are read when there's no URL",
          svc([nil, "Room 4", "Catalog review with the printer\nJoin Zoom Meeting\nhttps://zoom.us/j/123456789 (ID 123)"]) == .zoom)
    check("links: a trailing period is left off", CallLinks.find(in: ["Join at https://zoom.us/j/123456789."])?.link == "https://zoom.us/j/123456789")
    check("links: a link in angle brackets", svc(["<https://meet.google.com/xyz-abcd-efg>"]) == .meet)
    check("links: a calendar link isn't a call", svc(["https://calendar.google.com/calendar/event?eid=abc"]) == nil)
    check("services: Meet runs in a browser and waits for browsers", CallService.meet.runsInBrowser
          && CallService.meet.appKeys.contains(chrome) && CallService.meet.appKeys.contains(safari) && !CallService.meet.appKeys.contains(zoom))
    check("services: Teams waits for both Teams apps", CallService.teams.appKeys == ["com.microsoft.teams2", "com.microsoft.teams"])
    check("services: every service's apps are known to the detector",
          CallService.allCases.allSatisfy { s in s.appKeys.allSatisfy { MeetingApps.info(key: $0) != nil } })
}

// MARK: Which call is next

let day = Calendar(identifier: .gregorian)
var cal = day
cal.timeZone = TimeZone(identifier: "America/New_York")!
func at(_ h: Int, _ m: Int, dayOffset: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 11, day: 3 + dayOffset, hour: h, minute: m))!
}
func event(_ id: String, _ h: Int, _ m: Int, minutes: Int = 45, service: CallService = .zoom, dayOffset: Int = 0) -> CallEvent {
    CallEvent(id: id, title: "Call \(id)", start: at(h, m, dayOffset: dayOffset), end: at(h, m, dayOffset: dayOffset).addingTimeInterval(Double(minutes) * 60),
              service: service, link: "https://zoom.us/j/1", attendees: ["Printer"], people: 4)
}

do {
    let review = event("review", 10, 30)
    check("next: not shown more than 30 minutes before", CallSchedule.next([review], now: at(9, 59)) == nil)
    check("next: shown 30 minutes before", CallSchedule.next([review], now: at(10, 0))?.id == "review")
    check("next: shown while it's on", CallSchedule.next([review], now: at(11, 10))?.id == "review")
    check("next: gone once it ends", CallSchedule.next([review], now: at(11, 15)) == nil)
    let early = event("early", 10, 0, minutes: 60)
    check("next: a call about to start comes before one that started a while ago",
          CallSchedule.next([early, review], now: at(10, 25))?.id == "review")
    check("next: the one that's on, when the next is still far off", CallSchedule.next([early, event("noon", 12, 0)], now: at(10, 20))?.id == "early")
    check("next: a tie goes to the earlier start", CallSchedule.next([event("b", 10, 40), event("a", 10, 20)], now: at(10, 30))?.id == "a")
    let later = CallSchedule.laterToday([early, review, event("two", 14, 0), event("tomorrow", 9, 0, dayOffset: 1)], shown: review, now: at(10, 5), calendar: cal)
    check("later: today's calls not yet started, without the one shown", later.map(\.id) == ["review", "two"].filter { $0 != "review" })
    check("later: tomorrow's calls aren't today's", !later.contains { $0.id == "tomorrow" })
    check("later: the line", CallSchedule.moreLine(1) == "1 more call today" && CallSchedule.moreLine(2) == "2 more calls today")
    check("relative: in 12 min", CallSchedule.relative(at(10, 30), now: at(10, 18)) == "in 12 min")
    check("relative: in 1 hr 5 min", CallSchedule.relative(at(11, 30), now: at(10, 25)) == "in 1 hr 5 min")
    check("relative: now", CallSchedule.relative(at(10, 30), now: at(10, 30).addingTimeInterval(20)) == "now")
    check("relative: started 8 min ago", CallSchedule.relative(at(10, 30), now: at(10, 38)) == "started 8 min ago")
    check("detail: Zoom · 4 people · 45 min", review.detail == "Zoom · 4 people · 45 min", review.detail)
    check("detail: one person and an hour and a half", CallEvent(id: "x", title: "x", start: at(9, 0), end: at(10, 30), service: .meet, link: "", people: 1).detail
          == "Google Meet · 1 hr 30 min")
    check("attendees: no emails, no blanks, no You, each once",
          CallSchedule.attendeeNames(["Printer Rep", "anka@example.com", nil, " ", "You", "printer rep", "Marco"]) == ["Printer Rep", "Marco"])
    check("attendees: the calendar's name first", CallSchedule.displayName(name: "Priya Shah", email: "mailto:ps@example.com") == "Priya Shah")
    check("attendees: a first and last name from the email",
          CallSchedule.displayName(name: nil, email: "mailto:priya.shah@example.com") == "Priya Shah"
          && CallSchedule.displayName(name: "omar_haddad+cal@example.com", email: nil) == "Omar Haddad")
    check("attendees: nothing from an email without a full name",
          CallSchedule.displayName(name: nil, email: "mailto:info@example.com") == nil && CallSchedule.displayName(name: nil, email: "mailto:pshah@example.com") == nil
          && CallSchedule.displayName(name: nil, email: "mailto:p.shah2@example.com") == nil && CallSchedule.displayName(name: nil, email: nil) == nil)
    // A recording started without an event (the Call tile, a call app already on the mic) takes the call happening now.
    let meet = event("meet", 10, 30, service: .meet)
    check("current: from ten minutes before its start", CallSchedule.current([meet], now: at(10, 19)) == nil && CallSchedule.current([meet], now: at(10, 21))?.id == "meet")
    check("current: while it's on, not after", CallSchedule.current([meet], now: at(11, 10))?.id == "meet" && CallSchedule.current([meet], now: at(11, 16)) == nil)
    check("current: a browser holds a Meet call, Zoom doesn't", CallSchedule.current([meet], now: at(10, 30), appKey: chrome)?.id == "meet"
          && CallSchedule.current([meet], now: at(10, 30), appKey: zoom) == nil)
    check("current: the closest start of two", CallSchedule.current([event("early", 10, 0, minutes: 60), event("late", 10, 30)], now: at(10, 28))?.id == "late")
}

// MARK: Waiting for a call

do {
    let now = at(10, 18)
    let all = CallWaitChoices.all
    check("choices: Any call app first, waiting for every known app", all.first?.isAny == true && all.first?.name == "Any call app"
          && all.first?.keys.count == MeetingApps.known.count)
    check("choices: Teams once, with both apps", all.filter { $0.name == "Microsoft Teams" }.count == 1
          && all.first { $0.name == "Microsoft Teams" }?.keys == ["com.microsoft.teams2", "com.microsoft.teams"])
    check("choices: Google Meet waits for every browser", all.first { $0.name == "Google Meet" }?.keys == CallService.meet.appKeys)
    check("choices: each browser on its own too", all.contains { $0.name == "Chrome" && $0.keys == [chrome] })
    check("choices: names are unique", Set(all.map(\.name)).count == all.count)
    check("choices: a calendar call's app", CallWaitChoices.forService(.zoom).keys == [zoom] && CallWaitChoices.forService(.meet) == CallWaitChoices.meet)

    let review = event("review", 10, 30)
    let w = CallWaitChoices.wait(CallWaitChoices.forService(.zoom), event: review, copyNotice: true, now: now)
    check("wait: an event's wait names the recording and keeps the attendees", w.title == "Call review" && w.attendees == ["Printer"] && w.eventID == "review")
    check("wait: an event's wait ends with the event", w.expires == review.end && !w.expired(now: at(11, 0)) && w.expired(now: at(11, 15)))
    check("wait: says what it waits for", w.startsLine == "Recording starts when Zoom joins the call.")
    let open = CallWaitChoices.wait(all[0], event: nil, copyNotice: false, now: now)
    check("wait: without an event, it gives up after three hours", open.expires == now.addingTimeInterval(3 * 3600) && open.title == nil)
    check("wait: Any call app says so", open.startsLine == "Recording starts when a call app starts using the microphone.")
    let meet = CallWaitChoices.wait(CallWaitChoices.meet, event: nil, copyNotice: true, now: now)
    check("wait: Meet's line names Meet", meet.startsLine == "Recording starts when Google Meet joins the call.")
    let ended = CallWaitChoices.wait(CallWaitChoices.forService(.zoom), event: event("past", 9, 0, minutes: 30), copyNotice: true, now: now)
    check("wait: an event already over still gets a minute, never a wait in the past", ended.expires == now.addingTimeInterval(60))

    var t = CallWaitTracker()
    check("tracker: nothing without a wait", t.update(wait: nil, using: [zoom], now: 0) == nil)
    check("tracker: an app already on the mic before setup fires right away", t.update(wait: w, using: [zoom], now: 2.5) == zoom)
    t.reset()
    check("tracker: not in the first two seconds", t.update(wait: w, using: [zoom], now: 10) == nil && t.update(wait: w, using: [zoom], now: 11) == nil)
    check("tracker: fires after two seconds", t.update(wait: w, using: [zoom], now: 12) == zoom)
    t.reset()
    check("tracker: another app doesn't fire a Zoom wait", t.update(wait: w, using: [slack], now: 0) == nil && t.update(wait: w, using: [slack], now: 5) == nil)
    t.reset()
    _ = t.update(wait: w, using: [zoom], now: 0)
    _ = t.update(wait: w, using: [], now: 1)
    check("tracker: a blip restarts the two seconds", t.update(wait: w, using: [zoom], now: 2) == nil && t.update(wait: w, using: [zoom], now: 3.5) == nil
          && t.update(wait: w, using: [zoom], now: 4) == zoom)
    t.reset()
    _ = t.update(wait: w, using: [zoom], now: 0)
    check("tracker: busy waits", t.update(wait: w, using: [zoom], now: 5, busy: true) == nil && t.update(wait: w, using: [zoom], now: 6) == zoom)
    t.reset()
    _ = t.update(wait: open, using: [chrome, zoom], now: 0)
    check("tracker: Any call app prefers the app over a browser", t.update(wait: open, using: [chrome, zoom], now: 3) == zoom)
    t.reset()
    _ = t.update(wait: meet, using: [safari], now: 0)
    check("tracker: Meet fires for a browser", t.update(wait: meet, using: [safari], now: 3) == safari)
    t.reset()
    _ = t.update(wait: meet, using: [teams], now: 0)
    check("tracker: Meet doesn't fire for Teams", t.update(wait: meet, using: [teams], now: 3) == nil)
}

// MARK: Stopping when the call ends

do {
    var e = CallEndWatch(key: zoom)
    check("end: nothing before the app has used the mic (recorded from the menu before joining)", e.update(using: [], now: 0) == nil
          && e.update(using: [], now: 30) == nil)
    check("end: the app on the mic", e.update(using: [zoom], now: 31) == nil)
    check("end: a moment off the mic isn't the end", e.update(using: [], now: 32) == nil && e.update(using: [], now: 34) == nil)
    check("end: four seconds off: Zoom left the call", e.update(using: [], now: 36) == .left)
    check("end: no second banner", e.update(using: [], now: 40) == nil)
    check("end: back on the mic hides it", e.update(using: [zoom], now: 45) == .back)
    _ = e.update(using: [], now: 50)
    check("end: leaves again", e.update(using: [], now: 54) == .left)
    check("end: not before 15 seconds", e.update(using: [], now: 68) == nil)
    check("end: stops 15 seconds after the banner", e.update(using: [], now: 69) == .stop)
    check("end: and only once", e.update(using: [], now: 80) == nil && e.update(using: [zoom], now: 81) == nil)

    var k = CallEndWatch(key: zoom)
    _ = k.update(using: [zoom], now: 0)
    _ = k.update(using: [], now: 1)
    check("keep: the banner", k.update(using: [], now: 5) == .left)
    k.keep()
    check("keep: no stop while the app stays away", k.update(using: [], now: 30) == nil && k.update(using: [], now: 300) == nil)
    check("keep: the app comes back", k.update(using: [zoom], now: 301) == nil)
    _ = k.update(using: [], now: 310)
    check("keep: and leaves again: asked again", k.update(using: [], now: 314) == .left)
    check("end: the grace is 15 seconds, after a 4-second notice", CallEndWatch.grace == 15 && CallEndWatch.noticeAfter == 4)
    var other = CallEndWatch(key: zoom)
    _ = other.update(using: [zoom], now: 0)
    check("end: another app on the mic doesn't keep Zoom's call going", other.update(using: [slack], now: 1) == nil && other.update(using: [slack], now: 5) == .left)
}

// MARK: Stills of shared screens

do {
    let slide = CallStillRules.Measure(characters: 220, textCover: 0.09, faces: 0, faceCover: 0)
    let gallery = CallStillRules.Measure(characters: 30, textCover: 0.01, faces: 6, faceCover: 0.35)
    let speaker = CallStillRules.Measure(characters: 12, textCover: 0.004, faces: 1, faceCover: 0.22)
    let shareWithThumb = CallStillRules.Measure(characters: 180, textCover: 0.06, faces: 1, faceCover: 0.03)
    let namesOnly = CallStillRules.Measure(characters: 60, textCover: 0.012, faces: 4, faceCover: 0.05)
    check("stills: a slide looks shared", CallStillRules.looksShared(slide))
    check("stills: a gallery doesn't", !CallStillRules.looksShared(gallery))
    check("stills: a speaker view doesn't", !CallStillRules.looksShared(speaker))
    check("stills: a shared screen with one small face thumbnail does", CallStillRules.looksShared(shareWithThumb))
    check("stills: a gallery of small faces with name labels doesn't", !CallStillRules.looksShared(namesOnly))
    check("stills: a blank frame doesn't", !CallStillRules.looksShared(.init(characters: 0, textCover: 0, faces: 0, faceCover: 0)))

    let a = [UInt8](repeating: 240, count: 256)
    var b = a; for i in 0..<64 { b[i] = 40 }        // a quarter of the frame changed: a new slide
    var c = a; for i in 0..<8 { c[i] = 200 }        // a cursor moved
    check("difference: same is 0", CallStillRules.difference(a, a) == 0)
    check("difference: black against white is 1", CallStillRules.difference([UInt8](repeating: 0, count: 256), [UInt8](repeating: 255, count: 256)) == 1)
    check("stills: the first shared frame is kept", CallStillRules.keep(gray: a, at: 10, measure: slide, last: nil, kept: 0))
    check("stills: the first frame that isn't shared isn't", !CallStillRules.keep(gray: a, at: 10, measure: gallery, last: nil, kept: 0))
    check("stills: a new slide is kept", CallStillRules.keep(gray: b, at: 30, measure: slide, last: (a, 10), kept: 1))
    check("stills: a moved cursor isn't", !CallStillRules.keep(gray: c, at: 30, measure: slide, last: (a, 10), kept: 1))
    check("stills: not within six seconds of the last", !CallStillRules.keep(gray: b, at: 14, measure: slide, last: (a, 10), kept: 1)
          && CallStillRules.keep(gray: b, at: 16, measure: slide, last: (a, 10), kept: 1))
    check("stills: not past the limit", !CallStillRules.keep(gray: b, at: 300, measure: slide, last: (a, 10), kept: CallStillRules.limit))
    check("stills: a change is worth measuring before Vision runs", CallStillRules.changed(gray: b, at: 30, last: (a, 10), kept: 1)
          && !CallStillRules.changed(gray: c, at: 30, last: (a, 10), kept: 1))
    check("stills: every two seconds", CallStillRules.interval == 2)
    check("window: the largest on-screen window big enough", CallStillRules.pickWindow([
        (id: 1, width: 300, height: 200, onScreen: true), (id: 2, width: 1440, height: 900, onScreen: true),
        (id: 3, width: 1920, height: 1080, onScreen: false), (id: 4, width: 800, height: 600, onScreen: true)]) == 2)
    check("window: none when every window is small or hidden", CallStillRules.pickWindow([(id: 1, width: 200, height: 150, onScreen: true),
                                                                                         (id: 2, width: 1200, height: 800, onScreen: false)]) == nil)
}

// MARK: Words

do {
    check("words: the started banner", MeetingCopy.startedTitle("Zoom") == "Recording your Zoom call"
          && MeetingCopy.startedDetail(app: "Zoom", title: "Catalog review with the printer", copied: true)
          == "Catalog review with the printer · two tracks. The chat notice is on your clipboard; paste it in the Zoom chat.")
    check("words: without an event or the notice", MeetingCopy.startedDetail(app: "Zoom", title: nil, copied: false) == "Your microphone and Zoom · two tracks.")
    check("words: the call ended", MeetingCopy.leftTitle("Zoom") == "Zoom left the call"
          && MeetingCopy.leftDetail(title: "Catalog review with the printer", seconds: 15) == "Recording stops in 15 seconds and saves as “Catalog review with the printer”."
          && MeetingCopy.leftDetail(title: nil, seconds: 15) == "Recording stops in 15 seconds and saves.")
    let words = [MeetingCopy.waitTitle, MeetingCopy.waitBody, MeetingCopy.waitBodyNoCall, MeetingCopy.copyOnStart,
                 MeetingCopy.startedDetail(app: "Zoom", title: "x", copied: true), MeetingCopy.leftDetail(title: "x", seconds: 15)]
    check("words: no em dashes or exclamation points", words.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("!") })
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
