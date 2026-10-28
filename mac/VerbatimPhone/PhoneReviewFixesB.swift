import SwiftUI

// Self-test builds only (VERBOSE_SELFTEST: Debug, and CI's tour and bench builds). Shipping builds leave these
// iPhone review-fix checks out with PhoneUITest.swift, which runs them.
#if VERBOSE_SELFTEST
// Self-test checks for the build 228 review fixes on iPhone, group B (Library, Dictations, Add from Library, Thoughts,
// Templates, the transcript, Moments, Settings and You, the session screens, and Ask). Pure checks run with the
// others at the start of the tour (`reviewFixesPhoneB`); the Journal tab's check runs in the tab bar tour, where the
// Journal tab is on screen (`reviewFixesPhoneBJournalTab`).
extension PhoneUITest {
    @MainActor
    static func reviewFixesPhoneB(_ app: PhoneState) {
        func check(_ name: String, _ ok: Bool) { Log.note("UITEST \(ok ? "PASS" : "FAIL") review fixes B: \(name)") }

        // P-25, P-26, superseded by the refined Library (DESIGN.md §6.8): the places are one card of rows.
        let places = LibraryScreen.placeRows(dictations: 3, todayThoughts: 0, templates: 13, recipes: 0, projects: 0)
        check("Library's places are one card: Dictations, By day, Templates, Ask", places.map { $0.title } == ["Dictations", "By day", "Templates", "Ask"])
        check("By day and Ask show no value at zero", places[1].value == nil && places[3].value == nil && places[0].value == "3")
        check("Projects joins the card once you have one, and the four first keep their hues",
              LibraryScreen.placeRows(dictations: 0, todayThoughts: 2, templates: 0, recipes: 1, projects: 2).last.map { $0.title == "Projects" && $0.value == "2" } == true
              && places.map { $0.hue } == [.butter, .sage, .petal, .neutral])

        // P-27: the type chips stay put.
        check("type chips keep a fixed order and keep the chosen type",
              LibraryScreen.fixedSources(library: [.videos, .voiceMemos], selected: .links) == [.voiceMemos, .videos, .links])
        check("type chips never list All twice", !LibraryScreen.fixedSources(library: [.all, .voiceMemos], selected: .all).contains(.all))

        // P-28: no empty or generic row titles.
        var thought = Transcript(title: "", source: .voiceMemo, sourceLabel: PhoneState.thoughtSource, duration: 4, audioFileName: nil, model: "")
        thought.kind = .idea
        let thoughtTitle = PhoneRowTitle.title(thought)
        check("an untitled thought's row says Thought and its time (\(thoughtTitle))", thoughtTitle.hasPrefix("Thought · ") && thoughtTitle.count > 10)
        thought.title = "Thought"
        check("a thought titled Thought gets its time too", PhoneRowTitle.title(thought).hasPrefix("Thought · "))
        check("Premium's item, with the time on its date line, says Thought alone", PhoneRowTitle.title(thought, withTime: false) == "Thought")
        let memo = Transcript(title: "Voice memo", source: .voiceMemo, sourceLabel: "Voice memo", duration: 4, audioFileName: nil, model: "")
        check("a placeholder voice memo title reads Voice note and its time", PhoneRowTitle.title(memo).hasPrefix("Voice note · "))
        let named = Transcript(title: "Catalog shoot plan", source: .voiceMemo, sourceLabel: "Voice memo", duration: 4, audioFileName: nil, model: "")
        check("a real title stays as it is", PhoneRowTitle.title(named) == "Catalog shoot plan")

        // P-29: Dictations' rows.
        check("a dictation with no cleanup level and pasted words has no status line", PhoneDictationRow.statusLine(level: nil, notPasted: false) == nil)
        check("the status line shows the level, and not pasted", PhoneDictationRow.statusLine(level: "Clean", notPasted: true) == "Clean · not pasted"
              && PhoneDictationRow.statusLine(level: nil, notPasted: true) == "not pasted")
        check("an app's square is its initial", PhoneDictationRow.initial("Messages") == "M" && PhoneDictationRow.initial(" ") == "K")

        // P-31: Verbose thought times keep morning and afternoon apart.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let now = Date()
        let ten = cal.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        let three = cal.date(bySettingHour: 15, minute: 0, second: 0, of: now) ?? now
        let us = Locale(identifier: "en_US"), uk = Locale(identifier: "en_GB")
        check("12-hour English: 10:00a and 3:00p (\(ThoughtText.compactTime(ten, locale: us, calendar: cal)), \(ThoughtText.compactTime(three, locale: us, calendar: cal)))",
              ThoughtText.compactTime(ten, locale: us, calendar: cal) == "10:00a" && ThoughtText.compactTime(three, locale: us, calendar: cal) == "3:00p")
        check("24-hour English stays 15:00", ThoughtText.compactTime(three, locale: uk, calendar: cal) == "15:00")

        // P-33: 1:1 has its own glyph.
        let meeting = TemplateLibrary.scenarios.first { $0.glyph == TemplateGlyph.meeting }
        let oneOnOne = TemplateLibrary.scenarios.first { $0.glyph == TemplateGlyph.oneOnOne }
        check("Meeting notes and 1:1 have different icons", meeting != nil && oneOnOne != nil
              && String(describing: meeting.map(\.art)) != String(describing: oneOnOne.map(\.art)))

        // P-35: one meta line under the transcript's title (the refined header: the kind is its chip, so the line is
        // when, the length, and the speakers).
        var kinded = Transcript(title: "Call", source: .voiceMemo, sourceLabel: "Voice memo", duration: 40, audioFileName: nil, model: "")
        kinded.kind = .meeting
        let metaLine = TranscriptScreen.meta(kinded, languageMenu: true, now: kinded.createdAt)
        check("a meeting's meta line is when and the length, with no kind repeated (\(metaLine))",
              metaLine.hasPrefix("Today, ") && metaLine.hasSuffix(" · 0:40") && !metaLine.contains("Meeting"))
        var link = Transcript(title: "Walkthrough", source: .link, sourceLabel: "youtube.com", duration: 400, audioFileName: nil, model: "")
        link.sourceURL = "https://www.youtube.com/watch?v=x"
        check("a link's meta line doesn't repeat its site", !TranscriptScreen.meta(link, languageMenu: true).contains("youtube"))

        // P-37: Clean up's chip.
        check("Clean up reads Clean up while off, and its level once set",
              PhoneDocument.cleanUpLabel(.none) == "Clean up" && PhoneDocument.cleanUpLabel(.light) == "Clean up · Light")

        // P-42: the link card's buttons say what they do.
        check("while downloading: Cancel download and Keep downloading",
              LinkAddedCard.cancelTitle(.downloading) == "Cancel download" && LinkAddedCard.doneTitle(.downloading) == "Keep downloading")
        check("once queued: Cancel and Done", LinkAddedCard.cancelTitle(.queued) == "Cancel" && LinkAddedCard.doneTitle(.queued) == "Done")

        // P-44: the Action button page's lede.
        check("the Action button lede has no Settings path in it", !ActionButtonScreen.lede.contains("›") && ActionButtonScreen.lede.hasPrefix("Choose what happens"))

        // P-46: search calls Appearance by its name.
        let look = SettingsSearchIndex.all.first { $0.id == "look" }
        check("search names the look's page Appearance and still finds \"look\"", look?.label == "Appearance" && look?.keywords.contains("look") == true)

        // P-49: What's new leads with what this iPhone can use.
        if let next = ReleaseNotes.bundled.first {
            let sum = ReleaseNotes.summary(next.items, for: .phone)
            check("What's new on iPhone opens with an item for this iPhone or Apple Watch",
                  sum.sections.first.map { ReleaseApp.phone.own.contains($0.platform) } ?? (sum.alsoCount == next.items.count))
            check("What's new keeps every item", sum.sections.reduce(0) { $0 + $1.items.count } + sum.alsoCount == next.items.count)
        }

        // P-50: Native Dictionary and Journal tiles differ.
        check("Native Dictionary and Journal tiles have different symbols", HomeTile.dictionary.symbol != HomeTile.journal.symbol)
    }

    /// P-32: the Journal tab's root has no Thoughts and Journal switch.
    @MainActor
    static func reviewFixesPhoneBJournalTab() {
        Log.note("UITEST \(ByDayScreen.switchShown == false ? "PASS" : "FAIL") review fixes B: the Journal tab has no Thoughts switch")
    }
}
#endif
