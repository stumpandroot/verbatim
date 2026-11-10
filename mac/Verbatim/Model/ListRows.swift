import Foundation

/// The rows of long lists, both apps, built from data so each row is exactly one view. A lazy stack or a List whose
/// ForEach gives some elements two views (a hairline and a row, a day's title and its rows) or none makes SwiftUI build
/// every element to count them, so a long list stalls the screen (the November 10, 2026 freeze audit; the transcript's
/// lines have their own rows, `ReadingRows`).
enum ListRows {
    /// A row in a card, with whether it draws the hairline above it.
    struct Divided<Element, ID: Hashable>: Identifiable {
        let element: Element
        let id: ID
        /// Every row but the card's first.
        let divider: Bool
    }

    /// One card's rows from several runs in order (the queue's running file, then what's importing, then what waits):
    /// each item once, the first time it appears, and a hairline above every row but the first.
    static func divided<Element, ID: Hashable>(_ runs: [[Element]], id: (Element) -> ID) -> [Divided<Element, ID>] {
        var seen = Set<ID>()
        var out: [Divided<Element, ID>] = []
        out.reserveCapacity(runs.reduce(0) { $0 + $1.count })
        for run in runs {
            for e in run {
                let key = id(e)
                guard seen.insert(key).inserted else { continue }
                out.append(Divided(element: e, id: key, divider: !out.isEmpty))
            }
        }
        return out
    }

    /// Consecutive items with the same key, grouped in order (a list sorted by date, grouped by day).
    static func runs<Element, Key: Equatable>(_ items: [Element], key: (Element) -> Key) -> [(key: Key, items: [Element])] {
        var out: [(key: Key, items: [Element])] = []
        for e in items {
            let k = key(e)
            if let last = out.indices.last, out[last].key == k { out[last].items.append(e) } else { out.append((k, [e])) }
        }
        return out
    }

    /// A grouped list's row: a group's title, or one of its items, which knows whether it's its card's first or last.
    struct Grouped<Title: Hashable, Element>: Identifiable {
        enum Kind {
            case title(Title)
            case item(Element, first: Bool, last: Bool)
        }
        /// The title's own key, or the item's id.
        let id: AnyHashable
        let kind: Kind
    }

    private enum Key<T: Hashable, I: Hashable>: Hashable { case title(T), item(I) }

    /// Each group's title (when it has one) and then its items, as one list of rows. Empty groups are left out.
    static func grouped<Title: Hashable, Element, ID: Hashable>(_ groups: [(title: Title?, items: [Element])],
                                                                 id: (Element) -> ID) -> [Grouped<Title, Element>] {
        var out: [Grouped<Title, Element>] = []
        out.reserveCapacity(groups.reduce(0) { $0 + $1.items.count + 1 })
        for g in groups where !g.items.isEmpty {
            if let title = g.title { out.append(Grouped(id: AnyHashable(Key<Title, ID>.title(title)), kind: .title(title))) }
            let n = g.items.count
            for (i, e) in g.items.enumerated() {
                out.append(Grouped(id: AnyHashable(Key<Title, ID>.item(id(e))), kind: .item(e, first: i == 0, last: i == n - 1)))
            }
        }
        return out
    }

    /// The items' ids in order as one number: what an animation or `onChange` watches, so a render compares an Int,
    /// not an array the size of the list.
    static func fingerprint<C: Collection, ID: Hashable>(_ items: C, id: (C.Element) -> ID) -> Int {
        var h = Hasher()
        h.combine(items.count)
        for e in items { h.combine(id(e)) }
        return h.finalize()
    }
}

/// The last value a view worked out and what it was worked out from, for work over data the Store's library memo
/// doesn't key (the Dictionary): a render with the same key gets the same value back. `Key` must name everything the
/// value depends on; arrays that haven't changed compare at once, as they share storage.
final class LastValue<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?
    /// How many times the value was worked out (the tests).
    private(set) var made = 0

    init() {}

    func value(for key: Key, _ make: () -> Value) -> Value {
        if let k = self.key, k == key, let v = value { return v }
        let v = make()
        made += 1
        self.key = key
        value = v
        return v
    }
}
