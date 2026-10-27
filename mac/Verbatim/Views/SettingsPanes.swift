import SwiftUI
import AppKit

// brand: web style
//
// The Settings panes (SettingsView.swift holds the window), in the layout of MacSettingsMap (MacSettingsMap.swift).
// Every row's label and description come from SettingsIndex, so search always matches what's on screen. Website style (DESIGN.md §11): actions inside rows are
// line mini pills; switches, menus, and segmented controls stay native.

// MARK: - Personalization and preferences

/// How Verbose looks and sounds, Home, About me, your voice, and the Dictionary and language.
struct PersonalizationSettingsPane: View {
    @EnvironmentObject var app: AppState
    @AppStorage(MotionPreference.key) private var motionLimited = false
    @AppStorage(BuiltInVocabulary.enabledKey) private var builtInVocabulary = true
    @AppStorage(LanguageDetection.enabledKey) private var detectLanguage = true

    var body: some View {
        SettingsPane(tab: .personalization) {
            SettingsGroup {
                // The look: Verbose style or Native, as two live thumbnails. Applies at once, with a crossfade.
                SettingsRow("general.look") {
                    LookPicker(thumbnail: 128, captions: false).padding(.vertical, 4)
                }
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
            // Customize Home: Edit Home's list (EditHome.swift), the same one Home's inspector shows. The This week
            // switch sets the same layout.
            SettingsGroup(title: "Home") {
                EditHomeView()
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .settingsAnchor("general.customizeHome", radius: Radius.tile)
                SettingsToggleRow("general.homeWeek", isOn: Binding(get: { app.showHomeWeek }, set: { app.showHomeWeek = $0 }))
            }
            SettingsGroup(title: "About you") {
                AboutMeSettingsRow()
            }
            // The voice profile (VoiceProfileSection.swift): setup or quality, plus its switches and Delete.
            VoiceProfileSection()
                .settingsAnchor("speakers.voiceProfile", radius: Radius.tile)
                .settingsAnchor("speakers.onlyMyVoice", radius: Radius.tile)
            SettingsGroup(title: "Dictionary and language") {
                SettingsToggleRow("models.detectLanguage", isOn: $detectLanguage)
                SettingsToggleRow("models.builtInVocabulary", isOn: $builtInVocabulary)
                SettingsToggleRow("models.projectVocab", isOn: $app.projectScopedVocabulary)
            }
        }
    }
}

/// Support and feedback › Updates: Sparkle automatic updates (App/Updater.swift).
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage("settingsTab") private var tab: SettingsTab = .support
    var body: some View {
        SettingsGroup(title: "Updates",
                      footer: updater.isRunning ? nil : "Automatic updates are off in this build.") {
            SettingsToggleRow("general.autoUpdate", isOn: $updater.automaticallyChecksForUpdates, disabled: !updater.isRunning)
            SettingsToggleRow("general.beta", isOn: $updater.betaUpdates, disabled: !updater.isRunning)
            SettingsRow("general.version", detail: "Version \(AppVersion.label). A check sends your IP address and Verbose's version to GitHub, nothing else.") {
                HStack(spacing: 8) {
                    Button("What's New…") { tab = .whatsNew }.buttonStyle(.settingsPill)
                    Button("Check Now") { updater.checkForUpdates() }
                        .buttonStyle(.settingsPill)
                        .disabled(!updater.isRunning || !updater.canCheckForUpdates)
                }
            }
        }
    }
}

// MARK: - Dictation and keyboard

/// Dictation: the hotkey and how it starts, cleanup, tone per kind of app, accuracy, snippets, and Accessibility.
/// Where dictation shows is on Floating button and Ribbon.
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
    @AppStorage(SpokenCorrections.enabledKey) private var spokenCorrections = true

    var body: some View {
        SettingsPane(tab: .dictate) {
            SettingsGroup {
                SettingsToggleRow("dictate.enabled", isOn: $dictation.enabled)
            }
            SettingsGroup(title: "Starting and stopping") {
                HotkeyPickerRow(dictation: dictation)
                HowItStartsRow(dictation: dictation)
                DictationHotkeyRows(dictation: dictation)
                MarkHotkeyRow(dictation: dictation)
                RecallShortcutRow()
                LowerAudioRow()
                AutoSendSettingsRow()
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
                SettingsToggleRow("dictate.spokenCorrections", isOn: $spokenCorrections,
                                  detail: "Say “scratch that,” “delete the last sentence,” or “let me start over” to fix what you said. “At 2, actually 3” keeps 3. Works at Clean and Polished, with or without Apple Intelligence.")
                SettingsRow("dictate.cleanupHelp", detail: "Say “comma,” “period,” “question mark,” “new line,” or “new paragraph” at any level. At Clean and Polished, announce a list (“a few things,” “first… second…,” “step one,” or “bullet”) to get a numbered or bulleted list, and change topic (“also,” “one more thing”) to start a paragraph. Lists, paragraphs, filler removal, and fixes for capitals and “a” or “an” work without Apple Intelligence. Cleanup keeps the language you speak and never answers what you dictate. If it would change a number, a name, or a “not,” Verbose pastes your words instead.")
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
                EmailLayoutRows()
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
                                Button("Remove") { flow.snippets.removeAll { $0.id == s.id } }
                                    .buttonStyle(.settingsPill).help("Remove").accessibilityLabel("Remove \(s.trigger)")
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
                            .buttonStyle(.settingsPill)
                            .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty || newExpansion.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            SettingsGroup(title: "Permissions and pasting") {
                SettingsRow("dictate.accessibility") {
                    HStack(spacing: 8) {
                        StatusText(text: trusted ? "Allowed" : "Needed", tone: trusted ? .kept : .danger, check: trusted)
                        if !trusted {
                            Button("Allow…") { dictation.requestAccessibility() }.buttonStyle(.settingsPrimaryPill)
                            Button("Open System Settings") { dictation.openAccessibilitySettings() }.buttonStyle(.settingsPill)
                        }
                    }
                }
                AlwaysCopyRow()
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

// MARK: - Floating button and Ribbon

// FloatingButtonSettingsPane is in DictationSurfaceSettings.swift, with the rest of the dictation surfaces' settings.

// MARK: - Recording and transcription

/// The model, who's talking, what happens when a transcript is ready, the words while you record, and the switches
/// people rarely change.
struct RecordingSettingsPane: View {
    @EnvironmentObject var app: AppState
    @AppStorage(AutoLabel.enabledKey) private var autoLabels = true
    @AppStorage(Summarizer.autoKey) private var autoSummary = true
    @AppStorage(Transcript.hideFillerKey) private var hideFiller = true
    @AppStorage(Transcript.skipSponsorsKey) private var skipSponsors = true
    @AppStorage(RecordingWords.enabledKey) private var recordLiveWords = true
    @AppStorage(Transcript.mainSpeakerOnlyKey) private var mainSpeakerOnly = false
    @AppStorage(AudioTracksPreference.key) private var audioTracks = AudioTracksPreference.mix.rawValue
    @AppStorage(SpeakerVoices.enabledKey) private var recognizeVoices = true
    @State private var savedVoices = SpeakerVoices.namedCount

    var body: some View {
        SettingsPane(tab: .recording) {
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
            SettingsGroup(title: "Speakers") {
                if FluidDiarizer.isSupported {
                    SettingsToggleRow("speakers.identify", isOn: $app.identifySpeakers)
                } else {
                    SettingsToggleRow("speakers.identify", isOn: .constant(false), detail: "Speaker labels need macOS 15 or later.", disabled: true)
                }
                SettingsToggleRow("speakers.recognizeVoices", isOn: $recognizeVoices)
                SettingsRow("speakers.clearVoices", detail: savedVoices == 0 ? "No saved voices." : "\(savedVoices) saved voice\(savedVoices == 1 ? "" : "s"), kept on this Mac only and never synced.") {
                    Button("Clear Saved Voices") { SpeakerVoices.clear(); savedVoices = 0 }
                        .buttonStyle(.settingsPill).disabled(savedVoices == 0)
                        .onAppear { savedVoices = SpeakerVoices.namedCount }
                }
                SettingsToggleRow("speakers.mainOnly", isOn: $mainSpeakerOnly)
                SettingsRow("speakers.mic") { MicSourceMenu(status: "No microphone found").fixedSize() }
            }
            SettingsGroup(title: "When a transcript is ready") {
                SettingsToggleRow("models.nameSort", isOn: $autoLabels)
                SettingsToggleRow("models.summary", isOn: $autoSummary, detail: Summarizer.unavailableReason)
                SettingsToggleRow("models.hideFiller", isOn: $hideFiller)
                SettingsToggleRow("models.applyDictionary", isOn: $app.applyDictionary)
            }
            SettingsGroup(title: "While you record") {
                SettingsToggleRow("models.recordLiveWords", isOn: $recordLiveWords)
            }
            SettingsGroup(title: "More options") {
                SettingsRow("speakers.audioTracks") {
                    Picker("Files with several audio tracks", selection: $audioTracks) {
                        ForEach(AudioTracksPreference.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsToggleRow("models.skipSponsors", isOn: $skipSponsors)
            }
        }
    }
}

// MARK: - Meetings and captions

/// Live captions: text size, the header clock, and staying above full-screen apps.
struct CaptionsSettingsGroup: View {
    @AppStorage(CaptionSize.key) private var sizeRaw = CaptionSize.medium.rawValue
    @AppStorage(CaptionPrefs.timecodeKey) private var timecode = true
    @AppStorage(CaptionPrefs.aboveFullScreenKey) private var above = true
    var body: some View {
        SettingsGroup(title: "Live captions") {
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

/// Meeting capture: whether Verbose notices calls and asks, the chat notice, your microphone, and each app it
/// has noticed (don't ask for this app; bring back the consent sheet); then Live captions.
struct MeetingsSettingsPane: View {
    @AppStorage(MeetingCoordinator.noticeKey) private var notice = true
    @AppStorage(MeetingCoordinator.copyNoticeKey) private var copyNotice = true
    @ObservedObject private var coordinator = MeetingCoordinator.shared

    var body: some View {
        SettingsPane(tab: .meetings) {
            SettingsGroup(title: "Meetings") {
                SettingsToggleRow("meetings.notice", isOn: $notice)
                SettingsToggleRow("meetings.copyNotice", isOn: $copyNotice)
                SettingsRow("meetings.mic") { MicSourceMenu(status: "No microphone found").fixedSize() }
            }
            SettingsGroup(title: SettingsIndex.entry("meetings.apps")?.label,
                          footer: "In some places, everyone on a call must agree before you record. Verbose shows the consent sheet each time you start; after five recordings with an app, the sheet offers to stop asking for that app.") {
                let apps = coordinator.book.sorted
                if apps.isEmpty {
                    SettingsRow("meetings.apps", detail: "No calls noticed yet. When a meeting app starts using your microphone, it shows here.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(apps, id: \.key) { entry in
                            MeetingAppRow(key: entry.key, record: entry.record)
                        }
                    }
                    .settingsAnchor("meetings.apps")
                }
            }
            CaptionsSettingsGroup()
        }
    }
}

/// One noticed app: its counts, "Don't ask for this app", and, when the consent sheet is off for it, a way back.
private struct MeetingAppRow: View {
    var key: String
    var record: MeetingAppRecord

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // The app's dot: a neutral wash with the speakers glyph (color stays for meaning, DESIGN.md §1).
            IconGlyph(art: .iconSpeakers, size: 16, color: Ink.ink)
                .frame(width: 30, height: 30)
                .background(Ink.chip, in: Circle())
                .accessibilityHidden(true)
            SettingsRowText(label: record.name, detail: detail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if record.skipConsent {
                PillButton(title: "Ask before recording", kind: .line, size: .mini,
                           hint: "Shows the consent sheet again each time you record \(record.name)") {
                    MeetingCoordinator.shared.setSkipConsent(key, false)
                }
                .help("Show the consent sheet again each time you record \(record.name)")
            }
            // On (Verbose doesn't ask for this app), the pill is solid ink.
            PillButton(title: "Don't ask for this app", kind: record.dontAsk ? .dark : .line, size: .mini,
                       hint: record.dontAsk ? "Asks again when \(record.name) uses your microphone" : nil) {
                MeetingCoordinator.shared.setDontAsk(key, !record.dontAsk)
            }
            .accessibilityValue(record.dontAsk ? "On" : "Off")
            .help("Verbose doesn't ask when \(record.name) uses your microphone")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(minHeight: 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { RowRule() }
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        let calls = "\(record.calls) call\(record.calls == 1 ? "" : "s") noticed"
        let rec = "\(record.recorded) recorded"
        let skip = record.skipConsent ? " · no consent sheet" : ""
        return "\(calls) · \(rec)\(skip)"
    }
}

// MARK: - Watched folders and export › Export

/// The options Export and watched folders use (Copy follows the tab you're on instead), under the watched folders on
/// their pane (WatchedFoldersPane.swift). Same keys as `ExportOptions.saved`, so a change here shows in the export
/// popover and the other way round.
struct ExportSettingsGroups: View {
    @State private var options = ExportOptions.saved
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        SettingsGroup(title: "Export") {
            // The same saved options as the export sheet, laid out as Settings rows.
            ExportPaneRow("Text") {
                Picker("Text", selection: $options.source) { ForEach(ExportOptions.Source.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            .settingsAnchor("export.source", radius: Radius.row)
            ExportPaneToggle("Title and details header", isOn: $options.header)
            ExportPaneToggle("Note when Apple Intelligence cleaned it", isOn: $options.aiNote, note: "On Cleaned text the model touched: “\(Exporter.aiNoteText)”")
            ExportPaneToggle("Summary", isOn: $options.summary, note: "Written with Apple Intelligence, when the transcript has one.")
            ExportPaneToggle("One paragraph", isOn: $options.singleParagraph)
                .settingsAnchor("export.single", radius: Radius.row)
            ExportPaneToggle("“Transcribed with Verbose” footer", isOn: $options.provenance)
                .settingsAnchor("export.provenance", radius: Radius.row)
        }
        SettingsGroup(title: "Speakers and time") {
            ExportPaneRow("Speaker names") {
                Picker("Speaker names", selection: $options.speakerMode) { ForEach(ExportOptions.SpeakerMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            .settingsAnchor("export.speakers", radius: Radius.row)
            ExportPaneRow("Timecodes") {
                Picker("Timecodes", selection: $options.timecodeMode) { ForEach(ExportOptions.TimecodeMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            .settingsAnchor("export.timecodes", radius: Radius.row)
            if options.timecodeMode != .off || options.moments != .off {
                ExportPaneRow("Timecode style") {
                    Picker("Timecode style", selection: $options.timecodeStyle) { ForEach(ExportOptions.TimecodeStyle.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            }
            ExportPaneRow("Moments") {
                Picker("Moments", selection: $options.moments) { ForEach(ExportOptions.MomentsMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            ExportPaneRow("Start at", note: "Added to every time, such as 01:00:00 for a timeline that starts at one hour.") {
                ExportOffsetField(seconds: $options.timecodeOffset)
            }
            ExportPaneToggle("Include hidden lines", isOn: $options.includeHidden)
            ExportPaneToggle("Include sponsor reads", isOn: $options.includeSponsors, note: "Sponsor reads found in podcasts and videos.")
                .settingsAnchor("export.sponsors", radius: Radius.row)
        }
        SettingsGroup(title: "Subtitles", footer: "Used for SRT and VTT files.") {
            ExportPaneStepper("Characters per line", value: $options.subtitles.charsPerLine, range: 16...80, step: 1) { "\($0)" }
            ExportPaneStepper("Lines per caption", value: $options.subtitles.linesPerCaption, range: 1...3, step: 1) { "\($0)" }
            ExportPaneStepper("Shortest caption", value: $options.subtitles.minDuration, range: 0.3...5, step: 0.1) { String(format: "%.1f s", $0) }
            ExportPaneStepper("Longest caption", value: $options.subtitles.maxDuration, range: 2...20, step: 0.5) { ExportOptionRows.seconds($0) }
        }
        .onChange(of: options) { _, o in o.save() }
        SettingsGroup {
            SettingsRow("export.watched", detail: "Auto-export from a watched folder writes files with the options above.") {
                // The folders are at the top of this pane.
                PillButton(title: "Watched folders", kind: .line, size: .mini, trailing: .arrow) { model.focusID = "watched.folders" }
            }
        }
    }
}

// MARK: Export pane rows

/// One Settings row: label (and an optional note) on the left, the control on the right, a hairline above.
private struct ExportPaneRow<Control: View>: View {
    var title: String
    var note: String? = nil
    @ViewBuilder var control: () -> Control
    init(_ title: String, note: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.note = note; self.control = control
    }
    var body: some View {
        VStack(spacing: 0) {
            RowRule()
            HStack(alignment: .center, spacing: 16) {
                SettingsRowText(label: title, detail: note ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                control()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(minHeight: 60)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ExportPaneToggle: View {
    var title: String
    @Binding var isOn: Bool
    var note: String? = nil
    init(_ title: String, isOn: Binding<Bool>, note: String? = nil) { self.title = title; self._isOn = isOn; self.note = note }
    var body: some View {
        ExportPaneRow(title, note: note) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Ink.switchOn).controlSize(.small)
        }
    }
}

private struct ExportPaneStepper<V: Strideable>: View {
    var title: String
    @Binding var value: V
    var range: ClosedRange<V>
    var step: V.Stride
    var format: (V) -> String
    init(_ title: String, value: Binding<V>, range: ClosedRange<V>, step: V.Stride, format: @escaping (V) -> String) {
        self.title = title; self._value = value; self.range = range; self.step = step; self.format = format
    }
    var body: some View {
        ExportPaneRow(title) {
            HStack(spacing: 8) {
                Text(format(value)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Ink.ink).monospacedDigit()
                Stepper(title, value: $value, in: range, step: step).labelsHidden().controlSize(.small)
            }
        }
    }
}

private struct ExportOffsetField: View {
    @Binding var seconds: Double
    @State private var text = ""
    @State private var invalid = false
    var body: some View {
        TextField("00:00:00", text: $text)
            .textFieldStyle(.roundedBorder).font(Ink.mono(13)).multilineTextAlignment(.trailing)
            .foregroundStyle(invalid ? Ink.accentText : Ink.ink)
            .frame(width: 96)
            .onAppear { text = Timecode.offsetText(seconds) }
            .onChange(of: text) { _, v in
                if let s = Timecode.parseOffset(v) { invalid = false; seconds = s } else { invalid = true }
            }
            .accessibilityHint("Hours, minutes, and seconds added to every time, such as 01:00:00")
    }
}

// MARK: - Sync and storage

struct StorageSettingsPane: View {
    @EnvironmentObject var app: AppState
    @State private var keepFolder = Keep.folder

    var body: some View {
        SettingsPane(tab: .storage) {
            CloudSyncSection()
            SettingsGroup(title: "On this Mac", footer: Paths.root.path) {
                SettingsRow("storage.library") {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }.buttonStyle(.settingsPill)
                }
                SettingsRow("storage.models") {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.models]) }.buttonStyle(.settingsPill)
                }
            }
            SettingsGroup(title: "Links", footer: "Share links from Dropbox, Google Drive, OneDrive, SharePoint, and iCloud Drive download directly when they're shared with anyone who has the link.") {
                LinkSignInSettingsRow()
            }
            SettingsGroup(title: "Keep", footer: "Keep only what you have the right to save: your own uploads, Creative Commons, or with permission. Some sites' terms don't allow downloading.") {
                SettingsRow("storage.keepFolder", detail: keepFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    HStack(spacing: 8) {
                        Button("Change…") { chooseKeepFolder() }.buttonStyle(.settingsPill)
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: keepFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([keepFolder])
                        }
                        .buttonStyle(.settingsPill)
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
            Text("Verbose copies your library onto this Mac, then stops syncing the next time it opens. Your iPhone keeps what's already in iCloud.")
        }
    }

    private var note: String {
        if copying { return "Copying your library to this Mac…" }
        if failed > 0 { return "\(failed) file\(failed == 1 ? "" : "s") couldn't be downloaded from iCloud, so sync is still on. Check your internet connection and try again." }
        if wanted != Cloud.enabled {
            return wanted ? "Sync starts the next time you open Verbose." : "Your library is on this Mac. Quit and reopen Verbose to finish turning off sync."
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

/// Sync and storage › Delete All Data, asked twice because it reaches iCloud and the iPhone too.
struct DeleteAllDataSection: View {
    @EnvironmentObject private var app: AppState
    @State private var first = false
    @State private var second = false

    var body: some View {
        SettingsGroup(title: "Delete") {
            SettingsRow("storage.deleteAll") {
                Button("Delete All Data…", role: .destructive) { first = true }
                    .buttonStyle(SettingsDangerPillStyle())
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

// MARK: - Support and feedback

/// Help, the diagnostic log, the fine print, and updates.
struct SupportSettingsPane: View {
    @ObservedObject private var updater = Updater.shared
    @State private var showAcknowledgements = false
    @AppStorage("settingsTab") private var tab: SettingsTab = .support

    var body: some View {
        SettingsPane(tab: .support) {
            // The lockup (DESIGN.md §4) and the tagline in the serif.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    BarsMark(color: Ink.persimmon).frame(width: 22, height: 23)
                    Ink.wordmark(28)
                }
                Text(Ink.tagline).font(Ink.serif(19)).foregroundStyle(Ink.dim)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbose. \(Ink.tagline)")
            SettingsGroup {
                SettingsRow("about.version", detail: "Verbose \(AppVersion.label)") {
                    HStack(spacing: 12) {
                        // What each build added (WhatsNewPane.swift).
                        Button("What's New…") { tab = .whatsNew }.buttonStyle(.settingsPill)
                        BarsMark(color: Ink.persimmon).frame(width: 18, height: 19)
                    }
                }
                SettingsRow("about.support") {
                    if let u = Links.mail(subject: "Verbose support") {
                        PillButton(title: "Contact Support", kind: .line, size: .mini) { NSWorkspace.shared.open(u) }
                    }
                }
                SettingsRow("about.log") {
                    HStack(spacing: 8) {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }.buttonStyle(.settingsPill)
                        Button("Send…") { sendDiagnosticLog() }.buttonStyle(.settingsPill)
                    }
                }
                SettingsRow("about.legal") {
                    HStack(spacing: 12) {
                        Link("Privacy", destination: Links.privacy)
                        Link("Terms", destination: Links.terms)
                        Link("Refunds", destination: Links.refunds)
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                }
                SettingsRow("about.acknowledgements") {
                    Button("Acknowledgements…") { showAcknowledgements = true }.buttonStyle(.settingsPill)
                }
            }
            UpdateSettingsSection()
        }
        .sheet(isPresented: $showAcknowledgements) {
            VStack(spacing: 0) {
                AcknowledgementsView()
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showAcknowledgements = false }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 640)
        }
    }

    /// Opens a Mail draft to support with native.log attached; falls back to showing the file.
    private func sendDiagnosticLog() {
        Log.trimNow()
        if let mail = NSSharingService(named: .composeEmail) {
            mail.recipients = [Links.supportEmail]
            mail.subject = "Verbose diagnostic log"
            if mail.canPerform(withItems: [Log.file]) { mail.perform(withItems: [Log.file]); return }
        }
        NSWorkspace.shared.activateFileViewerSelecting([Log.file])
    }
}

// MARK: - Account and plan

/// Your name. Verbose has no account, so this pane is small on purpose (plans come with the pricing decision).
struct AccountSettingsPane: View {
    var body: some View {
        SettingsPane(tab: .account) {
            SettingsGroup {
                YourNameSettingsRow()
            }
        }
    }
}

// MARK: - Features

/// Widgets, Shortcuts, and the welcome tour: the places people go to learn what Verbose can do.
struct FeaturesSettingsPane: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SettingsPane(tab: .features) {
            ThoughtsSettingsGroup()
            SettingsGroup(title: "Widgets and Shortcuts") {
                SettingsRow("features.widgets")
                SettingsRow("features.shortcuts") {
                    Button("Open Shortcuts") {
                        if let u = URL(string: "shortcuts://") { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(.settingsPill)
                }
            }
            SettingsGroup(title: "Welcome tour") {
                SettingsRow("general.tour") { Button("Show Tour") { app.showOnboarding = true }.buttonStyle(.settingsPill) }
                SettingsToggleRow("general.tourOnLaunch", isOn: Binding(get: { Onboarding.showOnLaunch }, set: { Onboarding.showOnLaunch = $0 }))
            }
        }
    }
}

/// Features › Thoughts: the hotkey, the bubble, and when a new day's page starts (Flow/Thoughts.swift).
struct ThoughtsSettingsGroup: View {
    @AppStorage(Thoughts.bubbleKey) private var showBubble = true
    @AppStorage(DayPages.newPageHourKey) private var hour = 0

    var body: some View {
        SettingsGroup(title: "Thoughts") {
            SettingsRow("features.thoughtsHotkey") { KeyChip(text: Thoughts.hotkey) }
            SettingsToggleRow("features.thoughtsBubble", isOn: Binding(get: { showBubble }, set: { showBubble = $0; ThoughtBubble.shared.refresh() }))
            SettingsRow("features.thoughtsNewPage") {
                Picker("New page each day at", selection: $hour) {
                    ForEach(DayPages.hours, id: \.self) { h in Text(DayPages.hourLabel(h)).tag(h) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
        }
    }
}

/// Dictation and keyboard › Cleanup › Cloud cleanup: off by default. Your own Anthropic or OpenAI key, saved in your
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
                          detail: on ? CloudCleanup.privacyNote(provider) + " Without a connection, or if the request fails, Verbose cleans up on this Mac."
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
                    Button("Save", action: saveKey).buttonStyle(.settingsPrimaryPill).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey {
                        Button("Remove") { CloudCleanup.deleteKey(for: provider); hasKey = false; keyNote = "Key removed." }
                            .buttonStyle(.settingsPill)
                    }
                }
                Link("Get a key from \(provider.company)", destination: provider.keysURL).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.ink)
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
