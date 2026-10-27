import SwiftUI
import AppKit

// brand: web style
//
// The Settings window's building blocks: the panes and their sidebar groups, the searchable index every row is
// built from, and the row, group, and header views in the website style (DESIGN.md §11): a mono eyebrow and a
// compact serif title, groups as card-white panels with an ink outline, hairline-separated rows with a bold label
// and a dim detail, line mini pills for actions in rows, and switches that stay switches.
//
// Under the Native look the same pieces draw a grouped Form, as System Settings does: a bold title with no eyebrow,
// white sections on the window gray, regular labels with secondary details, separators, and bordered buttons.

// MARK: - Panes

/// A Settings pane, in sidebar order: the iPhone's seven groups plus the Mac-only panes (MacSettingsMap, from the
/// premium mockup's section 02). Raw values persist in "settingsTab" and in links from the Ribbon, the welcome tour, and
/// Home: a pane that took over an old one keeps its raw value (`general`, `transcription`, `dictate`, `floatingButton`,
/// `actions`, `meetings`, `watched`, `storage`, `privacy`, `about`, `whatsNew`), and the old Speakers, Live captions,
/// and Export panes' values open the panes they moved into. `whatsNew` is the release notes (WhatsNewPane.swift),
/// opened by the version at the foot of the sidebar, Verbose › What's New…, and Home's note after an update.
enum SettingsTab: CaseIterable, Identifiable, Hashable, RawRepresentable {
    case personalization, recording, dictate, floatingButton, actions, meetings, watched
    case storage, privacy, account, support, features, whatsNew

    var rawValue: String {
        switch self {
        case .personalization: return "general"
        case .recording: return "transcription"
        case .dictate: return "dictate"
        case .floatingButton: return "floatingButton"
        case .actions: return "actions"
        case .meetings: return "meetings"
        case .watched: return "watched"
        case .storage: return "storage"
        case .privacy: return "privacy"
        case .account: return "account"
        case .support: return "about"
        case .features: return "features"
        case .whatsNew: return "whatsNew"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "general": self = .personalization
        case "transcription", "speakers": self = .recording
        case "dictate": self = .dictate
        case "floatingButton": self = .floatingButton
        case "actions": self = .actions
        case "meetings", "captions": self = .meetings
        case "watched", "export": self = .watched
        case "storage": self = .storage
        case "privacy": self = .privacy
        case "account": self = .account
        case "about": self = .support
        case "features": self = .features
        case "whatsNew": self = .whatsNew
        default: return nil
        }
    }

    var id: String { rawValue }

    /// The sidebar title, also the pane's title (MacSettingsMap).
    var title: String { MacSettingsMap.title(rawValue) ?? rawValue }

    /// The pane's overline in Verbose style.
    var group: String { self == .whatsNew ? "Support and feedback" : "Settings" }

    /// One line under the pane's title.
    var blurb: String {
        switch self {
        case .personalization: return "How Verbose looks and sounds, what it knows about you, your voice, and the words it should spell your way."
        case .recording: return "Which model transcribes your recordings, who's talking, and what Verbose does to a transcript when it's ready."
        case .dictate: return "Hold or press your hotkey in any app and Verbose types what you say."
        case .floatingButton: return "What you see while Verbose listens, cleans up, and pastes: the Ribbon, the notch, or the floating button."
        case .actions: return "Instructions you save once and run on any text: a selection in any app, a dictation, or a whole transcript. Everything runs on this Mac."
        case .meetings: return "Record a call as two tracks, your microphone and the meeting app, on this Mac, and live captions for whatever your Mac is playing or hearing. Verbose can notice a call and ask; it never records on its own."
        case .watched: return "Drop audio or video into a watched folder and Verbose transcribes it, then exports the results where you choose, with the text, speaker names, and timecodes set here."
        case .storage: return "Where your library, models, and kept video live, how links sign in, and whether they sync with your iPhone."
        case .privacy: return "What leaves this Mac, and when. Local Only keeps everything here."
        case .account: return "Verbose has no account, so there's nothing to sign in to. Your name greets you and signs your emails."
        case .support: return "Help, the diagnostic log, updates, and the fine print."
        case .features: return "Widgets, Shortcuts, and the welcome tour: the places to learn what Verbose can do."
        case .whatsNew: return "What each build of Verbose added, newest first."
        }
    }

    /// The panes in the sidebar, in order (What's new opens from the version at its foot).
    static let sidebar: [SettingsTab] = allCases.filter { t in MacSettingsMap.panes.first { $0.raw == t.rawValue }?.inSidebar ?? true }

    /// The pane's glyph in the Verbose style sidebar.
    var art: BrandArt {
        switch self {
        case .personalization: return .iconAppearance
        case .recording: return .iconQuality
        case .dictate: return .iconDictations
        case .floatingButton: return .iconVoice
        case .actions: return .iconAI
        case .meetings: return .iconCaptions
        case .watched: return .iconFolder
        case .storage: return .iconSync
        case .privacy: return .iconPrivacy
        case .account: return .iconAboutMe
        case .support: return .iconSupport
        case .features: return .iconHome
        case .whatsNew: return .iconNotes
        }
    }
}

// MARK: - Search index

/// One searchable setting. Rows are built from these (label and description come from here), so what search
/// finds is exactly what the pane shows.
struct SettingsEntry: Identifiable, Hashable {
    let id: String
    let section: SettingsTab
    let label: String
    let detail: String
    let keywords: String

    init(_ id: String, _ section: SettingsTab, _ label: String, _ detail: String = "", keywords: String = "") {
        self.id = id; self.section = section; self.label = label; self.detail = detail; self.keywords = keywords
    }
}

/// Every searchable setting. Entries are grouped by the pane they started in; `section` is the pane they show on now
/// (MacSettingsMap), which mac/tools/test-settings-map.sh checks.
enum SettingsIndex {
    private static let base: [SettingsEntry] = [
        // General
        .init("general.look", .personalization, "Look", "How Verbose looks on this Mac. Your iPhone has its own setting.", keywords: "native verbose style theme apple stock paper design"),
        .init("general.appearance", .personalization, "Appearance", "Match the system, or always light or dark.", keywords: "dark mode light theme color"),
        .init("general.limitMotion", .personalization, "Limit animation", "Fades instead of movement; illustrations stay still. Always on when Reduce Motion is on in System Settings.", keywords: "reduce motion accessibility animations"),
        .init("general.menuBar", .personalization, "Show in menu bar", "Record from anywhere with the menu bar item, or press ⌥⇧R while Verbose is running.", keywords: "menubar status item record shortcut"),
        .init("general.sounds", .personalization, "Sounds", "A short chime when recording or dictation starts, a tick when your words are ready, and a soft tone when you cancel.", keywords: "chime audio feedback"),
        .init("general.customizeHome", .personalization, "Customize Home", "Show, hide, reorder, and resize Home's sections, and choose its four tiles. Each look keeps its own layout.", keywords: "edit home sections reorder drag tiles shortcut compact large hide show layout"),
        .init("general.homeWeek", .personalization, "Show This week on Home", "Words, time saved typing, recordings, and moments for the week, in one strip under the tiles.", keywords: "this week stats words saved typing recordings moments method cards welcome"),
        .init("general.tourOnLaunch", .features, "Show the welcome tour when Verbose opens", keywords: "onboarding launch"),
        .init("general.tour", .features, "Welcome tour", "Walk through the basics again.", keywords: "onboarding intro help"),
        .init("general.autoUpdate", .support, "Check for updates automatically", keywords: "sparkle update"),
        .init("general.beta", .support, "Get beta builds", "Beta builds arrive with every change to Verbose; leave this off for tested releases only.", keywords: "update prerelease"),
        .init("general.version", .support, "Check for updates", "A check sends your IP address and Verbose's version to GitHub, nothing else.", keywords: "version update check now"),
        .init("general.name", .account, "Your name", "Shown on the You page.", keywords: "profile name you"),
        .init("general.aboutMe", .personalization, "About me", "A few lines about you. Verbose uses this to spell names and word titles and summaries.", keywords: "profile context bio titles summaries you"),
        .init("general.countSites", .privacy, "Count websites", "When you dictate into Safari, Chrome, Arc, Edge, or Brave, the You page shows which websites, by domain only, never full addresses. macOS asks once per browser.", keywords: "domains browser where you dictate activity stats privacy"),

        // Dictation
        .init("dictate.enabled", .dictate, "Dictate anywhere", "Off, the hotkey does nothing and dictation doesn't show on screen.", keywords: "dictation voice typing"),
        .init("dictate.surface", .floatingButton, "Show dictation in", "What you see while Verbose listens, cleans up, and pastes.", keywords: "ribbon notch floating button pill tab where style display screen"),
        .init("dictate.noNotch", .floatingButton, "On displays without a notch", "External displays and Macs without a notch.", keywords: "external display monitor pill ribbon notch"),
        .init("dictate.notchWords", .floatingButton, "Show words as you speak", "Hover the notch to see them. What's pasted still comes from Verbose's own transcription.", keywords: "live words preview streaming notch"),
        .init("dictate.notchClick", .floatingButton, "Click the notch to dictate", "Point at the notch to see your hotkey; click to start, click again to paste.", keywords: "notch click hover pointer"),
        .init("ribbon.show", .floatingButton, "Show the Ribbon when you're not dictating", "Click it to start, click again to paste. Drag it to the bottom, left, or right edge; right-click it for options.", keywords: "ribbon tab sliver edge hide flow bar pill"),
        .init("ribbon.style", .floatingButton, "Style", "Paper is a light tab with ink type. Ink is a dark tab with paper type.", keywords: "ribbon look paper ink appearance"),
        .init("ribbon.mark", .floatingButton, "Voice mark", "Moves with your voice while you dictate.", keywords: "ribbon bars rings level meter"),
        .init("ribbon.liveWords", .floatingButton, "Show words as you speak", "A preview of your words in the Ribbon while you dictate, recognized on this Mac. What's pasted still comes from Verbose's own transcription.", keywords: "ribbon live words preview streaming"),
        .init("dictate.hotkey", .dictate, "Hotkey", "The key that starts dictation.", keywords: "shortcut key fn globe option command record mouse button side"),
        .init("dictate.mode", .dictate, "How it starts", "Hold the key while you talk and let go to paste. Press Esc to cancel.", keywords: "mode hold to talk press start stop either push toggle hands-free tap"),
        .init("dictate.shortcuts", .dictate, "Other shortcuts", "Paste last dictation, and New thought from any app.", keywords: "paste again thought thoughts hotkey"),
        .init("dictate.markHotkey", .dictate, "Mark a moment", "While a recording runs, marks the moment from any app. With nothing recording, other apps get the keys.", keywords: "mark moment bookmark hotkey shortcut recording control option b"),
        .init("dictate.recall", .dictate, "Recent dictations", "Shows your last 10 dictations in any app, so you can copy one or paste it again. Press 1–0 to copy, or hold ⇧ to paste. While it's set, the shortcut does nothing else, such as Paste Style (⌥⌘V) in Pages and TextEdit.", keywords: "history recent clipboard copy paste again missed failed lost shortcut hotkey panel"),
        .init("dictate.alwaysCopy", .dictate, "Also copy each dictation to the clipboard", "Each dictation stays on the clipboard after it's pasted, instead of what you copied before.", keywords: "clipboard copy keep paste pasteboard"),
        .init("dictate.lowerAudio", .dictate, "Lower other audio while Verbose listens", "Other sound drops to a whisper so it doesn't reach the microphone. Applies to dictation, voice notes, and Live captions from your microphone.", keywords: "duck music spotify youtube volume quiet mute background sound"),
        .init("dictate.maxMinutes", .dictate, "Stop dictating after", "A minute before, the button says so. Your words up to the stop are pasted, never thrown away.", keywords: "limit time minutes"),
        .init("dictate.cleanup", .dictate, "Cleanup", "How much Verbose tidies what you say before it's pasted.", keywords: "polish clean literal filler punctuation"),
        .init("dictate.cloud", .dictate, "Cloud cleanup", "Clean up dictation with Anthropic Claude or OpenAI, using your own API key. Off by default.", keywords: "claude anthropic openai chatgpt gpt api cloud grammar ai"),
        .init("dictate.cloudProvider", .dictate, "Provider", "Who cleans up your words when cloud cleanup is on.", keywords: "anthropic openai claude gpt cloud"),
        .init("dictate.cloudKey", .dictate, "API key", "Your own key, saved in your Keychain on this Mac only.", keywords: "api key keychain secret cloud"),
        .init("dictate.cloudModel", .dictate, "Model", "The model that cleans up your words.", keywords: "haiku gpt mini cloud model"),
        .init("dictate.spokenCorrections", .dictate, "Understand spoken corrections", "Say “scratch that,” “delete the last sentence,” or “let me start over” to fix what you said.", keywords: "scratch that actually no wait start over delete last sentence self-correction correction undo never mind"),
        .init("dictate.cleanupHelp", .dictate, "Punctuation, lists, and paragraphs by voice", "Say “comma,” “period,” “new line,” or “new paragraph.” Announce a list to get one.", keywords: "comma period list bullet numbered"),
        .init("dictate.styles", .dictate, "Style for each kind of app", "Formal, casual, very casual, or as spoken, by app.", keywords: "tone email chat messages code"),
        .init("dictate.emailLines", .dictate, "Put the greeting and sign-off on their own lines", "In email, a greeting you say (“Hi Sarah”) and a sign-off (“Thanks, Tim”) each get a line of their own. Verbose never adds one you didn't say.", keywords: "email greeting sign-off signature hi thanks gmail outlook layout"),
        .init("dictate.emailParagraphs", .dictate, "Paragraphs", "How long email paragraphs run: Short is 1 or 2 sentences, Normal is up to 4.", keywords: "email paragraph length short normal layout preview"),
        .init("dictate.context", .dictate, "Use the text around your cursor", "Verbose reads the app's name and the text near your cursor so names are spelled right and the tone matches. Password fields are never read, and nothing leaves this Mac.", keywords: "context privacy"),
        .init("dictate.boost", .dictate, "Listen for my Dictionary words", "Parakeet listens for the words in your Dictionary as you speak (a small extra model downloads once). Works best with fewer than 100 words.", keywords: "vocabulary accuracy boost"),
        .init("dictate.autoLearn", .dictate, "Learn from my fixes", "When you correct a name or term right after it's pasted, Verbose asks whether to remember it. Nothing is learned unless you say yes.", keywords: "dictionary corrections learn"),
        .init("dictate.snippets", .dictate, "Snippets", "Say a trigger like “my calendar link” and Verbose pastes the saved text: a link, an address, a sign-off.", keywords: "text expansion shortcut"),
        .init("dictate.accessibility", .dictate, "Accessibility access", "macOS requires this so Verbose can notice the hotkey, see which app and text field you're in, and press ⌘V there.", keywords: "permission privacy system settings"),
        .init("dictate.typeInstead", .dictate, "Type instead of paste", "For apps that block ⌘V or paste the wrong thing.", keywords: "paste clipboard typing apps"),

        // Floating button (its own style since the notch; the Ribbon's settings moved to Dictation)
        .init("float.look", .floatingButton, "Button", "Ink disc, Bars pill, Quiet dot, or Labeled pill.", keywords: "look disc pill dot labeled style appearance"),
        .init("float.size", .floatingButton, "Size", "Small is 32 pt, medium 44 pt, large 56 pt. The click target is never smaller than 28 pt.", keywords: "small medium large big"),
        .init("float.mark", .floatingButton, "Voice mark", "Moves with your voice while you dictate.", keywords: "bars rings level meter"),
        .init("float.snap", .floatingButton, "Snap to the screen edge", "Off, it stays where you drop it. On, it slides to the nearest edge, like the Ribbon.", keywords: "edge snap drag place position"),
        .init("float.liveWords", .floatingButton, "Show words as you speak", "A preview of your words beside the button, recognized on this Mac.", keywords: "live words preview streaming"),

        // Actions
        .init("actions.list", .actions, "Saved actions", "Name, instruction, and how long text is handled.", keywords: "prompt rewrite summarize instruction"),
        .init("actions.add", .actions, "Add an action", keywords: "new create"),
        .init("actions.restore", .actions, "Restore built-in actions", "Replaces your actions with the eight that come with Verbose.", keywords: "reset defaults"),

        // Models and language
        .init("models.quality", .recording, "Quality", "Parakeet is the default: fast on Apple silicon with word timings. Whisper is the alternate for languages Parakeet misses.", keywords: "model engine whisper parakeet language accuracy speed"),
        .init("models.engine", .recording, "Engine and model", "Shown when Quality is Advanced.", keywords: "whisper parakeet advanced"),
        .init("models.detectLanguage", .personalization, "Detect the language", "Verbose listens to the first 30 seconds of each recording. When it isn't English and Quality is English only, Parakeet v3 transcribes it; languages outside Parakeet v3's 25 use Apple's speech recognition on this Mac. To change one transcript's language, open its Details.", keywords: "language spanish french german japanese chinese multilingual detect automatic v3"),
        .init("models.applyDictionary", .recording, "Apply Dictionary to new transcripts", "Only words listed under “Heard as” are replaced, and every fix shows on the transcript.", keywords: "vocabulary corrections replace"),
        .init("models.builtInVocabulary", .personalization, "Built-in vocabulary", "Verbose spells about 800 modern words and names right, like ChatGPT, GitHub, and macOS, and fixes everyday mix-ups like “could of been” in dictation. Your Dictionary always wins. Turn off single terms on the Dictionary page.", keywords: "modern words brands apps tech terms spelling names places chatgpt iphone youtube boost mix-ups"),
        .init("models.projectVocab", .personalization, "Project vocabulary", "Dictionary fixes you save from a transcript inside a project apply only to that project. Off, every fix applies everywhere.", keywords: "dictionary project scope"),
        .init("models.nameSort", .recording, "Name and sort recordings", "Apple Intelligence suggests a title, kind, and tags when a transcript is ready. Anything you rename or change stays.", keywords: "auto label title tags kind"),
        .init("models.summary", .recording, "Write a summary when a transcript finishes", "Apple Intelligence writes a short overview and key points at the top of the transcript. A summary you edit stays. When this is off, choose Actions › Summarize.", keywords: "summary summaries overview key points recap"),
        .init("models.skipSponsors", .recording, "Skip sponsor reads", "In podcasts and videos from links and files, playback jumps past sponsor reads and the transcript folds each one into a line. Summaries, tags, copy, and export leave them out.", keywords: "sponsor sponsors ads ad read advertisement promo code skip podcast youtube"),
        .init("models.recordLiveWords", .recording, "Show words while you record", "A preview of your words on the recorder, made on this Mac. The saved transcript comes from the full model after you stop.", keywords: "live text live words preview real time transcript voice note memo recorder recording"),
        .init("models.hideFiller", .recording, "Hide filler lines", "Lines that are only “um” or “uh” stay out of view. Nothing is deleted; Show brings them back.", keywords: "um uh filler"),
        .init("models.offline", .recording, "Where models run", "Models download once from Hugging Face and run on this Mac. Transcription never leaves your computer.", keywords: "privacy offline download hugging face"),

        // Speakers and your voice
        .init("speakers.voiceProfile", .personalization, "Voice profile", "Teach Verbose your voice so transcripts label you as You.", keywords: "enroll my voice recognize me you"),
        .init("speakers.onlyMyVoice", .personalization, "Only keep my voice in dictation", "When someone nearby talks while you dictate, Verbose pastes only your words.", keywords: "voice filter background people dictation me"),
        .init("speakers.identify", .recording, "Identify speakers", "Labels turns as Speaker 1, Speaker 2… so you can name them. Runs on this Mac and adds time to each transcript.", keywords: "diarization speaker labels who"),
        .init("speakers.recognizeVoices", .recording, "Recognize voices I’ve named", "When a new speaker sounds like someone you named before, Verbose suggests that name. The voices stay on this Mac and are never synced.", keywords: "voice match name speakers suggest people remember"),
        .init("speakers.clearVoices", .recording, "Saved voices", "Voices of the speakers you’ve named, kept on this Mac only.", keywords: "delete clear forget voices speakers names"),
        .init("speakers.mainOnly", .recording, "Main speaker only", "In voice memos, other voices fold into a Background voices section under the transcript. Links, imported files, and meetings always show everyone.", keywords: "background voices"),
        .init("speakers.audioTracks", .recording, "Files with several audio tracks", "Mix every track into one transcript, or transcribe each track on its own as a speaker you can rename. A track's title or language names it, such as Commentary or English.", keywords: "multiple audio tracks mkv video language commentary mix separate speakers import"),
        .init("speakers.mic", .recording, "Record from", "Built-in mic, a USB interface, AirPods, or your iPhone (Continuity). “System default” follows the Mac's Sound settings.", keywords: "microphone input device airpods"),

        // Live captions
        .init("captions.size", .meetings, "Text size", "How big captions read in the captions bar.", keywords: "subtitles captions live font large"),
        .init("captions.soon", .meetings, "Show the time in the header", "Open live captions from Home, the menu bar, or ⌥⌘C. Captions are made on this Mac.", keywords: "subtitles captions live timecode clock"),
        .init("captions.above", .meetings, "Keep captions above full-screen apps", keywords: "subtitles captions floating window full screen"),

        // Meetings
        .init("meetings.notice", .meetings, "Notice calls and ask to record", "When Zoom, Teams, FaceTime, or a browser starts using your microphone, Verbose asks whether to record. It checks which app is using the microphone, never what it hears.", keywords: "meeting call detect detection prompt zoom teams facetime meet webex slack discord"),
        .init("meetings.copyNotice", .meetings, "Copy the chat notice when recording starts", "Puts a short notice on the clipboard to paste in the meeting chat, so everyone knows you're recording.", keywords: "consent notice chat clipboard tell everyone announce"),
        .init("meetings.mic", .meetings, "Record your side from", "The same microphone as Settings › Recording and transcription › Speakers. A built-in mic keeps Bluetooth headphones sounding their best.", keywords: "microphone input device airpods meeting"),
        .init("meetings.apps", .meetings, "Apps Verbose has noticed", "Turn off the question for an app, or bring back the consent sheet.", keywords: "meeting apps zoom teams chrome safari don't ask consent"),

        // Watched folders
        .init("watched.folders", .watched, "Watched folders", "New audio and video in these folders is transcribed automatically.", keywords: "watch folder automatic import hot folder"),
        .init("watched.add", .watched, "Add folder…", "Files already in the folder are left alone; anything new is transcribed.", keywords: "watch new folder"),
        .init("watched.activity", .watched, "Open activity", "What each watched folder has transcribed and exported.", keywords: "log history"),
        .init("watched.enabled", .watched, "Watch this folder", "Pause a folder without removing it.", keywords: "pause resume"),
        .init("watched.subfolders", .watched, "Include subfolders", keywords: "recursive nested"),
        .init("watched.location", .watched, "Folder", "Show it in Finder, or stop watching it.", keywords: "remove stop finder reveal"),
        .init("watched.formats", .watched, "Export formats", "SRT, Plain text, VTT, Word, Markdown, or JSON, written when each transcript is ready.", keywords: "auto-export subtitles srt vtt docx markdown json"),
        .init("watched.exportOptions", .watched, "Auto-export uses your Export settings", "Which text, speaker names, and timecodes come from Export, below the folders.", keywords: "timecode timecodes speakers options"),
        .init("watched.saveTo", .watched, "Save to", "The folder exports go to, or next to the original file.", keywords: "destination output folder"),
        .init("watched.fileName", .watched, "File name", "{original name}, {title}, and {date} fill in for each file.", keywords: "pattern naming rename"),
        .init("watched.notify", .watched, "When it's done", "A notification when a file is transcribed and exported.", keywords: "notification alert notify"),

        // Export
        .init("export.source", .watched, "Text", "Cleaned is paragraphs with your edits and cleanup. Original with corrections and Original (engine words) are line by line. Copy follows the tab you're on.", keywords: "document transcript source cleaned original engine words raw copy"),
        .init("export.speakers", .watched, "Speaker names", "Each speaker's name before their words.", keywords: "labels speakers"),
        .init("export.timecodes", .watched, "Include timecodes", "A timecode at the start of every line, like [00:12:04]. Subtitles always have them.", keywords: "timecode timestamps time"),
        .init("export.sponsors", .watched, "Include sponsor reads", "Sponsor reads found in podcasts and videos are left out unless this is on. Copy always leaves them out.", keywords: "sponsor sponsors ads advertisement promo"),
        .init("export.single", .watched, "One paragraph", "Everything joined into a single paragraph.", keywords: "line breaks join"),
        .init("export.provenance", .watched, "Add a “transcribed with” footer", "Title, source, length, model, and date at the end.", keywords: "provenance credit footer"),
        .init("export.watched", .watched, "Watched folders export with these options", keywords: "auto-export timecode"),

        // Storage and iCloud
        .init("storage.icloud", .storage, "Sync with iCloud", "Transcripts, notes, projects, and the Dictionary match your iPhone.", keywords: "icloud sync iphone cloud"),
        .init("storage.library", .storage, "Transcripts and audio", "Your library on this Mac.", keywords: "finder reveal files location folder"),
        .init("storage.models", .storage, "Models", "Downloaded transcription models.", keywords: "finder reveal disk space"),
        .init("links.signIn", .storage, "Sign-in for private videos", "Verbose reads cookies only for the link you're fetching and never stores them.",
              keywords: "cookies private age restricted members login signed in account browser safari chrome firefox brave edge youtube links dropbox google drive onedrive icloud"),
        .init("storage.keepFolder", .storage, "Keep folder", "Where kept video and audio from links go.", keywords: "keep download video folder"),
        .init("storage.keepVideo", .storage, "Keep the video of every link I transcribe", "Video is saved as MP4 (H.264, up to 1080p) with its sound; audio as M4A. Nothing is re-encoded.", keywords: "keep download youtube mp4"),
        .init("storage.deleteAll", .storage, "Delete all data", "Removes every transcript, dictation, and recording, plus projects, the Dictionary, snippets, Activity, and downloaded models. Settings stay.", keywords: "erase reset privacy remove"),

        // About
        .init("about.version", .support, "Version", "What's New… shows what each build added.", keywords: "build number what's new release notes changes changelog"),
        .init("about.support", .support, "Help", "Write to support.", keywords: "contact email support help"),
        .init("about.log", .support, "Diagnostic log", "A record of what Verbose did, to help fix problems. It keeps 7 days, leaves out links and folder names, and stays on this Mac unless you send it.", keywords: "logs debug send support"),
        .init("about.legal", .support, "Legal", "Privacy, Terms, and Refunds.", keywords: "privacy policy terms refunds"),
        .init("about.acknowledgements", .support, "Acknowledgements", "Open-source software in Verbose and its licenses, including FFmpeg (LGPL), which reads MKV, WebM, AVI, and other files.", keywords: "ffmpeg lgpl open source license credits third party"),

        // Features
        .init("features.widgets", .features, "Widgets", "Record and dictate, Recent recordings, This week, New thought, and Today's thoughts. Click the date in the menu bar, then Edit Widgets, and search for Verbose.", keywords: "widget desktop notification center this week recent recordings quick capture new thought thoughts"),
        .init("features.thoughtsHotkey", .features, "New thought", "Starts a thought from any app; press it again to add it to today's page. It saves as audio first, so a thought is never lost.", keywords: "thoughts thought pad idea hotkey shortcut control option p"),
        .init("features.thoughtsBubble", .features, "Show the bubble", "A small disc above every app. Click it to start a thought, click again to add it to today's page. Drag it anywhere.", keywords: "thoughts floating bubble button disc"),
        .init("features.thoughtsNewPage", .features, "New page each day at", "When a new day's page starts. A thought belongs to the day it started.", keywords: "thoughts journal day boundary midnight morning page"),
        .init("features.shortcuts", .features, "Shortcuts", "Transcribe a file, Last dictation, Start recording, Get transcript text, and Copy for AI work in Shortcuts and Spotlight, and with Siri.", keywords: "shortcuts siri app intents automation spotlight"),

        // What's new
        .init("whatsNew.builds", .whatsNew, "What's new", "Every build's notes, newest first.", keywords: "release notes changes changelog version build update new features"),
    ]

    /// Every entry: the panes above, plus Privacy and the trust rows (Views/TrustViews.swift).
    static let all: [SettingsEntry] = base + trustEntries

    private static let byID: [String: SettingsEntry] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func entry(_ id: String) -> SettingsEntry? { byID[id] }

    /// The query's words, lowercased. Every word has to match somewhere in an entry.
    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    /// Entries matching every word of the query (label, description, keywords, or pane title), in pane order.
    static func search(_ query: String) -> [SettingsEntry] {
        let words = terms(query)
        guard !words.isEmpty else { return [] }
        let order = Dictionary(uniqueKeysWithValues: SettingsTab.allCases.enumerated().map { ($1, $0) })
        return all.filter { e in
            let hay = [e.label, e.detail, e.keywords, e.section.title].joined(separator: " ")
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        .enumerated()
        .sorted { a, b in
            let pa = order[a.element.section] ?? 0, pb = order[b.element.section] ?? 0
            return pa != pb ? pa < pb : a.offset < b.offset
        }
        .map(\.element)
    }

    /// Matching panes with how many of their settings match, in sidebar order.
    static func sectionCounts(_ results: [SettingsEntry]) -> [(tab: SettingsTab, count: Int)] {
        SettingsTab.allCases.compactMap { tab in
            let n = results.filter { $0.section == tab }.count
            return n > 0 ? (tab, n) : nil
        }
    }

    /// `s` with every occurrence of each query word on a persimmon tint.
    static func highlighted(_ s: String, terms: [String]) -> AttributedString {
        var a = AttributedString(s)
        for t in terms {
            var from = s.startIndex
            while from < s.endIndex, let r = s.range(of: t, options: [.caseInsensitive, .diacriticInsensitive], range: from..<s.endIndex) {
                if let ar = Range(r, in: a) {
                    a[ar][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Ink.persimmonTint
                    a[ar][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Ink.ink
                }
                from = r.upperBound
            }
        }
        return a
    }
}

// MARK: - Search and navigation state

/// The window's search text and the row a search result asked to show. Shared so the UI self-test can drive it.
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    // @Changed, not @Published: text fields write their binding back on every update (see Changed.swift).
    @Changed var query = ""
    /// A row to scroll to once its pane is showing.
    @Changed var focusID: String? = nil
    /// The row that's briefly tinted after a search result opened it.
    @Changed var flashID: String? = nil
    weak var window: NSWindow?
    /// Renders of the Settings root and of a pane while the window is closed (SwiftUI keeps its views), for the
    /// self-test's timing lines. Not published.
    var closedRenders = (root: 0, pane: 0)
    /// How many times each row id is laid out now (SettingsAnchor), for the self-test's check that every search entry
    /// resolves to a row on its pane. Not published: counting never redraws anything.
    private(set) var anchorCounts: [String: Int] = [:]
    func anchorAppeared(_ id: String) { anchorCounts[id, default: 0] += 1 }
    func anchorDisappeared(_ id: String) {
        let n = (anchorCounts[id] ?? 0) - 1
        anchorCounts[id] = n > 0 ? n : nil
    }
    func isLaidOut(_ id: String) -> Bool { (anchorCounts[id] ?? 0) > 0 }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Opens a setting's pane and shows the row.
    func open(_ e: SettingsEntry) {
        UserDefaults.standard.set(e.section.rawValue, forKey: "settingsTab")
        query = ""
        focusID = e.id
    }

    func flash(_ id: String) {
        flashID = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if flashID == id { flashID = nil }
        }
    }
}

// MARK: - Page structure

/// The pane's mono eyebrow (its sidebar group), a compact serif title, and its one-line description.
struct SettingsPaneHeader: View {
    var overline: String
    var title: String
    var blurb: String? = nil
    @Environment(\.look) private var look
    var body: some View {
        if look == .native {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let blurb {
                    Text(blurb).font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: 600, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            verbose
        }
    }
    private var verbose: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: overline)
            Text(title).font(Ink.serif(34)).tracking(-0.5).foregroundStyle(Ink.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            if let blurb {
                Text(blurb).font(.system(size: 14)).lineSpacing(3).foregroundStyle(Ink.dim)
                    .frame(maxWidth: 600, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }
}

/// A scrolling pane: header, then groups. Scrolls to and flashes the row a search result opened.
struct SettingsPane<Content: View>: View {
    var tab: SettingsTab
    @ViewBuilder var content: () -> Content
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look

    var body: some View {
        let native = look == .native
        LookSwitch.mark("settings-pane")
        if model.window?.isVisible == false { model.closedRenders.pane += 1 }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: native ? 18 : 22) {
                    SettingsPaneHeader(overline: tab.group, title: tab.title, blurb: tab.blurb)
                    content()
                }
                .padding(.horizontal, native ? 28 : 36).padding(.top, native ? 22 : 44).padding(.bottom, native ? 28 : 36)
                .frame(maxWidth: native ? 700 : 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .onAppear { LookSwitch.mark("settings-pane-appear"); reveal(proxy) }
            .onChange(of: model.focusID) { _, _ in reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = model.focusID, SettingsIndex.entry(id)?.section == tab else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(limitMotion ? nil : Motion.nav) { proxy.scrollTo(id, anchor: .center) }
            model.flash(id)
            if model.focusID == id { model.focusID = nil }
        }
    }
}

/// An optional serif section title ("Apps Verbose has *noticed*") over a card of rows, with an optional note under it.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: look == .native ? 8 : 12) {
            if let title {
                if look == .native {
                    // A Form section header: plain text, sentence case.
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader).padding(.top, 6).padding(.leading, 2)
                } else {
                    let parts = WebText.splitLastWord(title)
                    SectionTitle(title: parts.0, italic: parts.1).padding(.top, 4)
                }
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                // Each row draws a hairline above itself; the first one tucks under the card's edge.
                .padding(.top, -1)
                .settingsCard()
            if let footer {
                Text(footer).font(.system(size: look == .native ? 11 : 12.5)).lineSpacing(3).foregroundStyle(Ink.mute)
                    .frame(maxWidth: 600, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

extension View {
    /// A Settings card (website style): card white, the panel radius, and the 1.5 pt ink outline. Content is clipped
    /// to it, so row tints and hairlines stay inside.
    func settingsCard() -> some View { modifier(SettingsCardSurface()) }
}

/// A Settings card, or under Native a grouped Form section.
struct SettingsCardSurface: ViewModifier {
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        if look == .native {
            content.nativeGroup()
        } else {
            content.clipShape(shape)
                .background(Ink.card, in: shape)
                .inkEdge(outline: true, radius: Radius.record)
        }
    }
}

/// The hairline between rows in a card (Native: an inset separator).
struct RowRule: View {
    @Environment(\.look) private var look
    var body: some View {
        if look == .native {
            Rectangle().fill(NativeInk.separator).frame(height: 1).padding(.leading, 12)
        } else {
            Rectangle().fill(Ink.hairline).frame(height: 1)
        }
    }
}

/// Marks a view as the target of a search result: it can be scrolled to, and it tints briefly when opened.
struct SettingsAnchor: ViewModifier {
    var id: String
    var radius: CGFloat = 0
    @ObservedObject private var model = SettingsModel.shared
    func body(content: Content) -> some View {
        content
            .background(Ink.persimmonTint.opacity(model.flashID == id ? 1 : 0), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .animation(.easeOut(duration: 0.6), value: model.flashID == id)
            .id(id)
            .onAppear { model.anchorAppeared(id) }
            .onDisappear { model.anchorDisappeared(id) }
    }
}
extension View {
    func settingsAnchor(_ id: String, radius: CGFloat = 0) -> some View { modifier(SettingsAnchor(id: id, radius: radius)) }
}

/// One setting: label and description from the index on the left, its control on the right (or below, `stacked`).
struct SettingsRow<Control: View>: View {
    var id: String
    /// Replaces the index's description when it depends on state (a status, the chosen option's note).
    var detail: String? = nil
    var detailColor: Color = Ink.mute
    var stacked = false
    @ViewBuilder var control: () -> Control

    init(_ id: String, detail: String? = nil, detailColor: Color = Ink.mute, stacked: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.id = id; self.detail = detail; self.detailColor = detailColor; self.stacked = stacked; self.control = control
    }

    private var entry: SettingsEntry? { SettingsIndex.entry(id) }
    @Environment(\.look) private var look

    var body: some View {
        let native = look == .native
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: native ? 8 : 12) { text; control() }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    control()
                }
            }
        }
        .padding(.horizontal, native ? 12 : 20).padding(.vertical, native ? 9 : 12)
        .frame(minHeight: native ? 38 : 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsAnchor(id)
        .overlay(alignment: .top) { RowRule() }
    }

    private var text: some View {
        SettingsRowText(label: entry?.label ?? id, detail: detail ?? entry?.detail ?? "", detailColor: detailColor)
    }
}

/// A row's text: the label in bold, the detail dim under it.
struct SettingsRowText: View {
    var label: String
    var detail: String = ""
    var detailColor: Color = Ink.mute
    @Environment(\.look) private var look
    var body: some View {
        let native = look == .native
        VStack(alignment: .leading, spacing: native ? 2 : 3) {
            Text(label).font(.system(size: native ? 13 : 14, weight: native ? .regular : .semibold)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail).font(.system(size: native ? 11 : 12.5)).foregroundStyle(detailColor).lineSpacing(native ? 1 : 2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
extension SettingsRow where Control == EmptyView {
    init(_ id: String, detail: String? = nil, detailColor: Color = Ink.mute) {
        self.init(id, detail: detail, detailColor: detailColor, stacked: false) { EmptyView() }
    }
}

/// A row whose control is a switch, labelled for VoiceOver with the row's label.
struct SettingsToggleRow: View {
    var id: String
    @Binding var isOn: Bool
    var detail: String? = nil
    var disabled = false
    init(_ id: String, isOn: Binding<Bool>, detail: String? = nil, disabled: Bool = false) {
        self.id = id; self._isOn = isOn; self.detail = detail; self.disabled = disabled
    }
    @Environment(\.look) private var look
    @Environment(\.controlSize) private var controlSize
    var body: some View {
        SettingsRow(id, detail: detail) {
            Toggle(SettingsIndex.entry(id)?.label ?? id, isOn: $isOn)
                .toggleStyle(.switch).labelsHidden().lookTint(look).disabled(disabled)
                .controlSize(look == .native ? .small : controlSize)   // System Settings' small switches in Native
        }
    }
}

/// Lays out a LabeledContent as label left, content right, for rows hosted outside a Form.
struct SettingsLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label.font(.system(size: NativeSwap.on ? 13 : 13.5)).foregroundStyle(Ink.ink)
            Spacer(minLength: 12)
            configuration.content
        }
    }
}

/// A toggle as label left, switch right, for rows hosted outside a Form.
struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.font(.system(size: NativeSwap.on ? 13 : 13.5)).foregroundStyle(Ink.ink)
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden()
                .tint(NativeSwap.on ? Ink.nativeAccent : Ink.switchOn)
        }
    }
}

extension View {
    /// Form-style rows (LabeledContent, Toggle, notes) shared with other screens, laid out for a Settings card.
    func settingsFormRows() -> some View {
        labeledContentStyle(SettingsLabeledStyle()).toggleStyle(SettingsToggleStyle())
    }
}

/// A toggle chip (watched folders' export formats): the website's soft filter chip, ink when on.
struct SettingsChip: View {
    var title: String
    var on: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        FilterChipLabel(title: title, selected: on, small: true, hover: hover)
            .onHover { hover = $0 }
            .tapArea(action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
    }
}

/// A line mini pill in the danger color, for destructive actions in a row ("Delete All Data…"). The word carries
/// the meaning; a confirmation always follows.
struct SettingsDangerPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.look) private var look
        var body: some View {
            if look == .native {
                NativeButtonStyleFace(configuration: configuration, prominent: false, size: .mini, tint: NativeInk.danger)
            } else {
                verbose
            }
        }
        private var verbose: some View {
            configuration.label
                .font(.system(size: PillSize.mini.font, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(Ink.danger)
                .padding(.horizontal, PillSize.mini.padding)
                .frame(height: PillSize.mini.height)
                .background {
                    ZStack {
                        Capsule().fill(Ink.danger.opacity(hover ? 0.08 : 0))
                        Capsule().strokeBorder(Ink.danger, lineWidth: 1.5)
                    }
                }
                .fixedSize()
                .contentShape(Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .onHover { hover = $0 }
                .animation(Motion.touch, value: hover)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    /// A line mini pill, for actions inside Settings rows.
    static var settingsPill: PillButtonStyle { PillButtonStyle(kind: .line, size: .mini) }
    /// A dark mini pill, for the one primary action in a Settings row.
    static var settingsPrimaryPill: PillButtonStyle { PillButtonStyle(kind: .dark, size: .mini) }
}
