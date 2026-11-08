import SwiftUI
import AppKit

/// The Settings window (DESIGN.md §13; mockup "Verbose Refined Look", MacSettings; redesign MAC-24): the system sidebar
/// (a NavigationSplitView, as the main window has: the column reaches the full height with the window controls in it,
/// the glass panel on macOS 26) with the search field on top, then the panes of MacSettingsMap, each with its colored
/// icon square, the chosen one on the persimmon tint, and the version with What's new at the foot; the chosen pane on
/// paper beside it. ↑ and ↓ move between panes while the pane list has the keyboard. Typing in search swaps the list for
/// the panes with matches and shows every matching setting; a result opens its pane and flashes the row. ⌘F focuses
/// search; Esc clears it.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .personalization
    @ObservedObject private var model = SettingsModel.shared
    @FocusState private var searchFocused: Bool
    /// Whether the window is closed. SwiftUI keeps a closed Settings window's views (it orders the window out), and
    /// every pane that reads AppState re-rendered on each publish: every screen change in the main window (build 214:
    /// 60 to 250 ms of a screen change). Closed, the window holds an empty view of the same size, so nothing in it
    /// observes anything; the panes are built again when it comes back on screen. Not reading AppState here keeps this view out of those publishes too (the
    /// panes get it from the scene).
    @State private var closed = false

    /// The window closed, or is on screen again.
    private func windowChanged(_ note: Notification, closing: Bool) {
        guard let w = note.object as? NSWindow, w === SettingsModel.shared.window else { return }
        let now = closing || !w.isVisible
        if closed != now { closed = now }
    }

    var body: some View {
        if closed { SettingsModel.shared.closedRenders.root += 1 }
        NavMarks.mark(closed ? "settings-closed" : "settings")
        return Group {
            if closed {
                Color.clear
                    .frame(minWidth: 820, idealWidth: 1000, maxWidth: .infinity, minHeight: 560, idealHeight: 720, maxHeight: .infinity)
            } else {
                window
            }
        }
        .background(WindowReader { w in configure(w) })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { windowChanged($0, closing: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { windowChanged($0, closing: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { windowChanged($0, closing: false) }
    }

    private var window: some View {
        // Always both columns: there's no sidebar button, and the pane list is the only way between panes.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(tab: $tab, searchFocused: $searchFocused)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            // The pages are as they were: on paper, from the window's top edge under the transparent title bar.
            Group {
                if model.isSearching {
                    SettingsSearchResults()
                } else {
                    pane.id(tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Refined.paper)
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Refined.paper)
        .frame(minWidth: 820, idealWidth: 1000, maxWidth: .infinity, minHeight: 560, idealHeight: 720, maxHeight: .infinity)
        .foregroundStyle(Refined.ink)
        .tint(Refined.accentText)
        .background {
            // ⌘F focuses search; Esc (anywhere in the window) clears it.
            Button("Search Settings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .onExitCommand { if model.isSearching { model.query = "" } }
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case .personalization: PersonalizationSettingsPane()
        case .recording: RecordingSettingsPane()
        case .dictate: DictationSettings()
        case .floatingButton: FloatingButtonSettingsPane()
        case .meetings: MeetingsSettingsPane()
        case .watched: WatchedFoldersPane()
        case .storage: StorageSettingsPane()
        case .privacy: PrivacySettingsPane()
        case .account: AccountSettingsPane()
        case .support: SupportSettingsPane()
        case .features: FeaturesSettingsPane()
        case .whatsNew: WhatsNewSettingsPane()
        }
    }

    /// The page runs under a transparent title bar, like the main window, so the sidebar reaches the top edge with the
    /// window controls in it.
    private func configure(_ w: NSWindow) {
        SettingsModel.shared.window = w
        guard !w.styleMask.contains(.fullSizeContentView) || w.titleVisibility != .hidden else { return }
        w.styleMask.insert(.fullSizeContentView)
        w.styleMask.insert(.resizable)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Settings"
        w.backgroundColor = NSColor(Refined.paper)
    }
}

// MARK: - Sidebar

/// The sidebar column (mockup; MAC-24): the search field, then each pane's row with its square, or while searching, the
/// panes with matches and how many; the version and What's new at the foot. It sits on the system's sidebar surface
/// (`macSidebarSurface`). With the pane list focused, ↑ and ↓ open the pane before or after (`MacSettingsMap.step`), and
/// the chosen row shows the focus bar (MAC-25); there's no blue ring around the column.
struct SettingsSidebar: View {
    @Binding var tab: SettingsTab
    var searchFocused: FocusState<Bool>.Binding
    @ObservedObject private var model = SettingsModel.shared
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            searchField.padding(.bottom, 10)
            ScrollView(.vertical, showsIndicators: false) {
                rows.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Settings panes")
            if model.isSearching {
                Text("Press Esc to clear the search.").font(.system(size: 12)).foregroundStyle(Refined.mute).padding(.horizontal, 10)
                    .padding(.top, 8)
            } else {
                SettingsVersionFooter { tab = .whatsNew }.padding(.top, 8)
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 14)
        // minHeight 0: the column never reports more height than the window has; the list scrolls instead.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .macSidebarSurface()
    }

    @ViewBuilder private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.isSearching {
                let results = SettingsIndex.search(model.query)
                let counts = SettingsIndex.sectionCounts(results)
                Text("Sections with matches").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.mute)
                    .padding(.horizontal, 10).padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                if counts.isEmpty {
                    Text("No matches").font(.system(size: 13)).foregroundStyle(Refined.mute).padding(.horizontal, 10).padding(.vertical, 6)
                }
                ForEach(Array(counts.enumerated()), id: \.element.tab) { i, c in
                    SettingsSideItem(tab: c.tab, count: c.count, selected: i == 0) {
                        if let first = results.first(where: { $0.section == c.tab }) { model.open(first) }
                    }
                    .uiWindowTarget("settings-match-\(c.tab.rawValue)").uiTarget("settings-match-\(c.tab.rawValue)")
                }
            } else {
                ForEach(SettingsTab.sidebar) { t in
                    SettingsSideItem(tab: t, selected: tab == t, focused: listFocused) { tab = t; listFocused = true }
                        .uiWindowTarget("settings-\(t.rawValue)").uiTarget("settings-\(t.rawValue)")
                }
            }
        }
    }

    /// ↑ or ↓ in the pane list: the pane before or after the chosen one. While searching, the arrows are left alone.
    private func step(_ by: Int) -> KeyPress.Result {
        guard !model.isSearching else { return .ignored }
        if let r = MacSettingsMap.step(from: tab.rawValue, by: by), let t = SettingsTab(rawValue: r), t != tab { tab = t }
        return .handled
    }

    /// The search field on the sidebar (mockup): a quiet wash, the magnifying glass, and a clear button while you type.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Refined.mute)
                .accessibilityHidden(true)
            TextField("Search settings", text: $model.query, prompt: Text("Search settings").foregroundStyle(Refined.mute))
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Refined.ink)
                .focused(searchFocused)
                .onExitCommand { model.query = "" }
                .onSubmit { if let first = SettingsIndex.search(model.query).first { model.open(first) } }
                .accessibilityLabel("Search settings")
            if model.isSearching {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Refined.mute) }
                    .buttonStyle(.plain).help("Clear the search (Esc)").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Refined.neutral, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.field), style: .continuous))
        .uiWindowTarget("settings-search").uiTarget("settings-search")
    }
}

/// A sidebar row (mockup): the pane's square and its name; chosen, the name in semibold on the persimmon tint.
struct SettingsSideItem: View {
    var tab: SettingsTab
    var count: Int? = nil
    var selected: Bool
    /// The pane list has the keyboard: the chosen row shows the focus bar (MAC-25), as the main sidebar's does.
    var focused = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 9) {
            IconSquare(art: tab.art, hue: tab.hue)
            Text(tab.sidebarTitle).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            if let count { Text("\(count)").monospacedDigit().foregroundStyle(Refined.mute) }
        }
        .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
        .foregroundStyle(Refined.ink)
        .padding(.horizontal, 10).frame(height: 34)
        .background {
            if selected { shape.fill(Refined.persimmonTint) } else { shape.fill(Refined.neutral).opacity(hover ? 1 : 0) }
        }
        .overlay(alignment: .leading) { if selected && focused { FocusBar() } }
        .contentShape(shape)
        .onHover { hover = $0 }
        .tapArea(action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(count.map { "\(tab.sidebarTitle), \($0) match\($0 == 1 ? "" : "es")" } ?? tab.sidebarTitle)
    }
}

/// The foot of the Settings sidebar (mockup): "Version 1.0 beta (237) · What's new"; the link opens the release notes
/// pane.
struct SettingsVersionFooter: View {
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            (Text("Version \(AppVersion.label) \u{00B7} ").foregroundStyle(Refined.mute)
             + Text("What's new").foregroundStyle(Refined.accentText))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Version \(AppVersion.spoken). What's new")
        .accessibilityAddTraits(.isButton)
        .help("What each build of Verbose added")
        .uiWindowTarget("settings-version").uiTarget("settings-version")
    }
}

// MARK: - Search results

/// Every matching setting, grouped by pane, with the query tinted in each label and description. Rows look like the
/// panes' rows; the whole row opens the setting.
struct SettingsSearchResults: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        let results = SettingsIndex.search(model.query)
        let terms = SettingsIndex.terms(model.query)
        let counts = SettingsIndex.sectionCounts(results)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\u{201C}\(model.query.trimmingCharacters(in: .whitespaces))\u{201D}")
                        .font(Refined.serif(30)).foregroundStyle(Refined.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")").font(.system(size: 14)).foregroundStyle(Refined.dim)
                }
                if results.isEmpty {
                    Text("Nothing in Settings matches that. Try a shorter word, like \u{201C}sync\u{201D} or \u{201C}hotkey.\u{201D}")
                        .font(.system(size: 14)).foregroundStyle(Refined.dim)
                }
                ForEach(counts, id: \.tab) { c in
                    SettingsGroup(title: c.tab.title) {
                        ForEach(results.filter { $0.section == c.tab }) { e in
                            SettingsResultRow(entry: e, terms: terms) { model.open(e) }
                                .uiWindowTarget("settings-result-\(results.firstIndex(of: e) ?? 0)")
                                .uiTarget("settings-result-\(results.firstIndex(of: e) ?? 0)")
                        }
                    }
                }
            }
            .padding(.horizontal, 56).padding(.top, 44).padding(.bottom, 40)
            .frame(maxWidth: 760 + 112, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A search result: the row's label and description with the query tinted, and a chevron.
struct SettingsResultRow: View {
    var entry: SettingsEntry
    var terms: [String]
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsIndex.highlighted(entry.label, terms: terms)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Refined.ink)
                if !entry.detail.isEmpty {
                    Text(SettingsIndex.highlighted(entry.detail, terms: terms)).font(.system(size: 12.5)).foregroundStyle(Refined.mute)
                        .lineSpacing(2).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Refined.faint)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 52)
        .background(Refined.stripe.opacity(hover ? 1 : 0))
        .overlay(alignment: .top) { RowRule() }
        .onHover { hover = $0 }
        .tapArea(action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(entry.section.title)")
    }
}

/// The menu bar's Thoughts group, at the top (mockup "Thoughts", section 04): New thought (⌃⌥P from any app), how many
/// thoughts today's page has, Open today's page, and Show the bubble.
///
/// It reads the library through Thoughts (`ThoughtCapture.app`), not AppState: as an environment object, AppState's every
/// publish (each screen change in the main window) re-rendered the group wherever it was built.
struct ThoughtsMenuSection: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var capture = ThoughtCapture.shared
    @AppStorage(Thoughts.bubbleKey) private var showBubble = Thoughts.bubbleDefault

    var body: some View {
        let _ = NavMarks.mark("menu-thoughts")
        let count = capture.app?.store.todaysThoughts().count ?? 0
        VStack(alignment: .leading, spacing: 2) {
            Text("Thoughts").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Refined.mute).padding(.horizontal, 8).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            row(capture.isRecording ? "Stop the thought" : "New thought", keys: Thoughts.hotkey, art: .iconThought) {
                dismiss()
                capture.toggle()
            }
            .uiTarget("menu-new-thought")
            Text("Today: \(DayPages.count(count, "thought", "thoughts"))").font(.system(size: 12.5)).foregroundStyle(Refined.mute)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .uiTarget("menu-today-count")
            row("Open today's page", keys: nil, art: nil) {
                dismiss()
                ThoughtPadController.shared.open()
            }
            .uiTarget("menu-open-page")
            // Today's note (Views/DayNote.swift): today's page in note mode, for ⌃⌥ dictation and Plan my day.
            row("Today's note", keys: nil, art: .iconBrainDump) {
                dismiss()
                DayNote.open()
            }
            .uiTarget("menu-brain-dump")
            row("Show the bubble", keys: nil, art: nil, checked: showBubble) {
                // The stored setting decides (the setter refreshes the bubble); the row's @AppStorage only draws the check.
                Thoughts.showBubble = !Thoughts.showBubble
            }
            .uiTarget("menu-show-bubble")
        }
        .padding(6)
        .background(Refined.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }

    private func row(_ title: String, keys: String?, art: BrandArt?, checked: Bool? = nil, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if let checked {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(checked ? 1 : 0).frame(width: 14)
            } else if let art {
                IconGlyph(art: art, size: 14, color: Refined.ink).frame(width: 14)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            if let keys { Text(keys).font(.system(size: 12)).foregroundStyle(Refined.mute) }
        }
        .foregroundStyle(Refined.ink)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .hoverChip(radius: Radius.button)
        .tapArea(action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(checked == true ? "On" : "")
    }
}

/// The menu bar panel: record from anywhere, jump back to the app.
struct MenuBarPanel: View {
    @Environment(AppState.self) var app
    /// Watched directly (AppState doesn't pass its changes on): something recording, and the last dictation.
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var capture: AppAudioCapture
    @EnvironmentObject private var dictation: DictationController

    var body: some View {
        NavMarks.mark("menubar")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BarsMark().frame(width: 16, height: 16)
                Refined.wordmark(17).accessibilityLabel("Verbose")
                Spacer()
                HStack(spacing: 5) { Keycap(keys: "⌥⇧R"); Text("to record").refinedFont(.meta) }.foregroundStyle(Refined.mute)
            }
            // Calls (CallViews.swift): Record a call, before the call starts.
            MenuBarCallsSection()
            ThoughtsMenuSection()
            if app.recorder.isRecording || app.capture.isCapturing {
                // The refined recording card, compact (RecordingStatus.swift).
                MenuBarRecordingRow()
            } else {
                Button { NSApp.activate(ignoringOtherApps: true); app.requestRecord() } label: {
                    HStack(spacing: 10) { RecordButton(size: 26); Text("Record a voice note").font(.system(size: 13, weight: .medium)); Spacer() }
                        .padding(10).background(Refined.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
                // Right-click: the six ways to record, as on Home's Record (CaptureBar.swift).
                .contextMenu { RecordKindMenuItems(activate: true) }
                Button { NSApp.activate(ignoringOtherApps: true); app.pickApp() } label: {
                    HStack(spacing: 10) {
                        ArtIcon(art: .iconVoice, size: 16).foregroundStyle(Refined.ink).frame(width: 26)
                        Text("Capture an app's audio").font(.system(size: 13, weight: .medium)); Spacer()
                    }
                    .padding(10).background(Refined.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
            }
            if let last = app.store.newestLive {
                Button { NSApp.activate(ignoringOtherApps: true); app.go(.transcript(last.id)) } label: {
                    HStack(spacing: 10) {
                        let style = HomeRecentStyle(last)
                        BrandGlyph(art: style.art, color: style.onTint, minLineWidth: 1.3).frame(width: 15, height: 15).frame(width: 26, height: 26)
                            .background(style.tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(last.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text("Last transcript · \(HomeRecentStyle.length(last.duration))").font(.system(size: 11)).foregroundStyle(Refined.mute)
                        }
                        Spacer()
                    }
                    .padding(10).background(Refined.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let last = app.dictation.lastResult, !last.isEmpty {
                Button { app.dictation.copyLast() } label: {
                    HStack(spacing: 8) { ArtIcon(art: .iconCopy, size: 16).foregroundStyle(Refined.ink).frame(width: 26); Text("Copy last dictation").font(.system(size: 12.5, weight: .medium)); Spacer() }
                        .padding(10).background(Refined.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Open Verbose") { NSApp.activate(ignoringOtherApps: true); app.go(.home) }.buttonStyle(.plain).foregroundStyle(Refined.ink).fontWeight(.medium)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Refined.mute)
            }
            .font(.system(size: 12.5))
        }
        .padding(12).frame(width: 320).background(Refined.paper)
    }
}
