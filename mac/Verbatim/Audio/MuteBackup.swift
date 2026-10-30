#if os(macOS)
import AVFoundation

/// The audio-thread side of the Mac's backup from the built-in mic (DESIGN.md §6.10, A muted microphone, Model/MuteRules.swift). While a
/// normal recording uses another mic, the built-in mic runs beside it and both feed this instead of the writer:
/// `MuteSplice` decides what's written, and this writes it, under one lock, so the two devices' threads never write out
/// of order. The recorder decides when the chosen mic is muted (`useBackup`) and back (`usePrimary`).
final class MuteBackup: @unchecked Sendable {
    private let lock = NSLock()
    private var splice = MuteSplice<AVAudioPCMBuffer>()
    private let writer: RecordingWriter
    private let onLevel: @Sendable (Float, TimeInterval) -> Void
    /// Detached (the recording stopped, paused, or changed mic): the chosen mic's audio is written as it comes.
    private var passthrough = false
    private var monoFormats: [Double: AVAudioFormat] = [:]

    init(writer: RecordingWriter, onLevel: @escaping @Sendable (Float, TimeInterval) -> Void) {
        self.writer = writer
        self.onLevel = onLevel
    }

    /// A buffer from the chosen mic (its input unit's thread). Quiet audio is copied, since the unit reuses its buffer.
    func primary(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(buffer)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let now = ProcessInfo.processInfo.systemUptime
        writer.notice(heard: rms > 0)
        lock.lock()
        // Paused: written as it comes (the writer drops it), so nothing heard during a pause is held for after it.
        if passthrough || writer.paused {
            for b in splice.flush() { _ = writer.write(b) }
            let v = writer.write(buffer)
            let secs = writer.seconds
            lock.unlock()
            onLevel(v, secs)
            return
        }
        let piece = MuteRules.quiet(rms) && !splice.onBackup ? (Self.copy(buffer) ?? buffer) : buffer
        for b in splice.primary(piece, at: now, seconds: seconds, rms: rms) { _ = writer.write(b) }
        let held = splice.heldSeconds, onBackup = splice.onBackup
        let secs = writer.seconds + held
        lock.unlock()
        // On the backup, the built-in mic drives the meter.
        if !onBackup { onLevel(MuteRules.meterLevel(rms), secs) }
    }

    /// A buffer from the built-in mic (its own unit's thread): its first channel is kept, and written while on the backup.
    func backup(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(buffer)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !passthrough, let mono = mono(buffer) else { lock.unlock(); return }
        let out = splice.backup(mono, at: now, seconds: seconds, rms: rms)
        for b in out { _ = writer.write(b) }
        let secs = writer.seconds
        lock.unlock()
        if !out.isEmpty { onLevel(MuteRules.meterLevel(rms), secs) }
    }

    /// The chosen mic is muted: the built-in mic's audio replaces what was held, and is written from now on.
    func useBackup() {
        lock.lock(); defer { lock.unlock() }
        guard !passthrough else { return }
        let out = splice.useBackup()
        for b in out { _ = writer.write(b) }
        Log.note("recorder: backup filled \(String(format: "%.1f", out.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate })) s from the built-in mic")
    }

    /// The chosen mic is back: its audio is written again.
    func usePrimary() {
        lock.lock(); splice.usePrimary(); lock.unlock()
    }

    /// Writes what's held now (before a pause, so it lands before the pause in the file).
    func flush() {
        lock.lock(); defer { lock.unlock() }
        for b in splice.flush() { _ = writer.write(b) }
    }

    /// Writes what's held, and from now on writes the chosen mic's audio as it comes and ignores the built-in mic.
    func detach() {
        lock.lock(); defer { lock.unlock() }
        if !splice.onBackup { for b in splice.flush() { _ = writer.write(b) } }
        passthrough = true
    }

    struct Status {
        var heldSeconds: Double
        var backupSpeechSeconds: Double
        var onBackup: Bool
        var primaryLoudAt: Double?
    }

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        return Status(heldSeconds: splice.heldSeconds, backupSpeechSeconds: splice.backupSpeechSeconds, onBackup: splice.onBackup,
                      primaryLoudAt: splice.primaryLoudAt)
    }

    // MARK: Buffers

    private static func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData?[0], b.frameLength > 0 else { return 0 }
        let n = Int(b.frameLength)
        let stride = b.format.isInterleaved ? Int(b.format.channelCount) : 1
        var sum: Float = 0
        for i in 0..<n { let s = ch[i * stride]; sum += s * s }
        return sqrt(sum / Float(n))
    }

    /// A copy of a float buffer in its own format.
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

    /// The first channel of a float buffer, as a mono buffer at its rate. Called with `lock` held.
    private func mono(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let rate = b.format.sampleRate
        let fmt: AVAudioFormat
        if let f = monoFormats[rate] { fmt = f } else {
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return nil }
            monoFormats[rate] = f; fmt = f
        }
        guard let src = b.floatChannelData?[0], let c = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(1, b.frameLength)),
              let dst = c.floatChannelData?[0] else { return nil }
        let n = Int(b.frameLength)
        if b.format.isInterleaved, b.format.channelCount > 1 {
            let stride = Int(b.format.channelCount)
            for i in 0..<n { dst[i] = src[i * stride] }
        } else {
            dst.update(from: src, count: n)
        }
        c.frameLength = b.frameLength
        return c
    }
}
#endif
