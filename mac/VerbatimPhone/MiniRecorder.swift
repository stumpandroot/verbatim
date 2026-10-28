import SwiftUI
import Combine
import UIKit

// MARK: - The minimized recorder
//
// Recording on iPhone starts in the recorder sheet (RecorderSheet.swift). Minimize, a swipe down, or VoiceOver's escape
// gesture minimizes it: the sheet goes away, and the recording carries on in `PhoneState.recorder`, which lives as long
// as the app. The minimized recorder (`MiniRecordingBar`, the refined kit; one design in both looks) shows it on every
// tab, with Pause or Resume and Stop: on a card above the tab bar in Verbose style, in the tab bar's bottom accessory in
// Native (RecordAccessory.swift). Tapping it brings the sheet back. Minimizing never stops, pauses, or discards
// anything: it only changes what's on screen.

/// The minimized recorder's rules, as pure functions so the self-test can check them without a microphone.
enum RecorderPresentation {
    /// What the Record button does.
    enum RecordTap: Equatable {
        /// Nothing is recording: start a new recording.
        case start
        /// A recording is running or saving: bring its recorder back instead of starting another.
        case reopen
    }

    /// The parts of the recorder's state the screen shows (`fullScreen`: the recorder sheet is up).
    struct State: Equatable {
        var recording: Bool
        var paused: Bool
        var fullScreen: Bool
        var elapsed: TimeInterval
    }

    static func recordTap(recording: Bool, saving: Bool) -> RecordTap {
        recording || saving ? .reopen : .start
    }

    /// The minimized recorder is up while a recording exists; the sheet covers it while it's up.
    static func showsBar(recording: Bool, saving: Bool) -> Bool { recording || saving }

    /// Minimizing hides the sheet. The recording, its pause state, and its elapsed time stay as they were.
    static func minimize(_ s: State) -> State {
        var s = s
        s.fullScreen = false
        return s
    }

    /// Reopening shows the sheet again, only while there's a recording to show.
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

// MARK: - The minimized recorder

/// Places the minimized recorder just above the tab bar on a tab's content in Verbose style: the kit's bar on an opaque
/// card with a hairline (it sits over scrolling content), never glass behind its text. A safe-area inset, so lists and
/// scroll views end above it instead of under it. In Native the tab bar's accessory carries it (RecordAccessory.swift),
/// and before iOS 26 an opaque bar above the tab bar does.
struct MiniRecorderInset: ViewModifier {
    @EnvironmentObject var app: PhoneState
    var tab: PhoneState.Tab
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.look) private var look
    @ObservedObject private var layouts = HomeLayoutStore.shared

    private var showing: Bool {
        RecorderPresentation.showsBar(recording: app.recorder.isRecording || app.previewRecording, saving: app.savingRecording)
    }

    /// Native before iOS 26: Record (or the live recording) in an opaque bar on every tab, where iOS 26 has the tab
    /// bar's bottom accessory (RecordAccessory.swift). Off while you read a transcript, and on Home's own screen while
    /// its Record card is there.
    private var nativeBar: Bool {
        look.isNative && !NativeRecordPlacement.systemAccessory && app.readingTranscripts == 0
            && !HomeSpacing.hidesRecordAccessory(tab: tab, homeAtRoot: app.homePath.isEmpty, recording: app.recordingActive,
                                                 layout: layouts.layout(look.homeLook))
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if look.isNative {
                    if nativeBar { NativeRecordBar() }   // brand: native
                } else if showing {
                    let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous)
                    PhoneMiniRecorder()
                        .frame(height: 56)
                        .background(Refined.card, in: shape)
                        .overlay(shape.strokeBorder(Refined.separator, lineWidth: 1))
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("recorder.mini")
                        .transition(limitMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(limitMotion ? Motion.fade : Motion.settle, value: showing)
    }
}

extension View {
    /// The minimized recorder on this tab's content, while a recording exists.
    func miniRecorderInset(_ tab: PhoneState.Tab) -> some View {
        modifier(MiniRecorderInset(tab: tab))
    }
}

/// The minimized recorder with the app's recording: the kit's `MiniRecordingBar` (the persimmon dot, "Recording ·
/// 4:12", your newest words or the kind, Pause or Resume, and Stop), the same in both looks.
struct PhoneMiniRecorder: View {
    @EnvironmentObject var app: PhoneState
    var inline = false

    var body: some View {
        MiniRecordingBar(live: app.recorder.live, paused: app.recorder.isPaused, saving: app.savingRecording, inline: inline,
                         onOpen: { app.openRecorder() }, onPause: { app.togglePause() }, onStop: { app.stopRecording() }) {
            MiniRecorderDetail(words: app.recordingWords, kind: app.recordingChoice.name, saving: app.savingRecording)
        }
    }
}

/// The bar's second line: your newest words, one line of whole words, or the kind when there are none.
private struct MiniRecorderDetail: View {
    @ObservedObject var words: RecordingLiveText
    var kind: String
    var saving: Bool
    @AppStorage(RecordingLiveText.enabledKey) private var showWords = true
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = CGFloat(RefinedRules.TextRole.meta.size(mac: false))

    var body: some View {
        let line = showWords && !saving ? words.shown.tail(80).text : ""
        if line.isEmpty {
            Text(kind).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
        } else {
            // Whole words only, never cut mid-word at the start (TailWords, review P-23).
            TailWords(text: line, lines: 1, lineHeight: UIFont.systemFont(ofSize: size).lineHeight) { tail in
                Text(tail).font(.system(size: size)).foregroundStyle(Refined.mute)
            }
        }
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

// MARK: - PhoneState

extension PhoneState {
    /// A recording exists: running, paused, or being saved (or the screenshot tour's stand-in).
    var recordingActive: Bool { recorder.isRecording || savingRecording || previewRecording }

    /// Minimize, a swipe down, or VoiceOver's escape: the recorder sheet goes away and the recording carries on.
    /// Never stops, pauses, or discards anything.
    func minimizeRecorder() {
        guard showRecorder else { return }
        setRecorderShown(false)
    }

    /// The minimized recorder, or Record while a recording exists: the sheet comes back with the same recording.
    func openRecorder() {
        guard recordingActive else { return }
        setRecorderShown(true)
    }

    /// With motion limited, the sheet appears and goes without sliding.
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
