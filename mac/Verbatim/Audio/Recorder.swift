import Foundation
import AVFoundation
import Combine
#if os(macOS)
import AppKit
import CoreAudio
#endif

/// Records the microphone with an AVAudioEngine tap: 16 kHz mono 16-bit WAV written as it goes (so a crash
/// loses nothing), real RMS levels from the samples (so the meter is your voice, not a smoothed power
/// reading), and a waveform envelope kept for the transcript.
/// Audio-thread side: converts and writes each tap buffer immediately (the engine reuses the buffer after
/// the callback returns), and keeps the envelope. Guarded by a lock; the main actor only reads snapshots.
/// 16 kHz mono 16-bit: what the engines want and a quarter of the disk of 48 kHz float.
let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

final class RecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    /// The format the converter expects. A buffer in any other format (one still in flight from a device the
    /// recording just moved off) is skipped rather than fed to the wrong converter.
    private var inputFormat: AVAudioFormat?
    private(set) var frames: Int64 = 0
    private(set) var envelope: [Float] = []
    private var envAccum: Float = 0, envCount = 0
    var paused = false
    /// Pre-roll: audio converted before the file is open (the mic starts first), written first on `attach`.
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: Int64 = 0
    private var holding = false
    /// A memory guard only: the file normally opens within milliseconds of the first buffer.
    private static let preRollCap = Int64(recordingFormat.sampleRate * 10)
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private var firstBufferAt: TimeInterval?
    /// Any sample that wasn't exact digital silence. A quiet room still has some noise; a mic that's asleep,
    /// muted in hardware, or switching profiles delivers zeros.
    private var signal = false
    /// Uptime of the last buffer that wasn't exact digital silence.
    private var lastSignal: TimeInterval?
    /// Long recordings: every `segmentFrames` the file is closed (so its header is final) and the recording
    /// continues in the next segment file beside it. A crash then loses at most the open segment's header,
    /// not the whole recording. `segments[0]` is the recording's own URL; Recorder joins them at stop.
    private let segmentLimit: Int64?
    private var framesInSegment: Int64 = 0
    /// Only touched with `lock` held (the audio thread appends to it); read through `segments`.
    private var segmentURLs: [URL] = []
    var segments: [URL] { lock.lock(); defer { lock.unlock() }; return segmentURLs }

    /// `segmented`: roll to a new file every `RecordingSegments.seconds` (normal recordings, not dictation).
    init(url: URL, inputFormat: AVAudioFormat, segmented: Bool = false) throws {
        file = try AVAudioFile(forWriting: url, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        converter = AVAudioConverter(from: inputFormat, to: recordingFormat)
        self.inputFormat = inputFormat
        segmentLimit = segmented ? Int64(recordingFormat.sampleRate * RecordingSegments.seconds) : nil
        segmentURLs = [url]
    }

    /// Converts from the first buffer and holds the audio until `attach(url:)` opens the file.
    init(inputFormat: AVAudioFormat) throws {
        guard let c = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw NSError(domain: "Verbatim", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone's format can't be converted."])
        }
        converter = c
        self.inputFormat = inputFormat
        holding = true
        segmentLimit = nil
    }

    /// Opens the file and writes the held pre-roll into it, so nothing heard before now is lost.
    func attach(url: URL) throws {
        let f = try AVAudioFile(forWriting: url, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        lock.lock(); defer { lock.unlock() }
        for b in preRoll {
            try? f.write(from: b)
            frames += Int64(b.frameLength)
        }
        preRoll = []; preRollFrames = 0
        holding = false
        file = f
    }

    /// Live words (`LiveTranscriber`): gets each converted 16 kHz mono buffer as it's written. Called on the
    /// audio thread, outside the lock; the buffer is freshly made for each call, so it may be kept.
    private var liveTap: (@Sendable (AVAudioPCMBuffer) -> Void)?
    func setLiveTap(_ tap: (@Sendable (AVAudioPCMBuffer) -> Void)?) { lock.lock(); liveTap = tap; lock.unlock() }

    /// Returns the perceptual level (0…1) of this buffer.
    func write(_ buffer: AVAudioPCMBuffer) -> Float {
        var tapped: AVAudioPCMBuffer?
        var tap: (@Sendable (AVAudioPCMBuffer) -> Void)?
        let v = write(buffer, tapped: &tapped, tap: &tap)
        if let tapped, let tap { tap(tapped) }
        return v
    }

    private func write(_ buffer: AVAudioPCMBuffer, tapped: inout AVAudioPCMBuffer?, tap: inout (@Sendable (AVAudioPCMBuffer) -> Void)?) -> Float {
        var rms: Float = 0
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            rms = sqrt(sum / Float(n))
        }
        // Speech RMS sits around 0.02–0.15 on a Mac mic; map that onto most of the bar height.
        let v = min(1, pow(max(0, rms - 0.004) * 6, 0.5))
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if firstBufferAt == nil { firstBufferAt = now }
        if rms > 0 { signal = true; lastSignal = now }
        guard !paused, converter != nil, file != nil || holding else { return 0 }
        // A route change (AirPods out, a new device) can change the format mid-stream: convert from the new one
        // instead of dropping it, so the file keeps one format and nothing is lost.
        if let f = inputFormat, buffer.format.sampleRate != f.sampleRate || buffer.format.channelCount != f.channelCount {
            guard let c = AVAudioConverter(from: buffer.format, to: recordingFormat) else { return v }
            converter = c
            inputFormat = buffer.format
        }
        guard let converter else { return v }
        let ratio = recordingFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: cap) else { return v }
        var fed = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 {
            if liveTap != nil { tapped = out; tap = liveTap }
            if let file {
                try? file.write(from: out)
                frames += Int64(out.frameLength)
                framesInSegment += Int64(out.frameLength)
                if let limit = segmentLimit, framesInSegment >= limit { rollSegment() }
            } else {
                preRoll.append(out)
                preRollFrames += Int64(out.frameLength)
                while preRollFrames > Self.preRollCap, !preRoll.isEmpty { preRollFrames -= Int64(preRoll.removeFirst().frameLength) }
            }
        }
        envAccum += v; envCount += 1
        if envCount >= 2 { envelope.append(envAccum / Float(envCount)); envAccum = 0; envCount = 0 }
        return v
    }

    var seconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(frames + preRollFrames) / recordingFormat.sampleRate }

    /// Opens the next segment file, then closes the current one (finalizing its header). Called with `lock`
    /// held, on the audio thread. If the next file can't be opened, keeps writing the current one.
    private func rollSegment() {
        framesInSegment = 0
        guard let first = segmentURLs.first else { return }
        let next = RecordingSegments.url(for: first, index: segmentURLs.count + 1)
        guard let f = try? AVAudioFile(forWriting: next, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true) else {
            Log.note("recorder: couldn't open segment \(segmentURLs.count + 1); continuing in the current file")
            return
        }
        if #available(macOS 15, iOS 18, *) { file?.close() }
        file = f
        segmentURLs.append(next)
        Log.note("recorder: segment \(segmentURLs.count) started")
    }

    /// Converts from a new input format (the recording moved to a fresh engine). False if it can't be converted.
    func replaceInput(_ format: AVAudioFormat) -> Bool {
        guard let c = AVAudioConverter(from: format, to: recordingFormat) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard converter != nil else { return false }
        converter = c
        inputFormat = format
        return true
    }

    /// Whether anything but digital silence has arrived.
    var heardSignal: Bool { lock.lock(); defer { lock.unlock() }; return signal }

    /// When (system uptime) the last sound that wasn't exact digital silence arrived, or nil if none has.
    var lastSignalAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return lastSignal }

    /// Milliseconds from creating the writer to the first buffer (how long the mic took to wake), if any arrived.
    var firstBufferDelay: Int? {
        lock.lock(); defer { lock.unlock() }
        return firstBufferAt.map { Int(($0 - createdAt) * 1000) }
    }

    /// Flushes the converter (its resampler holds the last few milliseconds) and closes the file.
    func close() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if let converter, let file, !paused { drain(converter, into: file) }
        if #available(macOS 15, iOS 18, *) { file?.close() }
        file = nil; converter = nil; preRoll = []; preRollFrames = 0; holding = false; liveTap = nil
        return envelope
    }

    private func drain(_ converter: AVAudioConverter, into file: AVAudioFile) {
        for _ in 0..<8 {
            guard let out = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: 4096) else { return }
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, s in s.pointee = .endOfStream; return nil }
            if err == nil, out.frameLength > 0 {
                try? file.write(from: out)
                frames += Int64(out.frameLength)
            }
            if err != nil || status != .haveData || out.frameLength == 0 { return }
        }
    }
}

/// Hands tap buffers to the current recording. The tap stays installed on a kept engine between recordings;
/// with no writer set, buffers are dropped (and the engine isn't running then anyway).
final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: RecordingWriter?
    private var onLevel: (@Sendable (Float, TimeInterval) -> Void)?
    private var lastSignal: TimeInterval?

    func set(_ writer: RecordingWriter?, onLevel: (@Sendable (Float, TimeInterval) -> Void)?) {
        lock.lock(); self.writer = writer; self.onLevel = onLevel; lock.unlock()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // Tracks whether this input delivers anything but exact digital silence, even with no writer set: a
        // muted mic the recording moved off is still listened to, to notice when it's unmuted.
        var heard = false
        if let ch = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) where ch[i] != 0 { heard = true; break }
        }
        lock.lock()
        if heard { lastSignal = ProcessInfo.processInfo.systemUptime }
        let w = writer, cb = onLevel
        lock.unlock()
        guard let w else { return }
        let v = w.write(buffer)
        cb?(v, w.seconds)
    }

    /// When (system uptime) this input last delivered anything but exact digital silence.
    var lastSignalAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return lastSignal }
}

/// What a recording is doing right now ("recording: starting Shure MV7"), so the hang watch can say which step
/// the main thread was stuck in. Any thread.
enum CaptureStep {
    private static let lock = NSLock()
    private static var step: String?
    private static var since: TimeInterval = 0

    static func set(_ s: String?) {
        lock.lock(); step = s; since = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }

    /// The step in progress and how long it has been running, or nil.
    static var current: String? {
        lock.lock(); defer { lock.unlock() }
        guard let step else { return nil }
        return "\(step), \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - since)) s in"
    }
}

/// A problem with the mic noticed while recording, shown for as long as it lasts.
enum MicWarning: Equatable {
    /// The device reports mute (or its input volume is at zero). Carries the device's name.
    case muted(String)
    /// Only exact digital silence is arriving: many USB mics mute in hardware this way, without saying so.
    case silent(String)
    /// The chosen mic is muted (`certain`) or silent, so the recording moved to the Mac's own mic until it's back.
    case usingBuiltIn(builtIn: String, chosen: String, certain: Bool)

    var isMuted: Bool { if case .muted = self { return true }; return false }
    var title: String {
        switch self {
        case .muted: return "Your mic is muted"
        case .silent: return "Not hearing your mic"
        case .usingBuiltIn(let builtIn, _, _): return "Using \(builtIn)"
        }
    }
    var detail: String {
        switch self {
        case .muted(let name): return "Unmute \(Self.phrase(name)) to keep going"
        case .silent(let name): return "Is \(Self.phrase(name)) muted?"
        case .usingBuiltIn(_, let chosen, let certain): return "\(chosen.isEmpty ? "Your mic" : chosen) \(certain ? "is muted" : "seems to be muted")"
        }
    }
    /// A firm statement (the device said so, or the recording moved mics), not a guess from silence.
    var isFirm: Bool { if case .silent = self { return false }; return true }

    /// "the Shure MV7 mic", "the MacBook Pro Microphone", or "the mic".
    static func phrase(_ name: String) -> String {
        guard !name.isEmpty else { return "the mic" }
        return name.lowercased().contains("mic") ? "the \(name)" : "the \(name) mic"
    }
}

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

#if os(macOS)
/// A normal recording's open microphone: its own unit, sink, and device listeners. Each start or reopen gets a
/// new one, so a start that finishes late (after a timeout or Stop) can only release its own. Everything here
/// runs on the recorder's audio queue, except `sink.set`, which is safe from any thread.
final class OpenInput: @unchecked Sendable {
    let unit: InputUnit
    let sink: TapSink
    let device: AudioDevices.Device
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(unit: InputUnit, sink: TapSink, device: AudioDevices.Device) {
        self.unit = unit; self.sink = sink; self.device = device
    }

    /// Calls `onChange` on the main queue when the device goes away or changes sample rate, and (when following
    /// the system default and `followDefault`) when the default input changes.
    func watch(followDefault: Bool = true, onChange: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var targets: [(AudioObjectID, AudioObjectPropertySelector)] = [(device.id, kAudioDevicePropertyDeviceIsAlive), (device.id, kAudioDevicePropertyNominalSampleRate)]
        if followDefault, AudioDevices.selectedInputID == nil { targets.append((AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)) }
        for (object, selector) in targets {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr { listeners.append((object, addr, block)) }
        }
    }

    /// Stops the device (the mic is free again), removes the listeners, and releases the unit.
    func release() {
        sink.set(nil, onLevel: nil)
        for (object, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        listeners = []
        unit.dispose()
    }
}

/// The name of the device a start is opening, reported from the audio queue for the timeout message.
final class MicNameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var name: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Where a normal recording goes after its microphone changed mid-recording (Mac).
enum MicRecovery: Equatable {
    /// The Mac's built-in microphone: the recording's mic went away, or the recording already moved there.
    case builtIn(AudioDevices.Device)
    /// The chosen mic, or the system default: the mic is still there (a new sample rate, a new default).
    case current
    /// Pause with Resume. `micLost`: the mic went away and the built-in one isn't available.
    case pause(micLost: Bool)

    /// `lostGone`: the recording's mic is no longer connected. `onBuiltIn`: the recording already moved to the
    /// built-in mic after losing its own. `recentlyReopened`: the mic changed less than 5 seconds ago too.
    /// `builtIn`: the Mac's built-in mic, if it has one available. A mic going away never pauses the recording
    /// unless there's no built-in mic to move to.
    static func plan(lostGone: Bool, onBuiltIn: Bool, recentlyReopened: Bool, builtIn: AudioDevices.Device?) -> MicRecovery {
        if lostGone {
            if let builtIn { return .builtIn(builtIn) }
            return .pause(micLost: true)
        }
        if recentlyReopened { return .pause(micLost: false) }
        if onBuiltIn, let builtIn { return .builtIn(builtIn) }
        return .current
    }
}
#endif

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    /// Mac normal recordings: the mic is being opened. `isRecording` is already true (the panel shows
    /// "Starting…"); Stop cancels.
    @Published private(set) var isStarting = false
    /// Called when Resume finishes reopening a microphone that went away while paused.
    var onResumed: (() -> Void)?
    let live = LiveMeter()
    /// The last `stop()` couldn't join a long recording's segments. The caller must not adopt the file then:
    /// every part stays in the recordings folder, and launch recovery joins it.
    private(set) var lastJoinFailed = false
    /// Called when a normal recording pauses itself (a phone call, or a microphone change it couldn't follow),
    /// with a short reason to show. Resume carries on in the same file.
    var onAutoPaused: ((String) -> Void)?
    /// A recording moved to another microphone on its own (the one it was using went away) and kept going.
    var onInputSwitched: ((String) -> Void)?
    var elapsed: TimeInterval { live.elapsed }

    /// Called when the input device changes or drops out mid-recording. The recording isn't moved to another
    /// device: the owner should stop and keep what was recorded. Without a handler, the recorder restarts
    /// the same device if it can.
    var onInterrupted: (() -> Void)?

    /// Dictation: no sound at all (no buffers, or only digital silence) 2 seconds after start. The owner should
    /// discard the recording and say the mic couldn't be heard. Without a handler, `onInterrupted` is called.
    var onNoAudio: (() -> Void)?

    /// Whether the last stopped or discarded recording received anything but digital silence.
    private(set) var lastHeardSignal = true

    /// Mac: the mic is muted, or nothing but digital silence is arriving, right now. Set within moments of the
    /// start (or of the change) and cleared as soon as it's fixed; the recording keeps going either way.
    @Published private(set) var micWarning: MicWarning?
    /// Called on every change of `micWarning`, including back to nil.
    var onMicWarning: ((MicWarning?) -> Void)?

    /// Normal recordings on the Mac open their own `InputUnit` on the chosen device per recording, off the main
    /// thread, released on Stop (see `begin(to:done:)`). An AVAudioEngine's input node first opens the system
    /// default input, which with Bluetooth headphones switches them to the call profile and can block the main
    /// thread for seconds. On the iPhone, normal recordings get a fresh engine per recording, released on Stop.
    /// Dictation (`keepWarm`, Mac only) records through an `InputUnit` bound to the chosen device instead of
    /// an engine (see `InputUnit` for why). It keeps that unit *initialized but stopped* between recordings,
    /// so key-down only starts the device. The mic runs only while recording. The unit is released after 10
    /// minutes unused and when the Mac sleeps, and is never kept prepared on a Bluetooth mic.
    private let keepWarm: Bool
    private var engine: AVAudioEngine?
    private var writer: RecordingWriter?
    private var url: URL?
    private let sink = TapSink()
    /// Live words: every converted buffer of the current and later recordings goes here too (audio thread).
    /// Set it before `start`; nil stops it. The recording itself never waits on it.
    var liveTap: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        didSet { writer?.setLiveTap(liveTap) }
    }
    private var configObserver: NSObjectProtocol?
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    #endif
    /// The tap's format on a normal recording's engine.
    private var tapFormat: AVAudioFormat?
    /// The dictation unit must be rebuilt before its next use (a device change, a failed start, a wake).
    private var stale = false
    /// Dictation wants the unit kept ready (dictation is on).
    private var armed = false
    private var idleTimer: Timer?
    private var startedAt: TimeInterval = 0
    private static let idleLimit: TimeInterval = 600
    #if os(macOS)
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Dictation's input, bound to one device.
    private var unit: InputUnit?
    /// Property listeners on the recording device (and the system default, when following it) while dictating.
    private var deviceWatch: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// Normal recordings (Mac): every Core Audio call (finding, opening, starting, and releasing the mic) runs
    /// here, never on the main thread. A device that takes seconds to answer can't freeze the app.
    private let audioQueue = DispatchQueue(label: "co.stumpandroot.verbatim.recorder", qos: .userInitiated)
    /// The open microphone of a normal recording; nil while starting, after the device went away, and when stopped.
    private var input: OpenInput?
    /// Bumped by every start, stop, cancel, and reopen. Work that finishes for an older value is released.
    private var attempt = 0
    private var pendingDone: ((Error?) -> Void)?
    private var reopening = false
    private var lastAutoReopen: TimeInterval = -100
    /// The recording's mic went away and it moved to the built-in mic: it stays there until Stop (or a Resume),
    /// and no longer follows the system default.
    private var stayOnBuiltIn = false
    /// How long opening a mic may take before the start is given up and the mic released.
    private static let startLimit: TimeInterval = 3
    /// The recording device's mute state, read and watched off the main thread.
    private var muteWatch: MicMuteWatch?
    private var silenceTimer: Timer?
    private var reportedMuted = false
    private var hearingSilence = false
    private var micName = ""
    /// While the chosen mic is muted: the Mac's built-in mic, running and writing into the same recording.
    /// The chosen mic keeps running too (its sink tracks signal only), so unmuting it is noticed.
    private var fallback: OpenInput?
    private var fallbackCertain = false
    private var fallbackStartedAt: TimeInterval = 0
    private var fallbackToken = 0
    private var switchingToFallback = false
    /// No built-in mic (or it delivered nothing): don't try again during this recording.
    private var fallbackUnavailable = false
    private var lastSwitchBack: TimeInterval = -100
    #endif

    static var targetFormat: AVAudioFormat { recordingFormat }

    init(keepWarm: Bool = false) {
        self.keepWarm = keepWarm
        #if os(macOS)
        if keepWarm {
            let ws = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.willSleep() }
            })
            workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.didWake() }
            })
        }
        #endif
    }

    private static var noInput: NSError {
        NSError(domain: "Verbatim", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
    }

    func start(to url: URL) throws {
        #if os(iOS)
        // iPhone: a record session that keeps going with the screen locked (background audio mode).
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif
        if keepWarm {
            CaptureStep.set("dictation: starting")
            defer { CaptureStep.set(nil) }
            try startWarm(to: url); return
        }
        #if os(macOS)
        // Normal recordings on the Mac start asynchronously; AppState calls `begin(to:done:)` directly.
        begin(to: url) { _ in }
        #else
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            self.engine = nil
            throw Self.noInput
        }
        let w = try RecordingWriter(url: url, inputFormat: inFormat, segmented: true)
        w.setLiveTap(liveTap)
        writer = w
        self.url = url
        live.reset()
        installRecordingTap(on: input, format: inFormat, writer: w)
        tapFormat = inFormat
        observeConfiguration(of: engine)
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0); removeConfigObserver()
            _ = w.close(); writer = nil; self.url = nil; self.engine = nil; tapFormat = nil
            throw error
        }
        RecordingSegments.setActive(url, true)
        observeInterruptions()
        pinCurrentInput()
        startedAt = ProcessInfo.processInfo.systemUptime
        isRecording = true
        isPaused = false
        #endif
    }

    #if os(iOS)
    /// Keeps a recording on the microphone it started with: AirPods connecting mid-recording don't take it over
    /// (that route switch is what froze the app). When this input goes away, iOS falls back to the iPhone mic.
    private func pinCurrentInput() {
        let s = AVAudioSession.sharedInstance()
        guard let cur = s.currentRoute.inputs.first,
              let port = s.availableInputs?.first(where: { $0.uid == cur.uid }) else { return }
        try? s.setPreferredInput(port)
    }

    /// After the pinned input went away: the iPhone's own microphone, pinned in its place.
    private func pinBuiltInMic() {
        let s = AVAudioSession.sharedInstance()
        if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) { try? s.setPreferredInput(mic) }
        else { try? s.setPreferredInput(nil) }
    }

    private var currentInputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first.map { $0.portType == .builtInMic ? "the iPhone microphone" : $0.portName } ?? "the iPhone microphone"
    }
    #endif

    private func installRecordingTap(on input: AVAudioInputNode, format: AVAudioFormat, writer w: RecordingWriter) {
        // iPhone: nil takes whatever the input delivers. Passing a format read during a route change (AirPods taken
        // out) can mismatch the hardware, and AVAudioEngine raises an exception that ends the app.
        #if os(iOS)
        let tapFormat: AVAudioFormat? = nil
        #else
        let tapFormat: AVAudioFormat? = format
        #endif
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            let v = w.write(buffer)
            let secs = w.seconds
            Task { @MainActor [weak self] in self?.meter(v, seconds: secs) }
        }
    }

    private func meter(_ v: Float, seconds: TimeInterval) {
        guard isRecording else { return }
        live.push(v, seconds: seconds, paused: isPaused)
    }

    func togglePause() {
        #if os(macOS)
        if !keepWarm {
            guard isRecording, !isStarting, !reopening else { return }
            // Resuming after the microphone went away: reopen it (off the main thread), then resume.
            if isPaused, input == nil { reopen(resuming: true); return }
        }
        #endif
        // Resuming after the recorder paused itself (a call, a device change): the engine stopped, start it again.
        if isPaused, !keepWarm, let engine, !engine.isRunning {
            guard restartCapture() else {
                Log.note("recorder: couldn't resume; still paused")
                onAutoPaused?("Couldn't restart the microphone. Stop to keep what was recorded.")
                return
            }
        }
        isPaused.toggle()
        writer?.paused = isPaused
        if isPaused { live.reset(); live.setElapsed(writer?.seconds ?? 0) }
    }

    /// Pauses a normal recording on the recorder's own initiative; what was recorded stays, Resume continues it.
    private func autoPause(_ reason: String) {
        guard isRecording, !keepWarm else { return }
        if !isPaused {
            isPaused = true
            writer?.paused = true
            live.reset(); live.setElapsed(writer?.seconds ?? 0)
        }
        Log.note("recorder: paused itself (\(reason))")
        onAutoPaused?(reason)
    }

    /// Normal recordings: points the tap at the input's current format (a new device, a new sample rate) and
    /// starts the engine again. The writer converts whatever arrives, so the file keeps one format.
    private func restartCapture() -> Bool {
        guard !keepWarm, var engine, let w = writer else { return false }
        #if os(iOS)
        pinBuiltInMic()
        try? AVAudioSession.sharedInstance().setActive(true)
        // A fresh engine after a route change: the old one can keep the departed device's format.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        removeConfigObserver()
        engine = AVAudioEngine()
        self.engine = engine
        observeConfiguration(of: engine)
        #endif
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        #if os(macOS)
        if let id = AudioDevices.selectedInputID { AudioDevices.setInput(id, on: input) }
        #endif
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, w.replaceInput(format) else { return false }
        installRecordingTap(on: input, format: format, writer: w)
        tapFormat = format
        engine.prepare()
        do { try engine.start() } catch {
            Log.note("recorder: restart failed: \(error.localizedDescription)"); return false
        }
        Log.note("recorder: capture restarted at \(Int(format.sampleRate)) Hz")
        return true
    }

    /// Returns the file URL, its duration, and the waveform envelope. A long recording's segments are joined into
    /// that file first; if that fails, `lastJoinFailed` is set and the caller must leave the file where it is.
    func stop() -> (URL, TimeInterval, [Float])? {
        lastJoinFailed = false
        #if os(macOS)
        if isStarting { cancelStart(); return nil }
        #endif
        guard let (w, url) = endCapture() else { return nil }
        lastHeardSignal = w.heardSignal
        let firstDelay = w.firstBufferDelay
        let env = Waveform.resample(w.close(), to: 120)   // close() flushes the converter's last frames first
        let d = w.seconds
        let parts = w.segments
        if parts.count > 1 {
            if RecordingSegments.join(parts) != nil {
                Log.note("recorder: joined \(parts.count) segments")
            } else {
                lastJoinFailed = true
                Log.note("recorder: couldn't join \(parts.count) segments; all kept for recovery at next launch")
            }
        }
        RecordingSegments.setActive(url, false)
        Log.note("recorder: stopped \(String(format: "%.2f", d))s, first audio \(firstDelay.map { "\($0) ms" } ?? "never") after start, warm=\(keepWarm)")
        finishStop()
        return (url, d, env)
    }

    /// Stops and deletes the recording and its segments without joining them.
    func discard() {
        lastJoinFailed = false
        #if os(macOS)
        if isStarting { cancelStart(); return }
        #endif
        guard let (w, url) = endCapture() else { return }
        lastHeardSignal = w.heardSignal
        _ = w.close()
        let fm = FileManager.default
        for u in w.segments { try? fm.removeItem(at: u) }
        RecordingSegments.removeSegments(of: url)
        RecordingSegments.setActive(url, false)
        Log.note("recorder: discarded")
        finishStop()
    }

    /// Stops capture and hands back the writer (not yet closed) and the recording's URL.
    private func endCapture() -> (RecordingWriter, URL)? {
        guard isRecording, let url, let w = writer else { return nil }
        #if os(macOS)
        stopMicWatch()
        #endif
        if keepWarm {
            sink.set(nil, onLevel: nil)
            #if os(macOS)
            unwatchDevice()
            unit?.stop()   // releases the mic; the unit stays initialized for the next dictation
            #endif
        } else {
            #if os(macOS)
            // A reopen still in flight is released when it finishes. The device is stopped off the main thread.
            attempt += 1
            reopening = false
            if let open = input {
                open.sink.set(nil, onLevel: nil)
                audioQueue.async { open.release() }
            }
            input = nil
            CaptureStep.set(nil)
            #endif
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine?.reset()
            removeConfigObserver()
            removeInterruptionObserver()
            engine = nil
            tapFormat = nil
        }
        return (w, url)
    }

    private func finishStop() {
        writer = nil
        isRecording = false; isPaused = false
        live.reset()
        self.url = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setPreferredInput(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if keepWarm {
            // Ready for the next dictation: prepared again (rebuilt if it went stale), mic off.
            if stale || !armed { teardown() }
            if armed { warmUp() }
        }
    }

    // MARK: Normal recordings (Mac)

    #if os(macOS)
    /// Starts a normal recording from the chosen mic (or the system default when none is chosen or it's
    /// unplugged) through an `InputUnit` bound to that device, so no other device, such as a Bluetooth headset's
    /// mic, is ever opened. Returns at once: the mic is opened on the audio queue while `isStarting` is true.
    /// `done(nil)` once it's recording. If opening fails, or the device doesn't answer within 3 seconds, the mic
    /// is released and `done` gets an error that names it. Stop while starting cancels, and `done` isn't called.
    func begin(to url: URL, done: @escaping (Error?) -> Void) {
        if keepWarm {
            do { try start(to: url); done(nil) } catch { done(error) }
            return
        }
        guard !isRecording else { done(RecorderError("A recording is already running.")); return }
        attempt += 1
        let mine = attempt
        let began = ProcessInfo.processInfo.systemUptime
        self.url = url
        lastAutoReopen = -100
        stayOnBuiltIn = false
        live.reset()
        isPaused = false
        isStarting = true
        isRecording = true
        pendingDone = done
        CaptureStep.set("recording: waiting for the audio queue")
        Log.note("recorder: starting")
        let levels = levelHandler()
        let probe = MicNameProbe()
        audioQueue.async { [weak self] in
            let result = Self.openInput(newFileAt: url, continuing: nil, levels: levels, probe: probe)
            Task { @MainActor in
                guard let self else {
                    if case .success(let (open, w)) = result { open.release(); _ = w.close() }
                    return
                }
                self.finishBegin(mine, result, url: url, probe: probe, began: began)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startLimit) { [weak self] in
            guard let self, self.attempt == mine, self.isStarting else { return }
            Log.note("recorder: start gave up after \(Int(Self.startLimit)) s (\(CaptureStep.current ?? "no step"))")
            let done = self.endStart()
            done?(RecorderError("Couldn't start \(Self.micPhrase(probe.name)). It didn't respond within \(Int(Self.startLimit)) seconds. Check that it's connected, or choose another mic in Settings › General › Microphone."))
        }
    }

    /// "the Shure MV7 mic", "the MacBook Pro Microphone", or "the microphone".
    static func micPhrase(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "the microphone" }
        return name.lowercased().contains("mic") ? "the \(name)" : "the \(name) mic"
    }

    /// Audio queue: finds the device, opens it, and starts it. With `continuing`, the existing writer is pointed
    /// at the new device's format; otherwise a new segmented writer is made at `url`. On failure everything it
    /// opened is released (and a new file removed). `device` opens that device instead of the current one.
    nonisolated private static func openInput(on device: AudioDevices.Device? = nil, newFileAt url: URL?, continuing existing: RecordingWriter?,
                                              levels: @escaping @Sendable (Float, TimeInterval) -> Void,
                                              probe: MicNameProbe) -> Result<(OpenInput, RecordingWriter), Error> {
        CaptureStep.set("recording: finding the microphone")
        // The chosen device if it's connected, otherwise the system default; never anything else.
        guard let target = device ?? AudioDevices.current() else { return .failure(RecorderError("No microphone is connected.")) }
        probe.name = target.name
        var made: InputUnit?
        do {
            CaptureStep.set("recording: preparing \(target.name)")
            let sink = TapSink()
            let u = try InputUnit(device: target.id) { buffer in sink.feed(buffer) }
            made = u
            try u.prepare()
            let w: RecordingWriter
            if let existing {
                guard existing.replaceInput(u.format) else { throw RecorderError("The microphone's format can't be converted.") }
                w = existing
            } else if let url {
                w = try RecordingWriter(url: url, inputFormat: u.format, segmented: true)
            } else {
                throw RecorderError("No file to record into.")
            }
            sink.set(w, onLevel: levels)
            CaptureStep.set("recording: starting \(target.name)")
            do {
                try u.start()
            } catch {
                sink.set(nil, onLevel: nil)
                if existing == nil, let url { _ = w.close(); try? FileManager.default.removeItem(at: url) }
                throw error
            }
            return .success((OpenInput(unit: u, sink: sink, device: target), w))
        } catch {
            made?.dispose()
            return .failure(error)
        }
    }

    private func finishBegin(_ mine: Int, _ result: Result<(OpenInput, RecordingWriter), Error>, url: URL, probe: MicNameProbe, began: TimeInterval) {
        let ms = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
        guard mine == attempt, isStarting else {
            // Stopped, cancelled, or given up meanwhile: release what opened, and its file.
            if case .success(let (open, w)) = result {
                open.sink.set(nil, onLevel: nil)
                audioQueue.async {
                    open.release()
                    _ = w.close()
                    for u in w.segments { try? FileManager.default.removeItem(at: u) }
                }
                Log.note("recorder: a start that was given up finished after \(ms) ms; mic released")
            }
            return
        }
        switch result {
        case .success(let (open, w)):
            let done = endStart(keepRecording: true)
            input = open
            w.setLiveTap(liveTap)
            writer = w
            RecordingSegments.setActive(url, true)
            startedAt = ProcessInfo.processInfo.systemUptime
            watch(open)
            startMicWatch(device: open.device.id, name: open.device.name)
            Log.note("recorder: recording from \(open.device.name) (\(open.device.transport)), \(Int(open.unit.format.sampleRate)) Hz, \(open.unit.format.channelCount) ch; started in \(ms) ms")
            done?(nil)
        case .failure(let error):
            Log.note("recorder: couldn't start after \(ms) ms: \(error.localizedDescription)")
            let done = endStart()
            done?(RecorderError("Couldn't start \(Self.micPhrase(probe.name)): \(error.localizedDescription)"))
        }
    }

    /// Leaves the starting state. Unless `keepRecording`, the recording is over too (failed or cancelled).
    /// Returns the start's completion, for the caller to call (or drop).
    @discardableResult
    private func endStart(keepRecording: Bool = false) -> ((Error?) -> Void)? {
        let done = pendingDone
        pendingDone = nil
        isStarting = false
        CaptureStep.set(nil)
        if !keepRecording {
            attempt += 1
            isRecording = false
            url = nil
            live.reset()
        }
        return done
    }

    /// Stop while the mic is still opening: the start is dropped, and the open releases itself when it finishes.
    private func cancelStart() {
        Log.note("recorder: start cancelled")
        _ = endStart()
    }

    private func watch(_ open: OpenInput) {
        let onChange: () -> Void = { [weak self, weak open] in
            guard let open else { return }
            Task { @MainActor in self?.inputChanged(open) }
        }
        let followDefault = !stayOnBuiltIn
        audioQueue.async { open.watch(followDefault: followDefault, onChange: onChange) }
    }

    /// The recording's device went away or changed (or the system default did, when following it). The dead
    /// input is released. A mic that went away (unplugged, AirPods out, Bluetooth dropped) is replaced by the
    /// Mac's built-in mic and the recording keeps going; it pauses only if the built-in mic can't start. A mic
    /// that's still there is reopened once by itself, and the recording pauses visibly if it changes again.
    private func inputChanged(_ changed: OpenInput) {
        guard !keepWarm, isRecording, !isStarting, input === changed else { return }
        Log.note("recorder: input changed mid-recording after \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt))s (\(changed.device.name))")
        input = nil
        stopMicWatch()
        changed.sink.set(nil, onLevel: nil)
        audioQueue.async { changed.release() }
        if let onInterrupted { onInterrupted(); return }
        if isPaused { Log.note("recorder: input changed while paused; Resume reopens the mic"); return }
        let now = ProcessInfo.processInfo.systemUptime
        let recent = now - lastAutoReopen <= 5
        lastAutoReopen = now
        recover(from: changed.device, recentlyReopened: recent)
    }

    static let switchedToBuiltInNotice = "Your microphone disconnected. Recording continues on the Mac's built-in microphone."
    static let noBuiltInNotice = "Your microphone disconnected, and the Mac's built-in microphone couldn't start. Tap Resume to keep recording."

    /// Audio queue: checks whether `lost` is still connected, then opens the mic `MicRecovery.plan` picks into the
    /// same writer (the writer converts the new format, so the file keeps one format). The main thread never waits.
    private func recover(from lost: AudioDevices.Device, recentlyReopened: Bool) {
        guard let w = writer, !reopening else { return }
        reopening = true
        attempt += 1
        let mine = attempt
        let levels = levelHandler()
        let probe = MicNameProbe()
        let onBuiltIn = stayOnBuiltIn
        CaptureStep.set("recording: following a microphone change")
        audioQueue.async { [weak self] in
            let gone = !AudioDevices.isPresent(lost.id)
            let builtIn = AudioDevices.builtInMic(excluding: gone ? lost.id : nil)
            let plan = MicRecovery.plan(lostGone: gone, onBuiltIn: onBuiltIn, recentlyReopened: recentlyReopened, builtIn: builtIn)
            let result: Result<(OpenInput, RecordingWriter), Error>?
            switch plan {
            case .builtIn(let d): result = Self.openInput(on: d, newFileAt: nil, continuing: w, levels: levels, probe: probe)
            case .current: result = Self.openInput(newFileAt: nil, continuing: w, levels: levels, probe: probe)
            case .pause: result = nil
            }
            Task { @MainActor in
                guard let self else { if case .success(let (open, _))? = result { open.release() }; return }
                self.finishRecover(mine, plan: plan, result: result, lost: lost, gone: gone)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startLimit) { [weak self] in
            guard let self, self.attempt == mine, self.reopening else { return }
            Log.note("recorder: following the mic change gave up after \(Int(Self.startLimit)) s (\(CaptureStep.current ?? "no step"))")
            self.attempt += 1
            self.reopening = false
            CaptureStep.set(nil)
            self.autoPause("Couldn't restart \(Self.micPhrase(probe.name)). Check that it's connected and tap Resume, or Stop to keep what was recorded.")
        }
    }

    private func finishRecover(_ mine: Int, plan: MicRecovery, result: Result<(OpenInput, RecordingWriter), Error>?, lost: AudioDevices.Device, gone: Bool) {
        guard mine == attempt, reopening, isRecording else {
            if case .success(let (open, _))? = result {
                open.sink.set(nil, onLevel: nil)
                audioQueue.async { open.release() }
                Log.note("recorder: a mic change that was given up finished; mic released")
            }
            return
        }
        reopening = false
        CaptureStep.set(nil)
        switch result {
        case .success(let (open, _))?:
            var movedToBuiltIn = false
            if case .builtIn = plan { movedToBuiltIn = true }
            if movedToBuiltIn { stayOnBuiltIn = true }
            input = open
            watch(open)
            startMicWatch(device: open.device.id, name: open.device.name)
            Log.note("recorder: \(gone ? "\(lost.name) went away; " : "")recording continues on \(open.device.name), \(Int(open.unit.format.sampleRate)) Hz")
            if movedToBuiltIn, open.device.id != lost.id { onInputSwitched?(Self.switchedToBuiltInNotice) }
        case .failure(let error)?:
            Log.note("recorder: couldn't follow the mic change: \(error.localizedDescription)")
            if case .builtIn = plan, gone { autoPause(Self.noBuiltInNotice) }
            else { autoPause("The microphone changed. Tap Resume to keep recording.") }
        case nil:
            if case .pause(micLost: true) = plan {
                Log.note("recorder: \(lost.name) went away and there's no built-in mic to move to")
                autoPause(Self.noBuiltInNotice)
            } else {
                autoPause("The microphone changed. Tap Resume to keep recording.")
            }
        }
    }

    /// Opens the mic again into the same writer (the writer converts the new format). `resuming`: Resume after the
    /// mic went away; success resumes. Otherwise a reopen after a device change; failure pauses.
    private func reopen(resuming: Bool) {
        guard let w = writer, !reopening else { return }
        reopening = true
        attempt += 1
        let mine = attempt
        let levels = levelHandler()
        let probe = MicNameProbe()
        CaptureStep.set("recording: reopening the microphone")
        Log.note("recorder: reopening the microphone\(resuming ? " to resume" : "")")
        audioQueue.async { [weak self] in
            let result = Self.openInput(newFileAt: nil, continuing: w, levels: levels, probe: probe)
            Task { @MainActor in
                guard let self else { if case .success(let (open, _)) = result { open.release() }; return }
                self.finishReopen(mine, result, resuming: resuming, probe: probe)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startLimit) { [weak self] in
            guard let self, self.attempt == mine, self.reopening else { return }
            Log.note("recorder: reopening gave up after \(Int(Self.startLimit)) s (\(CaptureStep.current ?? "no step"))")
            self.attempt += 1
            self.reopening = false
            CaptureStep.set(nil)
            self.autoPause("Couldn't restart \(Self.micPhrase(probe.name)). Check that it's connected and tap Resume, or Stop to keep what was recorded.")
        }
    }

    private func finishReopen(_ mine: Int, _ result: Result<(OpenInput, RecordingWriter), Error>, resuming: Bool, probe: MicNameProbe) {
        guard mine == attempt, reopening, isRecording else {
            if case .success(let (open, _)) = result {
                open.sink.set(nil, onLevel: nil)
                audioQueue.async { open.release() }
                Log.note("recorder: a reopen that was given up finished; mic released")
            }
            return
        }
        reopening = false
        CaptureStep.set(nil)
        switch result {
        case .success(let (open, _)):
            // Resume opens the chosen mic (or the system default) again, wherever the recording moved before.
            stayOnBuiltIn = false
            input = open
            watch(open)
            startMicWatch(device: open.device.id, name: open.device.name)
            Log.note("recorder: microphone reopened on \(open.device.name), \(Int(open.unit.format.sampleRate)) Hz")
            if resuming {
                isPaused = false
                writer?.paused = false
                onResumed?()
            }
        case .failure(let error):
            Log.note("recorder: couldn't reopen: \(error.localizedDescription)")
            if resuming {
                onAutoPaused?("Couldn't restart \(Self.micPhrase(probe.name)). Stop to keep what was recorded.")
            } else {
                autoPause("The microphone changed. Tap Resume to keep recording.")
            }
        }
    }
    #endif

    // MARK: Kept input (dictation)

    /// Prepares the dictation unit on the device dictation will use (mic off), so the next start is quick.
    /// Dictation calls this when it's on.
    func warmUp() {
        guard keepWarm else { return }
        armed = true
        guard !isRecording else { return }
        #if os(macOS)
        // Not on a Bluetooth mic: an initialized unit can hold a headset in its low-quality call profile.
        guard let target = AudioDevices.current(), target.transport != "Bluetooth" else { teardown(); return }
        if stale || !unitFits(target.id) {
            do { try rebuild(on: target) } catch { Log.note("recorder: couldn't prepare \(target.name): \(error.localizedDescription)") }
        }
        scheduleIdleRelease()
        #endif
    }

    /// Releases the dictation unit (dictation turned off).
    func coolDown() {
        guard keepWarm else { return }
        armed = false
        guard !isRecording else { return }
        teardown()
    }

    private func startWarm(to url: URL) throws {
        idleTimer?.invalidate(); idleTimer = nil
        armed = true
        #if os(macOS)
        // The chosen device if it's connected, otherwise the system default; never anything else.
        guard let target = AudioDevices.current() else { teardown(); throw Self.noInput }
        do {
            if stale || !unitFits(target.id) { try rebuild(on: target) }
            do {
                try beginCapture(to: url, name: target.name)
            } catch {
                // A device that changed while idle can fail to start. One retry on a fresh unit.
                Log.note("recorder: dictation start failed on \(target.name) (\(error.localizedDescription)); retrying on a fresh unit")
                try rebuild(on: target)
                try beginCapture(to: url, name: target.name)
            }
        } catch {
            // Release the device so a failed start never leaves a mic (or a headset's call profile) held open.
            teardown()
            throw error
        }
        #else
        throw Self.noInput
        #endif
    }

    #if os(macOS)
    /// Whether the prepared unit is on this device and still matches its sample rate.
    private func unitFits(_ device: AudioDeviceID) -> Bool {
        guard let unit, unit.device == device else { return false }
        guard let rate = AudioDevices.nominalSampleRate(device) else { return true }
        return rate == unit.format.sampleRate
    }

    /// A new unit on `target`, initialized, not started.
    private func rebuild(on target: AudioDevices.Device) throws {
        teardown()
        let u = try InputUnit(device: target.id) { [sink = self.sink] buffer in sink.feed(buffer) }
        do { try u.prepare() } catch { u.dispose(); throw error }
        unit = u
        stale = false
        Log.note("recorder: dictation input ready on \(target.name) (\(target.transport)), \(Int(u.format.sampleRate)) Hz, \(u.format.channelCount) ch")
    }

    private func beginCapture(to url: URL, name: String) throws {
        guard let unit else { throw Self.noInput }
        let w = try RecordingWriter(inputFormat: unit.format)
        w.setLiveTap(liveTap)
        live.reset()
        sink.set(w, onLevel: levelHandler())
        do {
            try unit.start()
        } catch {
            sink.set(nil, onLevel: nil)
            _ = w.close()
            throw error
        }
        // The mic is already running; audio heard while the file opens is held and written first.
        do {
            try w.attach(url: url)
        } catch {
            sink.set(nil, onLevel: nil)
            unit.stop()
            _ = w.close()
            throw error
        }
        writer = w
        self.url = url
        RecordingSegments.setActive(url, true)
        startedAt = ProcessInfo.processInfo.systemUptime
        isRecording = true
        isPaused = false
        watchDevice(unit.device)
        startMicWatch(device: unit.device, name: name)
        watchFirstSignal(w)
    }

    // MARK: Muted mic

    /// Starts watching the recording device: its mute switch and input volume (Core Audio, on the watch's own
    /// queue), and the audio itself for exact digital silence. Either sets `micWarning` while it lasts, and
    /// moves the recording to the Mac's built-in mic until the chosen one is back (see `startFallback`).
    private func startMicWatch(device: AudioDeviceID, name: String) {
        stopMicWatch()
        micName = name
        fallbackUnavailable = false
        lastSwitchBack = -100
        let w = MicMuteWatch(device: device) { [weak self] muted in
            MainActor.assumeIsolated { self?.mutedChanged(muted) }
        }
        muteWatch = w
        w.start()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.micTick() }
        }
        silenceTimer?.tolerance = 0.05
    }

    private func stopMicWatch() {
        muteWatch?.cancel(); muteWatch = nil
        silenceTimer?.invalidate(); silenceTimer = nil
        reportedMuted = false
        hearingSilence = false
        fallbackToken += 1
        switchingToFallback = false
        if let fb = fallback {
            fb.sink.set(nil, onLevel: nil)
            audioQueue.async { fb.release() }
            fallback = nil
            Log.note("recorder: released the built-in mic fallback")
        }
        updateMicWarning()
    }

    private func mutedChanged(_ muted: Bool) {
        guard isRecording, muteWatch != nil else { return }
        reportedMuted = muted
        updateMicWarning()
        micTick()
    }

    /// The chosen mic's sink and format: dictation's kept unit, or a normal recording's open input.
    private var primarySink: TapSink? { keepWarm ? sink : input?.sink }
    private var primaryFormat: AVAudioFormat? { keepWarm ? unit?.format : input?.unit.format }

    /// Every 0.15 s while recording. Exact digital silence for 0.6 s from the start, or for 3 s after sound was
    /// heard (a mic's noise gate can send zeros between words, so mid-recording waits longer), counts as
    /// muted; a quiet room still sends some noise. Muted moves the recording to the built-in mic; unmuted
    /// moves it back, at most once per 5 s.
    private func micTick() {
        guard isRecording, let w = writer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let fb = fallback {
            let primaryHeard = (primarySink?.lastSignalAt).map { now - $0 < 0.5 } ?? false
            if !reportedMuted, primaryHeard, now - lastSwitchBack >= 5 {
                switchBack("\(micName) is back")
            } else if now - max(fb.sink.lastSignalAt ?? 0, fallbackStartedAt) >= 1.5 {
                // The built-in mic sends nothing (lid closed, or it's off): stay on the chosen mic and just warn.
                fallbackUnavailable = true
                switchBack("\(fb.device.name) sent no sound")
            }
            return
        }
        let skip = isPaused || switchingToFallback || (!keepWarm && (isStarting || input == nil || reopening))
        let silent: Bool
        if skip {
            silent = hearingSilence && switchingToFallback
        } else if let last = w.lastSignalAt {
            silent = now - max(last, startedAt) >= 3
        } else {
            silent = now - startedAt >= 0.6
        }
        if silent != hearingSilence {
            hearingSilence = silent
            updateMicWarning()
        }
        if (reportedMuted || hearingSilence), !isPaused, !switchingToFallback, !fallbackUnavailable, !skip {
            startFallback(writer: w)
        }
    }

    /// Opens the Mac's built-in mic on the audio queue and, once it runs, points the recording at it. The
    /// chosen mic keeps running so its return is noticed. Never Bluetooth or any other external mic; with no
    /// built-in mic (or the lid closed) nothing switches and the warning stays.
    private func startFallback(writer w: RecordingWriter) {
        guard let chosen = (keepWarm ? unit?.device : input?.device.id) else { return }
        switchingToFallback = true
        fallbackToken += 1
        let mine = fallbackToken
        let certain = reportedMuted
        audioQueue.async { [weak self] in
            let open = Self.openBuiltIn(excluding: chosen)
            Task { @MainActor in
                guard let self, self.fallbackToken == mine, self.isRecording, self.writer === w, self.fallback == nil else {
                    if let open { open.sink.set(nil, onLevel: nil); DispatchQueue.global(qos: .userInitiated).async { open.release() } }
                    return
                }
                self.finishFallback(open, writer: w, certain: certain)
            }
        }
    }

    nonisolated private static func openBuiltIn(excluding chosen: AudioDeviceID) -> OpenInput? {
        guard let d = AudioDevices.builtInMic(), d.id != chosen else { return nil }
        let sink = TapSink()
        do {
            let u = try InputUnit(device: d.id) { buffer in sink.feed(buffer) }
            do { try u.prepare(); try u.start() } catch { u.dispose(); throw error }
            return OpenInput(unit: u, sink: sink, device: d)
        } catch {
            Log.note("recorder: couldn't open \(d.name) as a fallback: \(error.localizedDescription)")
            return nil
        }
    }

    private func finishFallback(_ open: OpenInput?, writer w: RecordingWriter, certain: Bool) {
        switchingToFallback = false
        guard let open else {
            fallbackUnavailable = true
            Log.note("recorder: \(micName) is \(certain ? "muted" : "silent"); no built-in mic to switch to")
            return
        }
        // Still muted? A mic unmuted while the built-in one opened stays the recording's mic.
        guard reportedMuted || hearingSilence else {
            open.sink.set(nil, onLevel: nil)
            audioQueue.async { open.release() }
            return
        }
        primarySink?.set(nil, onLevel: nil)
        guard w.replaceInput(open.unit.format) else {
            Log.note("recorder: \(open.device.name)'s format can't be converted; staying on \(micName)")
            if let pf = primaryFormat { _ = w.replaceInput(pf) }
            primarySink?.set(w, onLevel: levelHandler())
            open.sink.set(nil, onLevel: nil)
            audioQueue.async { open.release() }
            fallbackUnavailable = true
            return
        }
        open.sink.set(w, onLevel: levelHandler())
        fallback = open
        fallbackCertain = certain
        fallbackStartedAt = ProcessInfo.processInfo.systemUptime
        Log.note("recorder: switched to \(open.device.name) because \(micName) is \(certain ? "muted" : "sending only silence")")
        updateMicWarning()
    }

    /// Points the recording back at the chosen mic and releases the built-in one.
    private func switchBack(_ reason: String) {
        guard let fb = fallback, let w = writer else { return }
        fb.sink.set(nil, onLevel: nil)
        if let pf = primaryFormat, w.replaceInput(pf) {
            primarySink?.set(w, onLevel: levelHandler())
        } else {
            Log.note("recorder: couldn't point the recording back at \(micName)")
        }
        fallback = nil
        audioQueue.async { fb.release() }
        lastSwitchBack = ProcessInfo.processInfo.systemUptime
        hearingSilence = false
        Log.note("recorder: switched back to \(micName) (\(reason))")
        updateMicWarning()
    }

    private func updateMicWarning() {
        let next: MicWarning?
        if let fb = fallback { next = .usingBuiltIn(builtIn: fb.device.name, chosen: micName, certain: fallbackCertain) }
        else { next = reportedMuted ? .muted(micName) : hearingSilence ? .silent(micName) : nil }
        guard next != micWarning else { return }
        micWarning = next
        Log.note("recorder: mic warning: \(next.map { "\($0.title). \($0.detail)" } ?? "cleared")")
        onMicWarning?(next)
    }
    #endif

    private func levelHandler() -> @Sendable (Float, TimeInterval) -> Void {
        { [weak self] v, secs in
            Task { @MainActor [weak self] in self?.meter(v, seconds: secs) }
        }
    }

    /// Nothing but digital silence (or nothing at all) 2 s after start means the mic isn't delivering: asleep,
    /// muted in hardware, gone, or a stale route. A quiet speaker still sends room noise, so this never cancels
    /// someone who just hasn't spoken yet. The owner stops, releases the mic, and says so.
    /// While the Ribbon is already saying the mic seems muted, it waits until 8 s, so unmuting carries on.
    private func watchFirstSignal(_ w: RecordingWriter) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isRecording, self.writer === w, !w.heardSignal else { return }
            if self.micWarning != nil {
                Log.note("recorder: no audio 2 s after start; mic warning showing, waiting until 8 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.isRecording, self.writer === w, !w.heardSignal else { return }
                    self.noAudio(w, after: 8)
                }
                return
            }
            self.noAudio(w, after: 2)
        }
    }

    private func noAudio(_ w: RecordingWriter, after seconds: Int) {
        Log.note("recorder: no audio \(seconds) s after start (\(w.firstBufferDelay == nil ? "no buffers" : "only silence"))")
        stale = true
        if let onNoAudio { onNoAudio() } else { onInterrupted?() }
    }

    private func teardown() {
        idleTimer?.invalidate(); idleTimer = nil
        #if os(macOS)
        unwatchDevice()
        if let unit {
            sink.set(nil, onLevel: nil)
            unit.dispose()
        }
        unit = nil
        #endif
        stale = false
    }

    private func scheduleIdleRelease() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleLimit, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                Log.note("recorder: released after \(Int(Self.idleLimit / 60)) minutes unused")
                self.teardown()
            }
        }
        idleTimer?.tolerance = 30
    }

    private func willSleep() {
        guard keepWarm, !isRecording else { return }
        teardown()
    }

    private func didWake() {
        guard keepWarm, armed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.armed, !self.isRecording else { return }
            self.stale = true
            self.warmUp()
        }
    }

    // MARK: Dictation device changes

    #if os(macOS)
    /// Listens, while dictating, for the device going away or changing sample rate, and (when following the
    /// system default) for the default input changing. Any of these ends the dictation with what it has.
    private func watchDevice(_ device: AudioDeviceID) {
        unwatchDevice()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.dictationInputChanged() }
        }
        var targets: [(AudioObjectID, AudioObjectPropertySelector)] = [(device, kAudioDevicePropertyDeviceIsAlive), (device, kAudioDevicePropertyNominalSampleRate)]
        if AudioDevices.selectedInputID == nil { targets.append((AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)) }
        for (object, selector) in targets {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr { deviceWatch.append((object, addr, block)) }
        }
    }

    private func unwatchDevice() {
        for (object, addr, block) in deviceWatch {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        deviceWatch = []
    }

    private func dictationInputChanged() {
        guard keepWarm, isRecording, !deviceWatch.isEmpty else { return }
        Log.note("recorder: dictation input changed after \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt))s")
        stale = true
        unwatchDevice()   // one notice per dictation; several properties can change together
        onInterrupted?()
    }
    #endif

    // MARK: Interruptions (iPhone)

    /// A phone call or another app taking the audio session stops the engine. The recording pauses (it never
    /// silently stops while it says it's recording) and Resume continues it in the same file.
    private func observeInterruptions() {
        #if os(iOS)
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { self.autoPause("Paused for an interruption. Tap Resume to keep recording.") }
            }
        }
        #endif
    }

    private func removeInterruptionObserver() {
        #if os(iOS)
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        interruptionObserver = nil
        #endif
    }

    // MARK: Device changes

    private func observeConfiguration(of engine: AVAudioEngine) {
        removeConfigObserver()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configurationChanged() }
        }
    }

    private func removeConfigObserver() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
    }

    /// The input device changed or dropped out. The engine stops itself; a recording keeps what it has.
    private func configurationChanged() {
        guard let engine else { return }
        if isRecording {
            // Some routes post a change at start while the engine keeps running: nothing to do then.
            if engine.isRunning {
                Log.note("recorder: configuration change while running; ignored")
                return
            }
            Log.note("recorder: input changed mid-recording after \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt))s")
            stale = true
            if let onInterrupted {
                onInterrupted()
            } else if isPaused {
                // Already paused: Resume restarts capture on whatever input is there then.
                Log.note("recorder: configuration change while paused")
            } else {
                // Normal recordings: follow the new input (a new sample rate is fine, the writer converts). If that
                // can't start, pause visibly instead of recording nothing. On iPhone, let the new route settle
                // first (AirPods out, the built-in mic coming up).
                #if os(iOS)
                let delay = 0.4
                #else
                let delay = 0.0
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.isRecording, !self.isPaused, !(self.engine?.isRunning ?? false) else { return }
                    if self.restartCapture() {
                        #if os(iOS)
                        self.onInputSwitched?("Your microphone disconnected. Recording continues on \(self.currentInputName).")
                        #endif
                    } else {
                        self.autoPause("The microphone changed. Tap Resume to keep recording.")
                    }
                }
            }
        }
    }
}

/// Segment files of a long recording: "<name>.seg002.wav", "<name>.seg003.wav"… beside "<name>.wav" (segment 1).
enum RecordingSegments {
    /// A new segment every 5 minutes.
    static let seconds: Double = 300
    private static let marker = ".seg"

    static func url(for base: URL, index: Int) -> URL {
        let stem = base.deletingPathExtension().lastPathComponent
        return base.deletingLastPathComponent().appendingPathComponent("\(stem)\(marker)\(String(format: "%03d", index)).\(base.pathExtension)")
    }

    /// For "<name>.seg002.wav" (seg1000 and up too): the base URL "<name>.wav" and 2. nil for anything else.
    static func parse(_ url: URL) -> (base: URL, index: Int)? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let r = stem.range(of: marker, options: .backwards) else { return nil }
        let digits = stem[r.upperBound...]
        guard digits.count >= 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 2 else { return nil }
        let baseName = String(stem[..<r.lowerBound]) + "." + url.pathExtension
        return (url.deletingLastPathComponent().appendingPathComponent(baseName), n)
    }

    // MARK: Recordings in progress

    private static let activeLock = NSLock()
    private static var active = Set<String>()

    /// A recording being written right now (its base file name): launch recovery leaves it and its segments alone.
    static func setActive(_ base: URL, _ on: Bool) {
        activeLock.lock(); defer { activeLock.unlock() }
        if on { active.insert(base.lastPathComponent) } else { active.remove(base.lastPathComponent) }
    }

    static func isActive(_ url: URL) -> Bool {
        let name = parse(url)?.base.lastPathComponent ?? url.lastPathComponent
        activeLock.lock(); defer { activeLock.unlock() }
        return active.contains(name)
    }

    // MARK: Joining

    /// Written beside the base before a join appends anything; removed once the appended segments are deleted.
    /// If the app dies in between, `finishInterrupted` reads it at launch: a base that already holds every byte
    /// keeps them (the listed segments are deleted); otherwise the base is cut back to `originalLength` (and
    /// renamed back if it was renamed) so the segments, all still on disk, are joined again.
    struct JoinMarker: Codable {
        var base: String
        /// Sample bytes in the base before appending.
        var originalLength: UInt64
        /// Sample bytes in the base once every listed segment is appended.
        var expectedLength: UInt64
        /// Appended segments, in order.
        var segments: [String]
        /// The first part had already been adopted: this segment was renamed to `base` to start the file.
        var renamedFrom: String?
    }

    static func markerURL(for base: URL) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(".\(base.deletingPathExtension().lastPathComponent).joined")
    }

    static func writeMarker(_ m: JoinMarker, in folder: URL) throws {
        let data = try JSONEncoder().encode(m)
        try data.write(to: markerURL(for: folder.appendingPathComponent(m.base)), options: .atomic)
    }

    /// Appends segments 2… onto segment 1 (the recording's URL) in place, then deletes them. Every part is checked
    /// first (a readable WAV, all in one format); if any fails, nothing is touched. When segment 1 is missing
    /// (already adopted elsewhere), the next segment is renamed to a fresh name nobody uses (`isTaken`) and becomes
    /// the file. Returns the joined file's URL, or nil when it couldn't join (every file is then as it was).
    @discardableResult
    static func join(_ urls: [URL], isTaken: ((String) -> Bool)? = nil) -> URL? {
        let fm = FileManager.default
        guard let first = urls.first else { return nil }
        let folder = first.deletingLastPathComponent()
        let existing = urls.filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        // Check every part before changing anything. (Header repair only rewrites sizes to match the file's length.)
        var layouts: [URL: WavRepair.Layout] = [:]
        for part in existing {
            WavRepair.fixHeader(part)
            guard let l = WavRepair.layout(part) else {
                Log.note("recorder: segment \(part.lastPathComponent) unreadable; join skipped, every file kept")
                return nil
            }
            layouts[part] = l
        }
        guard Set(existing.compactMap { layouts[$0]?.format }).count == 1 else {
            Log.note("recorder: segments differ in format; join skipped"); return nil
        }

        var base = first
        var renamedFrom: URL?
        if !fm.fileExists(atPath: first.path) {
            base = uniqueURL(near: first, isTaken: isTaken)
            renamedFrom = existing[0]
        }
        let rest = Array(existing.dropFirst())
        let start = layouts[renamedFrom ?? base]!
        if rest.isEmpty && renamedFrom == nil { return base }
        let expected = rest.reduce(start.dataLength) { $0 + (layouts[$1]?.dataLength ?? 0) }
        guard start.dataOffset + expected <= UInt64(UInt32.max) else {
            Log.note("recorder: recording too long for one WAV file; segments kept"); return nil
        }
        let m = JoinMarker(base: base.lastPathComponent, originalLength: start.dataLength, expectedLength: expected,
                           segments: rest.map(\.lastPathComponent), renamedFrom: renamedFrom?.lastPathComponent)
        do { try writeMarker(m, in: folder) } catch {
            Log.note("recorder: couldn't write the join marker; join skipped"); return nil
        }
        if let from = renamedFrom {
            do { try fm.moveItem(at: from, to: base) } catch {
                try? fm.removeItem(at: markerURL(for: base))
                Log.note("recorder: couldn't rename \(from.lastPathComponent); join skipped"); return nil
            }
        }
        do {
            try append(rest, layouts: layouts, to: base, layout: start, total: expected)
        } catch {
            Log.note("recorder: join failed (\(error.localizedDescription)); rolled back, segments kept")
            rollBack(m, in: folder)
            return nil
        }
        // Every byte is in the base and on disk: now the segments can go, then the marker.
        for u in rest { try? fm.removeItem(at: u) }
        try? fm.removeItem(at: markerURL(for: base))
        return base
    }

    /// Appends each segment's sample bytes after the base's, then writes the final header sizes.
    private static func append(_ parts: [URL], layouts: [URL: WavRepair.Layout], to base: URL, layout: WavRepair.Layout, total: UInt64) throws {
        let out = try FileHandle(forUpdating: base)
        defer { try? out.close() }
        try out.truncate(atOffset: layout.dataOffset + layout.dataLength)
        try out.seekToEnd()
        for part in parts {
            guard let l = layouts[part] else { continue }
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            try input.seek(toOffset: l.dataOffset)
            var remaining = l.dataLength
            while remaining > 0 {
                guard let chunk = try input.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else {
                    throw NSError(domain: "Verbatim", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(part.lastPathComponent) ended early"])
                }
                try out.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
        try out.synchronize()
        try WavRepair.writeSizes(out, layout: layout, dataLength: total)
        try out.synchronize()
    }

    /// Puts the files back as they were before the join described by `m` started.
    private static func rollBack(_ m: JoinMarker, in folder: URL) {
        let fm = FileManager.default
        let base = folder.appendingPathComponent(m.base)
        if let l = WavRepair.layout(base), let h = try? FileHandle(forUpdating: base) {
            try? h.truncate(atOffset: l.dataOffset + min(m.originalLength, l.dataLength))
            try? WavRepair.writeSizes(h, layout: l, dataLength: min(m.originalLength, l.dataLength))
            try? h.synchronize()
            try? h.close()
        }
        if let from = m.renamedFrom, fm.fileExists(atPath: base.path) {
            try? fm.moveItem(at: base, to: folder.appendingPathComponent(from))
        }
        try? fm.removeItem(at: markerURL(for: base))
    }

    /// A join the app didn't live to finish (its marker is still there): rolls forward when the base already holds
    /// every byte, otherwise rolls back so the segments are joined again.
    static func finishInterrupted(in folder: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        for f in files where f.lastPathComponent.hasPrefix(".") && f.pathExtension == "joined" {
            guard let data = try? Data(contentsOf: f), let m = try? JSONDecoder().decode(JoinMarker.self, from: data) else {
                try? fm.removeItem(at: f); continue
            }
            let base = folder.appendingPathComponent(m.base)
            // No base: the app died before the rename (or before anything), so the segments are untouched.
            guard let l = WavRepair.layout(base) else { try? fm.removeItem(at: f); continue }
            if l.dataLength >= m.expectedLength {
                if let h = try? FileHandle(forUpdating: base) {
                    try? h.truncate(atOffset: l.dataOffset + m.expectedLength)
                    try? WavRepair.writeSizes(h, layout: l, dataLength: m.expectedLength)
                    try? h.synchronize()
                    try? h.close()
                }
                for s in m.segments { try? fm.removeItem(at: folder.appendingPathComponent(s)) }
                try? fm.removeItem(at: f)
                Log.note("recorder: finished an interrupted join of \(m.segments.count) segments")
            } else {
                rollBack(m, in: folder)
                Log.note("recorder: rolled back an interrupted join of \(m.segments.count) segments")
            }
        }
    }

    /// "<stem> 2.wav", "<stem> 3.wav"…: the first name not on disk here and not taken elsewhere.
    private static func uniqueURL(near url: URL, isTaken: ((String) -> Bool)?) -> URL {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while true {
            let u = folder.appendingPathComponent("\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: u.path), !(isTaken?(u.lastPathComponent) ?? false) { return u }
            n += 1
        }
    }

    /// Deletes a recording's segment files (and any join marker) without joining them: a discarded recording.
    static func removeSegments(of base: URL) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: base.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        where parse(f)?.base.lastPathComponent == base.lastPathComponent { try? fm.removeItem(at: f) }
        try? fm.removeItem(at: markerURL(for: base))
    }

    /// Anything for `joinLeftovers` to do: segment files (of recordings not in progress) or an unfinished join.
    static func hasLeftovers(in folder: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        return files.contains { (parse($0) != nil && !isActive($0)) || ($0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "joined") }
    }

    /// At launch, before orphaned recordings are recovered: finishes or rolls back an interrupted join, then joins
    /// leftover segments onto their first file. When the first file was already adopted (it's gone from here), the
    /// segments become a new recording under a name `isTaken` says is free. Recordings in progress are left alone.
    static func joinLeftovers(in folder: URL, isTaken: ((String) -> Bool)? = nil) {
        let fm = FileManager.default
        finishInterrupted(in: folder)
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        // Temp files from the earlier join method.
        for f in files where f.lastPathComponent.hasPrefix(".") && f.deletingPathExtension().lastPathComponent.hasSuffix(".joining") { try? fm.removeItem(at: f) }
        var groups: [URL: [(Int, URL)]] = [:]
        for f in files where !isActive(f) { if let p = parse(f) { groups[p.base, default: []].append((p.index, f)) } }
        for (base, parts) in groups {
            let ordered = [base] + parts.sorted { $0.0 < $1.0 }.map(\.1)
            let joined = join(ordered, isTaken: isTaken)
            Log.note("recorder: recovered \(parts.count + 1) segments of an interrupted recording (\(joined.map { "joined into \($0.lastPathComponent)" } ?? "join failed, kept"))")
        }
    }
}

/// A WAV whose writer never closed it (the app quit mid-recording) has zero sizes in its header, so nothing can
/// read it. This sets the RIFF and data chunk sizes from the file's length. Only touches WAV files whose
/// sizes are wrong.
enum WavRepair {
    /// Where a WAV's sample bytes start and how many there are (from the file's length, not the header, which may
    /// be stale), the offset of the data chunk's size field, and the fmt chunk's fields (to check parts match).
    struct Layout {
        var dataOffset: UInt64
        var dataLength: UInt64
        var dataSizeField: UInt64
        var format: Data
    }

    static func layout(_ url: URL) -> Layout? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let len = try? h.seekToEnd() else { return nil }
        try? h.seek(toOffset: 0)
        guard let head = try? h.read(upToCount: 65536), head.count >= 12,
              String(data: head[0..<4], encoding: .ascii) == "RIFF", String(data: head[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        func u32(_ o: Int) -> UInt32 { head[o..<o + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        var o = 12
        var fmt: Data?
        while o + 8 <= head.count {
            let id = String(data: head[o..<o + 4], encoding: .ascii) ?? ""
            let size = Int(u32(o + 4))
            if id == "fmt " {
                guard o + 8 + 16 <= head.count else { return nil }
                fmt = head.subdata(in: (o + 8)..<(o + 8 + 16))
            } else if id == "data" {
                guard let fmt else { return nil }
                let start = UInt64(o + 8)
                guard len >= start else { return nil }
                return Layout(dataOffset: start, dataLength: (len - start) & ~1, dataSizeField: UInt64(o + 4), format: fmt)
            }
            o += 8 + size + (size & 1)
        }
        return nil
    }

    /// Writes the RIFF and data chunk sizes for `dataLength` sample bytes.
    static func writeSizes(_ h: FileHandle, layout: Layout, dataLength: UInt64) throws {
        func le(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]) }
        try h.seek(toOffset: 4)
        try h.write(contentsOf: le(UInt32(clamping: layout.dataOffset + dataLength - 8)))
        try h.seek(toOffset: layout.dataSizeField)
        try h.write(contentsOf: le(UInt32(clamping: dataLength)))
    }

    static func fixHeader(_ url: URL) {
        guard url.pathExtension.lowercased() == "wav",
              let h = try? FileHandle(forUpdating: url) else { return }
        defer { try? h.close() }
        guard let len = try? h.seekToEnd(), len > 44 else { return }
        try? h.seek(toOffset: 0)
        guard let head = try? h.read(upToCount: 4096), head.count >= 12,
              String(data: head[0..<4], encoding: .ascii) == "RIFF", String(data: head[8..<12], encoding: .ascii) == "WAVE" else { return }
        func u32(_ o: Int) -> UInt32 { head[o..<o + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        func le(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]) }
        var o = 12
        while o + 8 <= head.count {
            let id = String(data: head[o..<o + 4], encoding: .ascii) ?? ""
            let size = u32(o + 4)
            if id == "data" {
                let dataStart = UInt64(o + 8)
                guard len > dataStart else { return }
                let actual = UInt32(clamping: (len - dataStart) & ~1)
                let riff = UInt32(clamping: len - 8)
                guard size != actual || u32(4) != riff else { return }
                try? h.seek(toOffset: 4); h.write(le(riff))
                try? h.seek(toOffset: UInt64(o + 4)); h.write(le(actual))
                Log.note("recorder: repaired the header of \(url.lastPathComponent)")
                return
            }
            o += 8 + Int(size) + Int(size & 1)
        }
    }
}

enum Waveform {
    /// Reads an audio file and returns `buckets` RMS values in 0…1, for thumbnails and the player track.
    static func envelope(of url: URL, buckets: Int = 120) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url) else { return [] }
        let format = f.processingFormat
        let total = Int(f.length)
        guard total > 0 else { return [] }
        let per = max(1, total / buckets)
        var out: [Float] = []
        out.reserveCapacity(buckets)
        let chunk = AVAudioFrameCount(min(per, 1 << 16))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return [] }
        var acc: Float = 0, n = 0, inBucket = 0
        while f.framePosition < f.length, out.count < buckets {
            buf.frameLength = 0
            guard (try? f.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData?[0] else { break }
            let len = Int(buf.frameLength)
            for i in 0..<len {
                acc += ch[i] * ch[i]; n += 1; inBucket += 1
                if inBucket >= per { out.append(sqrt(acc / Float(max(n, 1)))); acc = 0; n = 0; inBucket = 0 }
            }
        }
        if n > 0, out.count < buckets { out.append(sqrt(acc / Float(n))) }
        let peak = out.max() ?? 1
        return out.map { peak > 0 ? min(1, pow($0 / peak, 0.7)) : 0 }
    }

    static func resample(_ v: [Float], to n: Int) -> [Float] {
        guard !v.isEmpty else { return [] }
        guard v.count != n else { return v }
        return (0..<n).map { i in
            let a = Int(Double(i) / Double(n) * Double(v.count)), b = max(a + 1, Int(Double(i + 1) / Double(n) * Double(v.count)))
            let slice = v[a..<min(b, v.count)]
            return slice.isEmpty ? 0 : slice.max() ?? 0
        }
    }
}
