import SwiftUI

enum SettingsTab: String { case general, transcription, dictate, actions, keep, storage }

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @AppStorage("settingsTab") private var tab: SettingsTab = .general
    @AppStorage(MotionPreference.key) private var motionLimited = false
    @AppStorage(AutoLabel.enabledKey) private var autoLabels = true
    @AppStorage(Transcript.hideFillerKey) private var hideFiller = true
    @AppStorage(Transcript.mainSpeakerOnlyKey) private var mainSpeakerOnly = false

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            transcription.tabItem { Label("Transcription", systemImage: "text.alignleft") }.tag(SettingsTab.transcription)
            DictationSettings().tabItem { Label("Dictate", systemImage: "keyboard") }.tag(SettingsTab.dictate)
            ActionSettings().tabItem { Label("Actions", systemImage: "wand.and.stars") }.tag(SettingsTab.actions)
            KeepSettings().tabItem { Label("Keep", systemImage: "arrow.down.circle") }.tag(SettingsTab.keep)
            storage.tabItem { Label("Storage", systemImage: "externaldrive") }.tag(SettingsTab.storage)
        }
        .frame(width: 560)
        .padding(.bottom, 10)
        .tint(Ink.switchOn)   // switches in brand sage instead of the system blue
    }

    private var general: some View {
        Form {
            Picker("Appearance", selection: Binding(get: { app.appearance }, set: { app.appearance = $0; app.applyAppearance() })) {
                Text("Match the system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            Toggle("Limit animation", isOn: $motionLimited)
            Text("Fades instead of movement; illustrations stay still. Always on when Reduce Motion is on in System Settings.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute)
            Toggle("Show in menu bar", isOn: $app.showMenuBar)
            Text("Record from anywhere with the menu bar item, or press ⌥⇧R while Verbatim is running.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute)
            Toggle("Sounds", isOn: $app.sounds)
            Text("A short chime when recording starts and a tick when a transcript is ready. Off automatically with Reduce Motion.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute)
            Toggle("Show the welcome card on Home", isOn: Binding(get: { !app.heroDismissed }, set: { app.heroDismissed = !$0 }))
            Toggle("Show the welcome tour when Verbatim opens", isOn: Binding(get: { Onboarding.showOnLaunch }, set: { Onboarding.showOnLaunch = $0 }))
            LabeledContent("Welcome tour") { Button("Show Tour") { app.showOnboarding = true } }
            Section("Microphone") {
                LabeledContent("Record from") { MicSourceMenu(status: "No microphone found") }
                Text("Built-in mic, a USB interface, AirPods, or your iPhone (Continuity). “System default” follows the Mac's Sound settings.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            LiveCaptionsSettingsSection()
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
    }

    private var transcription: some View {
        Form {
            Section {
                Picker("Quality", selection: $app.presetRaw) {
                    ForEach(QualityPreset.allCases) { p in Text("\(p.title) · \(p.note)").tag(p.rawValue) }
                }
                if app.preset == .advanced {
                    Picker("Engine and model", selection: Binding(get: { app.advEngine + "/" + app.advModel }, set: { v in
                        let parts = v.split(separator: "/", maxSplits: 1).map(String.init)
                        if parts.count == 2 { app.advEngine = parts[0]; app.advModel = parts[1] }
                    })) {
                        ForEach(Engines.options) { o in Text("\(o.name) · \(o.note)").tag(o.id) }
                    }
                }
                Text("Parakeet (NVIDIA, via FluidAudio) is the default: fast on Apple silicon with word timings. Whisper is the alternate for languages Parakeet misses. Pick by testing on your own recordings; the labels are starting points, not benchmarks.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                if FluidDiarizer.isSupported {
                    Toggle("Identify speakers", isOn: $app.identifySpeakers)
                    Text("Labels turns as Speaker 1, Speaker 2… so you can name them. Runs on this Mac and adds time to each transcript.")
                        .font(.system(size: 12)).foregroundStyle(Ink.mute)
                } else {
                    Toggle("Identify speakers", isOn: .constant(false)).disabled(true)
                    Text("Speaker labels need macOS 15 or later.")
                        .font(.system(size: 12)).foregroundStyle(Ink.mute)
                }
                Toggle("Apply Dictionary to new transcripts", isOn: $app.applyDictionary)
                Text("Only words listed under “Heard as” are replaced, and every fix shows on the transcript.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                Toggle("Name and sort recordings", isOn: $autoLabels)
                Text("Apple Intelligence suggests a title, kind, and tags when a transcript is ready. Anything you rename or change stays.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
                Toggle("Hide filler lines", isOn: $hideFiller)
                Text("Lines that are only “um” or “uh” stay out of view. Nothing is deleted; Show brings them back.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
                Toggle("Main speaker only", isOn: $mainSpeakerOnly)
                Text("Other voices fold into a Background voices section under the transcript.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                Text("Models download once from Hugging Face into Application Support and run on this Mac. Transcription never leaves your computer; fetching a link does need the internet.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
        }
        .formStyle(.grouped)
    }

    private var storage: some View {
        Form {
            CloudSyncSection()
            Section("Files") {
                LabeledContent("Transcripts and audio") { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) } }
                LabeledContent("Models") { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.models]) } }
                Text(Paths.root.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.mute)
            }
            Section("Diagnostic log") {
                LabeledContent("Diagnostic log") {
                    HStack {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }
                        Button("Send…") { sendDiagnosticLog() }
                    }
                }
                Text("A record of what Verbatim did, to help fix problems. It keeps 7 days, leaves out links and folder names, and stays on this Mac unless you send it.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            DeleteAllDataSection()
            Section("About") {
                LabeledContent("Legal") {
                    HStack {
                        Link("Privacy", destination: Links.privacy)
                        Link("Terms", destination: Links.terms)
                        Link("Refunds", destination: Links.refunds)
                    }
                }
                LabeledContent("Help") {
                    if let u = Links.mail(subject: "Verbatim support") { Link("Contact Support", destination: u) }
                }
            }
        }
        .formStyle(.grouped)
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

/// Storage › iCloud: the sync switch. Turning it off copies the library onto this Mac first; the change takes
/// effect the next time Verbatim opens (the library's location is fixed for a session).
struct CloudSyncSection: View {
    @State private var wanted = Cloud.wantsSync
    @State private var confirmOff = false
    @State private var copying = false
    @State private var failed = 0
    @EnvironmentObject private var app: AppState

    var body: some View {
        Section("iCloud") {
            if Cloud.available {
                Toggle("Sync with iCloud", isOn: Binding(get: { wanted }, set: { on in
                    if on { wanted = true; Cloud.setWantsSync(true) } else { confirmOff = true }
                }))
                .disabled(copying)
                Text(note).font(.system(size: 12)).foregroundStyle(Ink.mute)
            } else {
                Text("iCloud sync is unavailable. Sign in to iCloud in System Settings to sync with your iPhone; until then, everything stays on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
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
        Section("Privacy") {
            LabeledContent("Delete all data") {
                Button("Delete All Data…", role: .destructive) { first = true }
            }
            Text("Removes every transcript, dictation, and recording, plus projects, the Dictionary, snippets, Activity, the Thought pad, and downloaded models. Settings stay.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute)
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

/// General › Updates: Sparkle automatic updates (App/Updater.swift).
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isRunning)
            Toggle("Get beta builds", isOn: $updater.betaUpdates)
                .disabled(!updater.isRunning)
            LabeledContent("Version \(updater.version) (\(updater.build))") {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.isRunning || !updater.canCheckForUpdates)
            }
            Text(updater.isRunning
                 ? "Beta builds arrive with every change to Verbatim; leave this off for tested releases only. A check sends your IP address and Verbatim's version to GitHub, nothing else."
                 : "Automatic updates are off in this build.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute)
        }
    }
}

/// Keep: where kept video and audio go, and whether links keep their video by default.
struct KeepSettings: View {
    @EnvironmentObject var app: AppState
    @State private var folder = Keep.folder
    var body: some View {
        Form {
            Section {
                LabeledContent("Keep folder") {
                    HStack(spacing: 8) {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).foregroundStyle(Ink.dim)
                        Button("Change…") { choose() }
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                }
                Toggle("Keep the video of every link I transcribe", isOn: $app.keepVideoByDefault)
                Text("Video is saved as MP4 (H.264, up to 1080p) with its sound; audio as M4A. Nothing is re-encoded. Notes pinned to a moment get a still from the video.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                Text("Keep only what you have the right to save: your own uploads, Creative Commons, or with permission. Some sites' terms don't allow downloading.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
        }
        .formStyle(.grouped)
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = folder; panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let u = panel.url { Keep.folder = u; folder = u }
    }
}

/// Dictate: the hold-to-talk hotkey, Accessibility status, and project vocabulary.
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
    @AppStorage(RibbonStyle.key) private var ribbonStyle: String = RibbonStyle.paper.rawValue
    @AppStorage(RibbonMark.key) private var ribbonMark: String = RibbonMark.bars.rawValue
    @AppStorage(LiveWordsSetting.key) private var liveWords = true

    var body: some View {
        Form {
            Section {
                Toggle("Dictate anywhere", isOn: $dictation.enabled)
                Toggle("Show the floating button", isOn: $flow.showBar)
                Text("A small button at the edge of your screen. Click it to start, click again to paste. Drag it to the bottom, left, or right edge; right-click it for options.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section("Floating button look") {
                Picker("Style", selection: $ribbonStyle) {
                    Text("Paper").tag(RibbonStyle.paper.rawValue)
                    Text("Ink").tag(RibbonStyle.ink.rawValue)
                }
                Picker("Voice mark", selection: $ribbonMark) {
                    Text("Three bars").tag(RibbonMark.bars.rawValue)
                    Text("Rings").tag(RibbonMark.rings.rawValue)
                }
                Toggle("Show words as you speak", isOn: $liveWords)
                    .help("A preview of your words in the floating button while you dictate, recognized on this Mac. What's pasted still comes from Verbatim's own transcription.")
                    .onChange(of: liveWords) { _, on in if on { dictation.prepareLiveWords() } }
                Text("Paper is a light tab with ink type. Ink is a dark tab with paper type. The voice mark moves with your voice while you dictate.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section("Starting and stopping") {
                Picker("Hotkey", selection: $dictation.hotkey) {
                    ForEach(DictationController.Hotkey.allCases) { Text($0.title).tag($0) }
                }
                Picker("Mode", selection: $flow.mode) {
                    ForEach(FlowMode.allCases) { Text($0.title).tag($0) }
                }
                DictationHotkeyRows(dictation: dictation)
                Text(flow.mode.note + " Press Esc to cancel. Hold Shift as you start to edit selected text by voice. ⌘⌃V pastes your last dictation again.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
                Picker("Stop dictating after", selection: $maxMinutes) {
                    Text("5 minutes").tag(5.0); Text("10 minutes").tag(10.0); Text("20 minutes").tag(20.0); Text("No limit").tag(0.0)
                }
                Text("A minute before, the button says so. Your words up to the stop are pasted, never thrown away. Recording in the app has no limit.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section("Cleanup") {
                Picker("Cleanup", selection: $flow.cleanup) {
                    ForEach(CleanupLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(flow.cleanup.note)
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
                Text("Say “comma,” “period,” “question mark,” “new line,” or “new paragraph” at any level. At Clean and Polished, announce a list (“a few things,” “first… second…,” “step one,” or “bullet”) to get a numbered or bulleted list, and change topic (“also,” “one more thing”) to start a paragraph. Lists and paragraphs work without Apple Intelligence. Cleanup keeps the language you speak and never answers what you dictate. If it would change a number, a name, or a “not,” Verbatim pastes your words instead.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
                if let notice = FlowCleanup.unavailableNotice {
                    Text(notice)
                        .font(.system(size: 12)).foregroundStyle(flow.cleanup == .literal ? Ink.mute : Ink.accentText)
                }
            }
            Section("Style for each kind of app") {
                ForEach(AppCategory.allCases.filter { $0 != .code }) { c in
                    Picker(selection: Binding(get: { flow.styles[c] ?? .casual }, set: { flow.styles[c] = $0 })) {
                        ForEach([FlowStyle.formal, .casual, .veryCasual, .verbatim]) { Text($0.title).tag($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title)
                            Text(c.examples).font(.system(size: 11)).foregroundStyle(Ink.mute)
                        }
                    }
                }
                LabeledContent {
                    Text("As spoken, always")
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppCategory.code.title)
                        Text(AppCategory.code.examples).font(.system(size: 11)).foregroundStyle(Ink.mute)
                    }
                }
                Toggle("Use the text around your cursor", isOn: $flow.useContext)
                Text("Verbatim reads the app's name and the text near your cursor so names are spelled right and the tone matches. Password fields are never read, and nothing leaves this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section("Accuracy") {
                Toggle("Listen for my Dictionary words", isOn: $flow.boostVocabulary)
                Text("Parakeet listens for the words in your Dictionary as you speak (a small extra model downloads once). Works best with fewer than 100 words.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
                Toggle("Learn from my fixes", isOn: $flow.autoLearn)
                Text("When you correct a name or term right after it's pasted, the floating button asks whether to remember it. Nothing is learned unless you say yes.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section("Snippets") {
                ForEach(flow.snippets) { s in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: "“\(s.trigger)”").fontWeight(.medium).frame(width: 150, alignment: .leading)
                        Text(s.expansion).foregroundStyle(Ink.dim).lineLimit(2)
                        Spacer()
                        Button { flow.snippets.removeAll { $0.id == s.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove")
                    }
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
                Text("Say a trigger like “my calendar link” and Verbatim pastes the saved text: a link, an address, a sign-off.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                LabeledContent("Accessibility access") {
                    HStack(spacing: 8) {
                        Circle().fill(trusted ? Ink.lime : Ink.coral).frame(width: 8, height: 8)
                        Text(trusted ? "Allowed" : "Needed")
                        if !trusted {
                            Button("Allow…") { dictation.requestAccessibility() }
                            Button("Open System Settings") { dictation.openAccessibilitySettings() }
                        }
                    }
                }
                Text("macOS requires this so Verbatim can notice the hotkey, see which app and text field you're in, and press ⌘V there.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
                PasteSettingsRows()
                Toggle("Project vocabulary", isOn: $app.projectScopedVocabulary)
                Text("Dictionary fixes you save from a transcript inside a project apply only to that project. Off, every fix applies everywhere.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = dictation.accessibilityTrusted }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let now = dictation.accessibilityTrusted
            if now != trusted { trusted = now; dictation.refreshMonitors(); dictation.bar?.refresh() }
        }
    }
}

struct ElapsedText: View {
    @ObservedObject var live: LiveMeter
    var body: some View { Text(live.elapsed.timecode).font(.system(size: 13, design: .monospaced)) }
}

/// The menu bar panel: record from anywhere, jump back to the app.
struct MenuBarPanel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandMark().frame(width: 20, height: 20)
                Text("Verbatim").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌥⇧R to record").font(.system(size: 11)).foregroundStyle(Ink.mute)
            }
            if app.recorder.isRecording {
                HStack(spacing: 10) {
                    RecordButton(size: 22)
                    ElapsedText(live: app.recorder.live)
                    Spacer()
                    Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }
                    Button("Stop") { app.stopRecording() }.buttonStyle(.brandPrimary)
                }
                .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if app.capture.isCapturing {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(Ink.iris)
                    HStack(spacing: 4) { Text("Capturing \(app.capture.appName) ·").font(.system(size: 12.5)); ElapsedText(live: app.capture.live) }
                    Spacer()
                    Button("Stop") { app.stopCapture() }.buttonStyle(.brandPrimary)
                }
                .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Button { NSApp.activate(ignoringOtherApps: true); app.requestRecord() } label: {
                    HStack(spacing: 10) { RecordButton(size: 26); Text("Record voice memo").font(.system(size: 13, weight: .medium)); Spacer() }
                        .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
                Button { NSApp.activate(ignoringOtherApps: true); app.pickApp() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(Ink.iris).frame(width: 26)
                        Text("Capture an app's audio").font(.system(size: 13, weight: .medium)); Spacer()
                    }
                    .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
            }
            if let last = app.store.live.first {
                Button { NSApp.activate(ignoringOtherApps: true); app.go(.transcript(last.id)) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: last.source.symbol).foregroundStyle(Ink.inkFixed).frame(width: 26, height: 26)
                            .background(Ink.persimmon, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(last.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text("Last transcript · \(last.duration.timecode)").font(.system(size: 11)).foregroundStyle(Ink.mute)
                        }
                        Spacer()
                    }
                    .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let last = app.dictation.lastResult, !last.isEmpty {
                Button { app.dictation.copyLast() } label: {
                    HStack(spacing: 8) { Image(systemName: "doc.on.clipboard").foregroundStyle(Ink.iris).frame(width: 26); Text("Copy last dictation").font(.system(size: 12.5, weight: .medium)); Spacer() }
                        .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Open Verbatim") { NSApp.activate(ignoringOtherApps: true); app.go(.home) }.buttonStyle(.plain).foregroundStyle(Ink.iris).fontWeight(.medium)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Ink.mute)
            }
            .font(.system(size: 12.5))
        }
        .padding(12).frame(width: 320).background(Ink.paper)
    }
}
