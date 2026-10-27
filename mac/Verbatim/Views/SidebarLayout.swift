import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The sidebar's order and what it hides: drag a row to move it, right-click › Hide from sidebar, or Customize
// sidebar… for the whole list. Saved in UserDefaults ("sidebar.order", "sidebar.hidden"). Settings always shows
// and never moves, and at least one item always stays.

/// A main sidebar item. Raw values persist in "sidebar.order" and "sidebar.hidden"; never change them.
enum SidebarItemID: String, CaseIterable, Identifiable {
    case home, library, links, moments, queue, dictations, you, dictionary
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .links: return "Links"
        case .moments: return "Moments"
        case .queue: return "Queue"
        case .dictations: return "Dictations"
        case .you: return "You"
        case .dictionary: return "Dictionary"
        }
    }

    var art: BrandArt {
        switch self {
        case .home: return .iconHome
        case .library: return .iconLibrary
        case .links: return .iconLinks
        case .moments: return .iconMoments
        case .queue: return .iconQueue
        case .dictations: return .iconDictations
        case .you: return .iconAboutMe
        case .dictionary: return .iconDictionary
        }
    }
}

/// Pure rules for the saved order and hidden set, so the self-test can check them.
enum SidebarRules {
    /// "settings" is never part of the reorderable list and can never be hidden.
    static let pinned = "settings"

    /// The saved order with unknown items dropped, duplicates removed, and new items added at the end in their
    /// default order.
    static func merge(saved: [String], known: [String]) -> [String] {
        let knownSet = Set(known)
        var seen = Set<String>(), out: [String] = []
        for id in saved where knownSet.contains(id) && !seen.contains(id) { out.append(id); seen.insert(id) }
        for id in known where !seen.contains(id) { out.append(id); seen.insert(id) }
        return out
    }

    /// The saved hidden set with unknown items and Settings dropped. If it would hide everything, nothing is hidden.
    static func sanitizeHidden(_ saved: [String], known: [String]) -> Set<String> {
        var h = Set(saved).intersection(known)
        h.remove(pinned)
        if !known.isEmpty && h.count >= Set(known).count { h = [] }
        return h
    }

    /// Whether `id` can be hidden: a known item other than Settings, and not the last one showing.
    static func canHide(_ id: String, hidden: Set<String>, known: [String]) -> Bool {
        guard id != pinned, known.contains(id), !hidden.contains(id) else { return false }
        return known.filter { !hidden.contains($0) }.count > 1
    }

    /// `order` with `id` moved to where `target` is (before it when moving up, after it when moving down).
    static func move(_ id: String, to target: String, in order: [String]) -> [String] {
        guard id != target, let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return order }
        var o = order
        o.remove(at: from)
        o.insert(id, at: to)
        return o
    }
}

@MainActor
final class SidebarLayout: ObservableObject {
    static let shared = SidebarLayout()
    static let orderKey = "sidebar.order", hiddenKey = "sidebar.hidden"
    static let known = SidebarItemID.allCases.map(\.rawValue)

    @Published private(set) var order: [SidebarItemID]
    @Published private(set) var hidden: Set<SidebarItemID>
    /// The row being dragged, while a drag is in flight.
    @Published var dragging: SidebarItemID?

    private init() {
        let d = UserDefaults.standard
        order = SidebarRules.merge(saved: d.stringArray(forKey: Self.orderKey) ?? [], known: Self.known).compactMap(SidebarItemID.init(rawValue:))
        hidden = Set(SidebarRules.sanitizeHidden(d.stringArray(forKey: Self.hiddenKey) ?? [], known: Self.known).compactMap(SidebarItemID.init(rawValue:)))
    }

    var visible: [SidebarItemID] { order.filter { !hidden.contains($0) } }
    var isDefault: Bool { order == SidebarItemID.allCases && hidden.isEmpty }

    /// Position among the main items, for the direction screens slide.
    func index(_ id: SidebarItemID) -> Int { order.firstIndex(of: id) ?? 0 }

    func canHide(_ id: SidebarItemID) -> Bool {
        SidebarRules.canHide(id.rawValue, hidden: Set(hidden.map(\.rawValue)), known: Self.known)
    }

    func setHidden(_ id: SidebarItemID, _ hide: Bool) {
        if hide { guard canHide(id) else { return }; hidden.insert(id) } else { hidden.remove(id) }
        save()
    }

    func move(_ id: SidebarItemID, to target: SidebarItemID) {
        let o = SidebarRules.move(id.rawValue, to: target.rawValue, in: order.map(\.rawValue)).compactMap(SidebarItemID.init(rawValue:))
        guard o != order else { return }
        order = o
        save()
    }

    /// One step up (-1) or down (+1) in the full order, for the keyboard and VoiceOver.
    func nudge(_ id: SidebarItemID, by delta: Int) {
        guard let i = order.firstIndex(of: id) else { return }
        let j = i + delta
        guard order.indices.contains(j) else { return }
        move(id, to: order[j])
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        var o = order
        o.move(fromOffsets: fromOffsets, toOffset: toOffset)
        order = o
        save()
    }

    func restoreDefault() {
        order = SidebarItemID.allCases
        hidden = []
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(order.map(\.rawValue), forKey: Self.orderKey)
        d.set(hidden.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
    }

    /// The drag type for reordering rows. In-process only, so it never lands in another app or on a transcript
    /// drop target (which take text).
    static let dragType = UTType(exportedAs: "co.stumpandroot.verbatim.sidebar-item")

    func itemProvider(_ id: SidebarItemID) -> NSItemProvider {
        dragging = id
        let p = NSItemProvider()
        p.registerDataRepresentation(forTypeIdentifier: Self.dragType.identifier, visibility: .ownProcess) { done in
            done(Data(id.rawValue.utf8), nil)
            return nil
        }
        return p
    }
}

/// Moves the dragged row into a row's place as the pointer passes over it.
@MainActor
struct SidebarReorderDrop: DropDelegate {
    let target: SidebarItemID
    let layout: SidebarLayout
    let animation: Animation?

    func validateDrop(info: DropInfo) -> Bool { layout.dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let d = layout.dragging, d != target else { return }
        withAnimation(animation) { layout.move(d, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        layout.dragging = nil
        return true
    }
}

// MARK: - Customize sheet

/// Every main item with a show/hide switch and a drag handle, plus Restore default order.
struct CustomizeSidebarSheet: View {
    @ObservedObject private var layout = SidebarLayout.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sidebar").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                Text("Customize sidebar").font(Ink.serif(32)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Drag to change the order, and switch off what you don't use. Settings always stays at the bottom.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach(layout.order) { id in
                    row(id)
                }
                .onMove { from, to in
                    withAnimation(limitMotion ? nil : .spring(duration: 0.3, bounce: 0)) { layout.move(fromOffsets: from, toOffset: to) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(layout.order.count) * 40 + 8)
            .cardSurface(radius: Radius.tile)
            HStack {
                Button("Restore default order") {
                    withAnimation(limitMotion ? nil : .spring(duration: 0.3, bounce: 0)) { layout.restoreDefault() }
                }
                .buttonStyle(.pillLine())
                .disabled(layout.isDefault)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.pillDark())
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(Ink.paper)
        .tint(Ink.switchOn)
    }

    private func row(_ id: SidebarItemID) -> some View {
        let i = layout.index(id)
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.mute)
                .accessibilityHidden(true)
            IconGlyph(art: id.art, size: 17, color: layout.hidden.contains(id) ? Ink.faint : Ink.ink)
            Text(id.title).font(.system(size: 13.5)).foregroundStyle(layout.hidden.contains(id) ? Ink.mute : Ink.ink)
            Spacer(minLength: 8)
            // Keyboard: Tab to these, Space to press.
            Button { layout.nudge(id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(i == 0)
                .help("Move up").accessibilityLabel("Move \(id.title) up")
            Button { layout.nudge(id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(i == layout.order.count - 1)
                .help("Move down").accessibilityLabel("Move \(id.title) down")
            Toggle("Show \(id.title)", isOn: Binding(get: { !layout.hidden.contains(id) }, set: { layout.setHidden(id, !$0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!layout.hidden.contains(id) && !layout.canHide(id))
        }
        .frame(height: 32)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Ink.hairline)
    }
}
