import SwiftUI

/// Settings: iCloud status, transcription quality, appearance, and the Dictionary.
struct SettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        Form {
            Section("Sync") {
                Label(Cloud.enabled ? "Syncing with iCloud" : "iCloud is off", systemImage: Cloud.enabled ? "icloud" : "icloud.slash")
                Text(Cloud.enabled ? "Transcripts, notes, bookmarks, projects, and the Dictionary match your Mac. Audio from the other device downloads when you play it." : "Sign in to iCloud in the Settings app to sync with your Mac. Until then, everything stays on this iPhone.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
            Section("Transcription") {
                Picker("Quality", selection: $app.presetRaw) {
                    ForEach(QualityPreset.allCases.filter { $0 != .advanced }) { p in Text(p.title).tag(p.rawValue) }
                }
                Text(app.preset.note).font(.system(size: 13)).foregroundStyle(Ink.mute)
                Toggle("Identify speakers", isOn: $app.identifySpeakers).tint(Ink.switchOn)
                Toggle("Apply Dictionary", isOn: $app.applyDictionary).tint(Ink.switchOn)
                Text("Transcription runs on this iPhone. The first time, the model downloads once (about 200–600 MB). Links are fetched by your Mac.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
            Section("Appearance") {
                Picker("Appearance", selection: $app.appearance) {
                    Text("Match the system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
            }
            Section("Welcome tour") {
                Toggle("Show it when Verbatim opens", isOn: Binding(get: { Onboarding.showOnLaunch }, set: { Onboarding.showOnLaunch = $0; app.objectWillChange.send() }))
                    .tint(Ink.switchOn)
                Button("Show Tour") { app.showOnboarding = true }
            }
            Section("Dictionary") {
                NavigationLink { DictionaryScreen() } label: { LabeledContent("Words", value: "\(app.store.dictionary.count)") }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            } footer: { Text("Verbatim · Stump & Root Co.") }
        }
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Settings")
    }
}
