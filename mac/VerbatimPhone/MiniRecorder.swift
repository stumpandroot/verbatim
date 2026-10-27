import SwiftUI
import Combine
import UIKit

// MARK: - The minimized recorder
//
// Recording on iPhone starts full screen (RecordScreen, HomeScreen.swift). The chevron, a swipe down, or VoiceOver's
// escape gesture minimizes it: the full screen goes away, and the recording carries on in `PhoneState.recorder`,
// which lives as long as the app. A bar just above the tab bar shows it on every tab, with Pause or Resume and
// Stop. Tapping the bar brings the full screen back. Minimizing never stops, pauses, or discards anything: it only
// changes what's on screen.

/// The minimized recorder's rules, as pure functions so the self-test can check them without a microphone.
enum RecorderPresentation {
    /// What the Record button does.
    enum RecordTap: Equatable {
        /// Nothing is recording: start a new recording.
        case start
        /// A recording is running or saving: bring its full screen back instead of starting another.
        case reopen
    }

    /// The parts of the recorder's state the screen shows.
    struct State: Equatable {
        var recording: Bool
        var paused: Bool
        var fullScreen: Bool
        var elapsed: TimeInterval
    }

    /// The id the full screen zooms from and back to (iOS 18 and later).
    static let zoomID = "recorder"

    static func recordTap(recording: Bool, saving: Bool) -> RecordTap {
        recording || saving ? .reopen : .start
    }

    /// The bar is up while a recording exists, so it's already in place when the full screen zooms back to it.
    /// The full screen covers it while it's up.
    static func showsBar(recording: Bool, saving: Bool) -> Bool { recording || saving }

    /// Minimizing hides the full screen. The recording, its pause state, and its elapsed time stay as they were.
    static func minimize(_ s: State) -> State {
        var s = s
        s.fullScreen = false
        return s
    }

    /// Reopening shows the full screen again, only while there's a recording to show.
    static func reopen(_ s: State) -> State {
        var s = s
        if s.recording { s.fullScreen = true }
        return s
    }

    /// "4:12" in the bar: minutes and seconds, with hours once there are any.
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "4 minutes 12 seconds", for VoiceOver.
    static func spoken(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        func unit(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts: [String] = []
        if h > 0 { parts.append(unit(h, "hour", "hours")) }
        if m > 0 { parts.append(unit(m, "minute", "minutes")) }
        if sec > 0 || parts.isEmpty { parts.append(unit(sec, "second", "seconds")) }
        return parts.joined(separator: " ")
    }

    /// The bar's VoiceOver label: "Recording, 4 minutes 12 seconds".
    static func accessibilityLabel(paused: Bool, saving: Bool, elapsed: TimeInterval) -> String {
        if saving { return "Saving your recording" }
        return "\(paused ? "Paused" : "Recording"), \(spoken(elapsed))"
    }
}

// MARK: - Live text while recording

/// "Show words while you record": a preview of your words on the record screen and in the bar, made on this
/// iPhone by `LiveTranscriber` from the recorder's own buffers (no second microphone). It's a preview only. The
/// saved transcript comes from the full engine after Stop, and the recording never waits on it.
///
/// - Starts with the recording when the setting is on (it's on by default).
/// - Shows nothing when on-device recognition isn't possible (no speech model, no permission). It never asks for
///   permission during a recording.
/// - Stops recognizing while Verbatim is in the background or the screen is locked, and picks up again when you
///   come back. The words from before stay on screen.
@MainActor
final class RecordingLiveText: ObservableObject {
    static let enabledKey = "record.liveWords"
    /// On unless you turned it off in Settings › Recording and transcription.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    let words = LiveTranscriber()
    /// What the screen shows: words from before a trip to the background, then the current session's.
    @Published private(set) var shown = LiveWords()
    /// Words kept from sessions that ended when Verbatim went to the background.
    private var earlier = ""
    private weak var recorder: Recorder?
    /// Live text belongs to the current recording.
    private var active = false
    /// The recorder is feeding the recognizer (false while in the background).
    private var feeding = false
    private var retries = 0
    private var ticker: Timer?
    private var bag = Set<AnyCancellable>()

    init() {
        words.$words.sink { [weak self] w in self?.merge(w) }.store(in: &bag)
        // Locking the screen sends Verbatim to the background too.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.suspend() }.store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.resumeIfNeeded() }.store(in: &bag)
    }

    var isActive: Bool { active }
    /// A thought shown in the Dynamic Island: live words keep going in the background (the voice note's stop there).
    var keepInBackground = false

    /// Before `recorder.start`: the capture feeds live text from its first buffer.
    func prepare(_ recorder: Recorder) {
        end()
        guard Self.enabled, !PhoneUITest.enabled else { return }
        self.recorder = recorder
        active = true
        recorder.liveTap = words.tap
    }

    /// After `recorder.start` succeeded.
    func begin() {
        guard active else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if UIApplication.shared.applicationState == .background, !keepInBackground { recorder?.liveTap = nil; return }
        startWords()
    }

    /// Ends live text at once (Stop, Discard, a start that failed). Never waits for final results.
    func end() {
        ticker?.invalidate(); ticker = nil
        words.stop()
        if active { recorder?.liveTap = nil }
        recorder = nil
        active = false; feeding = false
        earlier = ""; retries = 0
        if !shown.isEmpty { shown = LiveWords() }
    }

    private func startWords() {
        guard active, let recorder else { return }
        recorder.liveTap = words.tap
        words.start(format: Recorder.targetFormat)
        feeding = true
    }

    /// In the background: stop feeding and recognizing, and keep what's on screen.
    private func suspend() {
        guard active, feeding, !keepInBackground else { return }
        earlier = LiveWords(settled: shown.text).tail(600).text
        feeding = false
        recorder?.liveTap = nil
        words.stop()
    }

    private func resumeIfNeeded() {
        guard active, !feeding else { return }
        retries = 0
        startWords()
    }

    /// A speech model that's still installing: try again a few times, quietly.
    private func tick() {
        guard active, feeding, words.state == .off, retries < 12 else { return }
        retries += 1
        words.start(format: Recorder.targetFormat)
    }

    private func merge(_ w: LiveWords) {
        let next = LiveWords(settled: LiveWords.join(earlier, w.settled), volatile: w.volatile)
        if next != shown { shown = next }
    }

    /// Made-up words for the screenshot tour (UI test mode only; no microphone or speech).
    func seedForScreenshots() {
        shown = LiveWords(settled: "Okay, notes for the catalog shoot. Wheels on white first, then the wagons out in the field by the shop. Ask Jonathan about the",
                          volatile: "spec sheet before Thursday")
    }

    func clearScreenshots() { shown = LiveWords() }
}

// MARK: - The bar

/// Places the bar just above the tab bar on a tab's content. A safe-area inset, so lists and scroll views end above
/// it instead of under it. Opaque: no glass behind its text.
struct MiniRecorderInset: ViewModifier {
    @EnvironmentObject var app: PhoneState
    var tab: PhoneState.Tab
    var zoom: Namespace.ID
    @Environment(\.limitMotion) private var limitMotion

    private var showing: Bool {
        RecorderPresentation.showsBar(recording: app.recorder.isRecording || app.previewRecording, saving: app.savingRecording)
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showing {
                    MiniRecorderBar(live: app.recorder.live, words: app.recordingWords, zoom: zoom, isZoomSource: app.tab == tab)
                        .transition(limitMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(limitMotion ? Motion.fade : Motion.settle, value: showing)
    }
}

extension View {
    /// The minimized recorder's bar on this tab's content, while a recording exists.
    func miniRecorderInset(_ tab: PhoneState.Tab, zoom: Namespace.ID) -> some View {
        modifier(MiniRecorderInset(tab: tab, zoom: zoom))
    }
}

/// The bar: a pulsing persimmon dot, Recording or Paused with the elapsed time, a small level meter, then Pause or
/// Resume and Stop. Tap anywhere else on it to open the full screen. 56 pt tall on the reader surface.
struct MiniRecorderBar: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject var live: LiveMeter
    @ObservedObject var words: RecordingLiveText
    var zoom: Namespace.ID
    var isZoomSource: Bool
    @Environment(\.limitMotion) private var limitMotion
    @AppStorage(RecordingLiveText.enabledKey) private var showWords = true

    private var paused: Bool { app.recorder.isPaused }
    private var saving: Bool { app.savingRecording }
    private var status: String { saving ? "Saving…" : paused ? "Paused" : "Recording" }
    /// The newest words, one line, only when there are some.
    private var line: String? {
        guard showWords, !saving else { return nil }
        let t = words.shown.tail(80).text
        return t.isEmpty ? nil : t
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { app.openRecorder() } label: {
                HStack(spacing: 12) {
                    RecordingDot(paused: paused || saving, animate: !limitMotion)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(status).font(.system(size: 15, weight: .semibold)).foregroundStyle(paused || saving ? Ink.dim : Ink.ink)
                            Text(RecorderPresentation.clock(live.elapsed)).lookMono(14, weight: .medium).foregroundStyle(.lookInk)
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                        if let line {
                            // Whole words only, never cut mid-word at the start (TailWords, review P-23).
                            TailWords(text: line, lines: 1, lineHeight: UIFont.systemFont(ofSize: 12.5).lineHeight) { tail in
                                Text(tail).font(.system(size: 12.5)).foregroundStyle(.lookMute)
                            }
                        }
                    }
                    Spacer(minLength: 6)
                    MiniLevel(live: live, paused: paused || saving)
                        .frame(width: 26, height: 22)
                }
                .padding(.leading, 14)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())

            MiniControl(primary: false, action: { app.togglePause() }) {
                if paused { PlayMark().fill(Ink.ink).frame(width: 12, height: 14).offset(x: 1) }
                else { PauseMark().fill(Ink.ink).frame(width: 12, height: 14) }
            }
            MiniControl(primary: true, action: { app.stopRecording() }) {
                if saving { ProgressView().controlSize(.small).tint(Ink.readerFixed) }
                else { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Ink.readerFixed).frame(width: 13, height: 13) }
            }
            .padding(.trailing, 8)
        }
        .disabled(saving)
        .frame(height: 56)
        .background(.lookReader, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(.lookHairline))
        .shadow(color: Ink.inkFixed.opacity(0.10), radius: 12, y: 4)
        .modifier(RecorderZoomSource(zoom: zoom, active: isZoomSource))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .sensoryFeedback(trigger: paused) { _, _ in Haptics.feedback(.impact(weight: .light)) }
        // One element for VoiceOver: "Recording, 4 minutes 12 seconds", with Pause or Resume, Stop, and Open.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RecorderPresentation.accessibilityLabel(paused: paused, saving: saving, elapsed: live.elapsed))
        .accessibilityValue(line ?? "")
        .accessibilityHint("Opens the recorder.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.openRecorder() }
        .accessibilityAction(named: Text(paused ? "Resume" : "Pause")) { app.togglePause() }
        .accessibilityAction(named: "Stop") { app.stopRecording() }
        .accessibilityAction(named: "Open") { app.openRecorder() }
    }
}

/// A 40 pt round control in the bar. Stop is persimmon; Pause and Resume sit on the paper.
private struct MiniControl<Mark: View>: View {
    var primary: Bool
    var action: () -> Void
    @ViewBuilder var mark: () -> Mark
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(primary ? Ink.persimmon : Ink.paper)
                if !primary { Circle().strokeBorder(.lookHairline) }
                mark()
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(SoftPress())
    }
}

/// The recording light: persimmon with a soft ring that pulses outward. Still when paused or when motion is limited.
struct RecordingDot: View {
    var paused: Bool
    var animate: Bool
    var body: some View {
        ZStack {
            if !paused && animate {
                Circle().fill(Ink.persimmon)
                    .phaseAnimator([false, true]) { c, out in
                        c.scaleEffect(out ? 2.2 : 1).opacity(out ? 0 : 0.45)
                    } animation: { out in out ? .easeOut(duration: 1.3) : .linear(duration: 0.01) }
            }
            Circle().fill(paused ? Ink.mute : Ink.persimmon)
        }
        .frame(width: 10, height: 10)
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// Five bars from the recorder's live meter, newest on the right.
struct MiniLevel: View {
    @ObservedObject var live: LiveMeter
    var paused: Bool
    var body: some View {
        GeometryReader { g in
            let values = Array(live.levels.suffix(5))
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    Capsule()
                        .fill(paused ? Ink.track : (i == values.count - 1 ? Ink.persimmon : Ink.ink))
                        .frame(width: 3, height: max(3, CGFloat(paused ? 0 : v) * g.size.height))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .animation(.easeOut(duration: 0.12), value: live.levels)
        .accessibilityHidden(true)
    }
}

// MARK: - Marks (drawn, so there are no SF Symbols in the recorder's controls)

struct PauseMark: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width * 0.34
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: w, height: r.height), cornerSize: CGSize(width: 1.5, height: 1.5))
        p.addRoundedRect(in: CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height), cornerSize: CGSize(width: 1.5, height: 1.5))
        return p
    }
}

struct PlayMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The minimize chevron, pointing down.
struct ChevronDownMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.3))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.3))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.3))
        return p
    }
}

// MARK: - The matched transition

/// The bar the full screen zooms from (iOS 18 and later). Only the selected tab's bar is the source.
struct RecorderZoomSource: ViewModifier {
    var zoom: Namespace.ID
    var active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            if active { content.matchedTransitionSource(id: RecorderPresentation.zoomID, in: zoom) } else { content }
        } else {
            content
        }
    }
}

/// The full screen zooms out of the bar and back into it, and a swipe down minimizes it (iOS 18 and later). With
/// motion limited, or on iOS 17, it uses the standard cover, and RecordScreen handles the swipe itself.
struct RecorderZoomDestination: ViewModifier {
    var zoom: Namespace.ID
    @Environment(\.limitMotion) private var limitMotion
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            if limitMotion { content } else { content.navigationTransition(.zoom(sourceID: RecorderPresentation.zoomID, in: zoom)) }
        } else {
            content
        }
    }

    /// True when the system zoom transition (and its swipe down) is in use.
    static func systemSwipe(limitMotion: Bool) -> Bool {
        if #available(iOS 18.0, *) { return !limitMotion }
        return false
    }
}

// MARK: - Live text on the record screen

/// The last three lines of live words: settled words in ink, words still changing lighter. Nothing at all when
/// live text is off or hasn't heard anything.
struct RecordLiveText: View {
    @ObservedObject var text: RecordingLiveText
    @AppStorage(RecordingLiveText.enabledKey) private var showWords = true
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 18

    var body: some View {
        let w = text.shown.tail(260)
        if showWords && !w.isEmpty {
            // Whole words only: the longest end that fits in three lines (TailWords, review P-23). The last words that
            // are still changing stay lighter.
            let changing = w.volatile.split(whereSeparator: { $0.isWhitespace }).count
            TailWords(text: w.text, lines: 3, lineHeight: UIFont.systemFont(ofSize: size).lineHeight + 3) { tail in
                let words = tail.split(separator: " ")
                let settled = words.dropLast(min(changing, words.count)).joined(separator: " ")
                let volatile = words.suffix(min(changing, words.count)).joined(separator: " ")
                (Text(settled).foregroundStyle(.lookInk) + Text(settled.isEmpty || volatile.isEmpty ? "" : " ") + Text(volatile).foregroundStyle(.lookMute))
                    .font(.system(size: size))
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live text")
            .accessibilityValue(w.text)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - PhoneState

extension PhoneState {
    /// A recording exists: running, paused, or being saved (or the screenshot tour's stand-in).
    var recordingActive: Bool { recorder.isRecording || savingRecording || previewRecording }

    /// The chevron, a swipe down, or VoiceOver's escape: the full screen goes away and the recording carries on.
    /// Never stops, pauses, or discards anything.
    func minimizeRecorder() {
        guard showRecorder else { return }
        setRecorderShown(false)
    }

    /// The bar, or Record while a recording exists: the full screen comes back with the same recording.
    func openRecorder() {
        guard recordingActive else { return }
        setRecorderShown(true)
    }

    /// With motion limited, the cover appears and goes without sliding; its content fades in.
    private func setRecorderShown(_ on: Bool) {
        guard showRecorder != on else { return }
        var t = Transaction()
        t.disablesAnimations = UIAccessibility.isReduceMotionEnabled || UserDefaults.standard.bool(forKey: MotionPreference.key)
        withTransaction(t) { showRecorder = on }
    }

    /// Live captions or the keyboard while a recording is running: "Finish your recording first", with a button
    /// that opens it.
    func askToFinishRecording(for feature: String) {
        finishRecordingFirst = feature
    }
}
