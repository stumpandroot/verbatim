import Foundation

/// Apple Watch capture's rules (WatchTransfer.swift, WatchImport.swift), checked by the Linux tests
/// (`mac/tools/test-watch.sh`) and by the iPhone's self-test, which then receives a simulated watch file
/// (PhoneUITest.watchChecks). `check` logs PASS or FAIL.
enum WatchChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let started = Date(timeIntervalSince1970: 1_793_000_000)
        let marks = [WatchTransferMark(at: 252.4, createdAt: started.addingTimeInterval(252.4)),
                     WatchTransferMark(at: 707, createdAt: started.addingTimeInterval(707))]
        let thought = WatchTransfer(kind: .thought, startedAt: started, duration: 42.5, marks: marks)

        // What travels with the file.
        let meta = thought.metadata()
        check("watch: the metadata is a property list (Data under one key)", meta.count == 1 && meta[WatchTransfer.metadataKey] is Data
              && (try? PropertyListSerialization.data(fromPropertyList: meta, format: .binary, options: 0)) != nil)
        let back = WatchTransfer.from(metadata: meta)
        check("watch: the metadata reads back as the same transfer", back == thought)
        check("watch: kind, start, length, and marks survive the trip", back?.kind == .thought && back?.startedAt == started
              && back?.duration == 42.5 && back?.marks.map(\.at) == [252.4, 707])
        check("watch: a file without Verbose's metadata isn't one", WatchTransfer.from(metadata: nil) == nil
              && WatchTransfer.from(metadata: ["other": 1]) == nil && WatchTransfer.from(metadata: [WatchTransfer.metadataKey: Data("{".utf8)]) == nil)
        let newer = #"{"version":3,"id":"\#(thought.id.uuidString)","kind":"memo","startedAt":1793000000,"duration":12,"#
            + #""marks":[{"at":4,"createdAt":1793000004},{"at":"soon"},{"at":-2,"createdAt":1793000000}],"lens":"wide"}"#
        let fromNewer = WatchTransfer.from(metadata: [WatchTransfer.metadataKey: Data(newer.utf8)])
        check("watch: a newer watch's transfer still reads (unknown kind is a voice note, bad marks dropped, extra fields ignored)",
              fromNewer?.kind == .voiceNote && fromNewer?.marks.map(\.at) == [4] && fromNewer?.version == 3 && fromNewer?.duration == 12)
        check("watch: metadata sent as a JSON string also reads",
              WatchTransfer.from(metadata: [WatchTransfer.metadataKey: String(decoding: thought.encoded() ?? Data(), as: UTF8.self)]) == thought)

        // Marking on the watch.
        var m: [WatchTransferMark] = []
        var r = WatchRules.adding(252, to: m); m = r.marks
        check("watch: a mark confirms its time", m.count == 1 && r.confirmed == 252 && WatchRules.marked(r.confirmed) == "Marked 4:12")
        r = WatchRules.adding(254.5, to: m); m = r.marks
        check("watch: a second mark within 3 seconds confirms the first", m.count == 1 && r.confirmed == 252)
        r = WatchRules.adding(256, to: m); m = r.marks
        check("watch: 4 seconds later is a moment of its own", m.count == 2 && r.confirmed == 256)
        check("watch: the dedupe window and the confirmation match the iPhone's", WatchRules.dedupeWindow == Marks.dedupeWindow
              && WatchRules.confirmSeconds == Marks.confirmSeconds)
        check("watch: times read like the iPhone's", ([0, 59.9, 252, 3599, 3734, -4, Double.nan] as [Double]).allSatisfy { WatchRules.clock($0) == Marks.clock($0) })

        // The watch's words.
        check("watch: Today · 6 thoughts", WatchRules.todayLine(6) == "Today · 6 thoughts" && WatchRules.todayLine(1) == "Today · 1 thought"
              && WatchRules.todayLine(0) == "No thoughts today")
        check("watch: the complication says 6 thoughts today, then Tap to add one",
              WatchRules.complicationTitle(6) == "6 thoughts today" && WatchRules.complicationDetail == "Tap to add one")
        let note = WatchTransfer(kind: .voiceNote, startedAt: started, duration: 2465, marks: marks + [marks[0]])
        check("watch: the Sent line names the kind, length, and moments", WatchRules.sentLine(note) == "Voice note · 41:05 · 3 moments"
              && WatchRules.sentLine(WatchTransfer(kind: .thought, startedAt: started, duration: 42)) == "Thought · 0:42")
        check("watch: Sent says where it goes", WatchRules.sentDetail(.thought, reachable: true) == "Your iPhone transcribes it and adds it to today's Thoughts."
              && WatchRules.sentDetail(.voiceNote, reachable: false).hasPrefix("Your iPhone gets it when it's in reach"))
        check("watch: the waiting line counts recordings", WatchRules.waitingLine(0) == nil
              && WatchRules.waitingLine(1) == "1 recording waiting for your iPhone" && WatchRules.waitingLine(3) == "3 recordings waiting for your iPhone")
        let words = [WatchRules.todayLine(2), WatchRules.sentDetail(.thought, reachable: false), WatchRules.fullMessage, WatchRules.stoppedFullMessage,
                     WatchRules.micMessage, WatchRules.interruptedMessage, WatchRules.failedMessage, WatchRules.complicationDetail]
        check("watch: no exclamation points, em dashes, or filler in the watch's words",
              words.allSatisfy { w in !w.contains("!") && !w.contains("—") && !["just", "simply", "easily"].contains { w.lowercased().contains(" \($0) ") } })

        // Links from the complications.
        check("watch: the complications' links open the right recorder", WatchRules.kind(for: WatchRules.recordLink) == .voiceNote
              && WatchRules.kind(for: WatchRules.thoughtLink) == .thought && WatchRules.kind(for: URL(string: "verbatim://session?start=1")!) == nil)

        // Storage.
        check("watch: recording needs 50 MB free to start", WatchRules.canStart(freeBytes: 60_000_000) && !WatchRules.canStart(freeBytes: 40_000_000)
              && WatchRules.canStart(freeBytes: nil))
        check("watch: under 15 MB, recording stops and saves", WatchRules.mustStop(freeBytes: 10_000_000) && !WatchRules.mustStop(freeBytes: 20_000_000))

        // What the iPhone tells the watch.
        let ends = started.addingTimeInterval(3600)
        let ctx = WatchContext(thoughtsToday: 6, pageEnds: ends, lastTitle: String(repeating: "Errands after work ", count: 6), lastKind: "Thought",
                               lastDuration: 42, lastAt: started, sentAt: started)
        let dict = ctx.dictionary()
        check("watch: the context is a property list", (try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) != nil)
        let ctxBack = WatchContext(dictionary: dict)
        check("watch: the context reads back, with the title cut for the Smart Stack", ctxBack?.thoughtsToday == 6 && ctxBack?.pageEnds == ends
              && ctxBack?.lastTitle?.count == WatchContext.titleLimit && ctxBack?.lastKind == "Thought" && ctxBack?.lastDuration == 42)
        check("watch: the context survives the App Group", ctx.encoded().flatMap(WatchContext.decode)?.thoughtsToday == 6)
        check("watch: an empty context isn't one", WatchContext(dictionary: [:]) == nil)
        // The watch's haptics follow the iPhone's Settings › Haptics; an older iPhone's context leaves them on.
        var quiet = ctx
        quiet.haptics = false
        var older = dict
        older.removeValue(forKey: WatchContext.Key.haptics)
        check("watch: the iPhone's Haptics switch travels in the context, on when an older iPhone doesn't say",
              ctxBack?.haptics == true && WatchContext(dictionary: quiet.dictionary())?.haptics == false
              && quiet.encoded().flatMap(WatchContext.decode)?.haptics == false && WatchContext(dictionary: older)?.haptics == true)
        let now = started.addingTimeInterval(600)
        check("watch: today's count is the iPhone's plus unsent thoughts from today's page",
              WatchRules.thoughtsToday(context: ctx, unsent: [now, started.addingTimeInterval(-90_000)], now: now) == 7)
        check("watch: past the page's end, yesterday's count is dropped", WatchRules.thoughtsToday(context: ctx, unsent: [], now: ends.addingTimeInterval(1)) == 0)
        check("watch: the Smart Stack's line", WatchRules.lastLine(ctx, time: { _ in "9:58 AM" }) == "Thought · 0:42 · 9:58 AM")

        // What the iPhone makes of it.
        let p = WatchImport.plan(thought)
        check("watch import: a thought is a Thoughts recording you chose", p.kind == .idea && p.title == "Thought" && p.label == WatchImport.thoughtLabel)
        check("watch import: it lands on the day it started", p.createdAt == started)
        check("watch import: marks are moments from the Apple Watch", p.marks.count == 2 && p.marks.allSatisfy { $0.source == MarkSource.watch.rawValue }
              && p.notes.count == 2 && p.notes.allSatisfy { $0.isBookmark && $0.isMark && Marks.source($0) == .watch })
        check("watch import: the chip says from the Apple Watch", p.notes.first.flatMap(Marks.chip) == "Moment 4:12 · from the Apple Watch"
              && p.notes.first.flatMap(Marks.shortSource) == "Apple Watch")
        let v = WatchImport.plan(note)
        check("watch import: a voice note is a voice memo whose kind AutoLabel picks", v.kind == nil && v.title == "Voice memo" && v.label == WatchImport.voiceLabel)
        check("watch import: two marks within 3 seconds are one moment", v.notes.count == 2)
        var t = Transcript(title: p.title, source: .voiceMemo, sourceLabel: p.label, duration: 42.5, audioFileName: nil, model: "")
        t.kind = p.kind
        t.processingDeviceName = "Tim's iPhone"
        check("watch import: a thought from the watch says Apple Watch, not the iPhone that transcribed it", ThoughtText.origin(t) == "Apple Watch")
        check("watch import: it's known to be from the watch", WatchImport.isFromWatch(t))
        var phone = Transcript(title: "Thought", source: .voiceMemo, sourceLabel: "Thought · iPhone", duration: 3, audioFileName: nil, model: "")
        phone.kind = .idea
        check("watch import: a thought from the iPhone still says iPhone", ThoughtText.origin(phone) == "iPhone" && !WatchImport.isFromWatch(phone))
        var list: [String] = []
        for _ in 0..<3 { list = WatchImport.remembering(thought.id, in: list) }
        check("watch import: a transfer is remembered once", list == [thought.id.uuidString])
        for _ in 0..<(WatchImport.importedLimit + 5) { list = WatchImport.remembering(UUID(), in: list) }
        check("watch import: the remembered list stays bounded", list.count == WatchImport.importedLimit)

        // The context the iPhone sends.
        var meeting = Transcript(title: "Design review", source: .voiceMemo, sourceLabel: "Voice memo", duration: 2465, audioFileName: nil, model: "")
        meeting.kind = .meeting
        meeting.createdAt = started.addingTimeInterval(60)
        var dictation = Transcript(title: "Dictation", source: .dictation, sourceLabel: "Dictation", duration: 4, audioFileName: nil, model: "")
        dictation.createdAt = started.addingTimeInterval(120)
        t.createdAt = started
        let sent = WatchImport.context(today: [t], pageEnds: ends, live: [t, meeting, dictation], now: now)
        check("watch import: the context counts today's thoughts and names the newest recording, never a dictation",
              sent.thoughtsToday == 1 && sent.lastTitle == "Design review" && sent.lastKind == "Meeting" && sent.lastDuration == 2465 && sent.pageEnds == ends)
        check("watch import: the context carries the iPhone's Haptics switch",
              sent.haptics && !WatchImport.context(today: [t], pageEnds: ends, live: [t], now: now, haptics: false).haptics)
    }
}
