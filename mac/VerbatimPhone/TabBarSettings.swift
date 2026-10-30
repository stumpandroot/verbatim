import SwiftUI

/// Settings › Personalization and preferences › Tab bar (and Edit Home's Tab bar…): a live preview of the bar, then
/// every tab you can add. Check up to three; drag the checked ones to reorder. Home stays first and Settings last.
/// Changes reach the bar at once and are kept on this iPhone (PhoneTabBar.swift). On the refined kit (DESIGN.md §13)
/// in both look settings: the large serif title, the preview with Record above the tabs, and the rows in cards.
struct TabBarSettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    /// Done, when presented as a sheet (from Edit Home). Nil when pushed from Settings.
    var onDone: (() -> Void)? = nil
    @ObservedObject private var store = PhoneTabBarStore.shared
    @ObservedObject private var recordAs = RecordAsStore.shared
    @Environment(\.limitMotion) private var limitMotion
    /// Whether the picker is on screen, for the self-test.
    static var visible = false

    var body: some View {
        let bar = store.bar
        // Journal is offered once Journal entry is on in Record as or you have an entry (consolidation, item 16).
        let offered = PhoneTab.offered(showJournal: recordAs.rows.showsJournal(hasEntries: app.store.hasJournalEntries), in: bar.middle)
        let more = offered.filter { !bar.middle.contains($0) }
        List {
            Section {
                intro
                TabBarPreview(bar: bar)
                    .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            Section {
                heading(inBar(bar))
                fixedRow(.home)
                ForEach(bar.middle, id: \.self) { t in row(t, picked: true, room: true) }
                    .onMove { from, to in animate { app.setTabBar(PhoneTabBar.move(bar.middle, fromOffsets: from, toOffset: to)) } }
                fixedRow(.settings)
            }
            .listSectionSeparator(.hidden)
            if !more.isEmpty {
                Section {
                    heading("More tabs")
                    ForEach(Array(more.enumerated()), id: \.element) { i, t in
                        row(t, picked: false, room: bar.middle.count < PhoneTabBar.maxMiddle, first: i == 0, last: i == more.count - 1)
                    }
                    if bar.middle.count >= PhoneTabBar.maxMiddle {
                        Text(Self.fullNote).refinedFont(.meta).foregroundStyle(Refined.mute)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 34, bottom: 0, trailing: 34))
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { animate { app.setTabBar(PhoneTabBar.defaultMiddle) } }.disabled(bar == .default)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).fontWeight(.semibold) }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") { animate { app.setTabBar(PhoneTabBar.defaultMiddle) } }.disabled(bar == .default)
                }
            }
        }
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    private func animate(_ change: () -> Void) {
        withAnimation(limitMotion ? nil : .snappy(duration: 0.25)) { change() }
    }

    // MARK: Pieces

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            LargeSerifTitle(title: "Tab bar")
            Text("Home stays first and Settings last. Choose up to three tabs to go between them, and drag to reorder.")
                .refinedFont(.body).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4).padding(.bottom, 6)
    }

    /// A group's label over its card, in the meta style.
    private func heading(_ text: String) -> some View {
        Text(text).refinedFont(.meta).foregroundStyle(Refined.mute)
            .accessibilityAddTraits(.isHeader)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 34, bottom: 6, trailing: 34))
            .moveDisabled(true)
    }

    private func inBar(_ bar: PhoneTabBar) -> String { "In the bar · \(bar.middle.count) of \(PhoneTabBar.maxMiddle)" }

    static let fullNote = "Three fit between Home and Settings. Uncheck one to add another."

    /// Home or Settings: always in the bar, in place, with no checkbox.
    private func fixedRow(_ t: PhoneTab) -> some View {
        HStack(spacing: 12) {
            PhoneTabGlyph(tab: t, size: 22).foregroundStyle(Refined.mute).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).refinedFont(.body).foregroundStyle(Refined.dim)
                Text(t.detail).refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
        .listRowInsets(EdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 34))
        .listRowBackground(PaperRowBackground(first: t == .home, last: t == .settings))
        .listRowSeparator(t == .settings ? .hidden : .automatic, edges: .bottom)
        .listRowSeparatorTint(Refined.separator)
        .moveDisabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityValue(t == .home ? "Always first" : "Always last")
    }

    /// A tab you can add: the check (or the plus), the tab's icon, its name, and what it opens. Tap to check or
    /// uncheck it.
    private func row(_ t: PhoneTab, picked: Bool, room: Bool, first: Bool = false, last: Bool = false) -> some View {
        Button {
            animate { app.setTabBar(PhoneTabBar.toggle(t, in: store.bar.middle)) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: picked ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(picked ? Refined.accentText : Refined.faint)
                    .frame(width: 28, height: 28)
                PhoneTabGlyph(tab: t, size: 22).foregroundStyle(Refined.ink).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).refinedFont(.body).foregroundStyle(Refined.ink)
                    Text(t.detail).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
            .opacity(picked || room ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!picked && !room)
        .listRowInsets(EdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 34))
        .listRowBackground(PaperRowBackground(first: first, last: last))
        .listRowSeparator(last ? .hidden : .automatic, edges: .bottom)
        .listRowSeparatorTint(Refined.separator)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(picked ? "In the tab bar" : "Not in the tab bar")
        .accessibilityHint(picked ? "Takes it out of the tab bar." : room ? "Adds it to the tab bar." : "Uncheck a tab first.")
        .accessibilityIdentifier("tabbar.\(t.rawValue)")
    }
}

/// A tab's fine-line glyph at any size, as the tab bar draws it. Takes the foreground style.
struct PhoneTabGlyph: View {
    var tab: PhoneTab
    var size: CGFloat

    var body: some View {
        ArtIcon(art: tab.art, size: size, lineWidth: 1.5)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The live preview: Record as the tab bar's accessory draws it, then the bar as it is now, each tab's glyph over its
/// name, Home lit in the accent. A drawing of the system's glass bar on the card, so no material here.
struct TabBarPreview: View {
    var bar: PhoneTabBar
    /// For the self-test: the tabs the preview drew, left to right.
    static var shown: [PhoneTab] = []

    var body: some View {
        VStack(spacing: 6) {
            // Record in the tab bar's bottom accessory, above the tabs (RecordAccessory.swift).
            HStack(spacing: 10) {
                AccessoryRecordDisc(size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Record").font(.system(size: 13, weight: .semibold)).foregroundStyle(Refined.ink)
                    Text("Voice note").font(.system(size: 11)).foregroundStyle(Refined.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Refined.card))
            tabs
        }
        .animation(nil, value: bar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(bar.tabs.map(\.title).joined(separator: ", ")), with Record above the tabs")
        .onAppear { Self.shown = bar.tabs }
        .onChange(of: bar) { _, b in Self.shown = b.tabs }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(bar.tabs, id: \.self) { t in
                let on = t == .home
                VStack(spacing: 3) {
                    PhoneTabGlyph(tab: t, size: 22)
                    Text(t.title).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(on ? Refined.accentText : Refined.dim)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background(Capsule().fill(Refined.card))
    }
}
