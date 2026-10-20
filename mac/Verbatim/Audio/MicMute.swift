import Foundation
import AudioToolbox
import CoreAudio

/// Whether an input device is muted, read from Core Audio, and a watch that reports changes while recording.
///
/// A device counts as muted when it reports mute on its input side (the main element, or every channel that has
/// a mute control), or when its input volume is at zero (the virtual main volume, the main element's volume, or
/// every channel's volume). Many USB mics mute in hardware without exposing any of this; they send exact digital
/// silence instead, which `Recorder` notices separately.
enum MicMute {
    /// Reads the device's mute state. Core Audio calls can block on a device that's slow to answer, so callers
    /// off the main thread are preferred (`MicMuteWatch` reads on its own queue).
    static func isMuted(_ device: AudioDeviceID) -> Bool {
        let elements = [kAudioObjectPropertyElementMain] + (0..<channelCount(device)).map { AudioObjectPropertyElement($0 + 1) }

        // Mute switches.
        var channelMutes: [Bool] = []
        for e in elements {
            guard let v = readUInt32(device, kAudioDevicePropertyMute, element: e) else { continue }
            if e == kAudioObjectPropertyElementMain { if v != 0 { return true } } else { channelMutes.append(v != 0) }
        }
        if !channelMutes.isEmpty, channelMutes.allSatisfy({ $0 }) { return true }

        // Input volume at zero.
        if let v = virtualMainVolume(device), v <= 0.0001 { return true }
        var channelVolumes: [Float32] = []
        for e in elements {
            guard let v = readFloat(device, kAudioDevicePropertyVolumeScalar, element: e) else { continue }
            if e == kAudioObjectPropertyElementMain { if v <= 0.0001 { return true } } else { channelVolumes.append(v) }
        }
        if !channelVolumes.isEmpty, channelVolumes.allSatisfy({ $0 <= 0.0001 }) { return true }
        return false
    }

    /// The property addresses that change when the device is muted, unmuted, or its input volume moves.
    static func watchedAddresses(_ device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let elements = [kAudioObjectPropertyElementMain] + (0..<channelCount(device)).map { AudioObjectPropertyElement($0 + 1) }
        var out: [AudioObjectPropertyAddress] = []
        for e in elements {
            for s in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                var a = AudioObjectPropertyAddress(mSelector: s, mScope: kAudioDevicePropertyScopeInput, mElement: e)
                if has(AudioObjectHasProperty(device, &a)) { out.append(a) }
            }
        }
        return out
    }

    // Core Audio's `Boolean` results import as Bool or DarwinBoolean depending on the SDK; accept either.
    private static func has(_ b: Bool) -> Bool { b }
    private static func has(_ b: DarwinBoolean) -> Bool { b.boolValue }

    private static func channelCount(_ device: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return min(16, list.reduce(0) { $0 + Int($1.mNumberChannels) })
    }

    private static func readUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
        guard has(AudioObjectHasProperty(device, &addr)) else { return nil }
        var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func readFloat(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
        guard has(AudioObjectHasProperty(device, &addr)) else { return nil }
        var v: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    /// The input volume as the Sound settings slider shows it, when the device has one.
    private static func virtualMainVolume(_ device: AudioDeviceID) -> Float32? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        guard has(AudioHardwareServiceHasProperty(device, &addr)) else { return nil }
        var v: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        return AudioHardwareServiceGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }
}

/// Watches one device's mute state while recording. Reads and listener callbacks run on the watch's own queue;
/// `onChange` is called on the main queue with the new state, once right after `start()` and again on every
/// change. `cancel()` removes the listeners; nothing is delivered after it.
final class MicMuteWatch: @unchecked Sendable {
    let device: AudioDeviceID
    private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.micmute", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var listeners: [AudioObjectPropertyAddress] = []
    private var block: AudioObjectPropertyListenerBlock?
    private var last: Bool?
    private let onChange: (Bool) -> Void

    init(device: AudioDeviceID, onChange: @escaping (Bool) -> Void) {
        self.device = device
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard !isCancelled else { return }
            let b: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.check() }
            block = b
            for a in MicMute.watchedAddresses(device) {
                var addr = a
                if AudioObjectAddPropertyListenerBlock(device, &addr, queue, b) == noErr { listeners.append(a) }
            }
            check()
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        queue.async { [self] in
            guard let b = block else { return }
            for a in listeners {
                var addr = a
                AudioObjectRemovePropertyListenerBlock(device, &addr, queue, b)
            }
            listeners = []
            block = nil
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Watch queue: reads the state and reports it if it changed.
    private func check() {
        guard !isCancelled else { return }
        let muted = MicMute.isMuted(device)
        guard muted != last else { return }
        last = muted
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.onChange(muted)
        }
    }
}
