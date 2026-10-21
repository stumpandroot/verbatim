import Foundation

/// Self-tests for the built-in vocabulary, About me names, and learning from edits. The Mac's and the iPhone's UI
/// self-tests both run these (UITest.logicChecks, PhoneUITest.keyboardChecks). No model, no network, no Contacts.
enum VocabularySelfTest {
    static func run(_ check: (String, Bool) -> Void) {
        // The bundled list, whatever the switch says on this device.
        let rules = BuiltInVocabulary.rules(for: BuiltInVocabulary.terms)
        check("vocabulary: the built-in list loads", BuiltInVocabulary.terms.count >= 300 && rules.count > BuiltInVocabulary.terms.count)
        func same(_ s: String) -> Bool {
            let got = BuiltInVocabulary.fix(s, rules: rules)
            if got != s { Log.note("UITEST vocabulary changed “\(s)” to “\(got)”") }
            return got == s
        }
        func fixes(_ s: String, _ want: String) -> Bool {
            let got = BuiltInVocabulary.fix(s, rules: rules)
            if got != want { Log.note("UITEST vocabulary got “\(got)” for “\(s)”") }
            return got == want
        }
        check("vocabulary: ordinary words stay", same("I need to zoom in.") && same("I have a notion of what to do.")
              && same("Cut him some slack.") && same("The article is linked in the description.") && same("I phone my mom every day."))
        check("vocabulary: chat GPT becomes ChatGPT", fixes("Ask chat GPT about it.", "Ask ChatGPT about it."))
        check("vocabulary: git hub becomes GitHub", fixes("Push it to git hub tonight.", "Push it to GitHub tonight."))
        check("vocabulary: more modern words", fixes("Watch it on you tube, then open figma on my i phone.", "Watch it on YouTube, then open Figma on my iPhone.")
              && fixes("Update to mac OS and try whisper flow.", "Update to macOS and try Wispr Flow."))
        check("vocabulary: context words fix ambiguous ones", fixes("Hop on the zoom call.", "Hop on the Zoom call.")
              && fixes("Post it in the slack channel.", "Post it in the Slack channel."))
        check("vocabulary: links, addresses, and code stay", same("Open https://github.com/stumpandroot/verbatim now.")
              && same("Go to github.com and sign in.") && same("Email tim@github.com today.") && same("Run `git hub push` here."))

        // Your Dictionary wins: its spelling and its "heard as" forms are left alone.
        let mine = [DictionaryEntry(preferred: "Github", heardAs: ["git hub"], learnedFrom: "Added by you"),
                    DictionaryEntry(preferred: "Youtube", heardAs: ["you tube"], learnedFrom: "Added by you")]
        var segs = [Segment(start: 0, end: 1, text: "Push it to git hub and watch youtube.")]
        _ = DictionaryApplier.apply(mine, to: &segs, builtIn: false)
        let corrections = BuiltInVocabulary.apply(to: &segs, rules: rules, respecting: mine)
        check("vocabulary: your Dictionary wins", segs[0].text == "Push it to Github and watch youtube." && corrections.isEmpty)
        var shown = [Segment(start: 0, end: 1, text: "Send the pdf link.")]
        let shownFixes = BuiltInVocabulary.apply(to: &shown, rules: rules, respecting: [])
        check("vocabulary: every built-in fix is recorded", shown[0].text == "Send the PDF link."
              && shownFixes.count == 1 && shownFixes.first?.from == "pdf" && shownFixes.first?.to == "PDF")

        // About me names
        let names = NameExtractor.names(in: "Founder of Stump & Root Co. and Steadfast Films")
        if names != ["Stump & Root Co.", "Steadfast Films"] { Log.note("UITEST About me names: \(names)") }
        check("vocabulary: About me company names", names == ["Stump & Root Co.", "Steadfast Films"])
        let more = NameExtractor.names(in: "I'm Tim Medina, based in Strasburg, PA. Anchor client Star Quality. I love the outdoors.")
        if more != ["Tim Medina", "Strasburg", "Star Quality"] { Log.note("UITEST About me names: \(more)") }
        check("vocabulary: About me people and places", more == ["Tim Medina", "Strasburg", "Star Quality"])
        check("vocabulary: & is also heard as and", NameExtractor.heardForms("Stump & Root Co.") == ["Stump and Root Co."])
        let fromAbout = VocabularySuggestions.current(aboutMe: "Founder of Stump & Root Co. and Steadfast Films",
                                                      dictionary: [DictionaryEntry(preferred: "Steadfast Films", heardAs: [], learnedFrom: "Added by you")],
                                                      dismissedRaw: VocabularySuggestions.key(.aboutMe, heard: "", preferred: "Nobody"), pairs: [])
        check("vocabulary: About me skips words already in the Dictionary", fromAbout.map(\.preferred) == ["Stump & Root Co."]
              && fromAbout.first?.title == "Add Stump & Root Co. to your Dictionary?")
        let dismissed = VocabularySuggestions.dismissing(fromAbout.first?.id ?? "", in: "")
        check("vocabulary: dismissed suggestions stay dismissed",
              VocabularySuggestions.current(aboutMe: "Founder of Stump & Root Co.", dictionary: [], dismissedRaw: dismissed, pairs: []).isEmpty)

        // Learning from edits, in a scratch defaults suite
        let suite = "co.stumpandroot.verbatim.vocabulary-selftest"
        if let d = UserDefaults(suiteName: suite) {
            d.removePersistentDomain(forName: suite)
            let found = EditLearner.diff("We use chat gbt daily. It works.", "We use ChatGPT daily. It works.")
            check("vocabulary: edits are found word by word", found.count == 1 && found.first?.heard == "chat gbt" && found.first?.fixed == "ChatGPT")
            EditLearner.record(before: "We use chat gbt daily.", after: "We use ChatGPT daily.", in: d)
            check("vocabulary: one fix isn't a suggestion yet", EditLearner.ready(EditLearner.load(d)).isEmpty)
            EditLearner.record(before: "Ask chat gbt. Then chat gbt again.", after: "Ask ChatGPT. Then ChatGPT again.", in: d)
            let ready = EditLearner.ready(EditLearner.load(d))
            check("vocabulary: the same fix twice is a suggestion", ready.count == 1 && ready.first?.count == 2 && ready.first?.fixed == "ChatGPT")
            let fromEdits = VocabularySuggestions.current(aboutMe: "", dictionary: [], dismissedRaw: "", pairs: EditLearner.load(d))
            check("vocabulary: edit suggestion reads naturally", fromEdits.first?.title == "Always write ChatGPT for \u{201C}chat gbt\u{201D}?")
            EditLearner.record(before: "hello there. the end", after: "Hello there, the end", in: d)
            EditLearner.record(before: "Hello there. the end", after: "Hello there. The end", in: d)
            EditLearner.record(before: "it was great", after: "it is great", in: d)
            EditLearner.record(before: "it was great", after: "it is great", in: d)
            check("vocabulary: punctuation, sentence case, and grammar are ignored", EditLearner.load(d).count == 1)
            EditLearner.forget(heard: "chat gbt", fixed: "ChatGPT", in: d)
            check("vocabulary: a fix can be forgotten", EditLearner.load(d).isEmpty)
            d.removePersistentDomain(forName: suite)
        }
    }
}
