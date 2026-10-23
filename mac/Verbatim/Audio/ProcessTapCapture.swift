import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// What a meeting capture records on the system side (App/MeetingSession.swift).
enum MeetingAudioTarget: Equatable {
    /// Every audio process of one app: the app itself and any helper whose bundle ID starts with the app's plus a
    /// dot (browsers and Teams play sound from helper processes).
    case app(bundleID: String, name: String)
    /// One process, by PID.
    case process(pid: pid_t, name: String)
    /// Everything this Mac plays except Verbose itself, notifications and music included.
    case allSystemAudio

    var name: String {
        switch self {
        case .app(_, let n), .process(_, let n): return n
        case .allSystemAudio: return "All system audio"
        }
    }

    var bundleID: String? { if case .app(let id, _) = self { return id }; return nil }
}

/// The Core Audio host clock in seconds: the clock a tap's and a mic's buffer timestamps use, so meeting tracks line
/// up on it (MeetingAlign). Doesn't advance while the Mac sleeps.
enum HostClock {
    static func now() -> Double { seconds(AudioGetCurrentHostTime()) }
    static func seconds(_ hostTime: UInt64) -> Double { Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9 }
}

/// Records what other apps play with a Core Audio process tap (macOS 14.4 and later): a private, unmuted, mono
/// tap on the target's processes (or on everything but Verbose), inside a private aggregate device whose IOProc
/// writes each buffer through a segmented `RecordingWriter`, so the track gets the recorder's 16 kHz mono format,
/// its 5-minute segments, and its crash safety. No screen access; macOS asks for System Audio Recording the first
/// time the aggregate device starts (NSAudioCaptureUsageDescription). Without that permission the tap still runs
/// and delivers buffers of zeros, with no error: `verdict` reports that so the caller can fall back to
/// ScreenCaptureKit (`AppAudioCapture`). Modeled on Apple's "Capturing system audio with Core Audio taps" sample.
@available(macOS 14.4, *)
final class ProcessTapCapture: @unchecked Sendable {
    /// What a stopped tap saved, like `StoppedCapture` for ScreenCaptureKit.
    struct Stopped: Sendable {
        var url: URL
        var duration: TimeInterval
        var framesWritten: Int64
        var heardSignal: Bool
        var joinFailed = false
        var skipped: [ClosedRange<Double>] = []
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ what: String, _ status: OSStatus = noErr) { message = status == noErr ? what : "\(what) (\(status))" }
        var errorDescription: String? { message }
    }

    let target: MeetingAudioTarget
    /// Host time of the first sample and of the end of the last one written.
    let clock = TrackClock()
    /// Bundle IDs of the processes tapped, for the log. Empty for a global tap.
    private(set) var tappedBundleIDs: [String] = []
    /// The tap records everything but Verbose (the target had no audio process, or asked for it).
    private(set) var isGlobal = false

    private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.processtap", qos: .userInitiated)
    private let lock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedObjects: [AudioObjectID] = []
    private var writer: RecordingWriter?
    private var url: URL?
    private var format: AVAudioFormat?
    // Guarded by `lock`: written on the tap's queue, read by the session.
    private var silence = SilenceTracker()
    private var level: Float = 0
    private var isPaused = false
    private var startedAt: Double = 0

    init(target: MeetingAudioTarget) { self.target = target }

    deinit { teardown() }

    // MARK: Start and stop

    /// Builds the tap, the aggregate device, and the IOProc, then starts them, writing to `url` (and its segments).
    /// Throws, with everything released and no file left, when any step fails.
    func start(to url: URL) throws {
        let me = Self.processObject(pid: getpid())
        let exclude = me.map { [$0] } ?? []
        let description: CATapDescription
        switch target {
        case .allSystemAudio:
            description = CATapDescription(monoGlobalTapButExcludeProcesses: exclude)
            isGlobal = true
        case .app(let bundleID, _):
            let objects = Self.processObjects(matching: bundleID)
            if objects.isEmpty {
                // The app hasn't opened audio yet (no process object), or plays it from a process with another
                // bundle ID (Safari's WebKit processes): everything but Verbose instead.
                Log.noteNow("meeting tap: no audio process for \(bundleID); tapping all system audio except Verbose")
                description = CATapDescription(monoGlobalTapButExcludeProcesses: exclude)
                isGlobal = true
            } else {
                description = CATapDescription(monoMixdownOfProcesses: objects)
                tappedObjects = objects
            }
        case .process(let pid, _):
            guard let object = Self.processObject(pid: pid) else { throw Failure("Process \(pid) has no audio to record.") }
            description = CATapDescription(monoMixdownOfProcesses: [object])
            tappedObjects = [object]
        }
        tappedBundleIDs = tappedObjects.compactMap { Self.string($0, kAudioProcessPropertyBundleID) }
        description.uuid = UUID()
        description.name = "Verbose meeting capture"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        Log.noteNow("meeting tap: creating a \(isGlobal ? "global tap excluding Verbose" : "tap on \(tappedBundleIDs.joined(separator: ", "))")")

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw Failure("Couldn't create the audio tap.", status) }
        tapID = tap
        do {
            var asbd = try Self.tapFormat(tap)
            guard let f = AVAudioFormat(streamDescription: &asbd) else { throw Failure("The tap's audio format isn't supported.") }
            format = f
            Log.noteNow("meeting tap: tap format \(Int(f.sampleRate)) Hz, \(f.channelCount) ch, \(f.commonFormat == .pcmFormatFloat32 ? "float" : "other")")

            guard let output = Self.defaultOutputDevice(), let outputUID = AudioDevices.deviceUID(output) else {
                throw Failure("No sound output device is available.")
            }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Verbose meeting capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
            guard status == noErr, device != kAudioObjectUnknown else { throw Failure("Couldn't create the capture device.", status) }
            aggregateID = device

            let w = try RecordingWriter(url: url, inputFormat: f, segmented: true)
            lock.lock()
            writer = w; self.url = url; silence = SilenceTracker(); level = 0; isPaused = false
            startedAt = HostClock.now()
            lock.unlock()
            clock.reset()
            RecordingSegments.setActive(url, true)

            var proc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, inputTime, _, _ in
                self?.receive(input, inputTime)
            }
            guard status == noErr, let proc else { throw Failure("Couldn't attach to the capture device.", status) }
            procID = proc
            Log.noteNow("meeting tap: starting the capture device on \(outputUID); macOS asks for System Audio Recording the first time")
            status = AudioDeviceStart(device, proc)
            guard status == noErr else { throw Failure("Couldn't start the capture device.", status) }
            Log.noteNow("meeting tap: running")
        } catch {
            Log.noteNow("meeting tap: start failed: \(error.localizedDescription)")
            teardown()
            lock.lock()
            let w = writer; writer = nil; self.url = nil
            lock.unlock()
            if let w {
                _ = w.close()
                for u in w.segments { try? FileManager.default.removeItem(at: u) }
            }
            RecordingSegments.setActive(url, false)
            throw error
        }
    }

    /// Stops the tap and saves; segments are joined off the main thread. Nil when it wasn't running.
    func stop() async -> Stopped? {
        lock.lock()
        let w = writer, url = self.url
        lock.unlock()
        guard let w, let url else { return nil }
        teardown()
        // Buffers already handed to the queue are written before the file closes.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
        lock.lock(); writer = nil; self.url = nil; lock.unlock()
        _ = w.close()
        var result = Stopped(url: url, duration: w.seconds, framesWritten: w.framesWritten, heardSignal: w.heardSignal)
        let parts = w.segments
        if parts.count > 1 {
            let joined = await Task.detached(priority: .userInitiated) { RecordingSegments.join(parts) }.value
            if let joined {
                result.url = joined.url; result.skipped = joined.skipped; result.duration = joined.seconds
            } else {
                result.joinFailed = true
                Log.note("meeting tap: couldn't join \(parts.count) segments; all kept for recovery at next launch")
            }
        }
        RecordingSegments.setActive(url, false)
        Log.noteNow("meeting tap: stopped \(String(format: "%.2f", result.duration))s in \(parts.count) part\(parts.count == 1 ? "" : "s"), signal=\(result.heardSignal)")
        return result
    }

    /// Stops and deletes what the tap wrote (the session switched to ScreenCaptureKit).
    func discard() async {
        lock.lock()
        let w = writer, url = self.url
        writer = nil; self.url = nil
        lock.unlock()
        teardown()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
        guard let w, let url else { return }
        _ = w.close()
        for u in w.segments { try? FileManager.default.removeItem(at: u) }
        RecordingSegments.removeSegments(of: url)
        RecordingSegments.setActive(url, false)
        Log.noteNow("meeting tap: discarded")
    }

    /// Stops the device and destroys the IOProc, the aggregate device, and the tap, in that order. Safe to repeat.
    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Audio

    /// The tap's queue: writes one buffer (the writer converts it before returning, so the no-copy wrapper is safe)
    /// and keeps the level, the silence tracker, and the clock.
    private func receive(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        lock.lock()
        let w = writer, f = format, paused = isPaused
        lock.unlock()
        guard let w, let f, let buffer = AVAudioPCMBuffer(pcmFormat: f, bufferListNoCopy: input, deallocator: nil), buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        if let ch = buffer.floatChannelData {
            let stride = buffer.stride
            for c in 0..<Int(f.channelCount) { for i in 0..<frames { peak = max(peak, abs(ch[c][i * stride])) } }
        }
        let ts = time.pointee
        let host = ts.mFlags.contains(.hostTimeValid) && ts.mHostTime > 0 ? HostClock.seconds(ts.mHostTime) : HostClock.now()
        let v = w.write(buffer)
        if !paused { clock.mark(bufferStart: host, frames: frames, sampleRate: f.sampleRate) }
        lock.lock()
        silence.feed(peak: peak, at: host)
        level = v
        lock.unlock()
    }

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isPaused }
        set {
            lock.lock(); isPaused = newValue; let w = writer; lock.unlock()
            w?.paused = newValue
        }
    }

    /// The meter's level (0…1) of the latest buffer.
    var currentLevel: Float { lock.lock(); defer { lock.unlock() }; return level }

    /// Seconds since anything audible came from the tap.
    var silentFor: Double { lock.lock(); defer { lock.unlock() }; return silence.silentFor(now: HostClock.now()) }

    /// Seconds of audio on disk.
    var seconds: Double { lock.lock(); defer { lock.unlock() }; return writer?.seconds ?? 0 }

    /// Whether the tap is delivering real audio, only zeros (permission, almost always), or nothing.
    var verdict: TapVerdict {
        lock.lock()
        let s = silence, since = startedAt
        lock.unlock()
        let now = HostClock.now()
        return MeetingAlign.tapVerdict(elapsed: now - since, buffersArrived: s.buffers > 0, silence: s, now: now, targetPlaying: targetPlaying)
    }

    /// Whether any tapped process says it's playing sound right now. nil for a global tap.
    var targetPlaying: Bool? {
        guard !isGlobal, !tappedObjects.isEmpty else { return nil }
        return tappedObjects.contains { Self.uint32($0, kAudioProcessPropertyIsRunningOutput) == 1 }
    }

    // MARK: Core Audio helpers

    /// Every audio process object whose bundle ID is `bundleID` or starts with `bundleID` plus a dot.
    static func processObjects(matching bundleID: String) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &list) == noErr else { return [] }
        let want = bundleID.lowercased()
        return list.filter { obj in
            guard let id = string(obj, kAudioProcessPropertyBundleID)?.lowercased(), !id.isEmpty else { return false }
            return id == want || id.hasPrefix(want + ".")
        }
    }

    /// The audio process object of a PID, or nil when that process hasn't opened audio.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { throw Failure("Couldn't read the tap's audio format.", status) }
        return asbd
    }

    private static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }
}
