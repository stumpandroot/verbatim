import SwiftUI
import AppKit

/// The Settings window: a paper sidebar (search on top, then App, Transcription, and Files groups) and the
/// chosen pane. Typing in search swaps the sidebar for the panes with matches and shows every matching setting;
/// a result opens its pane and flashes the row. ⌘F focuses search; Esc clears it.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @AppStorage("settingsTab") private var tab: SettingsTab = .general
    @ObservedObject private var model = SettingsModel.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(tab: $tab, searchFocused: $searchFocused)
                .frame(width: 250)
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
        .background(WindowReader { w in configure(w) })
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case .general: GeneralSettingsPane()
        case .dictate: DictationSettings()
        case .floatingButton: FloatingButtonSettingsPane()
        case .actions: ActionSettings()
        case .privacy: PrivacySettingsPane()
        case .models: ModelsSettingsPane()
        case .speakers: SpeakersSettingsPane()
        case .captions: CaptionsSettingsPane()
        case .watched: WatchedFoldersPane()
        case .export: ExportSettingsPane()
        case .storage: StorageSettingsPane()
        case .about: AboutSettingsPane()
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
    @Namespace private var tick
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            searchField.padding(.bottom, 12)
            if model.isSearching {
                let results = SettingsIndex.search(model.query)
                let counts = SettingsIndex.sectionCounts(results)
                overline("Sections with matches", first: true)
                if counts.isEmpty {
                    Text("No matches").font(.system(size: 13)).foregroundStyle(Ink.mute).padding(.horizontal, 10).padding(.vertical, 7)
                }
                ForEach(Array(counts.enumerated()), id: \.element.tab) { i, c in
                    SettingsSideItem(title: c.tab.title, count: c.count, selected: i == 0, tick: tick, showsTick: false) {
                        if let first = results.first(where: { $0.section == c.tab }) { model.open(first) }
                    }
                    .uiTarget("settings-match-\(c.tab.rawValue)")
                }
                Spacer(minLength: 12)
                Text("Press Esc to clear the search.").font(.system(size: 12)).foregroundStyle(Ink.mute).padding(.horizontal, 10)
            } else {
                ForEach(Array(SettingsTab.groups.enumerated()), id: \.element.title) { gi, g in
                    overline(g.title, first: gi == 0)
                    ForEach(g.tabs) { t in
                        SettingsSideItem(title: t.title, selected: tab == t, tick: tick) {
                            if limitMotion { tab = t } else { withAnimation(Motion.snap) { tab = t } }
                        }
                        .uiTarget("settings-\(t.rawValue)")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(SidebarPaper())
    }

    private func overline(_ text: String, first: Bool) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
            .padding(.horizontal, 10).padding(.top, first ? 6 : 12).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private var searchField: some View {
        let active = searchFocused.wrappedValue || model.isSearching
        return HStack(spacing: 8) {
            IconGlyph(art: .search, size: 14, color: Ink.mute)
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
        .padding(.horizontal, 10).frame(height: 32)
        .background(active ? Ink.card : Ink.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.persimmon, lineWidth: active ? 1.5 : 0))
        .animation(Motion.touch, value: active)
        .uiTarget("settings-search")
    }
}

/// A sidebar row: semibold with a persimmon tick at the window edge when selected, a light ink tint on hover.
struct SettingsSideItem: View {
    var title: String
    var count: Int? = nil
    var selected: Bool
    var tick: Namespace.ID
    var showsTick = true
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer(minLength: 6)
            if let count { Text("\(count)").fontWeight(.regular).foregroundStyle(Ink.mute) }
        }
        .font(.system(size: 13.5))
        .fontWeight(selected ? .semibold : .regular)
        .foregroundStyle(selected ? Ink.ink : Ink.dim)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Ink.ink.opacity(hover && !selected ? 0.06 : 0)))
        .overlay(alignment: .leading) {
            if selected && showsTick {
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 2, topTrailingRadius: 2)
                    .fill(Ink.persimmon).frame(width: 3, height: 17).offset(x: -12)
                    .matchedGeometryEffect(id: "settings-tick", in: tick)
            }
        }
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .tapArea(action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(count.map { "\(title), \($0) match\($0 == 1 ? "" : "es")" } ?? title)
    }
}

// MARK: - Search results

/// Every matching setting, grouped by pane, with the query tinted in each label and description.
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Diamond().stroke(Ink.mute, lineWidth: 1).frame(width: 7, height: 7)
                            Text(c.tab.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
                        }
                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                        SettingsGroup {
                            ForEach(results.filter { $0.section == c.tab }) { e in
                                SettingsResultRow(entry: e, terms: terms) { model.open(e) }
                                    .uiTarget("settings-result-\(results.firstIndex(of: e) ?? 0)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 48).padding(.top, 40).padding(.bottom, 40)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsResultRow: View {
    var entry: SettingsEntry
    var terms: [String]
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(SettingsIndex.highlighted(entry.label, terms: terms)).font(.system(size: 14)).foregroundStyle(Ink.ink)
                if !entry.detail.isEmpty {
                    Text(SettingsIndex.highlighted(entry.detail, terms: terms)).font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Open →").font(.system(size: 13)).foregroundStyle(Ink.accentText)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Ink.ink.opacity(hover ? 0.04 : 0))
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
                Text("Verbatim").font(Ink.serif(17))
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
                Button("Open Verbatim") { NSApp.activate(ignoringOtherApps: true); app.go(.home) }.buttonStyle(.plain).foregroundStyle(Ink.iris).fontWeight(.medium)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Ink.mute)
            }
            .font(.system(size: 12.5))
        }
        .padding(12).frame(width: 320).background(Ink.paper)
    }
}
