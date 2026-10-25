import SwiftUI

/// Settings › Transcription › Cloud cleanup: off by default. Your own Anthropic or OpenAI key, saved in this
/// iPhone's Keychain only (`CloudCleanup`, `CloudKeychain`). Shown under the Cleanup row.
struct CloudCleanupRows: View {
    var searchFlash: String?
    @AppStorage(CloudCleanup.enabledKey) private var on = false
    @AppStorage(CloudCleanup.providerKey) private var providerRaw = CloudCleanup.Provider.anthropic.rawValue
    @State private var key = ""
    @State private var model = ""
    @State private var hasKey = false
    @State private var keyNote: String? = nil

    private var provider: CloudCleanup.Provider { CloudCleanup.Provider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        SettingsToggleRow(icon: "cloud", tint: Ink.sageTint, art: .iconSync, title: "Cloud cleanup",
                          subtitle: on ? CloudCleanup.privacyNote(provider) : "Off. Cleanup runs on this iPhone.", isOn: $on)
            .settingsSearchTarget("cloudCleanup", flash: searchFlash)
            .onAppear(perform: load)
            .onChange(of: providerRaw) { _, _ in load() }
        if on {
            SettingsDivider()
            Menu {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(CloudCleanup.Provider.allCases) { p in Text(p.title).tag(p.rawValue) }
                }
            } label: {
                SettingsRow(icon: "server.rack", tint: Ink.sageTint, art: .iconServer, title: "Provider", bounce: providerRaw) {
                    SettingsValue(provider.title); SettingsMenuMark()
                }
            }
            .buttonStyle(SettingsRowPress())
            .settingsSearchTarget("cloudProvider", flash: searchFlash)
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("API key").font(.system(size: 16)).foregroundStyle(.lookInk)
                Text(keyNote ?? (hasKey ? "A key is saved in this iPhone's Keychain." : "Paste your own \(provider.company) API key. It's saved in this iPhone's Keychain only."))
                    .font(.system(size: 13)).foregroundStyle(.lookMute).fixedSize(horizontal: false, vertical: true)
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
                Text("Model").font(.system(size: 16)).foregroundStyle(.lookInk)
                Text("Leave empty for \(provider.defaultModel).").font(.system(size: 13)).foregroundStyle(.lookMute)
                TextField(provider.defaultModel, text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model) { _, m in CloudCleanup.setModel(m, for: provider) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .settingsSearchTarget("cloudModel", flash: searchFlash)
        }
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
