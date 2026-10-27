import SwiftUI
import AppKit

// brand: web style
//
// Edit Home on the Mac (mockup "premium", section 03, Mac): a list of Home's sections with a checkbox to show each,
// a drag to reorder, and Compact or Large; the Tiles row opens the tile picker. Changes reach Home at once and
// are kept per look in this Mac's defaults (HomeLayout.swift).
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
    @Environment(\.look) private var look
    @State private var localPicking = false
    @State private var confirmReset = false
    /// Whether the inspector is on screen, for the self-test.
    static var visible = false

    init(onDone: (() -> Void)? = nil) { self.onDone = onDone }

    private var hl: HomeLook { look.homeLook }
    private var inspector: Bool { onDone != nil }
    /// The inspector's picker follows the shared session (the self-test opens it); Settings keeps its own.
    private var picking: Binding<Bool> { inspector ? $session.pickingTiles : $localPicking }

    var body: some View {
        let layout = store.layout(hl)
        VStack(alignment: .leading, spacing: 12) {
            if inspector { header }
            Text("Check to show. Drag to reorder. Size sets Compact or Large.")
                .font(.system(size: 13)).foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.dim))
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(layout.shown, id: \.section) { item in row(item, layout: layout) }
                    .onMove { from, to in store.update(hl) { $0.moveShown(fromOffsets: from, toOffset: to) } }
                ForEach(layout.hidden, id: \.section) { item in row(item, layout: layout) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(layout.items.count) * 38 + 6)
            HStack(spacing: 10) {
                PillButton(title: "Reset", kind: .line, size: .mini, hint: "Puts Home back the way this look started.") { confirmReset = true }
                    .uiTarget("home-edit-reset")
                if let onDone {
                    PillButton(title: "Done", kind: .dark, size: .mini, hint: "Stops editing Home.") { onDone() }
                        .uiTarget("home-edit-done")
                }
                Spacer(minLength: 0)
            }
            if inspector { Spacer(minLength: 0) }
        }
        .padding(inspector ? 20 : 0)
        .frame(maxHeight: inspector ? .infinity : nil, alignment: .top)
        .background { if inspector { chrome } }
        .confirmationDialog("Put Home back the way it started?", isPresented: $confirmReset) {
            Button("Reset Home", role: .destructive) { store.reset(hl) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every section and tile goes back to how this look began. The other look keeps its layout.")
        }
        .onAppear { if inspector { Self.visible = true } }
        .onDisappear { if inspector { Self.visible = false; session.pickingTiles = false } }
    }

    // MARK: Pieces

    @ViewBuilder private var header: some View {
        if look == .native {
            Text("Home Sections").font(.system(size: 17, weight: .bold))   // brand: native
                .accessibilityAddTraits(.isHeader)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Editing")
                WebText.serif("Home", italic: "sections", size: 28).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder private var chrome: some View {
        let shape = RoundedRectangle(cornerRadius: look == .native ? 18 : Radius.record, style: .continuous)
        if look == .native {
            Color.clear.premiumCard(radius: 18)
        } else {
            shape.fill(Ink.card).inkEdge(outline: true, shadow: CGSize(width: 6, height: 7), radius: Radius.record)
        }
    }

    private func row(_ item: HomeLayout.Item, layout: HomeLayout) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(look == .native ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Ink.mute))
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { item.visible },
                                 set: { on in store.update(hl) { $0.setVisible(item.section, on) } })) {
                Text(item.section.title).font(.system(size: 13.5)).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .layoutPriority(1)
            .accessibilityHint(item.visible ? "Hides it from Home." : "Shows it at the end of Home.")
            if item.section == .tiles {
                // A line mini pill (Native: a small bordered button), never a system link (review M-02).
                Button("Choose tiles") { picking.wrappedValue = true }
                    .buttonStyle(PillButtonStyle(kind: .line, size: .mini))
                    .popover(isPresented: picking, arrowEdge: .leading) { HomeTilePickerMac(look: hl) }
                    .help(layout.tiles.map(\.title).joined(separator: ", "))
                    .accessibilityValue(layout.tiles.map(\.title).joined(separator: ", "))
            }
            Spacer(minLength: 6)
            // A borderless menu, narrower than a pop-up button, so the section's name keeps its room.
            Menu {
                ForEach(HomeCardSize.allCases, id: \.self) { s in
                    Button { store.update(hl) { $0.setSize(item.section, s) } } label: {
                        if s == item.size { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            } label: {
                Text(item.size.title).font(.system(size: 12.5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.dim))
            .accessibilityLabel("\(item.section.title) size")
            .accessibilityValue(item.size.title)
        }
        .frame(height: 30)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2))
    }
}

// MARK: - Tile picker

/// Choose four tiles: click to pick (numbered in order) or to take one off; drag a picked tile onto another to swap
/// their places. Saved as soon as four are picked.
struct HomeTilePickerMac: View {
    let homeLook: HomeLook
    @Environment(\.look) private var look
    @State private var picks: [HomeTile]
    /// Whether the picker is open, for the self-test.
    static var visible = false

    init(look: HomeLook) {
        homeLook = look
        _picks = State(initialValue: HomeLayoutStore.shared.layout(look).tiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if look == .native {
                Text("Tiles").font(.system(size: 14, weight: .bold))   // brand: native
            } else {
                Eyebrow(text: "Tiles")
                WebText.serif("Choose", italic: "four", size: 24).foregroundStyle(Ink.ink)
            }
            Text(picks.count == HomeLayout.tileCount ? "Choose four. Drag to reorder." : "Pick \(HomeLayout.tileCount - picks.count) more.")
                .font(.system(size: 12.5)).foregroundStyle(look == .native ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.dim))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 8), count: 3), spacing: 8) {
                ForEach(HomeTile.available(on: .mac), id: \.self) { cell($0) }
            }
        }
        .padding(16)
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    private func commit() {
        guard picks.count == HomeLayout.tileCount else { return }
        HomeLayoutStore.shared.update(homeLook) { $0.tiles = picks }
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
        let shape = RoundedRectangle(cornerRadius: look == .native ? 12 : Radius.tile, style: .continuous)
        let fill = slot.flatMap(HomeView.tileFill)
        let on = look == .native ? Color.primary : (slot != nil && fill != nil ? Ink.inkFixed : Ink.ink)
        return VStack(alignment: look == .native ? .center : .leading, spacing: 4) {
            if look == .native {
                Image(systemName: t.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(PremiumInk.accentText)   // brand: native
            } else {
                IconGlyph(art: t.art, size: 16, color: on)
            }
            Text(t.title).font(look == .native ? .system(size: 12, weight: .semibold) : Ink.serif(15))
                .foregroundStyle(on).lineLimit(2).minimumScaleFactor(0.85)
                .multilineTextAlignment(look == .native ? .center : .leading)
        }
        .padding(8)
        .frame(width: 100, height: 64, alignment: look == .native ? .center : .topLeading)
        .background {
            if look == .native {
                shape.fill(slot != nil ? PremiumInk.accentSoft : PremiumInk.fill)
            } else if slot != nil, let fill {
                shape.fill(fill)
            } else {
                shape.fill(Ink.card)
            }
        }
        .overlay {
            if look == .native {
                if slot != nil { shape.strokeBorder(Ink.nativeAccent, lineWidth: 1.5) }
            } else {
                shape.strokeBorder(slot != nil ? Ink.ink : Ink.hairline, lineWidth: slot != nil ? 1.5 : 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let slot {
                Text("\(slot + 1)").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(look == .native ? Color.white : Ink.paper)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(look == .native ? Ink.nativeAccent : Ink.ink))
                    .padding(5)
            }
        }
        .contentShape(shape)
    }
}
