import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures one input device through a HAL output unit (AUHAL) set up for input only. Dictation records
/// with this instead of AVAudioEngine.
///
/// Why: an engine's input node is created on the system default input, and only moved to the chosen device
/// afterwards. With Bluetooth headphones as the default, that opens their mic (switching them into the
/// headset call profile) even when another mic, such as a USB mic, is chosen, and the move to the chosen
/// device can leave the tap on the default's format, so nothing arrives. Here the device is set before the
/// unit is initialized (Apple's TN2091 order), so no other device is ever opened.
///
/// `prepare()` initializes the unit without starting the device (no mic in use); `start()` and `stop()` run
/// and halt the device. Buffers arrive on the audio thread and are handed to `onBuffer` before it returns;
/// the buffer is reused for the next callback, so `onBuffer` must copy or convert it right away.
final class InputUnit: @unchecked Sendable {
    let device: AudioDeviceID
    /// What `onBuffer` receives: 32-bit float, non-interleaved, at the device's own sample rate and channels.
    let format: AVAudioFormat
    private let unit: AudioUnit
    private let buffer: AVAudioPCMBuffer
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private var initialized = false
    private var running = false
    private var disposed = false

    init(device: AudioDeviceID, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw InputUnit.error("No audio input unit is available.", 0) }
        var made: AudioUnit?
        let status = AudioComponentInstanceNew(component, &made)
        guard status == noErr, let u = made else { throw InputUnit.error("Couldn't create the audio input unit.", status) }
        do {
            // Input on (element 1), output off (element 0), then the device. Enabling input before choosing the
            // device is the documented order; nothing is opened until the unit starts.
            var on: UInt32 = 1, off: UInt32 = 0
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            try InputUnit.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "turn on input")
            try InputUnit.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "turn off output")
            var dev = device
            try InputUnit.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                                UInt32(MemoryLayout<AudioDeviceID>.size)), "choose the microphone")
            // Read back the device: if the unit didn't take it, don't record from whatever it fell back to.
            var bound = AudioDeviceID(0); var boundSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            try InputUnit.check(AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &bound, &boundSize), "confirm the microphone")
            guard bound == device else { throw InputUnit.error("The microphone couldn't be selected.", 0) }
            // The device side of the input element is the hardware format. The unit can't resample input, so the
            // format handed to us keeps the hardware's rate and channels; the recording writer converts it.
            var hw = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try InputUnit.check(AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &asbdSize), "read the microphone's format")
            guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0,
                  let f = AVAudioFormat(standardFormatWithSampleRate: hw.mSampleRate, channels: AVAudioChannelCount(hw.mChannelsPerFrame)) else {
                throw InputUnit.error("No microphone input is available.", 0)
            }
            var client = f.streamDescription.pointee
            try InputUnit.check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, asbdSize), "set the capture format")
            var maxFrames: UInt32 = 4096
            var maxSize = u32
            _ = AudioUnitGetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxSize)
            guard let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: max(maxFrames, 4096)) else {
                throw InputUnit.error("Couldn't make an audio buffer.", 0)
            }
            self.device = device
            self.format = f
            self.unit = u
            self.buffer = b
            self.onBuffer = onBuffer
        } catch {
            AudioComponentInstanceDispose(u)
            throw error
        }
    }

    deinit { dispose() }

    /// Installs the input callback and initializes the unit. The device isn't running afterwards.
    func prepare() throws {
        guard !disposed, !initialized else { return }
        var cb = AURenderCallbackStruct(inputProc: inputUnitCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try InputUnit.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                            UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "install the input callback")
        try InputUnit.check(AudioUnitInitialize(unit), "prepare the microphone")
        initialized = true
    }

    func start() throws {
        guard !disposed else { throw InputUnit.error("The microphone was released.", 0) }
        if !initialized { try prepare() }
        guard !running else { return }
        try InputUnit.check(AudioOutputUnitStart(unit), "start the microphone")
        running = true
    }

    /// Stops the device (the mic is no longer in use). The unit stays initialized for the next `start()`.
    func stop() {
        guard running, !disposed else { return }
        AudioOutputUnitStop(unit)
        running = false
    }

    /// Stops and releases the unit. Safe to call more than once.
    func dispose() {
        guard !disposed else { return }
        stop()
        if initialized { AudioUnitUninitialize(unit); initialized = false }
        AudioComponentInstanceDispose(unit)
        disposed = true
    }

    /// Audio thread: pulls this cycle's input into the reused buffer and hands it on.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard frames > 0, frames <= buffer.frameCapacity else { return noErr }
        // Setting frameLength also sets each buffer's byte size, which AudioUnitRender reads as the space available.
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        onBuffer(buffer)
        return noErr
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw error("Couldn't \(what).", status) }
    }

    private static func error(_ message: String, _ status: OSStatus) -> NSError {
        NSError(domain: "Verbatim.InputUnit", code: Int(status), userInfo: [NSLocalizedDescriptionKey: status == 0 ? message : "\(message) (\(status))"])
    }
}

/// The unit's input callback: a C function, so it reaches the `InputUnit` through the refcon.
private let inputUnitCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, bus, frames)
}
