import Foundation

/// Self-tests for Original and Cleaned: exact, reversible corrections; Clean up always starting from the corrected
/// lines; Copy taking the tab's text; and the three export sources. The Mac's and the iPhone's UI self-tests both run
/// these (UITest.logicChecks, PhoneUITest.keyboardChecks). No model, no network.
enum OriginalCleanedSelfTest {
    static func run(_ check: (String, Bool) -> Void) {
        // MARK: Corrections apply and undo exactly
        var t = Transcript(title: "Studio visit", source: .voiceMemo, sourceLabel: "Voice memo", duration: 8, audioFileName: nil, model: "test")
        let engine = Segment(start: 0, end: 4, text: "Claude met cloud at the studio.")
        t.original = [engine]
        t.segments = [engine]
        let entry = DictionaryEntry(preferred: "Claude", heardAs: ["cloud"], learnedFrom: "Added by you")
        t.corrections = DictionaryApplier.apply([entry], to: &t.segments, builtIn: false)
        check("corrections: Dictionary fix lands", t.segments[0].text == "Claude met Claude at the studio." && t.corrections.count == 1
              && t.corrections[0].spans?.count == 1 && t.corrections[0].spans?.first?.heard == "cloud")
        t.correct(segment: engine.id, from: "met", to: "greeted")
        check("corrections: a manual fix moves the earlier one with the text", t.segments[0].text == "Claude greeted Claude at the studio."
              && t.corrections.count == 2 && t.corrections[0].spans?.first?.location == 15)
        let dictionaryFix = t.corrections[0], manualFix = t.corrections[1]
        t.undo(dictionaryFix)
        check("corrections: Undo leaves the word that was already there", t.segments[0].text == "Claude greeted cloud at the studio." && t.corrections.count == 1)
        t.undo(manualFix)
        check("corrections: undoing every fix gives back the engine's text", t.segments[0].text == engine.text && t.corrections.isEmpty
              && t.original[0].text == engine.text)

        // Corrections from builds before spans: the engine's words find the right place.
        var old = t
        old.segments[0].text = "Claude met Claude at the studio, said Claude."
        old.original[0].text = "Claude met cloud at the studio, said Claude."
        let legacy = Correction(segmentId: engine.id, from: "cloud", to: "Claude", byDictionary: true)
        let other = Correction(segmentId: engine.id, from: "x", to: "y", byDictionary: false)
        old.corrections = [legacy, other]
        old.undo(legacy)
        check("corrections: older fixes undo by the engine's words", old.segments[0].text == "Claude met cloud at the studio, said Claude.")

        // Built-in vocabulary keeps spans too.
        var built = [Segment(start: 0, end: 1, text: "Ask chat GPT, then chat GPT again.")]
        let rules = BuiltInVocabulary.rules(for: BuiltInVocabulary.terms)
        let fixes = BuiltInVocabulary.apply(to: &built, rules: rules, respecting: [])
        check("corrections: built-in fixes record where they went", built[0].text == "Ask ChatGPT, then ChatGPT again."
              && fixes.contains { $0.to == "ChatGPT" && $0.spans?.count == 2 })

        // MARK: Clean up starts from the corrected lines
        var c = Transcript(title: "Notes", source: .voiceMemo, sourceLabel: "Voice memo", duration: 6, audioFileName: nil, model: "test")
        c.original = [Segment(start: 0, end: 2, text: "So um the plan is simple."), Segment(start: 2, end: 4, text: "We ship on Friday.")]
        c.segments = c.original
        let base = c.cleanupBase
        c.applyCleanup("The plan is simple. We ship Friday.", level: "Light", tone: "As spoken", byModel: true)
        let afterFirst = c.cleanupBase
        c.typeInCleaned("The plan is simple. We ship Friday!")
        check("cleanup: typing marks your edits", c.documentEdited)
        c.applyCleanup("The plan is simple. We ship on Friday.", level: "Medium", tone: "As spoken", byModel: true)
        check("cleanup: running it twice starts from the same base", base == afterFirst && c.cleanupBase == base
              && base == "So um the plan is simple. We ship on Friday." && !c.documentEdited)
        check("cleanup: the model's text is labeled", c.cleanedBy == .model && c.cleanedByModel)
        c.undoDocument()
        check("cleanup: Undo brings back your edits", c.document == "The plan is simple. We ship Friday!" && c.cleanedBy == .model)
        c.resetCleaned()
        check("cleanup: Reset goes back to the corrected lines", c.document == nil && c.cleanedBy == nil && c.documentText == base)
        c.applyRuleFixes("So um, the plan is simple. We ship on Friday.")
        check("cleanup: rule fixes are labeled as rules", c.cleanedBy == .rules)
        check("cleanup: the Original is never changed", c.original.map(\.text) == ["So um the plan is simple.", "We ship on Friday."]
              && c.segments.map(\.text) == c.original.map(\.text))

        // MARK: Copy takes the tab's text
        var k = c
        k.document = "The plan is simple. We ship on Friday."
        k.documentCleanedBy = .model
        k.segments[1].text = "We ship on Friday, Tim."
        check("copy: Cleaned copies the cleaned text", Exporter.copyText(k, .cleaned) == "The plan is simple. We ship on Friday.")
        check("copy: Original copies the corrected lines as a paragraph", Exporter.copyText(k, .original) == "So um the plan is simple. We ship on Friday, Tim.")
        check("copy: engine words copy what the engine heard", Exporter.copyText(k, .engine) == "So um the plan is simple. We ship on Friday.")
        check("copy: with timestamps, one line each", Exporter.copyText(k, .original, timestamps: true)
              == "[00:00:00] So um the plan is simple.\n[00:00:02] We ship on Friday, Tim.")

        // MARK: Export sources
        var o = ExportOptions()
        o.header = false; o.speakerMode = .off; o.timecodeMode = .off; o.moments = .off; o.summary = false
        o.source = .engine
        let engineOut = Exporter.render(k, as: .txt, options: o)
        o.source = .transcript
        let correctedOut = Exporter.render(k, as: .txt, options: o)
        o.source = .document
        let cleanedOut = Exporter.render(k, as: .txt, options: o)
        o.aiNote = false
        let cleanedNoNote = Exporter.render(k, as: .txt, options: o)
        check("export: engine words", engineOut == "So um the plan is simple.\n\nWe ship on Friday.")
        check("export: original with corrections", correctedOut == "So um the plan is simple.\n\nWe ship on Friday, Tim.")
        check("export: cleaned carries the Apple Intelligence note", cleanedOut == Exporter.aiNoteText + "\n\nThe plan is simple. We ship on Friday.")
        check("export: the note can be turned off", cleanedNoNote == "The plan is simple. We ship on Friday.")
        var rulesOnly = k
        rulesOnly.documentCleanedBy = .rules
        o.aiNote = true
        check("export: no note when only rules cleaned it", !Exporter.render(rulesOnly, as: .md, options: o).contains(Exporter.aiNoteText))
        check("export: subtitles follow the corrected lines", Exporter.render(k, as: .srt, options: o).contains("Tim"))
        check("export: sources have their names", ExportOptions.Source.allCases.map(\.label) == ["Cleaned", "Original with corrections", "Original (engine words)"])
    }
}
