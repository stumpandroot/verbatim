import Foundation
import AppKit
import CoreAudio

/// Notices when another app starts or stops using the microphone, and which app (App/MeetingCoordinator.swift
/// decides whether to ask). It never opens the microphone, never hears audio, and never uses the network: it only
/// reads Core Audio's bookkeeping.
///
/// - The default input device's `kAudioDevicePropertyDeviceIsRunningSomewhere`: someone is using the mic. Reported
///   to stay 0 for some Bluetooth mics, so it's a trigger, not the only source.
/// - On macOS 14.4 and later, the audio process objects (`kAudioHardwarePropertyProcessObjectList`): each one's
///   `kAudioProcessPropertyIsRunningInput` and `kAudioProcessPropertyBundleID` name the process using the mic.
///   Listeners on the list and on each process report changes as they happen.
///
/// `onChange` runs on the main queue whenever any of that changes; read `snapshot()` then.
@MainActor
final class MeetingDetector {
    struct Snapshot: Equatable {
        /// The default input device is running for some process (Verbose included).
        var deviceRunning = false
        /// Bundle IDs of other processes using any input right now; nil before macOS 14.4 (unknown).
        var users: [String]? = nil
    }

    var onChange: (() -> Void)?
    private(set) var isRunning = false

    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var defaultBlock: AudioObjectPropertyListenerBlock?
    private var listBlock: AudioObjectPropertyListenerBlock?
    private var processBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private let ownPID = getpid()

    private static var processesSupported: Bool { if #available(macOS 14.4, *) { return true } else { return false } }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.watchDefaultInput(); self?.onChange?() }
        }
        if AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main, block) == noErr { defaultBlock = block }
        watchDefaultInput()
        if #available(macOS 14.4, *) {
            var list = Self.address(kAudioHardwarePropertyProcessObjectList)
            let lb: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.watchProcesses(); self?.onChange?() }
            }
            if AudioObjectAddPropertyListenerBlock(system, &list, DispatchQueue.main, lb) == noErr { listBlock = lb }
            watchProcesses()
        }
        Log.note("meeting detector: watching the microphone\(Self.processesSupported ? " and the processes using it" : " (device only, before macOS 14.4)")")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let b = defaultBlock { var a = Self.address(kAudioHardwarePropertyDefaultInputDevice); AudioObjectRemovePropertyListenerBlock(system, &a, DispatchQueue.main, b) }
        if #available(macOS 14.4, *), let b = listBlock {
            var a = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(system, &a, DispatchQueue.main, b)
        }
        defaultBlock = nil; listBlock = nil
        unwatchDevice()
        for (obj, b) in processBlocks { Self.removeRunningInputListener(obj, b) }
        processBlocks = [:]
        Log.note("meeting detector: stopped")
    }

    /// Who's using the microphone right now.
    func snapshot() -> Snapshot {
        var s = Snapshot()
        if inputDevice != kAudioObjectUnknown { s.deviceRunning = (Self.uint32(inputDevice, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0 }
        if Self.processesSupported { s.users = currentUsers() }
        return s
    }

    // MARK: Listeners

    private func watchDefaultInput() {
        let id = Self.uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice).map { AudioObjectID($0) } ?? AudioObjectID(kAudioObjectUnknown)
        guard id != inputDevice else { return }
        unwatchDevice()
        inputDevice = id
        guard id != kAudioObjectUnknown else { return }
        var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.onChange?() } }
        if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr { deviceBlock = block }
    }

    private func unwatchDevice() {
        if let b = deviceBlock, inputDevice != kAudioObjectUnknown {
            var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(inputDevice, &addr, DispatchQueue.main, b)
        }
        deviceBlock = nil
        inputDevice = AudioObjectID(kAudioObjectUnknown)
    }

    /// One listener per audio process on whether it's using input; processes that went away lose theirs.
    private func watchProcesses() {
        guard #available(macOS 14.4, *) else { return }
        let now = Set(Self.processObjects())
        for (obj, b) in processBlocks where !now.contains(obj) {
            Self.removeRunningInputListener(obj, b)
            processBlocks[obj] = nil
        }
        for obj in now where processBlocks[obj] == nil {
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.onChange?() } }
            if AudioObjectAddPropertyListenerBlock(obj, &addr, DispatchQueue.main, block) == noErr { processBlocks[obj] = block }
        }
    }

    private static func removeRunningInputListener(_ obj: AudioObjectID, _ block: @escaping AudioObjectPropertyListenerBlock) {
        guard #available(macOS 14.4, *) else { return }
        var addr = address(kAudioProcessPropertyIsRunningInput)
        AudioObjectRemovePropertyListenerBlock(obj, &addr, DispatchQueue.main, block)
    }

    /// Bundle IDs of every other process using input. A process without a bundle ID in Core Audio is looked up by
    /// PID; Verbose's own process (its recordings and dictation) is left out.
    private func currentUsers() -> [String] {
        guard #available(macOS 14.4, *) else { return [] }
        var out: [String] = []
        for obj in Self.processObjects() where (Self.uint32(obj, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 {
            let pid = Self.pid(obj)
            if pid == ownPID { continue }
            var id = Self.string(obj, kAudioProcessPropertyBundleID) ?? ""
            if id.isEmpty, let pid, pid > 0 { id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            if id.isEmpty || MeetingApps.isOwn(id) { continue }
            out.append(id)
        }
        return out
    }

    // MARK: Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        guard #available(macOS 14.4, *) else { return [] }
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private static func pid(_ obj: AudioObjectID) -> pid_t? {
        guard #available(macOS 14.4, *) else { return nil }
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }
}
