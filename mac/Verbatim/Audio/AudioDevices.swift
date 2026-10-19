import Foundation
import AVFoundation
import CoreAudio

/// Input devices on this Mac, and which one Verbatim records from. "System default" follows macOS.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let transport: String     // "Built-in", "USB", "Bluetooth", "Continuity", …
        var symbol: String {
            switch transport {
            case "Bluetooth": return "airpods"
            case "USB", "Thunderbolt", "PCI": return "mic.fill"
            case "Continuity": return "iphone"
            case "Virtual": return "waveform"
            default: return "laptopcomputer"
            }
        }
    }

    static let selectionKey = "inputDeviceUID"

    /// The chosen device's UID, or nil for the system default.
    static var selectedUID: String? {
        get { UserDefaults.standard.string(forKey: selectionKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectionKey) }
    }

    static var selectedInputID: AudioDeviceID? {
        guard let uid = selectedUID else { return nil }
        return inputs().first { deviceUID($0.id) == uid }?.id
    }

    /// The device recording will use right now (chosen one if present, else the system default).
    static func current() -> Device? {
        if let id = selectedInputID, let d = inputs().first(where: { $0.id == id }) { return d }
        return defaultInput()
    }

    static func defaultInput() -> Device? {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return inputs().first { $0.id == id }
    }

    static func inputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, name: name, transport: transportName(id))
        }
    }

    /// The device's sample rate as the system has it set, or nil if it can't be read.
    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0); var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    static func setInput(_ id: AudioDeviceID, on node: AVAudioInputNode) {
        guard let unit = node.audioUnit else { return }
        var dev = id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // MARK: CoreAudio helpers

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }

    static func deviceUID(_ id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    private static func transportName(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return "Other" }
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "Virtual"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "Display"
        default: return "Other"
        }
    }
}
