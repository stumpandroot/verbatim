import SwiftUI

/// Edit Home (mockup "premium", section 03): Home's sections in a list you drag to reorder, each with Compact or Large
/// and a control to show or hide it, and the four shortcut tiles (HomeTilePicker). Changes reach Home at once and are
/// kept on this iPhone (HomeLayout.swift). One refined design in both look settings (DESIGN.md §13): the large serif
/// title, the sections in cards, and the accent's checks.
///
/// Two ways in: the Edit Home button at the end of Home presents it in a sheet with Reset and Done (`onDone`), and
/// Settings › Personalization › Customize Home pushes it (no `onDone`: Back closes it, Reset sits on the right).
struct EditHomeView: View {
    @EnvironmentObject var app: PhoneState
    /// Done, when presented as a sheet. Nil when pushed from Settings.
    var onDone: (() -> Void)? = nil
    @ObservedObject private var store = HomeLayoutStore.shared
    @Environment(\.look) private var look
    @Environment(\.limitMotion) private var limitMotion
    @State private var pickingTiles = false
    /// Tab bar…: the tab bar picker (TabBarSettings.swift), as a sheet over Edit Home.
    @State private var editingTabBar = false
    @State private var confirmReset = false
    /// Whether Edit Home is on screen, for the self-test.
    static var visible = false

    init(onDone: (() -> Void)? = nil) { self.onDone = onDone }

    /// Layouts are still kept per look setting (HomeLayout.swift); the editor itself is one design.
    private var hl: HomeLook { look.homeLook }

    var body: some View {
        let layout = store.layout(hl)
        // Home is the refined one in both looks, so every section is offered in both, the Record card included.
        let hidden = layout.hidden
        List {
            Section {
                intro
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            Section {
                heading("On Home")
                ForEach(Array(layout.shown.enumerated()), id: \.element.section) { i, item in
                    row(item, layout: layout, first: i == 0, last: i == layout.shown.count - 1)
                }
                .onMove { from, to in store.update(hl) { $0.moveShown(fromOffsets: from, toOffset: to) } }
            }
            .listSectionSeparator(.hidden)
            if !hidden.isEmpty {
                Section {
                    heading("Hidden")
                    ForEach(Array(hidden.enumerated()), id: \.element.section) { i, item in
                        row(item, layout: layout, first: i == 0, last: i == hidden.count - 1)
                    }
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("Edit Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .confirmationDialog("Put Home back the way it started?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Home", role: .destructive) { animate { store.reset(hl) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every section and tile goes back to how Home began.")
        }
        .sheet(isPresented: $pickingTiles) {
            NavigationStack { HomeTilePicker(look: hl) }
                .environmentObject(app)
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimHomeTilePicker)) { note in
            pickingTiles = (note.object as? Bool) ?? true
        }
        .sheet(isPresented: $editingTabBar) {
            NavigationStack { TabBarSettingsScreen(onDone: { editingTabBar = false }) }
                .environmentObject(app)
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimEditTabBar)) { note in
            editingTabBar = (note.object as? Bool) ?? true
        }
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The serif title sits on the page; the bar keeps only Apple's buttons.
        ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
        if let onDone {
            ToolbarItem(placement: .cancellationAction) { Button("Reset") { confirmReset = true } }
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).fontWeight(.semibold) }
        } else {
            ToolbarItem(placement: .topBarTrailing) { Button("Reset") { confirmReset = true } }
        }
    }

    private func animate(_ change: () -> Void) {
        withAnimation(limitMotion ? nil : .snappy(duration: 0.25)) { change() }
    }

    // MARK: Pieces

    /// The large serif title over the lede, and Tab bar as an accent link.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            LargeSerifTitle(title: "Edit Home")
                .accessibilityAddTraits(.isHeader)
            Text("Drag to reorder. Choose Compact or Large for each section, and hide what you don't use.")
                .refinedFont(.body).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
            // A link to another screen: its name and a chevron (an ellipsis read as cut-off text; review P-20).
            Button { editingTabBar = true } label: {
                HStack(spacing: 3) {
                    Text("Tab bar")
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
            }
            .buttonStyle(.borderless)
            .refinedFont(.hint, weight: .semibold)
            .foregroundStyle(Refined.accentText)
            .accessibilityLabel("Tab bar")
            .accessibilityHint("Choose up to three tabs between Home and Settings.")
            .accessibilityIdentifier("editHome.tabBar")
        }
        .padding(.top, 8).padding(.bottom, 4)
    }

    /// A group's label over its card, in the meta style.
    private func heading(_ text: String) -> some View {
        Text(text).refinedFont(.meta).foregroundStyle(Refined.mute)
            .accessibilityAddTraits(.isHeader)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 34, bottom: 6, trailing: 34))
            .moveDisabled(true)
    }

    private func row(_ item: HomeLayout.Item, layout: HomeLayout, first: Bool, last: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.section.title)
                    .refinedFont(.rowTitle)
                    .foregroundStyle(item.visible ? Refined.ink : Refined.dim)
                    .lineLimit(1)
                detail(item, layout: layout)
            }
            Spacer(minLength: 6)
            sizeMenu(item)
            visibility(item)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 30))
        .listRowBackground(PaperRowBackground(first: first, last: last))
        .listRowSeparator(last ? .hidden : .automatic, edges: .bottom)
        .listRowSeparatorTint(Refined.separator)
        .accessibilityElement(children: .contain)
    }

    /// The second line: what the section shows. The tiles row names its tiles, with Choose tiles on its own line under
    /// them, so neither wraps beside the size menu (review P-18).
    @ViewBuilder private func detail(_ item: HomeLayout.Item, layout: HomeLayout) -> some View {
        if item.section == .tiles {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.tileSummary(layout.tiles)).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                Button("Choose tiles") { pickingTiles = true }
                    .buttonStyle(.borderless)
                    .refinedFont(.meta, weight: .semibold)
                    .foregroundStyle(Refined.accentText)
                    .lineLimit(1).fixedSize()
                    .frame(minHeight: 32)
                    .accessibilityHint("Pick the four tiles and their order.")
            }
        } else {
            Text(item.section.detail(on: .phone, look: hl)).refinedFont(.meta).foregroundStyle(Refined.mute)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Dictate, Import, and 2 more".
    static func tileSummary(_ tiles: [HomeTile]) -> String {
        let names = tiles.map(\.title)
        guard names.count > 2 else { return names.joined(separator: " and ") }
        return "\(names[0]), \(names[1]), and \(names.count - 2) more"
    }

    private func sizeMenu(_ item: HomeLayout.Item) -> some View {
        Menu {
            ForEach(HomeCardSize.allCases, id: \.self) { size in
                Button {
                    store.update(hl) { $0.setSize(item.section, size) }
                } label: {
                    if size == item.size { Label(size.title, systemImage: "checkmark") } else { Text(size.title) }   // brand: system surface (menu)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(item.size.title)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .refinedFont(.meta, weight: .semibold)
            .foregroundStyle(Refined.ink)
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(Refined.neutral, in: Capsule())
            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(item.section.title) size")
        .accessibilityValue(item.size.title)
        .accessibilityHint("Compact is one slim row; Large is the full card.")
    }

    private func visibility(_ item: HomeLayout.Item) -> some View {
        Button {
            animate { store.update(hl) { $0.setVisible(item.section, !item.visible) } }
        } label: {
            RefinedCheckbox(on: item.visible, size: 22)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(item.visible ? "Hide \(item.section.title)" : "Show \(item.section.title)")
    }
}

// MARK: - Tile picker

/// Choose the four tiles: the numbered slots at the top (drag one onto another to reorder), then every tile this
/// iPhone offers. Tap a tile to pick it into the next slot, or a picked one to take it off. Done saves four. Picked
/// tiles take the colors Home gives them (`HomeTile.refinedHues`).
struct HomeTilePicker: View {
    let homeLook: HomeLook
    @Environment(\.dismiss) private var dismiss
    @State private var picks: [HomeTile]
    /// Whether the picker is on screen, for the self-test.
    static var visible = false

    init(look: HomeLook) {
        homeLook = look
        _picks = State(initialValue: HomeLayoutStore.shared.layout(look).tiles)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LargeSerifTitle(title: "Shortcut tiles", eyebrow: "Home")
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose four. Drag them to reorder.").refinedFont(.body).foregroundStyle(Refined.dim)
                HStack(spacing: 8) {
                    ForEach(0..<HomeLayout.tileCount, id: \.self) { slot($0) }
                }
                Text("All tiles").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(HomeTile.available(on: .phone), id: \.self) { cell($0) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("Shortcut tiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    HomeLayoutStore.shared.update(homeLook) { $0.tiles = picks }
                    dismiss()
                }
                .fontWeight(.semibold)
                .disabled(picks.count != HomeLayout.tileCount)
            }
        }
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    /// A numbered slot: the picked tile (drag it onto another slot to reorder), or an empty dashed box.
    @ViewBuilder private func slot(_ i: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.tile), style: .continuous)
        VStack(spacing: 6) {
            Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Refined.mute)
            if i < picks.count {
                let t = picks[i]
                tileFace(t, slot: i, compact: true)
                    .draggable(t.rawValue) { tileFace(t, slot: i, compact: true).frame(width: 76) }
                    .accessibilityLabel("\(i + 1): \(t.title)")
                    .accessibilityHint("Drag onto another slot to reorder.")
            } else {
                shape.strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .foregroundStyle(Refined.faint)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .accessibilityLabel("Slot \(i + 1), empty")
            }
        }
        .frame(maxWidth: .infinity)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let t = HomeTile(rawValue: raw), picks.contains(t) else { return false }
            picks = HomeLayout.move(t, to: i, in: picks)
            return true
        }
    }

    /// A tile in the grid, numbered when picked.
    private func cell(_ t: HomeTile) -> some View {
        let n = picks.firstIndex(of: t)
        return Button { picks = HomeLayout.toggle(t, in: picks) } label: {
            tileFace(t, slot: n, compact: false)
                .overlay(alignment: .topTrailing) { badge(n).padding(6) }
        }
        .buttonStyle(RefinedPress())
        .accessibilityLabel(t.title)
        .accessibilityValue(n.map { "Tile \($0 + 1)" } ?? "Not picked")
        .accessibilityHint(n == nil ? (picks.count < HomeLayout.tileCount ? "Picks it into the next slot." : "Take a tile off first.") : "Takes it off.")
    }

    /// The tile's face: picked tiles take Home's color for them, with the accent's edge; the rest sit on the neutral
    /// wash.
    private func tileFace(_ t: HomeTile, slot: Int?, compact: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.tile), style: .continuous)
        let hue: RefinedHue? = slot.flatMap { s in s < picks.count ? HomeTile.refinedHues(picks)[s] : nil }
        let fill = hue.map { Refined.badge($0) } ?? Refined.neutral
        let on = hue.map { Refined.onBadge($0) } ?? Refined.ink
        return VStack(alignment: .leading, spacing: 6) {
            IconGlyph(art: t.art, size: compact ? 16 : 20, color: on)
            Spacer(minLength: 0)
            Text(t.title)
                .refinedFont(compact ? .caption : .meta, weight: .semibold)
                .foregroundStyle(on)
                .multilineTextAlignment(.leading)
                .lineLimit(2).minimumScaleFactor(0.8)
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, minHeight: compact ? 64 : 82, alignment: .topLeading)
        .background(shape.fill(fill))
        .overlay { if slot != nil { shape.strokeBorder(Refined.accentText, lineWidth: 1.5) } }
        .contentShape(shape)
    }

    @ViewBuilder private func badge(_ n: Int?) -> some View {
        if let n {
            Text("\(n + 1)").font(.system(size: 12, weight: .bold))
                .foregroundStyle(Refined.paper)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Refined.accentText))
        } else {
            Circle().strokeBorder(Refined.faint, lineWidth: 1.2)
                .frame(width: 22, height: 22)
        }
    }
}

extension Notification.Name {
    /// Opens (true) or closes (false) Edit Home's tile picker; the self-test uses it.
    static let verbatimHomeTilePicker = Notification.Name("verbatimHomeTilePicker")
    /// Opens (true) or closes (false) Edit Home's Tab bar… sheet; the self-test uses it.
    static let verbatimEditTabBar = Notification.Name("verbatimEditTabBar")
}
