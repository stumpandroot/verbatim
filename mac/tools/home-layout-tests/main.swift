import Foundation

// Edit Home's layout model (Verbatim/Model/HomeLayout.swift): the defaults that match each look's Home before Edit
// Home, the older settings carried over, decoding stored layouts (unknown sections and tiles ignored, missing ones
// added where they belong), the editor's moves, the four tiles, and the Mac's pairing. Not part of any app target;
// run mac/tools/test-home-layout.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

func names(_ items: [HomeLayout.Item]) -> [String] { items.map(\.section.rawValue) }
func json(_ s: String) -> Data { Data(s.utf8) }

// MARK: Defaults

let pv = HomeLayout.defaults(.phone, .verbose)
let pn = HomeLayout.defaults(.phone, .native)
let mv = HomeLayout.defaults(.mac, .verbose)
let mn = HomeLayout.defaults(.mac, .native)

check("iPhone Verbose style: Record, tiles, This week, Recent recordings, as before",
      names(pv.shown) == ["record", "tiles", "week", "recent"], "\(names(pv.shown))")
check("iPhone Verbose style: Record panel and tiles Large, This week a Compact strip",
      pv.size(.record) == .large && pv.size(.tiles) == .large && pv.size(.week) == .compact && pv.size(.recent) == .large)
check("iPhone Native: This week, tiles, Recent recordings; the Record section hidden",
      names(pn.shown) == ["week", "tiles", "recent"] && !pn.isVisible(.record), "\(names(pn.shown))")
check("iPhone Native: hidden Record keeps its place between This week and the tiles",
      names(pn.items).prefix(3) == ["week", "record", "tiles"])
check("iPhone Native: This week Large, tiles Compact", pn.size(.week) == .large && pn.size(.tiles) == .compact)
check("Mac Verbose style: Record and tiles, This week, Recent recordings and Last dictation",
      names(mv.shown) == ["record", "tiles", "week", "recent", "lastDictation"], "\(names(mv.shown))")
check("Mac Native: This week and Stats, tiles, Recent recordings; Record hidden",
      names(mn.shown) == ["week", "stats", "tiles", "recent"] && !mn.isVisible(.record), "\(names(mn.shown))")
check("new sections start hidden on both apps", [pv, pn, mv, mn].allSatisfy { l in
    [HomeSection.projects, .moments, .queue].allSatisfy { !l.isVisible($0) } })
check("Last dictation is new on iPhone, so it starts hidden there", !pv.isVisible(.lastDictation) && !pn.isVisible(.lastDictation))
check("every default lists each available section once", [(pv, HomePlatform.phone, HomeLook.verbose), (pn, .phone, .native), (mv, .mac, .verbose), (mn, .mac, .native)].allSatisfy { l, p, look in
    Set(l.items.map(\.section)) == Set(HomeSection.allCases.filter { $0.isAvailable(on: p, look: look) }) && l.items.count == Set(l.items.map(\.section)).count })
check("Stats is the Mac's, in Native only", !pv.items.contains { $0.section == .stats } && !pn.items.contains { $0.section == .stats }
      && !mv.items.contains { $0.section == .stats } && mn.isVisible(.stats))
check("iPhone tiles: Dictate, Import, What's playing, Live captions", pv.tiles == [.dictate, .importMedia, .whatsPlaying, .captions] && pn.tiles == pv.tiles)
check("Mac tiles: Dictate, Import, App audio, Live captions", mv.tiles == [.dictate, .importMedia, .appAudio, .captions] && mn.tiles == mv.tiles)
check("defaults are already normalized", [(pv, HomePlatform.phone, HomeLook.verbose), (pn, .phone, .native), (mv, .mac, .verbose), (mn, .mac, .native)].allSatisfy { l, p, look in l.normalized(p, look) == l })

// MARK: Platform-specific tiles and sections

check("What's playing is iPhone only", HomeTile.available(on: .phone).contains(.whatsPlaying) && !HomeTile.available(on: .mac).contains(.whatsPlaying))
check("App audio and the Thought pad are Mac only", HomeTile.available(on: .mac).contains(.appAudio) && HomeTile.available(on: .mac).contains(.thoughtPad)
      && !HomeTile.available(on: .phone).contains(.appAudio) && !HomeTile.available(on: .phone).contains(.thoughtPad))
check("each app offers at least eleven tiles", HomeTile.available(on: .phone).count >= 11 && HomeTile.available(on: .mac).count >= 11)
check("Stats is marked Mac only; other sections are on both", HomeSection.stats.platformOnly == .mac && HomeSection.allCases.filter { $0 != .stats }.allSatisfy { $0.platformOnly == nil })

// MARK: Older settings (migration)

let noWeek = HomeLayout.initial(.mac, .verbose, legacy: .init(showWeek: false))
check("Mac: Show This week on Home turned off carries over as a hidden This week", !noWeek.isVisible(.week) && names(noWeek.shown) == ["record", "tiles", "recent", "lastDictation"])
check("Mac: and in Native", !HomeLayout.initial(.mac, .native, legacy: .init(showWeek: false)).isVisible(.week))
check("Mac: the switch left on changes nothing", HomeLayout.initial(.mac, .verbose, legacy: .init(showWeek: true)) == mv)
let recordCard = HomeLayout.initial(.phone, .native, legacy: .init(nativeRecordCard: true))
check("iPhone Native: Show the Record card carries over, in its old place", names(recordCard.shown) == ["week", "record", "tiles", "recent"], "\(names(recordCard.shown))")
check("iPhone: the Record card setting doesn't touch Verbose style", HomeLayout.initial(.phone, .verbose, legacy: .init(nativeRecordCard: false)) == pv)
check("no older settings: the defaults", HomeLayout.initial(.phone, .native, legacy: .init()) == pn)

// MARK: Storage round trip and tolerant decoding

var edited = pv
edited.setVisible(.week, false)
edited.setSize(.recent, .compact)
edited.moveShown(fromOffsets: IndexSet(integer: 2), toOffset: 0)
edited.tiles = [.search, .dictate, .moments, .pasteLink]
let data = edited.encoded()
check("a layout encodes", data != nil)
check("and decodes to the same layout", data.flatMap { HomeLayout.decode($0, .phone, .verbose) } == edited)
check("the stored form carries version \(HomeLayout.currentVersion)", data.flatMap { try? JSONDecoder().decode(HomeLayout.Record.self, from: $0) }?.version == HomeLayout.currentVersion)
check("garbage isn't a layout", HomeLayout.decode(json("not json"), .phone, .verbose) == nil)
check("an empty record is the defaults", HomeLayout.decode(json("{}"), .mac, .native) == mn)

let unknown = json("""
{"version":1,"items":[{"section":"hologram","visible":true,"size":"large"},{"section":"recent","visible":true,"size":"huge"},
{"section":"record","visible":false,"size":"compact"},{"section":"recent","visible":false,"size":"compact"}],
"tiles":["teleport","search","search","dictate"]}
""")
let u = HomeLayout.decode(unknown, .phone, .verbose)
check("unknown sections are ignored", u.map { !$0.items.contains { $0.section.rawValue == "hologram" } } == true)
check("a section listed twice keeps its first entry", u?.items.filter { $0.section == .recent }.count == 1 && u?.isVisible(.recent) == true)
check("an unknown size falls back to the default size", u?.size(.recent) == .large)
check("stored visibility and size are kept", u.map { !$0.isVisible(.record) && $0.size(.record) == .compact } == true)
check("missing sections are added, each once", u.map { Set($0.items.map(\.section)) == Set(pv.items.map(\.section)) && $0.items.count == pv.items.count } == true)
check("unknown and repeated tiles are dropped, then filled to four from the defaults", u?.tiles == [.search, .dictate, .importMedia, .whatsPlaying], "\(u?.tiles.map(\.rawValue) ?? [])")

let otherApp = json(#"{"items":[{"section":"stats","visible":true,"size":"large"},{"section":"week","visible":true}],"tiles":["appAudio","thoughtPad","captions"]}"#)
let o = HomeLayout.decode(otherApp, .phone, .native)
check("a section the app doesn't offer (Stats on iPhone) is ignored", o.map { !$0.items.contains { $0.section == .stats } } == true)
check("a missing size or visibility takes the default", o?.size(.week) == .large && o?.isVisible(.week) == true)
check("tiles the app doesn't offer are dropped", o?.tiles == [.captions, .dictate, .importMedia, .whatsPlaying], "\(o?.tiles.map(\.rawValue) ?? [])")
check("Stats isn't offered in the Mac's Verbose style", HomeLayout.decode(otherApp, .mac, .verbose).map { !$0.items.contains { $0.section == .stats } } == true)

// A layout saved before Moments and Queue existed: they're added after their neighbors, hidden.
let older = json(#"{"items":[{"section":"recent","visible":true,"size":"large"},{"section":"record","visible":true,"size":"large"},{"section":"projects","visible":true,"size":"compact"}],"tiles":["dictate","import","whatsPlaying","captions"]}"#)
let old = HomeLayout.decode(older, .phone, .verbose)
check("a layout without a version decodes", old != nil)
check("its own order is kept", old.map { names($0.shown).starts(with: ["recent", "record"]) } == true, "\(old.map { names($0.items) } ?? [])")
check("new sections land after the section before them in the defaults", old.map { l in
    let n = names(l.items)
    guard let p = n.firstIndex(of: "projects"), let m = n.firstIndex(of: "moments"), let q = n.firstIndex(of: "queue"),
          let r = n.firstIndex(of: "record"), let t = n.firstIndex(of: "tiles") else { return false }
    return m == p + 1 && q == m + 1 && t == r + 1
} == true, "\(old.map { names($0.items) } ?? [])")
check("added sections take the defaults' visibility", old.map { !$0.isVisible(.moments) && !$0.isVisible(.queue) && $0.isVisible(.tiles) } == true)
let newer = json(#"{"version":9,"items":[{"section":"queue","visible":true,"size":"large","pinned":true}],"tiles":["dictate"],"accent":"blue"}"#)
let n = HomeLayout.decode(newer, .mac, .verbose)
check("a newer build's layout decodes what this build knows", n.map { $0.isVisible(.queue) && $0.size(.queue) == .large && $0.items.count == mv.items.count } == true)
check("a section missing at the front goes first", n.map { $0.items.first?.section == .record } == true, "\(n.map { names($0.items) } ?? [])")

// MARK: Editing

var e = pv
e.setVisible(.week, false)
check("hiding a section takes it off Home", names(e.shown) == ["record", "tiles", "recent"])
e.setVisible(.moments, true)
check("showing a section puts it at the end of Home", names(e.shown) == ["record", "tiles", "recent", "moments"])
e.setVisible(.week, true)
check("showing a hidden one again: also at the end", names(e.shown) == ["record", "tiles", "recent", "moments", "week"])
e.setVisible(.week, true)
check("showing a shown section changes nothing", names(e.shown) == ["record", "tiles", "recent", "moments", "week"])
var ip = pn
ip.setVisible(.record, true, inPlace: true)
check("a switch elsewhere shows a section where it sits (Appearance's Record card)", names(ip.shown) == ["week", "record", "tiles", "recent"])
var r = pv
r.moveShown(fromOffsets: IndexSet(integer: 0), toOffset: 2)
check("drag the first section below the second (List.onMove offsets)", names(r.shown) == ["tiles", "record", "week", "recent"], "\(names(r.shown))")
r.moveShown(fromOffsets: IndexSet(integer: 3), toOffset: 0)
check("drag the last section to the top", names(r.shown) == ["recent", "tiles", "record", "week"], "\(names(r.shown))")
r.moveShown(fromOffsets: IndexSet([0, 1]), toOffset: 4)
check("drag two sections to the end", names(r.shown) == ["record", "week", "recent", "tiles"], "\(names(r.shown))")
r.moveShown(fromOffsets: IndexSet(integer: 1), toOffset: 1)
check("dropping a section where it was changes nothing", names(r.shown) == ["record", "week", "recent", "tiles"])
check("moving keeps the hidden sections", Set(r.hidden.map(\.section)) == Set(pv.hidden.map(\.section)) && r.items.count == pv.items.count)
var m = mv
m.moveShown(.lastDictation, before: .record)
check("move a section before another", names(m.shown) == ["lastDictation", "record", "tiles", "week", "recent"])
m.moveShown(.lastDictation, before: nil)
check("move a section to the end", names(m.shown) == ["record", "tiles", "week", "recent", "lastDictation"])
var s = pn
s.setSize(.week, .compact)
check("change a section's size", s.size(.week) == .compact && s.size(.tiles) == .compact && names(s.shown) == names(pn.shown))

// MARK: Tiles

var picks = pv.tiles
picks = HomeLayout.toggle(.search, in: picks)
check("with four picked, another can't be added", picks == pv.tiles)
picks = HomeLayout.toggle(.whatsPlaying, in: picks)
check("tapping a picked tile takes it off", picks == [.dictate, .importMedia, .captions])
picks = HomeLayout.toggle(.search, in: picks)
check("an unpicked tile goes in the last slot", picks == [.dictate, .importMedia, .captions, .search])
picks = HomeLayout.move(.search, to: 0, in: picks)
check("dragging a slot reorders the picks", picks == [.search, .dictate, .importMedia, .captions])
picks = HomeLayout.move(.dictate, to: 9, in: picks)
check("a drag past the end lands in the last slot", picks == [.search, .importMedia, .captions, .dictate])
var short = pv
short.tiles = [.search]
check("a layout with fewer than four tiles is filled from the defaults", short.normalized(.phone, .verbose).tiles == [.search, .dictate, .importMedia, .whatsPlaying])

check("tile slots keep their place and skip missing picks", HomeTileSlot.slots([.search, .dictate, .moments], 2..<4) == [HomeTileSlot(slot: 2, tile: .moments)])

// MARK: The Mac's grid

func rowNames(_ rows: [HomeRow]) -> [[String]] { rows.map { names($0.items) } }
check("Mac Verbose style: Record beside the tiles, This week across, Recent recordings beside Last dictation",
      rowNames(HomeRows.rows(mv.shown, wide: true)) == [["record", "tiles"], ["week"], ["recent", "lastDictation"]], "\(rowNames(HomeRows.rows(mv.shown, wide: true)))")
check("Mac Native: This week beside Stats, the tiles across, Recent recordings across",
      rowNames(HomeRows.rows(mn.shown, wide: true)) == [["week", "stats"], ["tiles"], ["recent"]], "\(rowNames(HomeRows.rows(mn.shown, wide: true)))")
check("a narrow window stacks every section", HomeRows.rows(mv.shown, wide: false).allSatisfy { $0.items.count == 1 } && HomeRows.rows(mv.shown, wide: false).count == mv.shown.count)
var g = mv
g.setSize(.tiles, .compact)
check("a Compact section runs across the grid and breaks the pair", rowNames(HomeRows.rows(g.shown, wide: true)) == [["record"], ["tiles"], ["week"], ["recent", "lastDictation"]])
g.setVisible(.queue, true)
g.setSize(.queue, .large)
g.moveShown(.queue, before: .recent)
check("Queue never pairs", rowNames(HomeRows.rows(g.shown, wide: true)).contains(["queue"]) && rowNames(HomeRows.rows(g.shown, wide: true)).contains(["recent", "lastDictation"]))
check("rows are identified by their first section", HomeRows.rows(mv.shown, wide: true).map(\.id) == [.record, .week, .recent])

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
