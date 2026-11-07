import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine
import UIKit

/// The iPhone app's state: the same Store, recorder, player, and transcription job as the Mac, so every
/// transcript, note, bookmark, project, and Dictionary word syncs through iCloud both ways.
@MainActor @Observable
final class PhoneState {
    /// A tab: Home and the up to four you pick after it (PhoneTabBar.swift).
    typealias Tab = PhoneTab

    let store = Store()
    let recorder = Recorder()
    let player = Player()

    /// The selected tab. Tabs arrive at once, with no entrance (DESIGN.md §7). Going to a tab closes Settings.
    var tab: Tab = .home { didSet { if tab != oldValue, showSettings { showSettings = false } } }
    /// Settings, as a sheet (`openSettings`, PhoneTabs.swift).
    var showSettings = false
    /// Each tab keeps its own navigation stack.
    var homePath = NavigationPath()
    var libraryPath = NavigationPath()
    var thoughtsPath = NavigationPath()
    var journalPath = NavigationPath()
    var dictationsPath = NavigationPath()
    var projectsPath = NavigationPath()
    /// The kinds' tabs (Meetings, Interviews, …), each with its own stack, by tab.
    var kindTabPaths: [PhoneTab: NavigationPath] = [:]
    /// Settings › Personalization and preferences › Tab bar: which tabs follow Home, on this iPhone.
    let tabBarStore = PhoneTabBarStore.shared
    var tabBar: PhoneTabBar { tabBarStore.bar }
    /// The toast at the top of the screen (`say`), with its action when it has one (Undo after Delete).
    var toast: PhoneToast? = nil
    /// Whether a finger is on the toast, and when it last lifted (ToastTiming). Plain storage: nothing redraws for it.
    @ObservationIgnored private(set) var toastHold = ToastHold()
    var showRecorder = false
    /// The screenshot tour's stand-in for a running recording (no microphone in the simulator). UI test mode only.
    var previewRecording = false { didSet { previewRecordingValues.send(previewRecording) } }
    /// `previewRecording` as a publisher, for Verbose Unlock's recording limit (Unlock.swift): the value now, then each
    /// set.
    @ObservationIgnored let previewRecordingValues = CurrentValueSubject<Bool, Never>(false)
    /// "Finish your recording first": the feature that asked for the microphone while a recording runs.
    var finishRecordingFirst: String? = nil
    /// Show words while you record (MiniRecorder.swift): live text from the recorder's own buffers.
    @ObservationIgnored private(set) lazy var recordingWords = RecordingLiveText()
    /// Live captions (LiveCaptionsScreen.swift), full screen over everything.
    var showCaptions = false
    @ObservationIgnored private(set) lazy var captions = PhoneCaptions()
    /// Live captions were asked for before the one-time consent notice: they open once it's acknowledged.
    @ObservationIgnored private var pendingCaptions = false
    /// The Verbatim keyboard's session: microphone and speech model kept ready for dictation (KeyboardSession.swift).
    @ObservationIgnored private(set) lazy var session = KeyboardSession(app: self)
    /// Why the recorder paused itself (a call, a microphone it couldn't follow); nil once you resume or stop.
    var autoPauseReason: String? = nil { didSet { autoPauseReasonValues.send(autoPauseReason) } }
    /// `autoPauseReason` as a publisher, for the Live Activity (RecordingPresence.swift): the value now, then each set.
    @ObservationIgnored let autoPauseReasonValues = CurrentValueSubject<String?, Never>(nil)
    /// Set to open Library on a kind's raw value, or "all" (the screenshot tour uses it); the Library screen clears it.
    var libraryFilterRequest: String? = nil { didSet { libraryFilterRequestValues.send(libraryFilterRequest) } }
    /// `libraryFilterRequest` as a publisher, for the Library tab's `onReceive` (LibraryScreen.swift): the value now,
    /// then each set.
    @ObservationIgnored let libraryFilterRequestValues = CurrentValueSubject<String?, Never>(nil)
    /// The Add from Library sheet, open for this project (from a project's Library view, or the screenshot tour).
    var addFromLibrary: UUID? = nil
    /// The one-time recording-consent notice, shown before the first recording on this iPhone.
    var showConsentNotice = false
    static let consentNoticeKey = "consent.noticeShown"
    var showLinkSheet = false
    /// The export sheet (PhoneExportSheet), for one transcript or several.
    var exportRequest: ExportRequest? = nil
    var showImporter = false
    /// Import › Choose from Photos (videos saved from TikTok and other apps live in Photos, not Files).
    var showPhotoPicker = false
    /// Transcribe what's playing (PhoneWhatsPlaying.swift): the sheet with the system broadcast picker.
    var showPlayingSheet = false
    /// Record as's Import asks where from (Photos, files, or a link) (RecordAccessory.swift).
    var showImportChoices = false
    /// Edit Record as (the tray's foot, the Record menu's last item): which ways to record the tray shows.
    var showRecordAsEditor = false
    /// Record a call (the Record tray's Call card): the three ways that work on iPhone (PhoneCallRelay.swift).
    var showCallSheet = false
    /// Transcript screens on screen, one token each, so a second onAppear can't leave Record's accessory off after you
    /// leave (build 233). The tab bar's Record accessory turns off while you read (RecordAccessory.swift).
    var readingScreens: Set<UUID> = []
    var readingTranscripts: Int { readingScreens.count }
    /// The Action button's What's playing: the sheet asks for the system broadcast picker as soon as it shows.
    @ObservationIgnored var playingSheetStartsPicker = false
    var showOnboarding = Onboarding.shouldShow
    /// "New project…" from a row's menu: name it, then the transcript moves into it.
    var newProjectFor: UUID? = nil
    /// The transcription queue, shared with the Mac. Lazy so it can be handed the Store.
    @ObservationIgnored private(set) lazy var coordinator = TranscriptionCoordinator(store: store, config: .phone)
    /// Background time and the iOS 26 continued-processing task while the queue runs.
    @ObservationIgnored private(set) lazy var backgroundWork = PhoneBackgroundWork(isBusy: { [weak self] in
        guard let self else { return false }
        return self.runningID != nil || !self.queue.isEmpty
    })
    var queue: [UUID] { coordinator.queue }
    var runningID: UUID? { coordinator.runningID }
    /// Continue recording: the transcript the current recording will be added to.
    var continuing: UUID? = nil
    @ObservationIgnored private var pendingContinue: UUID? = nil
    /// The kind picked in the Record as tray (Record a meeting, an interview, …): the new transcript takes it as
    /// yours, so AutoLabel never replaces it and Run automatically uses it (Templates.swift). The recorder's chip shows it.
    var recordKind: RecordingKind? = nil
    /// When the recording running started, by the clock (pauses included): a switch to Thought partway files the thought
    /// on the day it began (`switchRecordingKind`).
    @ObservationIgnored var recordingStartedAt: Date? = nil
    /// The next recorder to open was started from the Record as tray: it slides in 12 pt over 150 ms, opaque from its
    /// first frame, instead of the system's presentation (RecordTray.swift).
    @ObservationIgnored var recorderSlideIn = false
    /// The recording running is a thought (PhoneThoughts.swift): it lands on today's Thoughts page when you stop.
    var recordingThought = false
    /// When that thought started; it belongs to that day's page.
    @ObservationIgnored var thoughtStartedAt: Date? = nil
    /// The next recording to start is a thought (New thought, before the notice or the microphone question).
    @ObservationIgnored var pendingThought = false
    /// The last Stop was Discard (a thought's Live Activity then ends without "Added to Thoughts").
    @ObservationIgnored var lastStopDiscarded = false
    /// Transcript ready's `.success`, once per recording (HapticPolicy.swift).
    @ObservationIgnored private var readyOnce = ReadyOnce()
    /// Stop or Discard was tapped and the recording is being saved: the record screen says "Saving…" until it's done.
    var savingRecording = false
    /// Microphone access is off: an alert with Open Settings.
    var showMicDenied = false
    /// A transcript in a language Parakeet v3 handles, with v3 not downloaded: an alert offering the download.
    var v3Offer: ParakeetV3Offer? = nil
    /// A passage to land on when the next transcript opens (from Moments or search).
    @ObservationIgnored var focusSegment: UUID? = nil
    /// A play button's transcript: the transcript that starts playing once it opens and its audio is ready.
    @ObservationIgnored var autoplay: UUID? = nil
    /// Moments marked while recording (Model/Marks.swift): from the recorder's Mark, the Dynamic Island, the Lock
    /// Screen, or the Action button. Written beside the recording as they're made, saved as bookmarks when you stop.
    var recordingMoments: [RecordingMoment] = []
    /// "Marked 4:12 · 3 moments" for two seconds after a mark (the recorder, the Island, the Lock Screen).
    private(set) var lastMark: MarkConfirmation? = nil

    // Preferences (same keys as the Mac app; each device keeps its own).
    var presetRaw: String = UserDefaults.standard.string(forKey: "preset") ?? QualityPreset.defaultPreset.rawValue { didSet { UserDefaults.standard.set(presetRaw, forKey: "preset") } }
    var identifySpeakers: Bool = UserDefaults.standard.object(forKey: "identifySpeakers") as? Bool ?? true { didSet { UserDefaults.standard.set(identifySpeakers, forKey: "identifySpeakers") } }
    var applyDictionary: Bool = UserDefaults.standard.object(forKey: "applyDictionary") as? Bool ?? true { didSet { UserDefaults.standard.set(applyDictionary, forKey: "applyDictionary") } }
    var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "system" { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }

    @ObservationIgnored private var bag = Set<AnyCancellable>()

    init() {
        // Settings › Privacy: the network activity log, before anything can use the network.
        NetworkActivityLog.install()
        // Nothing is forwarded. PhoneState is @Observable, so a view re-renders when a value it reads changes; the
        // Store is Observable too (Store.swift); and the recorder, the player, and the queue are watched directly by the
        // views that show them (`phoneState(_:)` puts them in the environment).
        coordinator.host = self
        // Every interface sound loaded now, so the first one plays at once (SoundPlayer.swift).
        DispatchQueue.main.async { Sounds.preload() }
        // Snippets (synced with the Mac) go to the Verbatim keyboard's Snippets chip through the App Group.
        store.snippetsPublisher.sink { list in
            KeyboardBridge.writeSnippets(list.map { KeyboardBridge.Snippet(id: $0.id, trigger: $0.trigger, expansion: $0.expansion) })
        }.store(in: &bag)
        // Settings › Limit animation, copied into the App Group so the keyboard follows it too (MotionMirror): now, and
        // whenever the app's defaults change (the copy writes only a change).
        mirrorLimitMotion()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.mirrorLimitMotion() }
            .store(in: &bag)
        recorder.onAutoPaused = { [weak self] reason in self?.autoPauseReason = reason; self?.say(reason); Haptics.play(.autoPaused) }
        recorder.onInputSwitched = { [weak self] note in
            if self?.recorder.isPaused == false { self?.autoPauseReason = nil }
            self?.say(note)
        }
        // A wired or USB mic went silent: the recording moved to the iPhone's microphone (DESIGN.md §6.10, A muted microphone). The
        // recorder shows a banner with Switch back; here, a warning haptic, a toast, and in the background a notification.
        recorder.onMicWarning = { [weak self] w in
            let note = w.flatMap(PhoneState.mutedNote)
            if let note { self?.say(note); Haptics.play(.autoPaused) }
            RecordingPresence.shared.micMuted(note)
        }
        // Recordings recovered once launch recovery finishes in the background: transcribe them too.
        store.onRecovered = { [weak self] ids, announce in self?.queueRecovered(ids, announce: announce) }
        // Files and links shared to Verbatim, and sound from Transcribe what's playing (PhoneInbox.swift). PhoneRoot
        // imports again each time the app becomes active; the broadcast extension's notification covers an open app.
        // Each import waits for the library to load (`importInbox`).
        watchInbox()
        // The recording's Live Activity and its paused-for-a-call notification (RecordingPresence.swift).
        RecordingPresence.shared.attach(self)
        // New thought from a widget, control, the Action button, Back Tap, or Siri (NewThoughtIntent, PhoneThoughts.swift).
        ThoughtSignal.attach(self)
        // Recordings from the Apple Watch, and today's thought count for it (PhoneWatch.swift). Watch Connectivity itself
        // is activated at launch (PhoneAppDelegate), so files arrive even before this runs.
        PhoneWatchLink.shared.attach(self)
        // The queue, unfinished imports, link fetches, the keyboard's numbers, the widgets, and the self-test start
        // once the library has loaded (the transcripts are decoded off the main thread, after the first frame).
        store.whenLoaded { [weak self] in self?.resumeAfterLoad() }
    }

    /// What launch starts once the library has loaded (`Store.whenLoaded`), in the order it always ran.
    private func resumeAfterLoad() {
        // The consolidation: Record as's rows a device starts with, once (RecordAsRows.seeded; PhoneConsolidation.swift).
        PhoneConsolidation.afterLibraryLoaded(store)
        // Home's numbers for the keyboard's Home screen (KeyboardBridge.Stats): the same counts as This week. Worked
        // out on a background queue a second after the library or the typing pace changes (progress ticks don't change
        // the library; they go to the StageClock), and written only when the numbers differ. Comparing the numbers,
        // not the dictations, keeps a library change from deep-comparing every dictation, words and all.
        store.transcriptsPublisher.combineLatest(FlowSettings.shared.$typingWPM)
            .debounce(for: .seconds(1), scheduler: Self.statsQueue)
            .map { (pair: ([Transcript], Int)) -> KeyboardBridge.Stats in
                let live = pair.0.filter { $0.deletedAt == nil && $0.isDictation }
                // The running tally keeps deleted dictations, for all time on You, Home, and the keyboard.
                let all = DictationTally.shared.merge(live)
                return Self.keyboardStats(live, typingWPM: pair.1, allTime: all.span)
            }
            .removeDuplicates()
            .sink { (stats: KeyboardBridge.Stats) in KeyboardBridge.writeStats(stats) }
            .store(in: &bag)
        // Resume only this iPhone's own jobs; the Mac's show as "Transcribing on Mac".
        coordinator.resume(includeUnowned: false)
        if !queue.isEmpty { DispatchQueue.main.async { self.pump() } }
        // Templates: a banner when Run automatically finishes, and runs iOS stopped before they finished.
        TemplateCenter.shared.automatic = !PhoneUITest.enabled
        TemplateCenter.shared.announce = { [weak self] msg in self?.say(msg) }
        TemplateCenter.shared.resumeWaiting(store: store)
        // Ask: the passage index catches up in the background, never while something records or transcribes. Recipes
        // run when iOS gives Verbose background time near their schedule (AskBackgroundRefresh), or at the next open.
        AskCenter.shared.automatic = !PhoneUITest.enabled
        AskCenter.shared.attach(store) { [weak self] in
            guard let self else { return true }
            return self.recorder.isRecording || self.session.isOn || self.runningID != nil
        }
        AskRecipeCenter.shared.automatic = !PhoneUITest.enabled
        AskRecipeCenter.shared.scheduleBackground = { date in AskBackgroundRefresh.schedule(date) }
        AskRecipeCenter.shared.attach(store)
        // Picked files the app quit in the middle of importing start again (their placeholders are still "Importing").
        let resumable = store.takeResumableImports().compactMap { pair -> (UUID, ImportSource)? in
            let (id, url) = pair
            guard let t = store.transcript(id) else { return nil }
            return (id, ImportSource(url: url, title: t.title, label: t.sourceLabel, source: t.source))
        }
        if !resumable.isEmpty { DispatchQueue.main.async { self.runImportSources(resumable) } }
        if !PhoneUITest.enabled { DispatchQueue.main.async { self.resumeLinkFetches() } }
        if !PhoneUITest.enabled { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.importInbox() } }
        // The Home Screen widgets' snapshot in the App Group (App/WidgetFeed.swift).
        WidgetFeed.shared.attach(store)
        if PhoneUITest.enabled { PhoneUITest.run(self) }
    }

    /// Where the keyboard's Home numbers are worked out (`keyboardStats`), off the main thread.
    private static let statsQueue = DispatchQueue(label: "co.stumpandroot.verbatim.keyboard-stats", qos: .utility)

    /// The keyboard's Home numbers from your dictations: this week's words and time saved (as Home's This week card
    /// counts them), all time's words and time saved (the running tally, `allTime`, when it's ahead of the dictations
    /// kept), and the words and seconds behind your speaking pace. Pure, so it runs on `statsQueue`.
    nonisolated static func keyboardStats(_ items: [Transcript], typingWPM: Int, allTime: TimeSaved.Span? = nil,
                                          now: Date = Date(), calendar: Calendar = .current) -> KeyboardBridge.Stats {
        let entries = HomeCounts.entries(fromDictations: items)
        let week = HomeWeek(entries, now: now, calendar: calendar)
        var saved = TimeSaved(entries, now: now, calendar: calendar)
        if let allTime { saved.useAllTime(allTime, since: nil) }
        let ends = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? now.addingTimeInterval(7 * 86_400)
        let timed = entries.filter { $0.seconds > 0 }
        return KeyboardBridge.Stats(weekWords: week.words, weekSecondsSaved: week.secondsSaved(typingWPM: typingWPM), weekEnds: ends,
                                    totalWords: saved.all.words, totalSecondsSaved: saved.all.saved(typingWPM: typingWPM),
                                    paceWords: timed.reduce(0) { $0 + $1.words }, paceSeconds: timed.reduce(0) { $0 + $1.seconds },
                                    typingWPM: typingWPM)
    }

    var preset: QualityPreset { QualityPreset(rawValue: presetRaw) ?? .defaultPreset }
    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }

    /// "Shure MV7 seems to be muted. Recording continues on the iPhone microphone."
    nonisolated static func mutedNote(_ w: MicWarning) -> String? {
        guard case .usingBuiltIn(_, let chosen, _) = w else { return nil }
        return "\(chosen) seems to be muted. Recording continues on the iPhone microphone."
    }

    /// Copies Settings › Limit animation into the App Group, where the keyboard reads it (MotionMirror).
    func mirrorLimitMotion() {
        MotionMirror.mirror(UserDefaults.standard.bool(forKey: MotionPreference.key), into: KeyboardBridge.defaults)
    }

    /// Shows a toast. A message alone goes after 3 s; one with an action (Undo) stays at least 8 s, and while a finger
    /// is on it (ToastTiming, DESIGN.md §7). `celebration`: a finished transcript's fill sweeps it (DESIGN.md §7,
    /// Celebrations).
    func say(_ s: String, action: String? = nil, celebration: CelebrationTicket? = nil, onAction: (() -> Void)? = nil) {
        var t = PhoneToast(s, action: action, onAction: onAction)
        t.celebration = celebration
        toast = t
        endToastWhenDue(t.id)
    }

    /// A finger came down on the toast (true) or lifted (false). A toast with an action stays while it's held, and a
    /// moment after (ToastTiming).
    func holdToast(_ on: Bool) {
        guard let t = toast else { return }
        toastHold.set(on, for: t.id)
        if !on { endToastWhenDue(t.id) }
    }

    /// The toast's action (its button): runs it once and closes the toast.
    func runToastAction() {
        guard let t = toast else { return }
        toast = nil
        t.onAction?()
    }

    /// Closes toast `id` when its time is up, asking ToastTiming again after each wait (a hold may have started or
    /// ended meanwhile). A held toast waits for the finger to lift, which asks again.
    private func endToastWhenDue(_ id: UUID) {
        guard let t = toast, t.id == id else { return }
        let now = Date()
        guard let wait = ToastTiming.remaining(elapsed: now.timeIntervalSince(t.shownAt), hasAction: t.action != nil, plain: ToastTiming.phonePlain,
                                               held: toastHold.isHeld(id), sinceRelease: toastHold.sinceRelease(id, now: now)) else { return }
        if wait <= 0 { toast = nil; return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.endToastWhenDue(id)
        }
    }

    func open(_ id: UUID, segment: UUID? = nil) {
        focusSegment = segment
        pushHere(id)
    }

    // MARK: Recording

    func requestRecord(appendTo target: UUID? = nil, kind: RecordingKind? = nil) {
        // A recording is running behind the bar: Record brings it back instead of starting another.
        if RecorderPresentation.recordTap(recording: recorder.isRecording || previewRecording, saving: savingRecording) == .reopen { recorderSlideIn = false; openRecorder(); return }
        pendingContinue = target
        // A plain Record leaves the kind to AutoLabel; a picked one (Record a meeting) is yours.
        recordKind = target == nil ? kind : nil
        if !UserDefaults.standard.bool(forKey: Self.consentNoticeKey) { showConsentNotice = true; return }
        askMicAndRecord()
    }

    func dismissConsentNotice() { pendingContinue = nil; pendingCaptions = false; pendingThought = false; recorderSlideIn = false }

    /// The consent notice's OK: remembered, then recording starts as asked.
    func acknowledgeConsentNotice() {
        UserDefaults.standard.set(true, forKey: Self.consentNoticeKey)
        if pendingCaptions { pendingCaptions = false; askMicAndOpenCaptions(); return }
        askMicAndRecord()
    }

    private func askMicAndRecord() {
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                if ok { self.startRecording() } else {
                    self.pendingContinue = nil; self.pendingThought = false; self.recorderSlideIn = false; self.showMicDenied = true
                    Haptics.play(.failed); Sounds.play(.error)
                }
            }
        }
    }

    func startRecording() {
        // The microphone can serve one of them: a voice memo ends the keyboard session.
        if session.isOn { session.end(reason: "The session ended for a voice memo. Tap to start a new one.") }
        guard !savingRecording else { say("Saving the last recording. Try again in a moment."); return }
        // The Live Activity before the microphone, every time. A recording a widget, control, Siri, or the Action
        // button started belongs to their audio recording intent even after it brings Verbose forward, and iOS 27
        // closes the app when that intent's audio session turns on with no Live Activity showing (`InPlaceRecording`).
        let activityFirst = RecordingPresence.shared.startActivityBeforeRecording(thought: pendingThought)
        do {
            let url = store.newRecordingURL()
            // Audio only keeps the sound: no live words, and the system's voice processing off (Recorder.soundOnly).
            let soundOnly = recordKind == .audio && pendingContinue == nil
            recorder.soundOnly = soundOnly
            // A thought with Show words in the Dynamic Island keeps its live words going in the background.
            recordingWords.keepInBackground = pendingThought && ThoughtRules.islandWords()
            if !soundOnly { recordingWords.prepare(recorder) }   // before start, so live text hears the first word
            // The start tap plays before the microphone opens, so it isn't in the recording. (In the background, from
            // the Action button, a widget, or Siri, iOS plays nothing; the Live Activity shows the start instead.)
            Haptics.play(.recordStart)
            let thought = pendingThought
            try recorder.start(to: url)
            // The sound once the microphone is open (iOS plays it then because the session allows system sounds while
            // recording); what the microphone hears of it is written as silence (MicKeepOut). Only with Verbose in front.
            Sounds.play(SoundRules.start(thought: thought), keepingOutOf: recorder)
            recordingStartedAt = Date()
            if !soundOnly { recordingWords.begin() }
            // Audio only or a Brain dump: if Verbose is closed mid-recording, recovery files it as that kind.
            if pendingContinue == nil { Store.markKind(url, recordKind) }
            recordingMoments = []
            continuing = pendingContinue
            pendingContinue = nil
            // If Verbatim is closed mid-recording, recovery adds it to this transcript (RecordingSafety.swift).
            if let target = continuing { Store.markContinuation(url, to: target) }
            // A thought: if Verbatim is closed mid-thought, recovery brings it back as a thought on the day it started.
            beginThoughtIfAsked(url)
            presentRecorder()
            warmModel()
            if let warning = Store.lowSpaceWarning() {
                say(warning)
                // A beat after the start tap, so the two don't run together.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Haptics.play(.lowStorage) }
            }
        } catch {
            recordingWords.end()
            pendingThought = false
            recorderSlideIn = false
            if activityFirst { RecordingPresence.shared.cancelActivityBeforeRecording() }
            say("Couldn't start recording: \(error.localizedDescription)")
            Haptics.play(.failed)
            Sounds.play(.error)
        }
    }

    /// Opens the recorder sheet. Started from the Record as tray, it appears at once with no system transition and
    /// slides its content up 12 pt over 150 ms (RecorderSheet), opaque from its first frame; with Limit animation or
    /// Reduce Motion it appears at once and doesn't move (DESIGN.md §7).
    private func presentRecorder() {
        // Settings is a sheet too: it closes first (`closeSettings`).
        if showSettings { closeSettings { [weak self] in self?.presentRecorder() }; return }
        guard recorderSlideIn else { showRecorder = true; return }
        recorderSlideIn = false
        let still = UserDefaults.standard.bool(forKey: MotionPreference.key) || UIAccessibility.isReduceMotionEnabled
        RecorderSheet.slideInNext = !still
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { showRecorder = true }
    }

    /// The Action button's Record a voice note, or Record from a widget, with Verbose in the background (iOS 18 and
    /// later, through `AudioRecordingIntent`): starts its Live Activity, then the recording, in place
    /// (`InPlaceRecording`: never the microphone first), only when nothing needs asking (the consent notice was seen
    /// and the microphone is allowed) and nothing else holds the microphone. True when both started. False
    /// otherwise, with nothing recording; the intent then opens Verbose to the recorder.
    func startVoiceNoteInPlace() -> Bool {
        guard UserDefaults.standard.bool(forKey: Self.consentNoticeKey),
              AVAudioApplication.shared.recordPermission == .granted,
              !recordingActive, !savingRecording, !showCaptions else { return false }
        let outcome = InPlaceRecording.start(
            startActivity: { RecordingPresence.shared.startActivityBeforeRecording(thought: false) },
            startRecording: { startRecording(); return recorder.isRecording },
            endActivity: { RecordingPresence.shared.cancelActivityBeforeRecording() })
        if case .openVerbose(let why) = outcome {
            Log.note("action button: \(why); opening Verbose")
            return false
        }
        Log.note("action button: voice note started in place")
        return true
    }

    /// Loads the speech model while you talk, so transcription starts the moment you stop. iOS clears it from
    /// memory when Verbatim is closed, so without this every recording would wait for it to load first.
    ///
    /// Not for a recording started in place from a widget, control, Siri, or the Action button with Verbose in the
    /// background: loading the model there competes with the intent's start for the Neural Engine and the disk, and
    /// the model loads when Verbose comes forward (`KeyboardSession.warmAhead`) or when transcription starts.
    func warmModel() {
        guard UIApplication.shared.applicationState == .active else {
            Log.note("speech model warm-up skipped: the recording started with Verbose in the background")
            return
        }
        let (engineId, model) = engineChoice
        guard engineId == "fluid" else { return }
        Task.detached(priority: .utility) { await FluidEngine.shared.warm(model: model) }
    }

    private var engineChoice: (String, String) {
        preset == .advanced ? (UserDefaults.standard.string(forKey: "advEngine") ?? "fluid", UserDefaults.standard.string(forKey: "advModel") ?? "v2") : preset.config
    }

    /// Starts a recording that's added to the end of an existing transcript when you stop.
    func continueRecording(_ id: UUID) {
        guard coordinator.canContinue(id) else {
            say("This transcript can't take more recording right now."); return
        }
        requestRecord(appendTo: id)
    }

    /// Pause or Resume on the record screen. Resuming clears an automatic pause's reason.
    /// Pause plays its tap after the audio stops being written; Resume plays it before writing starts again, so
    /// neither ends up in the recording.
    func togglePause() {
        let resuming = recorder.isPaused
        if resuming { Haptics.play(.resume) }
        recorder.togglePause()
        if !resuming, recorder.isPaused { Haptics.play(.pause) }
        if !recorder.isPaused { autoPauseReason = nil }
    }

    /// Stop: capture ends at once, the recorder says "Saving…" while a long
    /// recording's parts are joined off the main thread, then it joins the queue. Nothing that reached the disk
    /// is thrown away: only a recording with no audio at all is removed, with a message saying so. `source`: where the
    /// Stop came from; only the recorder's own Stop celebrates (RecordingFinish, DESIGN.md §7).
    func stopRecording(from source: StopSource = .elsewhere) {
        guard !savingRecording else { return }
        Task { await finishRecording(discard: false, source: source) }
    }

    /// Discard: after you confirm, the recording goes to Recently Deleted (not transcribed, restorable for 30 days).
    func discardRecording() {
        guard !savingRecording else { return }
        Task { await finishRecording(discard: true) }
    }

    private func finishRecording(discard: Bool, source: StopSource = .elsewhere) async {
        // Stop or Discard: the stop tap plays at the tap, not after a long recording's parts are joined.
        Haptics.play(.recordStop)
        lastStopDiscarded = discard
        recordingWords.end()   // the preview stops at once; the saved transcript comes from the full engine
        autoPauseReason = nil
        let moments = recordingMoments
        recordingMoments = []
        lastMark = nil
        let target = continuing
        continuing = nil
        let kind = recordKind
        recordKind = nil
        recordingStartedAt = nil
        let thoughtStart = recordingThought ? (thoughtStartedAt ?? Date()) : nil
        recordingThought = false
        thoughtStartedAt = nil
        // Finishing a recording (DESIGN.md §7, Celebrations): a tap on the recorder's Stop fills its ring while it saves,
        // `.success` lands as the ring fills, and "Saved" shows on Home's Record card when Home is under the recorder.
        let plan = RecordingFinish.phone(source: source, discard: discard, thought: thoughtStart != nil, homeUnderneath: tab == .home && homePath.isEmpty)
        let tapped = Date()
        let ring = plan.ring ? CelebrationCenter.shared.fillRing(tone: thoughtStart != nil ? .butter : .persimmon) : nil
        savingRecording = true
        // The stop sound once the microphone is off (so it isn't recorded), before a long recording's parts are joined.
        // A thought saved has its own; Discard is a stop too.
        let stopSound = SoundRules.stop(thought: thoughtStart != nil && !discard)
        let stopped = await recorder.stopAndSave(captureEnded: { Sounds.play(stopSound) })
        if let ring {
            let saved = stopped.map { !$0.joinFailed && $0.framesWritten > 0 } ?? false
            await finishRing(ring, tapped: tapped, saved: saved, haptic: plan.haptic)
        }
        savingRecording = false
        showRecorder = false
        CelebrationCenter.shared.clearRing()
        guard let r = stopped else { return }
        if r.joinFailed {
            // Every part stays in the recordings folder; launch recovery joins it into one recording (and the
            // continuation marker sends it to the right transcript, the thought marker to Thoughts).
            say(Store.joinFailedNotice)
            Haptics.play(.failed)
            return
        }
        Store.clearContinuation(r.startedAs ?? r.url)
        Store.clearThoughtMark(r.startedAs ?? r.url)
        Store.clearThoughtMark(r.url)
        Store.clearKindMark(r.startedAs ?? r.url)
        Store.clearKindMark(r.url)
        recorder.soundOnly = false
        Marks.clear(r.startedAs ?? r.url)
        Marks.clear(r.url)
        guard r.framesWritten > 0 else {
            try? FileManager.default.removeItem(at: r.url)
            say(Store.nothingRecordedNotice)
            return
        }
        if discard {
            if store.keepDiscarded(r) != nil { say("Moved to Recently Deleted.") }
            else { say("Couldn't move the recording. Verbose recovers it the next time it opens."); Haptics.play(.failed) }
            return
        }
        // "Saved" on Home's Record card once the recorder has closed over it.
        if plan.savedChip { CelebrationCenter.shared.showSaved(after: CelebrationTiming.afterSheet) }
        // A free recording past 10 minutes is saved in full; its first 10 minutes transcribe (FreeTranscription).
        let freeLimit = UnlockStore.shared.freeLimit(forDuration: r.duration)
        if let target {
            let offset = store.transcript(target)?.duration ?? 0
            if let freeLimit { store.update(target) { $0.freeTranscriptLimit = freeLimit } }
            guard coordinator.queueAppend(recording: r.url, to: target) else { say("Couldn't save the recording."); Haptics.play(.failed); return }
            if freeLimit != nil { UnlockStore.shared.savedPastFreeTranscription(noun: "recording") }
            for n in Store.skippedNotes(r.skipped, offset: offset) + RecordingMoment.notes(moments, offset: offset) { store.addNote(n, to: target) }
            readyOnce.newRecording(target)
            return
        }
        if let thoughtStart {
            // A thought joins its day at once, with its time, and transcribes after ("Saved as audio. Transcribing…").
            let id = fileThought(url: r.url, duration: r.duration, envelope: r.envelope, startedAt: thoughtStart, skipped: r.skipped,
                                 moments: moments, freeLimit: freeLimit)
            if id != nil, freeLimit != nil { UnlockStore.shared.savedPastFreeTranscription(noun: "thought") }
            return
        }
        guard let name = store.adoptRecording(r.url) else { say("Couldn't save the recording."); Haptics.play(.failed); return }
        var t = Transcript(title: kind == .audio ? "Audio only" : "Voice note", source: .voiceMemo, sourceLabel: "Voice memo", duration: r.duration, audioFileName: name, model: "")
        t.waveform = r.envelope
        t.notes = Store.skippedNotes(r.skipped) + RecordingMoment.notes(moments)
        t.pickKindAtStart(kind)
        if t.isAudioOnly {
            // Audio only: kept as sound, never queued ("Saved. No transcript."). No limit: there's nothing to transcribe.
            coordinator.keepAudioOnly(t)
            say(AudioOnlyCopy.saved)
            return
        }
        t.freeTranscriptLimit = freeLimit
        enqueue(t)
        if freeLimit != nil { UnlockStore.shared.savedPastFreeTranscription(noun: kind.map { RecordChoice.kind($0).name.lowercased() } ?? "voice note") }
    }

    /// The stop ring after the save (DESIGN.md §7, Celebrations): `.success` as the ring finishes filling, once the
    /// recording is saved (at once when saving took longer than the fill), then the ring holds a moment and the recorder
    /// closes. A tap on the recorder skips to the end. Discard, a thought, and a stop from outside the recorder have no
    /// ring (RecordingFinish).
    private func finishRing(_ ring: CelebrationTicket, tapped: Date, saved: Bool, haptic: Bool) async {
        let center = CelebrationCenter.shared
        let toFill = RecordingFinish.hapticDelay(sinceTap: Date().timeIntervalSince(tapped), skipped: center.skipped(ring.id))
        if toFill > 0 { _ = await celebrationWait(toFill, ring.id) }
        if haptic && saved { Haptics.play(.recordingSaved) }
        let toClose = RecordingFinish.closeDelay(sinceTap: Date().timeIntervalSince(tapped), ring: true, skipped: center.skipped(ring.id))
        if toClose > 0 { _ = await celebrationWait(toClose, ring.id) }
    }

    /// Mark a moment (Model/Marks.swift): a bookmark at the recording's current time, saved with it when you stop. From
    /// the recorder's Mark, the Dynamic Island and the Lock Screen (`MarkMomentIntent`), or the Action button's Record
    /// or mark. A second mark within 3 seconds confirms the first instead of adding one. Each mark is written beside the
    /// recording at once, so a recording Verbose didn't get to stop keeps its moments. A light tap and "Marked 4:12"
    /// for two seconds confirm it. False when nothing is recording.
    @discardableResult
    func markMoment(source: MarkSource = .phoneApp) -> Bool {
        guard recorder.isRecording || previewRecording else { return false }
        let mark = RecordingMoment(at: recorder.elapsed, source: source.rawValue)
        let (marks, confirmed) = Marks.adding(mark, to: recordingMoments)
        recordingMoments = marks
        if let url = recorder.recordingURL { Marks.save(marks, for: url) }
        let c = MarkConfirmation(at: confirmed.at, count: marks.count)
        lastMark = c
        Haptics.play(.mark)
        Log.note("marks: marked \(Marks.clock(confirmed.at)) from \(source.rawValue) (\(marks.count) in this recording)")
        RecordingPresence.shared.marked()
        DispatchQueue.main.asyncAfter(deadline: .now() + Marks.confirmSeconds) { [weak self] in
            guard let self, self.lastMark?.id == c.id else { return }
            self.lastMark = nil
            RecordingPresence.shared.marked()
        }
        return true
    }

    /// Transcribe on an Audio only recording (its detail screen, the Library row's menu): the normal queue, filed as a
    /// voice note or as the kind picked with Transcribe as when the words are in (AudioOnly.swift).
    func transcribeLater(_ id: UUID, as kind: RecordingKind? = nil) {
        guard let t = store.transcript(id), AudioOnlyRules.canTranscribe(t) else { return }
        // Free: an Audio only recording past 10 minutes transcribes its first 10 (FreeTranscription).
        if !UnlockStore.shared.state.hasEverything, t.duration > FreeTranscription.limit {
            store.update(id) { $0.freeTranscriptLimit = FreeTranscription.limit }
        }
        coordinator.transcribeLater(id, as: kind)
        warmModel()
    }

    /// A kind picked for a recording (the kind chip, Details): yours from then on. An Audio only recording with no words
    /// that you file as another kind is transcribed as that kind, since only Audio only keeps sound without words.
    /// Nothing is ever deleted: the transcript, notes, moments, and results stay.
    func pickKind(_ k: RecordingKind, for id: UUID) {
        guard let t = store.transcript(id) else { return }
        if t.showsAudioDetail, k != .audio, t.status != .processing { transcribeLater(id, as: k); return }
        store.update(id) { $0.kind = k; $0.kindIsAuto = false }
    }

    /// Recordings recovered after launch: transcribed now (or added to the transcript they continued).
    func queueRecovered(_ ids: [UUID], announce: Bool = true) {
        for id in ids where !queue.contains(id) && runningID != id { coordinator.enqueueExisting(id) }
        guard announce else { return }
        say(ids.count == 1 ? "Recovered a recording. Transcribing it now." : "Recovered \(ids.count) recordings. Transcribing them now.")
    }

    /// Settings › Microphone access: opens Verbatim's page in the Settings app.
    func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // MARK: Live captions

    /// Home's Live captions. Captions record the room too, so the one-time consent notice comes first.
    func requestCaptions() {
        // Part of Verbose Unlock: while locked, the unlock sheet opens instead (Unlock.swift).
        guard allow(.liveCaptions) else { return }
        if recordingActive { askToFinishRecording(for: "live captions"); return }
        if PhoneUITest.enabled { captions.seedForScreenshots(); showCaptions = true; return }
        if !UserDefaults.standard.bool(forKey: Self.consentNoticeKey) { pendingCaptions = true; showConsentNotice = true; return }
        askMicAndOpenCaptions()
    }

    private func askMicAndOpenCaptions() {
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                if ok { self.openCaptions() } else { self.showMicDenied = true; Haptics.play(.failed); Sounds.play(.error) }
            }
        }
    }

    private func openCaptions() {
        if showSettings { closeSettings { [weak self] in self?.openCaptions() }; return }
        guard !recorder.isRecording else { askToFinishRecording(for: "live captions"); return }
        // The microphone can serve one of them: live captions end the keyboard session.
        if session.isOn { session.end(reason: "The session ended for live captions. Tap to start a new one.") }
        showCaptions = true
        let url = store.newRecordingURL()
        Task {
            if await captions.start(to: url) {
                warmModel()
            } else {
                showCaptions = false
                say(captions.status ?? "Couldn't start live captions.")
                Haptics.play(.failed)
                Sounds.play(.error)
            }
        }
    }

    /// Stop or Save transcript on the captions screen.
    func stopCaptions(save: Bool) {
        Haptics.play(.recordStop)
        showCaptions = false
        if PhoneUITest.enabled { captions.endScreenshots(); return }
        guard save else { captions.discard(); return }
        guard let (url, duration, env) = captions.stop() else { say("Couldn't finish saving. Verbose will recover the recording the next time it opens."); Haptics.play(.failed); return }
        // A short one is kept too; only a recording with no audio at all is removed.
        guard duration > 0 else { try? FileManager.default.removeItem(at: url); say(Store.nothingRecordedNotice); return }
        guard let name = store.adoptRecording(url) else { say("Couldn't save the recording."); Haptics.play(.failed); return }
        var t = Transcript(title: "Live captions", source: .voiceMemo, sourceLabel: "Live captions", duration: duration, audioFileName: name, model: "")
        t.waveform = env
        enqueue(t)
        say("Saved. Transcribing now.")
    }

    // MARK: Import

    @discardableResult
    func importFiles(_ urls: [URL]) -> [UUID] {
        let files = MediaImport.expand(urls)
        guard !files.isEmpty else { say("No audio or video found."); return [] }
        let ids = importSources(files.map {
            ImportSource(url: $0, title: $0.deletingPathExtension().lastPathComponent, label: $0.pathExtension.uppercased() + " file")
        })
        if files.count > 1 { say("Added \(files.count) files") }
        return ids
    }

    /// A file to import, and what its transcript is called and says about where it came from.
    struct ImportSource {
        var url: URL
        var title: String
        var label: String
        var source: SourceKind = .file
        var createdAt: Date? = nil
        /// A kind you chose (a thought from the Apple Watch): kept, so AutoLabel never replaces it. Nil lets AutoLabel pick.
        var kind: RecordingKind? = nil
        /// Notes the transcript starts with (the Apple Watch's marks, as bookmarks).
        var notes: [Note] = []
        /// Runs once the audio is prepared or the import failed (the inbox deletes its staged copy here).
        var finished: (() -> Void)? = nil
    }

    /// The import path for picked, shared, and played files: each transcript appears at once ("Importing"), then
    /// its audio is prepared (video becomes M4A) and it joins the transcription queue.
    @discardableResult
    func importSources(_ sources: [ImportSource]) -> [UUID] {
        var pending: [(UUID, ImportSource)] = []
        for s in sources {
            var t = Transcript(title: s.title, source: s.source, sourceLabel: s.label, duration: 0, audioFileName: nil, model: "")
            if let d = s.createdAt { t.createdAt = d }
            if let k = s.kind { t.kind = k; t.kindIsAuto = false }
            if !s.notes.isEmpty { t.notes = s.notes }
            t.status = .processing; t.stage = PendingImports.stage; t.processingDevice = Device.id; t.processingDeviceName = Device.name
            store.add(t)
            // Picked files: if the app quits before the audio is ready, launch imports the file again when it's still
            // there (Store.cleanUpStuckImports). The inbox imports its staged copies again itself.
            if s.finished == nil { PendingImports.record(t.id, source: s.url) }
            pending.append((t.id, s))
        }
        runImportSources(pending)
        return pending.map { $0.0 }
    }

    /// Prepares each placeholder's audio in turn and queues it. Also resumes imports the app quit in the middle of.
    func runImportSources(_ pending: [(UUID, ImportSource)]) {
        guard !pending.isEmpty else { return }
        Task {
            for (id, s) in pending {
                let src = s.url
                let access = src.startAccessingSecurityScopedResource()
                defer { PendingImports.clear(id) }
                do {
                    // Several audio tracks: mixed, or kept apart as speakers (Settings › Files with several audio tracks).
                    let folder = AudioTracksPreference.current == .separate ? Paths.tracks(id) : nil
                    let store = self.store
                    let dest = store.newAudioURL(ext: "m4a")
                    PendingImports.writing(id, to: dest)
                    let prepared = try await MediaImport.prepare(src, into: dest, separateTracksInto: folder) { s in
                        Task { @MainActor in store.setStage(id, s) }
                    }
                    if store.transcript(id) == nil {
                        // Cancelled from the "added" card while the audio was being prepared.
                        try? FileManager.default.removeItem(at: prepared.url)
                        if folder != nil { try? FileManager.default.removeItem(at: Paths.tracks(id)) }
                    } else {
                        store.update(id) {
                            $0.audioFileName = prepared.url.lastPathComponent; $0.duration = prepared.duration; $0.stage = "Queued"
                            if let mt = prepared.multitrack { $0.multitrack = mt; $0.waveform = prepared.wave }
                        }
                        // The screenshot tour never runs the speech engines (they download models).
                        if !PhoneUITest.enabled { coordinator.enqueueExisting(id) }
                        // A video's stills for the transcript's margin, while the file is still here (VideoStills).
                        await store.addStills(id, from: src)
                    }
                } catch {
                    store.update(id) { $0.status = .failed; $0.stage = nil; $0.error = error.localizedDescription }
                }
                if access { src.stopAccessingSecurityScopedResource() }
                s.finished?()
            }
        }
    }

    /// Adds a link: the transcript appears in Library right away, then this iPhone resolves the link, downloads
    /// the audio, and transcribes it like any import. Sites the iPhone can't fetch go to the Mac when one syncs.
    func addLink(_ raw: String) {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: link), let host = u.host, host.contains("."), ["http", "https"].contains(u.scheme ?? "") else { say("That doesn't look like a link."); return }
        var t = Transcript(title: link, source: .link, sourceLabel: host.replacingOccurrences(of: "www.", with: ""), duration: 0, audioFileName: nil, model: "")
        t.sourceURL = link
        t.status = .processing
        t.stage = "Getting the link ready"
        t.processingDevice = Device.id; t.processingDeviceName = Device.name
        store.add(t)
        libraryFilterRequest = "all"
        startLinkFetch(t.id)
        // The "link added" card shows the fetch; its tile lands on the Library tab (PhoneLinkCard.swift).
        if let imp = linkImports[t.id] {
            if let old = linkCardImport, old.id != t.id { linkBadgeHeld.remove(old.id) }
            linkBadgeHeld.insert(t.id)
            linkCardImport = imp
        }
    }

    /// A show or feed found while fetching a link: the root's episode picker sheet (EpisodePicker.swift).
    struct EpisodeChoice: Identifiable {
        let id = UUID()
        let link: URL
        let show: PodcastShow?
    }
    var episodeChoice: EpisodeChoice? = nil

    /// Links being fetched on this iPhone, by transcript. A "link added" view can observe `latestLinkImport`.
    private(set) var linkImports: [UUID: LinkImport] = [:]
    private(set) var latestLinkImport: LinkImport? = nil
    @ObservationIgnored private var linkTasks: [UUID: Task<Void, Never>] = [:]
    /// The link whose "link added" card is showing.
    var linkCardImport: LinkImport? = nil
    /// Links counted by the Library badge only once their card has landed there.
    var linkBadgeHeld: Set<UUID> = []

    /// Resolves, downloads, and prepares a link transcript's audio, then queues it for transcription.
    private func startLinkFetch(_ id: UUID) {
        // http and https only: a record synced from another device can hold any address (IPH-17).
        guard let t = store.transcript(id), let link = t.sourceURL ?? t.link?.url, let u = LinkInfo.web(link) else { return }
        linkTasks[id]?.cancel()
        let imp = LinkImport(id: id, url: link, site: PhoneLinkFetcher.siteName(u))
        linkImports[id] = imp
        latestLinkImport = imp
        // The screenshot tour never fetches the link (its card shows YouTube's thumbnail, as before).
        guard !PhoneUITest.enabled else { imp.thumbnailURL = LinkImport.quickThumbnail(u); return }
        // Settings › Privacy: logged by host, and refused before it starts while Local Only is on.
        let netEvent: UUID?
        do { netEvent = try NetworkGate.begin(.linkDownload, host: NetworkHost.of(link)) } catch {
            store.update(id) { x in x.status = .failed; x.stage = nil; x.error = LocalOnly.message(.linkDownload); x.processingDevice = nil; x.processingDeviceName = nil }
            imp.phase = .failed(LocalOnly.message(.linkDownload))
            return
        }
        // YouTube's thumbnail, from the video ID, before anything else loads; only once Local Only allows the link.
        imp.thumbnailURL = LinkImport.quickThumbnail(u)
        let bg = BackgroundTime("Download link")
        linkTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.linkImports[id] === imp { self.linkTasks[id] = nil }
                bg.end()
            }
            var downloaded: URL?
            // Called at most once per whole percent.
            let report: @Sendable (Double?) -> Void = { fraction in
                Task { @MainActor in
                    guard imp.phase == .downloading else { return }   // a late report after the download finished
                    imp.progress = fraction
                    if let fraction { self.store.setStage(id, "Downloading \(Int(fraction * 100))%") }
                }
            }
            do {
                var r: PhoneLinkFetcher.Resolved?
                let file: URL
                // The background download from before Verbatim last closed: it finished meanwhile or is still going.
                imp.phase = LinkDownloads.shared.hasEarlierAttempt(id) ? .downloading : .resolving
                if let earlier = try await PhoneLinkFetcher.continueDownload(id, progress: report) {
                    file = earlier
                    imp.phase = .downloading
                    if let t = self.store.transcript(id), !t.title.hasPrefix("http") { imp.title = t.title }
                } else {
                    imp.phase = .resolving
                    let resolved = try await PhoneLinkFetcher.resolve(u)
                    r = resolved
                    guard self.stillWanted(id) else { return }
                    imp.title = resolved.title; imp.site = resolved.site; imp.thumbnailURL = imp.thumbnailURL ?? resolved.thumbnail
                    if resolved.uploadDate != nil { Self.noteFetchedHere(id) }
                    self.store.update(id) { x in
                        if let title = resolved.title, !title.isEmpty, x.title == link || x.title.hasPrefix("http") { x.title = title }
                        x.link = LinkInfo(url: resolved.pageURL, site: resolved.site, channel: resolved.channel, uploadDate: resolved.uploadDate)
                        x.stage = "Downloading"
                    }
                    imp.phase = .downloading
                    file = try await PhoneLinkFetcher.download(resolved, id: id, progress: report)
                }
                downloaded = file
                NetworkGate.addBytes(netEvent, ModelFiles.bytes(of: file))
                // A direct link to a video file has no thumbnail of its own: use a frame from it.
                if r?.thumbnail == nil, imp.thumbnailURL == nil, self.store.transcript(id)?.link?.thumbnailFile == nil, let name = await LinkImport.saveFrameThumbnail(from: file, as: id.uuidString) {
                    self.store.update(id) { $0.link?.thumbnailFile = name }
                    imp.thumbnailURL = Paths.thumbs.appendingPathComponent(name)
                }
                imp.progress = 1
                imp.phase = .queued   // the audio is here; it's prepared and queued next
                guard self.stillWanted(id) else { try? FileManager.default.removeItem(at: file); return }
                self.store.setStage(id, "Preparing the audio")
                let prepared = try await MediaImport.prepare(file, into: self.store.newAudioURL(ext: "m4a"))
                guard self.stillWanted(id) else {
                    try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: prepared.url); return
                }
                imp.duration = prepared.duration
                self.store.update(id) { x in
                    x.audioFileName = prepared.url.lastPathComponent; x.duration = prepared.duration; x.stage = "Queued"
                    x.processingDevice = Device.id; x.processingDeviceName = Device.name
                }
                self.coordinator.enqueueExisting(id)
                if let thumb = r?.thumbnail, let name = await PhoneLinkFetcher.saveThumbnail(thumb, as: id.uuidString) {
                    self.store.update(id) { $0.link?.thumbnailFile = name }
                }
                // A downloaded video's stills while it transcribes (none for audio), then the download goes.
                await self.store.addStills(id, from: file)
                try? FileManager.default.removeItem(at: file)
            } catch is CancellationError {
                if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
            } catch LinkFetchError.needsMac {
                self.handLinkToMac(id, imp)
            } catch LinkFetchError.chooseEpisode(let show) {
                // A whole show or feed: no transcript for it; the episode picker adds the one you choose.
                guard self.stillWanted(id) else { return }
                self.cancelLinkCard(id)
                self.closeLinkCard(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.episodeChoice = EpisodeChoice(link: u, show: show) }
            } catch {
                if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
                guard self.stillWanted(id) else { return }
                let message = (error as? URLError).map { e -> String in
                    e.code == .notConnectedToInternet ? "You're offline. Choose Retry when you're connected." : e.localizedDescription
                } ?? error.localizedDescription
                Log.note("link fetch failed: \(error)")
                self.store.update(id) { x in
                    x.status = .failed; x.stage = nil; x.error = "Couldn't fetch that link: \(message)"
                    x.processingDevice = nil; x.processingDeviceName = nil
                }
                imp.phase = .failed(message)
                if self.linkCardImport?.id != id { self.say("Couldn't fetch that link") }
            }
        }
    }

    /// False once the transcript is deleted or cancelled while its link was being fetched, or another device took
    /// the job over (`jobIsMine`).
    private func stillWanted(_ id: UUID) -> Bool {
        guard let t = store.transcript(id) else { return false }
        return t.deletedAt == nil && t.status == .processing && t.jobIsMine() && !Task.isCancelled
    }

    /// A site this iPhone can't fetch: the Mac fetches it when one syncs this library (its yt-dlp helper picks up
    /// `pendingLink`). With no Mac, the transcript stops with a message instead of waiting forever.
    private func handLinkToMac(_ id: UUID, _ imp: LinkImport) {
        guard stillWanted(id) else { return }
        if Cloud.enabled && macSeen {
            store.update(id) { x in
                x.pendingLink = true; x.status = .processing; x.stage = nil
                x.processingDevice = nil; x.processingDeviceName = nil
            }
            imp.phase = .waitingForMac
            say(LinkFetchError.needsMac.localizedDescription)
        } else {
            let message = "Verbose can't download from this site on iPhone."
            store.update(id) { x in
                x.status = .failed; x.stage = nil; x.error = message
                x.processingDevice = nil; x.processingDeviceName = nil
            }
            imp.phase = .failed(message)
            say(message)
        }
    }

    /// Whether a Mac has ever worked on this library (it's the only device that records app audio or names
    /// itself "your Mac"). Remembered once seen.
    var macSeen: Bool {
        let key = "sync.macSeen"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let fetchedHere = Set(UserDefaults.standard.stringArray(forKey: Self.fetchedHereKey) ?? [])
        let seen = store.transcripts.contains { t in
            t.source == .app || (t.processingDevice != Device.id && (t.processingDeviceName ?? "").contains("Mac"))
                || (t.link?.uploadDate != nil && !fetchedHere.contains(t.id.uuidString))
        }
        if seen { UserDefaults.standard.set(true, forKey: key) }
        return seen
    }

    /// Links whose upload date this iPhone read from YouTube itself, so `macSeen` doesn't take that date for the
    /// Mac's yt-dlp.
    private static let fetchedHereKey = "links.fetchedHere"
    private static func noteFetchedHere(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: fetchedHereKey) ?? []
        guard !ids.contains(id.uuidString) else { return }
        ids.append(id.uuidString)
        UserDefaults.standard.set(Array(ids.suffix(2000)), forKey: fetchedHereKey)
    }

    /// Link downloads that stopped when Verbatim closed start again.
    private func resumeLinkFetches() {
        for t in store.live where t.source == .link && t.status == .processing && t.audioFileName == nil
            && !t.pendingLink && t.processingDevice == Device.id {
            startLinkFetch(t.id)
        }
    }

    // MARK: Pipeline (same job as the Mac, in TranscriptionCoordinator)

    private func enqueue(_ t: Transcript) { coordinator.enqueue(t) }

    func retry(_ t: Transcript) {
        // A link whose audio never arrived: fetch it again.
        if t.source == .link, t.audioFileName == nil, t.sourceURL ?? t.link?.url != nil {
            store.update(t.id) { x in
                x.status = .processing; x.error = nil; x.pendingLink = false; x.stage = "Getting the link ready"
                x.processingDevice = Device.id; x.processingDeviceName = Device.name
            }
            startLinkFetch(t.id)
            return
        }
        coordinator.retry(t)
    }

    func cancel(_ id: UUID) {
        if let task = linkTasks.removeValue(forKey: id) {
            task.cancel()
            store.update(id) { x in
                x.status = .failed; x.stage = nil; x.error = "Cancelled. Choose Retry to run it again."
                x.processingDevice = nil; x.processingDeviceName = nil
            }
            linkImports[id]?.phase = .failed("Cancelled")
            return
        }
        coordinator.cancel(id)
    }

    func pump() { coordinator.pump() }

    /// Throws away a continued recording that hasn't been added; the transcript stays as it was.
    func discardPendingAppend(_ id: UUID) { coordinator.discardPendingAppend(id) }

    // MARK: Organizing and notes

    func delete(_ ids: [UUID]) {
        for id in ids { forgetKeyboardCopy(id); linkTasks.removeValue(forKey: id)?.cancel(); coordinator.cancelIfActive(id); store.moveToTrash(id) }
        // Undo puts them straight back, as on the Mac and in Recently Deleted (Store.restore).
        say(ids.count == 1 ? "Moved to Recently Deleted" : "Moved \(ids.count) to Recently Deleted", action: ToastUndo.title) { [weak self] in
            ids.forEach { self?.store.restore($0) }
        }
    }
    func restore(_ id: UUID) { store.restore(id); say("Restored") }
    func purge(_ id: UUID) { forgetKeyboardCopy(id); if let t = store.transcript(id) { store.delete(t) } }

    /// A deleted dictation leaves the keyboard's Recent row and the App Group's last-dictation fields too, so the
    /// keyboard can't show or insert its words again.
    private func forgetKeyboardCopy(_ id: UUID) {
        guard let t = store.transcript(id), t.kind == .dictation else { return }
        KeyboardBridge.forgetDictation(id: id, texts: [t.flow?.pasted, t.flow?.raw, t.document].compactMap { $0 })
    }
    func move(_ id: UUID, to project: UUID?) { store.update(id) { $0.projectId = project } }
    /// Adds Library transcripts to a project (Add from Library, Add to project). One project at a time: a transcript
    /// from another project moves. Saves through the Store, so iCloud carries it to the Mac.
    func addToProject(_ ids: [UUID], _ project: UUID) {
        let plan = ProjectAdd.plan(ids, in: store.transcripts, to: project)
        guard !plan.isEmpty, let name = store.projects.first(where: { $0.id == project })?.name else { return }
        for id in plan.keys { store.update(id) { $0.projectId = project } }
        say(plan.count == 1 ? "Added to \(name)" : "Added \(plan.count) to \(name)")
    }
    func togglePin(_ id: UUID) { store.update(id) { $0.pinned.toggle() } }
    /// Renames a speaker everywhere in the transcript. Any name works (first and last, underscores); blank keeps the old one.
    func renameSpeaker(_ id: UUID, speaker sid: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        store.update(id) { t in if let i = t.speakers.firstIndex(where: { $0.id == sid }) { t.speakers[i].name = clean } }
        SpeakerVoices.remember(transcript: id, speaker: sid, name: clean)
    }
    /// Use on a speaker name suggestion: renames the speaker the way a typed name does and keeps the suggestion,
    /// with its reasons, as used.
    func useSpeakerSuggestion(_ id: UUID, _ s: SpeakerSuggestion) {
        renameSpeaker(id, speaker: s.speakerId, to: s.name)
        store.update(id) { $0.markSpeakerSuggestion(s.id, .accepted) }
        Haptics.play(.smallSave)
    }
    /// Dismiss: the suggestion hides and isn't made again.
    func dismissSpeakerSuggestion(_ id: UUID, _ s: SpeakerSuggestion) {
        store.update(id) { $0.markSpeakerSuggestion(s.id, .dismissed) }
    }
    /// Moves one line to another speaker, or to no speaker.
    func assign(_ id: UUID, segment: UUID, to speaker: String?) {
        store.update(id) { t in if let i = t.segments.firstIndex(where: { $0.id == segment }) { t.segments[i].speaker = speaker } }
    }

    func addNote(_ id: UUID, text: String, at: Double?, segment: UUID?, bookmark: Bool = false) {
        store.addNote(Note(text: text, at: at, segmentId: segment, isBookmark: bookmark), to: id)
        say(bookmark ? "Bookmarked \((at ?? 0).timecode)" : "Note added")
        Haptics.play(.smallSave)
    }
    func deleteNote(_ id: UUID, note: UUID) { store.update(id) { $0.notes.removeAll { $0.id == note } } }

    /// Copies one version with Copy's own defaults (the tab you're on; the Cleaned text from lists), never the export
    /// sheet's options.
    func copyText(_ t: Transcript, _ v: Exporter.CopyVersion = .cleaned, timestamps: Bool = false) {
        UIPasteboard.general.string = Exporter.copyText(t, v, timestamps: timestamps)
        say("Copied the \(v.name)" + (timestamps ? " with timestamps" : ""))
        Haptics.play(.copied)
    }

    /// Writes an export to a temporary file for the share sheet, named "{title}.{ext}".
    func exportFile(_ t: Transcript, as f: ExportFormat, options: ExportOptions = .saved) -> URL? {
        var used = Set<String>()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(ExportNames.unique(t.title, ext: f.ext, used: &used))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Exporter.write(t, as: f, options: options, to: url)
            return url
        } catch { say("Couldn't export: \(error.localizedDescription)"); return nil }
    }

    // MARK: Settings › Sync and storage

    /// Every finished transcript as Markdown and as JSON, plus the Dictionary and projects, in one zip for the
    /// share sheet. Text only: audio stays in iCloud and on the Mac. Nil when there's nothing to export.
    func exportEverything() async -> URL? {
        let items = store.live.filter { $0.status == .ready }
        guard !items.isEmpty else { say("Nothing to export yet."); return nil }
        let options = ExportOptions.saved
        let dictionary = (try? Store.enc.encode(store.dictionary)) ?? Data()
        let projects = (try? Store.enc.encode(store.projects)) ?? Data()
        let stamp = Formats.pattern("yyyy-MM-dd").string(from: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Verbose Export \(stamp).zip")
        let written: Bool = await Task.detached(priority: .userInitiated) {
            var zip = ZipWriter()
            var used = Set<String>()
            for t in items {
                var base = t.title.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                if base.isEmpty { base = "Transcript" }
                var name = base, n = 2
                while used.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
                used.insert(name.lowercased())
                zip.add("Markdown/\(name).md", Data(Exporter.render(t, as: .md, options: options).utf8))
                zip.add("JSON/\(name).json", Data(Exporter.render(t, as: .json, options: options).utf8))
            }
            zip.add("dictionary.json", dictionary)
            zip.add("projects.json", projects)
            return (try? zip.finish().write(to: url, options: .atomic)) != nil
        }.value
        if !written { say("Couldn't export.") }
        return written ? url : nil
    }

    /// Settings › Delete all data: every transcript (Recently Deleted too) with its audio and stills, every
    /// project, the Dictionary, snippets, About me, and the downloaded speech models. Uses the Store's own delete paths, so iCloud removes the files on
    /// every device, then waits until the deletes are on disk.
    func deleteAllData() {
        // Everything goes, so a recording in progress is deleted outright here, not kept in Recently Deleted.
        if recorder.isRecording {
            showRecorder = false; autoPauseReason = nil; continuing = nil; recordingMoments = []
            recordingWords.end()
            recorder.discard()
        }
        session.end(reason: nil)
        session.forgetTakes()
        player.stop()
        for t in PhoneTab.allCases { setPath(t, NavigationPath()) }
        coordinator.cancelAll()   // once, so cancelling one job doesn't start the next queued one
        for task in linkTasks.values { task.cancel() }
        linkTasks = [:]; linkImports = [:]; latestLinkImport = nil
        linkCardImport = nil; linkBadgeHeld = []
        for t in store.transcripts { store.delete(t) }
        store.projects = []
        store.dictionary = []
        store.snippets = []
        // Day plans and brain dump notes, and your own templates, through the store so the deletions sync (security
        // review IPH-16, October 31, 2026).
        store.plans = []
        store.templates = []
        // Ask's index, recent questions, recipes, and digests (Transcription/AskEngine.swift).
        Task { await AskData.eraseAll() }
        UserDefaults.standard.removeObject(forKey: Profile.aboutMeKey)
        UserDefaults.standard.removeObject(forKey: Store.profileNameKey)
        // Voice data: the speakers you named with their voiceprints, the recent voice embeddings, and your own voice
        // profile (IPH-16).
        SpeakerVoices.clear()
        VoiceProfile.reset()
        // Apple Watch recordings waiting to come in, and the ones kept after a failed import (IPH-16).
        try? FileManager.default.removeItem(at: WatchInbox.folder)
        // Also files with no transcript in memory, speech models, and local-only copies (Store.removeAllFiles).
        store.removeAllFiles()
        // What the keyboard and the extensions share through the App Group: the Recent row, the last dictation's
        // words, the Home stats, snippets, shared files and links waiting in the inbox, and finished broadcasts.
        KeyboardBridge.clearDictationData()
        for folder in [VerbatimInbox.inbox, VerbatimInbox.broadcasts].compactMap({ $0 }) {
            for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: f)
            }
        }
        // The diagnostic log (Settings › Send diagnostic log) starts over.
        Log.trimNow()
        try? FileManager.default.removeItem(at: Log.file)
        say("Deleted everything")
    }
}

extension PhoneState: TranscriptionHost {
    func jobSettings() -> TranscriptionSettings {
        let (engineId, model) = engineChoice
        return TranscriptionSettings(engineId: engineId, model: model, wantSpeakers: identifySpeakers, applyDictionary: applyDictionary)
    }

    func prepareNew(_ t: inout Transcript) {}
    func didEnqueue(_ id: UUID) {}

    /// One continued-processing task covers the whole queue; it's requested before each run starts.
    func jobStarted(_ id: UUID) { backgroundWork.keepRunning() }
    func runWillBegin(_ id: UUID) { backgroundWork.begin() }
    func queueDrained() {
        store.flush()   // the last transcript is on disk before iOS may suspend the app
        backgroundWork.end()
        backgroundWork.finish()
    }
    func progress(_ id: UUID, label: String) { backgroundWork.title(label) }
    func progressFraction(_ id: UUID, _ fraction: Double?) { backgroundWork.fraction(fraction) }

    func offerParakeetV3(_ id: UUID, language: String?) {
        // One question at a time; a batch of recordings asks once.
        guard v3Offer == nil else { return }
        v3Offer = ParakeetV3Offer(id: id, language: language)
    }

    /// Download on the offer: transcribes the recording again in its language with Parakeet v3, which downloads
    /// as part of that job (its progress shows on the transcript). When the language was unclear, the job downloads
    /// v3 first and checks the language again with it.
    func acceptV3Offer() {
        guard let offer = v3Offer else { return }
        v3Offer = nil
        player.stop()
        coordinator.rerun(offer.id, language: offer.language, checkWithV3: offer.language == nil)
    }

    /// Transcribe again in…: a language you pick, or nil to let Verbatim check.
    func transcribeAgain(_ id: UUID, language: String?) {
        player.stop()
        coordinator.rerun(id, language: language)
    }

    /// Transcribe again on this iPhone with your engine, keeping the words it replaces (TurboRerun.swift).
    func transcribeAgain(_ id: UUID) {
        guard let t = store.transcript(id), TranscribeAgain.unavailableReason(t) == nil else { return }
        player.stop()
        coordinator.transcribeAgain(id)
    }

    /// Whether a Mac can take Transcribe again with Whisper Turbo: the library syncs and a Mac has worked on it.
    var macCanTranscribe: Bool { Cloud.enabled && macSeen }

    /// Transcribe again with Whisper Turbo: the Mac does it (TurboRerun.swift). The request syncs with the
    /// transcript; the Mac picks it up, and the transcript says "Waiting for your Mac" until then. With no Mac, it
    /// says so instead.
    func requestTurbo(_ id: UUID) {
        guard macCanTranscribe else { say(TurboRerun.needsMac); return }
        guard let t = store.transcript(id), TurboRerun.unavailableReason(t) == nil else { return }
        store.update(id) { x in
            x.rerunRequest = RerunRequest(engine: Transcript.turboEngine, model: Transcript.turboModel, device: Device.id, deviceName: Device.name)
            x.processingDevice = nil; x.processingDeviceName = nil
        }
        say("Waiting for your Mac")
    }

    /// Takes back a request no Mac has picked up yet.
    func cancelTurboRequest(_ id: UUID) {
        guard let t = store.transcript(id), t.rerunRequest != nil, t.status == .ready, t.processingDevice == nil else { return }
        store.update(id) { $0.rerunRequest = nil }
        say("Cancelled")
    }

    /// Swaps the words with the version kept by Transcribe again (Switch to …).
    func switchTranscriptVersion(_ id: UUID) {
        guard store.transcript(id)?.previousVersion != nil else { return }
        player.stop()
        store.update(id) { _ = $0.switchVersion() }
        say("Switched to \(store.transcript(id)?.model ?? "the other words")")
    }

    /// A transcript is ready: "Transcript ready" with Open for the last in a batch, and its celebration on the first
    /// surface on screen (the open transcript, its Library row, or the toast), with the ready haptic and sound timed to
    /// its fill (DESIGN.md §7, Celebrations).
    func transcriptReady(_ id: UUID, corrections: Int, queueEmpty: Bool) {
        let celebration = playReady(id, queueEmpty: queueEmpty, celebrates: true)
        if queueEmpty {
            say("Transcript ready", action: "Open", celebration: celebration?.surface == .toast ? celebration : nil) { [weak self] in self?.open(id) }
        }
    }

    func jobFailed(_ id: UUID, error: Error) {
        say("Transcription failed: \(error.localizedDescription)")
        Haptics.play(.failed)
        Sounds.play(.error)
    }

    func appendReady(_ id: UUID, queueEmpty: Bool) {
        if queueEmpty { say("New recording added") }
        playReady(id, queueEmpty: queueEmpty)
    }

    func appendFailed(_ id: UUID, error: Error) {
        say("Couldn't add the new recording: \(error.localizedDescription)")
        Haptics.play(.failed)
        Sounds.play(.error)
    }

    /// `.success` once per recording, with Verbose in front and the "ready" message showing. A template that runs
    /// after it adds no second one. The transcription done sound with it, for recordings only (not a thought or a
    /// dictation, SoundRules.transcriptDone).
    ///
    /// With `celebrates`, a finished transcript celebrates on the first surface on screen (ReadyCelebration): the open
    /// transcript, its Library row, or the toast. The haptic and sound then wait for its fill, so they land together;
    /// with nothing on screen they play at once. Returns the celebration posted, if any.
    @discardableResult
    private func playReady(_ id: UUID, queueEmpty: Bool, celebrates: Bool = false) -> CelebrationTicket? {
        let front = UIApplication.shared.applicationState == .active
        let first = !readyOnce.played.contains(id)
        let plays = readyOnce.ready(id, foreground: front, queueEmpty: queueEmpty)
        let t = store.transcript(id)
        let moment = SoundRules.transcriptDone(isDictation: t?.isDictation ?? false, isThought: t?.kind == .idea)
        let feedback: (() -> Void)? = plays ? {
            Haptics.play(.transcriptReady)
            if let moment { Sounds.play(moment) }
        } : nil
        let center = CelebrationCenter.shared
        let surface = !celebrates ? nil : ReadyCelebration.surface(
            isDictation: t?.isDictation ?? false, isThought: t?.kind == .idea, first: first, foreground: front,
            transcriptOpen: center.isOpen(id), rowOnScreen: center.rowOnScreen(id), toastShows: queueEmpty, phone: true)
        guard let surface, let t, ReadyCelebration.feedbackWaits(for: surface) else { feedback?(); return nil }
        return center.celebrateReady(id, on: surface, tone: CelebrationTone.of(source: t.source.rawValue), feedback: feedback)
    }

    func notify(_ message: String) { say(message) }
}

// MARK: - The "link added" card

extension PhoneState {
    /// The tile reached the Library tab: the badge counts the link now.
    func linkCardLanded(_ id: UUID) {
        linkBadgeHeld.remove(id)
    }

    /// The card is gone (landed, faded, or cancelled).
    func closeLinkCard(_ id: UUID) {
        if linkCardImport?.id == id { linkCardImport = nil }
        linkBadgeHeld.remove(id)
    }

    /// Cancel on the card: stops the download and removes the transcript it was filling.
    func cancelLinkCard(_ id: UUID) {
        linkTasks.removeValue(forKey: id)?.cancel()
        coordinator.cancelIfActive(id)
        if let t = store.transcript(id) { store.delete(t) }
        linkImports[id] = nil
        linkBadgeHeld.remove(id)
    }

    /// Retry on the card, after a failed download. The fetch starts over with a fresh `LinkImport`; the card
    /// follows it.
    func retryLinkCard(_ id: UUID) {
        guard let t = store.transcript(id) else { return }
        retry(t)
        if let imp = linkImports[id] { linkCardImport = imp }
    }

    /// The Library tab's badge: what's queued or transcribing on this iPhone, plus links still downloading, less
    /// links whose card hasn't landed yet.
    var libraryBadgeCount: Int {
        var ids = Set(queue)
        if let r = runningID { ids.insert(r) }
        for (id, imp) in linkImports where !imp.isFinished { ids.insert(id) }
        return ids.subtracting(linkBadgeHeld).count
    }
}

/// Extra time from iOS so a link download can finish after you leave the app. Ends when the download does,
/// or when iOS needs the time back (the download then starts again the next time Verbatim opens).
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
