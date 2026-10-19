import SwiftUI
import AVFoundation
import UIKit

/// The app's half of keyboard dictation (see `KeyboardBridge` for the whole flow). The Verbatim keyboard opens
/// `verbatim://dictate?session=…`; this starts recording in the foreground with the same Recorder and
/// transcription queue as a voice note, keeps recording in the background while you go back to your app, and
/// stops on the keyboard's Done (or Done here, the 5-minute cap, or an interruption). The text goes back through
/// the App Group, and the recording is saved as a dictation, so it shows in Library › Dictations.
@MainActor
final class KeyboardHandoff: ObservableObject {
    enum Stage { case idle, starting, listening }

    @Published private(set) var stage: Stage = .idle
    private(set) var session: UUID?
    /// The transcript waiting for its words, for the session that asked.
    private var pending: (id: UUID, session: UUID)?
    private weak var app: PhoneState?
    private var timer: Timer?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var observing = false

    init(app: PhoneState) {
        self.app = app
    }

    private var defaults: UserDefaults? { KeyboardBridge.defaults }

    // MARK: Start

    /// Handles a link the app was opened with. True when it was a keyboard dictation link.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let s = KeyboardBridge.session(in: url) else { return false }
        begin(session: s)
        return true
    }

    private func begin(session s: UUID) {
        guard let app else { return }
        if session == s, stage != .idle { return }   // the same link twice
        if stage != .idle { finishRecording() }      // a newer request replaces an older one
        guard !app.recorder.isRecording else {
            fail(s, "Verbatim is already recording. Stop that recording first.")
            return
        }
        observeCommands()
        session = s
        stage = .starting
        app.showOnboarding = false
        app.showHandoff = true
        defaults?.set("Polished", forKey: KeyboardBridge.Key.levelLabel)
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                guard self.session == s else { return }
                if ok { self.startRecording() } else {
                    self.fail(s, "Microphone access is off. Turn it on in Settings › Verbatim.")
                    self.close()
                    app.say("Microphone access is off. Turn it on in Settings › Verbatim.")
                }
            }
        }
    }

    private func startRecording() {
        guard let app, let s = session else { return }
        do {
            try app.recorder.start(to: app.store.newRecordingURL())
        } catch {
            fail(s, "Couldn't start recording: \(error.localizedDescription)")
            close()
            return
        }
        stage = .listening
        app.warmModel()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        write(.listening, for: s)
        startTimer()
    }

    // MARK: While listening

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// About 10 times a second: level and time for the keyboard, then the stop conditions.
    private func tick() {
        guard let app, let s = session, stage == .listening else { return }
        let live = app.recorder.live
        if let d = defaults {
            d.set(Double(live.level), forKey: KeyboardBridge.Key.level)
            d.set(live.elapsed, forKey: KeyboardBridge.Key.elapsed)
            d.set(Date().timeIntervalSince1970, forKey: KeyboardBridge.Key.updated)
        }
        KeyboardBridge.post(KeyboardBridge.Note.state)
        checkCommand()
        guard session == s, stage == .listening else { return }
        if live.elapsed >= KeyboardBridge.maxSeconds { finishRecording(); return }
        // A call or a lost microphone paused the recorder. Without the microphone running, iOS would suspend the
        // app, so keep what was heard now.
        if app.recorder.isPaused || !app.recorder.isRecording { finishRecording() }
    }

    private func observeCommands() {
        guard !observing else { return }
        observing = true
        KeyboardBridge.observe(KeyboardBridge.Note.command) { [weak self] in self?.checkCommand() }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.session, self.stage != .idle else { return }
                self.app?.recorder.discard()
                self.fail(s, "Verbatim was closed while listening.")
            }
        }
    }

    private func checkCommand() {
        guard let d = defaults, let s = session, stage != .idle,
              d.string(forKey: KeyboardBridge.Key.commandSession) == s.uuidString,
              let raw = d.string(forKey: KeyboardBridge.Key.command), let c = KeyboardBridge.Command(rawValue: raw) else { return }
        d.removeObject(forKey: KeyboardBridge.Key.command)
        switch c {
        case .done: finishRecording()
        case .cancel: cancel()
        }
    }

    // MARK: Stop

    /// Done (from the keyboard or Done here): stop, save as a dictation, transcribe, and hand back the text.
    func finishRecording() {
        guard let app, let s = session else { return }
        timer?.invalidate(); timer = nil
        let wasListening = stage == .listening
        stage = .idle
        session = nil
        close()
        guard wasListening else { fail(s, "Dictation didn't start."); return }
        // Keep running long enough to transcribe after the microphone stops (the app is usually in the background).
        beginBackground()
        guard let (url, duration, env) = app.recorder.stop() else { fail(s, "Nothing was recorded."); return }
        if app.recorder.lastJoinFailed { fail(s, "Couldn't finish saving. Verbatim will recover the recording when it opens."); return }
        guard duration >= 0.5 else { try? FileManager.default.removeItem(at: url); fail(s, "No words were heard."); return }
        guard let name = app.store.adoptRecording(url) else { fail(s, "Couldn't save the recording."); return }
        var t = Transcript(title: "Dictation", source: .dictation, sourceLabel: "Dictation · Keyboard", duration: duration, audioFileName: name, model: "")
        t.kind = .dictation
        t.waveform = env
        pending = (t.id, s)
        write(.transcribing, for: s)
        app.coordinator.enqueue(t)
    }

    /// Cancel (keyboard or in-app): throw the recording away and insert nothing.
    func cancel() {
        guard let app, let s = session else { return }
        timer?.invalidate(); timer = nil
        if app.recorder.isRecording { app.recorder.discard() }
        stage = .idle
        session = nil
        write(.cancelled, for: s)
        close()
    }

    private func close() { app?.showHandoff = false }

    // MARK: Results (called by PhoneState's TranscriptionHost methods)

    /// True when `id` was a keyboard dictation; its text has been handed to the keyboard.
    func transcriptReady(_ id: UUID) -> Bool {
        guard let p = pending, p.id == id, let app else { return false }
        pending = nil
        let segments = app.store.transcript(id)?.segments ?? []
        let raw = segments.filter { !$0.isFillerOnly }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        // iPhone has no model cleanup (Flow's Cleanup.swift is Mac only), so Polished here is what the Mac falls
        // back to without Apple's model: the Clean prepass (spoken punctuation and line breaks, repeats), then the
        // rule-based layout (spoken lists and paragraphs). Plain bullets, since the destination app is unknown.
        let cleaned = CleanupPrepass.clean(raw)
        let text = DictationFormatter.format(cleaned, DictationFormatter.Options(style: .plain)).trimmingCharacters(in: .whitespacesAndNewlines)
        app.store.update(id) { t in
            if let title = Transcript.titleFrom(t.segments) { t.title = title }
        }
        if let d = defaults {
            d.set(text, forKey: KeyboardBridge.Key.text)
            d.set(raw, forKey: KeyboardBridge.Key.raw)
        }
        write(text.isEmpty ? .failed : .done, for: p.session, message: text.isEmpty ? "No words were heard." : nil)
        endBackground()
        return true
    }

    /// True when `id` was a keyboard dictation.
    func jobFailed(_ id: UUID, error: Error) -> Bool {
        guard let p = pending, p.id == id else { return false }
        pending = nil
        write(.failed, for: p.session, message: "Transcription failed: \(error.localizedDescription)")
        endBackground()
        return true
    }

    // MARK: Writing

    private func write(_ phase: KeyboardBridge.Phase, for s: UUID, message: String? = nil) {
        guard let d = defaults else { return }
        // A newer session from the keyboard wins; don't overwrite it with an older one's news.
        if let current = KeyboardBridge.currentSession, current != s { return }
        d.set(s.uuidString, forKey: KeyboardBridge.Key.session)
        d.set(phase.rawValue, forKey: KeyboardBridge.Key.phase)
        if let message { d.set(message, forKey: KeyboardBridge.Key.message) } else { d.removeObject(forKey: KeyboardBridge.Key.message) }
        if phase != .listening { d.set(0.0, forKey: KeyboardBridge.Key.level) }
        d.set(Date().timeIntervalSince1970, forKey: KeyboardBridge.Key.updated)
        KeyboardBridge.post(KeyboardBridge.Note.state)
    }

    private func fail(_ s: UUID, _ message: String) {
        write(.failed, for: s, message: message)
        endBackground()
    }

    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Keyboard dictation") { [weak self] in
            MainActor.assumeIsolated { self?.endBackground() }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }
}

// MARK: - Hand-off screen

/// Shown while the keyboard's dictation records: go back to your app and keep talking.
struct HandoffScreen: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject var handoff: KeyboardHandoff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Diamond().stroke(Ink.accentText, lineWidth: 1).frame(width: 7, height: 7)
                Overline(text: "Listening for your app", color: Ink.accentText)
            }
            .padding(.top, 24)
            .accessibilityElement(children: .combine)

            Text("Go back and keep talking.")
                .font(Ink.serif(34)).foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)

            Text("Verbatim keeps listening while you return to your app. Your words drop into the field when you tap Done on the keyboard.")
                .font(.system(size: 16)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            LevelCard(live: app.recorder.live, starting: handoff.stage == .starting)
                .padding(.top, 26)

            HStack(spacing: 12) {
                Button("Cancel") { handoff.cancel() }
                    .buttonStyle(.brandSecondaryLarge)
                    .accessibilityHint("Stops listening and inserts nothing")
                Button("Done here") { handoff.finishRecording() }
                    .buttonStyle(.brandPrimaryLarge)
                    .disabled(handoff.stage != .listening)
                    .accessibilityHint("Stops listening. Your words go in when you return to the keyboard.")
            }
            .padding(.top, 20)

            Spacer(minLength: 20)

            Text("To go back, swipe right along the bottom edge of the screen, or tap the app's name at the top left.")
                .font(.system(size: 13)).foregroundStyle(Ink.mute)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.paper.ignoresSafeArea())
        .interactiveDismissDisabled()
    }
}

/// The persimmon card with the three ink bars moving with your voice, and the elapsed time.
private struct LevelCard: View {
    @ObservedObject var live: LiveMeter
    var starting: Bool

    var body: some View {
        HStack(spacing: 18) {
            VoiceBars(level: starting ? 0 : Double(live.level), color: Ink.inkFixed, barWidth: 14, maxHeight: 64)
                .frame(width: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(starting ? "Starting…" : "Listening")
                    .font(Ink.serif(24)).foregroundStyle(Ink.inkFixed)
                Text(clock(live.elapsed))
                    .font(Ink.mono(15)).foregroundStyle(Ink.inkFixed.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
        .background(Ink.persimmon, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(starting ? "Starting" : "Listening, \(Int(live.elapsed)) seconds")
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

// MARK: - Settings › Keyboard

/// How to add the Verbatim keyboard. Google developer documentation style: second person, numbered steps.
struct KeyboardSetupScreen: View {
    @Environment(\.openURL) private var openURL

    private let steps = [
        "Open the Settings app.",
        "Go to General › Keyboard › Keyboards.",
        "Tap Add New Keyboard, and then tap Verbatim.",
        "Tap Verbatim in the list, and then turn on Allow Full Access.",
        "In any app, touch and hold the globe key, and then choose Verbatim.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("The Verbatim keyboard puts dictation in every app. You tap the record button, talk, and tap Done; Verbatim writes your words into the field.")
                    .font(.system(size: 16)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Overline(text: "Add the keyboard", color: Ink.mute).padding(.top, 6)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(i + 1).").font(Ink.mono(15, weight: .medium)).foregroundStyle(Ink.accentText)
                            Text(step).font(.system(size: 16)).foregroundStyle(Ink.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
                .cardSurface(radius: 14)

                Overline(text: "Why Full Access", color: Ink.mute).padding(.top, 6)
                Text("Full Access lets the keyboard open Verbatim to listen and receive your words from it. The recording and transcription happen in the Verbatim app on this iPhone; the keyboard never sends what you type or say anywhere else.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Overline(text: "How it works", color: Ink.mute).padding(.top, 6)
                Text("When you tap the record button, Verbatim opens and starts listening. Go back to your app and keep talking, and then tap Done on the keyboard. Dictations stop on their own after 5 minutes, and each one is saved in Library › Dictations.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.brandPrimaryLarge)
                .padding(.top, 8)
                .accessibilityHint("Opens Verbatim's page in the Settings app")
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Keyboard")
    }
}
