import SwiftUI
import AppKit

// brand: native file
//
// The Settings window in the Native look (mockup "Verbose Native Redesign", section 10): System Settings' layout. A
// glass sidebar with the search field on top and the panes of MacSettingsMap, each a white glyph on a colored square in
// a system color (`NativeSettingsSquare`; never red, which stays with recording), the selected pane in the accent, and
// the pane's title in the toolbar over a grouped form (SettingsPane draws as one under Native, SettingsKit.swift). The
// version and What's new live in Support and feedback, as System Settings keeps About in General.

struct NativeSettingsSplit<Detail: View>: View {
    @Binding var tab: SettingsTab
    @ViewBuilder var detail: () -> Detail
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SettingsTab.sidebar) { t in
                    Label { Text(t.sidebarTitle) } icon: { NativeSettingsIcon(tab: t) }
                        .uiTarget("settings-\(t.rawValue)")
                        .tag(t)
                }
            }
            .listStyle(.sidebar)
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
                // The pane's title in the toolbar, as System Settings shows it.
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Text(model.isSearching ? "Search Results" : tab.title)
                            .font(.system(size: 15, weight: .bold)).lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                            .uiWindowTarget("settings-title")
                    }
                }
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

/// A Settings pane's icon: its white SF Symbol on a rounded square in a system color, as System Settings draws its
/// sidebar.
struct NativeSettingsIcon: View {
    var tab: SettingsTab
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: NativeSymbols.settings(tab.rawValue))
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Self.color(NativeSettingsSquare.tint(tab.rawValue))))
            .accessibilityHidden(true)
    }

    /// The system color for a square's tint (the system's own, so it follows light, dark, and Increase Contrast).
    static func color(_ tint: NativeSettingsSquare.Tint) -> Color {
        let ns: NSColor
        switch tint {
        case .blue: ns = .systemBlue
        case .orange: ns = .systemOrange
        case .gray: ns = .systemGray
        case .indigo: ns = .systemIndigo
        case .purple: ns = .systemPurple
        case .teal: ns = .systemTeal
        case .cyan: ns = .systemCyan
        case .green: ns = .systemGreen
        case .pink: ns = .systemPink
        case .brown: ns = .systemBrown
        case .mint: ns = .systemMint
        case .yellow: ns = .systemYellow
        }
        return Color(nsColor: ns)
    }
}
