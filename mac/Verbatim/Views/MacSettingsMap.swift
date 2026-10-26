// The Mac Settings window's layout as data: its panes in sidebar order (the iPhone's seven groups plus the Mac-only
// panes, from the premium mockup's section 02), each pane's sections, and every setting in them. SettingsTab takes
// its titles from here, SettingsIndex's sections have to agree with it, and mac/tools/test-settings-map.sh checks on
// Linux that every setting and every stored key sits in exactly one place. Pure Swift (no SwiftUI or AppKit), so the
// test can compile it on its own.
//
// A setting's `id` is its SettingsIndex id. `keys` are the UserDefaults keys it stores, when it has one of its own;
// rows that show another row's value (the three "Show words as you speak" rows are one switch; Meetings' microphone
// is Speakers') list none.

enum MacSettingsMap {
    struct Setting {
        var id: String
        var keys: [String] = []
        init(_ id: String, keys: [String] = []) { self.id = id; self.keys = keys }
    }

    struct Section {
        var title: String?
        var settings: [Setting]
        init(_ title: String?, _ settings: [Setting]) { self.title = title; self.settings = settings }
    }

    /// A pane: its `SettingsTab` raw value (kept from the old window where the pane took over, so stored choices and
    /// links still land), sidebar title, and sections. `inSidebar` is false for What's new, which the version opens.
    struct Pane {
        var raw: String
        var title: String
        var sections: [Section]
        var inSidebar = true
    }

    static let panes: [Pane] = [
        Pane(raw: "general", title: "Personalization and preferences", sections: [
            Section(nil, [
                Setting("general.look", keys: ["appearance.look"]),
                Setting("general.appearance", keys: ["appearance"]),
                Setting("general.limitMotion", keys: ["motion.limited"]),
                Setting("general.menuBar"),
                Setting("general.sounds"),
            ]),
            // Customize Home (Edit Home's list, EditHome.swift) and the This week switch, which sets the same layout.
            Section("Home", [Setting("general.customizeHome"), Setting("general.homeWeek")]),
            Section("About you", [Setting("general.aboutMe", keys: ["profile.aboutMe"])]),
            Section("Your voice", [Setting("speakers.voiceProfile"), Setting("speakers.onlyMyVoice")]),
            Section("Dictionary and language", [
                Setting("models.detectLanguage", keys: ["language.detect"]),
                Setting("models.builtInVocabulary", keys: ["vocabulary.builtIn"]),
                Setting("models.projectVocab"),
            ]),
        ]),
        Pane(raw: "transcription", title: "Recording and transcription", sections: [
            Section("Model", [Setting("models.quality", keys: ["preset"]), Setting("models.engine"), Setting("models.offline")]),
            Section("Speakers", [
                Setting("speakers.identify", keys: ["identifySpeakers"]),
                Setting("speakers.recognizeVoices", keys: ["voice.recognizeNamed"]),
                Setting("speakers.clearVoices"),
                Setting("speakers.mainOnly", keys: ["transcript.mainSpeakerOnly"]),
                Setting("speakers.mic"),
            ]),
            Section("When a transcript is ready", [
                Setting("models.nameSort", keys: ["labels.auto"]),
                Setting("models.summary", keys: ["summary.auto"]),
                Setting("models.hideFiller", keys: ["transcript.hideFiller"]),
                Setting("models.applyDictionary", keys: ["applyDictionary"]),
            ]),
            Section("While you record", [Setting("models.recordLiveWords", keys: ["record.liveWords"])]),
            Section("More options", [
                Setting("speakers.audioTracks", keys: ["import.audioTracks"]),
                Setting("models.skipSponsors", keys: ["playback.skipSponsors"]),
            ]),
        ]),
        Pane(raw: "dictate", title: "Dictation and keyboard", sections: [
            Section(nil, [Setting("dictate.enabled")]),
            Section("Starting and stopping", [
                Setting("dictate.hotkey"), Setting("dictate.mode"), Setting("dictate.shortcuts"),
                Setting("dictate.recall", keys: ["dictation.recentShortcut"]),
                Setting("dictate.lowerAudio"), Setting("dictate.autoSend"), Setting("dictate.maxMinutes"),
            ]),
            Section("Cleanup", [
                Setting("dictate.cleanup", keys: ["flow.cleanup"]),
                Setting("dictate.spokenCorrections", keys: ["flow.spokenCorrections"]),
                Setting("dictate.cleanupHelp"),
                Setting("dictate.cloud", keys: ["cleanup.cloud.enabled"]),
                Setting("dictate.cloudProvider", keys: ["cleanup.cloud.provider"]),
                Setting("dictate.cloudKey"), Setting("dictate.cloudModel"),
            ]),
            Section("Style for each kind of app", [
                Setting("dictate.styles"), Setting("dictate.emailLines"), Setting("dictate.emailParagraphs"), Setting("dictate.context"),
            ]),
            Section("Accuracy", [Setting("dictate.boost"), Setting("dictate.autoLearn")]),
            Section("Snippets", [Setting("dictate.snippets")]),
            Section("Permissions and pasting", [
                Setting("dictate.accessibility"),
                Setting("dictate.alwaysCopy", keys: ["dictation.alwaysCopy"]),
                Setting("dictate.typeInstead"),
            ]),
        ]),
        Pane(raw: "floatingButton", title: "Floating button and Ribbon", sections: [
            Section("Where dictation shows", [
                Setting("dictate.surface", keys: ["flow.surface"]),
                Setting("dictate.noNotch", keys: ["flow.notch.noNotch"]),
                Setting("dictate.notchWords"),
                Setting("dictate.notchClick", keys: ["flow.notch.click"]),
                Setting("ribbon.show"),
                Setting("ribbon.style", keys: ["flow.ribbonStyle"]),
                Setting("ribbon.mark", keys: ["flow.ribbonMark"]),
                Setting("ribbon.liveWords", keys: ["flow.liveWords"]),
            ]),
            Section("Floating button", [
                Setting("float.look", keys: ["flow.button.look"]),
                Setting("float.size", keys: ["flow.button.size"]),
                Setting("float.mark"), Setting("float.snap"), Setting("float.liveWords"),
            ]),
        ]),
        Pane(raw: "actions", title: "Actions", sections: [
            Section(nil, [Setting("actions.list"), Setting("actions.add"), Setting("actions.restore")]),
        ]),
        Pane(raw: "meetings", title: "Meetings and captions", sections: [
            Section("Meetings", [Setting("meetings.notice"), Setting("meetings.copyNotice"), Setting("meetings.mic"), Setting("meetings.apps")]),
            Section("Live captions", [Setting("captions.size"), Setting("captions.soon"), Setting("captions.above")]),
        ]),
        Pane(raw: "watched", title: "Watched folders and export", sections: [
            Section("Watched folders", [
                Setting("watched.folders"), Setting("watched.add"), Setting("watched.activity"), Setting("watched.enabled"),
                Setting("watched.subfolders"), Setting("watched.location"), Setting("watched.formats"), Setting("watched.exportOptions"),
                Setting("watched.saveTo"), Setting("watched.fileName"), Setting("watched.notify"),
            ]),
            Section("Export", [
                Setting("export.source"), Setting("export.speakers"), Setting("export.timecodes"), Setting("export.sponsors"),
                Setting("export.single"), Setting("export.provenance"), Setting("export.watched"),
            ]),
        ]),
        Pane(raw: "storage", title: "Sync and storage", sections: [
            Section("iCloud", [Setting("storage.icloud", keys: ["cloud.sync"])]),
            Section("On this Mac", [Setting("storage.library"), Setting("storage.models")]),
            Section("Links", [Setting("links.signIn")]),
            Section("Keep", [Setting("storage.keepFolder"), Setting("storage.keepVideo")]),
            Section("Delete", [Setting("storage.deleteAll")]),
        ]),
        Pane(raw: "privacy", title: "Privacy", sections: [
            Section(nil, [Setting("privacy.statement")]),
            Section("Network", [
                Setting("privacy.localOnly", keys: ["privacy.localOnly"]),
                Setting("privacy.spotlight", keys: ["spotlight.enabled"]),
            ]),
            Section("Network activity", [Setting("general.countSites"), Setting("privacy.activity")]),
        ]),
        Pane(raw: "account", title: "Account and plan", sections: [
            Section(nil, [Setting("general.name", keys: ["profile.name"])]),
        ]),
        Pane(raw: "about", title: "Support and feedback", sections: [
            Section(nil, [
                Setting("about.version"), Setting("about.support"), Setting("about.log"),
                Setting("about.legal"), Setting("about.acknowledgements"),
            ]),
            Section("Updates", [Setting("general.autoUpdate"), Setting("general.beta"), Setting("general.version")]),
        ]),
        Pane(raw: "features", title: "Features", sections: [
            Section("Thoughts", [
                Setting("features.thoughtsHotkey"),
                Setting("features.thoughtsBubble", keys: ["thoughts.showBubble"]),
                Setting("features.thoughtsNewPage", keys: ["thoughts.newPageHour"]),
            ]),
            Section("Widgets and Shortcuts", [Setting("features.widgets"), Setting("features.shortcuts")]),
            Section("Welcome tour", [
                Setting("general.tour"),
                Setting("general.tourOnLaunch", keys: ["onboarding.showOnLaunch"]),
            ]),
        ]),
        Pane(raw: "whatsNew", title: "What's new", sections: [Section(nil, [Setting("whatsNew.builds")])], inSidebar: false),
    ]

    /// The pane a setting is in (its raw value), by SettingsIndex id.
    static func pane(of id: String) -> String? {
        panes.first { p in p.sections.contains { s in s.settings.contains { $0.id == id } } }?.raw
    }

    static func title(_ raw: String) -> String? { panes.first { $0.raw == raw }?.title }
}
