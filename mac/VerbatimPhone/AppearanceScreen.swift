import SwiftUI

/// Settings › Appearance in the refined look (DESIGN.md §13), one layout in both look settings: the look as one plain
/// row with a menu (Verbose style or Native; it retires with the look switch), the palette (Full or Soft), then light
/// or dark (Limit animation is a switch on the Settings root). Picking a look applies it at once, no relaunch: a small
/// card in the new look shows while the screens rebuild behind it, then fades (LookSwitch.swift). The look is stored
/// per device in the App Group (`AppLook`), so the keyboard follows it; it never syncs.
struct AppearanceScreen: View {
    @EnvironmentObject var app: PhoneState
    @AppStorage(AppLook.key, store: AppLook.store) private var lookRaw = AppLook.verbose.rawValue
    /// The refined look's palette (DESIGN.md §13), stored with the look in the App Group.
    @AppStorage(AppPalette.key, store: AppLook.store) private var palette: AppPalette = .full
    /// Whether Appearance is on screen, for the UI tour's checks.
    static var visible = false

    static let lookNote = "How Verbose looks on this iPhone. Your Mac has its own setting. The Verbose keyboard uses the same look."
    static let paletteNote = "How much color the Record card and Home's tiles carry. Kind badges and speaker chips keep their colors."

    private var current: AppLook { AppLook(rawValue: lookRaw) ?? .verbose }

    var body: some View {
        SettingsPageScaffold(title: "Appearance") {
            SettingsPageGroup(title: "Look", footer: Self.lookNote, first: true) {
                // A plain row with the system menu: the switching card shows first, then the look is stored behind it.
                Menu {
                    Picker("Look", selection: Binding(get: { current }, set: { if $0 != current { LookSwitch.shared.pick($0) } })) {
                        ForEach(AppLook.allCases) { l in Text(l.label).tag(l) }
                    }
                } label: {
                    SettingsRow(hue: RefinedRules.settingsHue(0), art: .iconAppearance, title: "Look") {
                        SettingsValue(current.label); SettingsMenuMark()
                    }
                }
                .buttonStyle(SettingsRowPress())
                .accessibilityHint("Shows the looks")
                .settingsSearchTarget("look", flash: nil)
            }
            SettingsPageGroup(title: "Palette", footer: Self.paletteNote) {
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
        .onAppear { Self.visible = true; LookSwitch.prewarm() }
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
