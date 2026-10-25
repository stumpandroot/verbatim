import SwiftUI

/// Settings › Appearance (the native mockup's section 04), modeled on Display & Brightness: the look picker with two
/// live thumbnails, then light or dark, then Limit animation (moved here from Personalization). Both looks use this
/// layout, each in its own clothes. Picking a look applies it at once, no relaunch: a small card in the new look shows
/// while the screens rebuild behind it, then fades (LookSwitch.swift). The look is stored per device in the App Group (`AppLook`), so the keyboard
/// follows it; it never syncs.
struct AppearanceScreen: View {
    @EnvironmentObject var app: PhoneState
    @AppStorage(AppLook.key, store: AppLook.store) private var lookRaw = AppLook.verbose.rawValue
    @AppStorage(MotionPreference.key) private var motionLimited = false
    /// Premium Native's Record card on Home (PremiumHome.swift): off unless turned on here.
    @AppStorage(PremiumHome.recordCardKey) private var recordCard = false
    @Environment(\.look) private var look
    /// Whether Appearance is on screen, for the UI tour's checks.
    static var visible = false

    static let lookNote = "How Verbose looks on this iPhone. Your Mac has its own setting. The Verbose keyboard uses the same look."

    private var selection: Binding<AppLook> {
        // The switching card shows first, then the look is stored behind it (LookSwitch.swift).
        Binding(get: { AppLook(rawValue: lookRaw) ?? .verbose }, set: { LookSwitch.shared.pick($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !look.isNative {
                    PhoneCompactTitle(title: "Appearance").padding(.top, 2)
                }
                section("Look", footer: Self.lookNote) {
                    LookPicker(selection: selection)
                        .padding(.vertical, 16)
                }
                .padding(.top, look.isNative ? 8 : 18)
                section("Light or dark") {
                    ForEach(Array(Self.modes.enumerated()), id: \.element.0) { i, mode in
                        if i > 0 { divider }
                        Button { app.appearance = mode.0 } label: {
                            HStack {
                                Text(mode.1).font(.system(size: look.isNative ? 17 : 16)).foregroundStyle(.lookInk)
                                Spacer(minLength: 8)
                                if app.appearance == mode.0 {
                                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.lookAccentText)
                                }
                            }
                            .padding(.horizontal, look.isNative ? 16 : 14).frame(minHeight: look.isNative ? 46 : 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SettingsRowPress())
                        .accessibilityAddTraits(app.appearance == mode.0 ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.top, 26)
                section("Motion", footer: look.isNative ? "Fades instead of movement; illustrations stay still." : nil) {
                    SettingsToggleRow(icon: "tortoise", tint: Ink.sageTint, art: .iconLimitMotion, title: "Limit animation",
                                      subtitle: look.isNative ? nil : "Fades instead of movement; illustrations stay still.",
                                      isOn: $motionLimited)
                }
                .padding(.top, 26)
                // Native's Home leads with This week and the floating record button; the Record card is optional.
                if look.isNative {
                    section("Home", footer: "The record button beside the tab bar always starts a voice note.") {
                        SettingsToggleRow(icon: "record.circle", tint: Ink.persimmonTint, art: .capture, title: "Show the Record card",
                                          subtitle: nil, isOn: $recordCard)
                    }
                    .padding(.top, 26)
                }
            }
            .padding(.horizontal, look.isNative ? 16 : 20).padding(.bottom, 32)
        }
        .phonePage()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Verbose style puts the serif title on the paper.
            if !look.isNative {
                ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
            }
        }
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    static let modes: [(String, String)] = [("system", "Match the system"), ("light", "Light"), ("dark", "Dark")]

    @ViewBuilder private var divider: some View {
        if look.isNative { NativeDivider() } else { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 14) }
    }

    /// A group in the look's clothes: Native's inset grouped card, or Verbose style's mono label over a card with a
    /// hairline edge (as on Settings).
    @ViewBuilder private func section<Rows: View>(_ title: String, footer: String? = nil, @ViewBuilder _ rows: () -> Rows) -> some View {
        if look.isNative {
            let content = rows()
            NativeGroup(header: title, footer: footer) { content }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Ink.mono(12)).foregroundStyle(Ink.mute)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) { rows() }
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.record, style: .continuous).strokeBorder(Ink.hairline))
                if let footer {
                    Text(footer).font(.system(size: 13)).foregroundStyle(Ink.mute)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}
