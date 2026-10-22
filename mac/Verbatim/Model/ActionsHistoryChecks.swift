import Foundation

/// Pure checks for the transcript actions, the Library's sort and search, and synced playback, run by both
/// self-tests (UITest on Mac, PhoneUITest on iPhone). Builds transcripts in memory only; nothing is saved.
enum ActionsHistoryChecks {
    @MainActor
    static func run(_ check: (String, Bool) -> Void) {
        // Actions: five, each with the no-add rule, and fixed IDs.
        let specs = TranscriptActions.builtIn
        check("actions: the five built-ins", specs.map(\.name) == ["Make a plan", "Journal entry", "Write a draft", "Study notes", "Key points"]
              && Set(specs.map(\.id)).count == 5)
        check("actions: every prompt says to use only the transcript", specs.allSatisfy { $0.instruction.contains(TranscriptActions.noAddRule) }
              && TranscriptActions.sessionInstructions.contains(TranscriptActions.noAddRule))
        check("actions: an edited prompt keeps the rule", TranscriptActions.withRule("Make a list.").hasSuffix(TranscriptActions.noAddRule)
              && TranscriptActions.withRule(TranscriptActions.noAddRule) == TranscriptActions.noAddRule)
        check("actions: only Key points reads times", specs.filter(\.timestamps).map(\.name) == ["Key points"])

        // Actions read the Original text with corrections, never the Cleaned text.
        var t = Transcript(title: "Plan", source: .voiceMemo, sourceLabel: "Voice memo", duration: 40, audioFileName: nil, model: "")
        t.original = [Segment(start: 0, end: 4, text: "Call Jon about the shed."), Segment(start: 12.4, end: 16, text: "Um.")]
        t.segments = [Segment(start: 0, end: 4, text: "Call John about the shed."), Segment(start: 12.4, end: 16, text: "Um."),
                      Segment(start: 17, end: 20, text: "Order the cedar on Friday.")]
        t.document = "CLEANED: call John."
        let src = TranscriptActions.source(t, timestamps: false)
        check("actions: run on the original with corrections", src.contains("Call John about the shed.") && src.contains("Order the cedar")
              && !src.contains("CLEANED") && !src.contains("Jon ") && !src.contains("Um."))
        let stamped = TranscriptActions.source(t, timestamps: true)
        check("actions: Key points sees line times", stamped.contains("[00:00] Call John") && stamped.contains("[00:17] Order"))
        let prompt = TranscriptActions.prompt(instruction: specs[0].instruction, text: src, part: (1, 2))
        check("actions: the prompt carries the rule and the transcript", prompt.contains(TranscriptActions.noAddRule)
              && prompt.contains("<transcript>\n" + src) && prompt.contains("part 1 of 2"))
        check("actions: a rewrite works in smaller parts", TranscriptActions.partLimit(extracts: false) < TranscriptActions.partLimit(extracts: true))
        check("actions: a code fence is dropped", TranscriptActions.clean("```\n- [ ] Call John\n```") == "- [ ] Call John")

        // Notes saved from an action keep the AI mark through a save and a load; older notes read without it.
        let note = Note(text: "- [ ] Call John", aiAction: "Make a plan")
        let back = (try? JSONEncoder().encode(note)).flatMap { try? JSONDecoder().decode(Note.self, from: $0) }
        check("notes: the AI mark round-trips", back == note && back?.aiAction == "Make a plan" && back?.byModel == true)
        let old = #"{"id":"\#(UUID().uuidString)","text":"Mine","isBookmark":false,"createdAt":700000000}"#
        let oldNote = try? JSONDecoder().decode(Note.self, from: Data(old.utf8))
        check("notes: older notes read as the person's", oldNote != nil && oldNote?.aiAction == nil && oldNote?.byModel == false)
        var withAI = t
        withAI.notes = [note, Note(text: "Mine")]
        check("export: AI notes carry their action", Exporter.aiResults(withAI).map { $0.action } == ["Make a plan"])

        // Sort orders.
        func make(_ title: String, _ dur: Double, _ ago: Double, pinned: Bool = false) -> Transcript {
            var x = Transcript(title: title, source: .voiceMemo, sourceLabel: "", duration: dur, audioFileName: nil, model: "")
            x.createdAt = Date(timeIntervalSince1970: 1_800_000_000 - ago); x.pinned = pinned
            return x
        }
        let a = make("beta", 30, 100), b = make("Alpha", 90, 300), c = make("gamma 10", 60, 200), d = make("gamma 9", 60, 50, pinned: true)
        let list = [a, b, c, d]
        check("sort: newest", LibrarySort.newest.sorted(list).map(\.title) == ["gamma 9", "beta", "gamma 10", "Alpha"])
        check("sort: oldest", LibrarySort.oldest.sorted(list).map(\.title) == ["Alpha", "gamma 10", "beta", "gamma 9"])
        check("sort: longest, ties newest first", LibrarySort.longest.sorted(list).map(\.title) == ["Alpha", "gamma 9", "gamma 10", "beta"])
        check("sort: title A–Z, numbers in order", LibrarySort.title.sorted(list).map(\.title) == ["Alpha", "beta", "gamma 9", "gamma 10"])
        let groups = Store.group(list, sort: .longest)
        check("sort: pinned first, one heading for Longest", groups.map(\.label) == ["Pinned", "Longest first"]
              && groups[1].items.map(\.title) == ["Alpha", "gamma 10", "beta"])
        check("sort: unknown saved value reads as Newest", LibrarySort(rawValue: "bogus") == nil && LibrarySort.allCases.count == 4)

        // Search covers the Cleaned text, the summary, notes, and tags.
        var s = make("Shed", 10, 0)
        s.segments = [Segment(start: 0, end: 2, text: "We talked about the roof.")]
        s.document = "We talked about the roof and the gutters."
        s.summary = TranscriptSummary(overview: "A chat about cedar shingles.")
        s.notes = [Note(text: "Ask about permits")]
        s.tags = ["backyard"]
        let idx = LibrarySearch.index(s)
        check("search: words, cleaned, summary, notes, tags", ["roof", "gutters", "cedar shingles", "permits", "backyard"].allSatisfy { LibrarySearch.matches(s, $0, index: idx) }
              && !LibrarySearch.matches(s, "basement", index: idx) && LibrarySearch.matches(s, "shed", index: idx))
        let hits = LibrarySearch.passages([s, t], query: "  roof ")
        check("search: passages find the line", hits.count == 1 && hits[0].lines.first?.text == "We talked about the roof." && hits[0].count == 1)
        check("search: one letter finds no passages", LibrarySearch.passages([s], query: "r").isEmpty)

        // Tap to seek: a line plays from its start, kept inside the recording.
        let line = Segment(start: 12.5, end: 15, text: "Order the cedar.")
        check("playback: a line plays from its start", PlaybackSync.seekTime(line, duration: 100) == 12.5
              && PlaybackSync.seekTime(Segment(start: -1, end: 1, text: "x"), duration: 100) == 0
              && PlaybackSync.seekTime(Segment(start: 120, end: 121, text: "x"), duration: 100) < 100
              && PlaybackSync.seekTime(line, duration: 0) == 12.5)
        check("playback: the line under the playhead", PlaybackSync.line(at: 18, in: t.segments)?.text == "Order the cedar on Friday."
              && PlaybackSync.line(at: 10, in: t.segments) == nil)
        var timed = Segment(start: 0, end: 3, text: "Order the cedar, Friday.")
        timed.words = [WordSpan(text: " Order", start: 0, end: 0.4), WordSpan(text: " the", start: 0.5, end: 0.7),
                       WordSpan(text: " cedar", start: 0.8, end: 1.3), WordSpan(text: ",", start: 1.3, end: 1.3), WordSpan(text: " Friday.", start: 1.6, end: 2.2)]
        check("playback: fresh word timings map to the shown words", PlaybackSync.timingsFresh(timed)
              && PlaybackSync.timingIndex(timed) == [0, 1, 2, 4] && PlaybackSync.wordIndex(at: 0.9, in: timed) == 2
              && PlaybackSync.wordIndex(at: 1.8, in: timed) == 4)
        var edited = timed
        edited.text = "Order the pine, Friday."
        check("playback: a corrected line falls back to the line highlight", !PlaybackSync.timingsFresh(edited)
              && PlaybackSync.wordIndex(at: 0.9, in: edited) == nil && PlaybackSync.timingIndex(edited).allSatisfy { $0 == nil })
        check("playback: speeds and labels", PlaybackSync.speeds.first == 0.75 && PlaybackSync.speeds.last == 2
              && PlaybackSync.speedLabel(0.75) == "0.75×" && PlaybackSync.speedLabel(1) == "1×" && PlaybackSync.speedLabel(1.5) == "1.5×")
    }
}
