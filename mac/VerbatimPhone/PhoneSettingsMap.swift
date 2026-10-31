// The iPhone's Settings layout as data: the seven groups in order, each row on the Settings root, the page a row
// opens, and every setting on that page. SettingsScreen takes its group titles from here, SettingsSearchIndex's
// sections and targets have to agree with it, and mac/tools/test-settings-map.sh checks on Linux that every setting
// and every stored key sits in exactly one place. Pure Swift (no SwiftUI), so the test can compile it on its own.
//
// A setting's `id` is its search id (SettingsSearch.swift). `keys` are the UserDefaults keys it stores, when it has
// one of its own; a setting that shows another's value (Action button's timeout is the keyboard session's) lists none.

enum PhoneSettingsMap {
    struct Setting {
        var id: String
        var keys: [String] = []
        init(_ id: String, keys: [String] = []) { self.id = id; self.keys = keys }
    }

    /// One row on the Settings root. With a `page`, the row opens that page and `settings` live there; without
    /// one, the row is the setting itself (`settings` is that one setting, with the row's id).
    struct Row {
        var id: String
        var page: String? = nil
        var settings: [Setting]
        /// Built but kept off the root until its screen lands (Customize Home, from the Edit Home branch).
        var hidden = false
    }

    struct Group {
        var title: String
        var rows: [Row]
    }

    static let personalization = "Personalization and preferences"
    static let recording = "Recording and transcription"
    static let dictation = "Dictation and keyboard"
    static let sync = "Sync and storage"
    static let account = "Account and plan"
    static let support = "Support and feedback"
    static let features = "Features"

    static let groups: [Group] = [
        Group(title: personalization, rows: [
            Row(id: "appearanceRow", page: "appearance", settings: [
                Setting("palette", keys: ["appearance.palette"]),
                Setting("appearance", keys: ["appearance"]),
            ]),
            // Customize Home: Edit Home's sections, sizes, and tiles (EditHome.swift).
            Row(id: "customizeHomeRow", page: "customizeHome", settings: [Setting("customizeHome")]),
            // Tab bar: the up to four tabs after Home (TabBarSettings.swift, PhoneTabBar.swift).
            Row(id: "tabBarRow", page: "tabBar", settings: [Setting("tabBar", keys: ["appearance.tabBar"])]),
            Row(id: "aboutMeRow", page: "aboutMe", settings: [Setting("aboutMe", keys: ["profile.aboutMe"])]),
            Row(id: "voice", settings: [Setting("voice")]),
            Row(id: "dictionaryRow", page: "dictionary", settings: [
                Setting("dictionary"),
                Setting("builtInVocabulary", keys: ["vocabulary.builtIn"]),
            ]),
            Row(id: "language", settings: [Setting("language", keys: ["language.detect"])]),
            Row(id: "limitMotion", settings: [Setting("limitMotion", keys: ["motion.limited"])]),
            Row(id: "haptics", settings: [Setting("haptics", keys: ["haptics.enabled"])]),
        ]),
        Group(title: recording, rows: [
            Row(id: "quality", settings: [Setting("quality", keys: ["preset"])]),
            Row(id: "speakersRow", page: "speakers", settings: [
                Setting("speakers", keys: ["identifySpeakers"]),
                Setting("mainSpeaker", keys: ["transcript.mainSpeakerOnly"]),
                Setting("recognizeVoices", keys: ["voice.recognizeNamed"]),
                Setting("clearVoices"),
            ]),
            Row(id: "summaries", settings: [Setting("summaries", keys: ["summary.auto"])]),
            Row(id: "nameAndSort", settings: [Setting("nameAndSort", keys: ["labels.auto"])]),
            Row(id: "recordLiveWords", settings: [Setting("recordLiveWords", keys: ["record.liveWords"])]),
            Row(id: "moreTranscriptionRow", page: "moreTranscription", settings: [
                Setting("hideFiller", keys: ["transcript.hideFiller"]),
                Setting("applyDictionary", keys: ["applyDictionary"]),
                Setting("audioTracks", keys: ["import.audioTracks"]),
                Setting("skipSponsors", keys: ["playback.skipSponsors"]),
            ]),
        ]),
        Group(title: dictation, rows: [
            Row(id: "keyboardRow", page: "keyboard", settings: [
                Setting("keyboard"),
                Setting("keyboardFullAccess"),
                Setting("keyboardTimeout", keys: ["keyboard.sessionTimeout"]),
                Setting("keyboardAutoStart"),
                Setting("keyboardPolishAfter"),
                Setting("keyboardLiveWords"),
                Setting("keyboardDictateButton"),
                Setting("keyboardIslandWords", keys: ["ribbon.islandWords"]),
                Setting("keyboardAlwaysCopy", keys: ["kb.alwaysCopy"]),
                Setting("keyboardLowerAudio", keys: ["audio.lowerOthers"]),
                Setting("keyboardTypingHaptics", keys: ["kb.typingHaptics"]),
            ]),
            Row(id: "actionButtonRow", page: "actionButton", settings: [
                Setting("actionButton", keys: ["ribbon.actionButton"]),
                Setting("actionButtonTimeout"),
            ]),
            Row(id: "cleanup", settings: [Setting("cleanup", keys: ["flow.cleanup"])]),
            Row(id: "spokenCorrections", settings: [Setting("spokenCorrections", keys: ["flow.spokenCorrections"])]),
            Row(id: "snippetsRow", page: "snippets", settings: [Setting("snippets")]),
            Row(id: "cloudCleanupRow", page: "cloudCleanup", settings: [
                Setting("cloudCleanup", keys: ["cleanup.cloud.enabled"]),
                Setting("cloudProvider", keys: ["cleanup.cloud.provider"]),
            ]),
        ]),
        Group(title: sync, rows: [
            Row(id: "privacyRow", page: "privacy", settings: [
                Setting("localOnly", keys: ["privacy.localOnly"]),
                Setting("networkActivity"),
            ]),
            Row(id: "sync", settings: [Setting("sync", keys: ["cloud.sync"])]),
            Row(id: "export", settings: [Setting("export")]),
            Row(id: "deleteAll", settings: [Setting("deleteAll")]),
        ]),
        Group(title: account, rows: [
            // Shown on the root, still edited in About me.
            Row(id: "yourNameRow", page: "aboutMe", settings: [Setting("yourName", keys: ["profile.name"])]),
        ]),
        Group(title: support, rows: [
            Row(id: "support", settings: [Setting("support")]),
            Row(id: "feedback", settings: [Setting("feedback")]),
            Row(id: "log", settings: [Setting("log")]),
            Row(id: "privacy", settings: [Setting("privacy")]),
            Row(id: "terms", settings: [Setting("terms")]),
            Row(id: "share", settings: [Setting("share")]),
            Row(id: "acknowledgements", settings: [Setting("acknowledgements")]),
            // The version at the foot of Settings opens What's new.
            Row(id: "version", page: "whatsNew", settings: [Setting("whatsNew")]),
        ]),
        Group(title: features, rows: [
            // Thoughts (ThoughtsSettings.swift): the ways in, their setup, and how a thought records.
            Row(id: "thoughtsRow", page: "thoughts", settings: [
                Setting("thoughtsWaysIn"),
                Setting("thoughtsInPlace", keys: ["thoughts.inPlace"]),
                Setting("thoughtsIslandWords", keys: ["thoughts.islandWords"]),
                Setting("thoughtsNewPage", keys: ["thoughts.newPageHour"]),
            ]),
            // Templates › Run automatically (TemplatesScreens.swift): kept on this iPhone; the results sync.
            Row(id: "templatesRow", page: "templates", settings: [
                Setting("templatesAuto", keys: ["templates.auto"]),
                Setting("templatesSkipShort", keys: ["templates.skipShort"]),
                Setting("templatesShowFirst", keys: ["templates.showFirst"]),
                Setting("templatesNotify", keys: ["templates.notify"]),
                Setting("askRecipes", keys: ["ask.showRecipes"]),
            ]),
            Row(id: "widgetsRow", page: "widgets", settings: [Setting("widgets")]),
            Row(id: "shortcutsRow", page: "shortcuts", settings: [Setting("shortcuts")]),
            Row(id: "tourRow", page: "tour", settings: [
                Setting("tourOnLaunch", keys: ["onboarding.showOnLaunch"]),
                Setting("tour"),
            ]),
        ]),
    ]

    /// Every setting with its group and the page it's on (nil: on the root), in Settings order.
    static var placements: [(setting: Setting, group: String, page: String?)] {
        groups.flatMap { g in g.rows.flatMap { r in r.settings.map { (setting: $0, group: g.title, page: r.page) } } }
    }

    /// The group a setting is in, by search id.
    static func group(of id: String) -> String? { placements.first { $0.setting.id == id }?.group }

    /// The page a setting is on (nil when it's on the root or unknown).
    static func page(of id: String) -> String? { placements.first { $0.setting.id == id }?.page }
}
