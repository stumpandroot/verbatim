import Foundation

// The refined Library's quick filter chips (LibraryChip, Model/LibraryFilter.swift; DESIGN.md §6.8). Not part of any
// app target; run mac/tools/test-library.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

check("the chips are the mockup's seven, in its order",
      LibraryChip.allCases.map(\.label) == ["All", "Voice notes", "Meetings", "Thoughts", "Audio", "Links", "Marked"])
check("All filters by nothing", LibraryChip.all.source == .all && LibraryChip.all.kind == nil)
check("Voice notes, Links, and Marked are types",
      LibraryChip.voiceNotes.source == .voiceMemos && LibraryChip.links.source == .links && LibraryChip.marked.source == .marked
      && [LibraryChip.voiceNotes, .links, .marked].allSatisfy { $0.kind == nil })
check("Meetings, Thoughts, and Audio are kinds (Audio is Audio only)",
      LibraryChip.meetings.kind == .meeting && LibraryChip.thoughts.kind == .idea && LibraryChip.audio.kind == .audio
      && [LibraryChip.meetings, .thoughts, .audio].allSatisfy { $0.source == .all })
check("every chip names a different filter",
      Set(LibraryChip.allCases.map { "\($0.source.rawValue)|\($0.kind?.rawValue ?? "-")" }).count == LibraryChip.allCases.count)
check("each chip is the chip for its own filter",
      LibraryChip.allCases.allSatisfy { LibraryChip.matching(LibraryFilter(source: $0.source), kind: $0.kind) == $0 })
check("a platform within Links still shows Links", LibraryChip.matching(LibraryFilter(source: .links, platform: "YouTube"), kind: nil) == .links)
check("a filter the chips don't name has no chip", LibraryChip.matching(LibraryFilter(source: .videos), kind: nil) == nil
      && LibraryChip.matching(.all, kind: .journal) == nil && LibraryChip.matching(LibraryFilter(source: .voiceMemos), kind: .meeting) == nil)
check("its own chip names it", LibraryChip.otherLabel(.all, kind: .journal) == "Journal"
      && LibraryChip.otherLabel(LibraryFilter(source: .videos), kind: nil) == "Videos"
      && LibraryChip.otherLabel(LibraryFilter(source: .voiceMemos), kind: .meeting) == "Voice notes, Meetings")
check("a filter a chip names gets no extra chip", LibraryChip.allCases.allSatisfy { LibraryChip.otherLabel(LibraryFilter(source: $0.source), kind: $0.kind) == nil })
check("kinds have plurals for their chips", RecordingKind.allCases.allSatisfy { !$0.plural.isEmpty } && RecordingKind.idea.plural == "Thoughts"
      && RecordingKind.audio.plural == "Audio")
let labels = LibraryChip.allCases.map(\.label) + [LibraryChip.otherLabel(LibraryFilter(source: .appAudio), kind: .brainDump) ?? ""]
check("chip labels start with a capital and have no em dashes or exclamation points",
      labels.allSatisfy { $0.first?.isUppercase == true && !$0.contains("\u{2014}") && !$0.contains("!") })
check("only the first word of a chip is capitalized", LibraryChip.allCases.allSatisfy { $0.label.split(separator: " ").dropFirst().allSatisfy { $0.first?.isLowercase == true } })

// The Search or ask panel's Search results (Model/SearchPanel.swift, MAC-35): recordings by title, then lines.
func rec(_ title: String, _ lines: [String], status: Transcript.Status = .ready) -> Transcript {
    var t = Transcript(title: title, source: .voiceMemo, sourceLabel: "Voice memo", duration: 60, audioFileName: nil, model: "")
    t.segments = lines.enumerated().map { Segment(start: Double($0.offset * 5), end: Double($0.offset * 5 + 5), text: $0.element) }
    t.status = status
    return t
}
let walk = rec("Folding wagon walkthrough", ["This is the folding wagon.", "It folds flat for the truck.", "Nothing here."])
let call = rec("Catalog call", ["The catalog needs the Folding wagon.", "And the wheel line.", "folding again", "fólding with an accent", "folding five"])
let busy = rec("Folding notes", ["folding while it transcribes"], status: .processing)
let found = SearchPanelResults.find("folding", in: [walk, call, busy])
check("search panel: recordings are the title matches, in the list's order", found.recordings.map(\.title) == ["Folding wagon walkthrough", "Folding notes"])
check("search panel: lines come from ready recordings only, ignoring case and accents",
      found.passages.map(\.transcript.title) == ["Folding wagon walkthrough", "Catalog call"] && found.passages[1].count == 4)
check("search panel: at most three lines from one recording", found.passages.allSatisfy { $0.lines.count <= SearchPanelResults.perRecording }
      && found.passages[1].lines.count == 3)
check("search panel: the items walk the recordings, then the lines", found.items.count == 2 + 1 + 3
      && found.items.first == SearchPanelItem.recording(walk.id) && found.items[2] == SearchPanelItem.passage(transcript: walk.id, segment: walk.segments[0].id))
check("search panel: an item opens its recording, at its line for a passage", found.items[2].transcript == walk.id && found.items[2].segment == walk.segments[0].id
      && found.items[0].segment == nil)
check("search panel: one letter, or spaces, searches nothing", SearchPanelResults.find("f", in: [walk]).isEmpty && SearchPanelResults.find("  ", in: [walk]).isEmpty
      && !SearchPanelResults.searches(" f ") && SearchPanelResults.searches("fo"))
let many = (0..<9).map { rec("Folding \($0)", ["folding a", "folding b"]) }
let capped = SearchPanelResults.find("folding", in: many)
check("search panel: at most five recordings and eight lines", capped.recordings.count == SearchPanelResults.maxRecordings
      && capped.passages.reduce(0) { $0 + $1.lines.count } == SearchPanelResults.maxLines)
check("search panel: nothing matching is empty", SearchPanelResults.find("zebra", in: [walk, call]).isEmpty)

// Bulk changes (Model/BulkChange.swift): which transcripts Empty, the 30-day purge, and dictation retention take, so the
// Store can make each one change to the library.
let a = UUID(), b = UUID(), c = UUID()
check("bulk: ids keep their order, each once", BulkChange.unique([a, b, a, c, b]) == [a, b, c] && BulkChange.unique([UUID]()).isEmpty)
let twice = rec("Twice", [])
check("bulk: a transcript passed twice counts once", BulkChange.unique([twice, walk, twice]).map(\.id) == [twice.id, walk.id])
let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
func gone(_ title: String, daysAgo: Double?) -> Transcript {
    var t = rec(title, [])
    t.deletedAt = daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
    return t
}
let trashList = [gone("Old", daysAgo: 31), gone("Recent", daysAgo: 29), gone("Live", daysAgo: nil), gone("Just over", daysAgo: 30.01)]
check("bulk: the purge takes what's been in Recently Deleted more than 30 days, never a live one",
      BulkChange.expired(trashList, days: 30, now: now).map(\.title) == ["Old", "Just over"])
func dictation(_ title: String, daysAgo: Double, pinned: Bool = false) -> Transcript {
    var t = Transcript(title: title, source: .dictation, sourceLabel: "Dictation", duration: 5, audioFileName: nil, model: "")
    t.createdAt = now.addingTimeInterval(-daysAgo * 86_400)
    t.pinned = pinned
    return t
}
var memo = rec("Old memo", [])
memo.createdAt = now.addingTimeInterval(-90 * 86_400)
let history = [dictation("Old", daysAgo: 2), dictation("Today", daysAgo: 0.5), dictation("Pinned", daysAgo: 9, pinned: true), memo, dictation("Older", daysAgo: 40)]
check("bulk: retention takes dictations older than Keep dictations, in order, never pinned ones or recordings",
      BulkChange.oldDictations(history, keepDays: 1, now: now) == [history[0].id, history[4].id])
check("bulk: retention set to keep everything takes nothing", BulkChange.oldDictations(history, keepDays: 0, now: now).isEmpty)
check("bulk: a month's retention takes only the older one", BulkChange.oldDictations(history, keepDays: 30, now: now) == [history[4].id])

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
