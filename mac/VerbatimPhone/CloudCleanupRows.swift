import SwiftUI

/// Settings › Cloud cleanup (Dictation and keyboard): off by default. Your own Anthropic or OpenAI key, saved in this
/// iPhone's Keychain only (`CloudCleanup`, `CloudKeychain`). Shown on the Cloud cleanup page (SettingsPages.swift).
/// Part of Verbose Unlock (DESIGN.md §21): while locked, turning it on opens the unlock sheet, and a switch left on
/// from the trial says it waits for the unlock (`CloudCleanup.current` returns nothing meanwhile).
struct CloudCleanupRows: View {
    var searchFlash: String?
    @ObservedObject private var unlock = UnlockStore.shared
    @AppStorage(CloudCleanup.enabledKey) private var on = false
    @AppStorage(CloudCleanup.providerKey) private var providerRaw = CloudCleanup.Provider.anthropic.rawValue
    @State private var key = ""
    @State private var model = ""
    @State private var hasKey = false
    @State private var keyNote: String? = nil
    /// The provider waiting for your OK before Cloud cleanup turns on or switches to it (AR-11).
    @State private var asking: CloudCleanup.Provider? = nil

    private var provider: CloudCleanup.Provider { CloudCleanup.Provider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        SettingsToggleRow(title: "Cloud cleanup",
                          subtitle: !unlock.hasEverything ? UnlockCopy.cloudCleanupLocked : on ? CloudCleanup.privacyNote(provider) : "Off. Cleanup runs on this iPhone. Turning it on asks first.", isOn: onBinding)
            .settingsSearchTarget("cloudCleanup", flash: searchFlash)
            .onAppear {
                // On from a build that didn't ask: off until you say yes (5.1.2(i)).
                if on && !CloudCleanup.hasConsent(provider) { on = false }
                load()
            }
            .onChange(of: providerRaw) { _, _ in load() }
            // Explicit permission before any words go to the provider (guideline 5.1.2(i), App Review AR-11).
            .alert(asking.map(CloudCleanup.consentTitle) ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                   presenting: asking) { p in
                Button("Cancel", role: .cancel) {}
                Button("Turn on") {
                    CloudCleanup.giveConsent(p)
                    providerRaw = p.rawValue
                    on = true
                }
            } message: { p in
                Text(CloudCleanup.consentMessage(p, device: "iPhone"))
            }
        if on {
            SettingsDivider()
            Menu {
                Picker("Provider", selection: providerBinding) {
                    ForEach(CloudCleanup.Provider.allCases) { p in Text(p.title).tag(p.rawValue) }
                }
            } label: {
                SettingsRow(hue: .sage, art: .iconServer, title: "Provider") {
                    SettingsValue(provider.title); SettingsMenuMark()
                }
            }
            .buttonStyle(SettingsRowPress())
            .settingsSearchTarget("cloudProvider", flash: searchFlash)
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("API key").font(.system(size: 16)).foregroundStyle(Refined.ink)
                Text(keyNote ?? (hasKey ? "A key is saved in this iPhone's Keychain." : "Paste your own \(provider.company) API key. It's saved in this iPhone's Keychain only."))
                    .font(.system(size: 13)).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    SecureField(hasKey ? "Replace the saved key" : provider.keyPlaceholder, text: $key)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey {
                        Button("Remove", role: .destructive) {
                            CloudCleanup.deleteKey(for: provider); hasKey = false; keyNote = "Key removed."
                        }
                    }
                }
                Link("Get a key from \(provider.company)", destination: provider.keysURL).font(.system(size: 13))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .settingsSearchTarget("cloudKey", flash: searchFlash)
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Model").font(.system(size: 16)).foregroundStyle(Refined.ink)
                Text("Leave empty for \(provider.defaultModel).").font(.system(size: 13)).foregroundStyle(Refined.mute)
                TextField(provider.defaultModel, text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model) { _, m in CloudCleanup.setModel(m, for: provider) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .settingsSearchTarget("cloudModel", flash: searchFlash)
        }
    }

    /// The switch: turning it on asks first, until you've said yes to this provider.
    private var onBinding: Binding<Bool> {
        Binding(get: { on }, set: { v in
            if v && !FeatureGate.allows(.cloudCleanup, ask: true) { return }
            if v && !CloudCleanup.hasConsent(provider) { asking = provider } else { on = v }
        })
    }

    /// The provider menu: switching to one you haven't said yes to asks first.
    private var providerBinding: Binding<String> {
        Binding(get: { providerRaw }, set: { raw in
            let p = CloudCleanup.Provider(rawValue: raw) ?? .anthropic
            if on && !CloudCleanup.hasConsent(p) { asking = p } else { providerRaw = raw }
        })
    }

    private func load() {
        let p = provider
        hasKey = CloudCleanup.hasKey(p)
        let m = CloudCleanup.model(for: p)
        model = m == p.defaultModel ? "" : m
        key = ""
        keyNote = nil
    }

    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        if CloudCleanup.saveKey(k, for: provider) {
            hasKey = true; keyNote = "Key saved in this iPhone's Keychain."
        } else {
            keyNote = "Couldn't save the key. Try again."
        }
        key = ""
    }
}
