import SwiftUI
import AppKit

// Edit Home on the Mac (mockup "premium", section 03, Mac): a list of Home's sections with a checkbox to show each,
// a drag to reorder, and Compact or Large; the Tiles row opens the tile picker. Changes reach Home at once and
// are kept in this Mac's defaults (HomeLayout.swift). On the refined kit (DESIGN.md §13).
//
// Two ways in: Edit Home at the end of Home outlines the sections and shows this list as an inspector on the right,
// with Reset and Done; Settings › Personalization › Customize Home shows the same list (no Done).

/// Whether Home is being edited, shared by Home, its inspector, and the self-test.
@MainActor
final class HomeEditSession: ObservableObject {
    static let shared = HomeEditSession()
    @Published var editing = false
    /// The inspector's tile picker (the self-test opens it too).
    @Published var pickingTiles = false
}

struct EditHomeView: View {
    /// Done, in Home's inspector. Nil in Settings.
    var onDone: (() -> Void)? = nil
    @ObservedObject private var store = HomeLayoutStore.shared
    @ObservedObject private var session = HomeEditSession.shared
    @State private var localPicking = false
    @State private var confirmReset = false
    /// Whether the inspector is on screen, for the self-test.
    static var visible = false

    init(onDone: (() -> Void)? = nil) { self.onDone = onDone }

    private var inspector: Bool { onDone != nil }
    /// The inspector's picker follows the shared session (the self-test opens it); Settings keeps its own.
    private var picking: Binding<Bool> { inspector ? $session.pickingTiles : $localPicking }

    var body: some View {
        let layout = store.layout
        VStack(alignment: .leading, spacing: 12) {
            if inspector {
                Text("Home sections").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("Check to show. Drag to reorder. Size sets Compact or Large.")
                .refinedFont(.meta).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(layout.shown, id: \.section) { item in row(item, layout: layout) }
                    .onMove { from, to in store.update { $0.moveShown(fromOffsets: from, toOffset: to) } }
                ForEach(layout.hidden, id: \.section) { item in row(item, layout: layout) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(layout.items.count) * 38 + 6)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            HStack(spacing: 10) {
                Button("Reset") { confirmReset = true }
                    .buttonStyle(RefinedActionStyle(kind: .quiet))
                    .help("Puts Home back the way it started.")
                    .uiTarget("home-edit-reset")
                if let onDone {
                    Button("Done") { onDone() }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Stops editing Home.")
                        .uiTarget("home-edit-done")
                }
                Spacer(minLength: 0)
            }
            if inspector { Spacer(minLength: 0) }
        }
        .padding(inspector ? 20 : 0)
        .frame(maxHeight: inspector ? .infinity : nil, alignment: .top)
        .background { if inspector { Refined.paper } }
        .confirmationDialog("Put Home back the way it started?", isPresented: $confirmReset) {
            Button("Reset Home", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every section and tile goes back to how Home began.")
        }
        .onAppear { if inspector { Self.visible = true } }
        .onDisappear { if inspector { Self.visible = false; session.pickingTiles = false } }
    }

    // MARK: Pieces

    private func row(_ item: HomeLayout.Item, layout: HomeLayout) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Refined.faint)
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { item.visible },
                                 set: { on in store.update { $0.setVisible(item.section, on) } })) {
                Text(item.section.title).refinedFont(.rowTitle).foregroundStyle(Refined.ink).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .tint(Refined.accentText)
            .layoutPriority(1)
            .accessibilityHint(item.visible ? "Hides it from Home." : "Shows it at the end of Home.")
            if item.section == .tiles {
                Button("Choose tiles") { picking.wrappedValue = true }
                    .buttonStyle(RefinedActionStyle(kind: .quiet))
                    .controlSize(.small)
                    .popover(isPresented: picking, arrowEdge: .leading) { HomeTilePickerMac() }
                    .help(layout.tiles.map(\.title).joined(separator: ", "))
                    .accessibilityValue(layout.tiles.map(\.title).joined(separator: ", "))
            }
            Spacer(minLength: 6)
            // A borderless menu, narrower than a pop-up button, so the section's name keeps its room.
            Menu {
                ForEach(HomeCardSize.allCases, id: \.self) { s in
                    Button { store.update { $0.setSize(item.section, s) } } label: {
                        if s == item.size { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }   // brand: system surface
                    }
                }
            } label: {
                Text(item.size.title).refinedFont(.meta)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Refined.dim)
            .accessibilityLabel("\(item.section.title) size")
            .accessibilityValue(item.size.title)
        }
        .frame(height: 30)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Refined.separator)
        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
    }
}

// MARK: - Tile picker

/// Choose four tiles: click to pick (numbered in order) or to take one off; drag a picked tile onto another to swap
/// their places. Saved as soon as four are picked. Picked tiles take the colors Home gives them
/// (`HomeTile.refinedHues`).
struct HomeTilePickerMac: View {
    @State private var picks: [HomeTile]
    /// Whether the picker is open, for the self-test.
    static var visible = false

    init() {
        _picks = State(initialValue: HomeLayoutStore.shared.layout.tiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tiles").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).accessibilityAddTraits(.isHeader)
            Text(picks.count == HomeLayout.tileCount ? "Choose four. Drag to reorder." : "Pick \(HomeLayout.tileCount - picks.count) more.")
                .refinedFont(.meta).foregroundStyle(Refined.dim)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 8), count: 3), spacing: 8) {
                ForEach(HomeTile.available(on: .mac), id: \.self) { cell($0) }
            }
        }
        .padding(16)
        .background(Refined.paper)
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    private func commit() {
        guard picks.count == HomeLayout.tileCount else { return }
        HomeLayoutStore.shared.update { $0.tiles = picks }
    }

    private func cell(_ t: HomeTile) -> some View {
        let n = picks.firstIndex(of: t)
        return Button {
            picks = HomeLayout.toggle(t, in: picks)
            commit()
        } label: {
            face(t, slot: n)
        }
        .buttonStyle(.plain)
        .draggable(t.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let n, let raw = items.first, let dragged = HomeTile(rawValue: raw), picks.contains(dragged) else { return false }
            picks = HomeLayout.move(dragged, to: n, in: picks)
            commit()
            return true
        }
        .accessibilityLabel(t.title)
        .accessibilityValue(n.map { "Tile \($0 + 1)" } ?? "Not picked")
    }

    private func face(_ t: HomeTile, slot: Int?) -> some View {
        let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.tile), style: .continuous)
        let hue: RefinedHue? = slot.map { HomeTile.refinedHues(picks)[$0] }
        let fill = hue.map { Refined.badge($0) } ?? Refined.neutral
        let on = hue.map { Refined.onBadge($0) } ?? Refined.ink
        return VStack(alignment: .leading, spacing: 4) {
            IconGlyph(art: t.art, size: 16, color: on)
            Text(t.title).refinedFont(.meta, weight: .semibold)
                .foregroundStyle(on).lineLimit(2).minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
        }
        .padding(8)
        .frame(width: 100, height: 64, alignment: .topLeading)
        .background(shape.fill(fill))
        .overlay { if slot != nil { shape.strokeBorder(Refined.accentText, lineWidth: 1.5) } }
        .overlay(alignment: .topTrailing) {
            if let slot {
                Text("\(slot + 1)").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Refined.paper)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Refined.accentText))
                    .padding(5)
            }
        }
        .contentShape(shape)
    }
}
