import Foundation
import AVFoundation
#if os(iOS)
import AudioToolbox
import UIKit
#endif

/// Plays Verbose's interface sounds (DESIGN.md §7, Sounds; the moments and rules are SoundRules.swift). Every file is
/// loaded at launch (`preload`), so dictation's tick plays without reading a file, and each plays at its own level:
/// the set was loudness-matched by ear, so nothing here changes a volume.
///
/// - Mac: one prepared `AVAudioPlayer` per file, at volume 1. Follows Settings › General › Sounds (`enabled`, set by
///   AppState). Sound isn't motion, so Reduce Motion doesn't silence it.
/// - iPhone: system sounds made from the same files (`AudioServicesCreateSystemSoundID`). They mix with your music
///   instead of stopping it, never touch the recording's audio session, follow the Ring/Silent switch, and play while
///   recording because every recording session allows them (`RecordingRoute.allowHaptics`). They follow Settings ›
///   Haptics, the iPhone's one switch for feedback, and play only with Verbose in front, as haptics do.
///
/// Two sounds never play within 150 ms of each other (`SoundSpacing`): the second is dropped.
@MainActor
enum Sounds {
    #if os(macOS)
    /// Settings › General › Sounds.
    static var enabled = true
    private static var players: [SoundMoment: AVAudioPlayer] = [:]
    #else
    /// Settings › Personalization and preferences › Haptics.
    static var enabled: Bool { Haptics.enabled }
    private static var ids: [SoundMoment: SystemSoundID] = [:]
    #endif
    private static var spacing = SoundSpacing()

    /// The bundled file for a moment.
    nonisolated static func url(_ m: SoundMoment) -> URL? {
        Bundle.main.url(forResource: m.fileName, withExtension: SoundMoment.fileExtension)
            ?? Bundle.main.url(forResource: m.fileName, withExtension: SoundMoment.fileExtension, subdirectory: "Sounds")
    }

    /// Loads every sound, once. Called at launch.
    static func preload() {
        for m in SoundMoment.allCases { _ = loaded(m) }
    }

    /// The moments whose file is missing or won't load (the self-tests expect none).
    static func unloadable() -> [SoundMoment] {
        SoundMoment.allCases.filter { !loaded($0) }
    }

    /// Plays the moment's sound. Returns its length in seconds when it plays, nil when it doesn't (sounds off, Verbose
    /// in the background on the iPhone, or another sound under 150 ms ago). A start played into an open microphone
    /// passes the length to the recorder (`Recorder.keepOut`).
    @discardableResult
    static func play(_ m: SoundMoment) -> Double? {
        guard enabled else { return nil }
        #if os(iOS)
        guard SoundRules.phonePlays(foreground: UIApplication.shared.applicationState == .active) else { return nil }
        #endif
        guard loaded(m) else { return nil }
        guard spacing.allows(at: ProcessInfo.processInfo.systemUptime) else {
            Log.note("sound: \(m.fileName) dropped (another sound under 150 ms ago)")
            return nil
        }
        #if os(macOS)
        guard let p = players[m] else { return nil }
        if p.isPlaying { p.stop() }
        p.currentTime = 0
        p.volume = 1
        p.play()
        #else
        guard let id = ids[m] else { return nil }
        AudioServicesPlaySystemSound(id)
        #endif
        return m.seconds
    }

    /// Plays a start that the microphone may hear, and keeps it out of `recorder`'s recording.
    static func play(_ m: SoundMoment, keepingOutOf recorder: Recorder) {
        guard let seconds = play(m) else { return }
        recorder.keepOut(seconds: seconds)
    }

    private static func loaded(_ m: SoundMoment) -> Bool {
        #if os(macOS)
        if players[m] != nil { return true }
        guard let u = url(m), let p = try? AVAudioPlayer(contentsOf: u) else {
            Log.note("sound: couldn't load \(m.fileName).\(SoundMoment.fileExtension)")
            return false
        }
        p.volume = 1
        p.prepareToPlay()
        players[m] = p
        return true
        #else
        if ids[m] != nil { return true }
        var id: SystemSoundID = 0
        guard let u = url(m), AudioServicesCreateSystemSoundID(u as CFURL, &id) == kAudioServicesNoError else {
            Log.note("sound: couldn't load \(m.fileName).\(SoundMoment.fileExtension)")
            return false
        }
        ids[m] = id
        return true
        #endif
    }
}
