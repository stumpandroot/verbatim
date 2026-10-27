import Foundation

/// Mark a moment's rules (Marks.swift), checked by the Linux tests (`mac/tools/test-marks.sh`) and by both self-tests
/// (the Mac's UITest and the iPhone's tour). `check` logs PASS or FAIL.
enum MarkChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let lines = [
            Segment(start: 242, end: 252, text: "Let's start with the empty states, since they show up first."),
            Segment(start: 252, end: 265, text: "Empty states need one sentence, not two. The second one never gets read."),
            Segment(start: 265, end: 280, text: "Agreed. And the button should say what it does, like Record, not Get started."),
            Segment(start: 707, end: 718, text: "The calendar dots read better in ink. Persimmon looks like something is recording."),
        ]

        // Dedupe while recording and on Stop.
        let a = RecordingMark(at: 254, source: MarkSource.lockScreen.rawValue)
        var marks = [a]
        let again = Marks.adding(RecordingMark(at: 255.5, source: MarkSource.actionButton.rawValue), to: marks)
        check("marks: a second press within 3 seconds confirms the first, no second moment", again.marks.count == 1 && again.confirmed.id == a.id)
        marks = Marks.adding(RecordingMark(at: 258, source: MarkSource.island.rawValue), to: marks).marks
        check("marks: 4 seconds later is a moment of its own", marks.count == 2)
        let raw = [RecordingMark(at: 10, source: "island"), RecordingMark(at: 11, name: "The price", source: "phoneApp"),
                   RecordingMark(at: 12.9, source: "island"), RecordingMark(at: 20, source: "island"), RecordingMark(at: 5, source: "island")]
        let kept = Marks.deduped(raw)
        check("marks: dedupe keeps time order and one mark per 3 seconds", kept.map(\.at) == [5, 10, 20])
        check("marks: a dropped mark's name moves to the one kept", kept[1].name == "The price")

        // Marks become bookmarks with their source.
        let notes = RecordingMark.notes([RecordingMark(at: 254, source: "lockScreen"), RecordingMark(at: 709, name: "  Dots  ", source: "watch"),
                                         RecordingMark(at: 1385, source: "macHotkey", keys: "⌃⌥B")], offset: 0)
        check("marks: each becomes a bookmark with its time and source", notes.count == 3 && notes.allSatisfy { $0.isBookmark && $0.isMark }
              && notes.map(\.at) == [254, 709, 1385] && notes.map(\.markSource) == ["lockScreen", "watch", "macHotkey"])
        check("marks: unnamed marks wait for their line; a name is kept, trimmed", notes[0].text.isEmpty && notes[1].text == "Dots")
        let appended = RecordingMark.notes([RecordingMark(at: 12, source: "island")], offset: 600)
        check("marks: added to a transcript, a mark lands after what was there", appended.first?.at == 612)

        // Snap to the line being said.
        let loose = Note(text: "Untimed note")
        var other = Note(text: "Ask about permits", at: 250)
        other.segmentId = nil
        let snapped = Marks.snap(notes + [loose, other], to: lines)
        let lock = snapped.first { $0.markSource == "lockScreen" }
        check("snap: a mark takes the line under it, and the line's time", lock?.segmentId == lines[1].id && lock?.at == 252)
        check("snap: an unnamed mark quotes the line's first sentence", lock?.text == "Empty states need one sentence, not two.")
        let dots = snapped.first { $0.markSource == "watch" }
        check("snap: a named mark keeps its name", dots?.text == "Dots" && dots?.segmentId == lines[3].id)
        let late = snapped.first { $0.markSource == "macHotkey" }
        check("snap: a mark after the last line takes the last line", late?.segmentId == lines[3].id || late == nil)
        check("snap: notes that aren't marks are left alone", snapped.contains { $0.text == "Ask about permits" && $0.segmentId == nil && $0.at == 250 }
              && snapped.contains { $0.text == "Untimed note" })
        let twice = Marks.snap([Note(text: "", at: 253, isBookmark: true).marked("island"), Note(text: "Rename me", at: 260, isBookmark: true).marked("lockScreen")], to: lines)
        check("snap: two marks on one line are one moment, with the name you gave", twice.count == 1 && twice.first?.text == "Rename me" && twice.first?.markSource == "island")
        check("snap: twice is the same as once", Marks.snap(snapped, to: lines) == snapped)
        check("snap: nothing to snap to before the words are in", Marks.snap(notes, to: []) == notes)
        var held = Note(text: "Mine", at: 254, isBookmark: true).marked("island")
        held.segmentId = lines[1].id
        let beside = Marks.snap([held, Note(text: "", at: 256, isBookmark: true).marked("lockScreen")], to: lines)
        check("snap: a line that already holds a mark keeps it", beside.count == 1 && beside[0].text == "Mine")

        // Quotes.
        check("quote: the first sentence of a line", Marks.quote("Then persimmon stays for record. I'll change the dots today.") == "Then persimmon stays for record.")
        check("quote: a short opener runs on to the next sentence", Marks.quote("Agreed. And the button should say what it does.") == "Agreed. And the button should say what it does.")
        let long = String(repeating: "word ", count: 40)
        let q = Marks.quote(long)
        check("quote: a long line is cut at a word with an ellipsis", q.count <= Marks.quoteLimit + 1 && q.hasSuffix("…") && !q.contains("wor…"))

        // Words.
        check("words: the confirmation", Marks.confirmation(MarkConfirmation(at: 252, count: 3)) == "Marked 4:12 · 3 moments"
              && Marks.confirmation(MarkConfirmation(at: 3725, count: 1)) == "Marked 1:02:05 · 1 moment")
        check("words: chips name where each mark came from", lock.flatMap(Marks.chip) == "Moment 4:12 · from the Lock Screen"
              && dots.flatMap(Marks.chip) == "Moment 11:47 · from the Apple Watch")
        check("words: the Moments column's short sources", MarkSource.allCases.map { $0.short() } ==
              ["Dynamic Island", "Lock Screen", "Action button", "iPhone", "Mac", "Mac · bubble", "Mac · ⌃⌥B", "Apple Watch"])
        check("words: a rebound hotkey is named as pressed", MarkSource.macHotkey.short(keys: "⌃⌥M") == "Mac · ⌃⌥M"
              && Marks.shortSource(Note(text: "", at: 1, isBookmark: true).marked("macHotkey", keys: "⌃⇧K")) == "Mac · ⌃⇧K")
        check("words: a source from a newer build still reads", Marks.chipSource(Note(text: "", at: 1, isBookmark: true).marked("ring")) == "marked while recording"
              && Marks.shortSource(Note(text: "", at: 1, isBookmark: true).marked("ring")) == "Marked")
        check("words: other notes have no source", Marks.chip(Note(text: "Mine", at: 3, isBookmark: true)) == nil)
        check("words: an unnamed bookmark reads as its line, or Moment before the words", Marks.words(Note(text: "", at: 253, isBookmark: true), in: lines) == "Empty states need one sentence, not two."
              && Marks.words(Note(text: "", at: 253, isBookmark: true), in: []) == "Moment")
        let copy = MarkSource.allCases.flatMap { [$0.chip(), $0.short()] } + [Marks.confirmation(MarkConfirmation(at: 1, count: 2))]
        check("words: no exclamation points, em dashes, or time-bound words", copy.allSatisfy { s in
            !s.contains("!") && !s.contains("—") && !["currently", "soon", "latest", "just ", "simply"].contains { s.lowercased().contains($0) } })

        // Beside the recording.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("marks-check-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rec = dir.appendingPathComponent("Recording 2026-10-26 10.42.wav")
        check("file: the marker is hidden beside the recording", Marks.marker(for: rec).lastPathComponent == ".Recording 2026-10-26 10.42.marks")
        Marks.save(marks, for: rec)
        check("file: marks round-trip", Marks.load(for: rec) == marks)
        Marks.save([], for: rec)
        check("file: no marks, no file", !FileManager.default.fileExists(atPath: Marks.marker(for: rec).path) && Marks.load(for: rec).isEmpty)
        Marks.save(marks, for: rec)
        Marks.clear(rec)
        check("file: cleared on Stop", Marks.load(for: rec).isEmpty)
        try? FileManager.default.removeItem(at: dir)

        // Sync: a mark's source survives the transcript file.
        let enc = JSONEncoder(), dec = JSONDecoder()
        let saved = (try? enc.encode(notes)).flatMap { try? dec.decode([Note].self, from: $0) }
        check("sync: a mark's source and keys survive the file", saved == notes)
        let older = (try? dec.decode([Note].self, from: Data(#"[{"id":"\#(UUID().uuidString)","text":"Old","isBookmark":true,"createdAt":0}]"#.utf8))) ?? []
        check("sync: a note from an older build reads with no source", older.count == 1 && older[0].markSource == nil && !older[0].isMark)
    }
}

private extension Note {
    func marked(_ source: String, keys: String? = nil) -> Note {
        var n = self
        n.markSource = source
        n.markKeys = keys
        return n
    }
}
