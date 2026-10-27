import Foundation
import AVFoundation
import WatchKit

// Recording on the watch (DESIGN.md §20): AAC, mono, 22.05 kHz, into the watch's recording folder with its details
// beside it. The audio background mode keeps it recording with the screen off or your wrist down while the audio
// session is active, and watchOS shows the microphone indicator. It stops and saves when another app takes the
// microphone, or when the watch runs low on space. Stop hands the file to the outbox (WatchLink), which keeps it until
// the iPhone has it. A mark is a light tap on your wrist and "Marked 4:12" for two seconds.
//
// Haptics (DESIGN.md §7 and §20): `.start` just before the microphone opens, `.click` on a mark, `.stop` once it has
// stopped, and `.failure` when it can't start. They follow the iPhone's Settings › Haptics, which arrives in the
// context the iPhone sends (`WatchContext.haptics`), and play only with the watch app in front.

@MainActor
final class WatchRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum Phase: Equatable {
        case idle
        case recording
        /// Saved and on its way to the iPhone; `note` says why it stopped when you didn't stop it.
        case sent(WatchTransfer, reachable: Bool, note: String?)
        case problem(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var kind: WatchCaptureKind = .voiceNote
    @Published private(set) var marks: [WatchTransferMark] = []
    /// The time "Marked 4:12" confirms, for two seconds after a mark.
    @Published private(set) var confirmed: Double?
    /// The last 13 levels, 0…1, newest last, for the voice bars.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: WatchRecorder.barCount)
    private(set) var startedAt = Date()

    static let barCount = 13
    private var recorder: AVAudioRecorder?
    private var id = UUID()
    private var meter: Timer?
    private var ticks = 0
    private var confirmToken = UUID()
    private var interruptions: NSObjectProtocol?
    private let link = WatchLink.shared

    var isRecording: Bool { phase == .recording }
    /// Seconds recorded so far.
    var elapsed: Double { recorder?.currentTime ?? 0 }

    override init() {
        super.init()
        recoverLeftovers()
        interruptions = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            Task { @MainActor in self?.stop(note: WatchRules.interruptedMessage) }
        }
    }

    // MARK: Recording

    /// Record or New thought: asks for the microphone the first time.
    func start(_ kind: WatchCaptureKind) {
        guard !isRecording else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            begin(kind)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    if granted { self.begin(kind) } else { self.fail(WatchRules.micMessage) }
                }
            }
        default:
            fail(WatchRules.micMessage)
        }
    }

    /// The iPhone's Haptics switch, as the iPhone last sent it (on until it says otherwise).
    private func play(_ event: HapticEvent) {
        let policy = HapticPolicy(enabled: link.context?.haptics ?? true, platform: .watch)
        guard let type = policy.haptic(for: event)?.watchType else { return }
        WKInterfaceDevice.current().play(type)
    }

    /// Couldn't start: the message, with the failure tap.
    private func fail(_ message: String) {
        phase = .problem(message)
        play(.failed)
    }

    private func begin(_ kind: WatchCaptureKind) {
        guard WatchRules.canStart(freeBytes: WatchStore.freeBytes()) else { fail(WatchRules.fullMessage); return }
        // The start tap before the microphone opens, so its sound isn't in the recording.
        play(.recordStart)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            // Marks tap the wrist while recording; watchOS turns haptics off during recording unless this is set
            // before the session activates.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            watchLog.error("audio session: \(error.localizedDescription, privacy: .public)")
            fail(WatchRules.failedMessage)
            return
        }
        let id = UUID()
        let url = WatchStore.recordingURL(id)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else {
            try? session.setActive(false)
            fail(WatchRules.failedMessage)
            return
        }
        r.delegate = self
        r.isMeteringEnabled = true
        guard r.record() else {
            try? session.setActive(false)
            fail(WatchRules.failedMessage)
            return
        }
        self.id = id
        self.kind = kind
        recorder = r
        startedAt = Date()
        marks = []
        confirmed = nil
        levels = Array(repeating: 0, count: Self.barCount)
        // Written now and on each mark, so a recording the app is closed in the middle of still goes to the iPhone.
        WatchStore.writeDetails(currentTransfer(duration: 0), beside: url)
        phase = .recording
        ticks = 0
        meter = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        watchLog.notice("recording a \(kind.rawValue, privacy: .public)")
    }

    private func currentTransfer(duration: Double) -> WatchTransfer {
        WatchTransfer(id: id, kind: kind, startedAt: startedAt, duration: duration, marks: marks)
    }

    private func tick() {
        guard let r = recorder, isRecording else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        // -50 dB and below is silence; 0 dB is full.
        let level = Float(max(0, min(1, (Double(db) + 50) / 50)))
        levels = Array(levels.dropFirst()) + [level]
        ticks += 1
        // About every 6 seconds: stop and save before the watch runs out of space.
        if ticks % 50 == 0, WatchRules.mustStop(freeBytes: WatchStore.freeBytes()) {
            stop(note: WatchRules.stoppedFullMessage)
        }
    }

    /// Mark: the time now, unless a mark is within 3 seconds (then that one is confirmed again).
    func mark() {
        guard isRecording else { return }
        let r = WatchRules.adding(elapsed, to: marks)
        marks = r.marks
        WatchStore.writeDetails(currentTransfer(duration: elapsed), beside: WatchStore.recordingURL(id))
        play(.mark)
        confirmed = r.confirmed
        let token = UUID()
        confirmToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + WatchRules.confirmSeconds) { [weak self] in
            guard let self, self.confirmToken == token else { return }
            self.confirmed = nil
        }
    }

    /// Stop: saves the recording and sends it to the iPhone.
    func stop(note: String? = nil) {
        guard isRecording, let r = recorder else { return }
        let duration = r.currentTime
        recorder = nil
        meter?.invalidate()
        meter = nil
        r.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // After the microphone has stopped, with the screen changing to Sent (or back to Record when too short).
        play(.recordStop)
        let url = WatchStore.recordingURL(id)
        guard duration >= 0.5 else {
            WatchStore.remove(url)
            phase = .idle
            return
        }
        let t = currentTransfer(duration: duration)
        link.enqueue(file: url, transfer: t)
        confirmed = nil
        phase = .sent(t, reachable: link.reachable, note: note)
        watchLog.notice("saved \(Int(duration)) s with \(t.marks.count) marks")
    }

    /// Back to Record and New thought.
    func dismiss() {
        guard !isRecording else { return }
        phase = .idle
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // The system stopped it (Stop has already cleared `recorder`): save what there is.
        Task { @MainActor in
            if self.isRecording, self.recorder === recorder { self.stop(note: WatchRules.interruptedMessage) }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            if self.isRecording, self.recorder === recorder { self.stop(note: WatchRules.interruptedMessage) }
        }
    }

    // MARK: Never lose a recording

    /// A recording the app was closed in the middle of (its details are beside it): sent to the iPhone with the length
    /// the file has. Files with no audio in them are removed.
    private func recoverLeftovers() {
        for item in WatchStore.items(in: WatchStore.recordingFolder) {
            var t = item.transfer
            let seconds = (try? AVAudioFile(forReading: item.audio)).map { Double($0.length) / max(1, $0.fileFormat.sampleRate) } ?? 0
            guard seconds >= 0.5 else {
                watchLog.notice("removed an unreadable recording left from \(t.startedAt.description, privacy: .public)")
                WatchStore.remove(item.audio)
                continue
            }
            t.duration = seconds
            link.enqueue(file: item.audio, transfer: t)
            watchLog.notice("recovered a recording of \(Int(seconds)) s")
        }
    }
}
