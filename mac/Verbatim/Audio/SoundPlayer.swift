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
/// - Mac: one prepared `AVAudioPlayer` per file, at volume 1, prepared off the main thread (preparing the first one
///   waits for the system's audio services, which took seconds at launch in the self-test). Follows Settings › General › Sounds (`enabled`, set by
///   AppState). Sound isn't motion, so Reduce Motion doesn't silence it.
/// - iPhone: system sounds made from the same files (`AudioServicesCreateSystemSoundID`). They mix with your music
///   instead of stopping it, never touch the recording's audio session, follow the Ring/Silent switch, and play while
///   recording because every recording session allows them (`RecordingRoute.allowHaptics`). They follow Settings ›
///   Sounds (its own switch, apart from Haptics) and play only with Verbose in front, as haptics do.
///
/// Two sounds never play within 150 ms of each other (`SoundSpacing`): the second is dropped.
@MainActor
enum Sounds {
    #if os(macOS)
    /// Settings › General › Sounds.
    static var enabled = true
    private static var players: [SoundMoment: AVAudioPlayer] = [:]
    private static var preloading = false
    /// Players made off the main thread, on their way to it.
    private struct Prepared: @unchecked Sendable { let players: [(SoundMoment, AVAudioPlayer)] }
    #else
    /// Settings › Personalization and preferences › Sounds, apart from Haptics (`SoundSettings`).
    static var enabled: Bool { SoundSettings.enabled(in: Haptics.store) }
    private static var ids: [SoundMoment: SystemSoundID] = [:]
    #endif
    private static var spacing = SoundSpacing()

    /// The bundled file for a moment.
    nonisolated static func url(_ m: SoundMoment) -> URL? {
        Bundle.main.url(forResource: m.fileName, withExtension: SoundMoment.fileExtension)
            ?? Bundle.main.url(forResource: m.fileName, withExtension: SoundMoment.fileExtension, subdirectory: "Sounds")
    }

    /// Loads every sound, once. Called at launch. On the Mac the players are prepared in the background and arrive a
    /// moment later; a sound asked for before then is loaded on the spot (`loaded`).
    static func preload() {
        #if os(macOS)
        guard !preloading else { return }
        preloading = true
        let wanted = SoundMoment.allCases.filter { players[$0] == nil }
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let made = Prepared(players: wanted.compactMap { m in prepared(m).map { (m, $0) } })
            DispatchQueue.main.async {
                for (m, p) in made.players where players[m] == nil { players[m] = p }
                let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
                Log.note("sound: \(made.players.count) of \(wanted.count) prepared in \(ms) ms, off the main thread")
            }
        }
        #else
        for m in SoundMoment.allCases { _ = loaded(m) }
        #endif
    }

    /// Whether every sound is prepared (the Mac prepares them in the background at launch).
    static var allPrepared: Bool {
        #if os(macOS)
        return players.count == SoundMoment.allCases.count
        #else
        return ids.count == SoundMoment.allCases.count
        #endif
    }

    /// The moments whose file is missing or won't load (the self-tests expect none).
    static func unloadable() -> [SoundMoment] {
        SoundMoment.allCases.filter { !loaded($0) }
    }

    /// Plays the moment's sound. Returns its length in seconds when it plays, nil when it doesn't (sounds off, Verbose
    /// in the background on the iPhone, or another sound under 150 ms ago). A start that opens the microphone goes
    /// through `playBeforeMic` instead.
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

    /// Plays a start before `recorder` starts (call it just before `start` or `begin`): the recording keeps what the
    /// microphone hears from when the sound ends (`MicArm`), so the sound is never in it and nothing is silenced. When
    /// the sound doesn't play (sounds off, Verbose in the background), the recording keeps everything from its start.
    static func playBeforeMic(_ m: SoundMoment, arming recorder: Recorder) {
        recorder.armAfterSound(seconds: play(m))
    }

    #if os(macOS)
    /// A prepared player for the moment's file. Safe to call off the main thread.
    nonisolated private static func prepared(_ m: SoundMoment) -> AVAudioPlayer? {
        guard let u = url(m), let p = try? AVAudioPlayer(contentsOf: u) else {
            Log.note("sound: couldn't load \(m.fileName).\(SoundMoment.fileExtension)")
            return nil
        }
        p.volume = 1
        p.prepareToPlay()
        return p
    }
    #endif

    private static func loaded(_ m: SoundMoment) -> Bool {
        #if os(macOS)
        if players[m] != nil { return true }
        guard let p = prepared(m) else { return false }
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
