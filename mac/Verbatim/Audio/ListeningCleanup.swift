import Foundation
import AVFoundation
import AudioToolbox

/// The player's Reduce background noise switch: for listening only. It changes what you hear, never the transcript
/// or the saved file. Off by default and remembered on each device (not synced).
///
/// It uses Apple's own voice isolation (the AUSoundIsolation audio unit, built into macOS and iOS), so nothing is
/// downloaded and the apps don't grow. The noise report suggested DeepFilterNet 3 at a 20 dB attenuation limit;
/// here the same limit comes from mixing 90% isolated voice with 10% of the original (10% is −20 dB), so noise never
/// drops to digital silence and the voice keeps its room.
enum ListeningCleanup {
    static let key = "player.reduceNoise"
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Isolated voice in the mix, in percent; the rest is the original (a 20 dB floor on how far noise drops).
    static let wetPercent: Float = 90

    static var component: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                  componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    }

    /// Whether this device has Apple's voice isolation unit. Checked before one is made: making a missing unit fails.
    static var isAvailable: Bool {
        var d = component
        return AudioComponentFindNext(nil, &d) != nil
    }

    static let title = "Reduce background noise"
    static let unavailable = "Noise reduction isn't available on this device."
}

/// Playback through Apple's voice isolation: the file into a player node, the isolation unit, a time-pitch unit for
/// the speed, and the output. `Player` switches to it while Reduce background noise is on and back when it's off,
/// at the same moment in the recording.
@MainActor
final class CleanPlayback {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// Converts the file's format (often 16 kHz mono) to the one the isolation unit runs in.
    private let convert = AVAudioMixerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let isolation: AVAudioUnitEffect
    private let file: AVAudioFile
    private let sampleRate: Double
    private let length: AVAudioFramePosition
    /// Where the current schedule started, and where playback stopped while paused.
    private var startFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0
    /// Each schedule's number: a stopped schedule's late completion is ignored.
    private var token = 0
    private(set) var isPlaying = false
    /// Played to the end.
    var onFinish: (() -> Void)?

    /// nil when this device has no voice isolation or the file can't be opened.
    init?(url: URL, rate: Float) {
        guard ListeningCleanup.isAvailable, let f = try? AVAudioFile(forReading: url) else { return nil }
        file = f
        sampleRate = f.processingFormat.sampleRate
        length = f.length
        isolation = AVAudioUnitEffect(audioComponentDescription: ListeningCleanup.component)
        // The unit runs in standard 48 kHz stereo; one it refuses is found here, before any connection (an engine
        // connection in a format a unit refuses stops the app).
        guard let working = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return nil }
        do {
            try isolation.auAudioUnit.inputBusses[0].setFormat(working)
            try isolation.auAudioUnit.outputBusses[0].setFormat(working)
        } catch {
            Log.note("listening cleanup: the isolation unit refused 48 kHz stereo (\(error.localizedDescription))")
            return nil
        }
        engine.attach(node); engine.attach(convert); engine.attach(isolation); engine.attach(pitch)
        engine.connect(node, to: convert, format: f.processingFormat)
        engine.connect(convert, to: isolation, format: working)
        engine.connect(isolation, to: pitch, format: working)
        engine.connect(pitch, to: engine.mainMixerNode, format: working)
        AudioUnitSetParameter(isolation.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
                              kAudioUnitScope_Global, 0, ListeningCleanup.wetPercent, 0)
        pitch.rate = rate
        // The engine starts only when playback does, so opening a transcript never interrupts other audio.
        engine.prepare()
    }

    var duration: Double { Double(length) / sampleRate }

    var currentTime: Double {
        if isPlaying, let now = node.lastRenderTime, let t = node.playerTime(forNodeTime: now) {
            return min(duration, Double(startFrame + t.sampleTime) / sampleRate)
        }
        return Double(pausedFrame) / sampleRate
    }

    var rate: Float {
        get { pitch.rate }
        set { pitch.rate = newValue }
    }

    private func frame(_ seconds: Double) -> AVAudioFramePosition {
        max(0, min(length, AVAudioFramePosition((seconds * sampleRate).rounded())))
    }

    func play(from seconds: Double) {
        let from = frame(seconds)
        token += 1
        let mine = token
        node.stop()
        startFrame = from; pausedFrame = from
        let remaining = AVAudioFrameCount(clamping: max(0, length - from))
        guard remaining > 0 else { isPlaying = false; return }
        if !engine.isRunning {
            do { try engine.start() } catch { Log.note("listening cleanup: couldn't start (\(error.localizedDescription))"); return }
        }
        node.scheduleSegment(file, startingFrame: from, frameCount: remaining, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.token == mine, self.isPlaying else { return }
                self.isPlaying = false
                self.pausedFrame = 0
                self.onFinish?()
            }
        }
        node.play()
        isPlaying = true
    }

    func pause() {
        pausedFrame = frame(currentTime)
        token += 1
        node.stop()
        engine.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        if isPlaying { play(from: seconds) } else { pausedFrame = frame(seconds) }
    }

    func stop() {
        token += 1
        node.stop()
        engine.stop()
        isPlaying = false
    }
}
