import SwiftUI
import AVFoundation
import Combine
import UIKit

/// Live captions in the room: the iPhone's microphone, live words as large lines, recorded the whole time so
/// "Save transcript" hands the main engine the full recording. Keeps the screen awake while it runs. A call or
/// another app taking the audio pauses it (the recorder pauses itself); Resume carries on in the same file.
@MainActor
final class PhoneCaptions: ObservableObject {
    let feed = CaptionFeed()
    let words = LiveTranscriber()
    private let recorder = Recorder()

    @Published private(set) var running = false
    @Published private(set) var paused = false
    /// Why the recording paused itself; nil once you resume.
    @Published private(set) var pauseReason: String?
    @Published private(set) var startedAt = Date()
    /// Getting ready, or live captions not possible here.
    @Published private(set) var status: String?
    /// Turns the captions 180° so someone across the table can read them.
    @Published var flipped = false
    @Published private(set) var language = CaptionLanguage.current

    private var ticker: Timer?
    private var retries = 0
    private var bag = Set<AnyCancellable>()

    init() {
        feed.maxLineLength = 90
        feed.onFinished = { CaptionPermission.announce($0) }
        words.$words.sink { [weak self] w in self?.feed.update("room", words: w) }.store(in: &bag)
        recorder.onAutoPaused = { [weak self] reason in
            self?.paused = true
            self?.pauseReason = reason
            Haptics.play(.autoPaused)
        }
        // The recording resumed on its own after a call (or moved to another mic): show it running again.
        recorder.onInputSwitched = { [weak self] _ in
            guard let self else { return }
            self.paused = self.recorder.isPaused
            if !self.paused { self.pauseReason = nil }
        }
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Starts recording and live words. False (with `status` set) when the microphone couldn't start.
    func start(to url: URL) async -> Bool {
        await CaptionPermission.ensureSpeech()
        feed.reset()
        feed.addSource("room", speaker: nil)
        flipped = false
        paused = false; pauseReason = nil
        status = nil
        retries = 0
        language = CaptionLanguage.current
        words.locale = CaptionLanguage.locale
        recorder.liveTap = words.tap
        do {
            // Before the microphone opens, so the tap isn't in the recording.
            Haptics.play(.recordStart)
            try recorder.start(to: url)
        } catch {
            recorder.liveTap = nil
            status = "Couldn't start the microphone: \(error.localizedDescription)"
            return false
        }
        words.start(format: Recorder.targetFormat)
        startedAt = Date()
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    func togglePause() {
        let resuming = recorder.isPaused
        if resuming { Haptics.play(.resume) }
        recorder.togglePause()
        if !resuming, recorder.isPaused { Haptics.play(.pause) }
        paused = recorder.isPaused
        if !paused { pauseReason = nil }
    }

    func setLanguage(_ id: String) {
        guard id != language else { return }
        CaptionLanguage.current = id
        language = id
        guard running else { return }
        feed.finishAll()
        words.locale = CaptionLanguage.locale
        retries = 0
        words.start(format: Recorder.targetFormat)
    }

    /// Ends the session and returns the recording (nil if nothing was kept, or its parts are left for recovery).
    func stop() -> (URL, TimeInterval, [Float])? {
        guard running else { endSession(); return nil }
        endSession()
        let r = recorder.stop()
        return recorder.lastJoinFailed ? nil : r
    }

    /// Ends the session and deletes the recording.
    func discard() {
        let wasRunning = running
        endSession()
        if wasRunning { recorder.discard() }
    }

    private func endSession() {
        feed.finishAll()
        ticker?.invalidate(); ticker = nil
        words.stop()
        recorder.liveTap = nil
        running = false
        paused = false; pauseReason = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Pauses end lines; live words that couldn't start (a speech model still installing) are tried again.
    private func tick() {
        feed.tick()
        guard running else { return }
        guard words.state == .off else {
            if status != nil { status = nil }
            return
        }
        retries += 1
        if retries % 8 == 0, retries <= 240 { words.start(format: Recorder.targetFormat) }
        status = retries > 240
            ? "Live captions aren't available on this iPhone for this language. The recording continues; Save transcript still works."
            : "Getting live captions ready… The recording has started."
    }

    /// Made-up lines for screenshots (UI test mode only; no microphone or speech).
    func seedForScreenshots() {
        feed.reset()
        flipped = false
        feed.seed(history: [
            CaptionLine(id: UUID(), text: "We can move the shoot to Monday if the location is still free.", speaker: nil),
            CaptionLine(id: UUID(), text: "Then the crew call is at seven, and we start lighting by eight.", speaker: nil),
        ], current: [
            CaptionLine(id: UUID(), text: "Monday works. Let me check with the crew about the morning call", speaker: nil),
        ])
        startedAt = Date().addingTimeInterval(-252)
        running = true
        status = nil
    }

    func endScreenshots() {
        running = false
        feed.reset()
    }
}

/// The full-screen captions view (approved mockup PhoneCaptions): a mono header, faded older lines over a large
/// current line, Aa Size / language / Flip for them, then Stop and Save transcript.
struct LiveCaptionsScreen: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject var captions: PhoneCaptions
    @ObservedObject var feed: CaptionFeed
    @AppStorage(CaptionSize.key) private var sizeRaw = CaptionSize.medium.rawValue
    @Environment(\.limitMotion) private var limitMotion
    @State private var confirmStop = false

    private var size: CaptionSize { CaptionSize(rawValue: sizeRaw) ?? .medium }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                lines
            }
            .rotationEffect(.degrees(captions.flipped ? 180 : 0))
            .animation(limitMotion ? nil : Motion.settle, value: captions.flipped)

            if captions.paused {
                HStack(spacing: 10) {
                    Text(captions.pauseReason ?? "Paused.").refinedFont(.hint).foregroundStyle(Refined.dim).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Resume") { captions.togglePause() }
                        .buttonStyle(RefinedActionStyle(kind: .quiet))
                }
                .padding(.bottom, 12)
                .transition(.opacity)
            }
            chips.padding(.bottom, 12)
            HStack(spacing: 10) {
                Button { stopTapped() } label: {
                    Text("Stop").frame(maxWidth: .infinity).frame(minHeight: 50)
                }
                .buttonStyle(RefinedActionStyle(kind: .quiet))
                Button { app.stopCaptions(save: true) } label: {
                    Text("Save transcript").frame(maxWidth: .infinity).frame(minHeight: 50)
                }
                .buttonStyle(RefinedActionStyle(kind: .strong))
                .disabled(!captions.running)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
        .background(Refined.paper.ignoresSafeArea())
        .animation(Motion.fade, value: captions.paused)
        .confirmationDialog("Stop live captions?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Save transcript") { app.stopCaptions(save: true) }
            Button("Discard recording", role: .destructive) { app.stopCaptions(save: false) }
            Button("Keep captioning", role: .cancel) {}
        } message: {
            Text("The recording can be saved as a transcript, or deleted.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconGlyph(art: .iconCaptions, size: 16, color: Refined.mute)
            Text("Live captions · in the room").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute).lineLimit(1)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(captionClock(captions.elapsed)).refinedFont(.caption, weight: .medium).monospacedDigit().foregroundStyle(Refined.mute)
            }
            .accessibilityLabel("Elapsed time")
        }
    }

    private var lines: some View {
        ZStack(alignment: .bottomLeading) {
            if feed.history.isEmpty && feed.current.isEmpty {
                Text(captions.status ?? "Listening…").font(.system(size: 24, design: .serif)).foregroundStyle(Refined.mute)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CaptionLinesView(feed: feed, size: size.phone,
                                 older: [(size.phone * 0.71, Refined.mute), (size.phone * 0.65, Refined.mute.opacity(0.75)),
                                         (size.phone * 0.62, Refined.mute.opacity(0.6)), (size.phone * 0.6, Refined.mute.opacity(0.5))],
                                 showSpeakers: false, spacing: 14, currentLimit: 150)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.vertical, 20)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25), .init(color: .black, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .clipped()
        .overlay(alignment: .top) {
            if let s = captions.status, !(feed.history.isEmpty && feed.current.isEmpty) {
                Text(s).refinedFont(.meta).foregroundStyle(Refined.mute).padding(.top, 24)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Text size", selection: $sizeRaw) {
                    ForEach(CaptionSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } label: { chip("Aa Size") }
            .accessibilityLabel("Text size, \(size.title)")
            Menu {
                Picker("Language", selection: Binding(get: { captions.language }, set: { captions.setLanguage($0) })) {
                    ForEach(CaptionLanguage.all, id: \.self) { Text(CaptionLanguage.fullName($0)).tag($0) }
                }
            } label: { chip(CaptionLanguage.shortName(captions.language)) }
            .accessibilityLabel("Language, \(CaptionLanguage.fullName(captions.language))")
            Button { captions.flipped.toggle() } label: { chip("Flip for them", on: captions.flipped) }
                .accessibilityValue(captions.flipped ? "On" : "Off")
                .accessibilityHint("Turns the captions upside down so someone across from you can read them")
        }
    }

    private func chip(_ title: String, on: Bool = false) -> some View {
        Text(title).refinedFont(.hint, weight: on ? .semibold : .medium).lineLimit(1)
            .foregroundStyle(on ? Refined.accentText : Refined.ink)
            .padding(.horizontal, 14).frame(height: 36)
            .background(on ? Refined.persimmonTint : Refined.neutral, in: Capsule())
            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
            .contentShape(Rectangle())
    }

    private func stopTapped() {
        if captions.running, captions.elapsed > 20, !PhoneUITest.enabled { confirmStop = true }
        else { app.stopCaptions(save: false) }
    }
}
