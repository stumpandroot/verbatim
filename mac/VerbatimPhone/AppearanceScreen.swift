import SwiftUI

/// Settings › Appearance (DESIGN.md §13): the palette (Full or Soft), then light or dark (Limit animation is a switch
/// on the Settings root). The palette is stored per device in the App Group (`AppearanceStore`); it never syncs.
struct AppearanceScreen: View {
    @EnvironmentObject var app: PhoneState
    /// The palette (DESIGN.md §13), stored in the App Group.
    @AppStorage(AppPalette.key, store: AppearanceStore.defaults) private var palette: AppPalette = .full
    /// Whether Appearance is on screen, for the UI tour's checks.
    static var visible = false

    static let paletteNote = "How much color the Record card and Home's tiles carry. Kind badges and speaker chips keep their colors."

    var body: some View {
        SettingsPageScaffold(title: "Appearance") {
            SettingsPageGroup(title: "Palette", footer: Self.paletteNote, first: true) {
                ForEach(Array(AppPalette.allCases.enumerated()), id: \.element) { i, p in
                    if i > 0 { SettingsDivider() }
                    choiceRow(p.label, detail: p.detail, chosen: palette == p) { palette = p }
                }
            }
            .settingsSearchTarget("palette", flash: nil)
            SettingsPageGroup(title: "Light or dark") {
                ForEach(Array(Self.modes.enumerated()), id: \.element.0) { i, mode in
                    if i > 0 { SettingsDivider() }
                    choiceRow(mode.1, detail: nil, chosen: app.appearance == mode.0) { app.appearance = mode.0 }
                }
            }
            .settingsSearchTarget("appearance", flash: nil)
        }
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    static let modes: [(String, String)] = [("system", "Match the system"), ("light", "Light"), ("dark", "Dark")]

    /// One choice in a list: its name and line, and the accent's checkmark on the chosen one.
    private func choiceRow(_ title: String, detail: String?, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsRowText(title: title, subtitle: detail)
                Spacer(minLength: 8)
                if chosen {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Refined.accentText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPress())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}
