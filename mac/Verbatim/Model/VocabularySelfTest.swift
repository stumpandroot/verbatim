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

        // Word patch 1 (version 2): a sample of the new terms, the longest match winning, and look-alikes that stay.
        check("vocabulary: patch 1 is in the list", BuiltInVocabulary.terms.count >= 800
              && BuiltInVocabulary.terms.contains { $0.term == "NVIDIA" } && !BuiltInVocabulary.terms.contains { $0.term == "Nvidia" })
        check("vocabulary: new names and places", fixes("Ask gemeni, then chatgbt.", "Ask Gemini, then ChatGPT.")
              && fixes("We flew to albequerque via philidelphia.", "We flew to Albuquerque via Philadelphia.")
              && fixes("Did nvidia and huawai report?", "Did NVIDIA and Huawei report?")
              && fixes("Sam oltman met mark benioff.", "Sam Altman met Marc Benioff."))
        check("vocabulary: film, business, and general terms", fixes("Shoot h 264 on the sony fx3 with a kino flow.", "Shoot H.264 on the Sony FX3 with a Kino Flo.")
              && fixes("Our roas and the e b i t d a are up.", "Our ROAS and the EBITDA are up.")
              && fixes("Is it hippa compliant, per say?", "Is it HIPAA compliant, per se?"))
        check("vocabulary: the longest match wins", fixes("Get the i phone air.", "Get the iPhone Air.")
              && fixes("Record in black magic raw.", "Record in Blackmagic RAW.") && fixes("Gen alpha loves it.", "Gen Alpha loves it.")
              && fixes("Use a sure sm7b.", "Use a Shure SM7B.") && same("I record on a Shure SM7B."))
        check("vocabulary: plus names change only next to a context word", fixes("Watch the disney plus show.", "Watch the Disney+ show.")
              && same("We compared Netflix, Disney plus Universal, and Max.") && same("We use Alexa plus Google Home in the kitchen."))
        check("vocabulary: look-alike names stay", same("Every day I phone my mom.") && same("We met at Columbia University.")
              && same("He ordered chicken Kiev.") && same("I met Kofi Annan once.") && same("She walked through the open glass door.")
              && same("The birds twitter at dawn.") && same("Let's be real about the budget.") && same("That's a meta AI question."))
        check("vocabulary: look-alike names change next to their context words", fixes("We drove to Pittsburg PA.", "We drove to Pittsburgh PA.")
              && fixes("Send it to my Kofi page.", "Send it to my Ko-fi page."))

        // Everyday fixes: every example in the file becomes its fix, every "keep" stays, and a few more.
        let everyday = EverydayFixes.fixes
        func mended(_ s: String) -> String { EverydayFixes.apply(s, fixes: everyday) }
        let wrongExamples = EverydayFixes.samples.examples.filter { mended($0.0) != $0.1 }
        for e in wrongExamples.prefix(5) { Log.note("UITEST everyday fix got “\(mended(e.0))” for “\(e.0)”") }
        let movedKeeps = EverydayFixes.samples.keep.filter { mended($0) != $0 }
        for k in movedKeeps.prefix(5) { Log.note("UITEST everyday fix changed “\(k)” to “\(mended(k))”") }
        check("everyday fixes: the list loads", everyday.count >= 50 && EverydayFixes.samples.examples.count >= 50)
        check("everyday fixes: every example is fixed", !EverydayFixes.samples.examples.isEmpty && wrongExamples.isEmpty)
        check("everyday fixes: every keep sentence stays", !EverydayFixes.samples.keep.isEmpty && movedKeeps.isEmpty)
        check("everyday fixes: mix-ups", mended("I could of been there an then left.") == "I could have been there and then left."
              && mended("For all intensive purposes, it's a sneak peak.") == "For all intents and purposes, it's a sneak peek."
              && mended("Can you here me? I don’t no why.") == "Can you hear me? I don’t know why.")
        check("everyday fixes: ordinary sentences stay", mended("You could of course ask.") == "You could of course ask."
              && mended("There are two much bigger rooms.") == "There are two much bigger rooms."
              && mended("We need eggs, milk, and bread.") == "We need eggs, milk, and bread."
              && mended("It was an historic day.") == "It was an historic day."
              && mended("Three things:\n1. The photos\n2. the copy") == "Three things:\n1. The photos\n2. the copy")
        check("everyday fixes: before the grammar pass", GrammarPass.fix(mended("me an you should talk.")).lowercased() == "me and you should talk.")

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
