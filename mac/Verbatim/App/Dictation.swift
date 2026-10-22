import SwiftUI
import AppKit
import Combine
import AVFoundation
import ApplicationServices
import Carbon
import Carbon.HIToolbox

extension Notification.Name {
    static let verbatimOpenSettings = Notification.Name("verbatimOpenSettings")
}

/// Verbatim Flow: dictate into any app on the Mac.
///
/// Start with the hotkey (hold to talk, tap for hands-free, or both) or by clicking the floating button.
/// Verbatim transcribes on this Mac, cleans the words up for the app you're in (email, chat, code), pastes
/// them where your cursor is, and puts your clipboard back. Every dictation is kept, with its audio, in
/// Dictations, so a missed paste is never a lost thought.
///
/// Needs Accessibility access: to notice the hotkey, to read which app and field you're in (never password
/// fields), and to press ⌘V there. Nothing leaves the Mac.
@MainActor
final class DictationController: ObservableObject {
    enum Hotkey: String, CaseIterable, Identifiable {
        case rightOption, rightCommand, fnGlobe, controlOptionSpace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rightOption: return "Right ⌥ Option"
            case .rightCommand: return "Right ⌘ Command"
            case .fnGlobe: return "🌐 Fn"
            case .controlOptionSpace: return "⌃⌥ Space"
            }
        }
        var shortTitle: String {
            switch self {
            case .rightOption: return "hold right ⌥"
            case .rightCommand: return "hold right ⌘"
            case .fnGlobe: return "hold Fn"
            case .controlOptionSpace: return "hold ⌃⌥ Space"
            }
        }
        var isModifierOnly: Bool { self != .controlOptionSpace }
    }

    @Published private(set) var isListening = false {
        didSet {
            if isListening != oldValue { carbon.setEscape(secureSince != nil && escapeCancels) }
            if isListening != oldValue { AudioDucker.shared.set(.dictation, isListening) }   // Lower other audio while listening.
            // Live words are a preview of listening only; they end the moment listening does.
            if !isListening { liveWords.stop() }
        }
    }
    /// Transcribing and cleaning up (or running an action), until the text is handed to the paster.
    @Published private(set) var isWorking = false {
        didSet { if isWorking != oldValue { carbon.setEscape(secureSince != nil && escapeCancels) } }
    }
    /// Esc cancels while listening, and while a dictation's words are being written.
    private var escapeCancels: Bool { isListening || writingSession != nil }
    @Published private(set) var handsFree = false
    @Published private(set) var targetAppName = ""
    /// The last dictation's final text. Kept (never cleared by a paste, a failed paste, or the thought pad's
    /// Send) so ⌃⌘V (or Copy last dictation in the floating menu) can always bring it back.
    @Published private(set) var lastResult: String? = nil
    /// Whether the target app confirmed it read `lastResult` (the paste receipt arrived).
    @Published private(set) var lastPasteConfirmed = true
    /// Secure Event Input has been on for 3 seconds or more (a password field, Terminal's Secure Keyboard Entry).
    /// Keyed shortcuts stop reaching the event monitors then; modifier-only hotkeys keep working.
    @Published private(set) var secureInputOn = false
    @Published var hotkey: Hotkey = Hotkey(rawValue: UserDefaults.standard.string(forKey: "dictateHotkey") ?? "") ?? .rightOption {
        didSet { UserDefaults.standard.set(hotkey.rawValue, forKey: "dictateHotkey"); if secureSince != nil { carbon.activate(hotkey: hotkey) }; bar?.refresh() }
    }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "dictateEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "dictateEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "dictateEnabled"); refreshMonitors(); warmRecorder(); bar?.refresh() }
    }

    private weak var app: AppState?
    /// Keeps one input unit prepared (mic off) on the chosen mic between dictations, so key-down only starts it.
    private let recorder = Recorder(keepWarm: true)
    /// Live words in the Ribbon while you speak (Settings › Dictation › Show words as you speak). A preview only:
    /// the pasted text still comes from the main engine and cleanup.
    let liveWords = LiveTranscriber()
    private var monitors: [Any] = []
    private(set) var bar: FlowBarController?
    private let learner = AutoLearn()
    private var target: NSRunningApplication?
    private var context: AppContext?
    /// The browser tab's website for the You page, asked for as dictation starts (SiteCapture).
    private var siteProbe: SiteProbe?
    private var command = false
    private var keyDown = false
    /// When the hotkey went down, from the event itself (handling can lag while the mic starts).
    private var pressedTS: TimeInterval?
    private var session = 0
    /// The current dictation stopped itself at the time limit; said in the Ribbon once it's pasted.
    private var stoppedAtLimit = false
    private var startedAt: Date?
    private var lastPressTS: TimeInterval = 0
    private var lastTrusted = false
    private var lastDuration: Double = 0
    /// Whether this dictation goes to the thought pad, decided when it starts (not when the text arrives).
    private var toPad = false
    /// The mic is running its short tail after you let go (`DictationTiming.tail`).
    private var tailing = false
    /// When you let go of the hotkey or clicked stop, for the release-to-paste log line.
    private var releasedAt: Date?
    /// A dictation started while the last one was being written. It starts when that one is handed to the paster.
    private var queuedStart: (handsFree: Bool, command: Bool)?
    /// The session whose words are being written (transcription and cleanup); Esc cancels it.
    private var writingSession: Int?
    /// Sessions cancelled with Esc while being written: kept in Dictations, never pasted.
    private let abandoned = SessionSet()
    /// Pastes handed to the paster that haven't finished.
    private var pastesInFlight = 0
    func showPendingLearn() { learner.showPending() }

    /// Live words, between dictations (the Ribbon went idle) or when the setting is turned on: gets the on-device
    /// recognizer ready, and on systems that use the older recognizer asks for speech recognition permission once.
    /// Never while listening or writing, so a permission dialog can't take focus from the paste.
    func prepareLiveWords() {
        guard LiveWordsSetting.isOn, !isListening, !isWorking, pastesInFlight == 0 else { return }
        liveWords.prepare(allowPermissionPrompt: true)
    }
    var projects: [Project] { app?.store.projects ?? [] }
    private var trustTimer: Timer?
    private var secureTimer: Timer?
    /// When Secure Event Input was first seen on (nil while off).
    private var secureSince: TimeInterval?
    private var secureFlashed = false
    private let carbon = CarbonHotkeys()
    private var wakeObserver: NSObjectProtocol?

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    var liveMeter: LiveMeter { recorder.live }

    func attach(_ app: AppState) {
        self.app = app
        carbon.owner = self
        learner.app = app
        ThoughtPadController.shared.dictation = self
        // Recent dictations (⌥⌘V by default): works in every app, even with dictation off.
        RecallPanelController.shared.dictation = self
        RecallHotkey.shared.onPress = { [weak self] in self?.toggleRecall() }
        RecallHotkey.shared.apply()
        bar = FlowBarController(dictation: self)
        refreshMonitors()
        purgeOldDictations()
        // Turning on Accessibility in System Settings doesn't tell the app. Watch for it, and start listening for
        // the hotkey the moment it's allowed (key monitors added before that never receive anything).
        lastTrusted = accessibilityTrusted
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = self.accessibilityTrusted
                if now != self.lastTrusted {
                    self.lastTrusted = now
                    Log.note("accessibility trusted=\(now)")
                    self.refreshMonitors(); self.bar?.refresh()
                    if now { self.bar?.flash("Ready. \(self.hotkey.shortTitle.prefix(1).uppercased() + self.hotkey.shortTitle.dropFirst()) to dictate.", seconds: 4) }
                }
            }
        }
        // The mic changing mid-dictation ends it gracefully: what was said so far is transcribed and kept.
        recorder.onInterrupted = { [weak self] in self?.inputInterrupted() }
        // No sound at all from the mic shortly after starting: stop instead of listening to nothing.
        recorder.onNoAudio = { [weak self] in self?.noAudio() }
        // A muted mic (or only digital silence) says so right away in the Ribbon, and listening carries on.
        recorder.onMicWarning = { [weak self] w in self?.micWarningChanged(w) }
        warmRecorder()
        // Live words: ask for the on-device speech model now (no permission prompt at launch).
        if LiveWordsSetting.isOn { liveWords.prepare() }
        // Load the speech model and run a tiny transcription now, so the first dictation doesn't wait for it.
        prewarmModel(reason: "launch")
        // Core ML can drop compiled models over sleep; warm again a few seconds after waking.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.prewarmModel(reason: "wake")
            }
        }
    }

    /// A real (tiny) inference on the model dictation uses, so loading and first-run compilation happen now. Then
    /// the Dictionary boost's session, so the first dictation can use it.
    private func prewarmModel(reason: String) {
        guard enabled, let choice = app?.engineChoice, choice.engine == "fluid" else { return }
        let model = choice.model
        Log.note("dictation prewarm \(model) (\(reason))")
        let boost = boostEntries()
        Task.detached(priority: .utility) {
            await FluidEngine.shared.prewarm(model: model)
            if let boost { await FluidEngine.shared.prepareBoost(dictionary: boost.entries, project: boost.project) }
        }
        watchVocabulary()
    }

    /// The active project, when it still exists.
    private var activeProject: UUID? {
        FlowSettings.shared.activeProject.flatMap { p in app?.store.projects.contains(where: { $0.id == p }) == true ? p : nil }
    }

    /// The words the boost listens for: your enabled Dictionary words (everywhere, plus the active project's) and the
    /// built-in vocabulary. Nil when boosting is off.
    private func boostEntries() -> (entries: [DictionaryEntry], project: UUID?)? {
        guard FlowSettings.shared.boostVocabulary else { return nil }
        let project = activeProject
        let dict = (app?.store.dictionary ?? []).filter { $0.projectId == nil || $0.projectId == project }
        return (dict.filter(\.enabled) + BuiltInVocabulary.boostEntries(excluding: dict), project)
    }

    private var vocabularyWatch: AnyCancellable?

    /// Rebuilds the boost's session in the background soon after the Dictionary, the built-in vocabulary, or the
    /// active project changes (the last two live in UserDefaults), so no dictation waits for a rebuild.
    private func watchVocabulary() {
        guard vocabularyWatch == nil, let store = app?.store else { return }
        let defaults = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }
        vocabularyWatch = store.$dictionary.map { _ in () }.merge(with: defaults)
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.enabled, self.app?.engineChoice.engine == "fluid", let boost = self.boostEntries() else { return }
                    Task.detached(priority: .utility) { await FluidEngine.shared.prepareBoost(dictionary: boost.entries, project: boost.project) }
                }
            }
    }

    /// Keeps the recorder's input prepared while dictation is on and the mic is allowed; releases it otherwise.
    private func warmRecorder() {
        // Not on a Bluetooth mic: a prepared input can hold the headset in its low-quality call profile.
        let bluetooth = AudioDevices.current()?.transport == "Bluetooth"
        if enabled && !bluetooth && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { recorder.warmUp() }
        else { recorder.coolDown() }
    }

    /// The input device changed or dropped out while listening.
    private func inputInterrupted() {
        guard isListening else { return }
        Log.note("dictation: input device changed mid-dictation, finishing")
        finish(.interrupted)
        if isWorking { bar?.model.warning = "Mic changed, so listening stopped" }
    }

    /// The recorder's watchdog: no sound at all 2 seconds in (8 when the Ribbon already said the mic seems
    /// muted). Stops, releases the mic, and says which mic.
    private func noAudio() {
        guard isListening else { return }
        Log.note("dictation: no audio from \(AudioDevices.current()?.name ?? "the mic"); stopped")
        let warned = recorder.micWarning
        recorder.discard()
        resetListening()
        showMicProblem("Couldn't hear", warned: warned)
    }

    /// Shows or clears the muted-mic warning in the listening tab, and announces it to VoiceOver.
    private func micWarningChanged(_ w: MicWarning?) {
        guard let m = bar?.model else { return }
        guard isListening, let w else { m.alert = nil; return }
        m.alert = .init(title: w.title, detail: w.detail, strong: w.isFirm)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(w.title). \(w.detail).", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Back to idle after listening ended without a recording to transcribe.
    private func resetListening() {
        isListening = false; handsFree = false; command = false; toPad = false; tailing = false
    }

    /// "Couldn't hear the Shure MV7 mic. Check Settings › General › Microphone.", with a button that opens it.
    /// After a muted-mic warning, it says to unmute instead.
    private func showMicProblem(_ verb: String, warned: MicWarning? = nil) {
        switch warned {
        case .muted(let name):
            bar?.flash("Stopped listening: \(MicWarning.phrase(name)) is muted. Unmute it, then dictate again.", seconds: 8)
            return
        case .silent(let name):
            bar?.flash("Couldn't hear \(MicWarning.phrase(name)). If it has a mute button or switch, unmute it and dictate again.", action: "Settings", seconds: 8) { [weak self] in
                self?.openSettings(tab: .general)
            }
            return
        case .usingBuiltIn, nil: break
        }
        let name = AudioDevices.current()?.name ?? "the microphone"
        let mic = name.range(of: "mic", options: .caseInsensitive) != nil ? name : "the \(name) mic"
        bar?.flash("\(verb) \(mic). Check Settings › General › Microphone.", action: "Open", seconds: 6) { [weak self] in
            self?.openSettings(tab: .general)
        }
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshMonitors() }
    }

    func openAccessibilitySettings() {
        // Asking first puts Verbatim in the Accessibility list, so you only have to switch it on.
        if !accessibilityTrusted {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        Self.openPrivacy("Privacy_Accessibility")
    }

    /// Opens System Settings › Privacy & Security at a section. macOS 13 and later use the new address; the old
    /// one is the fallback.
    static func openPrivacy(_ anchor: String) {
        let addresses = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
                         "x-apple.systempreferences:com.apple.preference.security?\(anchor)"]
        for a in addresses {
            if let u = URL(string: a), NSWorkspace.shared.open(u) { Log.note("opened settings \(anchor)"); return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func refreshMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        updateSecureInputWatch()
        guard enabled, accessibilityTrusted else {
            if enabled { Log.note("dictation hotkey off: Accessibility not allowed") }
            return
        }
        // Global (other apps) and local (our own windows) so it works everywhere.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            // ⌃⌥P and ⌃⌘V are ours; don't also send them to the text field in front (the thought pad's, say).
            if e.type == .keyDown, Self.isOwnShortcut(e) { self?.handle(e); return nil }
            self?.handle(e); return e
        }) { monitors.append(l) }
        Log.note("dictation monitors on, hotkey=\(hotkey.rawValue)")
    }

    // MARK: Secure input

    /// Polls Secure Event Input once a second while dictation is on. While it's on, keyDown events stop
    /// reaching the event monitors (modifier-only hotkeys keep working), so the keyed shortcuts are registered
    /// with Carbon, which secure input doesn't block, until it goes off. A CGEventTap would replace the
    /// NSEvent monitors in `refreshMonitors()` (and swallow the hotkey); this fallback stays either way.
    private func updateSecureInputWatch() {
        if enabled {
            guard secureTimer == nil else { return }
            secureTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSecureInput() }
            }
            secureTimer?.tolerance = 0.2
            checkSecureInput()
        } else {
            secureTimer?.invalidate(); secureTimer = nil
            endSecureInput()
        }
    }

    private func checkSecureInput() {
        guard Self.secureInputEnabled() else { endSecureInput(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if secureSince == nil {
            secureSince = now
            carbon.activate(hotkey: hotkey)
            carbon.setEscape(escapeCancels)
        }
        // A password field gaining focus turns it on for a moment; only a sustained stretch is worth a notice.
        guard !secureInputOn, now - (secureSince ?? now) >= 3 else { return }
        secureInputOn = true
        Log.note("secure input on; Carbon fallback has \(carbon.covered), missing \(carbon.uncovered)")
        bar?.refresh()
        if !hotkey.isModifierOnly, !carbon.coversDictate, !secureFlashed, !isListening, !isWorking {
            secureFlashed = true
            bar?.flash("Secure input is on (a password field or Terminal), so \(hotkey.title) can't be heard. Click here to dictate.", seconds: 6)
        }
    }

    private func endSecureInput() {
        guard secureSince != nil || secureInputOn else { return }
        secureSince = nil
        carbon.deactivate()
        if secureInputOn {
            secureInputOn = false
            secureFlashed = false
            Log.note("secure input off")
            bar?.refresh()
        }
    }

    /// The Ribbon's hint while secure input blocks a keyed shortcut the Carbon fallback couldn't take over.
    var secureInputHint: String? {
        guard secureInputOn else { return nil }
        if !hotkey.isModifierOnly && !carbon.coversDictate { return "secure input on · click to dictate" }
        if !carbon.uncovered.isEmpty { return "secure input on · some shortcuts paused" }
        return nil
    }

    nonisolated private static func secureInputEnabled() -> Bool { truth(IsSecureEventInputEnabled()) }
    // Carbon's Boolean comes into Swift as Bool or DarwinBoolean depending on the SDK; either compiles.
    nonisolated private static func truth(_ b: Bool) -> Bool { b }
    nonisolated private static func truth(_ b: DarwinBoolean) -> Bool { b.boolValue }

    /// A shortcut that arrived through the Carbon fallback (secure input is on).
    fileprivate func carbonHotkey(_ action: CarbonAction, down: Bool) {
        let ts = ProcessInfo.processInfo.systemUptime   // the same clock as NSEvent.timestamp
        switch action {
        case .dictate, .dictateCommand:
            guard hotkey == .controlOptionSpace else { return }
            if down { if !keyDown { pressed(shift: action == .dictateCommand, at: ts) } }
            else if keyDown { released(at: ts) }
        case .pasteLast: if down { pasteLast() }
        case .copyLast: if down { copyLast() }
        case .thoughtPad: if down { ThoughtPadController.shared.toggle() }
        case .escape: if down { if isListening { cancel() } else if writingSession != nil { cancelWriting() } }
        }
    }

    // MARK: Keys

    nonisolated private static func isOwnShortcut(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(e.keyCode) {
        case kVK_ANSI_P: return mods == [.control, .option]
        case kVK_ANSI_V: return mods == [.command, .control]
        default: return false
        }
    }

    private func handle(_ e: NSEvent) {
        // Esc cancels a dictation in progress, or while its words are being written; ⌘⌃V pastes the last one again.
        if e.type == .keyDown {
            if e.keyCode == UInt16(kVK_Escape), isListening { cancel(); return }
            if e.keyCode == UInt16(kVK_Escape), writingSession != nil { cancelWriting(); return }
            // Esc closes the didn't-paste notice (the words stay on the clipboard and in the thought pad).
            if e.keyCode == UInt16(kVK_Escape), rescuing, bar?.model.phase == .prompt { rescuing = false; bar?.dismissPrompt(); return }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == UInt16(kVK_ANSI_V), mods == [.command, .control] { if !e.isARepeat { pasteLast() }; return }
            if e.keyCode == UInt16(kVK_ANSI_P), mods == [.control, .option], !e.isARepeat { ThoughtPadController.shared.toggle(); return }
        }
        switch hotkey {
        case .rightOption: modifier(e, code: 61, flag: .option)          // kVK_RightOption
        case .rightCommand: modifier(e, code: 54, flag: .command)        // kVK_RightCommand
        case .fnGlobe: modifier(e, code: 63, flag: .function)            // kVK_Function
        case .controlOptionSpace:
            if e.keyCode == 49 {                                          // kVK_Space
                let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if e.type == .keyDown, mods.contains([.control, .option]), !e.isARepeat { pressed(shift: mods.contains(.shift), at: e.timestamp) }
                if e.type == .keyUp, keyDown { released(at: e.timestamp) }
            } else if e.type == .keyDown { otherKey(at: e.timestamp) }
        }
    }

    private func modifier(_ e: NSEvent, code: UInt16, flag: NSEvent.ModifierFlags) {
        if e.type == .flagsChanged, e.keyCode == code {
            if e.modifierFlags.contains(flag) { if !keyDown { pressed(shift: e.modifierFlags.contains(.shift), at: e.timestamp) } }
            else if keyDown { released(at: e.timestamp) }
        } else if e.type == .keyDown {
            otherKey(at: e.timestamp)
        }
    }

    /// A letter pressed right after a modifier-only hotkey means a shortcut (⌥E, ⌘C), not dictation.
    private func otherKey(at ts: TimeInterval) {
        guard keyDown, hotkey.isModifierOnly, isListening, !handsFree, let at = pressedTS, ts - at < 1.0 else { return }
        Log.note("dictation: chord detected, cancelled")
        cancel(quiet: true)
    }

    private func pressed(shift: Bool, at ts: TimeInterval) {
        keyDown = true
        pressedTS = ts
        guard ts - lastPressTS > 0.15 else { return }
        lastPressTS = ts
        switch FlowSettings.shared.mode {
        case .hold:
            begin(handsFree: false, command: shift)
        case .toggle:
            if isListening { finish() } else { begin(handsFree: true, command: shift) }
        case .hybrid:
            if isListening && handsFree { finish() } else { begin(handsFree: false, command: shift) }
        }
    }

    private func released(at ts: TimeInterval) {
        keyDown = false
        // Tap to talk hands-free while the last dictation is being written: the queued one starts hands-free.
        if !isListening, queuedStart != nil, FlowSettings.shared.mode == .hybrid, let at = pressedTS, ts - at < 0.5 {
            queuedStart?.handsFree = true
            return
        }
        guard isListening, let at = pressedTS else { return }
        switch FlowSettings.shared.mode {
        case .hold: finish()
        case .toggle: break
        case .hybrid:
            // A quick tap keeps listening hands-free; a hold of half a second or more ends on release.
            if ts - at < 0.5 { handsFree = true; bar?.model.handsFree = true }
            else if !handsFree { finish() }
        }
    }

    // MARK: Floating button

    func barClicked() {
        if isListening { finish() } else if !isWorking { startFromBar(command: false) }
    }

    func startFromBar(command: Bool) {
        guard !isListening else { return }
        guard accessibilityTrusted else {
            bar?.flash("Allow Accessibility to dictate", action: "Open", seconds: 6) { [weak self] in self?.openAccessibilitySettings() }
            return
        }
        begin(handsFree: true, command: command)
    }

    // MARK: Session

    private func begin(handsFree: Bool, command wantCommand: Bool) {
        guard !isListening else { return }
        // Still writing the last one: this one waits, with a sound and a word in the Ribbon, and starts as soon as
        // that text is handed to the paster (`startQueued`). Pastes run one at a time, so nothing lands on top.
        if isWorking { queueStart(handsFree: handsFree, command: wantCommand); return }
        // Ask for the microphone once, the first time; if it's off, say where to turn it on.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                Task { @MainActor in
                    // The key was let go during the permission dialog, so listen hands-free; click or tap to stop.
                    if ok { self?.begin(handsFree: true, command: wantCommand) }
                    else { self?.bar?.flash("Verbose can't hear you: microphone access is off", action: "Open", seconds: 6) { Self.openMicrophoneSettings() } }
                }
            }
            return
        default:
            bar?.flash("Verbose can't hear you: microphone access is off", action: "Open", seconds: 6) { Self.openMicrophoneSettings() }
            return
        }
        target = NSWorkspace.shared.frontmostApplication
        targetAppName = target?.localizedName ?? "the front app"
        siteProbe = SiteCapture.probe(bundleID: target?.bundleIdentifier)
        // The mic starts first: reading the app's text through Accessibility can take a moment, and the
        // first word must not be lost to it.
        let showWords = LiveWordsSetting.isOn
        recorder.liveTap = showWords ? liveWords.tap : nil
        do {
            try recorder.start(to: app?.store.newRecordingURL() ?? Paths.downloads.appendingPathComponent("dictation-\(Int(Date().timeIntervalSince1970)).wav"))
        } catch {
            Log.note("dictation start failed: \(error)")
            showMicProblem("Couldn't start")
            return
        }
        startedAt = Date()
        session += 1
        toPad = !wantCommand && ThoughtPadController.shared.isOpen
        self.handsFree = handsFree
        isListening = true
        if showWords { liveWords.start(format: Recorder.targetFormat) }
        learner.check()   // Learn from any fixes to the last dictation before this one is pasted.
        let s = FlowSettings.shared
        let ctx = AppContext.capture(readText: s.useContext || wantCommand || s.autoLearn)
        context = ctx
        command = wantCommand && !ctx.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ctx.selectionClipped
        if wantCommand && ctx.selectionClipped {
            cancel(quiet: true)
            bar?.flash("That selection is too long to edit here. Select less than about 6,000 characters.", seconds: 4)
            return
        }
        if wantCommand && !command {
            cancel(quiet: true)
            bar?.flash("Select some text first, then edit it by voice")
            return
        }
        Sounds.start()
        if let m = bar?.model {
            m.handsFree = handsFree
            m.command = command
            m.warning = Self.bluetoothWarning()
            m.appLabel = Self.label(for: targetAppName)
        }
        bar?.setPhase(.listening)
        FlowCleanup.prewarm()
        scheduleTimeLimit()
        Log.note("dictation begin -> \(targetAppName) [\(ctx.category.rawValue)] handsFree=\(handsFree) command=\(command)")
    }

    /// Dictation stops itself after `FlowSettings.maxDictationMinutes` (and pastes what it heard), with a
    /// warning in the Ribbon a minute before. In-app recording has no limit. The warning uses the Ribbon's
    /// warning line rather than `flash`, which would replace the listening state.
    private func scheduleTimeLimit() {
        stoppedAtLimit = false
        let minutes = FlowSettings.maxDictationMinutes
        guard minutes > 0 else { return }   // 0: no limit
        let mine = session
        let limit = minutes * 60
        if limit > 60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + limit - 60) { [weak self] in
                guard let self, self.isListening, self.session == mine else { return }
                self.bar?.model.warning = "1 minute left. Dictation stops at \(Self.limitText(minutes))."
                Log.note("dictation: 1 minute left")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self, self.isListening, self.session == mine else { return }
            Log.note("dictation: reached the \(Self.limitText(minutes)) limit; finishing")
            // Like letting go of the key: transcribed and pasted, never discarded.
            self.stoppedAtLimit = true
            self.finish(.timeLimit)
        }
    }

    /// "10 minutes", "1 minute", "30 seconds": the limit as the Ribbon says it.
    static func limitText(_ minutes: Double) -> String {
        if minutes < 1 { let s = max(1, Int((minutes * 60).rounded())); return s == 1 ? "1 second" : "\(s) seconds" }
        let m = Int(minutes.rounded())
        return m == 1 ? "1 minute" : "\(m) minutes"
    }

    /// "MAIL", "SLACK": the app's name as the Ribbon shows it while writing.
    private static func label(for app: String) -> String {
        let short = app.count > 12 ? String(app.prefix(11)) + "…" : app
        return short.uppercased()
    }

    /// AirPods and other Bluetooth mics record in call quality and wake slowly (the first word gets lost).
    private static func bluetoothWarning() -> String {
        guard let d = AudioDevices.current(), d.transport == "Bluetooth" else { return "" }
        return "\(d.name) mic: lower quality. Pick another in Settings."
    }

    /// Stops listening without pasting, at once, even during the tail after you let go. The recording is discarded.
    func cancel(quiet: Bool = false) {
        guard isListening else { return }
        tailing = false
        // The recorder already stopped on its own: still end listening, so the Ribbon never stays stuck.
        guard let stopped = recorder.stop() else { resetListening(); bar?.setPhase(.idle); return }
        isListening = false; handsFree = false; command = false
        try? FileManager.default.removeItem(at: stopped.0)
        if quiet { bar?.setPhase(.idle) } else { Sounds.cancel(); bar?.flash("Cancelled", seconds: 1.5, exact: true) }
    }

    /// Esc while the words are being written: nothing is pasted, and the dictation is kept in Dictations. A
    /// dictation waiting to start is dropped too.
    private func cancelWriting() {
        guard let s = writingSession else { return }
        abandoned.insert(s)
        queuedStart = nil
        writingSession = nil
        isWorking = false
        Sounds.cancel()
        bar?.flash("Cancelled. It's saved in Dictations.", seconds: 2.5, exact: true)
        Log.note("dictation: cancelled while writing; kept in Dictations, not pasted")
    }

    /// The writing phase of `mine` is over (its text went to the paster, the thought pad, or nowhere). A dictation
    /// that was waiting starts now.
    private func endWriting(_ mine: Int) {
        guard writingSession == mine else { return }
        writingSession = nil
        isWorking = false
        startQueued()
    }

    /// Ends an action's working phase (`apply`), then starts a dictation that was waiting.
    private func endAction() {
        isWorking = false
        startQueued()
    }

    private func queueStart(handsFree: Bool, command: Bool) {
        if queuedStart == nil {
            Sounds.queued()
            bar?.model.appLabel = "NEXT UP"
            Log.note("dictation: started while writing the last one; waiting for its paste")
        }
        queuedStart = (handsFree, command)
    }

    private func startQueued() {
        guard let q = queuedStart else { return }
        queuedStart = nil
        // Hold to talk, and the key was let go before the last dictation was handed off: there's nothing to record.
        if !q.handsFree && !keyDown {
            bar?.flash("Your last dictation was still being written, so this one didn't start. Dictate again.", seconds: 4)
            return
        }
        begin(handsFree: q.handsFree, command: q.command)
    }

    /// Letting go keeps the mic on for `DictationTiming.tail` so the last syllable isn't clipped, while the Ribbon
    /// already shows it's writing. A mic change or the time limit stops at once, even mid-tail.
    private func finish(_ stop: DictationTiming.Stop = .release) {
        guard isListening else { return }
        let delay = DictationTiming.tailDelay(for: stop)
        if tailing && delay > 0 { return }
        if !tailing { releasedAt = Date() }
        guard delay > 0 else { tailing = false; finishNow(tail: 0); return }
        tailing = true
        bar?.setPhase(.working)
        let mine = session
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.tailing, self.session == mine, self.isListening else { return }
            self.tailing = false
            self.finishNow(tail: delay)
        }
    }

    private func finishNow(tail: Double) {
        guard isListening else { return }
        let warned = recorder.micWarning
        guard let stopped = recorder.stop() else {
            // The recorder already stopped on its own: end listening anyway, so the Ribbon never stays stuck.
            resetListening(); showMicProblem("Couldn't hear"); return
        }
        let (url, duration, env) = stopped
        let wasHandsFree = handsFree
        isListening = false; handsFree = false
        // A second or more without a single non-silent sample: the mic isn't delivering (shorter is a stray tap).
        if !recorder.lastHeardSignal, Date().timeIntervalSince(startedAt ?? Date()) >= 1 {
            keepNothingHeard(url: url, duration: duration, env: env)   // in Dictations, never pasted
            command = false; toPad = false
            showMicProblem("Couldn't hear", warned: warned)
            return
        }
        guard !DictationTiming.isStrayTap(duration: duration, tail: tail) else {   // too short: discard, like Wispr Flow
            try? FileManager.default.removeItem(at: url); bar?.setPhase(.idle); return
        }
        // Nothing but silence: don't run the models (Whisper in particular invents words in silence).
        // Not after the time limit: a long hands-free dictation can be mostly quiet, and what was said still counts
        // (an empty result is reported, and the audio is kept in Dictations).
        let loud = env.sorted(by: >).prefix(max(1, env.count / 10))
        if !stoppedAtLimit, !env.isEmpty, (loud.reduce(0, +) / Float(loud.count)) < 0.05 {
            keepNothingHeard(url: url, duration: duration, env: env)   // in Dictations, never pasted
            bar?.flash("Didn't hear anything. Check your mic in Settings.", seconds: 3)
            return
        }
        let mine = session
        writingSession = mine
        isWorking = true
        lastDuration = duration
        bar?.setPhase(.working)
        let s = FlowSettings.shared
        let (engineId, model) = app?.engineChoice ?? ("fluid", "v3")
        // Words that apply everywhere, plus the active project's.
        let project = activeProject
        let dict = (app?.store.dictionary ?? []).filter { $0.projectId == nil || $0.projectId == project }
        let released = releasedAt ?? Date()
        let cancelled = abandoned
        let ctx = context
        let site = siteProbe
        let isCommand = command
        let targetName = targetAppName
        let baseCategory = ctx?.category ?? .other
        let styles = Dictionary(uniqueKeysWithValues: AppCategory.allCases.map { ($0, s.style(for: $0)) })
        let level = s.cleanup
        let snippets = s.snippets
        let useContext = s.useContext
        let boost = s.boostVocabulary
        let vocabulary = dict.filter(\.enabled).map(\.preferred)
        let boostDict = dict.filter(\.enabled) + BuiltInVocabulary.boostEntries(excluding: dict)
        let saved = s.actions
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let t0 = Date()
                var heard: EngineResult
                if engineId == "fluid" {
                    // Silence trimming for every dictation; the boost (active project's words first) when on.
                    heard = try await FluidEngine.shared.transcribeDictation(url: url, model: model, dictionary: boost ? boostDict : [], project: project)
                } else {
                    heard = try await Engines.engine(for: engineId).transcribe(url: url, model: model, progress: { _ in })
                }
                // Settings › Only keep my voice in dictation: words from other voices nearby are dropped (VoiceProfile).
                if let mine = await VoiceProfile.filterDictation(url: url, segments: heard.segments) { heard.segments = mine }
                let r = heard
                let transcribeTime = Date().timeIntervalSince(t0)
                let t1 = Date()
                // In a browser, the front tab's host decides first (Gmail is email whatever its tab's title says).
                let host = await SiteHostCache.resolve(site, bundleID: ctx?.bundleID, title: ctx?.windowTitle ?? "")
                let category = ctx.map { AppContext.category(bundleID: $0.bundleID, title: $0.windowTitle, host: host) } ?? baseCategory
                let style = styles[category] ?? .casual
                let original = r.segments
                var segs = r.segments
                let fixes = DictionaryApplier.apply(dict, to: &segs, project: project)
                // Long pauses become sentence breaks (and, hands-free, paragraph breaks) for the rules and the model.
                // Not in Literal, which keeps your words as spoken, or in code apps.
                let pauseHints = !isCommand && level != .literal && category != .code
                let raw = (pauseHints ? PauseBreaks.join(segs.map { ($0.text, $0.start, $0.end) }, handsFree: wasHandsFree)
                                      : segs.map(\.text).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
                var final: String
                var note: String?
                var cleaned = false
                var corrected: SpokenCorrectionNotice?
                var cloudSent: String?   // FlowInfo.cloudCleanup: who the words went to, if anyone
                if isCommand, let selection = ctx?.selection {
                    // Saying a saved action's name ("client email") runs that action.
                    let n = FlowAction.norm(raw)
                    let named = saved.first { a in let an = FlowAction.norm(a.name); return n == an || ["run", "use", "do", "apply"].contains { n == "\($0) \(an)" } }
                    if let edited = await FlowCleanup.apply(instruction: named?.instruction ?? raw, to: selection, kind: named?.kind ?? .rewrite) {
                        final = Self.keepingEdges(of: selection, edited); cleaned = true
                        if let named { note = "“\(named.name)” applied. Press ⌘Z to undo." }
                    }
                    else { final = selection; note = "Couldn't apply “\(named?.name ?? raw)”. Editing by voice needs Apple Intelligence on macOS 26." }
                } else {
                    var request = FlowCleanup.Request(raw: raw, level: level, style: style, category: category, context: ctx,
                                                      vocabulary: vocabulary, useContext: useContext, snippets: snippets)
                    // One budget for the model step, cloud and Apple's model together; past it, the rules' text.
                    let budget = DictationTiming.cleanupBudget(characters: raw.count)
                    request.timeBudget = budget
                    request.pauseHints = pauseHints
                    let req = request
                    let out: FlowCleanup.Result
                    if cancelled.contains(mine) {
                        out = FlowCleanup.Result(text: FlowCleanup.rulesOnly(req), cleaned: false, note: "Cancelled before cleanup")
                    } else if let o = await FluidEngine.race(seconds: budget + DictationTiming.cleanupBackstop, { await FlowCleanup.run(req) }) {
                        out = o
                    } else {
                        // A backstop: FlowCleanup keeps to its budget itself, but the paste never waits past this.
                        Log.note("dictation cleanup: over \(String(format: "%.1f", budget + DictationTiming.cleanupBackstop)) s; pasting the rule-based text")
                        out = FlowCleanup.Result(text: FlowCleanup.rulesOnly(req), cleaned: false, note: "Cleanup took too long; pasted without it")
                    }
                    final = out.text; note = out.note; cleaned = out.cleaned
                    cloudSent = out.cloud
                    corrected = Self.correctionNotice(raw: raw, request: request)   // "Removed “…”" after the paste
                }
                var info = FlowInfo(app: targetName, bundleID: ctx?.bundleID, category: category, style: style, level: isCommand ? "Command" : level.rawValue,
                                    raw: raw, pasted: final, pastedOK: true, instruction: isCommand ? raw : nil, selection: isCommand ? ctx?.selection : nil)
                // Why the rules' text was used, so fallbacks can be counted (History and Activity).
                if !isCommand { info.cleanupNote = note }
                info.cloudCleanup = cloudSent
                let keepNote = note, wasCleaned = cleaned, finalText = final, keptSegs = segs, correction = corrected
                let cleanupTime = Date().timeIntervalSince(t1)
                let timing = DeliveryTiming(released: released, tail: tail, transcribe: transcribeTime, cleanup: cleanupTime, cleaned: wasCleaned, note: note)
                let flowInfo = info
                await MainActor.run {
                    // Cancelled with Esc while writing: kept in Dictations as not pasted, and nothing is pasted.
                    if cancelled.remove(mine) {
                        var kept = flowInfo; kept.pastedOK = false
                        _ = self?.keep(url: url, duration: duration, env: env, original: original, segments: keptSegs, fixes: fixes, result: r, info: kept, cleaned: wasCleaned, project: project)
                        return
                    }
                    let id = self?.keep(url: url, duration: duration, env: env, original: original, segments: keptSegs, fixes: fixes, result: r, info: flowInfo, cleaned: wasCleaned, project: project)
                    if let id, !isCommand, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ActivityLog.shared.add(ActivityLog.event(id: id, date: Date(), info: flowInfo, seconds: duration, fixes: fixes.count, transcribe: transcribeTime, cleanup: cleanupTime))
                        SiteLog.shared.attach(id, site)
                    }
                    self?.deliver(finalText, transcriptID: id, note: isCommand ? keepNote : nil, raw: raw, correction: correction, session: mine, timing: timing)
                }
            } catch {
                Log.note("dictation transcribe failed: \(error)")
                await MainActor.run {
                    self?.keepFailed(url: url, duration: duration, env: env, error: error.localizedDescription)
                    if cancelled.remove(mine) { return }
                    self?.endWriting(mine)
                    if self?.isListening != true { self?.bar?.flash("Dictation failed. It's saved in Dictations.", seconds: 4) }
                }
            }
        }
    }

    /// One dictation's times, from letting go to the paste, for the log.
    private struct DeliveryTiming {
        var released: Date
        var tail: Double
        var transcribe: Double
        var cleanup: Double
        var cleaned: Bool
        var note: String?
    }

    private func keep(url: URL, duration: Double, env: [Float], original: [Segment], segments: [Segment], fixes: [Correction], result: EngineResult, info: FlowInfo, cleaned: Bool, project: UUID? = nil) -> UUID? {
        guard let app else { return nil }
        let name = app.store.adoptRecording(url) ?? url.lastPathComponent
        let titleSource = info.pasted.isEmpty ? segments : [Segment(start: 0, end: duration, text: info.pasted)]
        var t = Transcript(title: Transcript.titleFrom(titleSource) ?? "Dictation", source: .dictation, sourceLabel: "Dictation · \(info.app)", duration: duration, audioFileName: name, model: Engines.displayName(engine: result.engine, model: result.model))
        t.engine = result.engine; t.language = result.language
        t.original = original; t.segments = segments; t.corrections = fixes; t.waveform = env
        t.flow = info
        t.projectId = project
        if cleaned, info.pasted != info.raw { t.document = info.pasted; t.documentLevel = info.level.capitalized }
        app.store.add(t)
        return t.id
    }

    /// A dictation too quiet to transcribe (or with no signal at all): its audio stays in Dictations as
    /// "Nothing heard", with Retry, instead of being deleted. Nothing is pasted.
    private func keepNothingHeard(url: URL, duration: Double, env: [Float]) {
        guard let app else { return }
        let name = app.store.adoptRecording(url) ?? url.lastPathComponent
        var t = Transcript(title: "Nothing heard", source: .dictation, sourceLabel: "Dictation", duration: duration, audioFileName: name, model: "")
        t.waveform = env; t.status = .failed
        t.error = "Nothing heard. Choose Retry to transcribe it anyway."
        app.store.add(t)
        Log.note("dictation: nothing heard; kept in Dictations (\(String(format: "%.1f", duration)) s)")
    }

    private func keepFailed(url: URL, duration: Double, env: [Float], error: String) {
        guard let app else { return }
        let name = app.store.adoptRecording(url) ?? url.lastPathComponent
        var t = Transcript(title: "Dictation", source: .dictation, sourceLabel: "Dictation", duration: duration, audioFileName: name, model: "")
        t.waveform = env; t.status = .failed; t.error = error
        app.store.add(t)
    }

    private func deliver(_ text: String, transcriptID: UUID?, note: String?, raw: String = "", correction: SpokenCorrectionNotice? = nil,
                         session mine: Int, timing: DeliveryTiming) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            mistake(raw: raw, transcriptID: transcriptID)
            endWriting(mine)
            return
        }
        lastResult = text
        let ctx = context, tgt = target
        let wasCommand = command
        let duration = lastDuration
        let atLimit = stoppedAtLimit
        command = false
        // With the thought pad open, a dictation becomes a piece of the pad instead of a paste.
        if !wasCommand, toPad {
            toPad = false
            ThoughtPad.shared.add(text, seconds: duration)
            if !ThoughtPadController.shared.isOpen { ThoughtPadController.shared.open() }   // closed meanwhile: show where it went
            Sounds.done()
            bar?.flash("Added to the thought pad", seconds: 1.8)
            if let id = transcriptID { app?.store.update(id) { $0.flow?.app = "Thought pad" } }
            endWriting(mine)
            return
        }
        toPad = false
        // Never into a password field: the field focused now decides, or the one focused when dictation started.
        let secureNow = tgt.flatMap { AppContext.focusedSecure(pid: $0.processIdentifier) }
        if DictationTiming.blocksPaste(secureAtStart: ctx?.secureField ?? false, secureNow: secureNow) {
            Paster.copy(text)
            lastPasteConfirmed = false
            if let id = transcriptID { app?.store.update(id) { $0.flow?.pastedOK = false } }
            stoppedAtLimit = false
            Sounds.done()
            bar?.flash(DictationTiming.securePasteNotice, seconds: 4)
            Log.note("dictation: a password field has focus; copied, not pasted")
            endWriting(mine)
            return
        }
        // The pad may hold keyboard focus; hand it back to the app the text is for, or ⌘V lands in the pad.
        ThoughtPadController.shared.yieldKeyboard(to: tgt)
        let spaced = (ctx?.selection.isEmpty ?? true) && !wasCommand && needsLeadingSpace(ctx) ? " " + text : text
        lastPasteConfirmed = false
        let appName = tgt?.localizedName ?? targetAppName
        // Hand-off: the text goes to the paster, and a new dictation may start now. Pastes run one at a time
        // (Paster's chain), so the next dictation's paste and clipboard restore wait for this one's.
        pastesInFlight += 1
        endWriting(mine)
        Task { @MainActor in
            let pasteStarted = Date()
            // A paste that doesn't land leaves the words on the clipboard (unless you copied something else
            // meanwhile) and, for a dictation, in the thought pad too. With Also copy each dictation to the
            // clipboard on, a paste that lands leaves them on the clipboard as well.
            let outcome = await Paster.paste(spaced + (wasCommand ? "" : trailingSpace(text)), into: tgt, focusedField: ctx?.hasFocusedField ?? true,
                                             onFailure: .leaveOnClipboard, keepOnClipboard: !wasCommand && AlwaysCopy.isOn)
            pastesInFlight -= 1
            let now = Date()
            Log.note(DictationTiming.timingLine(total: now.timeIntervalSince(timing.released), tail: timing.tail, transcribe: timing.transcribe,
                                                cleanup: timing.cleanup, paste: now.timeIntervalSince(pasteStarted), cleaned: timing.cleaned, note: timing.note))
            // A newer dictation is listening or being written: its Ribbon and sounds win. This one's text still
            // lands in Dictations, and in the thought pad when the paste missed.
            let current = session == mine && !isListening && !isWorking
            if current { Sounds.done(); stoppedAtLimit = false }
            if let rescue = Recall.rescue(for: outcome, command: wasCommand) {
                // No text field, or the app never read the paste: the Ribbon holds the words with Copy and Paste again.
                ThoughtPad.shared.add(text, seconds: duration, missed: true)
                if let id = transcriptID { app?.store.update(id) { $0.flow?.pastedOK = false } }
                if current { offerRescue(text, title: Recall.rescueTitle(rescue, app: appName, onClipboard: Paster.leftTextOnClipboard)) }
                Log.note("dictation not pasted (\(rescue)); kept in the \(current ? "Ribbon" : "thought pad"), clipboard=\(Paster.leftTextOnClipboard)")
                return
            }
            switch outcome {
            case .pasted:
                lastPasteConfirmed = true
                guard current else { return }
                if let note { bar?.flash(note, seconds: 4) }
                else if let correction { showCorrectionNotice(correction) }
                else if atLimit { bar?.flash("Stopped at \(Self.limitText(FlowSettings.maxDictationMinutes))", seconds: 2) }
                else { bar?.setPhase(.idle) }
                if !wasCommand { learner.watch(element: ctx?.element, cursor: ctx?.cursor, pasted: spaced.trimmingCharacters(in: .whitespaces), appName: ctx?.appName ?? "") }
                // Settings › Dictation › After pasting: Return or ⌘Return to send (Flow/AutoSend.swift).
                if !wasCommand { await AutoSend.afterPaste(target: tgt, category: ctx?.category, secureAtStart: ctx?.secureField ?? false) }
            case .copiedOnly:
                // Nowhere to paste: it's on the clipboard, and kept in the thought pad too.
                if !wasCommand { ThoughtPad.shared.add(text, seconds: duration, missed: true) }
                if current { bar?.flash(wasCommand ? "Copied. Click a text field and press ⌘V." : "Copied, and saved to the thought pad.", seconds: 5) }
                if let id = transcriptID { app?.store.update(id) { $0.flow?.pastedOK = false } }
            case .failed(let why):
                if let id = transcriptID { app?.store.update(id) { $0.flow?.pastedOK = false } }
                if !wasCommand { ThoughtPad.shared.add(text, seconds: duration, missed: true) }
                guard current else { return }
                if wasCommand {
                    if why == .notTrusted {
                        bar?.flash("Allow Accessibility to edit by voice. The result is on your clipboard.", action: "Open", seconds: 6) { [weak self] in self?.openAccessibilitySettings() }
                    } else {
                        bar?.flash("Couldn't confirm the edit. The result is on your clipboard.", seconds: 5)
                    }
                } else {
                    switch why {
                    case .notTrusted:
                        bar?.flash("Saved to the thought pad. Allow Accessibility to paste.", action: "Open", seconds: 6) { [weak self] in self?.openAccessibilitySettings() }
                    case .notRead:
                        bar?.flash("\(appName) didn't take the paste. Saved to the thought pad; ⌃⌘V tries again.", seconds: 5)
                    case .typingInterrupted:
                        bar?.flash("Typing stopped part way. The full text is in the thought pad.", seconds: 5)
                    }
                }
            }
        }
        Log.note("dictation delivered \(text.count) chars")
    }

    /// "Started by mistake?": nothing usable came out (only filler words, or nothing transcribed).
    /// Discard removes it from Dictations; Paste anyway pastes what was heard; doing nothing keeps it in
    /// Dictations, marked as not pasted.
    private func mistake(raw: String, transcriptID: UUID?) {
        command = false
        if let id = transcriptID { app?.store.update(id) { $0.flow?.pastedOK = false } }
        let heard = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = context, tgt = target
        bar?.ask(.init(
            title: "Started by mistake?",
            body: heard.isEmpty ? "No words were heard, so nothing was pasted." : "Only ",
            quote: heard.isEmpty ? nil : String(heard.prefix(60)) + (heard.count > 60 ? "…" : ""),
            after: heard.isEmpty ? "" : " was heard, so nothing was pasted.",
            primary: heard.isEmpty ? nil : "Paste anyway",
            secondary: "Discard",
            seconds: 7,
            onPrimary: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.lastResult = heard
                    self.lastPasteConfirmed = false
                    let out = await Paster.paste(heard, into: tgt, focusedField: ctx?.hasFocusedField ?? true)
                    self.lastPasteConfirmed = out == .pasted
                    self.explainUnpasted(out)
                    if let id = transcriptID { self.app?.store.update(id) { $0.flow?.pasted = heard; $0.flow?.pastedOK = out == .pasted } }
                }
            },
            onSecondary: { [weak self] in
                if let id = transcriptID { self?.app?.store.moveToTrash(id) }
            }
        ))
    }

    static func openMicrophoneSettings() { openPrivacy("Privacy_Microphone") }

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's openSettings is the reliable route on macOS 14+; ContentView listens for this.
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NotificationCenter.default.post(name: .verbatimOpenSettings, object: nil)
            return
        }
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// Adds a space before the text when the cursor sits right after a word.
    private func needsLeadingSpace(_ ctx: AppContext?) -> Bool {
        guard let last = ctx?.before.last else { return false }
        return !last.isWhitespace && !"([{\"“‘/-".contains(last)
    }

    /// A space after a finished sentence, so the next dictation can follow straight on.
    private func trailingSpace(_ text: String) -> String {
        guard let last = text.last, !text.contains("\n") else { return "" }
        return ".!?:;,".contains(last) ? " " : ""
    }

    // MARK: Saved actions on a selection

    /// Runs a saved action on the text selected in the app you're using, and puts the result in its place.
    /// The app's own Undo (⌘Z) brings the original back.
    func apply(_ action: FlowAction) {
        guard !isListening, !isWorking else { return }
        guard accessibilityTrusted else {
            bar?.flash("Allow Accessibility to use actions", action: "Open", seconds: 6) { [weak self] in self?.openAccessibilitySettings() }
            return
        }
        let ctx = AppContext.capture(readText: true)
        let selection = ctx.selection
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            bar?.flash("Select some text first, then pick “\(action.name)”", seconds: 3)
            return
        }
        guard !ctx.selectionClipped else {
            bar?.flash("That selection is too long to replace here. Copy it into a transcript, or select less.", seconds: 4)
            return
        }
        let tgt = NSWorkspace.shared.frontmostApplication
        isWorking = true
        bar?.model.appLabel = Self.label(for: action.name)
        bar?.setPhase(.working)
        Task { @MainActor in
            guard let out = await FlowCleanup.apply(instruction: action.instruction, to: selection, kind: action.kind) else {
                bar?.flash(FlowCleanup.available ? "Couldn't run “\(action.name)”. Try a shorter selection." : "Actions need Apple Intelligence on macOS 26.", seconds: 4)
                endAction()
                return
            }
            let result = Self.keepingEdges(of: selection, out)
            // A long action can take a while: if you clicked elsewhere or changed the selection meanwhile,
            // don't replace whatever is selected now. Copy the result instead.
            let now = AppContext.capture(readText: true)
            let same = NSWorkspace.shared.frontmostApplication?.processIdentifier == tgt?.processIdentifier && now.selection == selection
            let outcome: Paster.Outcome
            if same { outcome = await Paster.paste(result, into: tgt, focusedField: ctx.hasFocusedField) }
            else { Paster.copy(result); outcome = .copiedOnly }
            lastResult = result
            Sounds.done()
            bar?.flash(outcome == .pasted ? "“\(action.name)” applied. Press ⌘Z to undo."
                       : same ? "Copied. Click a text field and press ⌘V." : "The selection changed, so the result is on your clipboard.", seconds: 4)
            endAction()
            Log.note("action \(action.name) applied, \(out.count) chars")
        }
    }

    /// Puts the selection's leading and trailing spaces and line breaks back around a result, so replacing a
    /// paragraph doesn't join it to the next one.
    nonisolated static func keepingEdges(of original: String, _ result: String) -> String {
        let lead = original.prefix { $0.isWhitespace }, trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        guard lead.count < original.count else { return result }
        return String(lead) + result.trimmingCharacters(in: .whitespacesAndNewlines) + trail
    }

    // MARK: History actions

    /// Puts the last dictation back on the clipboard (for a paste that went to the wrong place).
    func copyLast() {
        guard let last = lastResult ?? app?.store.live.first(where: { $0.source == .dictation })?.flow?.pasted, !last.isEmpty else { return }
        Paster.copy(last)
        app?.toast = Toast("Last dictation copied")
        bar?.flash("Last dictation copied", seconds: 1.8)
    }

    /// Pastes the last dictation again where the cursor is now (⌘⌃V).
    func pasteLast() {
        guard let last = lastResult ?? app?.store.live.first(where: { $0.source == .dictation })?.flow?.pasted, !last.isEmpty else { return }
        pasteText(last)
    }

    /// Pastes text where the cursor is now, in the app in front (Paste last dictation, Recent dictations, Paste again).
    func pasteText(_ text: String) {
        let ctx = AppContext.capture(readText: false)
        Task { @MainActor in
            let out = await Paster.paste(text, into: NSWorkspace.shared.frontmostApplication, focusedField: ctx.hasFocusedField)
            if out == .pasted { lastPasteConfirmed = true }
            explainUnpasted(out)
        }
    }

    // MARK: Recent dictations and missed pastes

    /// True while the Ribbon holds a dictation that didn't land (Esc closes it).
    private var rescuing = false

    /// Dictations for Recent dictations, newest first.
    func recallItems() -> [RecallItem] { Recall.items(from: app?.store.live ?? [], sites: SiteLog.shared.hosts) }

    func toggleRecall() { RecallPanelController.shared.toggle() }

    /// Copies text on purpose (the notice's Copy), and says so by the pointer.
    func copyText(_ text: String) {
        Paster.copy(text)
        RecallHUD.shared.show("Copied", near: NSEvent.mouseLocation)
    }

    /// A dictation that didn't land stays in the Ribbon for 12 seconds: what it says, Copy, and Paste again (after
    /// you click the text field you meant). Esc or the X closes it; it stays in Dictations and the thought pad.
    private func offerRescue(_ text: String, title: String) {
        rescuing = true
        bar?.ask(.init(title: title, body: "", quote: Recall.truncate(text, to: 110), after: "",
                       primary: "Paste again", secondary: "Copy", seconds: 12,
                       onPrimary: { [weak self] in self?.rescuing = false; self?.pasteText(text) },
                       onSecondary: { [weak self] in self?.rescuing = false; self?.copyText(text) },
                       onTimeout: { [weak self] in self?.rescuing = false }))
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(title) Click a text field, then choose Paste again.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The didn't-paste notice with sample words, for screenshots.
    func previewRescue() {
        offerRescue("Hi Jonathan, I think we should meet on Friday morning to go over the catalog.",
                    title: Recall.rescueTitle(.noField, app: "Finder", onClipboard: true))
    }

    /// Says why text wasn't pasted. Each of these leaves it on the clipboard.
    private func explainUnpasted(_ out: Paster.Outcome) {
        switch out {
        case .pasted: break
        case .failed(.notTrusted):
            bar?.flash("Allow Accessibility to paste. It's on your clipboard.", action: "Open", seconds: 6) { [weak self] in self?.openAccessibilitySettings() }
        default:
            bar?.flash("Copied. Click a text field and press ⌘V.", seconds: 5)
        }
    }

    func openHistory() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        app?.go(.dictations)
    }

    /// Re-runs cleanup on a kept dictation at another level, and returns the new text (History's Redo).
    func reclean(_ id: UUID, level: CleanupLevel) async -> String? {
        guard let t = app?.store.transcript(id), let info = t.flow else { return nil }
        let raw = info.raw.isEmpty ? t.text : info.raw
        let out = await FlowCleanup.run(.init(raw: raw, level: level, style: info.style, category: info.category, context: nil,
                                          vocabulary: app?.store.dictionary.filter(\.enabled).map(\.preferred) ?? [], useContext: false, snippets: FlowSettings.shared.snippets))
        app?.store.update(id) { x in
            x.flow?.pasted = out.text; x.flow?.level = level.rawValue
            if let sent = out.cloud { x.flow?.cloudCleanup = sent }
            x.document = out.text == raw ? nil : out.text
        }
        return out.text
    }

    /// Moves dictations older than the retention setting to Recently Deleted.
    func purgeOldDictations() {
        let days = FlowSettings.shared.keepDays
        guard days > 0, let app else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = app.store.live.filter { $0.source == .dictation && $0.createdAt < cutoff && !$0.pinned }.map(\.id)
        // Straight to Recently Deleted, quietly: this runs at launch, when a toast would only confuse.
        for id in old { app.store.moveToTrash(id) }
        if !old.isEmpty { Log.note("dictation retention: moved \(old.count) to Recently Deleted") }
    }

    /// Shows the listening button without recording, for screenshots.
    func previewPill(seconds: Double) {
        targetAppName = "Mail"
        bar?.model.handsFree = true
        bar?.setPhase(.listening)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.bar?.setPhase(.idle) }
    }
}

/// Dictation session numbers, shared by the main actor and the background work that writes each dictation.
private final class SessionSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []
    func insert(_ id: Int) { lock.lock(); ids.insert(id); lock.unlock() }
    func contains(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    /// Removes it, and says whether it was there.
    func remove(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.remove(id) != nil }
}

// MARK: - Carbon fallback for keyed shortcuts

fileprivate enum CarbonAction: UInt32, CaseIterable {
    case dictate = 1, dictateCommand, pasteLast, copyLast, thoughtPad, escape
}

private let carbonSignature: OSType = 0x5642_5448   // "VBTH"

/// Carbon calls this on the main thread for a registered hotkey's press and release.
private func carbonHotkeyHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let data else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard err == noErr, id.signature == carbonSignature, let action = CarbonAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
    let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let hotkeys = Unmanaged<CarbonHotkeys>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { hotkeys.fire(action, down: down) }
    return noErr
}

/// Keyed shortcuts registered with `RegisterEventHotKey` while Secure Event Input is on (Handy's approach):
/// Carbon hotkeys keep arriving when keyDown events stop reaching the event monitors. They're registered only
/// while secure input is on, because a Carbon hotkey takes the keystroke from every app. Esc is registered
/// only while listening. The user's chosen hotkey is never changed.
@MainActor
final class CarbonHotkeys {
    weak var owner: DictationController?
    private var refs: [CarbonAction: EventHotKeyRef] = [:]
    private var failed: Set<CarbonAction> = []
    private var handler: EventHandlerRef?

    var covered: [String] { refs.keys.map { "\($0)" }.sorted() }
    var uncovered: [String] { failed.map { "\($0)" }.sorted() }
    var coversDictate: Bool { refs[.dictate] != nil }

    func activate(hotkey: DictationController.Hotkey) {
        guard installHandler() else { return }
        var want: [CarbonAction] = [.pasteLast, .thoughtPad]
        if hotkey == .controlOptionSpace { want += [.dictate, .dictateCommand] }
        if refs[.escape] != nil { want.append(.escape) }
        for a in CarbonAction.allCases where !want.contains(a) { unregister(a) }
        for a in want { register(a) }
    }

    /// Esc cancels a dictation; registered only while listening (and secure input is on).
    func setEscape(_ on: Bool) {
        if on { if installHandler() { register(.escape) } } else { unregister(.escape) }
    }

    func deactivate() {
        for a in CarbonAction.allCases { unregister(a) }
        failed = []
    }

    private func register(_ a: CarbonAction) {
        guard refs[a] == nil else { return }
        let binding = Self.binding(a)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(binding.key), UInt32(binding.mods), EventHotKeyID(signature: carbonSignature, id: a.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[a] = ref
            failed.remove(a)
        } else {
            failed.insert(a)
            Log.note("carbon hotkey \(a) not registered (\(status))")
        }
    }

    private func unregister(_ a: CarbonAction) {
        failed.remove(a)
        if let r = refs.removeValue(forKey: a) { UnregisterEventHotKey(r) }
    }

    private static func binding(_ a: CarbonAction) -> (key: Int, mods: Int) {
        switch a {
        case .dictate: return (kVK_Space, controlKey | optionKey)
        case .dictateCommand: return (kVK_Space, controlKey | optionKey | shiftKey)
        case .pasteLast: return (kVK_ANSI_V, cmdKey | controlKey)
        case .copyLast: return (kVK_ANSI_C, controlKey | optionKey)
        case .thoughtPad: return (kVK_ANSI_P, controlKey | optionKey)
        case .escape: return (kVK_Escape, 0)
        }
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let count = types.count
        let status = InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyHandler, count, &types,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            Log.note("carbon hotkey handler not installed (\(status))")
            handler = nil
            return false
        }
        return true
    }

    fileprivate func fire(_ a: CarbonAction, down: Bool) { owner?.carbonHotkey(a, down: down) }
}

/// Settings › Dictate rows: the shortcuts that work alongside the dictation hotkey, and secure input's state.
struct DictationHotkeyRows: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        LabeledContent("Paste last dictation") { Text("⌃⌘V").font(.system(size: 13, design: .monospaced)) }
        LabeledContent("Copy last dictation") { Text("Floating button menu").font(.system(size: 12)).foregroundStyle(Ink.mute) }
        LabeledContent("Thought pad") { Text("⌃⌥P").font(.system(size: 13, design: .monospaced)) }
        if dictation.secureInputOn {
            Text(dictation.hotkey.isModifierOnly
                 ? "Secure input is on (a password field, or Terminal's Secure Keyboard Entry). Your hotkey still works, and Verbose listens for the other shortcuts another way until it's off."
                 : "Secure input is on (a password field, or Terminal's Secure Keyboard Entry). Verbose listens for \(dictation.hotkey.title) another way until it's off. If it doesn't respond, click the floating button, or pick a modifier hotkey like right ⌥.")
                .font(.system(size: 12)).foregroundStyle(Ink.accentText)
        }
    }
}
