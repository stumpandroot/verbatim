import AppKit
import SwiftUI
import Combine

/// Meeting capture's front door. It notices calls (`MeetingDetector`: another app started using the microphone)
/// and asks with a banner; it never records on its own. Every start, from the banner, File › Record As › Meeting…, or
/// the Record panel's menu on Home, goes through the consent sheet (first time for each app and every start
/// after; "Don't ask again" only after five recordings with that app). While recording, it shows the menu bar item
/// and the notes for a silent meeting app or a Mac that slept. The decisions themselves (which app, when to ask,
/// one prompt per call, consent counts) are pure and tested in Audio/MeetingDetect.swift.
@MainActor
final class MeetingCoordinator: ObservableObject {
    static let shared = MeetingCoordinator()

    static let noticeKey = "meetings.noticeCalls"
    static let copyNoticeKey = "meetings.copyNotice"
    static let bookKey = "meetings.apps"
    /// Settings › Meetings › Notice calls and ask to record. On by default.
    static var noticeCalls: Bool { UserDefaults.standard.object(forKey: noticeKey) as? Bool ?? true }
    /// Settings › Meetings › Copy the chat notice when recording starts: the consent sheet's checkbox starts this
    /// way, and a start without the sheet follows it. On by default.
    static var copyNoticeOnStart: Bool { UserDefaults.standard.object(forKey: copyNoticeKey) as? Bool ?? true }

    @Published private(set) var book: MeetingAppBook

    let banner = MeetingBannerController()
    let consent = MeetingConsentController()
    let status = MeetingStatusController()
    private let detector = MeetingDetector()
    private var tracker = MeetingCallTracker()
    private weak var app: AppState?
    private var poll: Timer?
    private var bag = Set<AnyCancellable>()
    private var defaultsObserver: NSObjectProtocol?
    /// The app the call banner is asking about.
    private var promptApp: MeetingAppInfo?
    /// A start waiting for the session to record, so the recording counts toward "Don't ask again".
    private var pendingCount: (key: String, name: String)?
    private var lastKeys: Set<String> = []

    private init() {
        book = MeetingAppBook.decode(UserDefaults.standard.data(forKey: Self.bookKey))
    }

    func attach(_ app: AppState) {
        guard self.app == nil else { return }
        self.app = app
        let session = MeetingSession.shared
        session.onNotice = { [weak self] m in self?.banner.show(.notice(m)) }
        banner.onAction = { [weak self] a in self?.handle(a) }
        status.copyNotice = { [weak self] in self?.copyChatNotice() }
        session.$phase.removeDuplicates().sink { [weak self] p in self?.phaseChanged(p) }.store(in: &bag)
        session.$remoteSilent.removeDuplicates().sink { [weak self] on in self?.remoteSilentChanged(on) }.store(in: &bag)
        session.$slept.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            if on { self.banner.show(.slept) } else { self.banner.hide { $0 == .slept } }
        }.store(in: &bag)
        detector.onChange = { [weak self] in self?.evaluate() }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        preferencesChanged()
    }

    // MARK: Noticing calls

    /// Starts or stops watching the microphone when the setting changes. The self-test never watches (it shows a
    /// pretend prompt instead).
    private func preferencesChanged() {
        let want = Self.noticeCalls && !UITest.enabled && !Bench.isRequested
        if want, !detector.isRunning {
            detector.start()
            evaluate()
        } else if !want, detector.isRunning {
            detector.stop()
            tracker = MeetingCallTracker()
            stopPolling()
            banner.hide { $0.isCall }
        }
    }

    /// Who's using the microphone now, through the call tracker. Runs on every Core Audio change, and once a
    /// second while anything is going on (the 2-second wait and the end-of-call grace need a clock).
    private func evaluate() {
        guard detector.isRunning else { return }
        let snap = detector.snapshot()
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        let runningSet = Set(running)
        var keys = Set<String>()
        if let users = snap.users {
            for id in users { if let a = MeetingApps.resolve(id, running: runningSet) { keys.insert(a.key) } }
        } else if snap.deviceRunning, !verboseUsesMic {
            // Before macOS 14.4: the mic is in use, but not by whom.
            if let a = MeetingApps.guess(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, running: running) { keys.insert(a.key) }
        }
        if keys != lastKeys {
            Log.note("meeting detector: microphone in use by \(keys.isEmpty ? "no meeting app" : keys.sorted().joined(separator: ", "))")
            lastKeys = keys
        }
        let session = MeetingSession.shared
        let context = MeetingCallTracker.Context(enabled: Self.noticeCalls, busy: isBusy, recordingMeeting: session.isActive, muted: book.muted)
        for event in tracker.update(using: keys, now: ProcessInfo.processInfo.systemUptime, context: context) {
            switch event {
            case .prompt(let key):
                if let info = MeetingApps.info(key: key) { prompt(info) }
            case .ended(let key):
                if promptApp?.key == key, banner.kind?.isCall == true {
                    Log.note("meeting: the call in \(promptApp?.name ?? key) ended; prompt hidden")
                    banner.hide()
                }
            }
        }
        if !tracker.isIdle || snap.deviceRunning || !keys.isEmpty { startPolling() } else { stopPolling() }
    }

    /// Verbose itself is recording, capturing, dictating, showing captions, or asking for consent: wait.
    private var isBusy: Bool {
        guard let app else { return true }
        return app.recorder.isRecording || app.capture.isCapturing || app.dictation.isListening || LiveCaptions.shared.isOpen || consent.isShowing
    }

    /// Verbose's own use of the microphone (only matters before macOS 14.4, where the device can't say who).
    private var verboseUsesMic: Bool { isBusy || MeetingSession.shared.isActive }

    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
    }

    private func stopPolling() { poll?.invalidate(); poll = nil }

    private func prompt(_ info: MeetingAppInfo) {
        book.noticed(info.key, name: info.name, at: Date())
        saveBook()
        promptApp = info
        Log.note("meeting: \(info.name) is using the microphone; asking whether to record")
        banner.show(.call(app: info.name))
    }

    // MARK: Banner actions

    private func handle(_ action: MeetingBannerAction) {
        switch action {
        case .notNow:
            Log.note("meeting: Not now for \(promptApp?.name ?? "the call")")
            banner.hide()
        case .record:
            banner.hide()
            guard let info = promptApp else { return }
            requestRecording(app: info, target: MeetingSession.target(for: info), speaker: info.name)
        case .openSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        case .keepMicOnly:
            banner.hide()
            MeetingSession.shared.keepMicOnly()
        case .resume:
            banner.hide()
            MeetingSession.shared.resumeAfterSleep()
        case .stopAndSave:
            banner.hide()
            MeetingSession.shared.dismissSleepNote()
            MeetingSession.shared.stop()
        case .dismiss:
            banner.hide()
        }
    }

    // MARK: Starting

    /// File › Record As › Meeting… and the Record panel's menu: the frontmost (or first running) meeting app, else all
    /// system audio; then the consent sheet.
    func recordFromMenu() {
        guard !MeetingSession.shared.isActive else { return }
        let choice = MeetingSession.chooseTarget()
        requestRecording(app: choice.app, target: choice.target, speaker: choice.speaker)
    }

    /// Stop from the File menu.
    func stopFromMenu() { MeetingSession.shared.stop() }

    /// The consent sheet, unless you turned it off for this app after five recordings.
    private func requestRecording(app info: MeetingAppInfo?, target: MeetingAudioTarget, speaker: String) {
        guard !MeetingSession.shared.isActive else { return }
        let key = info?.key ?? "system"
        let name = info?.name
        guard book.needsConsent(key) else {
            Log.note("meeting: recording \(name ?? "all system audio") without the consent sheet (turned off for this app)")
            start(key: key, name: name ?? speaker, target: target, speaker: speaker, copy: Self.copyNoticeOnStart, skipFromNowOn: false)
            return
        }
        let request = MeetingConsentRequest(key: key, appName: name, offerSkip: info != nil && book.canOfferSkip(key))
        consent.show(request, copyDefault: Self.copyNoticeOnStart) { [weak self] result in
            guard let self, let result else { return }
            self.start(key: key, name: name ?? speaker, target: target, speaker: speaker, copy: result.copyNotice, skipFromNowOn: result.dontAskAgain)
        }
    }

    private func start(key: String, name: String, target: MeetingAudioTarget, speaker: String, copy: Bool, skipFromNowOn: Bool) {
        guard let app else { return }
        tracker.settleAll()
        if skipFromNowOn { book.setSkipConsent(key, true); saveBook() }
        pendingCount = (key, name)
        if copy {
            copyChatNotice()
            banner.show(.notice("The chat notice is copied. Paste it in the meeting chat."))
        }
        MeetingSession.shared.start(app: app, target: target, speaker: speaker)
    }

    func copyChatNotice() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingCopy.chatNotice, forType: .string)
        Log.note("meeting: chat notice copied")
    }

    // MARK: While recording

    private func phaseChanged(_ phase: MeetingSession.Phase) {
        switch phase {
        case .idle:
            status.hide()
            pendingCount = nil
            // The silent and sleep notes belong to the recording; a notice ("The meeting is saved…") stays.
            banner.hide { k in
                switch k {
                case .silent, .slept: return true
                case .call, .notice: return false
                }
            }
        case .starting, .stopping:
            status.show()
        case .recording, .paused:
            status.show()
            if let p = pendingCount, phase == .recording {
                book.recorded(p.key, name: p.name)
                saveBook()
                pendingCount = nil
            }
        }
        status.update()
    }

    private func remoteSilentChanged(_ on: Bool) {
        let s = MeetingSession.shared
        if on {
            banner.show(.silent(app: MeetingStatusController.appName(s) ?? "other apps"))
        } else {
            banner.hide { if case .silent = $0 { return true }; return false }
        }
    }

    // MARK: Settings

    func setDontAsk(_ key: String, _ on: Bool) {
        book.setDontAsk(key, name: book.apps[key]?.name ?? MeetingApps.info(key: key)?.name ?? key, on)
        saveBook()
    }

    func setSkipConsent(_ key: String, _ on: Bool) {
        book.setSkipConsent(key, on)
        saveBook()
    }

    private func saveBook() {
        UserDefaults.standard.set(book.encoded(), forKey: Self.bookKey)
    }

    // MARK: Self-test

    /// A pretend call prompt for the UI self-test: nothing is watched and nothing records unless Record is
    /// clicked in the consent sheet (the self-test clicks Cancel).
    func showTestPrompt(name: String) {
        promptApp = MeetingAppInfo(key: "uitest.\(name.lowercased())", bundleID: "uitest.\(name.lowercased())", name: name)
        banner.show(.call(app: name))
    }
}
