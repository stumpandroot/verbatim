import SwiftUI

/// Settings › Personalization and preferences › Tab bar (and Edit Home's Tab bar…): a live preview of the bar, then
/// every tab you can add. Check up to three; drag the checked ones to reorder. Home stays first and Settings last.
/// Changes reach the bar at once and are kept on this iPhone (PhoneTabBar.swift). Both looks, each in its own clothes.
struct TabBarSettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    /// Done, when presented as a sheet (from Edit Home). Nil when pushed from Settings.
    var onDone: (() -> Void)? = nil
    @ObservedObject private var store = PhoneTabBarStore.shared
    @ObservedObject private var recordAs = RecordAsStore.shared
    @Environment(\.look) private var look
    @Environment(\.limitMotion) private var limitMotion
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34
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
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            Section {
                if !look.isNative { PhoneListHeading(text: inBar(bar)) }
                fixedRow(.home)
                ForEach(bar.middle, id: \.self) { t in row(t, picked: true, room: true) }
                    .onMove { from, to in animate { app.setTabBar(PhoneTabBar.move(bar.middle, fromOffsets: from, toOffset: to)) } }
                fixedRow(.settings)
            } header: {
                if look.isNative { Text(inBar(bar)) }
            }
            .listSectionSeparator(.hidden)
            if !more.isEmpty {
                Section {
                    if !look.isNative { PhoneListHeading(text: "More tabs") }
                    ForEach(Array(more.enumerated()), id: \.element) { i, t in
                        row(t, picked: false, room: bar.middle.count < PhoneTabBar.maxMiddle, first: i == 0, last: i == more.count - 1)
                    }
                    if !look.isNative, bar.middle.count >= PhoneTabBar.maxMiddle {
                        Text(Self.fullNote).font(.system(size: 13)).foregroundStyle(Ink.mute)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 0, trailing: 4))
                    }
                } header: {
                    if look.isNative { Text("More tabs") }
                } footer: {
                    if look.isNative, bar.middle.count >= PhoneTabBar.maxMiddle { Text(Self.fullNote) }
                }
                .listSectionSeparator(.hidden)
            }
        }
        .environment(\.editMode, .constant(.active))
        .phoneGroupedList()
        .scrollContentBackground(.hidden)
        .phonePage()
        .navigationTitle(look.isNative ? "Tab bar" : "")
        .navigationBarTitleDisplayMode(look.isNative ? .large : .inline)
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

    @ViewBuilder private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !look.isNative {
                PhoneEyebrow(text: "Personalization")
                (Text("Tab ") + Text("bar").italic()).lookSerif(titleSize).foregroundStyle(.lookInk)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("Home stays first and Settings last. Choose up to three tabs to go between them, and drag to reorder.")
                .font(.system(size: 15)).foregroundStyle(.lookDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func inBar(_ bar: PhoneTabBar) -> String { "In the bar · \(bar.middle.count) of \(PhoneTabBar.maxMiddle)" }

    static let fullNote = "Three fit between Home and Settings. Uncheck one to add another."

    /// Home or Settings: always in the bar, in place, with no checkbox.
    private func fixedRow(_ t: PhoneTab) -> some View {
        HStack(spacing: 12) {
            PhoneTabGlyph(tab: t, size: 22).foregroundStyle(.lookMute).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(look.isNative ? .body : .system(size: 16)).foregroundStyle(.lookInk).opacity(0.65)
                Text(t.detail).font(.system(size: 13)).foregroundStyle(.lookMute)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .listRowBackground(PhoneListRowCard(first: t == .home, last: t == .settings))
        .listRowSeparator(t == .settings ? .hidden : .automatic, edges: .bottom)
        .listRowSeparatorTint(look.isNative ? nil : Ink.hairline)
        .moveDisabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityValue(t == .home ? "Always first" : "Always last")
    }

    /// A tab you can add: the check (or the empty circle), the tab's icon, its name, and what it opens. Tap to check or
    /// uncheck it.
    private func row(_ t: PhoneTab, picked: Bool, room: Bool, first: Bool = false, last: Bool = false) -> some View {
        Button {
            animate { app.setTabBar(PhoneTabBar.toggle(t, in: store.bar.middle)) }
        } label: {
            HStack(spacing: 12) {
                check(picked)
                PhoneTabGlyph(tab: t, size: 22).foregroundStyle(.lookInk).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(look.isNative ? .body : .system(size: 16)).foregroundStyle(.lookInk)
                    Text(t.detail).font(.system(size: 13)).foregroundStyle(.lookMute).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .opacity(picked || room ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!picked && !room)
        .listRowBackground(PhoneListRowCard(first: first, last: last))
        .listRowSeparator(last ? .hidden : .automatic, edges: .bottom)
        .listRowSeparatorTint(look.isNative ? nil : Ink.hairline)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(picked ? "In the tab bar" : "Not in the tab bar")
        .accessibilityHint(picked ? "Takes it out of the tab bar." : room ? "Adds it to the tab bar." : "Uncheck a tab first.")
        .accessibilityIdentifier("tabbar.\(t.rawValue)")
    }

    @ViewBuilder private func check(_ on: Bool) -> some View {
        Group {
            if look.isNative {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")   // brand: native
                    .foregroundStyle(on ? NativeInk.accent : NativeInk.tertiary)
            } else {
                Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(Ink.ink)
            }
        }
        .font(.system(size: 22))
        .frame(width: 28, height: 28)
    }
}

/// A tab's icon at any size: the BrandArt glyph in Verbose style, the SF Symbol in Native. Takes the foreground style.
struct PhoneTabGlyph: View {
    var tab: PhoneTab
    var size: CGFloat
    @Environment(\.look) private var look

    var body: some View {
        Group {
            if look.isNative {
                Image(systemName: tab.symbol).font(.system(size: size * 0.8))   // brand: native
            } else {
                ArtIcon(art: tab.art, size: size, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The live preview: the bar as it is now, each tab's icon over its name, Home lit as selected. Verbose style: an
/// outlined card capsule; Native: a soft card capsule (a drawing of the system's glass bar, so no material here).
struct TabBarPreview: View {
    var bar: PhoneTabBar
    @Environment(\.look) private var look
    /// For the self-test: the tabs the preview drew, left to right.
    static var shown: [PhoneTab] = []

    var body: some View {
        VStack(spacing: 6) {
            // Native: Record in the tab bar's bottom accessory, above the tabs (RecordAccessory.swift).
            if look.isNative {
                HStack(spacing: 10) {
                    NativeRecordDisc(size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Record").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeInk.label)
                        Text("Voice note").font(.system(size: 11)).foregroundStyle(NativeInk.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(NativeInk.card))
            }
            tabs
        }
        .animation(nil, value: bar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(bar.tabs.map(\.title).joined(separator: ", "))\(look.isNative ? ", with Record above the tabs" : "")")
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
                .foregroundStyle(on ? (look.isNative ? NativeInk.accent : Ink.ink) : (look.isNative ? NativeInk.secondary : Ink.mute))
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background {
            if look.isNative {
                Capsule().fill(NativeInk.card)
            } else {
                Capsule().fill(Ink.card).overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5))
            }
        }
    }
}
