import SwiftUI
import AppKit

// brand: native file
//
// The Settings window in the Native look (premium mockup section 02, "Mac Settings window"): System Settings' layout. A
// sidebar with the search field on top, the panes of MacSettingsMap, each with its SF Symbol, and the version at the
// foot, which opens What's new; the pane is the same SettingsPane, which draws as a grouped form under Native
// (SettingsKit.swift).

struct NativeSettingsSplit<Detail: View>: View {
    @Binding var tab: SettingsTab
    @ViewBuilder var detail: () -> Detail
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SettingsTab.sidebar) { t in
                    Label(t.sidebarTitle, systemImage: NativeSymbols.settings(t.rawValue))
                        .uiTarget("settings-\(t.rawValue)")
                        .tag(t)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsVersionFooter {
                    if model.isSearching { model.query = "" }
                    tab = .whatsNew
                }
                .padding(.horizontal, 4).padding(.bottom, 10)
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: "Search")
            .onSubmit(of: .search) { if let first = SettingsIndex.search(model.query).first { model.open(first) } }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 290)
            // On the sidebar column itself, where it takes effect: on the split view alone it left a second toggle
            // under the traffic lights and a toolbar's height of empty space above every pane's title.
            .toolbar(removing: .sidebarToggle)
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
