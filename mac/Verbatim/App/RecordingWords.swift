import SwiftUI
import AVFoundation
import Combine

/// "Show words while you record" on the Mac, like the iPhone's (VerbatimPhone/MiniRecorder.swift): a preview of your
/// words in the recording bar while a voice note records, made on this Mac by `LiveTranscriber` from the recorder's
/// own buffers (`Recorder.liveTap`, no second microphone). It's a preview only: the saved transcript comes from the
/// full engine after Stop, and the recording never waits on it.
///
/// - Starts with the recording when the setting is on (it's on by default). Settings › Models and language.
/// - Shows nothing when on-device recognition isn't possible (no speech model yet, no permission). It never asks for
///   speech recognition permission during a recording; `LiveTranscriber.start` never prompts.
/// - Ends at once when the recording stops, however it stops.
@MainActor
final class RecordingWords: ObservableObject {
    /// The iPhone's key, so the setting means the same thing on both (each device keeps its own value).
    static let enabledKey = "record.liveWords"
    /// On unless you turned it off in Settings › Models and language.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    let words = LiveTranscriber()
    /// What the bar shows.
    @Published private(set) var shown = LiveWords()
    private weak var recorder: Recorder?
    private var active = false
    private var retries = 0
    private var ticker: Timer?
    private var bag = Set<AnyCancellable>()
    /// Watches for the recording to end.
    private var stopWatch: AnyCancellable?

    init() {
        words.$words.sink { [weak self] w in self?.merge(w) }.store(in: &bag)
    }

    var isActive: Bool { active }

    /// Before `recorder.begin`: the capture feeds live words from its first buffer, and words wait (held up to
    /// 10 s by `LiveTranscriber`) while the mic opens and the recognizer gets ready.
    func begin(_ recorder: Recorder) {
        end()
        guard Self.enabled, !UITest.enabled else { return }
        self.recorder = recorder
        active = true
        recorder.liveTap = words.tap
        words.start(format: Recorder.targetFormat)
        // Ends with the recording, whichever way it stops (Stop, a failed start, a quit).
        stopWatch = recorder.$isRecording.dropFirst().filter { !$0 }.first()
            .sink { [weak self] _ in self?.end() }
        ticker = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Ends live words at once. Never waits for final results.
    func end() {
        ticker?.invalidate(); ticker = nil
        stopWatch = nil
        words.stop()
        if active { recorder?.liveTap = nil }
        recorder = nil
        active = false
        retries = 0
        if !shown.isEmpty { shown = LiveWords() }
    }

    /// A speech model that's still installing: try again a few times, quietly.
    private func tick() {
        guard active, words.state == .off, retries < 12 else { return }
        retries += 1
        words.start(format: Recorder.targetFormat)
    }

    private func merge(_ w: LiveWords) {
        guard active, w != shown else { return }
        shown = w
    }
}

/// The last two lines of live words in the recording bar: settled words in ink, words still changing lighter.
/// Nothing at all when the setting is off or nothing has been heard.
struct RecordingWordsLine: View {
    @ObservedObject var words: RecordingWords
    /// Space around the words, only while there are words (the bar keeps its height until then).
    var insets = EdgeInsets()
    @AppStorage(RecordingWords.enabledKey) private var showWords = true

    var body: some View {
        let w = words.shown.tail(220)
        if showWords && !w.isEmpty {
            let gap = w.settled.isEmpty || w.volatile.isEmpty ? "" : " "
            (Text(w.settled).foregroundStyle(Ink.ink) + Text(gap) + Text(w.volatile).foregroundStyle(Ink.mute))
                .font(.system(size: 13.5))
                .lineSpacing(2)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(insets)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Live text")
                .accessibilityValue(w.text)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
