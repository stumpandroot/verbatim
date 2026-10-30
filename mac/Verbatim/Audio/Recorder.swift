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

/// Audio only's file (AudioOnly.swift, DESIGN.md §17.8): sound, not speech, so it keeps what 16 kHz cuts (everything
/// above 8 kHz: a guitar's top end, the air in a voice). The input's own rate (48 or 44.1 kHz, whatever the hardware
/// gives; a 16 or 24 kHz input such as AirPods on the call link is upsampled to 48 kHz, so the file is never below
/// 44.1 kHz), mono, 24-bit PCM in a WAV. WAV rather than AAC because it's written as it goes: a segment the app dies in
/// is repaired by fixing its header (WavRepair) and joined byte for byte (RecordingSegments), which an AAC file that
/// was never closed can't be. About 8.6 MB a minute at 48 kHz. The engines still hear 16 kHz: Transcribe later works
/// from a 16 kHz copy (TranscriptionInput).
enum SoundFormat {
    static let minimumRate: Double = 44_100
    static let fallbackRate: Double = 48_000
    static let bitDepth = 24

    /// The file's rate for an input delivering `inputRate`.
    static func rate(for inputRate: Double) -> Double { inputRate >= minimumRate ? inputRate : fallbackRate }

    /// What the writer converts to: mono float at `rate`. AVAudioFile turns it into 24-bit samples on disk.
    static func processing(rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    /// A recording kept at a sound rate: a WAV above 16 kHz. Verbose's other recordings are 16 kHz WAVs and its imports
    /// are M4A, so this is Audio only's file (even after Transcribe later), which the engines hear through a 16 kHz copy.
    static func isSoundFile(_ url: URL, rate: Double) -> Bool {
        url.pathExtension.lowercased() == "wav" && rate > recordingFormat.sampleRate
    }

    /// The file on disk: 24-bit little-endian integer PCM, mono, at `rate`.
    static func settings(rate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: bitDepth,
         AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }
}

final class RecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    /// What every buffer is converted to before it's written: `recordingFormat` (16 kHz Int16) for speech, or Audio
    /// only's mono float at the input's own rate (`SoundFormat`). Fixed for the whole recording, so every segment
    /// has the same format and they join byte for byte, whatever device the recording moves to.
    let format: AVAudioFormat
    /// Audio only: the file is `SoundFormat` (24-bit at `format`'s rate) instead of 16 kHz Int16.
    let sound: Bool
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
    private var preRollCap: Int64 { Int64(format.sampleRate * 10) }
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private var firstBufferAt: TimeInterval?
    /// Uptime of the latest buffer from the microphone, paused or not: proof the input is delivering.
    private var lastBufferAt: TimeInterval?
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
    /// A write to the file failed (usually a full disk), or new segment files couldn't be opened 3 times in a
    /// row. The writer then takes no more audio until `retryAfterFailure` opens a fresh segment, so `frames`
    /// only ever counts audio that's on disk.
    private var failed = false
    private var segmentOpenFailures = 0
    /// Called once per failure, on the audio thread, outside the lock. Recorder pauses the recording on it.
    private var onFailure: (@Sendable () -> Void)?
    func setOnFailure(_ f: (@Sendable () -> Void)?) { lock.lock(); onFailure = f; lock.unlock() }
    var writeFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    /// Audio frames on disk (pre-roll not yet written isn't counted).
    var framesWritten: Int64 { lock.lock(); defer { lock.unlock() }; return frames }
    /// Self-test only: every write that would go past this many frames fails, as on a full disk.
    var failWritesAfterFrames: Int64?

    /// `segmented`: roll to a new file every `RecordingSegments.seconds` (normal recordings, not dictation).
    /// `sound`: Audio only's format (`SoundFormat`), at the rate `inputFormat` delivers.
    init(url: URL, inputFormat: AVAudioFormat, segmented: Bool = false, sound: Bool = false) throws {
        self.sound = sound
        format = sound ? SoundFormat.processing(rate: SoundFormat.rate(for: inputFormat.sampleRate)) : recordingFormat
        file = try Self.openFile(url, format: format, sound: sound)
        converter = AVAudioConverter(from: inputFormat, to: format)
        self.inputFormat = inputFormat
        segmentLimit = segmented ? Int64(format.sampleRate * RecordingSegments.seconds) : nil
        segmentURLs = [url]
        if sound { Log.note("recorder: Audio only at \(Int(format.sampleRate)) Hz, 24-bit mono (input \(Int(inputFormat.sampleRate)) Hz)") }
    }

    /// A new file (or segment) in the recording's format.
    private static func openFile(_ url: URL, format: AVAudioFormat, sound: Bool) throws -> AVAudioFile {
        if sound { return try AVAudioFile(forWriting: url, settings: SoundFormat.settings(rate: format.sampleRate), commonFormat: .pcmFormatFloat32, interleaved: false) }
        return try AVAudioFile(forWriting: url, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    /// Converts from the first buffer and holds the audio until `attach(url:)` opens the file. Speech only (dictation).
    init(inputFormat: AVAudioFormat) throws {
        sound = false
        format = recordingFormat
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
        let f = try Self.openFile(url, format: format, sound: sound)
        lock.lock(); defer { lock.unlock() }
        for b in preRoll {
            // Only audio that reached the file counts.
            if (try? f.write(from: b)) != nil { frames += Int64(b.frameLength) }
        }
        preRoll = []; preRollFrames = 0
        holding = false
        file = f
    }

    /// Live words (`LiveTranscriber`): gets each converted mono buffer (16 kHz for speech) as it's written. Called on the
    /// audio thread, outside the lock; the buffer is freshly made for each call, so it may be kept.
    private var liveTap: (@Sendable (AVAudioPCMBuffer) -> Void)?
    func setLiveTap(_ tap: (@Sendable (AVAudioPCMBuffer) -> Void)?) { lock.lock(); liveTap = tap; lock.unlock() }

    /// Returns the perceptual level (0…1) of this buffer.
    func write(_ buffer: AVAudioPCMBuffer) -> Float {
        var tapped: AVAudioPCMBuffer?
        var tap: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var failure: (@Sendable () -> Void)?
        let v = write(buffer, tapped: &tapped, tap: &tap, failure: &failure)
        if let tapped, let tap { tap(tapped) }
        failure?()
        return v
    }

    /// Writes one converted buffer to the open file. Called with `lock` held. On an error the writer stops taking
    /// audio and hands back the failure callback for the caller to run outside the lock.
    private func append(_ out: AVAudioPCMBuffer, to file: AVAudioFile, failure: inout (@Sendable () -> Void)?) {
        do {
            if let limit = failWritesAfterFrames, frames + Int64(out.frameLength) > limit {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            }
            try file.write(from: out)
        } catch {
            fail("write failed (\(error.localizedDescription))", failure: &failure)
            return
        }
        frames += Int64(out.frameLength)
        framesInSegment += Int64(out.frameLength)
        if let limit = segmentLimit, framesInSegment >= limit { rollSegment(failure: &failure) }
    }

    private func fail(_ why: String, failure: inout (@Sendable () -> Void)?) {
        guard !failed else { return }
        failed = true
        Log.note("recorder: \(why) after \(frames) frames; taking no more audio")
        failure = onFailure
    }

    /// After a failure (Resume): continues in a fresh segment file, so whatever went wrong with the last file
    /// can't touch what's already saved. False when it still can't write.
    func retryAfterFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard failed else { return true }
        guard segmentLimit != nil, let first = segmentURLs.first else { return false }
        let next = RecordingSegments.url(for: first, index: segmentURLs.count + 1)
        guard let f = try? Self.openFile(next, format: format, sound: sound) else {
            Log.note("recorder: still can't open a new segment"); return false
        }
        if #available(macOS 15, iOS 18, *) { file?.close() }
        file = f
        segmentURLs.append(next)
        framesInSegment = 0
        segmentOpenFailures = 0
        failed = false
        Log.note("recorder: writing again in segment \(segmentURLs.count)")
        return true
    }

    private func write(_ buffer: AVAudioPCMBuffer, tapped: inout AVAudioPCMBuffer?, tap: inout (@Sendable (AVAudioPCMBuffer) -> Void)?,
                       failure: inout (@Sendable () -> Void)?) -> Float {
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
        lastBufferAt = now
        if rms > 0 { signal = true; lastSignal = now }
        guard !paused, !failed, converter != nil, file != nil || holding else { return 0 }
        // A route change (AirPods out, a new device) can change the format mid-stream: convert from the new one
        // instead of dropping it, so the file keeps one format and nothing is lost.
        if let f = inputFormat, buffer.format.sampleRate != f.sampleRate || buffer.format.channelCount != f.channelCount
            || buffer.format.commonFormat != f.commonFormat || buffer.format.isInterleaved != f.isInterleaved {
            guard let c = AVAudioConverter(from: buffer.format, to: format) else { return v }
            converter = c
            inputFormat = buffer.format
        }
        guard let converter else { return v }
        let out: AVAudioPCMBuffer
        var err: NSError?
        if buffer.format == format, let same = Self.copy(buffer) {
            // Audio only on a mono mic already at the file's rate: nothing to convert, so the samples are copied as
            // they are (the engine reuses its buffer after the callback).
            out = same
        } else {
            let ratio = format.sampleRate / buffer.format.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let made = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return v }
            var fed = false
            _ = converter.convert(to: made, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            out = made
        }
        if err == nil, out.frameLength > 0 {
            if liveTap != nil { tapped = out; tap = liveTap }
            if let file {
                append(out, to: file, failure: &failure)
            } else {
                preRoll.append(out)
                preRollFrames += Int64(out.frameLength)
                while preRollFrames > preRollCap, !preRoll.isEmpty { preRollFrames -= Int64(preRoll.removeFirst().frameLength) }
            }
        }
        envAccum += v; envCount += 1
        if envCount >= 2 { envelope.append(envAccum / Float(envCount)); envAccum = 0; envCount = 0 }
        return v
    }

    var seconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(frames + preRollFrames) / format.sampleRate }

    /// A copy of a float buffer in its own format, or nil for any other kind of buffer.
    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = b.floatChannelData, let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: max(1, b.frameLength)),
              let dst = c.floatChannelData else { return nil }
        let n = Int(b.frameLength)
        let channels = b.format.isInterleaved ? 1 : Int(b.format.channelCount)
        let perChannel = b.format.isInterleaved ? n * Int(b.format.channelCount) : n
        for ch in 0..<channels { dst[ch].update(from: src[ch], count: perChannel) }
        c.frameLength = b.frameLength
        return c
    }

    /// Opens the next segment file, then closes the current one (finalizing its header). Called with `lock`
    /// held, on the audio thread. If the next file can't be opened, keeps writing the current one and tries again
    /// a second later; after 3 failures in a row (a full disk, usually) the writer stops taking audio.
    private func rollSegment(failure: inout (@Sendable () -> Void)?) {
        framesInSegment = 0
        guard let first = segmentURLs.first else { return }
        let next = RecordingSegments.url(for: first, index: segmentURLs.count + 1)
        guard let f = try? Self.openFile(next, format: format, sound: sound) else {
            segmentOpenFailures += 1
            Log.note("recorder: couldn't open segment \(segmentURLs.count + 1) (try \(segmentOpenFailures)); continuing in the current file")
            if segmentOpenFailures >= 3 { fail("couldn't open a new segment 3 times", failure: &failure); return }
            framesInSegment = max(0, (segmentLimit ?? 0) - Int64(format.sampleRate))
            return
        }
        segmentOpenFailures = 0
        if #available(macOS 15, iOS 18, *) { file?.close() }
        file = f
        segmentURLs.append(next)
        Log.note("recorder: segment \(segmentURLs.count) started")
    }

    /// Converts from a new input format (the recording moved to a fresh engine). False if it can't be converted.
    func replaceInput(_ format: AVAudioFormat) -> Bool {
        guard let c = AVAudioConverter(from: format, to: self.format) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard converter != nil else { return false }
        converter = c
        inputFormat = format
        return true
    }

    /// A buffer arrived from the microphone that isn't written yet (the Mac's backup holds quiet audio back,
    /// MuteBackup.swift): counted as delivered, and as signal when `heard`, so the mute and no-audio checks see it now.
    func notice(heard: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if firstBufferAt == nil { firstBufferAt = now }
        lastBufferAt = now
        if heard { signal = true; lastSignal = now }
    }

    /// Whether anything but digital silence has arrived.
    var heardSignal: Bool { lock.lock(); defer { lock.unlock() }; return signal }

    /// When (system uptime) the last sound that wasn't exact digital silence arrived, or nil if none has.
    var lastSignalAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return lastSignal }

    /// When (system uptime) the latest buffer arrived from the microphone, or nil if none has.
    var latestBufferAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return lastBufferAt }

    /// Milliseconds from creating the writer to the first buffer (how long the mic took to wake), if any arrived.
    var firstBufferDelay: Int? {
        lock.lock(); defer { lock.unlock() }
        return firstBufferAt.map { Int(($0 - createdAt) * 1000) }
    }

    /// Flushes the converter (its resampler holds the last few milliseconds) and closes the file.
    func close() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if let converter, let file, !paused, !failed { drain(converter, into: file) }
        if #available(macOS 15, iOS 18, *) { file?.close() }
        file = nil; converter = nil; preRoll = []; preRollFrames = 0; holding = false; liveTap = nil; onFailure = nil
        return envelope
    }

    private func drain(_ converter: AVAudioConverter, into file: AVAudioFile) {
        for _ in 0..<8 {
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return }
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, s in s.pointee = .endOfStream; return nil }
            if err == nil, out.frameLength > 0 {
                guard (try? file.write(from: out)) != nil else { return }
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
    /// Mac: buffers go here instead of to a writer (the backup from the built-in mic, MuteBackup.swift).
    private var forward: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Writes buffers to `writer` (nil drops them). Ends any `forward`.
    func set(_ writer: RecordingWriter?, onLevel: (@Sendable (Float, TimeInterval) -> Void)?) {
        lock.lock(); self.writer = writer; self.onLevel = onLevel; forward = nil; lock.unlock()
    }

    /// Hands every buffer to `f` instead of a writer, until the next `set`.
    func setForward(_ f: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.lock(); writer = nil; onLevel = nil; forward = f; lock.unlock()
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
        let w = writer, cb = onLevel, fw = forward
        lock.unlock()
        if let fw { fw(buffer); return }
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

/// A normal recording once Stop has saved it (`Recorder.stopAndSave`).
struct StoppedRecording: Sendable {
    /// The recording's file. Usually the URL it was started with; another name when its first part couldn't be read.
    var url: URL
    var duration: TimeInterval
    var envelope: [Float]
    /// Audio frames that reached the disk. Zero means nothing was recorded at all.
    var framesWritten: Int64
    /// The segments couldn't be joined: every part stays in the recordings folder for launch recovery, and the
    /// caller must not adopt `url`.
    var joinFailed = false
    /// Parts that couldn't be read, in seconds of the recording. Silence stands in for each one.
    var skipped: [ClosedRange<Double>] = []
    /// The URL the recording was started with (where its continuation marker sits), when `url` differs.
    var startedAs: URL? = nil
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

/// What a recording does when an interruption (a call, Siri, an alarm, another app's audio) ends, and which input
/// it carries on with. Pure, so the self-tests check it on any platform.
enum InterruptionPolicy {
    /// Resume on its own only when the recording paused itself for this interruption, is still recording and
    /// paused, and iOS says resuming is appropriate (`.shouldResume`). Otherwise it stays paused for you.
    static func shouldResume(pausedForInterruption: Bool, isRecording: Bool, isPaused: Bool, systemSaysResume: Bool) -> Bool {
        pausedForInterruption && isRecording && isPaused && systemSaysResume
    }

    /// The input to pin when capture restarts: the one the recording was using, if it's still available (AirPods
    /// stay AirPods after a call); otherwise the built-in mic. Nil lets iOS choose.
    static func input(pinned: String?, available: [String], builtIn: String?) -> String? {
        if let pinned, available.contains(pinned) { return pinned }
        return builtIn
    }

    /// Whether the microphone is delivering after a resume: a buffer arrived after the resume began.
    static func delivering(resumedAt: TimeInterval, latestBuffer: TimeInterval?) -> Bool {
        guard let latestBuffer else { return false }
        return latestBuffer > resumedAt
    }

    /// How long a resumed recording may go without a buffer before it pauses again and says so.
    static let resumeCheckDelay: TimeInterval = 1.2
}

#if os(iOS)
/// The iPhone's recording session, shared by voice notes, meetings, thoughts, brain dumps, Audio only, Live captions,
/// the Live Activity's in-place recording (Recorder), and the keyboard session (KeyboardSession). The Mac never sets a
/// session. Which input a recording uses, what the chip calls it, and the mode are pure rules
/// (`RecordingInputRules`, Model/RecordingInputRules.swift); this turns them into AVAudioSession calls.
///
/// AirPods: on iOS 26 a Bluetooth input asks for the high-quality link (`bluetoothHighQualityRecording`, with HFP as
/// the fallback), which Apple documents as working only in the default mode. Build 223 asked for it with spoken audio
/// (and Audio only with measurement), then pinned whatever the route said a moment after starting and moved to the
/// iPhone's microphone on the first engine change while AirPods came up: recordings with AirPods in came from the
/// iPhone microphone. Now the input is chosen from what iOS lists and set before the session activates, the mode
/// follows the input, and a route change keeps the recording on its input while it's there.
enum RecordingRoute {
    /// The category options: Bluetooth always allowed (HFP), so AirPods are listed and can record; the high-quality
    /// link only when the plan asks for it, since it needs the default mode.
    static func options(mixWithOthers: Bool = false, highQuality: Bool = false) -> AVAudioSession.CategoryOptions {
        var o: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
        if mixWithOthers { o.insert(.mixWithOthers) }
        if highQuality, #available(iOS 26, *) { o.insert(.bluetoothHighQualityRecording) }
        return o
    }

    /// Whether this iPhone can ask for AirPods' high-quality link (iOS 26 and later).
    static var highQualityAvailable: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    static func mode(_ m: RecordingInputRules.Mode) -> AVAudioSession.Mode {
        switch m {
        case .standard: return .default
        case .spokenAudio: return .spokenAudio
        case .measurement: return .measurement
        }
    }

    /// Sets the recording category and lets haptics play while the microphone records. iOS turns haptics off when
    /// recording begins unless `allowHapticsAndSystemSoundsDuringRecording` is set before the session activates
    /// (DESIGN.md §7, Haptics), so every recording session (voice notes, thoughts, Live captions, the keyboard
    /// session) sets its category here, before `setActive(true)`.
    static func setCategory(_ s: AVAudioSession = .sharedInstance(), mode: AVAudioSession.Mode = .spokenAudio,
                            options: AVAudioSession.CategoryOptions) throws {
        try s.setCategory(.playAndRecord, mode: mode, options: options)
        allowHaptics(s)
    }

    /// Pause, resume, and mark can buzz while recording. A failure is logged, never thrown: recording matters more.
    static func allowHaptics(_ s: AVAudioSession = .sharedInstance()) {
        guard !s.allowHapticsAndSystemSoundsDuringRecording else { return }
        do { try s.setAllowHapticsAndSystemSoundsDuringRecording(true) } catch {
            Log.note("audio session: couldn't allow haptics while recording: \(error.localizedDescription)")
        }
    }

    /// Sets up the session for a recording before it activates: the category with Bluetooth allowed (and the
    /// high-quality link where it can be), so iOS lists AirPods; the input the rules pick (`chosen` is the
    /// microphone menu's pick for this recording); the mode and option that input needs; and, with `pin`, that input
    /// as the preferred one, so the session comes up on it. The keyboard session passes `pin: false` and follows
    /// whatever iOS routes to. Returns the input it picked.
    @discardableResult
    static func prepare(_ s: AVAudioSession = .sharedInstance(), soundOnly: Bool, mixWithOthers: Bool = false,
                        chosen: String?, pin: Bool = true) throws -> RecordingInput? {
        let wide = RecordingInputRules.SessionPlan(mode: highQualityAvailable ? .standard : (soundOnly ? .measurement : .spokenAudio),
                                                   highQuality: highQualityAvailable)
        try RecordingRoute.setCategory(s, mode: mode(wide.mode), options: options(mixWithOthers: mixWithOthers, highQuality: wide.highQuality))
        let available = (s.availableInputs ?? []).map(input)
        let listed = RecordingInputRules.choose(available: available, current: s.currentRoute.inputs.first?.uid, chosen: chosen)
        // AirPods playing audio whose microphone iOS hasn't listed yet (the first recording): plan for them and
        // leave the input unpinned, so the session doesn't lock onto the iPhone microphone (`RecordingInputRules.awaited`).
        let waiting = RecordingInputRules.awaited(picked: listed, available: available, bluetoothOutputs: bluetoothOutputs(s), chosen: chosen)
        awaiting = waiting
        let picked = waiting ?? listed
        let plan = RecordingInputRules.plan(for: picked, soundOnly: soundOnly, highQualityAvailable: highQualityAvailable)
        if plan != wide {
            try RecordingRoute.setCategory(s, mode: mode(plan.mode), options: options(mixWithOthers: mixWithOthers, highQuality: plan.highQuality))
        }
        if pin, waiting == nil, let picked, let port = s.availableInputs?.first(where: { $0.uid == picked.uid }) {
            try? s.setPreferredInput(port)
        } else {
            try? s.setPreferredInput(nil)
        }
        lastPlan = plan
        Log.note("audio session: \(plan.mode.rawValue) mode, high-quality AirPods \(plan.highQuality ? "asked" : "not asked"), input \(picked.map { "\($0.name) (\($0.kind.rawValue))" } ?? "iOS's choice")\(waiting != nil ? ", waiting for it to be listed" : "")\(pin ? "" : ", not pinned")")
        return picked
    }

    /// The headset the last `prepare` is waiting for (on the output, not listed as an input yet), until `confirm`
    /// finds it listed.
    private(set) static var awaiting: RecordingInput? = nil

    /// After `setActive(true)`: sets the picked input again, now that the session controls the route (iOS can
    /// ignore a preferred input set while the session is inactive). Returns the input as iOS lists it, or nil when
    /// it isn't listed (a headset `prepare` is still waiting for).
    @discardableResult
    static func confirm(_ picked: RecordingInput?, _ s: AVAudioSession = .sharedInstance()) -> RecordingInput? {
        guard let picked else { return nil }
        let ports = s.availableInputs ?? []
        guard let found = RecordingInputRules.arrived(picked, in: ports.map(input)),
              let port = ports.first(where: { $0.uid == found.uid }) else { return nil }
        if awaiting != nil {
            awaiting = nil
            Log.note("audio session: \(port.portName) listed once the session started")
        }
        if s.currentRoute.inputs.first?.uid != port.uid || s.preferredInput?.uid != port.uid { try? s.setPreferredInput(port) }
        return found
    }

    /// The Bluetooth headsets on the output, as inputs (AirPods playing audio).
    static func bluetoothOutputs(_ s: AVAudioSession = .sharedInstance()) -> [RecordingInput] {
        s.currentRoute.outputs.filter { kind($0.portType) == .bluetooth }.map(input)
    }

    /// Mid-recording (the microphone menu, or the automatic move when the recording's input goes): moves the session
    /// to the input `uid`, first changing the mode and option when the new input needs them
    /// (`RecordingInputRules.replan`). Changing the high-quality option can relist AirPods under another UID, so the
    /// port is found again by UID, then by name. Nil when the input isn't there.
    static func move(to uid: String, soundOnly: Bool, _ s: AVAudioSession = .sharedInstance()) -> RecordingInput? {
        guard let first = s.availableInputs?.first(where: { $0.uid == uid }) else { return nil }
        let wanted = input(first)
        if let plan = RecordingInputRules.replan(moving: wanted, soundOnly: soundOnly, highQualityAvailable: highQualityAvailable, current: lastPlan) {
            let mixing = s.categoryOptions.contains(.mixWithOthers)
            do {
                try RecordingRoute.setCategory(s, mode: mode(plan.mode), options: options(mixWithOthers: mixing, highQuality: plan.highQuality))
                lastPlan = plan
                Log.note("audio session: \(plan.mode.rawValue) mode, high-quality AirPods \(plan.highQuality ? "asked" : "not asked"), for \(wanted.name)")
            } catch {
                Log.note("audio session: couldn't change the mode for \(wanted.name): \(error.localizedDescription)")
            }
        }
        let ports = s.availableInputs ?? []
        guard let port = ports.first(where: { $0.uid == uid }) ?? ports.first(where: { $0.portName == wanted.name && kind($0.portType) == wanted.kind })
        else { return nil }
        try? s.setPreferredInput(port)
        return input(port)
    }

    /// The plan the last recording set up, for the self-test and the log.
    private(set) static var lastPlan: RecordingInputRules.SessionPlan? = nil

    /// A port as the rules see it.
    static func input(_ p: AVAudioSessionPortDescription) -> RecordingInput {
        RecordingInput(uid: p.uid, name: p.portName, kind: kind(p.portType))
    }

    static func kind(_ t: AVAudioSession.Port) -> RecordingInput.Kind {
        switch t {
        case .builtInMic: return .builtIn
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return .bluetooth
        case .headsetMic, .lineIn: return .wired
        case .usbAudio: return .usb
        case .carAudio: return .car
        default: return .other
        }
    }

    /// The inputs a recording could use right now, without touching the session: what iOS lists, and before the
    /// first recording (when the app's session isn't a recording session and lists no microphones) a Bluetooth
    /// headset on the output and the iPhone's microphone.
    static func knownInputs(_ s: AVAudioSession = .sharedInstance()) -> [RecordingInput] {
        let records = s.category == .playAndRecord || s.category == .record
        let listed = (s.availableInputs ?? []).map(input) + s.currentRoute.inputs.map(input)
        return RecordingInputRules.known(inputs: listed, bluetoothOutputs: bluetoothOutputs(s), sessionRecords: records)
    }

    /// The input the next recording will use (`chosen` is a pick waiting for it).
    static func nextInput(chosen: String? = nil, _ s: AVAudioSession = .sharedInstance()) -> RecordingInput? {
        RecordingInputRules.choose(available: knownInputs(s), current: s.currentRoute.inputs.first?.uid, chosen: chosen)
    }

    /// The Record card's chip at rest: "Ready · AirPods Pro", or "Ready · iPhone microphone".
    static func readyText(chosen: String? = nil) -> String { RecordingInputRules.readyText(nextInput(chosen: chosen)) }

    /// The input a running recording hears, by name ("AirPods Pro", "iPhone microphone").
    static func currentName(_ s: AVAudioSession = .sharedInstance()) -> String {
        RecordingInputRules.displayName(s.currentRoute.inputs.first.map(input) ?? nextInput(s))
    }

    /// The last route a recording started on: "AirPods Pro (BluetoothHFP) 16000 Hz, 1 ch".
    private(set) static var lastRoute: String? = nil

    /// Logs the input a recording starts on and the rate it really delivers (`format`, the input node's), so the
    /// diagnostic log shows whether AirPods came in at 16 kHz (HFP) or higher (high-quality recording).
    static func noteStart(_ context: String, format: AVAudioFormat?) {
        let s = AVAudioSession.sharedInstance()
        let input = s.currentRoute.inputs.first
        let rate = format.map { Int($0.sampleRate) } ?? Int(s.sampleRate)
        let route = "\(input?.portName ?? "no input") (\(input?.portType.rawValue ?? "-")) \(rate) Hz, \(format.map { Int($0.channelCount) } ?? s.inputNumberOfChannels) ch"
        lastRoute = route
        let available = (s.availableInputs ?? []).map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        var asked = false
        if #available(iOS 26, *) { asked = s.categoryOptions.contains(.bluetoothHighQualityRecording) }
        Log.note("\(context): recording on \(route), session \(Int(s.sampleRate)) Hz, mode \(s.mode.rawValue), high-quality AirPods asked: \(asked), available: \(available)")
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
    let live = LiveMeter()
    /// The last `stop()` couldn't join a long recording's segments. The caller must not adopt the file then:
    /// every part stays in the recordings folder, and launch recovery joins it.
    private(set) var lastJoinFailed = false
    /// Called when a normal recording pauses itself (a phone call, a microphone change it couldn't follow, or
    /// audio it can't save), with a short reason to show. Resume carries on in the same recording.
    var onAutoPaused: ((String) -> Void)?
    /// A recording's audio can't be written (a full disk): it pauses with this, and Resume tries a fresh file.
    #if os(iOS)
    static let cantSaveNotice = "Verbose can't save audio. Free up space, then tap Resume."
    #else
    static let cantSaveNotice = "Verbose can't save audio. Free up space, then click Resume."
    #endif
    /// A recording moved to another microphone on its own (the one it was using went away) and kept going.
    var onInputSwitched: ((String) -> Void)?
    #if os(iOS)
    /// Shown when a call starts: the recording pauses, and what was said stays saved.
    static let interruptionBeganNotice = "Paused for a call or another app's audio."
    /// The call ended but the microphone couldn't start again (iOS often refuses from the background).
    static let callPausedNotice = "Recording paused for a call. Open Verbose and tap Resume."
    /// The interruption ended without iOS saying to resume (another app kept the audio).
    static let audioPausedNotice = "Recording paused for another app's audio. Open Verbose and tap Resume."
    /// iOS restarted its audio services: the engine was rebuilt and the recording paused.
    static let audioRestartedNotice = "Audio restarted. Tap Resume to keep recording."
    /// Called after an interruption when the recording stays paused and needs you (it didn't resume, or it
    /// couldn't), with the notice to show. The iPhone app posts a local notification when it's in the background.
    var onNeedsAttention: ((String) -> Void)?
    /// The recording paused for an interruption or an audio restart and is waiting for you to tap Resume.
    private(set) var awaitingResume = false
    #endif
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

    /// The mic is muted, or nothing but digital silence is arriving, right now. Set within moments of the start (or
    /// of the change) and cleared as soon as it's fixed; the recording keeps going either way. On the iPhone, only
    /// `.usingBuiltIn`: a wired or USB mic went silent and the recording moved to the iPhone's microphone.
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
    /// The file this recording started as (moments marked meanwhile are written beside it, Marks.swift); nil when idle.
    var recordingURL: URL? { isRecording ? url : nil }
    private let sink = TapSink()
    /// Live words: every converted buffer of the current and later recordings goes here too (audio thread).
    /// Set it before `start`; nil stops it. The recording itself never waits on it.
    var liveTap: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        didSet { writer?.setLiveTap(liveTap) }
    }
    private var configObserver: NSObjectProtocol?
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var resetObserver: NSObjectProtocol?
    /// The recording paused itself for a call or another app's audio, so it may resume when that ends.
    private var pausedForInterruption = false
    /// The UID of the input the recording uses. Capture restarts on it while it's available.
    private var pinnedInputUID: String?
    /// The input the recorder's microphone menu picked: used by this recording (or the next one, picked before it
    /// starts) while it's there, then forgotten when the recording stops.
    @Published private(set) var chosenInputUID: String?
    /// The input `RecordingRoute.prepare` picked when this recording started.
    private var chosenInput: RecordingInput?
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
    /// Normal recordings on another mic: the built-in mic running beside it, and what decides which one reaches the
    /// file (DESIGN.md §6.10, A muted microphone, MuteBackup.swift). While muted, `fallback` is this same input.
    private var backupInput: OpenInput?
    private var muteBackup: MuteBackup?
    private var backupToken = 0
    /// The built-in mic is opening for the backup: a mute noticed meanwhile waits for it instead of opening its own.
    private var backupOpening = false
    /// Whether the backup may also call the chosen mic muted when it's near silent while the built-in mic hears speech.
    /// Off for a meeting's mic track (the other side's voices come through the Mac's speakers) and for Audio only (room
    /// sound between takes); exact silence and the device's own mute still count there.
    var comparesMics = true
    /// The recording moved to the built-in mic because it heard speech the chosen mic didn't (not exact silence),
    /// so it moves back when the chosen mic hears speech again, not at its first faint noise.
    private var fallbackByCompare = false
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

    /// Audio only (AudioOnly.swift): record sound, not speech. On iPhone the session uses the measurement mode, which
    /// turns off the system's input processing (gain control and the voice shaping the spoken-audio mode allows), so a
    /// hummed melody or a guitar keeps its dynamics. On both, the file keeps the input's own rate in 24-bit
    /// (`SoundFormat`) instead of 16 kHz. Set before `start` (or `begin`); the Mac's input unit never processes voice.
    var soundOnly = false

    func start(to url: URL) throws {
        #if os(iOS)
        // iPhone: a record session that keeps going with the screen locked (background audio mode).
        // The input is picked (AirPods over the iPhone's microphone, or the one chosen in the microphone menu) and set
        // before the session activates, with the mode it needs (RecordingRoute.prepare).
        let session = AVAudioSession.sharedInstance()
        let picked = try RecordingRoute.prepare(session, soundOnly: soundOnly, chosen: chosenInputUID)
        try session.setActive(true)
        chosenInput = RecordingRoute.confirm(picked, session)
        awaitingInput = chosenInput == nil ? RecordingRoute.awaiting : nil
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
        let w = try RecordingWriter(url: url, inputFormat: inFormat, segmented: true, sound: soundOnly)
        w.setLiveTap(liveTap)
        watchWrites(w)
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
        RecordingRoute.noteStart("recorder", format: inFormat)
        startedAt = ProcessInfo.processInfo.systemUptime
        isRecording = true
        isPaused = false
        startPhoneMuteWatch()
        #endif
    }

    #if os(iOS)
    /// Keeps a recording on the microphone it started with: AirPods connecting mid-recording don't take it over
    /// (that route switch is what froze the app). That's the input `RecordingRoute.prepare` picked (`chosenInput`),
    /// not whatever the route says a moment after starting: AirPods can still be coming up on their link then, and
    /// pinning the route's input locked the recording onto the iPhone microphone. When this input goes away, the
    /// recording moves to the best input left (`RecordingInputRules.afterRouteChange`).
    private func pinCurrentInput() {
        let s = AVAudioSession.sharedInstance()
        if let awaited = awaitingInput {
            // AirPods iOS hasn't listed yet: no pinned input, so iOS can route to them as they come up.
            try? s.setPreferredInput(nil)
            pinnedInputUID = nil
            Log.note("recorder: waiting for \(awaited.name) to be listed; iOS routes meanwhile")
            waitForAwaitedInput(afterLoss: false)
            return
        }
        let available = s.availableInputs ?? []
        let port = chosenInput.flatMap { c in available.first(where: { $0.uid == c.uid }) }
            ?? s.currentRoute.inputs.first.flatMap { cur in available.first(where: { $0.uid == cur.uid }) }
        guard let port else { return }
        try? s.setPreferredInput(port)
        pinnedInputUID = port.uid
        Log.note("recorder: recording on \(port.portName) (\(port.portType.rawValue))")
    }

    /// The recorder's microphone menu: records from `uid` for the rest of this recording, or the next one when
    /// nothing is recording. The session changes its mode first when the new input needs it (AirPods' high-quality
    /// link wants the default mode), and capture restarts on the new input (`configurationChanged`, or here when the
    /// engine keeps running on the old one). Picked while paused, capture restarts on it when you resume
    /// (`togglePause`). Returns the input the recording moved to, nil when nothing moved.
    @discardableResult
    func useInput(_ uid: String) -> RecordingInput? {
        chosenInputUID = uid
        guard isRecording, !keepWarm else { return nil }
        stopWaiting()
        guard let picked = moveRecording(to: uid) else {
            Log.note("recorder: the input you chose isn't there any more"); return nil
        }
        chosenInputUID = picked.uid
        // A pick ends a mute's move (Switch back is this pick), and the watch starts over on the new input.
        if mutedInput != nil { clearPhoneMute("you chose \(picked.name)") }
        muteSince = ProcessInfo.processInfo.systemUptime
        Log.note("recorder: you chose \(picked.name) (\(picked.kind.rawValue))")
        return picked
    }

    // MARK: Muted mic (iPhone)

    /// The wired or USB mic a mute moved the recording off (DESIGN.md §6.10, A muted microphone), until you switch back, pick another
    /// input, or it's unplugged. The iPhone records from one input at a time, so there's no backup to fill the gap:
    /// the move comes 0.6 s into a recording, or after 6 s of silence partway through (`MuteRules.phoneMidWindow`).
    @Published private(set) var mutedInput: RecordingInput?
    private var phoneMuteTimer: Timer?
    /// When the mute watch started on the current input.
    private var muteSince: TimeInterval = 0

    private func startPhoneMuteWatch() {
        phoneMuteTimer?.invalidate()
        muteSince = ProcessInfo.processInfo.systemUptime
        phoneMuteTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.phoneMuteTick() }
        }
        phoneMuteTimer?.tolerance = 0.05
    }

    private func stopPhoneMuteWatch() {
        phoneMuteTimer?.invalidate(); phoneMuteTimer = nil
        if mutedInput != nil || micWarning != nil {
            mutedInput = nil
            setMicWarning(nil)
        }
    }

    /// Every 0.25 s while recording: a wired or USB mic sending exact digital silence counts as muted, and the
    /// recording moves to the iPhone's microphone. Not while paused, or while waiting for AirPods to be listed.
    private func phoneMuteTick() {
        guard isRecording, !isPaused, let w = writer, awaitingInput == nil else { return }
        let s = AVAudioSession.sharedInstance()
        if let muted = mutedInput {
            // Unplugged while muted: there's nothing to switch back to.
            if !(s.availableInputs ?? []).contains(where: { $0.uid == muted.uid }) { clearPhoneMute("\(muted.name) was unplugged") }
            return
        }
        guard let port = s.currentRoute.inputs.first else { return }
        let current = RecordingRoute.input(port)
        guard MuteRules.watchesForMute(current.kind) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard MuteRules.silent(lastSignal: w.lastSignalAt, since: muteSince, now: now, midWindow: MuteRules.phoneMidWindow) else { return }
        guard let builtIn = (s.availableInputs ?? []).first(where: { $0.portType == .builtInMic }),
              moveRecording(to: builtIn.uid) != nil else {
            Log.note("recorder: \(current.name) sends only silence, and the iPhone microphone isn't available"); return
        }
        mutedInput = current
        muteSince = now
        Log.note("recorder: \(current.name) (\(current.kind.rawValue)) sends only silence; moved to the iPhone microphone")
        setMicWarning(.usingBuiltIn(builtIn: Self.phoneMicName, chosen: RecordingInputRules.displayName(current), certain: false))
    }

    /// Switch back in the recorder's mute banner: records from the muted mic again. Nil when it isn't there.
    @discardableResult
    func switchBackFromMute() -> RecordingInput? {
        guard let m = mutedInput else { return nil }
        return useInput(m.uid)
    }

    private func clearPhoneMute(_ reason: String) {
        mutedInput = nil
        Log.note("recorder: mute move ended (\(reason))")
        setMicWarning(nil)
    }

    static let phoneMicName = "the iPhone microphone"

    /// Moves a running recording to `uid` (the microphone menu, or AirPods coming up after a wait): the session's
    /// mode and input, then capture, when the engine keeps running on the old input. Paused, capture restarts on it
    /// when you resume. Nil when the input isn't there.
    @discardableResult
    private func moveRecording(to uid: String) -> RecordingInput? {
        guard let picked = RecordingRoute.move(to: uid, soundOnly: soundOnly, AVAudioSession.sharedInstance()) else { return nil }
        chosenInput = picked
        pinnedInputUID = picked.uid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.isRecording, !self.isPaused, let engine = self.engine, engine.isRunning,
                  AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid != picked.uid else { return }
            Log.note("recorder: restarting capture on \(picked.name)")
            if !self.restartCapture() { self.autoPause("The microphone changed. Tap Resume to keep recording.") }
        }
        return picked
    }

    /// A Bluetooth headset the recording waits for: AirPods iOS hadn't listed when it started (the first recording),
    /// or AirPods that dropped out while coming up on their link. Nil otherwise.
    private var awaitingInput: RecordingInput?
    /// Bumped when a wait starts or ends, so older looks do nothing.
    private var awaitToken = 0

    private func stopWaiting() {
        awaitingInput = nil
        awaitToken += 1
    }

    /// Looks for the awaited headset at `RecordingInputRules.awaitChecks` and moves the recording to it when iOS
    /// lists it. At the last look it settles on the best input left, with that input's mode; after a loss, it says so.
    private func waitForAwaitedInput(afterLoss: Bool) {
        awaitToken += 1
        let token = awaitToken
        let checks = RecordingInputRules.awaitChecks
        for (i, delay) in checks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.awaitToken == token else { return }
                self.checkAwaitedInput(last: i == checks.count - 1, afterLoss: afterLoss)
            }
        }
    }

    private func checkAwaitedInput(last: Bool, afterLoss: Bool) {
        guard isRecording, !keepWarm, let awaited = awaitingInput else { return }
        let available = (AVAudioSession.sharedInstance().availableInputs ?? []).map(RecordingRoute.input)
        if let arrived = RecordingInputRules.arrived(awaited, in: available) {
            stopWaiting()
            Log.note("recorder: \(arrived.name) listed; recording on it")
            moveRecording(to: arrived.uid)
            return
        }
        guard last else { return }
        stopWaiting()
        guard let rest = RecordingInputRules.afterRouteChange(pinned: nil, available: available) else { return }
        Log.note("recorder: \(awaited.name) wasn't listed; recording on \(rest.name)")
        moveRecording(to: rest.uid)
        if afterLoss {
            let name = rest.kind == .builtIn ? "the " + RecordingInputRules.builtInName : RecordingInputRules.displayName(rest)
            onInputSwitched?("Your microphone disconnected. Recording continues on \(name).")
        }
    }

    /// The route isn't on the recording's input: a microphone picked while paused, which the running engine didn't
    /// follow. Resume restarts capture then.
    private var routeOffPinnedInput: Bool {
        guard let pinned = pinnedInputUID else { return false }
        return AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid != pinned
    }

    /// Restarting capture (after a call, a route change, or Resume): the input the recording was using (AirPods
    /// stay AirPods), or the best input left only when that one is gone (`RecordingInputRules.afterRouteChange`:
    /// another accessory, then the iPhone's microphone). A move takes the new input's mode and options too
    /// (`RecordingRoute.move`, as the microphone menu does): AirPods taken out of an Audio only recording put the
    /// iPhone microphone back in measurement mode, and a voice note back in spoken audio, without the high-quality
    /// option.
    private func pinRecordingInput() {
        let s = AVAudioSession.sharedInstance()
        let available = s.availableInputs ?? []
        let inputs = available.map(RecordingRoute.input)
        // Waiting for AirPods: take them as soon as iOS lists them; until then, stay unpinned so iOS can route to them.
        if let awaited = awaitingInput {
            if let arrived = RecordingInputRules.arrived(awaited, in: inputs) {
                stopWaiting()
                Log.note("recorder: \(arrived.name) listed; recording on it")
                if let moved = RecordingRoute.move(to: arrived.uid, soundOnly: soundOnly, s) {
                    chosenInput = moved; pinnedInputUID = moved.uid
                }
            } else {
                try? s.setPreferredInput(nil)
                Log.note("recorder: still waiting for \(awaited.name)")
            }
            return
        }
        // AirPods dropping out of the list in the first seconds (coming up on their link), or while still on the
        // output, are waited for instead of trading them for the iPhone microphone for the rest of the recording.
        if let lost = chosenInput, let pinned = pinnedInputUID, !inputs.contains(where: { $0.uid == pinned }) {
            // Relisted under another UID (the high-quality link): the same headset, so stay on it.
            if let back = RecordingInputRules.arrived(lost, in: inputs), let moved = RecordingRoute.move(to: back.uid, soundOnly: soundOnly, s) {
                chosenInput = moved; pinnedInputUID = moved.uid
                Log.note("recorder: keeping \(moved.name), listed again")
                return
            }
        }
        if let lost = chosenInput, let pinned = pinnedInputUID, !inputs.contains(where: { $0.uid == pinned }),
           RecordingInputRules.waits(for: lost, secondsIn: ProcessInfo.processInfo.systemUptime - startedAt,
                                     bluetoothOutputs: RecordingRoute.bluetoothOutputs(s)) {
            awaitingInput = lost
            pinnedInputUID = nil
            try? s.setPreferredInput(nil)
            Log.note("recorder: \(lost.name) dropped out; waiting for it")
            waitForAwaitedInput(afterLoss: true)
            return
        }
        let choice = RecordingInputRules.afterRouteChange(pinned: pinnedInputUID, available: inputs)?.uid
        guard let choice, let port = available.first(where: { $0.uid == choice }) else {
            try? s.setPreferredInput(nil)
            Log.note("recorder: no input to pin; iOS chooses")
            pinnedInputUID = nil
            return
        }
        guard choice != pinnedInputUID else {
            try? s.setPreferredInput(port)
            Log.note("recorder: keeping \(port.portName)")
            return
        }
        Log.note("recorder: the recording's input is gone; using \(port.portName)")
        if let moved = RecordingRoute.move(to: choice, soundOnly: soundOnly, s) {
            chosenInput = moved
            pinnedInputUID = moved.uid
        } else {
            try? s.setPreferredInput(port)
            pinnedInputUID = choice
        }
    }

    private var currentInputName: String {
        let name = RecordingRoute.currentName()
        return name == RecordingInputRules.builtInName ? "the " + name : name
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

    /// Pauses the recording the moment its audio can't be written, so it never looks like it's recording
    /// while nothing is saved.
    private func watchWrites(_ w: RecordingWriter) {
        w.setOnFailure { [weak self, weak w] in
            Task { @MainActor in
                guard let self, let w, self.writer === w, self.isRecording else { return }
                self.autoPause(Self.cantSaveNotice)
            }
        }
    }

    func togglePause() {
        #if os(iOS)
        pausedForInterruption = false
        #endif
        // Resuming after audio couldn't be written: carry on in a fresh segment file, or stay paused.
        if isPaused, !keepWarm, let w = writer, w.writeFailed {
            guard w.retryAfterFailure() else { onAutoPaused?(Self.cantSaveNotice); return }
        }
        #if os(macOS)
        if !keepWarm {
            guard isRecording, !isStarting, !reopening else { return }
            // Resuming after the microphone went away: reopen it (off the main thread), then resume.
            if isPaused, input == nil { reopen(resuming: true); return }
        }
        #endif
        // Resuming after the recorder paused itself (a call, a device change): the engine stopped, start it again
        // on the input the recording was using, if it's still there. iPhone: also when you picked a microphone while
        // paused and the engine kept running on the old one.
        #if os(iOS)
        let moveOnResume = isPaused && !keepWarm && routeOffPinnedInput
        #else
        let moveOnResume = false
        #endif
        if isPaused, !keepWarm, let engine, !engine.isRunning || moveOnResume {
            if engine.isRunning { Log.note("recorder: resuming on the microphone you picked while paused") }
            guard restartCapture() else {
                Log.note("recorder: couldn't resume; still paused")
                onAutoPaused?("Couldn't restart the microphone. Stop to keep what was recorded.")
                return
            }
        }
        isPaused.toggle()
        #if os(macOS)
        // Quiet audio the backup held back belongs before the pause.
        if isPaused { muteBackup?.flush() }
        #endif
        writer?.paused = isPaused
        if isPaused { live.reset(); live.setElapsed(writer?.seconds ?? 0) }
        #if os(iOS)
        if !isPaused, awaitingResume { awaitingResume = false; Log.note("recorder: resumed by you after an interruption") }
        if !isPaused { muteSince = ProcessInfo.processInfo.systemUptime }
        #endif
    }

    /// Pauses a normal recording on the recorder's own initiative; what was recorded stays, Resume continues it.
    private func autoPause(_ reason: String) {
        guard isRecording, !keepWarm else { return }
        if !isPaused {
            isPaused = true
            #if os(macOS)
            muteBackup?.flush()
            #endif
            writer?.paused = true
            live.reset(); live.setElapsed(writer?.seconds ?? 0)
        }
        Log.note("recorder: paused itself (\(reason))")
        onAutoPaused?(reason)
    }

    /// Normal recordings: points the tap at the input's current format (a new device, a new sample rate) and
    /// starts the engine again. The writer converts whatever arrives, so the file keeps one format.
    /// iPhone: it stays on the input the recording was using while it's available (after a call, after AirPods come
    /// up on their high-quality link), and moves to the best input left only when that one is gone.
    private func restartCapture() -> Bool {
        guard !keepWarm, var engine, let w = writer else { return false }
        #if os(iOS)
        RecordingRoute.allowHaptics()
        do { try AVAudioSession.sharedInstance().setActive(true) } catch {
            Log.note("recorder: couldn't activate the audio session: \(error.localizedDescription)")
        }
        pinRecordingInput()
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
        guard engine.isRunning else { Log.note("recorder: restart returned but the engine isn't running"); return false }
        Log.note("recorder: capture restarted at \(Int(format.sampleRate)) Hz")
        #if os(iOS)
        // The new engine's first audio is moments away: the mute watch starts over, so the silence before it (a call,
        // a pause) isn't counted against the mic.
        muteSince = ProcessInfo.processInfo.systemUptime
        #endif
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
        var out = url
        if parts.count > 1 {
            if let joined = RecordingSegments.join(parts) {
                out = joined.url
                Log.note("recorder: joined \(parts.count) segments\(joined.skipped.isEmpty ? "" : ", \(joined.skipped.count) unreadable")")
            } else {
                lastJoinFailed = true
                Log.note("recorder: couldn't join \(parts.count) segments; all kept for recovery at next launch")
            }
        }
        RecordingSegments.setActive(url, false)
        Log.note("recorder: stopped \(String(format: "%.2f", d))s, first audio \(firstDelay.map { "\($0) ms" } ?? "never") after start, warm=\(keepWarm)")
        finishStop()
        return (out, d, env)
    }

    /// Stop for normal recordings: capture ends at once (the recorder is free and `isRecording` is false), then a
    /// long recording's segments are joined off the main thread, so the app stays responsive however long it ran.
    /// Until the join is done the files stay marked in progress; if the app dies meanwhile, the join marker and
    /// launch recovery finish the job. Nil when nothing was recording (or Stop cancelled a start).
    func stopAndSave() async -> StoppedRecording? {
        lastJoinFailed = false
        #if os(macOS)
        if isStarting { cancelStart(); return nil }
        #endif
        guard let (w, url) = endCapture() else { return nil }
        lastHeardSignal = w.heardSignal
        let env = Waveform.resample(w.close(), to: 120)   // close() flushes the converter's last frames first
        var result = StoppedRecording(url: url, duration: w.seconds, envelope: env, framesWritten: w.framesWritten)
        let parts = w.segments
        Log.note("recorder: stopped \(String(format: "%.2f", result.duration))s in \(parts.count) part\(parts.count == 1 ? "" : "s"), \(w.writeFailed ? "after a write failure" : "all written")")
        finishStop()
        if parts.count > 1 {
            let joined = await Task.detached(priority: .userInitiated) { RecordingSegments.join(parts) }.value
            if let joined {
                if joined.url != url { result.startedAs = url }
                result.url = joined.url
                result.skipped = joined.skipped
                result.duration = joined.seconds
                Log.note("recorder: joined \(parts.count) segments in the background\(joined.skipped.isEmpty ? "" : ", \(joined.skipped.count) unreadable")")
            } else {
                result.joinFailed = true
                Log.note("recorder: couldn't join \(parts.count) segments; all kept for recovery at next launch")
            }
        }
        RecordingSegments.setActive(url, false)
        lastJoinFailed = result.joinFailed
        return result
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
        pausedForInterruption = false
        awaitingResume = false
        pinnedInputUID = nil
        chosenInputUID = nil
        chosenInput = nil
        stopWaiting()
        stopPhoneMuteWatch()
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
        let sound = soundOnly
        audioQueue.async { [weak self] in
            let result = Self.openInput(newFileAt: url, continuing: nil, sound: sound, levels: levels, probe: probe)
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
            done?(RecorderError("Couldn't start \(Self.micPhrase(probe.name)). It didn't respond within \(Int(Self.startLimit)) seconds. Check that it's connected, or choose another mic in Settings › Recording and transcription › Record from."))
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
                                              sound: Bool = false, levels: @escaping @Sendable (Float, TimeInterval) -> Void,
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
                w = try RecordingWriter(url: url, inputFormat: u.format, segmented: true, sound: sound)
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
            watchWrites(w)
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
    /// moves the recording to the Mac's built-in mic until the chosen one is back. A normal recording on another
    /// mic also opens the built-in mic beside it as a backup (`startBackup`), so the move loses nothing.
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
        if !keepWarm { startBackup(beside: device) }
    }

    private func stopMicWatch() {
        muteWatch?.cancel(); muteWatch = nil
        silenceTimer?.invalidate(); silenceTimer = nil
        reportedMuted = false
        hearingSilence = false
        fallbackToken += 1
        switchingToFallback = false
        fallbackByCompare = false
        if let fb = fallback, fb !== backupInput {
            fb.sink.set(nil, onLevel: nil)
            audioQueue.async { fb.release() }
            Log.note("recorder: released the built-in mic fallback")
        }
        fallback = nil
        stopBackup()
        updateMicWarning()
    }

    // MARK: Backup from the built-in mic

    /// Normal recordings on a mic other than the built-in one: opens the built-in mic on the audio queue and, once it
    /// runs, routes both mics through a `MuteBackup` (DESIGN.md §6.10, A muted microphone). Never Bluetooth or any other mic. Not with
    /// Settings › Back up a muted mic off, and not after the recording moved to the built-in mic for good.
    private func startBackup(beside chosen: AudioDeviceID) {
        guard MuteRules.backupEnabled(.standard), !stayOnBuiltIn, let open = input, open.device.id == chosen, writer != nil else { return }
        backupToken += 1
        let mine = backupToken
        backupOpening = true
        // A built-in mic that doesn't answer never holds up a mute's other response.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startLimit) { [weak self] in
            guard let self, self.backupToken == mine, self.backupOpening else { return }
            self.backupOpening = false
            Log.note("recorder: the built-in mic didn't open for the backup within \(Int(Self.startLimit)) s")
        }
        audioQueue.async { [weak self] in
            let builtIn = Self.openBuiltIn(excluding: chosen)
            Task { @MainActor in
                if self?.backupToken == mine { self?.backupOpening = false }
                guard let self, self.backupToken == mine, self.isRecording, let w = self.writer, let primary = self.input,
                      primary === open, self.fallback == nil, !self.switchingToFallback, let builtIn else {
                    if let builtIn { builtIn.sink.set(nil, onLevel: nil); DispatchQueue.global(qos: .userInitiated).async { builtIn.release() } }
                    return
                }
                let b = MuteBackup(writer: w, onLevel: self.levelHandler())
                self.muteBackup = b
                self.backupInput = builtIn
                builtIn.sink.setForward { buffer in b.backup(buffer) }
                primary.sink.setForward { buffer in b.primary(buffer) }
                Log.note("recorder: backing up \(self.micName) with \(builtIn.device.name)")
            }
        }
    }

    /// Writes what the backup held, points the chosen mic straight at the writer again, and releases the built-in mic.
    private func stopBackup() {
        backupToken += 1
        backupOpening = false
        guard let b = muteBackup else { return }
        b.detach()
        if let w = writer, let primary = input { primary.sink.set(w, onLevel: levelHandler()) }
        muteBackup = nil
        if let open = backupInput {
            open.sink.set(nil, onLevel: nil)
            audioQueue.async { open.release() }
        }
        backupInput = nil
        Log.note("recorder: stopped the backup from the built-in mic")
    }

    /// The chosen mic is muted (`certain`), silent, or quiet while the built-in mic hears speech (`byCompare`): the
    /// backup's audio replaces what was held, and the recording carries on from the built-in mic.
    private func useBackup(certain: Bool, byCompare: Bool) {
        guard let b = muteBackup, let open = backupInput, fallback == nil else { return }
        b.useBackup()
        fallback = open
        fallbackCertain = certain
        fallbackByCompare = byCompare
        fallbackStartedAt = ProcessInfo.processInfo.systemUptime
        Log.note("recorder: switched to \(open.device.name) because \(micName) is \(certain ? "muted" : byCompare ? "quiet while the built-in mic hears speech" : "sending only silence")")
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
    /// muted; a quiet room still sends some noise (`MuteRules.silent`). With the backup running, so does the chosen
    /// mic staying quiet while the built-in mic hears speech (`MuteRules.mutedByComparison`). Muted moves the
    /// recording to the built-in mic; unmuted moves it back, at most once per 5 s.
    private func micTick() {
        guard isRecording, let w = writer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let fb = fallback {
            // After a comparison the chosen mic still sends faint noise, so it's back when it hears speech again.
            let primaryHeard = fallbackByCompare
                ? (muteBackup?.status.primaryLoudAt).map { now - $0 < 0.5 } ?? false
                : (primarySink?.lastSignalAt).map { now - $0 < 0.5 } ?? false
            if !reportedMuted, primaryHeard, now - lastSwitchBack >= 5 {
                switchBack("\(micName) is back")
            } else if now - max(fb.sink.lastSignalAt ?? 0, fallbackStartedAt) >= 1.5 {
                // The built-in mic sends nothing (lid closed, or it's off): stay on the chosen mic and just warn.
                fallbackUnavailable = true
                switchBack("\(fb.device.name) sent no sound")
                // Nothing to back up with: release it, so the chosen mic's audio isn't held for nothing.
                if muteBackup != nil { stopBackup() }
            }
            return
        }
        let skip = isPaused || switchingToFallback || (!keepWarm && (isStarting || input == nil || reopening))
        let silent: Bool
        if skip {
            silent = hearingSilence && switchingToFallback
        } else {
            silent = MuteRules.silent(lastSignal: w.lastSignalAt, since: startedAt, now: now)
        }
        if silent != hearingSilence {
            hearingSilence = silent
            updateMicWarning()
        }
        guard !isPaused, !switchingToFallback, !fallbackUnavailable, !skip, !backupOpening else { return }
        if reportedMuted || hearingSilence {
            if muteBackup != nil { useBackup(certain: reportedMuted, byCompare: false) } else { startFallback(writer: w) }
        } else if comparesMics, !soundOnly, let st = muteBackup?.status,
                  MuteRules.mutedByComparison(heldSeconds: st.heldSeconds, backupSpeechSeconds: st.backupSpeechSeconds) {
            useBackup(certain: false, byCompare: true)
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
        if fb === backupInput, let b = muteBackup {
            // The backup keeps running for the next mute; only what reaches the file changes.
            b.usePrimary()
            fallback = nil
            fallbackByCompare = false
            lastSwitchBack = ProcessInfo.processInfo.systemUptime
            hearingSilence = false
            Log.note("recorder: switched back to \(micName) (\(reason))")
            updateMicWarning()
            return
        }
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
        setMicWarning(next)
    }
    #endif

    /// Sets `micWarning` and tells `onMicWarning`, when it changed.
    private func setMicWarning(_ next: MicWarning?) {
        guard next != micWarning else { return }
        micWarning = next
        Log.note("recorder: mic warning: \(next.map { "\($0.title). \($0.detail)" } ?? "cleared")")
        onMicWarning?(next)
    }

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
    /// silently stops while it says it's recording) and keeps what was said.
    ///
    /// When the interruption ends, the recording resumes on its own only if iOS says to (`.shouldResume`), on the
    /// input it was using. If it can't (no `.shouldResume`, the engine won't start, or no audio arrives within a
    /// second, as when iOS refuses the microphone in the background), it stays paused, says so, and calls
    /// `onNeedsAttention`, so the iPhone app can post a notification. Every step is logged for device diagnosis.
    private func observeInterruptions() {
        #if os(iOS)
        removeInterruptionObserver()
        let session = AVAudioSession.sharedInstance()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let reasonRaw = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            Task { @MainActor in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    self.interruptionBegan(reason: reasonRaw)
                } else if type == .ended {
                    self.interruptionEnded(options: AVAudioSession.InterruptionOptions(rawValue: optionsRaw))
                }
            }
        }
        resetObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesReset() }
        }
        #endif
    }

    private func removeInterruptionObserver() {
        #if os(iOS)
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        if let o = resetObserver { NotificationCenter.default.removeObserver(o) }
        interruptionObserver = nil
        resetObserver = nil
        #endif
    }

    #if os(iOS)
    private func interruptionBegan(reason: UInt?) {
        let wasPaused = isPaused
        Log.note("recorder: interruption began (recording \(isRecording), paused \(wasPaused), reason \(reason.map { String($0) } ?? "none"))")
        guard isRecording, !keepWarm else { return }
        autoPause(Self.interruptionBeganNotice)
        pausedForInterruption = !wasPaused && isPaused
    }

    private func interruptionEnded(options: AVAudioSession.InterruptionOptions) {
        let systemSaysResume = options.contains(.shouldResume)
        Log.note("recorder: interruption ended (shouldResume \(systemSaysResume), paused for it \(pausedForInterruption), recording \(isRecording), paused \(isPaused))")
        guard pausedForInterruption else { return }
        let resume = InterruptionPolicy.shouldResume(pausedForInterruption: pausedForInterruption, isRecording: isRecording,
                                                     isPaused: isPaused, systemSaysResume: systemSaysResume)
        pausedForInterruption = false
        guard resume else {
            Log.note("recorder: staying paused; iOS didn't say to resume")
            needsAttention(Self.audioPausedNotice)
            return
        }
        // Let the call's audio route settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard self.isRecording, self.isPaused else {
                Log.note("recorder: not resuming; already resumed or stopped")
                return
            }
            self.resumeAfterInterruption()
        }
    }

    /// Restarts capture on the recording's own input, then checks that audio arrives. Stays paused, says so, and
    /// asks for attention when either fails.
    private func resumeAfterInterruption() {
        Log.note("recorder: resuming after the interruption")
        if let w = writer, w.writeFailed, !w.retryAfterFailure() {
            autoPause(Self.cantSaveNotice); return
        }
        let began = ProcessInfo.processInfo.systemUptime
        guard engine != nil, restartCapture() else {
            Log.note("recorder: couldn't restart capture after the interruption; staying paused")
            needsAttention(Self.callPausedNotice)
            return
        }
        isPaused = false
        writer?.paused = false
        awaitingResume = false
        Log.note("recorder: resumed; waiting for audio")
        let w = writer
        DispatchQueue.main.asyncAfter(deadline: .now() + InterruptionPolicy.resumeCheckDelay) { [weak self] in
            guard let self, let w, self.isRecording, !self.isPaused, self.writer === w else { return }
            if InterruptionPolicy.delivering(resumedAt: began, latestBuffer: w.latestBufferAt) {
                Log.note("recorder: audio is arriving after the resume")
                self.onInputSwitched?("Recording resumed.")
            } else {
                Log.note("recorder: no audio within \(InterruptionPolicy.resumeCheckDelay) s of the resume; pausing")
                self.engine?.stop()
                self.needsAttention(Self.callPausedNotice)
            }
        }
    }

    /// iOS restarted its audio services (rare: the media server crashed). Every audio object is invalid: the
    /// engine is rebuilt and the session set up again. A recording pauses with its segments intact; Resume
    /// continues it on the fresh engine.
    private func mediaServicesReset() {
        Log.note("recorder: media services were reset (recording \(isRecording), paused \(isPaused))")
        guard !keepWarm else { return }
        if let old = engine {
            old.inputNode.removeTap(onBus: 0)
            old.stop()
        }
        removeConfigObserver()
        guard isRecording, writer != nil else { engine = nil; tapFormat = nil; return }
        let s = AVAudioSession.sharedInstance()
        do {
            let picked = try RecordingRoute.prepare(s, soundOnly: soundOnly, chosen: pinnedInputUID ?? chosenInputUID)
            try s.setActive(true)
            if let found = RecordingRoute.confirm(picked, s) {
                chosenInput = found; pinnedInputUID = found.uid
            } else if let waiting = RecordingRoute.awaiting {
                awaitingInput = waiting; pinnedInputUID = nil
                waitForAwaitedInput(afterLoss: false)
            }
            Log.note("recorder: audio session set up again")
        } catch {
            Log.note("recorder: couldn't set up the audio session again: \(error.localizedDescription)")
        }
        let fresh = AVAudioEngine()
        engine = fresh
        observeConfiguration(of: fresh)
        pausedForInterruption = false
        needsAttention(Self.audioRestartedNotice)
    }

    /// The recording stays paused and needs you: it pauses (if it isn't already) with this reason, and the
    /// owner is told so it can notify you.
    private func needsAttention(_ reason: String) {
        guard isRecording else { return }
        awaitingResume = true
        autoPause(reason)
        onNeedsAttention?(reason)
    }
    #endif

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
                #if os(iOS)
                let before = pinnedInputUID
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.isRecording, !self.isPaused, !(self.engine?.isRunning ?? false) else { return }
                    // iPhone: stay on the recording's input while it's there (AirPods coming up on their high-quality
                    // link change the engine's format, which used to move the recording to the iPhone microphone),
                    // and move only when it's gone.
                    if self.restartCapture() {
                        #if os(iOS)
                        if let before, self.pinnedInputUID != before, self.awaitingInput == nil {
                            self.onInputSwitched?("Your microphone disconnected. Recording continues on \(self.currentInputName).")
                        }
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
        /// Parts that couldn't be read (silence stands in for them): set aside once the join is done, so they're
        /// never joined again but never deleted either.
        var unreadable: [String]? = nil
    }

    /// What `join` made: the file, the parts it couldn't read, and the joined length.
    struct JoinResult: Sendable {
        var url: URL
        /// Unreadable parts as seconds of the recording (from where they'd start to where they'd end).
        var skipped: [ClosedRange<Double>]
        var seconds: Double
    }

    /// A piece of the joined file: a readable segment's samples, or zeros where an unreadable one was.
    private enum Piece {
        case audio(URL)
        case silence(UInt64)
    }

    static func markerURL(for base: URL) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(".\(base.deletingPathExtension().lastPathComponent).joined")
    }

    static func writeMarker(_ m: JoinMarker, in folder: URL) throws {
        let data = try JSONEncoder().encode(m)
        try data.write(to: markerURL(for: folder.appendingPathComponent(m.base)), options: .atomic)
    }

    /// Appends segments 2… onto segment 1 (the recording's URL) in place, then deletes them. Every part is checked
    /// first. A part that can't be read (or isn't in the recording's format) never strands the parts after it:
    /// silence as long as its file stands in for it (so the times after it still line up), its range is reported
    /// in `skipped`, and the file is set aside under an "Unreadable …" name, never deleted. When segment 1 is
    /// missing (already adopted elsewhere) or unreadable, the first readable segment is renamed to a fresh name
    /// nobody uses (`isTaken`) and becomes the file. Nil when it couldn't join at all (no part readable, or the
    /// disk work failed and was rolled back): every file is then as it was.
    @discardableResult
    static func join(_ urls: [URL], isTaken: ((String) -> Bool)? = nil) -> JoinResult? {
        let fm = FileManager.default
        guard let first = urls.first else { return nil }
        let folder = first.deletingLastPathComponent()
        let existing = urls.filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        // Check every part before changing anything. (Header repair only rewrites sizes to match the file's length.)
        var layouts: [URL: WavRepair.Layout] = [:]
        for part in existing {
            WavRepair.fixHeader(part)
            if let l = WavRepair.layout(part) { layouts[part] = l }
            else { Log.note("recorder: segment \(part.lastPathComponent) unreadable; joining the rest around it") }
        }
        // The first readable part sets the format; a part in any other format can't be appended byte for byte.
        guard let startPart = existing.first(where: { layouts[$0] != nil }), let start = layouts[startPart] else {
            Log.note("recorder: no part of \(first.lastPathComponent) is readable; every file kept"); return nil
        }
        for part in existing where layouts[part].map({ $0.format != start.format }) ?? false {
            Log.note("recorder: segment \(part.lastPathComponent) is in another format; joining the rest around it")
            layouts[part] = nil
        }
        let byteRate = Double(max(1, start.byteRate))
        let align = UInt64(max(1, start.blockAlign))

        // Lay out the recording: each part's place in time, and what goes into the joined file for it.
        var pieces: [Piece] = []
        var skipped: [ClosedRange<Double>] = []
        var unreadable: [URL] = []
        var at: Double = 0
        let startIndex = existing.firstIndex(of: startPart)!
        for (i, part) in existing.enumerated() {
            if let l = layouts[part] {
                if i > startIndex { pieces.append(.audio(part)) }
                at += Double(l.dataLength) / byteRate
                continue
            }
            // Unreadable: as long as its file says (less a WAV header), rounded to whole frames.
            let size = (try? fm.attributesOfItem(atPath: part.path)[.size] as? UInt64) ?? 0
            let bytes = (size > 44 ? size - 44 : 0) / align * align
            let seconds = Double(bytes) / byteRate
            skipped.append(at...(at + seconds))
            unreadable.append(part)
            // Before the first readable part there's nothing to put silence in front of; after it, silence keeps
            // the later parts at their times.
            if i > startIndex, bytes > 0 { pieces.append(.silence(bytes)) }
            at += seconds
        }

        var base = first
        var renamedFrom: URL?
        if startPart != first {
            base = uniqueURL(near: first, isTaken: isTaken)
            renamedFrom = startPart
        }
        let appended = pieces.compactMap { if case .audio(let u) = $0 { return u } else { return nil } }
        let expected = pieces.reduce(start.dataLength) { total, p in
            switch p {
            case .audio(let u): return total + (layouts[u]?.dataLength ?? 0)
            case .silence(let n): return total + n
            }
        }
        let seconds = Double(expected) / byteRate
        if pieces.isEmpty && renamedFrom == nil && unreadable.isEmpty { return JoinResult(url: base, skipped: [], seconds: seconds) }
        guard start.dataOffset + expected <= UInt64(UInt32.max) else {
            Log.note("recorder: recording too long for one WAV file; segments kept"); return nil
        }
        let m = JoinMarker(base: base.lastPathComponent, originalLength: start.dataLength, expectedLength: expected,
                           segments: appended.map(\.lastPathComponent), renamedFrom: renamedFrom?.lastPathComponent,
                           unreadable: unreadable.isEmpty ? nil : unreadable.map(\.lastPathComponent))
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
            try append(pieces, layouts: layouts, to: base, layout: start, total: expected)
        } catch {
            Log.note("recorder: join failed (\(error.localizedDescription)); rolled back, segments kept")
            rollBack(m, in: folder)
            return nil
        }
        // Every byte is in the base and on disk: now the segments can go, the unreadable ones are set aside, and
        // then the marker goes.
        for u in appended { try? fm.removeItem(at: u) }
        for u in unreadable { setAside(u) }
        try? fm.removeItem(at: markerURL(for: base))
        return JoinResult(url: base, skipped: skipped, seconds: seconds)
    }

    /// Keeps a part that can't be read out of every later join and out of recovery, without deleting it:
    /// "Unreadable <name>.bin" in the same folder.
    static func setAside(_ part: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: part.path) else { return }
        let folder = part.deletingLastPathComponent()
        var dest = folder.appendingPathComponent("Unreadable \(part.lastPathComponent).bin")
        if fm.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("Unreadable \(part.lastPathComponent) \(UUID().uuidString.prefix(4)).bin") }
        do { try fm.moveItem(at: part, to: dest); Log.note("recorder: set aside unreadable \(part.lastPathComponent)") }
        catch { Log.note("recorder: couldn't set aside \(part.lastPathComponent): \(error.localizedDescription)") }
    }

    /// Appends each piece after the base's samples (a segment's sample bytes, or zeros), then writes the final
    /// header sizes.
    private static func append(_ pieces: [Piece], layouts: [URL: WavRepair.Layout], to base: URL, layout: WavRepair.Layout, total: UInt64) throws {
        let out = try FileHandle(forUpdating: base)
        defer { try? out.close() }
        try out.truncate(atOffset: layout.dataOffset + layout.dataLength)
        try out.seekToEnd()
        for piece in pieces {
            let part: URL
            switch piece {
            case .silence(let n):
                var remaining = n
                let zeros = Data(count: Int(min(n, 1 << 20)))
                while remaining > 0 {
                    let k = Int(min(remaining, UInt64(zeros.count)))
                    try out.write(contentsOf: k == zeros.count ? zeros : zeros.prefix(k))
                    remaining -= UInt64(k)
                }
                continue
            case .audio(let u): part = u
            }
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
                for s in m.unreadable ?? [] { setAside(folder.appendingPathComponent(s)) }
                try? fm.removeItem(at: f)
                Log.note("recorder: finished an interrupted join of \(m.segments.count) segments")
            } else {
                rollBack(m, in: folder)
                Log.note("recorder: rolled back an interrupted join of \(m.segments.count) segments")
            }
        }
    }

    /// "<stem> 2.wav", "<stem> 3.wav"…: the first name not on disk here and not taken elsewhere. With `tryPlain`,
    /// `url` itself comes first.
    private static func uniqueURL(near url: URL, isTaken: ((String) -> Bool)?, tryPlain: Bool = false) -> URL {
        let fm = FileManager.default
        if tryPlain, !fm.fileExists(atPath: url.path), !(isTaken?(url.lastPathComponent) ?? false) { return url }
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
    /// Parts that still can't be joined become recordings of their own ("<name> part 3.wav"), so recovery
    /// surfaces each one. Returns the unreadable ranges of each joined file, by file name.
    @discardableResult
    static func joinLeftovers(in folder: URL, isTaken: ((String) -> Bool)? = nil) -> [String: [ClosedRange<Double>]] {
        var skipped: [String: [ClosedRange<Double>]] = [:]
        let fm = FileManager.default
        finishInterrupted(in: folder)
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        // Temp files from the earlier join method.
        for f in files where f.lastPathComponent.hasPrefix(".") && f.deletingPathExtension().lastPathComponent.hasSuffix(".joining") { try? fm.removeItem(at: f) }
        var groups: [URL: [(Int, URL)]] = [:]
        for f in files where !isActive(f) { if let p = parse(f) { groups[p.base, default: []].append((p.index, f)) } }
        for (base, parts) in groups {
            let sorted = parts.sorted { $0.0 < $1.0 }
            let ordered = [base] + sorted.map(\.1)
            let joined = join(ordered, isTaken: isTaken)
            Log.note("recorder: recovered \(parts.count + 1) segments of an interrupted recording (\(joined.map { "joined into \($0.url.lastPathComponent)" } ?? "join failed"))")
            if let joined {
                if !joined.skipped.isEmpty { skipped[joined.url.lastPathComponent] = joined.skipped }
                continue
            }
            // Still can't be joined: each readable part becomes its own recording; unreadable ones are set aside.
            for (index, part) in sorted where fm.fileExists(atPath: part.path) {
                guard WavRepair.layout(part) != nil else { setAside(part); continue }
                let stem = base.deletingPathExtension().lastPathComponent
                let dest = uniqueURL(near: folder.appendingPathComponent("\(stem) part \(index).\(part.pathExtension)"), isTaken: isTaken, tryPlain: true)
                do { try fm.moveItem(at: part, to: dest); Log.note("recorder: kept \(part.lastPathComponent) as \(dest.lastPathComponent)") }
                catch { Log.note("recorder: couldn't rename \(part.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        return skipped
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
        /// From the fmt chunk: bytes per second, and bytes per frame (all channels).
        var byteRate: UInt32 { format.count >= 12 ? format[format.startIndex + 8..<format.startIndex + 12].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } : 0 }
        var blockAlign: UInt16 { WavRepair.blockAlign(format) }
    }

    /// Bytes per frame from a fmt chunk's fields (0 when too short).
    static func blockAlign(_ fmt: Data) -> UInt16 {
        fmt.count >= 14 ? UInt16(fmt[fmt.startIndex + 12]) | UInt16(fmt[fmt.startIndex + 13]) << 8 : 0
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
                // Whole frames only: 2 bytes for speech, 3 for Audio only's 24-bit mono. A WAV's pad byte after an odd
                // data chunk, or a frame the app died part way through, is never counted as audio.
                let block = UInt64(max(1, Self.blockAlign(fmt)))
                return Layout(dataOffset: start, dataLength: (len - start) / block * block, dataSizeField: UInt64(o + 4), format: fmt)
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
        var block: UInt64 = 2
        while o + 8 <= head.count {
            let id = String(data: head[o..<o + 4], encoding: .ascii) ?? ""
            let size = u32(o + 4)
            if id == "fmt ", o + 8 + 14 <= head.count {
                block = UInt64(max(1, blockAlign(head.subdata(in: (o + 8)..<(o + 8 + 14)))))
            }
            if id == "data" {
                let dataStart = UInt64(o + 8)
                guard len > dataStart else { return }
                // Whole frames (3 bytes each in Audio only's 24-bit files).
                let actual = UInt32(clamping: (len - dataStart) / block * block)
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
