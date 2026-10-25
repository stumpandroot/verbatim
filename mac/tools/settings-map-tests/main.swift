import Foundation

// The Settings layouts (VerbatimPhone/PhoneSettingsMap.swift and Verbatim/Views/MacSettingsMap.swift) against the code that
// draws and searches them: every setting and every stored key sits in exactly one place, every search entry is in the
// layout with the right group and target, every page and pane exists, every root row and search entry has a row id to
// land on, old pane names still open their new panes, and every key is one the app really stores. Reads the Swift
// sources from the mac/ folder given as the first argument. Not part of any app target; run
// mac/tools/test-settings-map.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func read(_ path: String) -> String { (try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8)) ?? "" }

/// Every Swift file under the given folders, except the two maps.
func sources(_ dirs: [String]) -> String {
    var out = ""
    for d in dirs {
        let root = mac.appendingPathComponent(d)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
        for case let u as URL in e where u.pathExtension == "swift" && !u.lastPathComponent.hasSuffix("SettingsMap.swift") {
            out += ((try? String(contentsOf: u, encoding: .utf8)) ?? "") + "\n"
        }
    }
    return out
}

/// Every match of `pattern` in `text`, as its capture groups.
func matches(_ pattern: String, _ text: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
    }
}

func duplicates(_ xs: [String]) -> [String] {
    var seen = Set<String>(), dup = Set<String>()
    for x in xs { if !seen.insert(x).inserted { dup.insert(x) } }
    return dup.sorted()
}

let allSources = sources(["Verbatim", "VerbatimPhone", "VerbatimKeyboard", "VerbatimWidgets", "VerbatimShare"])
func storedSomewhere(_ key: String) -> Bool { allSources.contains("\"\(key)\"") }

// MARK: - iPhone

let phonePlacements = PhoneSettingsMap.placements
let phoneIDs = phonePlacements.map(\.setting.id)
let phoneKeys = phonePlacements.flatMap(\.setting.keys)
check("iPhone: seven groups, in the mockup's order", PhoneSettingsMap.groups.map(\.title) == [
    "Personalization and preferences", "Recording and transcription", "Dictation and keyboard", "Sync and storage",
    "Account and plan", "Support and feedback", "Features"], "\(PhoneSettingsMap.groups.map(\.title))")
check("iPhone: every setting appears exactly once", duplicates(phoneIDs).isEmpty, "\(duplicates(phoneIDs))")
check("iPhone: every stored key appears exactly once", duplicates(phoneKeys).isEmpty, "\(duplicates(phoneKeys))")
let phoneRows = PhoneSettingsMap.groups.flatMap(\.rows)
check("iPhone: every root row has its own id", duplicates(phoneRows.map(\.id)).isEmpty, "\(duplicates(phoneRows.map(\.id)))")
let badRootRows = phoneRows.filter { $0.page == nil && ($0.settings.count != 1 || $0.settings.first?.id != $0.id) }
check("iPhone: a row without a page is its one setting", badRootRows.isEmpty, "\(badRootRows.map(\.id))")
let rowIDClash = phoneRows.filter { $0.page != nil && phoneIDs.contains($0.id) }
check("iPhone: a row that opens a page doesn't share a setting's id", rowIDClash.isEmpty, "\(rowIDClash.map(\.id))")
let phoneMissingKeys = phoneKeys.filter { !storedSomewhere($0) }
check("iPhone: every key is one the app stores", phoneMissingKeys.isEmpty, "\(phoneMissingKeys)")

// The search index (SettingsSearch.swift): id, section, and target of each entry.
let search = read("VerbatimPhone/SettingsSearch.swift")
let groupConstants = ["personalization": PhoneSettingsMap.personalization, "recording": PhoneSettingsMap.recording,
                      "dictation": PhoneSettingsMap.dictation, "sync": PhoneSettingsMap.sync, "account": PhoneSettingsMap.account,
                      "support": PhoneSettingsMap.support, "features": PhoneSettingsMap.features]
struct PhoneEntry { var id: String; var section: String; var page: String? }
var phoneEntries: [PhoneEntry] = []
let entryStarts = matches(#"\.init\(id: "([A-Za-z]+)", section: ([A-Za-z]+),"#, search)
let chunks = search.components(separatedBy: ".init(id: \"").dropFirst()
for (start, chunk) in zip(entryStarts, chunks) {
    let body = chunk.components(separatedBy: "\n        .init(").first ?? chunk
    let page = matches(#"target: \.page\(\.([A-Za-z]+)\)"#, body).first?[1]
    phoneEntries.append(PhoneEntry(id: start[1], section: groupConstants[start[2]] ?? start[2], page: page))
}
check("iPhone: the search index was read", phoneEntries.count > 50, "\(phoneEntries.count) entries")
check("iPhone: search ids are unique", duplicates(phoneEntries.map(\.id)).isEmpty, "\(duplicates(phoneEntries.map(\.id)))")
let notInMap = phoneEntries.filter { !phoneIDs.contains($0.id) }.map(\.id)
check("iPhone: every search entry is in the layout", notInMap.isEmpty, "\(notInMap)")
let notSearchable = phoneIDs.filter { id in !phoneEntries.contains { $0.id == id } }
check("iPhone: every setting in the layout is searchable", notSearchable.isEmpty, "\(notSearchable)")
let wrongGroup = phoneEntries.filter { $0.section != PhoneSettingsMap.group(of: $0.id) }.map { "\($0.id): \($0.section)" }
check("iPhone: each search entry's section is its group", wrongGroup.isEmpty, "\(wrongGroup)")
let wrongTarget = phoneEntries.filter { $0.page != PhoneSettingsMap.page(of: $0.id) }.map { "\($0.id): \($0.page ?? "row")" }
check("iPhone: a setting on a page opens that page, one on the root flashes its row", wrongTarget.isEmpty, "\(wrongTarget)")

// Pages: every page in the layout is a SettingsSubpage, and the other way round.
let subpageCases = Set(matches(#"case ([a-zA-Z, ]+)\n"#, search.components(separatedBy: "enum SettingsSubpage").dropFirst().first?
    .components(separatedBy: "var title").first ?? "").flatMap { $0[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
let layoutPages = Set(phoneRows.compactMap(\.page))
check("iPhone: every page in the layout is a Settings subpage", layoutPages.isSubset(of: subpageCases), "\(layoutPages.subtracting(subpageCases).sorted())")
check("iPhone: every Settings subpage is in the layout", subpageCases.isSubset(of: layoutPages), "\(subpageCases.subtracting(layoutPages).sorted())")
let screen = read("VerbatimPhone/SettingsScreen.swift")
let noDestination = subpageCases.filter { !screen.contains("case .\($0):") }
check("iPhone: Settings has a destination for every page", noDestination.isEmpty, "\(noDestination.sorted())")

// Row ids: every root row, and every search entry that flashes a row, can be scrolled to.
let phoneSources = sources(["VerbatimPhone"])
func phoneTarget(_ id: String) -> Bool {
    phoneSources.contains("settingsSearchTarget(\"\(id)\"") || screen.contains("pageRow(\"\(id)\"") || screen.contains("actionRow(\"\(id)\"")
}
let rootRowsWithoutTarget = phoneRows.filter { !phoneTarget($0.id) }.map(\.id)
check("iPhone: every root row has its row id", rootRowsWithoutTarget.isEmpty, "\(rootRowsWithoutTarget)")
let rowEntriesWithoutTarget = phoneEntries.filter { $0.page == nil && !phoneTarget($0.id) }.map(\.id)
check("iPhone: every search entry on the root has a row to flash", rowEntriesWithoutTarget.isEmpty, "\(rowEntriesWithoutTarget)")
let hiddenRows = phoneRows.filter(\.hidden).map(\.id)
check("iPhone: no row waits off the root (Customize Home is on)", hiddenRows.isEmpty, "\(hiddenRows)")

// MARK: - Mac

let macIDs = MacSettingsMap.panes.flatMap { p in p.sections.flatMap { $0.settings.map(\.id) } }
let macKeys = MacSettingsMap.panes.flatMap { p in p.sections.flatMap { $0.settings.flatMap(\.keys) } }
check("Mac: every setting appears exactly once", duplicates(macIDs).isEmpty, "\(duplicates(macIDs))")
check("Mac: every stored key appears exactly once", duplicates(macKeys).isEmpty, "\(duplicates(macKeys))")
let macMissingKeys = macKeys.filter { !storedSomewhere($0) }
check("Mac: every key is one the app stores", macMissingKeys.isEmpty, "\(macMissingKeys)")
let sidebar = MacSettingsMap.panes.filter(\.inSidebar).map(\.title)
check("Mac: twelve panes in the sidebar, the seven groups among them", sidebar.count == 12 &&
      PhoneSettingsMap.groups.map(\.title).allSatisfy(sidebar.contains), "\(sidebar)")

// SettingsTab: each case's raw value, and the old raw values it still reads.
let kit = read("Verbatim/Views/SettingsKit.swift")
let tabRaw = Dictionary(matches(#"case \.([a-zA-Z]+): return "([a-zA-Z]+)""#, kit.components(separatedBy: "var rawValue: String {").dropFirst().first?
    .components(separatedBy: "init?(rawValue").first ?? "").map { ($0[1], $0[2]) }, uniquingKeysWith: { a, _ in a })
check("Mac: SettingsTab was read", tabRaw.count == MacSettingsMap.panes.count, "\(tabRaw)")
check("Mac: every pane is a SettingsTab", Set(tabRaw.values) == Set(MacSettingsMap.panes.map(\.raw)), "\(tabRaw.values.sorted())")
let decoder = kit.components(separatedBy: "init?(rawValue: String) {").dropFirst().first?.components(separatedBy: "default: return nil").first ?? ""
let oldRaw = ["general", "dictate", "floatingButton", "actions", "privacy", "transcription", "speakers", "captions", "meetings",
              "watched", "export", "storage", "about", "whatsNew"]
let lost = oldRaw.filter { !decoder.contains("\"\($0)\"") }
check("Mac: every old pane name still opens a pane", lost.isEmpty, "\(lost)")

// The index (SettingsKit.swift and TrustViews.swift): each entry's pane.
let index = kit + read("Verbatim/Views/TrustViews.swift")
let macEntries = matches(#"\.init\("([a-zA-Z.]+)", \.([a-zA-Z]+),"#, index).map { (id: $0[1], tab: $0[2]) }
check("Mac: the index was read", macEntries.count > 100, "\(macEntries.count) entries")
check("Mac: index ids are unique", duplicates(macEntries.map(\.id)).isEmpty, "\(duplicates(macEntries.map(\.id)))")
let macNotInMap = macEntries.filter { !macIDs.contains($0.id) }.map(\.id)
check("Mac: every index entry is in the layout", macNotInMap.isEmpty, "\(macNotInMap)")
let macNotSearchable = macIDs.filter { id in !macEntries.contains { $0.id == id } }
check("Mac: every setting in the layout is searchable", macNotSearchable.isEmpty, "\(macNotSearchable)")
let macWrongPane = macEntries.filter { tabRaw[$0.tab] != MacSettingsMap.pane(of: $0.id) }.map { "\($0.id): .\($0.tab)" }
check("Mac: each index entry's pane is its place in the layout", macWrongPane.isEmpty, "\(macWrongPane)")
let macSources = sources(["Verbatim"])
let unanchored = macIDs.filter { id in
    !macSources.contains("SettingsRow(\"\(id)\"") && !macSources.contains("SettingsToggleRow(\"\(id)\"") && !macSources.contains("settingsAnchor(\"\(id)\"")
}
check("Mac: every setting has a row a search result can scroll to", unanchored.isEmpty, "\(unanchored)")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
