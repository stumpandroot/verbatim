#if os(macOS)
import Foundation
import AppKit
import Combine
import CoreAudio
import AudioToolbox
import SwiftUI

/// Settings › Dictation › Lower other audio while Verbatim listens. On unless you turn it off.
enum LowerAudioSetting {
    static let key = "audio.lowerOthers"
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Settings › Dictation: the switch for `LowerAudioSetting`.
struct LowerAudioRow: View {
    @AppStorage(LowerAudioSetting.key) private var on = true
    var body: some View { SettingsToggleRow("dictate.lowerAudio", isOn: $on) }
}

// MARK: - Decisions (no Core Audio; self-tested)

/// The pure rules behind `AudioDucker`: the lowered level, who's listening, and when to put the volume back.
enum DuckMath {
    /// Other sound drops to 10% of where it was (not an absolute 10%).
    static let factor: Float = 0.10
    /// Volume readings within this of each other count as the same (devices round what they're given).
    static let tolerance: Float = 0.02
    static let fadeDown: TimeInterval = 0.15
    static let fadeUp: TimeInterval = 0.30
    static let stepInterval: TimeInterval = 0.015
    /// A saved duck older than this, on a device that isn't connected, is forgotten.
    static let keepMissingFor: TimeInterval = 12 * 3600

    static func target(_ v: Float) -> Float { max(0, min(1, v * factor)) }

    /// Only a device you can set, that isn't muted, and that's playing above silence.
    static func shouldDuck(volume: Float?, muted: Bool, settable: Bool) -> Bool {
        guard settable, !muted, let volume else { return false }
        return volume > 0.001
    }

    /// The volume moved away from what Verbatim last set: you changed it, so Verbatim leaves it alone.
    static func userChanged(current: Float, lastSet: Float) -> Bool { abs(current - lastSet) > tolerance }

    /// One fade: `count` evenly spaced values from just after `from` to exactly `to`.
    static func fadeSteps(from: Float, to: Float, duration: TimeInterval) -> [Float] {
        let n = max(1, Int((duration / stepInterval).rounded()))
        return (1...n).map { i in i == n ? to : from + (to - from) * Float(i) / Float(n) }
    }

    enum LaunchRestore: Equatable {
        /// The device is still at the lowered level: put it back.
        case restore
        /// You changed the volume since: leave it, forget the duck.
        case leave
        /// The device isn't connected: keep the record for a later launch.
        case keepForLater
        /// Not connected and too old to matter.
        case drop
    }

    /// Verbatim quit or crashed while other audio was lowered.
    static func launchDecision(current: Float?, lastSet: Float, target: Float, savedAt: Date, now: Date) -> LaunchRestore {
        guard let current else { return now.timeIntervalSince(savedAt) < keepMissingFor ? .keepForLater : .drop }
        let stillLowered = !userChanged(current: current, lastSet: lastSet) || !userChanged(current: current, lastSet: target)
        return stillLowered ? .restore : .leave
    }
}

/// Who's listening. The volume goes down when the first one starts and comes back once, after the last one ends.
struct DuckHolders: Equatable {
    private(set) var users: Set<String> = []
    var isEmpty: Bool { users.isEmpty }
    /// True when this is the first listener (the volume should go down). Repeats from the same listener don't count twice.
    mutating func acquire(_ user: String) -> Bool {
        let was = users.isEmpty
        users.insert(user)
        return was && !users.isEmpty
    }
    /// True when this was the last listener (the volume should come back).
    mutating func release(_ user: String) -> Bool {
        guard users.remove(user) != nil else { return false }
        return users.isEmpty
    }
}

// MARK: - Output volume (Core Audio)

/// The default output device's volume: the virtual main volume when the device has one, otherwise the main
/// element's volume, otherwise each channel's. Values are 0…1. Core Audio calls: never on the main thread.
struct OutputVolume {
    enum Kind { case virtualMain, mainScalar, channels([UInt32]) }
    let device: AudioObjectID
    let kind: Kind

    private static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }

    static func defaultOutput() -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var id = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func uid(_ id: AudioObjectID) -> String? {
        var a = addr(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }

    static func device(uid: String) -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { self.uid($0) == uid }
    }

    static func isAlive(_ id: AudioObjectID) -> Bool {
        var a = addr(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)
        var alive = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private static func settable(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        guard AudioObjectHasProperty(id, &a) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &a, &ok) == noErr && ok.boolValue
    }

    /// The first volume control the device lets Verbatim set, or nil (HDMI, DisplayPort, many USB devices).
    init?(device: AudioObjectID) {
        self.device = device
        let out = kAudioDevicePropertyScopeOutput
        if Self.settable(device, Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, out)) { kind = .virtualMain; return }
        if Self.settable(device, Self.addr(kAudioDevicePropertyVolumeScalar, out)) { kind = .mainScalar; return }
        let chans = [UInt32(1), 2].filter { Self.settable(device, Self.addr(kAudioDevicePropertyVolumeScalar, out, $0)) }
        guard !chans.isEmpty else { return nil }
        kind = .channels(chans)
    }

    private var addresses: [AudioObjectPropertyAddress] {
        let out = kAudioDevicePropertyScopeOutput
        switch kind {
        case .virtualMain: return [Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, out)]
        case .mainScalar: return [Self.addr(kAudioDevicePropertyVolumeScalar, out)]
        case .channels(let c): return c.map { Self.addr(kAudioDevicePropertyVolumeScalar, out, $0) }
        }
    }

    func read() -> [Float]? {
        var values: [Float] = []
        for var a in addresses {
            var v = Float32(0); var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr else { return nil }
            values.append(v)
        }
        return values
    }

    func write(_ values: [Float]) {
        for (i, address) in addresses.enumerated() where i < values.count {
            var a = address
            var v = Float32(max(0, min(1, values[i])))
            _ = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    var isMuted: Bool {
        var a = Self.addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &a) else { return false }
        var m = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m) == noErr && m != 0
    }
}

// MARK: - Ducker

/// Lowers other audio to about 10% of its level while Verbatim listens (dictation, voice notes, Live captions from
/// the microphone), so it doesn't reach the microphone, and puts it back after. It works on the default output
/// device's volume: it fades down over 150 ms and back up over 300 ms, all on its own queue, so a recording never
/// waits for it. The original volume is saved first, so a crash or quit while lowered is put right at the next
/// launch. If you change the volume while it's lowered, or the output device changes, your choice stands.
final class AudioDucker {
    static let shared = AudioDucker()

    enum User: String { case dictation, voiceNote, captions }

    /// The start sound plays first, at full volume; the fade begins after it.
    static let startDelay: TimeInterval = 0.25
    private static let savedKey = "audio.duck.saved"

    private struct Ducked {
        let device: AudioObjectID
        let uid: String
        let control: OutputVolume
        let original: [Float]
        var lastSet: [Float]
        var target: [Float] { original.map(DuckMath.target) }
    }

    private let q = DispatchQueue(label: "verbatim.audio-ducker", qos: .userInitiated)
    // Only touched on `q`.
    private var holders = DuckHolders()
    private var ducked: Ducked?
    /// The output device changed, or you changed the volume, during this listening stretch: don't lower again until it ends.
    private var standDown = false
    private var generation = 0
    // Only touched on the main thread.
    private var bag = Set<AnyCancellable>()

    private init() {
        q.async { self.restoreAfterCrash() }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, q) { [weak self] _, _ in self?.outputChanged() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.restoreBeforeQuit()
        }
    }

    /// Starts or ends one listener. Returns at once.
    func set(_ user: User, _ on: Bool) {
        q.async { on ? self.acquire(user.rawValue) : self.release(user.rawValue) }
    }

    /// Follows a listening state for the life of the app (true while that listener hears the microphone).
    @MainActor
    func follow<P: Publisher>(_ user: User, _ listening: P) where P.Output == Bool, P.Failure == Never {
        listening.removeDuplicates().sink { [weak self] on in self?.set(user, on) }.store(in: &bag)
    }

    // MARK: Listening

    private func acquire(_ user: String) {
        guard holders.acquire(user) else { return }
        guard LowerAudioSetting.isOn else { return }
        generation += 1
        let g = generation
        q.asyncAfter(deadline: .now() + Self.startDelay) { [weak self] in
            guard let self, self.generation == g, !self.holders.isEmpty, !self.standDown else { return }
            self.duck(g)
        }
    }

    private func release(_ user: String) {
        guard holders.release(user) else { return }
        standDown = false
        generation += 1
        let g = generation
        guard let d = ducked else { return }
        guard let now = d.control.read() else { forget(); return }
        if DuckMath.userChanged(current: now[0], lastSet: d.lastSet[0]) {
            Log.note("ducker: volume changed while lowered; keeping yours")
            forget(); return
        }
        fade(to: d.original, over: DuckMath.fadeUp, g) { [weak self] in
            guard let self, let d = self.ducked else { return }
            d.control.write(d.original)
            self.forget()
        }
    }

    private func duck(_ g: Int) {
        if let d = ducked {
            // Still coming back up from the last listener: go down again from here, toward the same level.
            fade(to: d.target, over: DuckMath.fadeDown, g)
            return
        }
        guard let device = OutputVolume.defaultOutput(), let uid = OutputVolume.uid(device) else { return }
        guard let control = OutputVolume(device: device) else {
            Log.note("ducker: the output's volume can't be set; leaving it")
            return
        }
        let now = control.read()
        guard DuckMath.shouldDuck(volume: now?.max(), muted: control.isMuted, settable: true), let now else { return }
        ducked = Ducked(device: device, uid: uid, control: control, original: now, lastSet: now)
        save()
        fade(to: now.map(DuckMath.target), over: DuckMath.fadeDown, g)
    }

    /// Steps the volume from where Verbatim last set it to `to`. Stops when another start or end takes over, or
    /// when you change the volume yourself.
    private func fade(to: [Float], over duration: TimeInterval, _ g: Int, done: (() -> Void)? = nil) {
        guard let d = ducked else { return }
        let from = d.lastSet
        let tracks = to.indices.map { i in DuckMath.fadeSteps(from: i < from.count ? from[i] : to[i], to: to[i], duration: duration) }
        let count = tracks.map(\.count).max() ?? 0
        func step(_ i: Int) {
            guard generation == g, var d = ducked else { return }
            if let now = d.control.read(), DuckMath.userChanged(current: now[0], lastSet: d.lastSet[0]) {
                Log.note("ducker: volume changed while lowered; keeping yours")
                forget()
                standDown = !holders.isEmpty
                return
            }
            d.control.write(tracks.map { $0[min(i, $0.count - 1)] })
            d.lastSet = d.control.read() ?? d.lastSet
            ducked = d
            save()
            if i + 1 < count {
                q.asyncAfter(deadline: .now() + DuckMath.stepInterval) { step(i + 1) }
            } else {
                done?()
            }
        }
        step(0)
    }

    /// The default output changed: put the old device back (when it's still here) and leave the new one alone
    /// until this listening stretch ends.
    private func outputChanged() {
        guard let d = ducked, OutputVolume.defaultOutput() != d.device else { return }
        generation += 1
        standDown = !holders.isEmpty
        if OutputVolume.isAlive(d.device) {
            if let now = d.control.read(), !DuckMath.userChanged(current: now[0], lastSet: d.lastSet[0]) { d.control.write(d.original) }
            forget()
            Log.note("ducker: output device changed; put the old one back")
        } else {
            // Gone (AirPods put away): the saved record stays, so the next launch can put it back.
            ducked = nil
            Log.note("ducker: output device went away while lowered")
        }
    }

    private func forget() {
        ducked = nil
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
    }

    // MARK: Crash and quit

    private func save() {
        guard let d = ducked else { return }
        UserDefaults.standard.set([
            "uid": d.uid,
            "original": d.original.map(Double.init),
            "lastSet": d.lastSet.map(Double.init),
            "target": d.target.map(Double.init),
            "at": Date().timeIntervalSince1970,
        ] as [String: Any], forKey: Self.savedKey)
    }

    private func restoreAfterCrash() {
        guard let s = UserDefaults.standard.dictionary(forKey: Self.savedKey),
              let uid = s["uid"] as? String,
              let original = (s["original"] as? [Double])?.map(Float.init), !original.isEmpty,
              let lastSet = (s["lastSet"] as? [Double])?.map(Float.init), !lastSet.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.savedKey); return
        }
        let target = (s["target"] as? [Double])?.map(Float.init) ?? original.map(DuckMath.target)
        let at = Date(timeIntervalSince1970: s["at"] as? Double ?? 0)
        let device = OutputVolume.device(uid: uid)
        let control = device.flatMap { OutputVolume(device: $0) }
        let now = control?.read()
        switch DuckMath.launchDecision(current: now?.first, lastSet: lastSet[0], target: target.first ?? 0, savedAt: at, now: Date()) {
        case .restore:
            control?.write(original)
            Log.note("ducker: put the output volume back after Verbatim last quit while it was lowered")
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        case .leave, .drop:
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        case .keepForLater:
            break
        }
    }

    private func restoreBeforeQuit() {
        q.sync {
            generation += 1
            guard let d = ducked else { return }
            if let now = d.control.read(), !DuckMath.userChanged(current: now[0], lastSet: d.lastSet[0]) { d.control.write(d.original) }
            forget()
        }
    }
}

// MARK: - Self-test

enum AudioDuckerSelfTest {
    static func run(_ check: (String, Bool) -> Void) {
        func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.0001 }
        check("ducker: target is 10% of the current volume", near(DuckMath.target(0.8), 0.08) && near(DuckMath.target(0.25), 0.025)
              && near(DuckMath.target(0), 0) && near(DuckMath.target(1), 0.1))
        check("ducker: skips muted, silent, and unsettable outputs", !DuckMath.shouldDuck(volume: 0.5, muted: true, settable: true)
              && !DuckMath.shouldDuck(volume: 0, muted: false, settable: true) && !DuckMath.shouldDuck(volume: 0.5, muted: false, settable: false)
              && !DuckMath.shouldDuck(volume: nil, muted: false, settable: true) && DuckMath.shouldDuck(volume: 0.5, muted: false, settable: true))
        var h = DuckHolders()
        let first = h.acquire("dictation")
        let second = h.acquire("voiceNote")
        let again = h.acquire("dictation")
        let endOne = h.release("dictation")
        let endStray = h.release("captions")
        let endLast = h.release("voiceNote")
        check("ducker: overlapping listeners lower once and restore once", first && !second && !again && !endOne && !endStray && endLast && h.isEmpty)
        check("ducker: a volume you change while lowered is kept", DuckMath.userChanged(current: 0.5, lastSet: 0.05)
              && !DuckMath.userChanged(current: 0.055, lastSet: 0.05) && DuckMath.userChanged(current: 0.0, lastSet: 0.08))
        let down = DuckMath.fadeSteps(from: 0.6, to: 0.06, duration: DuckMath.fadeDown)
        let up = DuckMath.fadeSteps(from: 0.06, to: 0.6, duration: DuckMath.fadeUp)
        check("ducker: fades end exactly on the level and move one way", down.count == 10 && up.count == 20 && down.last == 0.06 && up.last == 0.6
              && zip(down, down.dropFirst()).allSatisfy { $0 > $1 } && zip(up, up.dropFirst()).allSatisfy { $0 < $1 })
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        check("ducker: after a crash, restores only a volume still lowered",
              DuckMath.launchDecision(current: 0.06, lastSet: 0.06, target: 0.06, savedAt: t0, now: t0) == .restore
              && DuckMath.launchDecision(current: 0.06, lastSet: 0.3, target: 0.06, savedAt: t0, now: t0) == .restore
              && DuckMath.launchDecision(current: 0.7, lastSet: 0.06, target: 0.06, savedAt: t0, now: t0) == .leave
              && DuckMath.launchDecision(current: nil, lastSet: 0.06, target: 0.06, savedAt: t0, now: t0.addingTimeInterval(60)) == .keepForLater
              && DuckMath.launchDecision(current: nil, lastSet: 0.06, target: 0.06, savedAt: t0, now: t0.addingTimeInterval(13 * 3600)) == .drop)
        check("ducker: on unless you turn it off", UserDefaults.standard.object(forKey: LowerAudioSetting.key) != nil || LowerAudioSetting.isOn)
        check("settings search finds Lower other audio", SettingsIndex.search("music").map(\.id).contains("dictate.lowerAudio")
              && SettingsIndex.search("duck").map(\.id).contains("dictate.lowerAudio"))
    }
}
#endif
