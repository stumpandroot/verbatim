import SwiftUI
import AppKit

// The Settings panes (SettingsView.swift holds the window). Every row's label and description come from
// SettingsIndex, so search always matches what's on screen.

// MARK: - App › General

struct GeneralSettingsPane: View {
    @EnvironmentObject var app: AppState
    @AppStorage(MotionPreference.key) private var motionLimited = false

    var body: some View {
        SettingsPane(tab: .general) {
            SettingsGroup {
                SettingsRow("general.appearance") {
                    Picker("Appearance", selection: Binding(get: { app.appearance }, set: { app.appearance = $0; app.applyAppearance() })) {
                        Text("Match the system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsToggleRow("general.limitMotion", isOn: $motionLimited)
                SettingsToggleRow("general.menuBar", isOn: $app.showMenuBar)
                SettingsToggleRow("general.sounds", isOn: $app.sounds)
            }
            SettingsGroup(title: "Welcome") {
                SettingsToggleRow("general.welcomeCard", isOn: Binding(get: { app.showWelcomeCard }, set: { app.showWelcomeCard = $0 }))
                SettingsToggleRow("general.tourOnLaunch", isOn: Binding(get: { Onboarding.showOnLaunch }, set: { Onboarding.showOnLaunch = $0 }))
                SettingsRow("general.tour") { Button("Show Tour") { app.showOnboarding = true }.buttonStyle(.brandSecondary) }
            }
            UpdateSettingsSection()
        }
    }
}

/// General › Updates: Sparkle automatic updates (App/Updater.swift).
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        SettingsGroup(title: "Updates",
                      footer: updater.isRunning ? nil : "Automatic updates are off in this build.") {
            SettingsToggleRow("general.autoUpdate", isOn: $updater.automaticallyChecksForUpdates, disabled: !updater.isRunning)
            SettingsToggleRow("general.beta", isOn: $updater.betaUpdates, disabled: !updater.isRunning)
            SettingsRow("general.version", detail: "Version \(updater.version) (\(updater.build)). A check sends your IP address and Verbatim's version to GitHub, nothing else.") {
                Button("Check Now") { updater.checkForUpdates() }
                    .buttonStyle(.brandSecondary)
                    .disabled(!updater.isRunning || !updater.canCheckForUpdates)
            }
        }
    }
}

// MARK: - App › Dictation

/// Dictation: the hotkey and mode, cleanup, tone per kind of app, accuracy, snippets, and Accessibility.
struct DictationSettings: View {
    @EnvironmentObject var app: AppState
    var body: some View { DictationForm(dictation: app.dictation) }
}

struct DictationForm: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dictation: DictationController
    @ObservedObject private var flow = FlowSettings.shared
    @State private var trusted = false
    @State private var newTrigger = ""
    @State private var newExpansion = ""
    @AppStorage(FlowSettings.maxDictationMinutesKey) private var maxMinutes: Double = 10

    var body: some View {
        SettingsPane(tab: .dictate) {
            SettingsGroup {
                SettingsToggleRow("dictate.enabled", isOn: $dictation.enabled)
            }
            SettingsGroup(title: "Starting and stopping") {
                SettingsRow("dictate.hotkey") {
                    Picker("Hotkey", selection: $dictation.hotkey) {
                        ForEach(DictationController.Hotkey.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow("dictate.mode", detail: flow.mode.note + " Press Esc to cancel. Hold Shift as you start to edit selected text by voice. ⌘⌃V pastes your last dictation again.") {
                    Picker("Mode", selection: $flow.mode) {
                        ForEach(FlowMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow("dictate.shortcuts", stacked: true) {
                    VStack(alignment: .leading, spacing: 8) { DictationHotkeyRows(dictation: dictation) }
                        .settingsFormRows()
                }
                SettingsRow("dictate.maxMinutes", detail: "A minute before, the button says so. Your words up to the stop are pasted, never thrown away. Recording in the app has no limit.") {
                    Picker("Stop dictating after", selection: $maxMinutes) {
                        Text("5 minutes").tag(5.0); Text("10 minutes").tag(10.0); Text("20 minutes").tag(20.0); Text("No limit").tag(0.0)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsGroup(title: "Cleanup") {
                SettingsRow("dictate.cleanup", detail: flow.cleanup.note, stacked: true) {
                    Picker("Cleanup", selection: $flow.cleanup) {
                        ForEach(CleanupLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                    if let notice = FlowCleanup.unavailableNotice {
                        Text(notice).font(.system(size: 12.5)).foregroundStyle(flow.cleanup == .literal ? Ink.mute : Ink.accentText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SettingsRow("dictate.cleanupHelp", detail: "Say “comma,” “period,” “question mark,” “new line,” or “new paragraph” at any level. At Clean and Polished, announce a list (“a few things,” “first… second…,” “step one,” or “bullet”) to get a numbered or bulleted list, and change topic (“also,” “one more thing”) to start a paragraph. Lists, paragraphs, filler removal, and fixes for capitals and “a” or “an” work without Apple Intelligence. Cleanup keeps the language you speak and never answers what you dictate. If it would change a number, a name, or a “not,” Verbatim pastes your words instead.")
                CloudCleanupSettingsRows()
            }
            SettingsGroup(title: "Style for each kind of app") {
                SettingsRow("dictate.styles", stacked: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(AppCategory.allCases.filter { $0 != .code }) { c in
                            HStack(alignment: .center) {
                                categoryLabel(c)
                                Spacer(minLength: 12)
                                Picker(c.title, selection: Binding(get: { flow.styles[c] ?? .casual }, set: { flow.styles[c] = $0 })) {
                                    ForEach([FlowStyle.formal, .casual, .veryCasual, .verbatim]) { Text($0.title).tag($0) }
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                        HStack {
                            categoryLabel(.code)
                            Spacer(minLength: 12)
                            Text("As spoken, always").font(.system(size: 13)).foregroundStyle(Ink.dim)
                        }
                    }
                }
                SettingsToggleRow("dictate.context", isOn: $flow.useContext)
            }
            SettingsGroup(title: "Accuracy") {
                SettingsToggleRow("dictate.boost", isOn: $flow.boostVocabulary)
                SettingsToggleRow("dictate.autoLearn", isOn: $flow.autoLearn)
            }
            SettingsGroup(title: "Snippets") {
                SettingsRow("dictate.snippets", stacked: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(flow.snippets) { s in
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: "“\(s.trigger)”").fontWeight(.medium).frame(width: 150, alignment: .leading)
                                Text(s.expansion).foregroundStyle(Ink.dim).lineLimit(2)
                                Spacer()
                                Button { flow.snippets.removeAll { $0.id == s.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).help("Remove").accessibilityLabel("Remove \(s.trigger)")
                            }
                            .font(.system(size: 13))
                        }
                        HStack {
                            TextField("Say…", text: $newTrigger).frame(width: 150)
                            TextField("…to paste", text: $newExpansion)
                            Button("Add") {
                                let t = newTrigger.trimmingCharacters(in: .whitespaces), e = newExpansion.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !t.isEmpty, !e.isEmpty else { return }
                                flow.snippets.append(Snippet(trigger: t, expansion: e)); newTrigger = ""; newExpansion = ""
                            }
                            .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty || newExpansion.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            SettingsGroup(title: "Permissions and pasting") {
                SettingsRow("dictate.accessibility") {
                    HStack(spacing: 8) {
                        Circle().fill(trusted ? Ink.sage : Ink.persimmon).frame(width: 8, height: 8)
                        Text(trusted ? "Allowed" : "Needed").font(.system(size: 13))
                        if !trusted {
                            Button("Allow…") { dictation.requestAccessibility() }.buttonStyle(.brandPrimary)
                            Button("Open System Settings") { dictation.openAccessibilitySettings() }.buttonStyle(.brandSecondary)
                        }
                    }
                }
                SettingsRow("dictate.typeInstead", stacked: true) {
                    VStack(alignment: .leading, spacing: 8) { PasteSettingsRows() }
                        .settingsFormRows()
                        .font(.system(size: 12.5))
                }
            }
        }
        .onAppear { trusted = dictation.accessibilityTrusted }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let now = dictation.accessibilityTrusted
            if now != trusted { trusted = now; dictation.refreshMonitors(); dictation.bar?.refresh() }
        }
    }

    private func categoryLabel(_ c: AppCategory) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(c.title).font(.system(size: 13.5))
            Text(c.examples).font(.system(size: 11.5)).foregroundStyle(Ink.mute)
        }
    }
}

// MARK: - App › Floating button

struct FloatingButtonSettingsPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var flow = FlowSettings.shared
    @AppStorage(LiveWordsSetting.key) private var liveWords = true
    @AppStorage(RibbonStyle.key) private var ribbonStyle: String = RibbonStyle.paper.rawValue
    @AppStorage(RibbonMark.key) private var ribbonMark: String = RibbonMark.bars.rawValue

    var body: some View {
        SettingsPane(tab: .floatingButton) {
            SettingsGroup {
                SettingsToggleRow("float.show", isOn: $flow.showBar)
            }
            SettingsGroup(title: "Look") {
                SettingsRow("float.style") {
                    Picker("Style", selection: $ribbonStyle) {
                        Text("Paper").tag(RibbonStyle.paper.rawValue)
                        Text("Ink").tag(RibbonStyle.ink.rawValue)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingsRow("float.mark") {
                    Picker("Voice mark", selection: $ribbonMark) {
                        Text("Three bars").tag(RibbonMark.bars.rawValue)
                        Text("Rings").tag(RibbonMark.rings.rawValue)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingsToggleRow("float.liveWords", isOn: $liveWords)
                    .onChange(of: liveWords) { _, on in if on { app.dictation.prepareLiveWords() } }
            }
        }
    }
}

// MARK: - Transcription › Models and language

struct ModelsSettingsPane: View {
    @EnvironmentObject var app: AppState
    @AppStorage(AutoLabel.enabledKey) private var autoLabels = true
    @AppStorage(Summarizer.autoKey) private var autoSummary = true
    @AppStorage(Transcript.hideFillerKey) private var hideFiller = true

    var body: some View {
        SettingsPane(tab: .models) {
            SettingsGroup(title: "Model") {
                SettingsRow("models.quality", detail: "Parakeet (NVIDIA, via FluidAudio) is the default, with Parakeet v2 (English only) preselected: fast on Apple silicon with word timings. Whisper is the alternate for languages Parakeet misses. Pick by testing on your own recordings; the labels are starting points, not benchmarks.", stacked: true) {
                    Picker("Quality", selection: $app.presetRaw) {
                        ForEach(QualityPreset.allCases) { p in Text("\(p.title) · \(p.note)").tag(p.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                if app.preset == .advanced {
                    SettingsRow("models.engine", detail: "") {
                        Picker("Engine and model", selection: Binding(get: { app.advEngine + "/" + app.advModel }, set: { v in
                            let parts = v.split(separator: "/", maxSplits: 1).map(String.init)
                            if parts.count == 2 { app.advEngine = parts[0]; app.advModel = parts[1] }
                        })) {
                            ForEach(Engines.options) { o in Text("\(o.name) · \(o.note)").tag(o.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                SettingsRow("models.offline", detail: "Models download once from Hugging Face into Application Support and run on this Mac. Transcription never leaves your computer; fetching a link does need the internet.")
            }
            SettingsGroup(title: "Dictionary") {
                SettingsToggleRow("models.applyDictionary", isOn: $app.applyDictionary)
                SettingsToggleRow("models.projectVocab", isOn: $app.projectScopedVocabulary)
            }
            SettingsGroup(title: "When a transcript is ready") {
                SettingsToggleRow("models.nameSort", isOn: $autoLabels)
                SettingsToggleRow("models.summary", isOn: $autoSummary, detail: Summarizer.unavailableReason)
                SettingsToggleRow("models.hideFiller", isOn: $hideFiller)
            }
        }
    }
}

// MARK: - Transcription › Speakers and your voice

struct SpeakersSettingsPane: View {
    @EnvironmentObject var app: AppState
    @AppStorage(Transcript.mainSpeakerOnlyKey) private var mainSpeakerOnly = false

    var body: some View {
        SettingsPane(tab: .speakers) {
            // The voice profile (VoiceProfileSection.swift): setup or quality, plus its switches and Delete.
            VoiceProfileSection()
                .settingsAnchor("speakers.voiceProfile", radius: 16)
                .settingsAnchor("speakers.onlyMyVoice", radius: 16)
            SettingsGroup(title: "Speakers") {
                if FluidDiarizer.isSupported {
                    SettingsToggleRow("speakers.identify", isOn: $app.identifySpeakers)
                } else {
                    SettingsToggleRow("speakers.identify", isOn: .constant(false), detail: "Speaker labels need macOS 15 or later.", disabled: true)
                }
                SettingsToggleRow("speakers.mainOnly", isOn: $mainSpeakerOnly)
            }
            SettingsGroup(title: "Your microphone") {
                SettingsRow("speakers.mic") { MicSourceMenu(status: "No microphone found").fixedSize() }
            }
        }
    }
}

// MARK: - Transcription › Live captions

/// Live captions: text size, the header clock, and staying above full-screen apps.
struct CaptionsSettingsPane: View {
    @AppStorage(CaptionSize.key) private var sizeRaw = CaptionSize.medium.rawValue
    @AppStorage(CaptionPrefs.timecodeKey) private var timecode = true
    @AppStorage(CaptionPrefs.aboveFullScreenKey) private var above = true
    var body: some View {
        SettingsPane(tab: .captions) {
            SettingsGroup {
                SettingsRow("captions.size") {
                    Picker("Text size", selection: $sizeRaw) {
                        ForEach(CaptionSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingsToggleRow("captions.soon", isOn: $timecode)
                SettingsToggleRow("captions.above", isOn: $above)
            }
        }
    }
}

// MARK: - Files › Export

/// The options Copy, Export, and watched folders use. Same keys as `ExportOptions.saved`, so a change here
/// shows in the export popover and the other way round.
struct ExportSettingsPane: View {
    @State private var options = ExportOptions.saved
    @AppStorage("settingsTab") private var tab: SettingsTab = .export

    var body: some View {
        SettingsPane(tab: .export) {
            SettingsGroup(title: "What's included") {
                // The same rows as the export sheet, editing the same saved options.
                ExportOptionRows(options: $options, format: nil)
                    .settingsAnchor("export.source", radius: 12)
            }
            .onChange(of: options) { _, o in o.save() }
            SettingsGroup {
                SettingsRow("export.watched", detail: "Auto-export from a watched folder writes files with the options above.") {
                    Button("Watched folders →") { tab = .watched }.buttonStyle(.plain).foregroundStyle(Ink.accentText).font(.system(size: 13))
                }
            }
        }
    }
}

// MARK: - Files › Storage and iCloud

struct StorageSettingsPane: View {
    @EnvironmentObject var app: AppState
    @State private var keepFolder = Keep.folder

    var body: some View {
        SettingsPane(tab: .storage) {
            CloudSyncSection()
            SettingsGroup(title: "On this Mac", footer: Paths.root.path) {
                SettingsRow("storage.library") {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }.buttonStyle(.brandSecondary)
                }
                SettingsRow("storage.models") {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.models]) }.buttonStyle(.brandSecondary)
                }
            }
            SettingsGroup(title: "Keep", footer: "Keep only what you have the right to save: your own uploads, Creative Commons, or with permission. Some sites' terms don't allow downloading.") {
                SettingsRow("storage.keepFolder", detail: keepFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    HStack(spacing: 8) {
                        Button("Change…") { chooseKeepFolder() }.buttonStyle(.brandSecondary)
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: keepFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([keepFolder])
                        }
                        .buttonStyle(.brandSecondary)
                    }
                }
                SettingsToggleRow("storage.keepVideo", isOn: $app.keepVideoByDefault,
                                  detail: "Video is saved as MP4 (H.264, up to 1080p) with its sound; audio as M4A. Nothing is re-encoded. Notes pinned to a moment get a still from the video.")
            }
            DeleteAllDataSection()
        }
    }

    private func chooseKeepFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = keepFolder; panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let u = panel.url { Keep.folder = u; keepFolder = u }
    }
}

/// Storage › iCloud: the sync switch. Turning it off copies the library onto this Mac first; the change takes
/// effect the next time Verbatim opens (the library's location is fixed for a session).
struct CloudSyncSection: View {
    @State private var wanted = Cloud.wantsSync
    @State private var confirmOff = false
    @State private var copying = false
    @State private var failed = 0
    @EnvironmentObject private var app: AppState

    var body: some View {
        SettingsGroup(title: "iCloud") {
            if Cloud.available {
                SettingsToggleRow("storage.icloud", isOn: Binding(get: { wanted }, set: { on in
                    if on { wanted = true; Cloud.setWantsSync(true) } else { confirmOff = true }
                }), detail: note, disabled: copying)
            } else {
                SettingsRow("storage.icloud", detail: "iCloud sync is unavailable. Sign in to iCloud in System Settings to sync with your iPhone; until then, everything stays on this Mac.")
            }
        }
        .alert("Turn off iCloud sync?", isPresented: $confirmOff) {
            Button("Cancel", role: .cancel) {}
            Button("Turn Off") { turnOff() }
        } message: {
            Text("Verbatim copies your library onto this Mac, then stops syncing the next time it opens. Your iPhone keeps what's already in iCloud.")
        }
    }

    private var note: String {
        if copying { return "Copying your library to this Mac…" }
        if failed > 0 { return "\(failed) file\(failed == 1 ? "" : "s") couldn't be downloaded from iCloud, so sync is still on. Check your internet connection and try again." }
        if wanted != Cloud.enabled {
            return wanted ? "Sync starts the next time you open Verbatim." : "Your library is on this Mac. Quit and reopen Verbatim to finish turning off sync."
        }
        return wanted ? "Transcripts, notes, projects, and the Dictionary match your iPhone. Audio from the other device downloads when you play it."
                      : "Everything stays on this Mac."
    }

    private func turnOff() {
        guard Cloud.enabled else { wanted = false; Cloud.setWantsSync(false); return }
        copying = true; failed = 0
        Task { @MainActor in
            app.store.flush()
            let r = await Task.detached(priority: .userInitiated) { () -> (copied: Int, failed: Int) in
                TranscriptFiles.queue.sync {}   // queued saves land in iCloud before the copy reads it
                return Cloud.copyToDevice()
            }.value
            failed = r.failed
            if r.failed == 0 { Cloud.setWantsSync(false); wanted = false }
            copying = false
        }
    }
}

/// Storage › Delete All Data, asked twice because it reaches iCloud and the iPhone too.
struct DeleteAllDataSection: View {
    @EnvironmentObject private var app: AppState
    @State private var first = false
    @State private var second = false

    var body: some View {
        SettingsGroup(title: "Privacy") {
            SettingsRow("storage.deleteAll") {
                Button("Delete All Data…", role: .destructive) { first = true }
            }
        }
        .alert("Delete all data?", isPresented: $first) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { second = true } }
        } message: {
            Text(Cloud.enabled
                 ? "This removes everything from this Mac and from iCloud, so it's gone from your iPhone too. It can't be undone."
                 : "This removes everything from this Mac. It can't be undone.")
        }
        .alert("Delete everything for good?", isPresented: $second) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) { app.deleteAllData() }
        } message: {
            Text("\(app.store.transcripts.count) transcripts and dictations, with their audio.")
        }
    }
}

// MARK: - Files › About

struct AboutSettingsPane: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        SettingsPane(tab: .about) {
            SettingsGroup {
                SettingsRow("about.version", detail: "Verbatim \(updater.version) (\(updater.build))") {
                    BarsMark(color: Ink.persimmon).frame(width: 18, height: 19)
                }
                SettingsRow("about.support") {
                    if let u = Links.mail(subject: "Verbatim support") {
                        Link("Contact Support", destination: u).font(.system(size: 13)).foregroundStyle(Ink.accentText)
                    }
                }
                SettingsRow("about.log") {
                    HStack(spacing: 8) {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }.buttonStyle(.brandSecondary)
                        Button("Send…") { sendDiagnosticLog() }.buttonStyle(.brandSecondary)
                    }
                }
                SettingsRow("about.legal") {
                    HStack(spacing: 12) {
                        Link("Privacy", destination: Links.privacy)
                        Link("Terms", destination: Links.terms)
                        Link("Refunds", destination: Links.refunds)
                    }
                    .font(.system(size: 13)).foregroundStyle(Ink.accentText)
                }
            }
        }
    }

    /// Opens a Mail draft to support with native.log attached; falls back to showing the file.
    private func sendDiagnosticLog() {
        Log.trimNow()
        if let mail = NSSharingService(named: .composeEmail) {
            mail.recipients = [Links.supportEmail]
            mail.subject = "Verbatim diagnostic log"
            if mail.canPerform(withItems: [Log.file]) { mail.perform(withItems: [Log.file]); return }
        }
        NSWorkspace.shared.activateFileViewerSelecting([Log.file])
    }
}

/// Settings › Dictation › Cleanup › Cloud cleanup: off by default. Your own Anthropic or OpenAI key, saved in your
/// Keychain on this Mac only (`CloudCleanup`, `CloudKeychain`).
struct CloudCleanupSettingsRows: View {
    @AppStorage(CloudCleanup.enabledKey) private var on = false
    @AppStorage(CloudCleanup.providerKey) private var providerRaw = CloudCleanup.Provider.anthropic.rawValue
    @State private var key = ""
    @State private var model = ""
    @State private var hasKey = false
    @State private var keyNote: String? = nil

    private var provider: CloudCleanup.Provider { CloudCleanup.Provider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        SettingsToggleRow("dictate.cloud", isOn: $on,
                          detail: on ? CloudCleanup.privacyNote(provider) + " Without a connection, or if the request fails, Verbatim cleans up on this Mac."
                                     : "Off. Cleanup runs on this Mac.")
            .onAppear(perform: load)
            .onChange(of: providerRaw) { _, _ in load() }
        if on {
            SettingsRow("dictate.cloudProvider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(CloudCleanup.Provider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow("dictate.cloudKey", detail: keyNote ?? (hasKey ? "A key is saved in your Keychain." : "Paste your own \(provider.company) API key. It's saved in your Keychain on this Mac only."), stacked: true) {
                HStack(spacing: 8) {
                    SecureField(hasKey ? "Replace the saved key" : provider.keyPlaceholder, text: $key)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey {
                        Button("Remove") { CloudCleanup.deleteKey(for: provider); hasKey = false; keyNote = "Key removed." }
                    }
                }
                Link("Get a key from \(provider.company)", destination: provider.keysURL).font(.system(size: 12.5))
            }
            SettingsRow("dictate.cloudModel", detail: "Leave empty for \(provider.defaultModel).") {
                TextField(provider.defaultModel, text: $model)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .onChange(of: model) { _, m in CloudCleanup.setModel(m, for: provider) }
            }
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
            hasKey = true; keyNote = "Key saved in your Keychain."
        } else {
            keyNote = "Couldn't save the key. Try again."
        }
        key = ""
    }
}
