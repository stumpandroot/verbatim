import SwiftUI
import UIKit

/// About me: a few lines of context in UserDefaults. With iCloud sync on, it travels with your name to your Mac
/// (Store.SyncedProfile).
enum Profile {
    static let aboutMeKey = "profile.aboutMe"
    static let aboutMeLimit = 300
}

extension Notification.Name {
    /// Scrolls Settings to a row or group id (`group-3`, `settings-footer`), for the screenshot tour.
    static let verbatimSettingsScroll = Notification.Name("verbatimSettingsScroll")
}

/// Settings in seven groups (PhoneSettingsMap, from the premium mockup's section 02): search, the You card at the top
/// (your initial and your name; it opens the You page, YouScreen.swift), then Personalization and preferences,
/// Recording and transcription, Dictation and keyboard, Sync and storage, Account and plan, Support and feedback, and
/// Features. Each root row has its icon (a thin tinted symbol in Native, a colored square in Verbose style), its value
/// on the right, and a chevron; rarely changed switches sit one level down on a page (SettingsPages.swift). The
/// version sits at the foot; tapping it opens What's new (WhatsNewScreen.swift).
struct SettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.openURL) private var openURL
    @AppStorage(Profile.aboutMeKey) private var aboutMe = ""
    @AppStorage(MotionPreference.key) private var motionLimited = false
    @AppStorage(AutoLabel.enabledKey) private var autoLabels = true
    @AppStorage(Summarizer.autoKey) private var autoSummary = true
    /// Check each recording's language and pick a model that knows it (LanguageCheck.swift). On by default.
    @AppStorage(LanguageDetection.enabledKey) private var detectLanguage = true
    @AppStorage(CloudCleanup.enabledKey) private var cloudCleanupOn = false
    @State private var showAcknowledgements = false
    /// Show words while you record (MiniRecorder.swift). On by default.
    @AppStorage(RecordingLiveText.enabledKey) private var recordLiveWords = true
    /// Haptics (PhoneMotion.swift's `Haptics`). On by default, per device.
    @AppStorage(Haptics.enabledKey) private var hapticsOn = true
    /// Understand spoken corrections, in the App Group so the keyboard's live words follow it.
    @AppStorage(SpokenCorrections.enabledKey, store: SpokenCorrections.store) private var spokenCorrections = true
    /// Dictation cleanup level (the Mac's `flow.cleanup` key; per device, never synced).
    @ObservedObject private var flow = FlowSettings.shared
    /// The tab bar's picks, for the Tab bar row's value.
    @ObservedObject private var tabBarStore = PhoneTabBarStore.shared
    /// "Library, Moments": the tabs between Home and Settings, or "Home and Settings" with none.
    private var tabBarValue: String {
        let m = tabBarStore.bar.middle
        return m.isEmpty ? "Home and Settings" : m.map(\.title).joined(separator: ", ")
    }
    /// Tap counts per row: each change gives that row's icon one small bounce.
    @State private var bumps: [String: Int] = [:]
    /// The page pushed from a root row, a search result, or a request (SettingsPage).
    @State private var page: SettingsSubpage? = nil
    /// The You page (YouScreen.swift): the You card, and Home's This week card.
    @State private var showYou = false
    /// A row the You page asked for (Cloud cleanup): its page opens, or the row is scrolled to and flashed, once the
    /// You page has closed.
    @State private var pendingRow: String? = nil
    /// Settings › Action button's choice (Ribbon.ActionChoice), for the row's value.
    @AppStorage(Ribbon.actionChoiceKey) private var actionChoice = Ribbon.ActionChoice.dictate.rawValue
    @State private var showVoice = false
    @State private var voicePreview = false
    @ObservedObject private var voice = VoiceProfileStatus.shared
    @State private var exporting = false
    @State private var exportURL: URL? = nil
    @State private var confirmDelete = false
    @State private var confirmDeleteFinal = false
    /// iCloud switch: the preference for next launch, the turn-off question, and the copy that runs first.
    @State private var syncWanted = Cloud.wantsSync
    @State private var confirmSyncOff = false
    @State private var copyingDown = false
    @State private var copyFailed = 0
    /// Search: the shared query, and the row that flashes after a result scrolls to it.
    @ObservedObject private var search = SettingsSearchModel.shared
    @State private var searchFlash: String? = nil
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Native uses the navigation bar's large title.
                if !look.isNative {
                    PhoneCompactTitle(title: "Settings")
                        .padding(.top, 2)
                }
                SettingsSearchField(text: $search.query) {
                    if let first = SettingsSearchIndex.search(search.query).first?.entries.first { pickSearchResult(first, proxy) }
                }
                .padding(.top, look.isNative ? 4 : 14)
                .id("settings-top")
                if search.isActive {
                    SettingsSearchResults(query: search.query, value: { SettingsSearchIndex.value(for: $0, app: app) }) { pickSearchResult($0, proxy) }
                } else {
                youCard
                    .padding(.top, 18)
                group(1, PhoneSettingsMap.personalization) { personalization }
                group(2, PhoneSettingsMap.recording,
                      footer: "Transcription runs on this iPhone. The first time, the model downloads once (about 200–600 MB). Links download and transcribe on this iPhone; a few sites need your Mac to fetch them. Naming and sorting use Apple Intelligence on this iPhone; where it isn't available, titles use the first words and the kind is a best guess. Nothing you rename or change is overwritten.") { recording }
                group(3, PhoneSettingsMap.dictation, footer: "Cleanup: " + Self.cleanupNote(flow.cleanup)) { dictation }
                group(4, PhoneSettingsMap.sync) { syncAndStorage }
                group(5, PhoneSettingsMap.account) { account }
                group(6, PhoneSettingsMap.support) { support }
                group(7, PhoneSettingsMap.features) { features }
                footer
                    .padding(.top, 30)
                    .id("settings-footer")
                }
            }
            .padding(.horizontal, look.isNative ? 16 : 20).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: pendingRow) { _, row in
            guard let row else { return }
            pendingRow = nil
            // A setting on a page (You › Cloud cleanup) opens that page; one on the root flashes.
            if let p = PhoneSettingsMap.page(of: row).flatMap(SettingsSubpage.init(rawValue:)) {
                open(p)
            } else {
                flashRow(row, label: SettingsSearchIndex.all.first { $0.id == row }?.label ?? "", proxy)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimSettingsScroll)) { note in
            guard let id = note.object as? String else { return }
            withAnimation(nil) { proxy.scrollTo(id, anchor: .top) }
        }
        }
        .phonePage()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(look.isNative ? .visible : .hidden, for: .navigationBar)
        .navigationDestination(item: $page) { p in destination(p).settingsSubpage(p) }
        .navigationDestination(isPresented: $showYou) {
            YouScreen { row in
                showYou = false
                // The row's page opens (or the row flashes) after the pop has finished.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { pendingRow = row }
            }
        }
        .navigationDestination(isPresented: $showVoice) { VoiceProfileScreen(preview: voicePreview) }
        .navigationDestination(isPresented: $showAcknowledgements) { AcknowledgementsView().navigationTitle("Acknowledgements") }
        // Home's This week card opens the You page, and its keyboard row opens Keyboard (SettingsPage, HomeScreen.swift).
        // On the tab's first appearance (Home's What's new note creates it), the push waits a turn of the main loop: a
        // destination presented during the stack's own first appearance can push before the stack is in the window.
        .onAppear { DispatchQueue.main.async { openRequestedPage() } }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimOpenSettingsPage)) { _ in openRequestedPage() }
        // UI tour: `false` closes the You page (and anything pushed from it).
        .onReceive(NotificationCenter.default.publisher(for: .verbatimYouPage)) { note in
            if note.object as? Bool == false { showYou = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimShowVoiceProfile)) { note in
            let open = note.object as? Bool ?? false
            voicePreview = open
            showVoice = open
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .alert("Turn off iCloud sync?", isPresented: $confirmSyncOff) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off") { turnSyncOff() }
        } message: {
            Text("Verbose copies your library onto this iPhone, then stops syncing the next time it opens. Your Mac keeps what's already in iCloud.")
        }
        .alert("Delete all data?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
                // The second question waits for the first alert to finish closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmDeleteFinal = true }
            }
        } message: {
            Text(Cloud.enabled
                 ? "This removes your transcripts, recordings, projects, and Dictionary from this iPhone and from iCloud, so they're gone from your Mac too. It can't be undone."
                 : "This removes your transcripts, recordings, projects, and Dictionary from this iPhone. It can't be undone.")
        }
        .alert(deleteTitle, isPresented: $confirmDeleteFinal) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive) { app.deleteAllData() }
        } message: {
            Text(deleteDetail)
        }
    }

    /// Each page a root row, a search result, or a request opens.
    @ViewBuilder private func destination(_ p: SettingsSubpage) -> some View {
        switch p {
        case .aboutMe: AboutMeScreen()
        case .dictionary: DictionaryScreen()
        case .keyboard: KeyboardSetupScreen()
        case .snippets: SnippetsScreen()
        case .actionButton: ActionButtonScreen()
        case .appearance: AppearanceScreen()
        case .whatsNew: WhatsNewScreen()
        case .speakers: SpeakersSettingsScreen()
        case .moreTranscription: MoreTranscriptionScreen()
        case .cloudCleanup: CloudCleanupScreen()
        case .privacy: PhonePrivacyScreen()
        case .tour: WelcomeTourScreen()
        case .widgets: WidgetsInfoScreen()
        case .shortcuts: ShortcutsInfoScreen()
        case .customizeHome: CustomizeHomeDestination()
        case .thoughts: ThoughtsSettingsScreen()
        case .tabBar: TabBarSettingsScreen()
        case .templates: TemplatesAutoScreen()
        }
    }

    // MARK: You

    @AppStorage("profile.name") private var profileName = ""

    /// You: your initial on the record color, your name in the serif (the last name in italic), and what's inside.
    /// Opens the You page.
    @ViewBuilder private var youCard: some View {
        if look.isNative { nativeYouCard } else { verboseYouCard }
    }

    // brand: native begin
    /// Native: the Apple Account-style row: a gray initials avatar, your name in semibold, and the same subtitle.
    private var nativeYouCard: some View {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button { showYou = true } label: {
            HStack(spacing: 14) {
                NativeAvatar(name: name, size: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "You" : name).font(.title3.weight(.semibold)).foregroundStyle(NativeInk.label).lineLimit(1)
                    Text("About me, your voice, your week, and cleanup").font(.footnote).foregroundStyle(NativeInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(NativeInk.card, in: RoundedRectangle(cornerRadius: NativeMetrics.groupRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: NativeMetrics.groupRadius, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name.isEmpty ? "You" : name)
        .accessibilityHint("Opens your You page: About me, your voice, your week, and cleanup.")
    }
    // brand: native end

    private var verboseYouCard: some View {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        return Button { showYou = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(PhoneInk.record)
                    Circle().strokeBorder(Ink.inkFixed, lineWidth: 1.5)
                    if let first = name.first {
                        Text(String(first).uppercased()).lookSerif(26).foregroundStyle(Ink.inkFixed)
                    } else {
                        IconGlyph(art: .iconAboutMe, size: 24, color: Ink.inkFixed)
                    }
                }
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if parts.count == 2 { Text("\(parts[0]) ") + Text(parts[1]).italic() }
                        else { Text(name.isEmpty ? "You" : name) }
                    }
                    .lookSerif(youSize).foregroundStyle(.lookInk).lineLimit(1).minimumScaleFactor(0.8)
                    Text("About me, your voice, your week, and cleanup").font(.system(size: 13)).foregroundStyle(.lookMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .phoneOutlined(radius: Radius.record)
            .contentShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name.isEmpty ? "You" : name)
        .accessibilityHint("Opens your You page: About me, your voice, your week, and cleanup.")
    }

    @ScaledMetric(relativeTo: .title2) private var youSize: CGFloat = 22

    // MARK: Groups

    /// A root row that opens a page: icon, title, the value, and a chevron.
    private func pageRow(_ id: String, _ p: SettingsSubpage, icon: String, tint: Color, art: BrandArt?, title: String, value: String? = nil) -> some View {
        Button { bump(id); open(p) } label: {
            SettingsRow(icon: icon, tint: tint, art: art, title: title, bounce: bumps[id, default: 0]) {
                if let value { SettingsValue(value) }
                SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget(id, flash: searchFlash)
    }

    /// A root row that runs an action or opens a link: icon, title, and a chevron.
    private func actionRow(_ id: String, icon: String, tint: Color, art: BrandArt?, title: String, value: String? = nil, action: @escaping () -> Void) -> some View {
        Button { bump(id); action() } label: {
            SettingsRow(icon: icon, tint: tint, art: art, title: title, bounce: bumps[id, default: 0]) {
                if let value { SettingsValue(value) }
                SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget(id, flash: searchFlash)
    }

    @ViewBuilder private var personalization: some View {
        pageRow("appearanceRow", .appearance, icon: "circle.lefthalf.filled", tint: Ink.petalTint, art: .iconAppearance, title: "Appearance", value: look.label)
        // Customize Home (the Edit Home branch): off the root until its screen lands (CustomizeHomeEntry).
        if CustomizeHomeEntry.isAvailable {
            SettingsDivider()
            pageRow("customizeHomeRow", .customizeHome, icon: "house", tint: Ink.butterTint, art: .iconHome, title: "Customize Home", value: "Edit")
        }
        SettingsDivider()
        pageRow("tabBarRow", .tabBar, icon: "dock.rectangle", tint: Ink.sageTint, art: .iconTabBar, title: "Tab bar", value: tabBarValue)
        SettingsDivider()
        pageRow("aboutMeRow", .aboutMe, icon: "person", tint: Ink.petalTint, art: .iconAboutMe, title: "About me", value: aboutMe.isEmpty ? "Add" : "Added")
        SettingsDivider()
        Button { bump("voice"); voicePreview = false; showVoice = true } label: {
            SettingsRow(icon: "waveform", tint: Ink.persimmonTint, art: .iconVoice, title: "Your voice", bounce: bumps["voice", default: 0]) {
                SettingsValue(voice.isEnrolled ? "On" : "Set up"); SettingsChevron()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("voice", flash: searchFlash)
        SettingsDivider()
        pageRow("dictionaryRow", .dictionary, icon: "book.closed", tint: Ink.sageTint, art: .iconDictionary, title: "Dictionary",
                value: app.store.dictionary.count == 1 ? "1 word" : "\(app.store.dictionary.count) words")
        SettingsDivider()
        SettingsToggleRow(icon: "globe", tint: Ink.sageTint, art: .iconLanguage, title: "Detect the language", isOn: $detectLanguage)
            .settingsSearchTarget("language", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "tortoise", tint: PhoneInk.wash, art: .iconLimitMotion, title: "Limit animation", isOn: $motionLimited)
            .settingsSearchTarget("limitMotion", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "hand.tap", tint: PhoneInk.wash, art: .iconHaptics, title: "Haptics",
                          subtitle: "Light taps when you save, copy, or mark", isOn: $hapticsOn)
            .settingsSearchTarget("haptics", flash: searchFlash)
    }

    @ViewBuilder private var recording: some View {
        Menu {
            Picker("Quality", selection: $app.presetRaw) {
                ForEach(QualityPreset.allCases.filter { $0 != .advanced }) { p in Text(p.title).tag(p.rawValue) }
            }
        } label: {
            SettingsRow(icon: "chart.line.uptrend.xyaxis", tint: Ink.sageTint, art: .iconQuality, title: "Quality", bounce: app.presetRaw) {
                SettingsValue(app.preset.title); SettingsMenuMark()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("quality", flash: searchFlash)
        SettingsDivider()
        pageRow("speakersRow", .speakers, icon: "person.2", tint: Ink.sageTint, art: .iconSpeakers, title: "Speakers", value: app.identifySpeakers ? "Identify" : "Off")
        SettingsDivider()
        SettingsToggleRow(icon: "text.quote", tint: Ink.butterTint, art: .iconSummaries, title: "Summaries",
                          subtitle: Summarizer.unavailableReason, isOn: $autoSummary)
            .settingsSearchTarget("summaries", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "sparkles", tint: Ink.butterTint, art: .iconNameAndSort, title: "Name and sort recordings", isOn: $autoLabels)
            .settingsSearchTarget("nameAndSort", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "text.bubble", tint: Ink.persimmonTint, art: .iconDictations, title: "Show words while you record", isOn: $recordLiveWords)
            .settingsSearchTarget("recordLiveWords", flash: searchFlash)
        SettingsDivider()
        pageRow("moreTranscriptionRow", .moreTranscription, icon: "square.stack.3d.up", tint: PhoneInk.wash, art: .iconMultitrack, title: "More transcription options")
    }

    @ViewBuilder private var dictation: some View {
        pageRow("keyboardRow", .keyboard, icon: "keyboard", tint: Ink.butterTint, art: .iconDictations, title: "Keyboard", value: "Set up")
        SettingsDivider()
        pageRow("actionButtonRow", .actionButton, icon: "button.horizontal.top.press", tint: Ink.butterTint, art: .iconActionButton, title: "Action button",
                value: Ribbon.actionChoice(actionChoice).shortTitle)
        SettingsDivider()
        Menu {
            Picker("Cleanup", selection: $flow.cleanup) {
                ForEach(CleanupLevel.allCases) { l in Text(l.title).tag(l) }
            }
        } label: {
            SettingsRow(icon: "wand.and.stars", tint: Ink.butterTint, art: .refine, title: "Cleanup", bounce: flow.cleanup.rawValue) {
                SettingsValue(flow.cleanup.title); SettingsMenuMark()
            }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("cleanup", flash: searchFlash)
        SettingsDivider()
        SettingsToggleRow(icon: "arrow.uturn.backward", tint: Ink.sageTint, art: .iconSwap, title: "Spoken corrections", isOn: $spokenCorrections)
            .settingsSearchTarget("spokenCorrections", flash: searchFlash)
        SettingsDivider()
        pageRow("snippetsRow", .snippets, icon: "text.badge.plus", tint: Ink.petalTint, art: .iconQuote, title: "Snippets", value: "\(app.store.snippets.count)")
        SettingsDivider()
        pageRow("cloudCleanupRow", .cloudCleanup, icon: "cloud", tint: PhoneInk.wash, art: .iconServer, title: "Cloud cleanup", value: cloudCleanupOn ? "On" : "Off")
    }

    @ViewBuilder private var syncAndStorage: some View {
        // Local Only, Network activity, and what leaves this iPhone (PhoneTrust.swift).
        PhonePrivacyRow(bounce: bumps["privacyRow", default: 0]) { bump("privacyRow"); open(.privacy) }
            .settingsSearchTarget("privacyRow", flash: searchFlash)
        SettingsDivider()
        if Cloud.available {
            Toggle(isOn: Binding(get: { syncWanted }, set: { on in
                if on { syncWanted = true; Cloud.setWantsSync(true) } else { confirmSyncOff = true }
            })) {
                SettingsLabel(icon: syncWanted ? "icloud" : "icloud.slash", tint: Ink.sageTint, art: syncWanted ? .iconSync : .iconSyncOff, title: "iCloud sync",
                              subtitle: syncSubtitle, subtitleLines: nil, bounce: syncWanted)
            }
            .toggleStyle(.switch).tint(look.isNative ? NativeInk.toggle : PhoneInk.switchOn)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 50)
            .disabled(copyingDown)
            .settingsSearchTarget("sync", flash: searchFlash)
        } else {
            SettingsRow(icon: "icloud.slash", tint: Ink.sageTint, art: .iconSyncOff, title: "iCloud is off",
                        subtitle: "Sign in to iCloud in the Settings app to sync with your Mac. Until then, everything stays on this iPhone.",
                        subtitleLines: nil) { EmptyView() }
                .accessibilityElement(children: .combine)
                .settingsSearchTarget("sync", flash: searchFlash)
        }
        SettingsDivider()
        Button {
            bump("export")
            exporting = true
            Task {
                exportURL = await app.exportEverything()
                exporting = false
            }
        } label: {
            SettingsRow(icon: "square.and.arrow.down", tint: Ink.petalTint, art: .iconExport, title: "Export everything", bounce: bumps["export", default: 0]) {
                if exporting { ProgressView().controlSize(.small) } else { SettingsValue("Zip"); SettingsChevron() }
            }
        }
        .buttonStyle(SettingsRowPress())
        .disabled(exporting)
        .settingsSearchTarget("export", flash: searchFlash)
        SettingsDivider()
        Button { bump("delete"); confirmDelete = true } label: {
            SettingsRow(icon: "trash", tint: Ink.persimmonTint, art: .iconDeleteAll, title: "Delete all data", bounce: bumps["delete", default: 0], danger: true) { EmptyView() }
        }
        .buttonStyle(SettingsRowPress())
        .settingsSearchTarget("deleteAll", flash: searchFlash)
    }

    @ViewBuilder private var account: some View {
        // Verbose has no account; your name is shown here and edited in About me.
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        pageRow("yourNameRow", .aboutMe, icon: "person.crop.circle", tint: Ink.petalTint, art: .iconAboutMe, title: "Your name", value: name.isEmpty ? "Add" : name)
    }

    /// What the cleanup level does to keyboard dictations, and what happens without Apple Intelligence. Also on the
    /// You page.
    static func cleanupNote(_ level: CleanupLevel) -> String {
        let what: String
        switch level {
        case .none: what = "Keyboard dictations go in as spoken, with punctuation and capitals."
        case .light: what = "Removes ums, repeats, and false starts, and turns spoken lists into lists. Keeps your wording."
        case .medium: what = "Everything Clean does, plus fixes grammar, splits run-on sentences, and smooths rambling. Keeps your meaning and voice."
        }
        guard level.usesModel, !FlowCleanup.available else { return what }
        return what + " Without Apple Intelligence on this iPhone, rules remove ums, repeats, and false starts, fix capitals and “a” or “an,” and make lists and paragraphs."
    }

    /// The sync row's line while something is happening; nil once it has settled (the switch says the rest).
    private var syncSubtitle: String? {
        if copyingDown { return "Copying your library to this iPhone…" }
        if copyFailed > 0 { return "\(copyFailed) file\(copyFailed == 1 ? "" : "s") couldn't be downloaded from iCloud, so sync is still on. Check your connection and try again." }
        if syncWanted != Cloud.enabled {
            return syncWanted ? "Starts the next time you open Verbose." : "Your library is on this iPhone. Syncing stops the next time you open Verbose (swipe it away to finish now)."
        }
        return nil
    }

    private func turnSyncOff() {
        guard Cloud.enabled else { syncWanted = false; Cloud.setWantsSync(false); return }
        copyingDown = true; copyFailed = 0
        Task {
            app.store.flush()
            let r = await Task.detached(priority: .userInitiated) { () -> (copied: Int, failed: Int) in
                TranscriptFiles.queue.sync {}   // queued saves land in iCloud before the copy reads it
                return Cloud.copyToDevice()
            }.value
            copyFailed = r.failed
            if r.failed == 0 { Cloud.setWantsSync(false); syncWanted = false }
            copyingDown = false
        }
    }

    @ViewBuilder private var support: some View {
        actionRow("support", icon: "bubble.left", tint: Ink.sageTint, art: .iconSupport, title: "Contact support") {
            if let u = Links.mail(subject: "Verbose support") { openURL(u) }
        }
        SettingsDivider()
        actionRow("feedback", icon: "pencil", tint: Ink.butterTint, art: .iconFeedback, title: "Share feedback") {
            if let u = Links.mail(subject: "Verbose feedback") { openURL(u) }
        }
        SettingsDivider()
        ShareLink(item: Log.file, subject: Text("Verbose diagnostic log"),
                  message: Text("Send to \(Links.supportEmail)")) {
            SettingsRow(icon: "stethoscope", tint: PhoneInk.wash, art: .iconDiagnosticLog, title: "Send diagnostic log", bounce: bumps["log", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .simultaneousGesture(TapGesture().onEnded { bump("log"); Log.trimNow() })
        .accessibilityHint("7 days of app events, without links or folder names")
        .settingsSearchTarget("log", flash: searchFlash)
        SettingsDivider()
        actionRow("privacy", icon: "lock", tint: Ink.sageTint, art: .iconPrivacy, title: "Privacy policy") { openURL(Links.privacy) }
        SettingsDivider()
        actionRow("terms", icon: "doc.text", tint: PhoneInk.wash, art: .iconTerms, title: "Terms of use") { openURL(Links.terms) }
        SettingsDivider()
        ShareLink(item: Links.base) {
            SettingsRow(icon: "square.and.arrow.up", tint: Ink.petalTint, art: .iconShare, title: "Share Verbose", bounce: bumps["share", default: 0]) { SettingsChevron() }
        }
        .buttonStyle(SettingsRowPress())
        .simultaneousGesture(TapGesture().onEnded { bump("share") })
        .settingsSearchTarget("share", flash: searchFlash)
        SettingsDivider()
        actionRow("acknowledgements", icon: "doc.plaintext", tint: PhoneInk.wash, art: .iconDetails, title: "Acknowledgements") { showAcknowledgements = true }
    }

    @ViewBuilder private var features: some View {
        pageRow("thoughtsRow", .thoughts, icon: "lightbulb", tint: Ink.butterTint, art: .iconThought, title: "Thoughts",
                value: Self.thoughtsValue(app.store.todaysThoughts().count))
        SettingsDivider()
        pageRow("templatesRow", .templates, icon: "doc.text", tint: Ink.sageTint, art: .iconSummaries, title: "Templates",
                value: Self.templatesValue(TemplateSettingsModel.shared.settings.assignedCount))
        SettingsDivider()
        pageRow("widgetsRow", .widgets, icon: "square.grid.2x2", tint: Ink.persimmonTint, art: .iconHome, title: "Widgets and controls")
        SettingsDivider()
        pageRow("shortcutsRow", .shortcuts, icon: "bolt.circle", tint: Ink.sageTint, art: .iconAI, title: "Shortcuts and Siri")
        SettingsDivider()
        pageRow("tourRow", .tour, icon: "play.rectangle", tint: Ink.sageTint, art: .iconTour, title: "Welcome tour")
    }

    /// Thoughts' row: today's count ("3 today"), or nothing yet.
    static func thoughtsValue(_ n: Int) -> String? { n > 0 ? "\(n) today" : nil }

    /// Templates' row: how many kinds run one automatically ("2 automatic"), or Off.
    static func templatesValue(_ n: Int) -> String { n > 0 ? "\(n) automatic" : "Off" }

    private var footer: some View {
        // "Version 1.0 beta (217)": the marketing version, the channel, and the build (VERSIONING.md).
        VStack(spacing: 6) {
            // The lockup (DESIGN.md §4) and the tagline in the serif. Native keeps only the version lines.
            if !look.isNative {
                HStack(spacing: 8) {
                    BarsMark(color: Ink.persimmon).frame(width: 17, height: 18)
                    Ink.wordmark(22)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("Verbose")
                Text(Ink.tagline).lookSerif(16).foregroundStyle(.lookDim).padding(.bottom, 6)
            }
            // The version opens What's new.
            Button { open(.whatsNew) } label: {
                VStack(spacing: 2) {
                    Text("Version \(AppVersion.label)")
                    Text("What's new").fontWeight(.semibold).foregroundStyle(.lookAccentText)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Version \(AppVersion.spoken). What's new")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows what's new in each build")
            .settingsSearchTarget("version", flash: searchFlash)
            Text("Verbose · Stump & Root Co.")
        }
        .font(.system(size: 12.5)).foregroundStyle(.lookMute)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: Helpers

    @ViewBuilder private func group<Rows: View>(_ index: Int, _ title: String, footer: String? = nil, @ViewBuilder _ rows: () -> Rows) -> some View {
        if look.isNative {
            // Native: an inset grouped section with a sentence-case header.
            let content = rows()
            NativeGroup(header: title, footer: footer) { content }
                .padding(.top, 26)
                .id("group-\(index)")
        } else {
            verboseGroup(index, title, footer: footer, rows)
        }
    }

    private func verboseGroup<Rows: View>(_ index: Int, _ title: String, footer: String? = nil, _ rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).lookMono(12).foregroundStyle(.lookMute)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { rows() }
                .background(.lookCard, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.record, style: .continuous).strokeBorder(.lookHairline))
            if let footer {
                Text(footer).font(.system(size: 13)).foregroundStyle(.lookMute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.top, 22)
        .id("group-\(index)")
    }

    private func bump(_ key: String) { bumps[key, default: 0] += 1 }

    /// Pushes a page. Asking for one while another is showing swaps it, so a request always lands on its page.
    private func open(_ p: SettingsSubpage) {
        if p == .customizeHome && !CustomizeHomeEntry.isAvailable { return }
        page = p
    }

    private func openRequestedPage() {
        guard let name = SettingsPage.take() else { return }
        switch name {
        case "you": showYou = true
        // Back to Settings itself (the screenshot tour, between subpages).
        case "root": page = nil
        default: if let p = SettingsSubpage(rawValue: name) { open(p) }
        }
    }

    /// A search result was chosen: clear the search, then push its subpage, or scroll to its row and flash it.
    private func pickSearchResult(_ entry: SettingsSearchEntry, _ proxy: ScrollViewProxy) {
        search.query = ""
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        switch entry.target {
        case .page(let p): open(p)
        case .row: flashRow(entry.id, label: entry.label, proxy)
        }
    }

    /// Scrolls to a row and flashes it (a search result, or a row the You page links to).
    private func flashRow(_ id: String, label: String, _ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)   // the groups lay out again first
            withAnimation(limitMotion ? nil : Motion.nav) { proxy.scrollTo(id, anchor: .center) }
            searchFlash = id
            if !label.isEmpty { AccessibilityNotification.Announcement(label).post() }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if searchFlash == id { searchFlash = nil }
        }
    }

    private var deleteTitle: String {
        let n = app.store.transcripts.count
        return n == 1 ? "Delete 1 transcript?" : "Delete \(n) transcripts?"
    }

    private var deleteDetail: String {
        let n = app.store.transcripts.count, p = app.store.projects.count, w = app.store.dictionary.count
        let things = n == 1 ? "the 1 transcript" : "all \(n) transcripts"
        let projects = p == 1 ? "1 project" : "\(p) projects"
        let words = w == 1 ? "1 Dictionary word" : "\(w) Dictionary words"
        return "Verbose deletes \(things) (Recently Deleted too) with their audio, plus \(projects) and \(words), for good."
    }
}

// MARK: - Rows

/// The icon tile and the text of a settings row. The icon bounces once each time `bounce` changes.
struct SettingsLabel: View {
    var icon: String
    var tint: Color
    /// A fine-line Verbatim icon in place of the symbol.
    var art: BrandArt? = nil
    var title: String
    var subtitle: String? = nil
    var subtitleLines: Int? = 2
    var bounce: AnyHashable = 0
    var danger = false
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative { native } else { verbose }
    }

    // brand: native begin
    /// Native: the row's SF Symbol tinted (no colored square, so persimmon stays the only color), then the title.
    private var native: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17))
                .foregroundStyle(danger ? NativeInk.danger : NativeInk.accent)
                .symbolEffect(.bounce, value: bounce)
                .symbolEffectsRemoved(limitMotion)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(danger ? NativeInk.danger : NativeInk.label)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(NativeInk.secondary)
                        .lineLimit(subtitleLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
        }
    }
    // brand: native end

    private var verbose: some View {
        HStack(spacing: 12) {
            ZStack {
                // Neutral squares with ink glyphs: a settings row is a tool, and tools stay neutral (DESIGN.md §1).
                // Destructive rows keep the neutral square with the danger color.
                let square = danger ? Ink.neutralChip : SettingsLabel.square(for: tint)
                let on = danger ? Ink.danger : Ink.ink
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(square)
                if let art {
                    IconGlyph(art: art, size: 17, color: on)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on)
                        .symbolEffect(.bounce, value: bounce)
                        .symbolEffectsRemoved(limitMotion)
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(danger ? Ink.danger : Ink.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.lookMute)
                        .lineLimit(subtitleLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
        }
    }

    /// Every row's square is the neutral wash, whatever tint the call site passes: the brand hues mean capture modes
    /// (persimmon Record, butter Dictate, sage Import, petal App audio), so a settings row never borrows one (P-01).
    static func square(for tint: Color) -> Color { PhoneInk.wash }
}

/// One settings row: icon tile, title and subtitle, then a value, chevron, or control.
struct SettingsRow<Trailing: View>: View {
    var icon: String
    var tint: Color
    var art: BrandArt? = nil
    var title: String
    var subtitle: String? = nil
    var subtitleLines: Int? = 2
    var bounce: AnyHashable = 0
    var danger = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            SettingsLabel(icon: icon, tint: tint, art: art, title: title, subtitle: subtitle, subtitleLines: subtitleLines, bounce: bounce, danger: danger)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// A row with a switch that settles with a small spring. The icon bounces when it changes.
struct SettingsToggleRow: View {
    var icon: String
    var tint: Color
    var art: BrandArt? = nil
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    @Environment(\.look) private var look

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLabel(icon: icon, tint: tint, art: art, title: title, subtitle: subtitle, subtitleLines: nil, bounce: isOn)
        }
        // Native: system switches stay green, as in Apple's own apps.
        .toggleStyle(.switch).tint(look.isNative ? NativeInk.toggle : PhoneInk.switchOn)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 50)
    }
}

struct SettingsValue: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 16)).foregroundStyle(.lookMute).lineLimit(1) }
}

struct SettingsChevron: View {
    @Environment(\.look) private var look
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(look.isNative ? NativeInk.tertiary : Ink.mute).accessibilityHidden(true)
    }
}

/// Marks a row that opens a menu of choices.
struct SettingsMenuMark: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(.lookMute).accessibilityHidden(true)
    }
}

/// The hairline between rows, inset past the icon tile.
struct SettingsDivider: View {
    @Environment(\.look) private var look
    var body: some View {
        if look.isNative { NativeDivider(leading: 54) } else { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 56) }
    }
}

/// Rows highlight while pressed (a color change, not movement). Native: the system's gray row highlight.
struct SettingsRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.look) private var look
        var body: some View {
            if look.isNative {
                NativeRowPress().makeBody(configuration: configuration)
            } else {
                configuration.label
                    .background(Ink.ink.opacity(configuration.isPressed ? 0.05 : 0))
                    .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
            }
        }
    }
}

// MARK: - About me

/// Your name (Home greeting, email sign-offs) and a few lines of context (up to 300 characters) for wording titles
/// and summaries. Both sync with your Mac through iCloud when sync is on.
struct AboutMeScreen: View {
    @AppStorage(Profile.aboutMeKey) private var aboutMe = ""
    @AppStorage("profile.name") private var name = ""
    @FocusState private var focused: Bool
    /// Whether About me is on screen, for the UI tour's checks.
    static var visible = false

    var body: some View {
        // The Settings page scaffold: the serif compact title, as Appearance and Templates use, and the shared labels.
        SettingsPageScaffold(title: "About me") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsPageLabel(text: "Your name")
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .font(.system(size: 16)).foregroundStyle(.lookInk)
                    .padding(.horizontal, 14).frame(height: 48)
                    .background(.lookCard, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(.lookHairline))
                    .accessibilityLabel("Your name")
                SettingsPageLabel(text: "About me").padding(.top, 10)
                ZStack(alignment: .topLeading) {
                    if aboutMe.isEmpty {
                        Text("For example: I'm a teacher. I record lessons and parent meetings, and often mention Room 12 and the spring fair.")
                            .font(.system(size: 16)).foregroundStyle(.lookFaint)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $aboutMe)
                        .focused($focused)
                        .font(.system(size: 16)).foregroundStyle(.lookInk)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .accessibilityLabel("About me")
                }
                .padding(10)
                .background(.lookCard, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(.lookHairline))
                .onChange(of: aboutMe) { _, v in
                    if v.count > Profile.aboutMeLimit { aboutMe = String(v.prefix(Profile.aboutMeLimit)) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Verbose uses this on device to spell names correctly and to write titles and summaries. It syncs with your Mac when iCloud sync is on.")
                        .font(.system(size: 13)).foregroundStyle(.lookMute)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("\(aboutMe.count)/\(Profile.aboutMeLimit)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.lookMute)
                        .accessibilityLabel("\(aboutMe.count) of \(Profile.aboutMeLimit) characters")
                }
                .padding(.horizontal, 4)
            }
            .padding(.top, 14)
        }
        .onAppear { Self.visible = true; if aboutMe.isEmpty, !PhoneUITest.enabled { focused = true } }
        .onDisappear { Self.visible = false }
    }
}
