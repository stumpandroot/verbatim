import SwiftUI
import UIKit

// The Settings pages the regrouped root opens (PhoneSettingsMap, SettingsScreen.swift): Speakers, More transcription
// options, Cloud cleanup, Welcome tour, Widgets and controls, and Shortcuts and Siri, plus the spot Customize Home
// fills. Each page uses the root's rows and groups in both looks, and every row keeps the search id it had on the
// root, so search and the self-test find it here.

// MARK: - Page structure

/// A Settings page: Verbose style's compact serif title on the paper (Native uses the inline navigation title), then
/// its groups.
struct SettingsPageScaffold<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.look) private var look

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !look.isNative {
                    PhoneCompactTitle(title: title).padding(.top, 2)
                }
                content()
            }
            .padding(.horizontal, look.isNative ? 16 : 20).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .phonePage()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Verbose style puts the serif title on the paper.
            if !look.isNative {
                ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
            }
        }
    }
}

/// A group on a Settings page, as on the root: Native's inset grouped section, or Verbose style's mono label over a
/// card with a hairline edge.
struct SettingsPageGroup<Rows: View>: View {
    var title: String? = nil
    var footer: String? = nil
    var first = false
    @ViewBuilder var rows: () -> Rows
    @Environment(\.look) private var look

    var body: some View {
        Group {
            if look.isNative {
                let content = rows()
                NativeGroup(header: title, footer: footer) { content }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let title {
                        Text(title).lookMono(12).foregroundStyle(.lookMute)
                            .padding(.horizontal, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
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
            }
        }
        .padding(.top, first ? (look.isNative ? 8 : 18) : 26)
    }
}

extension View {
    /// Marks a pushed Settings page, so the self-test knows which page a search result opened.
    func settingsSubpage(_ page: SettingsSubpage) -> some View {
        self
            .onAppear { SettingsRowRegistry.page = page }
            .onDisappear { if SettingsRowRegistry.page == page { SettingsRowRegistry.page = nil } }
    }
}

// MARK: - Speakers

/// Settings › Speakers: who's talking in a recording, and the voices you've named.
struct SpeakersSettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    @AppStorage(Transcript.mainSpeakerOnlyKey) private var mainSpeakerOnly = false
    /// Recognize voices I've named (SpeakerVoices): on device only, never synced.
    @AppStorage(SpeakerVoices.enabledKey) private var recognizeVoices = true
    @State private var savedVoices = 0
    @State private var confirmClear = false

    var body: some View {
        SettingsPageScaffold(title: "Speakers") {
            SettingsPageGroup(footer: "Speaker labels are made on this iPhone and add a little time to each transcript.", first: true) {
                SettingsToggleRow(icon: "person.2", tint: Ink.sageTint, art: .iconSpeakers, title: "Identify speakers",
                                  subtitle: "Labels turns as Speaker 1, Speaker 2, and so on, so you can name them", isOn: $app.identifySpeakers)
                    .settingsSearchTarget("speakers", flash: nil)
                SettingsDivider()
                SettingsToggleRow(icon: "person", tint: Ink.sageTint, art: .iconMainSpeaker, title: "Main speaker only",
                                  subtitle: "In voice memos, other voices fold into a Background voices section", isOn: $mainSpeakerOnly)
                    .settingsSearchTarget("mainSpeaker", flash: nil)
            }
            SettingsPageGroup(title: "Voices you've named") {
                SettingsToggleRow(icon: "person.2", tint: Ink.petalTint, art: .iconVoice, title: "Recognize voices I\u{2019}ve named",
                                  subtitle: "Suggests a name when a new speaker sounds like someone you named. The voices stay on this iPhone and are never synced.",
                                  isOn: $recognizeVoices)
                    .settingsSearchTarget("recognizeVoices", flash: nil)
                SettingsDivider()
                Button { confirmClear = true } label: {
                    SettingsRow(icon: "trash", tint: Ink.petalTint, art: .iconDeleteAll, title: "Clear saved voices",
                                subtitle: savedVoices == 0 ? "No saved voices" : "\(savedVoices) saved voice\(savedVoices == 1 ? "" : "s"), on this iPhone only") { EmptyView() }
                }
                .buttonStyle(SettingsRowPress())
                .disabled(savedVoices == 0)
                .settingsSearchTarget("clearVoices", flash: nil)
            }
        }
        .onAppear { savedVoices = SpeakerVoices.namedCount }
        .alert("Clear saved voices?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { SpeakerVoices.clear(); savedVoices = 0 }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Verbose forgets the voices of the speakers you\u{2019}ve named. Names you gave stay.")
        }
    }
}

// MARK: - More transcription options

/// Settings › More transcription options: the switches people rarely change.
struct MoreTranscriptionScreen: View {
    @EnvironmentObject var app: PhoneState
    @AppStorage(Transcript.hideFillerKey) private var hideFiller = true
    @AppStorage(Transcript.skipSponsorsKey) private var skipSponsors = true
    @AppStorage(AudioTracksPreference.key) private var audioTracks = AudioTracksPreference.mix.rawValue

    var body: some View {
        SettingsPageScaffold(title: "More options") {
            SettingsPageGroup(title: "Transcripts", first: true) {
                SettingsToggleRow(icon: "eye.slash", tint: Ink.petalTint, art: .iconFiller, title: "Hide filler lines",
                                  subtitle: "Lines that are only \u{201C}um\u{201D} or \u{201C}uh\u{201D} stay out of view, never deleted", isOn: $hideFiller)
                    .settingsSearchTarget("hideFiller", flash: nil)
                SettingsDivider()
                SettingsToggleRow(icon: "checkmark", tint: Ink.sageTint, art: .iconApplyDictionary, title: "Apply Dictionary",
                                  subtitle: "Fixes words listed under \u{201C}Heard as\u{201D} in new transcripts", isOn: $app.applyDictionary)
                    .settingsSearchTarget("applyDictionary", flash: nil)
                SettingsDivider()
                Menu {
                    Picker("Files with several audio tracks", selection: $audioTracks) {
                        ForEach(AudioTracksPreference.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    SettingsRow(icon: "square.stack.3d.up", tint: Ink.petalTint, art: .iconMultitrack, title: "Files with several audio tracks",
                                subtitle: audioTracks == AudioTracksPreference.separate.rawValue
                                    ? "Each track is transcribed on its own as a speaker you can rename"
                                    : "Every track is mixed into one transcript",
                                subtitleLines: nil, bounce: audioTracks) {
                        SettingsValue(audioTracks == AudioTracksPreference.separate.rawValue ? "Separate" : "Mix"); SettingsMenuMark()
                    }
                }
                .buttonStyle(SettingsRowPress())
                .settingsSearchTarget("audioTracks", flash: nil)
            }
            SettingsPageGroup(title: "Playback") {
                SettingsToggleRow(icon: "tag", tint: Ink.butterTint, art: .iconSponsor, title: "Skip sponsor reads",
                                  subtitle: "In podcasts and videos, playback jumps past sponsor reads, and they fold into a line", isOn: $skipSponsors)
                    .settingsSearchTarget("skipSponsors", flash: nil)
            }
        }
    }
}

// MARK: - Cloud cleanup

/// Settings › Cloud cleanup: off by default; the provider, your key, and the model inside (CloudCleanupRows.swift).
struct CloudCleanupScreen: View {
    var body: some View {
        SettingsPageScaffold(title: "Cloud cleanup") {
            SettingsPageGroup(footer: "Without a connection, or if a request fails, Verbose cleans up on this iPhone.", first: true) {
                CloudCleanupRows(searchFlash: nil)
            }
        }
    }
}

// MARK: - Welcome tour

/// Settings › Welcome tour: show it again now, or each time Verbose opens.
struct WelcomeTourScreen: View {
    @EnvironmentObject var app: PhoneState

    var body: some View {
        SettingsPageScaffold(title: "Welcome tour") {
            SettingsPageGroup(footer: "A short walk through recording, the keyboard, and the Action button.", first: true) {
                Button { app.showOnboarding = true } label: {
                    SettingsRow(icon: "play.rectangle", tint: Ink.sageTint, art: .iconTour, title: "Show Tour") { SettingsChevron() }
                }
                .buttonStyle(SettingsRowPress())
                .settingsSearchTarget("tour", flash: nil)
                SettingsDivider()
                SettingsToggleRow(icon: "sparkles", tint: Ink.petalTint, art: .iconTour, title: "Show it when Verbose opens",
                                  isOn: Binding(get: { Onboarding.showOnLaunch }, set: { Onboarding.showOnLaunch = $0; app.objectWillChange.send() }))
                    .settingsSearchTarget("tourOnLaunch", flash: nil)
            }
        }
    }
}

// MARK: - Widgets and controls

/// Settings › Widgets and controls: what Verbose offers on the Home Screen, the Lock Screen, and in Control Center,
/// and how to add each (VerbatimWidgets).
struct WidgetsInfoScreen: View {
    private static let widgets: [(String, String)] = [
        ("Record and dictate", "Start a voice note or a dictation session with one tap."),
        ("Recent recordings", "Your latest recordings and dictations. Open one to read its transcript."),
        ("This week", "Words you dictated this week, day by day."),
        ("New thought", "Starts a thought at once, behind a Live Activity. It lands on today's Thoughts page."),
        ("Today's thoughts", "The last two thoughts on today's page, and New thought."),
        ("Thoughts", "On the Lock Screen: starts a thought. The rectangular one shows today's count, never your words."),
    ]
    private static let controls: [(String, String)] = [
        ("Verbose session", "Turns the microphone on for dictation in any app, or off."),
        ("Verbose action", "Does what you chose in Settings › Action button, and takes that choice's name."),
        ("Record voice note", "Starts a voice note, in place when iOS allows it."),
        ("Dictate", "Starts a dictation session, so you can dictate in any app."),
        ("New thought", "Starts a thought, in place when iOS allows it. Press it again to stop."),
    ]

    var body: some View {
        SettingsPageScaffold(title: "Widgets and controls") {
            SettingsPageGroup(title: "Widgets", footer: "Touch and hold the Home Screen, tap Edit, then Add Widget, and search for Verbose. On the Lock Screen, touch and hold it and tap Customize.", first: true) {
                infoRows(Self.widgets, icon: "square.grid.2x2", art: .iconHome)
                    .settingsSearchTarget("widgets", flash: nil)
            }
            SettingsPageGroup(title: "Controls", footer: "Open Control Center, touch and hold an empty spot, tap Add a Control, and search for Verbose. The same controls can go on the Lock Screen or the Action button.") {
                infoRows(Self.controls, icon: "switch.2", art: .iconActionButton)
            }
        }
    }

    @ViewBuilder private func infoRows(_ items: [(String, String)], icon: String, art: BrandArt) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { SettingsDivider() }
                SettingsRow(icon: icon, tint: Ink.sageTint, art: art, title: item.0, subtitle: item.1, subtitleLines: nil) { EmptyView() }
                    .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Shortcuts and Siri

/// Settings › Shortcuts and Siri: the App Shortcuts Verbose offers (KeyboardSessionShortcuts.swift) and a way into
/// the Shortcuts app.
struct ShortcutsInfoScreen: View {
    @Environment(\.openURL) private var openURL
    private static let shortcuts: [(String, String)] = [
        ("Action button", "Does what you chose in Settings › Action button. Say \u{201C}Verbose action button.\u{201D}"),
        ("Dictate", "Starts or stops a dictation. Say \u{201C}Dictate with Verbose.\u{201D}"),
        ("Start dictation session", "Turns the microphone on for the Verbose keyboard. Say \u{201C}Start a Verbose session.\u{201D}"),
        ("New thought", "Starts a thought that lands on today's Thoughts page. Say \u{201C}New thought in Verbose.\u{201D}"),
    ]

    var body: some View {
        SettingsPageScaffold(title: "Shortcuts and Siri") {
            SettingsPageGroup(footer: "Ask Siri with the phrase under each one, find them in Spotlight, or add them to your own shortcuts.", first: true) {
                VStack(spacing: 0) {
                    ForEach(Array(Self.shortcuts.enumerated()), id: \.offset) { i, item in
                        if i > 0 { SettingsDivider() }
                        SettingsRow(icon: "bolt.circle", tint: Ink.sageTint, art: .iconAI, title: item.0, subtitle: item.1, subtitleLines: nil) { EmptyView() }
                            .accessibilityElement(children: .combine)
                    }
                }
                .settingsSearchTarget("shortcuts", flash: nil)
            }
            SettingsPageGroup {
                Button { if let u = URL(string: "shortcuts://") { openURL(u) } } label: {
                    SettingsRow(icon: "arrow.up.forward.app", tint: Ink.butterTint, art: .iconLinks, title: "Open Shortcuts") { SettingsChevron() }
                }
                .buttonStyle(SettingsRowPress())
            }
        }
    }
}

// MARK: - Customize Home

/// Settings › Personalization › Customize Home: Edit Home (EditHome.swift), pushed. The same screen opens as a sheet
/// from the Edit Home button at the end of Home.
enum CustomizeHomeEntry {
    static let isAvailable = true
}

struct CustomizeHomeDestination: View {
    var body: some View { EditHomeView() }
}
