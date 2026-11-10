import Foundation

// The long lists' rows (ListRows.swift): each row one view, built from data.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) \(detail)") }
}

struct Item: Equatable { let id: Int; let day: Int }

// A card's rows: a hairline above every row but the first, each item once.
do {
    let running = [Item(id: 1, day: 0)], importing = [Item(id: 2, day: 0), Item(id: 3, day: 0)], waiting = [Item(id: 4, day: 0), Item(id: 2, day: 0)]
    let rows = ListRows.divided([running, importing, waiting], id: \.id)
    check("divided: runs in order, each item once", rows.map(\.id) == [1, 2, 3, 4], "\(rows.map(\.id))")
    check("divided: a hairline above every row but the first", rows.map(\.divider) == [false, true, true, true])
    let noRunning = ListRows.divided([[], importing, waiting], id: \.id)
    check("divided: with nothing running, the first importing row has no hairline", noRunning.first?.id == 2 && noRunning.first?.divider == false
          && noRunning.dropFirst().allSatisfy(\.divider))
    check("divided: nothing gives no rows", ListRows.divided([[Item](), []], id: \.id).isEmpty)
    let one = ListRows.divided([[Item(id: 9, day: 0)]], id: \.id)
    check("divided: one row, no hairline", one.count == 1 && !one[0].divider && one[0].element == Item(id: 9, day: 0))
}

// Consecutive runs by key (days of a list sorted newest first).
do {
    let items = [Item(id: 1, day: 5), Item(id: 2, day: 5), Item(id: 3, day: 4), Item(id: 4, day: 2), Item(id: 5, day: 2)]
    let groups = ListRows.runs(items, key: \.day)
    check("runs: one group per day, in order", groups.map(\.key) == [5, 4, 2], "\(groups.map(\.key))")
    check("runs: items keep their order", groups.map { $0.items.map(\.id) } == [[1, 2], [3], [4, 5]])
    check("runs: nothing gives no groups", ListRows.runs([Item](), key: \.day).isEmpty)
    // The same as grouping by day and sorting the days newest first, for a list sorted newest first.
    let byDict = Dictionary(grouping: items, by: \.day)
    check("runs: matches grouping and sorting the days", byDict.keys.sorted(by: >) == groups.map(\.key)
          && byDict.keys.sorted(by: >).map { byDict[$0]!.map(\.id) } == groups.map { $0.items.map(\.id) })
}

// Day groups as one list of rows.
do {
    let groups: [(title: String?, items: [Item])] = [("Today", [Item(id: 1, day: 0), Item(id: 2, day: 0)]), ("Monday", []),
                                                     ("Sunday", [Item(id: 3, day: 0)])]
    let rows = ListRows.grouped(groups, id: \.id)
    func describe(_ r: ListRows.Grouped<String, Item>) -> String {
        switch r.kind {
        case .title(let t): return "title \(t)"
        case .item(let e, let first, let last): return "item \(e.id)\(first ? " first" : "")\(last ? " last" : "")"
        }
    }
    check("grouped: a title, then its items with first and last", rows.map(describe) == ["title Today", "item 1 first", "item 2 last", "title Sunday", "item 3 first last"],
          "\(rows.map(describe))")
    check("grouped: an empty group adds nothing, not even its title", !rows.map(describe).contains("title Monday"))
    check("grouped: every row's id is different", Set(rows.map(\.id)).count == rows.count)
    let untitled = ListRows.grouped([(title: String?.none, items: [Item(id: 1, day: 0), Item(id: 2, day: 0)])], id: \.id)
    check("grouped: an untitled group is only its items", untitled.map(describe) == ["item 1 first", "item 2 last"])
    // A title that reads like an item's id still gets a key of its own.
    let clash = ListRows.grouped([(title: Int?.some(1), items: [Item(id: 1, day: 0)])], id: \.id)
    check("grouped: a title and an item never share an id", clash.count == 2 && clash[0].id != clash[1].id)
    let dates = ListRows.grouped([(title: Date?.some(Date(timeIntervalSince1970: 0)), items: [Item(id: 7, day: 0)])], id: \.id)
    check("grouped: dates work as titles", dates.count == 2)
}

// The ids' fingerprint.
do {
    let a = [1, 2, 3], b = [1, 3, 2]
    check("fingerprint: the same ids give the same number", ListRows.fingerprint(a, id: { $0 }) == ListRows.fingerprint([1, 2, 3], id: { $0 }))
    check("fingerprint: another order gives another number", ListRows.fingerprint(a, id: { $0 }) != ListRows.fingerprint(b, id: { $0 }))
    check("fingerprint: one more id gives another number", ListRows.fingerprint(a, id: { $0 }) != ListRows.fingerprint([1, 2, 3, 4], id: { $0 }))
    check("fingerprint: empty differs from one item", ListRows.fingerprint([Int](), id: { $0 }) != ListRows.fingerprint([0], id: { $0 }))
}

// A view's last value: worked out again only when the key changes.
do {
    struct Key: Equatable { var list: [String]; var query: String }
    let cache = LastValue<Key, [String]>()
    var list = (0..<1_000).map { "word \($0)" }
    func shown(_ q: String) -> [String] { cache.value(for: Key(list: list, query: q)) { list.filter { $0.contains(q) } } }
    let first = shown("9")
    _ = shown("9"); _ = shown("9")
    check("last value: the same key works it out once", cache.made == 1 && first == shown("9"))
    _ = shown("99")
    check("last value: a new key works it out again", cache.made == 2 && shown("99").allSatisfy { $0.contains("99") })
    list.append("word 9999")
    let again = shown("99")
    check("last value: a changed list works it out again", cache.made == 3 && again.last == "word 9999")
    let started = Date()
    for _ in 0..<10_000 { _ = shown("99") }
    check("last value: 10,000 renders with an unchanged 1,000-word list in well under a second",
          cache.made == 3 && Date().timeIntervalSince(started) < 0.5, "\(Date().timeIntervalSince(started))")
}

// Big lists stay fast.
do {
    let many = (0..<20_000).map { Item(id: $0, day: $0 / 40) }
    let started = Date()
    let card = ListRows.divided([many], id: \.id)
    let days = ListRows.grouped(ListRows.runs(many, key: \.day).map { (title: Int?.some($0.key), items: $0.items) }, id: \.id)
    let fp = ListRows.fingerprint(many, id: \.id)
    check("big: 20,000 rows in well under a second", card.count == 20_000 && days.count == 20_000 + 500 && fp != 0
          && Date().timeIntervalSince(started) < 0.5, "\(Date().timeIntervalSince(started))")
}

if failures > 0 { print("\(failures) list row check(s) failed"); exit(1) }
print("All list row checks passed.")
