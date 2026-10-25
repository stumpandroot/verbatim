import SwiftUI
import AppKit

// Website style (DESIGN.md §11) for the Settings window; not marked `brand: web style` because the menu bar panel
// below keeps its small keycap.

/// The Settings window: a paper sidebar (search on top, then the panes of MacSettingsMap, each with its glyph, and the
/// version at the foot, which opens What's new) and the chosen pane. Typing in search swaps the sidebar for the panes
/// with matches and shows every matching setting; a result opens its pane and flashes the row. ⌘F focuses search;
/// Esc clears it.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @AppStorage("settingsTab") private var tab: SettingsTab = .personalization
    @ObservedObject private var model = SettingsModel.shared
    @FocusState private var searchFocused: Bool
    @Environment(\.look) private var look

    var body: some View {
        Group {
            if look == .native {
                // Native: System Settings' layout, a sidebar with SF Symbols and a grouped form (NativeSettings.swift).
                NativeSettingsSplit(tab: $tab) {
                    if model.isSearching { SettingsSearchResults() } else { pane.id(tab) }
                }
                .frame(minWidth: 820, idealWidth: 920, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
                .lookTint(look)
            } else {
                verbose
            }
        }
        .lookRebuild()
        .background(WindowReader { w in configure(w) })
    }

    private var verbose: some View {
        HStack(spacing: 0) {
            SettingsSidebar(tab: $tab, searchFocused: $searchFocused)
                .frame(width: 230)
            Group {
                if model.isSearching {
                    SettingsSearchResults()
                } else {
                    pane.id(tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Ink.paper)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 820, idealWidth: 920, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .foregroundStyle(Ink.ink)
        .tint(Ink.switchOn)   // switches in brand sage instead of the system blue
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
        case .actions: ActionSettings()
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

    /// The page runs under a transparent title bar, like the main window, so the sidebar reaches the top edge.
    private func configure(_ w: NSWindow) {
        SettingsModel.shared.window = w
        guard !w.styleMask.contains(.fullSizeContentView) || w.titleVisibility != .hidden else { return }
        w.styleMask.insert(.fullSizeContentView)
        w.styleMask.insert(.resizable)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Settings"
        w.backgroundColor = NSColor(Ink.paper)
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Binding var tab: SettingsTab
    var searchFocused: FocusState<Bool>.Binding
    @ObservedObject private var model = SettingsModel.shared
    @Namespace private var plate
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            searchField.padding(.bottom, 6)
            if model.isSearching {
                let results = SettingsIndex.search(model.query)
                let counts = SettingsIndex.sectionCounts(results)
                groupLabel("Sections with matches", first: true)
                if counts.isEmpty {
                    Text("No matches").font(.system(size: 13)).foregroundStyle(Ink.mute).padding(.horizontal, 12).padding(.vertical, 7)
                }
                ForEach(Array(counts.enumerated()), id: \.element.tab) { i, c in
                    SettingsSideItem(title: c.tab.title, count: c.count, selected: i == 0, plate: plate) {
                        if let first = results.first(where: { $0.section == c.tab }) { model.open(first) }
                    }
                    .uiTarget("settings-match-\(c.tab.rawValue)")
                }
                Spacer(minLength: 12)
                Text("Press Esc to clear the search.").font(.system(size: 12)).foregroundStyle(Ink.mute).padding(.horizontal, 12)
            } else {
                ForEach(SettingsTab.sidebar) { t in
                    SettingsSideItem(title: t.title, art: t.art, selected: tab == t, plate: plate) { select(t) }
                        .uiTarget("settings-\(t.rawValue)")
                }
                Spacer(minLength: 12)
                SettingsVersionFooter { select(.whatsNew) }
            }
        }
        .padding(.horizontal, 14).padding(.top, 48).padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(SidebarPaper())
    }

    private func select(_ t: SettingsTab) {
        if limitMotion { tab = t } else { withAnimation(Motion.snap) { tab = t } }
    }

    /// The mono label over search matches.
    private func groupLabel(_ text: String, first: Bool) -> some View {
        Text(text).font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1)
            .padding(.horizontal, 12).padding(.top, first ? 10 : 16).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    /// The website's pill search field: card white with an ink outline, a little heavier while you type.
    private var searchField: some View {
        let active = searchFocused.wrappedValue || model.isSearching
        return HStack(spacing: 8) {
            IconGlyph(art: .search, size: 15, color: Ink.mute)
            TextField("Search settings", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused(searchFocused)
                .onExitCommand { model.query = "" }
                .onSubmit { if let first = SettingsIndex.search(model.query).first { model.open(first) } }
                .accessibilityLabel("Search settings")
            if model.isSearching {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Ink.mute) }
                    .buttonStyle(.plain).help("Clear the search (Esc)").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).frame(height: 34)
        .background(Ink.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: active ? 2 : 1.5))
        .animation(Motion.touch, value: active)
        .uiTarget("settings-search")
    }
}

/// A sidebar row (website style): a rounded row in dim text; under the pointer it takes the soft chip wash; selected,
/// it's semibold ink on the card fill with the ink outline and a small hard shadow, and that plate slides between rows.
struct SettingsSideItem: View {
    var title: String
    /// The pane's glyph (none for search matches).
    var art: BrandArt? = nil
    var count: Int? = nil
    var selected: Bool
    var plate: Namespace.ID
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 9) {
            if let art { IconGlyph(art: art, size: 16, color: selected ? Ink.ink : Ink.dim).accessibilityHidden(true) }
            Text(title).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            if let count { Text("\(count)").font(Ink.mono(12)).foregroundStyle(Ink.mute) }
        }
        .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Ink.ink : Ink.dim)
        .padding(.horizontal, 12).frame(height: 32)
        .background {
            if selected {
                shape.fill(Ink.card)
                    .inkEdge(outline: true, shadow: CGSize(width: 2, height: 3), radius: 16)
                    .matchedGeometryEffect(id: "settings-selection", in: plate)
            } else {
                shape.fill(Ink.chip).opacity(hover ? 1 : 0)
            }
        }
        .contentShape(shape)
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .tapArea(action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(count.map { "\(title), \($0) match\($0 == 1 ? "" : "es")" } ?? title)
    }
}

/// The foot of the Settings sidebar: the version, and What's new, which opens the release notes pane.
struct SettingsVersionFooter: View {
    var open: () -> Void
    @ObservedObject private var updater = Updater.shared
    @Environment(\.look) private var look

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(updater.version) (\(updater.build))")
                    .font(look == .native ? .system(size: 11) : Ink.mono(12)).foregroundStyle(Ink.mute)
                Text("What's new").font(.system(size: look == .native ? 11 : 12.5, weight: .semibold))
                    .foregroundStyle(look == .native ? Ink.nativeAccent : Ink.accentText)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Version \(updater.version), build \(updater.build). What's new")
        .accessibilityAddTraits(.isButton)
        .help("What each build of Verbose added")
        .uiTarget("settings-version")
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
            VStack(alignment: .leading, spacing: 22) {
                SettingsPaneHeader(overline: "\(results.count) result\(results.count == 1 ? "" : "s")",
                                   title: "“\(model.query.trimmingCharacters(in: .whitespaces))”")
                if results.isEmpty {
                    Text("Nothing in Settings matches that. Try a shorter word, like “sync” or “hotkey.”")
                        .font(.system(size: 14)).foregroundStyle(Ink.dim)
                }
                ForEach(counts, id: \.tab) { c in
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: c.tab.title)
                            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(results.filter { $0.section == c.tab }) { e in
                                SettingsResultRow(entry: e, terms: terms) { model.open(e) }
                                    .uiTarget("settings-result-\(results.firstIndex(of: e) ?? 0)")
                            }
                        }
                        .padding(.top, -1)
                        .settingsCard()
                    }
                }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 36)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A search result: the pane row's bold label and dim detail, with "Open →" as a line mini pill on the right.
struct SettingsResultRow: View {
    var entry: SettingsEntry
    var terms: [String]
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(SettingsIndex.highlighted(entry.label, terms: terms)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                if !entry.detail.isEmpty {
                    Text(SettingsIndex.highlighted(entry.detail, terms: terms)).font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                        .lineSpacing(2).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PillLabel(title: "Open", kind: .line, size: .mini, trailing: .arrow, hover: hover)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(minHeight: 60)
        .background(Ink.ink.opacity(hover ? 0.035 : 0))
        .overlay(alignment: .top) { RowRule() }
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .tapArea(action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(entry.section.title)")
    }
}

struct ElapsedText: View {
    @ObservedObject var live: LiveMeter
    var body: some View { Text(live.elapsed.timecode).font(.system(size: 13, design: .monospaced)) }
}

/// The menu bar panel: record from anywhere, jump back to the app.
struct MenuBarPanel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BarsMark().frame(width: 16, height: 16)
                Ink.wordmark(17).accessibilityLabel("Verbose")
                Spacer()
                HStack(spacing: 5) { Keycap(keys: "⌥⇧R", size: 10.5); Text("to record") }.font(.system(size: 11)).foregroundStyle(Ink.mute)
            }
            if app.recorder.isRecording {
                HStack(spacing: 10) {
                    RecordButton(size: 22)
                    ElapsedText(live: app.recorder.live)
                    Spacer()
                    Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }
                    Button("Stop") { app.stopRecording() }.buttonStyle(.brandPrimary)
                }
                .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            } else if app.capture.isCapturing {
                HStack(spacing: 10) {
                    ArtIcon(art: .iconVoice, size: 16).foregroundStyle(Ink.iris)
                    HStack(spacing: 4) { Text("Capturing \(app.capture.appName) ·").font(.system(size: 12.5)); ElapsedText(live: app.capture.live) }
                    Spacer()
                    Button("Stop") { app.stopCapture() }.buttonStyle(.brandPrimary)
                }
                .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            } else {
                Button { NSApp.activate(ignoringOtherApps: true); app.requestRecord() } label: {
                    HStack(spacing: 10) { RecordButton(size: 26); Text("Record voice memo").font(.system(size: 13, weight: .medium)); Spacer() }
                        .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
                Button { NSApp.activate(ignoringOtherApps: true); app.pickApp() } label: {
                    HStack(spacing: 10) {
                        ArtIcon(art: .iconVoice, size: 16).foregroundStyle(Ink.iris).frame(width: 26)
                        Text("Capture an app's audio").font(.system(size: 13, weight: .medium)); Spacer()
                    }
                    .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
            }
            if let last = app.store.live.first {
                Button { NSApp.activate(ignoringOtherApps: true); app.go(.transcript(last.id)) } label: {
                    HStack(spacing: 10) {
                        let style = HomeRecentStyle(last)
                        BrandGlyph(art: style.art, color: style.onTint, minLineWidth: 1.3).frame(width: 15, height: 15).frame(width: 26, height: 26)
                            .background(style.tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(last.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text("Last transcript · \(HomeRecentStyle.length(last.duration))").font(.system(size: 11)).foregroundStyle(Ink.mute)
                        }
                        Spacer()
                    }
                    .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let last = app.dictation.lastResult, !last.isEmpty {
                Button { app.dictation.copyLast() } label: {
                    HStack(spacing: 8) { ArtIcon(art: .iconCopy, size: 16).foregroundStyle(Ink.iris).frame(width: 26); Text("Copy last dictation").font(.system(size: 12.5, weight: .medium)); Spacer() }
                        .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Open Verbose") { NSApp.activate(ignoringOtherApps: true); app.go(.home) }.buttonStyle(.plain).foregroundStyle(Ink.iris).fontWeight(.medium)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Ink.mute)
            }
            .font(.system(size: 12.5))
        }
        .padding(12).frame(width: 320).background(Ink.paper)
    }
}
