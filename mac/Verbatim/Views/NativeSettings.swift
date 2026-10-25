import SwiftUI
import AppKit

// brand: native file
//
// The Settings window in the Native look (mockup section 03, "Settings window"): System Settings' layout. A sidebar
// with the search field on top and the App, Transcription, and Files groups, each pane with its SF Symbol; the pane
// is the same SettingsPane, which draws as a grouped form under Native (SettingsKit.swift).

struct NativeSettingsSplit<Detail: View>: View {
    @Binding var tab: SettingsTab
    @ViewBuilder var detail: () -> Detail
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SettingsTab.groups, id: \.title) { g in
                    Section(g.title) {
                        ForEach(g.tabs) { t in
                            Label(t.title, systemImage: NativeSymbols.settings(t.rawValue))
                                .uiTarget("settings-\(t.rawValue)")
                                .tag(t)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $model.query, placement: .sidebar, prompt: "Search")
            .onSubmit(of: .search) { if let first = SettingsIndex.search(model.query).first { model.open(first) } }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(NativeInk.window)
        }
        .toolbar(removing: .sidebarToggle)
        .onExitCommand { if model.isSearching { model.query = "" } }
    }

    /// The selected pane; choosing one clears a search, as System Settings does.
    private var selection: Binding<SettingsTab?> {
        Binding(get: { model.isSearching ? nil : tab }, set: { t in
            guard let t else { return }
            if model.isSearching { model.query = "" }
            if limitMotion { tab = t } else { withAnimation(Motion.snap) { tab = t } }
        })
    }
}
