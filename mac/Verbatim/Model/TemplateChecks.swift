import Foundation

/// Pure checks for templates and Run automatically (Templates.swift), run by both self-tests (UITest on Mac,
/// PhoneUITest on iPhone). Builds transcripts in memory only; nothing is saved. mac/tools/test-templates.sh covers the
/// same rules on Linux in more detail.
enum TemplateChecks {
    /// A recording finished a few seconds ago, of `kind` (picked when `picked`), with words.
    static func recording(_ kind: RecordingKind?, picked: Bool, minutes: Double = 32, now: Date = Date()) -> Transcript {
        var t = Transcript(title: "Client call · website refresh", source: .voiceMemo, sourceLabel: "Voice memo", duration: minutes * 60, audioFileName: nil, model: "Test")
        t.segments = [Segment(start: 0, end: 5, text: "The headline is too long. Can we launch on November 18?", speaker: "S1"),
                      Segment(start: 5, end: 9, text: "Yes. I'll send two shorter headlines by Friday.", speaker: "S2")]
        t.original = t.segments
        t.speakers = [Speaker(id: "S1", name: "Alex"), Speaker(id: "S2", name: "Sam")]
        t.createdAt = now.addingTimeInterval(-30)
        if picked { t.pickKindAtStart(kind) } else { t.kind = kind }
        return t
    }

    /// The sample result the screenshots and checks use: Meeting notes' four sections.
    static let sampleMeetingNotes = """
        ## Summary
        Alex wants the refreshed site live by November 18. The homepage gets a shorter headline, and the contact form moves higher.

        ## Decisions
        - Launch stays on November 18.
        - Keep the logo; refresh the colors only.

        ## Action items
        - [ ] Send two shorter headlines by Friday (Sam)
        - [ ] Check the contact form on phones

        ## Open questions
        - Does the blog move to the new site at launch or after?
        """

    static func run(_ check: (String, Bool) -> Void) {
        let meeting = TemplateLibrary.scenarios[0], reflection = TemplateLibrary.scenarios[7]
        let lib = TemplateLibrary.all(yours: [])
        check("five built-ins and nine scenarios, Plan my day ninth", TemplateLibrary.builtIn.count == 5 && TemplateLibrary.scenarios.count == 9 && lib.count == 14
              && TemplateLibrary.scenarios[8].id == TemplateLibrary.planMyDayID)
        check("every template prompt carries the no-add rule", lib.allSatisfy { TemplatePrompt.instruction($0).hasSuffix(TranscriptActions.noAddRule) })
        check("Meeting notes asks for its four sections as headings", TemplatePrompt.instruction(meeting).contains("1. Summary") && TemplatePrompt.instruction(meeting).contains("4. Open questions"))

        var s = AutoRunSettings()
        check("Run automatically starts Off for every kind, skip short on, show first off, notify on", s.assignedCount == 0 && s.skipShort && !s.showFirst && s.notify)
        s.set(meeting.id, for: .meeting)
        s.set(reflection.id, for: .journal)

        // A picked kind.
        var picked = recording(nil, picked: false)
        picked.pickKindAtStart(.meeting)
        picked.applySuggestedKind(.note)
        check("a kind picked when recording starts isn't overwritten by AutoLabel", picked.kind == .meeting && !picked.kindIsAuto)
        check("the auto-run picks the template by the picked kind", AutoRunRules.decide(picked, settings: s, templates: lib, labelPending: true) == .run(meeting.id, .meeting))
        var guessed = recording(nil, picked: false)
        check("with no kind yet, the auto-run waits for AutoLabel", AutoRunRules.decide(guessed, settings: s, templates: lib, labelPending: true) == .waitForKind)
        guessed.applySuggestedKind(.journal)
        check("then runs the guessed kind's template", AutoRunRules.decide(guessed, settings: s, templates: lib, labelPending: false) == .run(reflection.id, .journal))
        check("Skip short recordings skips under two minutes", AutoRunRules.decide(recording(.meeting, picked: true, minutes: 1.5), settings: s, templates: lib, labelPending: false) == .short)
        check("a kind set to Off waits for you", AutoRunRules.decide(recording(.talk, picked: true), settings: s, templates: lib, labelPending: false) == .off)

        // Run once, and the kind-change offer.
        var ran = recording(.meeting, picked: true)
        ran.autoRun = AutoRunMark(templateId: meeting.id, name: meeting.name, kind: .meeting, state: .done, device: "self-test")
        ran.addTemplateResult(TemplateResult(templateId: meeting.id, name: meeting.name, text: sampleMeetingNotes, auto: true, kind: .meeting, madeOn: "Mac"))
        check("a recording that ran never runs again", AutoRunRules.decide(ran, settings: s, templates: lib, labelPending: false) == .alreadyRan)
        ran.kind = .journal
        let offer = AutoRunRules.offer(ran, settings: s, templates: lib)
        check("kind changed after a run: the offer appears", offer?.text == "Now a Journal. Run Daily reflection?")
        check("kind changed after a run: it doesn't run on its own", AutoRunRules.decide(ran, settings: s, templates: lib, labelPending: false) == .alreadyRan)
        ran.kind = .talk
        check("kind changed to an Off kind: no offer", AutoRunRules.offer(ran, settings: s, templates: lib) == nil)
        check("the result says why it ran", ran.templateResults.flatMap { $0.first.flatMap(AutoRunRules.reason) } == "Ran automatically because this is a Meeting")
        check("the result's sections are the template's", TemplateResultText.blocks(sampleMeetingNotes).compactMap { if case .heading(let h) = $0 { return h } else { return nil } }
              == meeting.sections.map(\.name))
        check("record as: eight choices, Voice note first, then Thought, Brain dump, and Audio only, no Note",
              RecordChoice.all.map(\.name) == ["Voice note", "Meeting", "Interview", "Journal entry", "Talk", "Thought", "Brain dump", "Audio only"])
        check("record menu titles", RecordChoice.all.map(\.menuTitle) == ["Record", "Record a meeting", "Record an interview", "Record a journal entry", "Record a talk", "New thought",
                                                                          "Record a brain dump", "Record audio only"])
        var hints = AutoRunSettings()
        hints.set(meeting.id, for: .meeting)
        check("record as: a kind with a template says it runs", RecordChoice.kind(.meeting).hint(settings: hints, templates: lib) == "Runs Meeting notes when it finishes")
        check("record as: a kind with Run automatically off says what it does", RecordChoice.kind(.interview).hint(settings: hints, templates: lib) == "Filed under Interviews, every voice kept")
        check("record as: Brain dump runs Plan my day from the start; Audio only names no template",
              RecordChoice.kind(.brainDump).hint(settings: AutoRunSettings.startingChoices, templates: lib) == "Runs Plan my day when it finishes"
              && RecordChoice.kind(.audio).hint(settings: AutoRunSettings.startingChoices, templates: lib) == RecordChoice.audioOnlyLine)
        check("record as: Voice note and Thought keep their lines", RecordChoice.voiceNote.hint(settings: hints, templates: lib) == "Plain Record. Verbose picks the kind."
              && RecordChoice.thought.hint(settings: hints, templates: lib) == "Adds to today\u{2019}s page")
    }
}
