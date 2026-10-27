import Foundation

/// Pure checks for Plan my day, Audio only, and Brain dump (DayPlan.swift, AudioOnly.swift, Templates.swift), run by
/// both self-tests (UITest on Mac, PhoneUITest on iPhone) and by mac/tools/test-templates.sh. Builds transcripts in
/// memory only; nothing is saved, and the model never runs: the plan is a canned result.
enum PlanChecks {
    /// The mockup's brain dump (Tuesday, 7:42 AM), as Plan my day would write it.
    static let samplePlan = """
        ## Top three
        - [ ] Send the bakery invoice [00:04]
        - [ ] Finish the orchard storyboard before Thursday's call [00:11]
        - [ ] Call the print shop about the menu proofs [00:19]

        ## Today
        - [ ] Back up the cards from yesterday's shoot [00:27]

        ## Tomorrow
        - [ ] Book the drone pilot for the farm shoot [00:41]
        - [ ] Send the shot list to the client [00:47]

        ## This week
        - [ ] Renew the portfolio site's domain [00:58]
        - [ ] Pick up the lens from repair on Friday [01:06]

        ## Someday
        - [ ] Redo the studio reel [01:15]

        ## Ideas
        - A short series on how families run their farm stands [01:24]
        - A mug with the barn logo for the welcome kits [01:39]
        """

    /// A brain dump recorded at `at`, with its words and Plan my day's result.
    static func brainDump(at: Date) -> Transcript {
        var t = Transcript(title: "Brain dump, Tuesday", source: .voiceMemo, sourceLabel: "Voice memo", duration: 168, audioFileName: nil, model: "Test")
        t.createdAt = at
        t.segments = [Segment(start: 4, end: 9, text: "Okay. Today I need to send the bakery invoice, it's been sitting since Friday."),
                      Segment(start: 41, end: 46, text: "Tomorrow, book the drone pilot for the farm shoot and send the shot list to the client.")]
        t.original = t.segments
        t.pickKindAtStart(.brainDump)
        t.addTemplateResult(TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: samplePlan, auto: true, kind: .brainDump, madeOn: "iPhone"))
        t.autoRun = AutoRunMark(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", kind: .brainDump, state: .done, device: "self-test")
        return t
    }

    /// A short melody kept as Audio only, with two moments.
    static func audioOnly(at: Date) -> Transcript {
        var t = Transcript(title: "Melody for the second verse", source: .voiceMemo, sourceLabel: "Voice memo", duration: 72, audioFileName: nil, model: "")
        t.createdAt = at
        t.pickKindAtStart(.audio)
        t.titleIsAuto = false
        t.waveform = (0..<120).map { i in Float(0.3 + 0.6 * abs(sin(Double(i) * 0.16 + 0.4))) }
        var a = Note(text: "Chorus starts", at: 31, isBookmark: true); a.markSource = "lockScreen"
        var b = Note(text: "", at: 58, isBookmark: true); b.markSource = "phoneApp"
        t.notes = [a, b]
        return t
    }

    static func run(_ check: (String, Bool) -> Void, now: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let recorded = cal.date(bySettingHour: 7, minute: 42, second: 0, of: now) ?? now
        let plan = DayPlan.parse(samplePlan)
        check("plan my day: six sections from a canned result, top three first", plan.shownSections == [.top, .today, .tomorrow, .week, .someday, .ideas]
              && plan.top.map(\.text).first == "Send the bakery invoice" && plan.tasks.count == 9 && plan.ideas.count == 2)
        check("plan my day: each task keeps the time it was said", plan.top.first?.anchor == 4 && plan.week.last?.anchor == 66)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: recorded))!
        check("plan my day: tomorrow is the day after the recording, with no time",
              DayPlan.due(plan.tomorrow[0], recordedAt: recorded, calendar: cal).flatMap { cal.date(from: $0) } == tomorrow
              && DayPlan.due(plan.tomorrow[0], recordedAt: recorded, calendar: cal)?.hour == nil)
        check("plan my day: tasks with no day sit under Someday, with its line", plan.someday.count == 1 && DayPlan.due(plan.someday[0], recordedAt: recorded, calendar: cal) == nil
              && DayPlan.somedayLine == "And anything you didn\u{2019}t give a day")
        let noTop = DayPlan.parse("## Today\n- [ ] One [00:01]\n- [ ] Two [00:02]\n- [ ] Three [00:03]\n- [ ] Four [00:04]")
        check("plan my day: no top three named, today's first three in order, and it says so", noTop.topInferred && noTop.top.map(\.text) == ["One", "Two", "Three"])
        let drafts = DayPlan.drafts(plan, selected: DayPlan.defaultSelection(plan, sent: [:]), sent: [:], recordedAt: recorded, source: "Brain dump",
                                    anchorLabel: { $0.anchor.map(DayPlan.clock) }, calendar: cal)
        check("send to reminders: every task, ideas unchecked, due only where a day was said", drafts.count == 9
              && drafts.filter { $0.due != nil }.count == 7 && drafts[0].notes.hasPrefix("From Verbose \u{00B7} Brain dump, ") && drafts[0].notes.hasSuffix(", 0:04"))
        let t = brainDump(at: recorded)
        check("brain dump: Plan my day's result draws as a plan", t.templateResults.map { $0.contains(where: DayPlan.isPlan) } == true)
        check("brain dump: a short one still runs Plan my day", { var x = t; x.autoRun = nil; x.templateResults = nil; x.duration = 50; x.createdAt = now.addingTimeInterval(-30)
            return AutoRunRules.decide(x, settings: AutoRunSettings.startingChoices, templates: TemplateLibrary.all(yours: []), labelPending: false, now: now)
                == .run(TemplateLibrary.planMyDayID, .brainDump) }())
        let a = audioOnly(at: recorded)
        check("audio only: the queue, AutoLabel, Ask, and Run automatically leave it alone", AudioOnlyRules.skipsQueue(a) && !AudioOnlyRules.labels(a)
              && !AudioOnlyRules.indexes(a) && AutoRunRules.decide(a, settings: AutoRunSettings.startingChoices, templates: TemplateLibrary.all(yours: []), labelPending: false, now: now) == .notEligible)
        var later = a
        later.beginTranscribeLater()
        let waiting = later.isAudioOnly && later.status == .processing && later.showsAudioDetail
        later.segments = [Segment(start: 30, end: 34, text: "The chorus climbs here.")]
        later.status = .ready
        later.finishTranscribeLater(as: nil)
        check("transcribe later: a voice note with its title and moments kept", waiting && later.kind == nil && later.kindIsAuto
              && later.title == a.title && later.notes == a.notes && !later.isAudioOnly)
        var filed = t
        filed.kind = .audio
        check("changing a kind keeps the transcript, notes, and results", filed.segments == t.segments && filed.templateResults == t.templateResults && !filed.showsAudioDetail)
    }
}
