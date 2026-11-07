import Foundation

/// Names and titles for a call with no calendar event (CallWindowNames, MeetingNames, and Transcript's call titles),
/// checked by the Linux tests (`mac/tools/test-meeting-names.sh`) and the Mac's self-test (App/UITest.swift). `check`
/// logs PASS or FAIL. Every name and title here is invented.
enum CallNameChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let me = MeetingNames.selfNames(stored: "Sam Ortiz", account: "")

        // The call window: FaceTime's call shows the other person among its buttons and its timer.
        let call = CallWindowNames.Window(title: "FaceTime", texts: ["Dana Reyes", "FaceTime Video", "12:04", "Mute", "Camera", "Effects",
                                                                     "SharePlay", "End", "Sam Ortiz (Me)", "Connecting…"])
        let read = CallWindowNames.read(bundleID: "com.apple.FaceTime", windows: [call], selfNames: me)
        check("call window: FaceTime's call names the other person", read.names == ["Dana Reyes"] && read.meetingTitle == nil)
        check("call window: interface words and times are never names",
              ["FaceTime", "Mute", "End", "Effects", "12:04", "Connecting…", "Share Screen", "Add People"].allSatisfy { CallWindowNames.name($0) == nil })
        let list = CallWindowNames.Window(title: "FaceTime", texts: ["New FaceTime", "Create Link", "Priya Shah", "Omar Haddad"])
        check("call window: FaceTime's list of calls names nobody",
              CallWindowNames.read(bundleID: "com.apple.FaceTime", windows: [list], selfNames: me).names.isEmpty)
        let gallery = CallWindowNames.Window(title: "Zoom Meeting", texts: ["Priya Shah", "Omar Haddad", "Dana Reyes"])
        check("call window: a gallery of people names nobody",
              CallWindowNames.read(bundleID: "us.zoom.xos", windows: [gallery], selfNames: me).names.isEmpty)
        let number = CallWindowNames.Window(title: "FaceTime", texts: ["+1 (555) 010-4477", "FaceTime Audio"])
        let byNumber = CallWindowNames.read(bundleID: "com.apple.FaceTime", windows: [number], selfNames: me)
        check("call window: a phone number is looked up, never kept as a name", byNumber.names.isEmpty && byNumber.handles == ["+1 (555) 010-4477"])
        check("call window: the contact's name wins", CallWindowNames.preferContact("Dana", matches: ["Dana Reyes"]) == "Dana Reyes"
              && CallWindowNames.preferContact("Dana", matches: ["Dana Reyes", "Dana Baker"]) == "Dana")

        // Meeting titles from window titles.
        check("window titles: a Meet tab's meeting name", CallWindowNames.meetingTitle("Meet - Weekly design sync - Google Chrome", app: .browser) == "Weekly design sync")
        check("window titles: a Meet code is no title", CallWindowNames.meetingTitle("Meet - abc-defg-hij", app: .browser) == nil)
        check("window titles: another tab is no title", CallWindowNames.meetingTitle("Inbox (3) - Google Chrome", app: .browser) == nil)
        check("window titles: Teams' meeting, not its pages", CallWindowNames.meetingTitle("Budget review | Microsoft Teams", app: .teams) == "Budget review"
              && CallWindowNames.meetingTitle("Chat | Dana Reyes | Microsoft Teams", app: .teams) == nil)
        check("window titles: Zoom's own window is no title", CallWindowNames.meetingTitle("Zoom Meeting", app: .zoom) == nil)

        // Suggested like the one other invitee.
        let ctx = MeetingContext(app: "FaceTime", windowNames: ["Dana Reyes"])
        let s = MeetingNames.suggestions(ctx, selfNames: me, speakerId: "S2")
        check("window names: suggested for the call's track", s.count == 1 && s[0].name == "Dana Reyes" && s[0].fromCallWindow
              && s[0].reasons == ["shown in the FaceTime window"])
        let kept = SpeakerNames.merge(existing: s, new: []) ?? []
        check("window names: a later suggestion run keeps it", kept.map(\.name) == ["Dana Reyes"])

        // The generated title.
        let placeholder = Transcript.meetingPlaceholder(app: "FaceTime", stamp: "Nov 6, 2026 at 8:33 PM")
        check("titles: the generated call title is a placeholder", placeholder == "Meeting · FaceTime · Nov 6, 2026 at 8:33 PM"
              && Transcript.isMeetingPlaceholder(placeholder) && Transcript.isMeetingPlaceholder("Recovered meeting · Others · Nov 6, 2026 at 8:33 PM"))
        check("titles: a calendar title or a typed one isn't", !Transcript.isMeetingPlaceholder("Weekly design sync")
              && !Transcript.isMeetingPlaceholder("Meeting · notes") && !Transcript.isMeetingPlaceholder("Recovered: Weekly design sync"))
        check("titles: the name joins a written title", Transcript.titleAddingName("Film schedule and sound mix", name: "Dana") == "Film schedule and sound mix with Dana")
        check("titles: the name joins the placeholder", Transcript.titleAddingName(placeholder, name: "Dana") == "Meeting with Dana · FaceTime · Nov 6, 2026 at 8:33 PM")
        check("titles: never a second name", Transcript.titleAddingName("Budget call with Priya", name: "Dana") == nil
              && Transcript.titleAddingName("Planning Priya's visit", name: "Dana") == nil
              && Transcript.titleAddingName("Meeting with Dana · FaceTime · Nov 6, 2026 at 8:33 PM", name: "Dana") == nil)

        // A finished call: the placeholder may be retitled, and "Who was this with?" asks about the unnamed side.
        var t = Transcript(title: placeholder, source: .app, sourceLabel: "Meeting", duration: 600, audioFileName: nil, model: "")
        t.kind = .meeting
        t.speakers = [Speaker(id: "S1", name: "You"), Speaker(id: "S2", name: "FaceTime")]
        t.speakerSuggestions = []
        check("who was this with: asks about the call's unnamed side", t.callPartnerToAsk?.id == "S2" && t.waitsForModelTitle)
        var dismissed = t; dismissed.askWhoDismissed = true
        check("who was this with: Dismiss stops it", dismissed.callPartnerToAsk == nil)
        var suggested = t; suggested.speakerSuggestions = s
        check("who was this with: a suggestion shows instead", suggested.callPartnerToAsk == nil)
        var named = t; named.speakers[1].name = "Dana"
        named.addCallNameToTitle()
        check("who was this with: a name ends it and joins the title", named.callPartnerToAsk == nil
              && named.title == "Meeting with Dana · FaceTime · Nov 6, 2026 at 8:33 PM" && Transcript.isMeetingPlaceholder(named.title))
        var typed = named; typed.title = "Catch-up"; typed.titleIsAuto = false
        typed.addCallNameToTitle()
        check("titles: a title you typed never changes", typed.title == "Catch-up")
    }
}
