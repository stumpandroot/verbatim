import Foundation
import AppKit
import AVFoundation
import IOKit.pwr_mgt

/// Meeting capture: local, bot-free, two-track recording of a call. The
/// meeting app's sound comes from a Core Audio process tap (`ProcessTapCapture`, macOS 14.4 and later), or from
/// ScreenCaptureKit (`AppAudioCapture`) on macOS 14.0–14.3 or when the tap delivers only zeros; your voice comes
/// from the microphone through its own `Recorder` (an `InputUnit` on the chosen mic, no ducking). The two tracks
/// are written separately (segmented and crash-safe) into one session folder, "<stem>.meeting" in the recordings
/// folder, beside a sidecar (`MeetingSidecar`, session.json) with each track's start host time. Stop joins the
/// segments, lines the tracks up (`MeetingAlign.plan`: start offsets and a drift correction from host time), and
/// hands both to the multi-track pipeline as one `.meeting` transcript: the mic track is "You", the system track
/// the app's name. Launch recovery (`recoverLeftovers`) turns a session folder a crash left behind into that same
/// two-track transcript. Nothing leaves the Mac and nothing here uses the network.
///
/// It never starts on its own: `MeetingCoordinator` starts it after you click Record in the consent sheet (from the
/// call prompt, File › Record Meeting…, or the Record panel's menu on Home). While it runs, the menu bar item
/// (Views/MeetingStatus.swift) shows the time, both tracks' levels, Pause, and Stop and save. Optional developer
/// override of the system track's target (a bundle ID, or "system"):
///     defaults write co.stumpandroot.verbatim meetings.target -string us.zoom.xos
/// Every step leaves a line starting "meeting" in ~/Library/Logs/Verbatim/native.log.
@MainActor
final class MeetingSession: ObservableObject {
    static let shared = MeetingSession()

    static let targetKey = "meetings.target"
    static let folderExtension = "meeting"

    enum Phase: Equatable { case idle, starting, recording, paused, stopping }
    @Published private(set) var phase: Phase = .idle
    var isActive: Bool { phase != .idle }
    /// Pause needs both tracks to pause together; the ScreenCaptureKit fallback can't pause.
    var canPause: Bool { (phase == .recording || phase == .paused) && screenCapture == nil }
    /// The system track hears only zeros and there's nothing left to try: "Verbose isn't hearing anything from Zoom".
    @Published private(set) var remoteSilent = false
    /// The Mac slept while recording: the session paused (when it can), and the note offers Resume or Stop and save.
    @Published private(set) var slept = false
    /// Only your mic is recording: no system track could start, or you chose Keep my mic only.
    @Published private(set) var micOnly = false
    /// The system track's speaker: the meeting app's name ("Zoom"), or "Others" for all system audio.
    private(set) var speaker = "Others"
    /// The microphone recording your side, for the panel ("MacBook Pro Microphone").
    private(set) var micName = "Microphone"
    /// The system track is everything this Mac plays (no one app).
    var tapsEverything: Bool { target.bundleID == nil }
    /// Seconds recorded on the mic track (pauses left out): the menu bar timer.
    var elapsed: TimeInterval { mic.elapsed }
    /// Short messages for you (a failed start, a saved meeting). The coordinator shows them as a banner; without
    /// one they go to the main window's toast.
    var onNotice: ((String) -> Void)?

    private weak var app: AppState?
    /// The mic track's recorder: its own, so the app's voice-memo recorder (and its ducking) stays out of it.
    private let mic = Recorder()
    private let micClock = TrackClock()
    /// A `ProcessTapCapture` (stored untyped: it needs macOS 14.4).
    private var tapObject: AnyObject?
    private var screenCapture: AppAudioCapture?
    /// The ScreenCaptureKit fallback's clock and silence, fed from its live-words tap.
    private let screenClock = TrackClock()
    private let screenSilence = SilenceBox()
    private var target: MeetingAudioTarget = .allSystemAudio
    private var folder: URL?
    private var micURL: URL?
    private var systemURL: URL?
    private var sidecar: MeetingSidecar?
    private var sleepAssertion: IOPMAssertionID = 0
    private var holdsAssertion = false
    private var watchdog: Timer?
    private var startedAt = Date()
    private var startsWritten = false
    private var verdictDone = false
    private var lastSilenceNote: TimeInterval = 0
    private var lastProgressNote: TimeInterval = 0
    private var sleepObservers: [NSObjectProtocol] = []
    private var screenStartedAt: Double = 0
    private var pausedForSleep = false

    @available(macOS 14.4, *)
    private var tap: ProcessTapCapture? { tapObject as? ProcessTapCapture }

    // MARK: Targets

    /// The system track's target for a meeting app: its processes, or everything but Verbose for apps whose call
    /// sound comes from system processes (FaceTime's call daemons, Safari's WebKit processes).
    static func target(for app: MeetingAppInfo) -> MeetingAudioTarget {
        app.globalTap ? .allSystemAudio : .app(bundleID: app.bundleID, name: app.name)
    }

    /// For a start from the menu: the target override, else the frontmost meeting app, else the first running one
    /// (`MeetingApps.known` order), else all system audio. Also the system track's speaker name and the app (nil
    /// for all system audio).
    static func chooseTarget() -> (target: MeetingAudioTarget, speaker: String, app: MeetingAppInfo?) {
        let running = NSWorkspace.shared.runningApplications
        func name(_ id: String) -> String {
            running.first { $0.bundleIdentifier?.lowercased() == id.lowercased() }?.localizedName ?? id
        }
        let override = UserDefaults.standard.string(forKey: targetKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        if override.lowercased() == "system" { return (.allSystemAudio, "Others", nil) }
        if !override.isEmpty {
            let app = MeetingApps.info(key: override) ?? MeetingAppInfo(key: override.lowercased(), bundleID: override, name: name(override))
            return (.app(bundleID: app.bundleID, name: app.name), app.name, app)
        }
        let ids = running.compactMap { $0.bundleIdentifier?.lowercased() }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let f = front, let app = MeetingApps.resolve(f, running: Set(ids)) { return (target(for: app), app.name, app) }
        if let app = MeetingApps.known.first(where: { ids.contains($0.key) }) { return (target(for: app), app.name, app) }
        return (.allSystemAudio, "Others", nil)
    }

    // MARK: Start

    func start(app: AppState, target: MeetingAudioTarget, speaker: String) {
        guard phase == .idle else { return }
        self.app = app
        self.target = target
        self.speaker = speaker
        remoteSilent = false; slept = false; micOnly = false; pausedForSleep = false
        micName = AudioDevices.current()?.name ?? "Microphone"
        phase = .starting
        let os = ProcessInfo.processInfo.operatingSystemVersion
        Log.noteNow("meeting: start requested; target \(target.name)\(target.bundleID.map { " (\($0))" } ?? ""), speaker \(speaker), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        Task { await begin() }
    }

    private func begin() async {
        guard let app else { phase = .idle; return }
        // The microphone first: without it there's no meeting to record.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            Log.noteNow("meeting: asking for microphone access")
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return failStart("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.") }
        default:
            return failStart("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
        }

        let base = app.store.newRecordingURL()
        let stem = base.deletingPathExtension().lastPathComponent
        let folder = Paths.recordings.appendingPathComponent("\(stem).\(Self.folderExtension)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            return failStart("Couldn't make a folder for the meeting: \(error.localizedDescription)")
        }
        let micURL = folder.appendingPathComponent("\(stem) mic.wav")
        let systemURL = folder.appendingPathComponent("\(stem) system.wav")
        var side = MeetingSidecar(targetName: target.name, targetBundleID: target.bundleID, capturePath: "none", tracks: [
            MeetingTrack(role: .mic, fileName: micURL.lastPathComponent, speaker: "You"),
            MeetingTrack(role: .system, fileName: systemURL.lastPathComponent, speaker: speaker),
        ])
        self.folder = folder; self.micURL = micURL; self.systemURL = systemURL
        sidecar = side
        writeSidecar()
        Log.noteNow("meeting: session folder \(folder.lastPathComponent)")
        holdSleepAssertion()
        observeSleep()

        // Mic track: the host time of each converted buffer's first sample, from when it arrived.
        micClock.reset()
        let clock = micClock
        mic.liveTap = { buffer in
            let rate = buffer.format.sampleRate, n = Int(buffer.frameLength)
            guard rate > 0, n > 0 else { return }
            clock.mark(bufferStart: HostClock.now() - Double(n) / rate, frames: n, sampleRate: rate)
        }
        Log.noteNow("meeting: starting the mic track")
        let recorder = mic
        let micError: Error? = await withCheckedContinuation { c in
            Task { @MainActor in recorder.begin(to: micURL) { c.resume(returning: $0) } }
        }
        if let micError {
            mic.liveTap = nil
            return failStart("Couldn't start the microphone: \(micError.localizedDescription)")
        }
        Log.noteNow("meeting: mic track recording")

        // System track: the tap, else ScreenCaptureKit.
        var path = "none"
        if #available(macOS 14.4, *) {
            let t = ProcessTapCapture(target: target)
            do {
                try t.start(to: systemURL)
                tapObject = t
                path = "tap"
                side.events.append(t.isGlobal ? "tap: all system audio except Verbose" : "tap: \(t.tappedBundleIDs.joined(separator: ", "))")
            } catch {
                Log.noteNow("meeting: the process tap couldn't start (\(error.localizedDescription)); trying ScreenCaptureKit")
                side.events.append("tap failed: \(error.localizedDescription)")
            }
        } else {
            Log.noteNow("meeting: macOS before 14.4 has no process taps; trying ScreenCaptureKit")
        }
        if path == "none" {
            if await startScreenCapture(to: systemURL) { path = "screenCapture"; side.events.append("screenCapture: \(target.name)") }
            else { side.events.append("no system track; mic only"); micOnly = true; remoteSilent = true }
        }
        side.capturePath = path
        sidecar = side
        writeSidecar()
        startedAt = Date()
        startsWritten = false
        verdictDone = path != "tap"
        lastSilenceNote = 0; lastProgressNote = 0
        phase = .recording
        startWatchdog()
        Log.noteNow("meeting: recording; system track via \(path)")
    }

    /// ScreenCaptureKit for the target app: needs Screen & System Audio Recording, and an app (not all system audio).
    private func startScreenCapture(to url: URL) async -> Bool {
        guard let id = target.bundleID else {
            Log.noteNow("meeting: ScreenCaptureKit records one app; the target is all system audio, so the system track is skipped")
            return false
        }
        guard let running = try? await AppAudioCapture.runningApps(), let runningApp = running.first(where: { $0.id == id }) else {
            Log.noteNow("meeting: ScreenCaptureKit doesn't list \(id) (not running, or Screen Recording is off)")
            return false
        }
        let capture = AppAudioCapture()
        screenClock.reset()
        screenSilence.reset()
        let clock = screenClock, silence = screenSilence
        capture.liveTap.set { buffer in
            let rate = buffer.format.sampleRate, n = Int(buffer.frameLength)
            guard rate > 0, n > 0 else { return }
            let now = HostClock.now()
            clock.mark(bufferStart: now - Double(n) / rate, frames: n, sampleRate: rate)
            var peak: Float = 0
            if let ch = buffer.floatChannelData?[0] { for i in 0..<n { peak = max(peak, abs(ch[i])) } }
            silence.feed(peak: peak, at: now)
        }
        do {
            Log.noteNow("meeting: starting ScreenCaptureKit for \(runningApp.name)")
            try await capture.start(app: runningApp, to: url)
            screenCapture = capture
            screenStartedAt = HostClock.now()
            return true
        } catch {
            capture.liveTap.set(nil)
            Log.noteNow("meeting: ScreenCaptureKit couldn't start (\(error.localizedDescription)); the system track is skipped")
            return false
        }
    }

    private func failStart(_ message: String) {
        Log.noteNow("meeting: start failed: \(message)")
        notify(message)
        releaseSleepAssertion()
        stopObservingSleep()
        if let folder, (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.allSatisfy({ $0 == MeetingSidecar.fileName }) ?? true {
            try? FileManager.default.removeItem(at: folder)
        }
        reset()
    }

    // MARK: While recording

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    /// Once a second: records both start times in the sidecar once known, decides whether the tap is really
    /// hearing anything, and leaves breadcrumbs about silence and progress.
    private func tick() async {
        guard phase == .recording || phase == .paused else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let systemClock = currentSystemClock
        if !startsWritten, let m = micClock.start, (systemClock?.start != nil || elapsed > 10) {
            let s = systemClock?.start
            sidecar?.update(.mic) { $0.startHostTime = m }
            sidecar?.update(.system) { $0.startHostTime = s }
            writeSidecar()
            startsWritten = true
            Log.noteNow("meeting: start host times mic \(String(format: "%.3f", m))\(s.map { String(format: ", system %.3f (%+.0f ms)", $0, ($0 - m) * 1000) } ?? ", system none")")
        }
        if !verdictDone, #available(macOS 14.4, *), let t = tap {
            let verdict = t.verdict
            switch verdict {
            case .ok:
                verdictDone = true
                Log.noteNow("meeting: the tap hears audio \(String(format: "%.1f", elapsed)) s in")
            case .waiting:
                break
            case .onlyZeros, .noBuffers:
                verdictDone = true
                let playing = t.targetPlaying.map { $0 ? "playing" : "not playing" } ?? "unknown"
                Log.noteNow("meeting: the tap delivers \(verdict == .noBuffers ? "no buffers" : "only zeros") after \(String(format: "%.0f", elapsed)) s (app \(playing)); System Audio Recording is probably off")
                await fallBackFromTap(t)
            }
        }
        checkRemoteSilence()
        let silent = currentSilentFor
        if silent >= 30, elapsed - lastSilenceNote >= 30 {
            lastSilenceNote = elapsed
            Log.note("meeting: system track silent for \(Int(silent)) s")
        }
        if elapsed - lastProgressNote >= 60 {
            lastProgressNote = elapsed
            Log.note("meeting: \(Int(elapsed)) s; mic \(String(format: "%.0f", mic.elapsed)) s, system \(String(format: "%.0f", systemSeconds)) s, phase \(phase)")
        }
    }

    /// The tap hears nothing: ScreenCaptureKit into the same track when the target is an app, else mic only.
    @available(macOS 14.4, *)
    private func fallBackFromTap(_ t: ProcessTapCapture) async {
        guard let systemURL else { return }
        if target.bundleID == nil {
            sidecar?.events.append("tap silent; no fallback for all system audio")
            writeSidecar()
            remoteSilent = true
            return
        }
        await t.discard()
        tapObject = nil
        if await startScreenCapture(to: systemURL) {
            sidecar?.capturePath = "screenCapture"
            sidecar?.events.append("tap silent; switched to ScreenCaptureKit")
            // The system track starts again now: its start time is the new capture's first buffer.
            sidecar?.update(.system) { $0.startHostTime = nil }
            startsWritten = false
            Log.noteNow("meeting: switched the system track to ScreenCaptureKit")
        } else {
            sidecar?.capturePath = "none"
            sidecar?.events.append("tap silent; ScreenCaptureKit unavailable; mic only")
            Log.noteNow("meeting: no system track; the mic keeps recording")
            micOnly = true
            remoteSilent = true
        }
        writeSidecar()
    }

    /// The ScreenCaptureKit track delivering only zeros past the limit is the same problem as a silent tap; and a
    /// warning goes away by itself once real sound arrives.
    private func checkRemoteSilence() {
        if remoteSilent, !micOnly {
            var hearing = false
            if #available(macOS 14.4, *), let t = tap { hearing = t.verdict == .ok }
            if screenCapture != nil { hearing = screenSilence.everNonZero }
            if hearing { remoteSilent = false; Log.noteNow("meeting: the system track hears sound again") }
            return
        }
        guard !remoteSilent, screenCapture != nil, !screenSilence.everNonZero, screenStartedAt > 0,
              HostClock.now() - screenStartedAt >= MeetingAlign.zeroLimit else { return }
        remoteSilent = true
        sidecar?.events.append("screenCapture silent")
        writeSidecar()
        Log.noteNow("meeting: ScreenCaptureKit delivers only zeros; asking about Screen & System Audio Recording")
    }

    /// Keep my mic only: the system track (zeros, so far) is dropped and the warning goes away.
    func keepMicOnly() {
        guard isActive else { return }
        remoteSilent = false
        micOnly = true
        verdictDone = true
        Task {
            if #available(macOS 14.4, *), let t = tap { await t.discard() }
            tapObject = nil
            if let c = screenCapture { _ = await c.stop(); c.liveTap.set(nil); screenCapture = nil }
            if let systemURL { try? FileManager.default.removeItem(at: systemURL); RecordingSegments.removeSegments(of: systemURL) }
            sidecar?.capturePath = "none"
            sidecar?.events.append("kept the mic only")
            writeSidecar()
            Log.noteNow("meeting: keeping the mic only; the system track is dropped")
        }
    }

    /// The meters' levels (0…1) right now: the mic track and the system track.
    func levels() -> (mic: Float, system: Float) {
        var system: Float = 0
        if #available(macOS 14.4, *), let t = tap { system = t.currentLevel }
        else if let c = screenCapture { system = c.live.level }
        return (phase == .paused ? 0 : mic.live.level, phase == .paused ? 0 : system)
    }

    private func notify(_ message: String) {
        if let onNotice { onNotice(message) } else { app?.toast = Toast(message) }
    }

    private var currentSystemClock: TrackClock? {
        if #available(macOS 14.4, *), let t = tap { return t.clock }
        return screenCapture != nil ? screenClock : nil
    }

    private var currentSilentFor: Double {
        if #available(macOS 14.4, *), let t = tap { return t.silentFor }
        return screenCapture != nil ? screenSilence.silentFor : 0
    }

    private var systemSeconds: Double {
        if #available(macOS 14.4, *), let t = tap { return t.seconds }
        return screenCapture?.elapsed ?? 0
    }

    // MARK: Pause

    func togglePause() {
        guard canPause else { return }
        let now = HostClock.now()
        if phase == .recording {
            if !mic.isPaused { mic.togglePause() }
            if #available(macOS 14.4, *) { tap?.paused = true }
            sidecar?.pauses.append(MeetingPause(start: now))
            phase = .paused
            Log.noteNow("meeting: paused")
        } else {
            if mic.isPaused { mic.togglePause() }
            if #available(macOS 14.4, *) { tap?.paused = false }
            pausedForSleep = false
            if let i = sidecar?.pauses.indices.last, sidecar?.pauses[i].end == nil { sidecar?.pauses[i].end = now }
            phase = .recording
            Log.noteNow("meeting: resumed")
        }
        writeSidecar()
    }

    // MARK: Stop

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        phase = .stopping
        watchdog?.invalidate(); watchdog = nil
        Log.noteNow("meeting: stopping after \(Int(Date().timeIntervalSince(startedAt))) s")
        Task { await finish() }
    }

    private func finish() async {
        guard let app, let folder, var side = sidecar else { reset(); return }
        if let i = side.pauses.indices.last, side.pauses[i].end == nil { side.pauses[i].end = HostClock.now() }
        let micStopped = await mic.stopAndSave()
        mic.liveTap = nil
        let micHeard = mic.lastHeardSignal
        Log.noteNow("meeting: mic track saved: \(micStopped.map { String(format: "%.2f s, %lld frames", $0.duration, $0.framesWritten) } ?? "nothing")")

        var system: (url: URL, duration: Double)?
        var systemFrames: Int64?, systemHeard: Bool?, systemJoinFailed = false
        var systemClock: TrackClock?
        if #available(macOS 14.4, *), let t = tap {
            if let s = await t.stop() {
                system = (s.url, s.duration); systemFrames = s.framesWritten; systemHeard = s.heardSignal; systemJoinFailed = s.joinFailed
            }
            systemClock = t.clock
        } else if let c = screenCapture {
            if let s = await c.stop() {
                system = (s.url, s.duration); systemFrames = s.framesWritten; systemJoinFailed = s.joinFailed
            }
            c.liveTap.set(nil)
            systemHeard = screenSilence.everNonZero
            systemClock = screenClock
        }
        tapObject = nil; screenCapture = nil
        releaseSleepAssertion()
        stopObservingSleep()
        Log.noteNow("meeting: system track saved: \(system.map { String(format: "%.2f s", $0.duration) } ?? "nothing"), signal \(systemHeard.map { "\($0)" } ?? "unknown")")

        side.update(.mic) { t in
            t.startHostTime = micClock.start ?? t.startHostTime; t.endHostTime = micClock.end
            t.framesWritten = micStopped?.framesWritten; t.heardSignal = micHeard
        }
        side.update(.system) { t in
            t.startHostTime = systemClock?.start ?? t.startHostTime; t.endHostTime = systemClock?.end
            t.framesWritten = systemFrames; t.heardSignal = systemHeard
        }
        side.stoppedCleanly = true
        sidecar = side
        writeSidecar()

        if micStopped?.joinFailed == true || systemJoinFailed {
            // Every part stays in the session folder; launch recovery joins them and makes the transcript.
            Log.noteNow("meeting: couldn't join a track's segments; the session stays for launch recovery")
            notify(Store.joinFailedNotice)
            reset()
            return
        }
        let micTrack = micStopped.map { (url: $0.url, duration: $0.duration) }
        Self.handOff(app: app, folder: folder, sidecar: side, mic: micTrack, system: system, recovered: false)
        notify((micTrack?.duration ?? 0) >= 0.5 || (system?.duration ?? 0) >= 0.5 ? "The meeting is saved. Verbose is transcribing it." : "Nothing was recorded, so there's nothing to save.")
        reset()
    }

    private func reset() {
        watchdog?.invalidate(); watchdog = nil
        tapObject = nil; screenCapture = nil
        folder = nil; micURL = nil; systemURL = nil; sidecar = nil
        remoteSilent = false; slept = false; pausedForSleep = false; screenStartedAt = 0
        phase = .idle
    }

    // MARK: Hand-off to the multi-track pipeline

    /// Turns a stopped (or recovered) session into a transcript: both tracks as one two-track `.meeting`
    /// transcript lined up from host time, or the one usable track on its own. The session folder goes once the
    /// transcript has its own copies.
    static func handOff(app: AppState, folder: URL, sidecar: MeetingSidecar, mic: (url: URL, duration: Double)?,
                        system: (url: URL, duration: Double)?, recovered: Bool) {
        let fm = FileManager.default
        func usable(_ t: (url: URL, duration: Double)?) -> Bool { t.map { $0.duration >= 0.5 && fm.fileExists(atPath: $0.url.path) } ?? false }
        let micOK = usable(mic)
        // A system track of exact zeros (no permission) only adds an empty speaker.
        let systemOK = usable(system) && sidecar.track(.system)?.heardSignal != false
        var side = sidecar
        let title = "\(recovered ? "Recovered meeting" : "Meeting") · \(side.track(.system)?.speaker ?? side.targetName) · \(Store.stamp(side.createdAt))"
        let label = recovered ? "Recovered meeting" : "Meeting"
        if micOK, systemOK, let mic, let system, let micTrack = side.track(.mic), let sysTrack = side.track(.system) {
            let plan = MeetingAlign.plan(side)
            Log.noteNow("meeting: alignment \(MeetingAlign.describe(plan))")
            let id = app.startMultitrack(sources: [mic.url, system.url], sourceNames: [micTrack.fileName, sysTrack.fileName],
                                         speakers: [micTrack.speaker, sysTrack.speaker], offsets: plan.offsets,
                                         durations: [mic.duration, system.duration], title: title, align: false, ignoreBleed: true,
                                         source: .app, sourceLabel: label, recordedAt: side.createdAt) { ok in
                if ok {
                    try? fm.removeItem(at: folder)
                    Log.noteNow("meeting: tracks handed to the multi-track pipeline; session folder removed")
                } else {
                    Log.noteNow("meeting: preparing the tracks failed; the session folder stays")
                }
            }
            side.transcriptID = id
            try? side.write(in: folder)
            Log.noteNow("meeting: two-track transcript \(id.map { String($0.uuidString.prefix(8)) } ?? "none") queued (\(recovered ? "recovered" : "stopped"))")
            return
        }
        guard let only = micOK ? mic : (usable(system) ? system : nil) else {
            Log.noteNow("meeting: nothing usable was recorded; session folder removed")
            try? fm.removeItem(at: folder)
            return
        }
        Log.noteNow("meeting: one usable track (\(micOK ? "mic" : "system")); transcribing it on its own")
        guard let name = app.store.adoptRecording(only.url) else {
            Log.noteNow("meeting: couldn't move the track into the library; the session folder stays")
            return
        }
        var t = Transcript(title: title, source: micOK ? .voiceMemo : .app, sourceLabel: label, duration: only.duration, audioFileName: name, model: "")
        t.createdAt = side.createdAt
        t.kind = .meeting
        t.titleIsAuto = false
        app.enqueue(t)
        side.transcriptID = t.id
        try? side.write(in: folder)
        try? fm.removeItem(at: folder)
        Log.noteNow("meeting: single-track transcript queued; session folder removed")
    }

    // MARK: Launch recovery

    /// A session folder left behind by a crash or a quit: its segments joined per track, then the same hand-off as
    /// Stop, so it comes back as one two-track transcript, not two recordings. A session that already became a
    /// transcript is removed once that transcript has its audio. Runs at launch; the joins run off the main thread.
    static func recoverLeftovers(app: AppState) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Paths.recordings, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let active = shared.folder?.standardizedFileURL
        let folders = items.filter { u in
            u.pathExtension == folderExtension && u.standardizedFileURL != active
                && ((try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
        guard !folders.isEmpty else { return }
        Log.noteNow("meeting recovery: \(folders.count) session folder\(folders.count == 1 ? "" : "s") left behind")
        var prepared: [UUID: Bool] = [:]
        for t in app.store.transcripts { prepared[t.id] = t.audioFileName != nil }
        let known = prepared
        Task.detached(priority: .userInitiated) {
            var found: [Leftover] = []
            for f in folders {
                if let id = MeetingSidecar.read(in: f)?.transcriptID, let done = known[id] {
                    if done { try? fm.removeItem(at: f); Log.noteNow("meeting recovery: \(f.lastPathComponent) already became a transcript; removed") }
                    else { Log.noteNow("meeting recovery: \(f.lastPathComponent) is still being prepared; left as is") }
                    continue
                }
                if let l = MeetingSession.leftover(in: f) { found.append(l) }
            }
            let ready = found
            await MainActor.run {
                for l in ready { MeetingSession.handOff(app: app, folder: l.folder, sidecar: l.sidecar, mic: l.mic, system: l.system, recovered: true) }
            }
        }
    }

    struct Leftover: @unchecked Sendable {
        var folder: URL
        var sidecar: MeetingSidecar
        var mic: (url: URL, duration: Double)?
        var system: (url: URL, duration: Double)?
    }

    /// Joins a session folder's segments and reads its tracks. Without a sidecar (it couldn't be written), the
    /// tracks are found by name.
    nonisolated static func leftover(in folder: URL) -> Leftover? {
        let fm = FileManager.default
        RecordingSegments.joinLeftovers(in: folder)
        var side = MeetingSidecar.read(in: folder)
        if side == nil {
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            func find(_ suffix: String) -> String? { files.first { $0.hasSuffix(suffix) && RecordingSegments.parse(folder.appendingPathComponent($0)) == nil } }
            var tracks: [MeetingTrack] = []
            if let m = find(" mic.wav") { tracks.append(MeetingTrack(role: .mic, fileName: m, speaker: "You")) }
            if let s = find(" system.wav") { tracks.append(MeetingTrack(role: .system, fileName: s, speaker: "Others")) }
            guard !tracks.isEmpty else {
                Log.noteNow("meeting recovery: \(folder.lastPathComponent) has no tracks; left as is")
                return nil
            }
            let made = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            side = MeetingSidecar(createdAt: made, targetName: "Meeting", capturePath: "unknown", tracks: tracks)
        }
        guard var side else { return nil }
        var found: [MeetingTrack.Role: (url: URL, duration: Double)] = [:]
        for t in side.tracks {
            let u = folder.appendingPathComponent(t.fileName)
            WavRepair.fixHeader(u)   // the app quit before the open segment was closed
            guard let l = WavRepair.layout(u), l.byteRate > 0 else { continue }
            let seconds = Double(l.dataLength) / Double(l.byteRate)
            found[t.role] = (u, seconds)
            // No end times after a crash, so the plan uses start offsets only; the frame count is still known.
            side.update(t.role) { $0.framesWritten = Int64(seconds * $0.sampleRate) }
        }
        Log.noteNow("meeting recovery: \(folder.lastPathComponent): mic \(found[.mic].map { String(format: "%.1f s", $0.duration) } ?? "none"), system \(found[.system].map { String(format: "%.1f s", $0.duration) } ?? "none")")
        return Leftover(folder: folder, sidecar: side, mic: found[.mic], system: found[.system])
    }

    // MARK: Sidecar, sleep

    private func writeSidecar() {
        guard let folder, let sidecar else { return }
        do { try sidecar.write(in: folder) } catch { Log.note("meeting: couldn't write the sidecar: \(error.localizedDescription)") }
    }

    /// Keeps idle sleep away while recording. Closing the lid still sleeps the Mac (that can only be delayed).
    private func holdSleepAssertion() {
        guard !holdsAssertion else { return }
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "Verbose is recording a meeting" as CFString, &id)
        if r == kIOReturnSuccess { sleepAssertion = id; holdsAssertion = true; Log.noteNow("meeting: holding off idle sleep") }
        else { Log.noteNow("meeting: couldn't hold off idle sleep (\(r))") }
    }

    private func releaseSleepAssertion() {
        guard holdsAssertion else { return }
        IOPMAssertionRelease(sleepAssertion)
        holdsAssertion = false
        Log.note("meeting: idle sleep allowed again")
    }

    /// Lid-close sleep can't be prevented: it's noted in the sidecar and the log (a gap in both tracks).
    private func observeSleep() {
        stopObservingSleep()
        let ws = NSWorkspace.shared.notificationCenter
        sleepObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.sidecar?.events.append(String(format: "sleep at %.3f", HostClock.now()))
                if self.phase == .recording, self.canPause { self.togglePause(); self.pausedForSleep = true }
                self.writeSidecar()
                Log.noteNow("meeting: the Mac is going to sleep while recording\(self.pausedForSleep ? "; paused" : "")")
            }
        })
        sleepObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.sidecar?.events.append(String(format: "wake at %.3f", HostClock.now()))
                self.writeSidecar()
                self.slept = true
                Log.noteNow("meeting: the Mac woke while recording")
            }
        })
    }

    /// The sleep note's Resume: carries on in the same recording (a gap in both tracks, noted in the sidecar).
    func resumeAfterSleep() {
        slept = false
        if phase == .paused { togglePause() }
    }

    func dismissSleepNote() { slept = false }

    private func stopObservingSleep() {
        for o in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObservers = []
    }
}

/// A `SilenceTracker` behind a lock, fed from a capture queue and read on the main actor.
final class SilenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = SilenceTracker()
    func feed(peak: Float, at time: Double) { lock.lock(); tracker.feed(peak: peak, at: time); lock.unlock() }
    func reset() { lock.lock(); tracker = SilenceTracker(); lock.unlock() }
    var silentFor: Double { lock.lock(); defer { lock.unlock() }; return tracker.silentFor(now: HostClock.now()) }
    var everNonZero: Bool { lock.lock(); defer { lock.unlock() }; return tracker.everNonZero }
}
