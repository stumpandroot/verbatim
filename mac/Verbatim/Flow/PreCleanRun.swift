import AVFoundation
import Foundation

/// One dictation's clean-while-you-talk worker (the rules, and what it must never do, are in Model/PreClean.swift).
///
/// While you talk it copies the audio from the recorder's tap (`PreCleanAudio`; the recording and its file are never
/// touched), and at each pause transcribes everything said so far the way the release will: the same model, silence
/// trimming, and boost rule (`FluidEngine.transcribeDictationSoFar`), then the Dictionary, the pause hints, and
/// the rules. Finished sentences go to `PreCleanSession`, which cleans them with Apple's on-device model. Everything
/// runs at utility priority, one snapshot at a time. When you let go, cleanup asks the session what it can reuse
/// (`FlowCleanup.Request.preClean`).
///
/// It skips "Only keep my voice" (`VoiceProfile.filterDictation` needs the finished file): when that filter drops
/// words, the final text no longer starts the same, and only the parts before the change are reused.
final class PreCleanRun: @unchecked Sendable {
    /// What the release will use for this dictation, read as it starts. A setting changed while you talk makes the
    /// release's key differ, and then nothing is reused.
    struct Setup {
        var model: String
        /// Your Dictionary words that apply here (everywhere, plus the active project's).
        var dictionary: [DictionaryEntry]
        /// The words the boost listens for; empty when boosting is off.
        var boost: [DictionaryEntry]
        var project: UUID?
        var handsFree: Bool
        var level: CleanupLevel
        var styles: [AppCategory: FlowStyle]
        var vocabulary: [String]
        var useContext: Bool
        var context: AppContext?
        var site: SiteProbe?
    }

    let session: PreCleanSession
    private let audio = PreCleanAudio()
    private let request: RequestBox
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var released = false
    private var over = false

    /// The cleanup request the parts are cleaned for, set once the worker has worked it out.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: FlowCleanup.Request?
        func get() -> FlowCleanup.Request? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ r: FlowCleanup.Request?) { lock.lock(); value = r; lock.unlock() }
    }

    init() {
        let box = RequestBox()
        request = box
        session = PreCleanSession { text, first in
            guard let r = box.get() else { return nil }
            return await FlowCleanup.cleanAhead(r, text: text, first: first)
        }
    }

    /// For the recorder's live tap: keeps a copy of each 16 kHz mono buffer as it's written. Called on the audio
    /// thread. Audio in any other format ends the run (the release then cleans everything, as before).
    var tap: @Sendable (AVAudioPCMBuffer) -> Void {
        { [audio] buffer in
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            guard buffer.format.sampleRate == PreCleanAudio.rate, buffer.format.channelCount == 1, let data = buffer.int16ChannelData else {
                audio.stop()
                return
            }
            audio.append(UnsafeBufferPointer(start: data[0], count: n))
        }
    }

    /// Starts watching for pauses. Does nothing after `cancel`.
    func start(_ setup: Setup) {
        let task = Task.detached(priority: .utility) { [self] in await work(setup) }
        lock.lock()
        let stale = over || released || loop != nil
        if !stale { loop = task }
        lock.unlock()
        if stale { task.cancel() }
    }

    private var listening: Bool { lock.lock(); defer { lock.unlock() }; return !over && !released }

    private func work(_ s: Setup) async {
        var base: FlowCleanup.Request?
        var lastTotal = 0.0, idle = 0
        while listening, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard listening, !Task.isCancelled else { return }
            let now = audio.status
            if now.over { return }
            // No audio for 30 seconds: the recording ended without telling this run. Never keep running.
            idle = now.total == lastTotal ? idle + 1 : 0
            lastTotal = now.total
            if idle >= 120 { cancel(); return }
            guard PreClean.Pacing.shouldSnapshot(total: now.total, lastSnapshotAt: now.lastSnapshotAt, speechSince: now.speechSince,
                                                 trailingSilence: now.trailingSilence) else { continue }
            if base == nil {
                // Before the first snapshot: the checks that would be too slow for key-down (the keychain, the model).
                guard let r = await Self.request(s) else { cancel(); return }
                base = r
                request.set(r)
                await session.start(key: FlowCleanup.preCleanKey(r))
            }
            guard var r = base, let samples = audio.snapshot() else { continue }
            guard let heard = try? await FluidEngine.shared.transcribeDictationSoFar(samples: samples, model: s.model, dictionary: s.boost, project: s.project) else { continue }
            // You let go (or cancelled) meanwhile: this snapshot is dropped, and what's sealed already stays.
            guard listening, !Task.isCancelled else { return }
            var segments = heard.segments
            _ = DictionaryApplier.apply(s.dictionary, to: &segments, project: s.project)
            r.raw = DictationController.spokenText(segments, pauseHints: true, handsFree: s.handsFree)
            guard let pre = FlowCleanup.preCleanInput(r) else { continue }
            await session.offer(pre)
        }
    }

    /// The request the release will build for this dictation (`DictationController.finishNow`), or nil when this
    /// dictation isn't one to clean ahead: a code app, cloud cleanup, or no Apple Intelligence.
    private static func request(_ s: Setup) async -> FlowCleanup.Request? {
        let ctx = s.context
        let host = await SiteHostCache.resolve(s.site, bundleID: ctx?.bundleID, title: ctx?.windowTitle ?? "")
        let category = ctx.map { AppContext.category(bundleID: $0.bundleID, title: $0.windowTitle, host: host) } ?? .other
        // Cloud cleanup that Local Only would refuse cleans nothing, so Apple's model does, here and at the release.
        let cloud = CloudCleanup.current != nil && NetworkGate.permits(.cloudCleanup)
        guard PreClean.allowed(flag: true, engine: "fluid", command: false, thought: false, usesModel: s.level.usesModel,
                               codeApp: category == .code, cloudCleanup: cloud, modelAvailable: FlowCleanup.available) else { return nil }
        var r = FlowCleanup.Request(raw: "", level: s.level, style: s.styles[category] ?? .casual, category: category, context: ctx,
                                    vocabulary: s.vocabulary, useContext: s.useContext)
        r.pauseHints = true
        return r
    }

    /// Letting go: no more snapshots, and the audio copy is dropped. Parts sealed so far stay for the release.
    func letGo() {
        lock.lock()
        released = true
        let task = loop
        loop = nil
        lock.unlock()
        task?.cancel()
        audio.stop()
    }

    /// Esc, a new dictation, or any stop that isn't a release: everything is dropped and the model stops.
    func cancel() {
        lock.lock()
        over = true
        let task = loop
        loop = nil
        lock.unlock()
        task?.cancel()
        audio.stop()
        request.set(nil)
        Task.detached(priority: .utility) { [session] in await session.cancel() }
    }

    /// The release is done with it: the counts for the log, and everything dropped.
    func end() async -> PreClean.Stats {
        let stats = await session.stats()
        cancel()
        return stats
    }
}
