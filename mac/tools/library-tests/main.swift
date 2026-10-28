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

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
