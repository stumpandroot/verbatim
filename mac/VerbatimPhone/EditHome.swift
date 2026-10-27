import SwiftUI

/// Edit Home (mockup "premium", section 03): Home's sections in a list you drag to reorder, each with Compact or Large
/// and a control to show or hide it, and the four shortcut tiles (HomeTilePicker). Changes reach Home at once and are
/// kept per look, on this iPhone (HomeLayout.swift). Both looks use this screen, each in its own clothes.
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
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34
    /// Whether Edit Home is on screen, for the self-test.
    static var visible = false

    init(onDone: (() -> Void)? = nil) { self.onDone = onDone }

    private var hl: HomeLook { look.homeLook }

    var body: some View {
        let layout = store.layout(hl)
        // Native's Record lives in the tab bar's accessory, so Edit Home doesn't offer a Record section there.
        let hidden = layout.hidden.filter { !(look.isNative && $0.section == .record) }
        List {
            Section {
                intro
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            Section {
                if !look.isNative { PhoneListHeading(text: "On Home") }
                ForEach(Array(layout.shown.enumerated()), id: \.element.section) { i, item in
                    row(item, layout: layout, first: i == 0, last: i == layout.shown.count - 1)
                }
                .onMove { from, to in store.update(hl) { $0.moveShown(fromOffsets: from, toOffset: to) } }
            } header: {
                if look.isNative { Text("On Home") }
            }
            .listSectionSeparator(.hidden)
            if !hidden.isEmpty {
                Section {
                    if !look.isNative { PhoneListHeading(text: "Hidden") }
                    ForEach(Array(hidden.enumerated()), id: \.element.section) { i, item in
                        row(item, layout: layout, first: i == 0, last: i == hidden.count - 1)
                    }
                } header: {
                    if look.isNative { Text("Hidden") }
                } footer: {
                    if look.isNative { Text("Record is in the tab bar on every tab.") }
                }
                .listSectionSeparator(.hidden)
            }
        }
        .environment(\.editMode, .constant(.active))
        .phoneGroupedList()
        .scrollContentBackground(.hidden)
        .phonePage()
        .navigationTitle(look.isNative ? "Edit Home" : "")
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
        .toolbar { toolbar }
        .confirmationDialog("Put Home back the way it started?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Home", role: .destructive) { animate { store.reset(hl) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every section and tile goes back to how this look began. The other look keeps its layout.")
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
        .onAppear {
            Self.visible = true
            // The Record card retired from Native's Home (Record is in the tab bar's accessory): a layout that still
            // shows it hides it, so Edit Home and Home agree.
            if look.isNative, layout.isVisible(.record) { store.update(hl) { $0.setVisible(.record, false) } }
        }
        .onDisappear { Self.visible = false }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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

    /// Verbose style: the eyebrow and the serif title over the lede. Native: the lede under the large title.
    @ViewBuilder private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !look.isNative {
                PhoneEyebrow(text: "Home")
                (Text("Edit ") + Text("Home").italic()).lookSerif(titleSize).foregroundStyle(.lookInk)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("Drag to reorder. Choose Compact or Large for each section, and hide what you don't use.")
                .font(.system(size: 15)).foregroundStyle(.lookDim)
                .fixedSize(horizontal: false, vertical: true)
            // A link to another screen: its name and a chevron (an ellipsis read as cut-off text; review P-20).
            Button { editingTabBar = true } label: {
                HStack(spacing: 3) {
                    Text("Tab bar")
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.lookAccentText)
            .accessibilityLabel("Tab bar")
            .accessibilityHint("Choose up to three tabs between Home and Settings.")
            .accessibilityIdentifier("editHome.tabBar")
        }
        .padding(.vertical, 4)
    }

    private func row(_ item: HomeLayout.Item, layout: HomeLayout, first: Bool, last: Bool) -> some View {
        HStack(spacing: 12) {
            if look.isNative { visibility(item) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.section.title)
                    .font(look.isNative ? .body : .system(size: 16))
                    .foregroundStyle(.lookInk)
                    .opacity(item.visible ? 1 : 0.65)
                    .lineLimit(1)
                detail(item, layout: layout)
            }
            Spacer(minLength: 6)
            sizeMenu(item)
            if !look.isNative { visibility(item) }
        }
        .padding(.vertical, 3)
        .listRowBackground(PhoneListRowCard(first: first, last: last))
        .listRowSeparator(last ? .hidden : .automatic, edges: .bottom)
        .listRowSeparatorTint(look.isNative ? nil : Ink.hairline)
        .accessibilityElement(children: .contain)
    }

    /// The second line: what the section shows. The tiles row names its tiles, with Choose tiles on its own line under
    /// them, so neither wraps beside the size menu (review P-18).
    @ViewBuilder private func detail(_ item: HomeLayout.Item, layout: HomeLayout) -> some View {
        if item.section == .tiles {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.tileSummary(layout.tiles)).font(.system(size: 13)).foregroundStyle(.lookMute).lineLimit(1)
                Button("Choose tiles") { pickingTiles = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.lookAccentText)
                    .lineLimit(1).fixedSize()
                    .accessibilityHint("Pick the four tiles and their order.")
            }
        } else {
            Text(item.section.detail(on: .phone, look: hl)).font(.system(size: 13)).foregroundStyle(.lookMute)
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
                    if size == item.size { Label(size.title, systemImage: "checkmark") } else { Text(size.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(item.size.title)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(look.isNative ? .system(size: 14, weight: .medium) : .system(size: 13, weight: .semibold))
            .foregroundStyle(.lookInk)
            .padding(.horizontal, 10).frame(minHeight: 30)
            .background(look.isNative ? NativeInk.fill : PhoneInk.wash, in: RoundedRectangle(cornerRadius: look.isNative ? 15 : Radius.button, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(item.section.title) size")
        .accessibilityValue(item.size.title)
        .accessibilityHint("Compact is one slim row; Large is the full card.")
    }

    @ViewBuilder private func visibility(_ item: HomeLayout.Item) -> some View {
        Button {
            animate { store.update(hl) { $0.setVisible(item.section, !item.visible) } }
        } label: {
            Group {
                if look.isNative {
                    Image(systemName: item.visible ? "minus.circle.fill" : "plus.circle.fill")   // brand: native
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, item.visible ? NativeInk.danger : NativeInk.toggle)   // brand: native
                } else {
                    Image(systemName: item.visible ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(Ink.ink)
                }
            }
            .font(.system(size: 22))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(item.visible ? "Hide \(item.section.title)" : "Show \(item.section.title)")
    }
}

// MARK: - Tile picker

/// Choose the four tiles: the numbered slots at the top (drag one onto another to reorder), then every tile this
/// iPhone offers. Tap a tile to pick it into the next slot, or a picked one to take it off. Done saves four.
struct HomeTilePicker: View {
    let homeLook: HomeLook
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @State private var picks: [HomeTile]
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30
    /// Whether the picker is on screen, for the self-test.
    static var visible = false

    init(look: HomeLook) {
        homeLook = look
        _picks = State(initialValue: HomeLayoutStore.shared.layout(look).tiles)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !look.isNative {
                    PhoneEyebrow(text: "Home")
                    (Text("Shortcut ") + Text("tiles").italic()).lookSerif(titleSize).foregroundStyle(.lookInk)
                        .accessibilityAddTraits(.isHeader)
                }
                Text("Choose four. Drag them to reorder.").font(.system(size: 15)).foregroundStyle(.lookDim)
                HStack(spacing: 8) {
                    ForEach(0..<HomeLayout.tileCount, id: \.self) { slot($0) }
                }
                Text("All tiles").font(look.isNative ? .headline : Ink.mono(12)).foregroundStyle(look.isNative ? NativeInk.label : Ink.mute)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(HomeTile.available(on: .phone), id: \.self) { cell($0) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .phonePage()
        .navigationTitle(look.isNative ? "Shortcut tiles" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        let shape = RoundedRectangle(cornerRadius: look.isNative ? 18 : Radius.tile, style: .continuous)
        VStack(spacing: 6) {
            Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.lookMute)
            if i < picks.count {
                let t = picks[i]
                tileFace(t, slot: i, compact: true)
                    .draggable(t.rawValue) { tileFace(t, slot: i, compact: true).frame(width: 76) }
                    .accessibilityLabel("\(i + 1): \(t.title)")
                    .accessibilityHint("Drag onto another slot to reorder.")
            } else {
                shape.strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .foregroundStyle(.lookMute)
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
        .buttonStyle(PhoneCardPress())
        .accessibilityLabel(t.title)
        .accessibilityValue(n.map { "Tile \($0 + 1)" } ?? "Not picked")
        .accessibilityHint(n == nil ? (picks.count < HomeLayout.tileCount ? "Picks it into the next slot." : "Take a tile off first.") : "Takes it off.")
    }

    /// The tile's face. Verbose style: picked tiles take their capture mode's color (Home's `tileFill`) with an ink
    /// outline. Native: a soft card, outlined in the accent when picked.
    private func tileFace(_ t: HomeTile, slot: Int?, compact: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: look.isNative ? 18 : Radius.tile, style: .continuous)
        let fill = slot == nil ? nil : HomeScreen.tileFill(t, in: picks)
        return VStack(alignment: look.isNative ? .center : .leading, spacing: 6) {
            if look.isNative {
                Image(systemName: t.symbol).font(.system(size: compact ? 15 : 17, weight: .medium)).foregroundStyle(NativeInk.accent)
                    .frame(width: compact ? 30 : 36, height: compact ? 30 : 36)
            } else {
                IconGlyph(art: t.art, size: compact ? 16 : 20, color: fill == nil ? Ink.ink : Ink.inkFixed)
            }
            if !look.isNative { Spacer(minLength: 0) }
            Text(t.title)
                .font(look.isNative ? .system(size: compact ? 11 : 13, weight: .semibold) : Ink.serif(compact ? 13 : 16))
                .foregroundStyle(look.isNative ? NativeInk.label : (fill == nil ? Ink.ink : Ink.inkFixed))
                .multilineTextAlignment(look.isNative ? .center : .leading)
                .lineLimit(2).minimumScaleFactor(0.8)
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, minHeight: compact ? 64 : 82, alignment: look.isNative ? .center : .topLeading)
        .background {
            if look.isNative {
                shape.fill(NativeInk.card)
            } else if let fill {
                PhonePanelFill(color: fill, shape: shape)
            } else {
                shape.fill(Ink.card)
            }
        }
        .overlay {
            if look.isNative {
                if slot != nil { shape.strokeBorder(NativeInk.accent, lineWidth: 1.5) }
            } else {
                shape.strokeBorder(slot == nil ? Ink.hairline : Ink.ink, lineWidth: slot == nil ? 1 : 1.5)
            }
        }
        .contentShape(shape)
    }

    @ViewBuilder private func badge(_ n: Int?) -> some View {
        if let n {
            Text("\(n + 1)").font(.system(size: 12, weight: .bold))
                .foregroundStyle(look.isNative ? Color.white : Ink.paper)
                .frame(width: 22, height: 22)
                .background(Circle().fill(look.isNative ? NativeInk.accent : Ink.ink))
        } else {
            Circle().strokeBorder(look.isNative ? AnyShapeStyle(NativeInk.tertiary) : AnyShapeStyle(Ink.mute), lineWidth: 1.2)
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
