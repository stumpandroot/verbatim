import Foundation
import AVFoundation
import Combine
import Speech

// MARK: - Live words
//
// A preview of your words while you speak, made on this device. It never replaces the main transcription: the text
// that's pasted or saved still comes from the main engine (Parakeet or Whisper) after you stop.
//
// - macOS 26 / iOS 26 and later: Apple's SpeechAnalyzer with a SpeechTranscriber module, which streams volatile
//   (best guess so far) and finalized results. Its model is a system asset; `prepare()` asks for it to be installed.
// - Earlier systems, or a language SpeechAnalyzer doesn't support: SFSpeechRecognizer with on-device recognition
//   required. It needs speech recognition permission.
// - Neither possible on device: live words are off. Nothing is shown and nothing is reported. Audio never leaves
//   the device.
//
// Use (Mac dictation, and later the iPhone keyboard session and Live Captions):
//
//     recorder.liveTap = transcriber.tap          // before recorder.start; the capture feeds it, no second mic
//     try recorder.start(to: url)
//     transcriber.start(format: Recorder.targetFormat)
//     …  observe transcriber.text / transcriber.words / transcriber.state
//     transcriber.stop()                          // at once; doesn't wait for final results
//
// Any capture can call `feed(_:)` (or `tap`) directly, from any thread, with buffers in any PCM format.

/// The words heard so far: the settled part (final, won't change) and the volatile tail (may still change).
struct LiveWords: Equatable {
    var settled = ""
    var volatile = ""

    var text: String { Self.join(settled, volatile) }
    var isEmpty: Bool { settled.isEmpty && volatile.isEmpty }

    /// The end of the words, at most `limit` characters, starting at a word boundary.
    func tail(_ limit: Int) -> LiveWords {
        let full = text
        guard full.count > limit else { return self }
        var cut = full.suffix(limit)
        if let space = cut.firstIndex(of: " ") { cut = cut[cut.index(after: space)...] }
        let t = String(cut)
        let vol = volatile.trimmingCharacters(in: .whitespaces)
        if vol.isEmpty { return LiveWords(settled: t, volatile: "") }
        if t.count <= vol.count { return LiveWords(settled: "", volatile: t) }
        return LiveWords(settled: String(t.dropLast(vol.count)).trimmingCharacters(in: .whitespaces), volatile: vol)
    }

    /// The words split for display: everything before the newest word, settled and volatile, and the newest word.
    var display: (settled: String, volatile: String, newest: String) {
        let vol = volatile.trimmingCharacters(in: .whitespaces)
        if !vol.isEmpty {
            let (rest, last) = Self.splitLast(vol)
            return (settled, rest, last)
        }
        let (rest, last) = Self.splitLast(settled.trimmingCharacters(in: .whitespaces))
        return (rest, "", last)
    }

    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    private static func splitLast(_ s: String) -> (String, String) {
        guard let space = s.lastIndex(of: " ") else { return ("", s) }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }
}

/// Streams live words from audio fed by an existing capture. One session at a time; `start` ends any previous one.
/// Main actor for its published state; `feed(_:)` and `tap` are safe from the audio thread.
@MainActor
final class LiveTranscriber: ObservableObject {
    enum State: Equatable {
        /// Not running, or live words aren't possible here.
        case off
        /// A session was asked for and the recognizer is being set up. Audio is held meanwhile.
        case starting
        /// Words can arrive.
        case running
    }

    @Published private(set) var state: State = .off
    /// The words so far, settled and volatile.
    @Published private(set) var words = LiveWords()
    /// The words so far as one string (settled, then volatile).
    @Published private(set) var text = ""

    /// The language to recognize. Defaults to the system language.
    var locale: Locale = .current

    /// The audio thread side. Thread-safe.
    nonisolated let input = LiveInput()

    /// Pass to a capture (such as `Recorder.liveTap`) to feed this transcriber.
    nonisolated var tap: @Sendable (AVAudioPCMBuffer) -> Void {
        { [input] buffer in input.feed(buffer) }
    }

    private var backend: LiveBackend?
    private var session = 0
    /// Word-by-word updates, at most 15 a second: words that arrive faster wait for the next frame.
    static let minInterval: TimeInterval = 1.0 / 15
    private var pending: LiveWords?
    private var lastPublish = Date.distantPast
    private var flushScheduled = false

    init() {}

    /// Gets ready ahead of time, without starting: asks for the on-device model to be installed (SpeechAnalyzer),
    /// and, only when `allowPermissionPrompt` and the fallback recognizer is what this device would use, asks for
    /// speech recognition permission once. Never call it with prompts allowed while text is about to be pasted.
    func prepare(allowPermissionPrompt: Bool = false) {
        let locale = self.locale
        Task.detached(priority: .utility) {
            if #available(macOS 26.0, iOS 26.0, *), let l = await AnalyzerBackend.supportedLocale(for: locale) {
                if !(await AnalyzerBackend.isInstalled(l)) { await AnalyzerBackend.install(l) }
                return
            }
            guard allowPermissionPrompt, SFSpeechRecognizer.authorizationStatus() == .notDetermined,
                  let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition else { return }
            SFSpeechRecognizer.requestAuthorization { status in
                Log.note("live words: speech recognition permission \(status.rawValue)")
            }
        }
    }

    /// Starts a session. `format` is the format the capture will feed (a hint; buffers in any format are converted).
    /// Audio fed before the recognizer is ready is held (up to 10 s) and analyzed first, so the first word isn't lost.
    func start(format: AVAudioFormat? = nil) {
        stop()
        session += 1
        let mine = session
        input.open()
        state = .starting
        let locale = self.locale
        let onWords: @Sendable (LiveWords) -> Void = { [weak self] w in
            Task { @MainActor [weak self] in self?.receive(w, session: mine) }
        }
        Task { [weak self] in
            let made = await LiveTranscriber.makeBackend(locale: locale, expecting: format, onWords: onWords)
            guard let self, self.session == mine, self.state == .starting else { made?.cancel(); return }
            guard let made else {
                // Not possible on device: live words stay off, quietly.
                self.input.close()
                self.state = .off
                return
            }
            self.backend = made
            self.state = .running
            self.input.connect { buffer in made.feed(buffer) }
        }
    }

    /// Feeds audio. Any thread, any PCM format. Ignored when no session is running.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) { input.feed(buffer) }

    /// Ends the session at once and clears the words. Doesn't wait for final results, so it never delays the main
    /// transcription that follows.
    func stop() {
        session += 1
        input.close()
        backend?.cancel()
        backend = nil
        pending = nil
        flushScheduled = false
        if state != .off { state = .off }
        if !words.isEmpty { words = LiveWords() }
        if !text.isEmpty { text = "" }
    }

    /// Shows new words at once, unless the last update was under `minInterval` ago; then the newest words go out
    /// when it has passed (words in between are skipped, never queued).
    private func receive(_ w: LiveWords, session mine: Int) {
        guard mine == session, state == .running else { return }
        pending = w
        let wait = Self.minInterval - Date().timeIntervalSince(lastPublish)
        if wait <= 0 { publish(); return }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, self.session == mine, self.flushScheduled else { return }
            self.flushScheduled = false
            self.publish()
        }
    }

    private func publish() {
        guard let w = pending else { return }
        pending = nil
        lastPublish = Date()
        guard w != words else { return }
        words = w
        text = w.text
    }

    nonisolated private static func makeBackend(locale: Locale, expecting: AVAudioFormat?, onWords: @escaping @Sendable (LiveWords) -> Void) async -> LiveBackend? {
        if #available(macOS 26.0, iOS 26.0, *), let l = await AnalyzerBackend.supportedLocale(for: locale) {
            if await AnalyzerBackend.isInstalled(l) {
                do {
                    if let b = try await AnalyzerBackend.make(locale: l, expecting: expecting, onWords: onWords) { return b }
                } catch {
                    Log.note("live words: SpeechAnalyzer couldn't start: \(error.localizedDescription)")
                }
            } else {
                // Ready for a later session; this one tries the fallback, which may also be off.
                Task.detached(priority: .utility) { await AnalyzerBackend.install(l) }
            }
        }
        return RecognizerBackend.make(locale: locale, onWords: onWords)
    }
}

// MARK: - Audio thread side

/// Holds audio until the recognizer is ready, then hands each buffer straight to it. Thread-safe. Buffers are
/// handed over in order, with the lock held; the recognizer's feed is cheap (a format conversion and a queue).
final class LiveInput: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = false
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var held: [AVAudioPCMBuffer] = []
    private var heldSeconds: Double = 0
    private static let holdLimit: Double = 10

    func open() {
        lock.lock(); accepting = true; sink = nil; held = []; heldSeconds = 0; lock.unlock()
    }

    func connect(_ s: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        for b in held { s(b) }
        held = []; heldSeconds = 0
        sink = s
    }

    func close() {
        lock.lock(); accepting = false; sink = nil; held = []; heldSeconds = 0; lock.unlock()
    }

    /// The buffer may be kept: callers pass buffers they won't reuse (`Recorder` makes a new one per call).
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        if let sink { sink(buffer); return }
        held.append(buffer)
        heldSeconds += Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
        while heldSeconds > Self.holdLimit, !held.isEmpty {
            let b = held.removeFirst()
            heldSeconds -= Double(b.frameLength) / max(1, b.format.sampleRate)
        }
    }
}

/// A recognizer behind a session. `feed` is called serially (under `LiveInput`'s lock); `cancel` from the main actor.
protocol LiveBackend: AnyObject {
    func feed(_ buffer: AVAudioPCMBuffer)
    func cancel()
}

/// Converts buffers to one format, rebuilding the converter if the input format changes. Not thread-safe; used
/// serially.
final class LiveConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?
    private var from: AVAudioFormat?

    init(output: AVAudioFormat, expecting: AVAudioFormat? = nil) {
        self.output = output
        if let expecting, expecting != output {
            converter = AVAudioConverter(from: expecting, to: output)
            from = expecting
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if buffer.format == output { return buffer }
        if from != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            from = buffer.format
        }
        guard let converter, buffer.format.sampleRate > 0 else { return nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}

// MARK: - SpeechAnalyzer (macOS 26, iOS 26)

@available(macOS 26.0, iOS 26.0, *)
final class AnalyzerBackend: LiveBackend, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: LiveConverter
    private var results: Task<Void, Never>?

    private init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation, converter: LiveConverter) {
        self.analyzer = analyzer
        self.continuation = continuation
        self.converter = converter
    }

    /// Volatile results, and fast results: Apple's progressive (live) configuration, which reports each new word
    /// as it's heard instead of a few words at a time. Finalized results still replace them as they settle.
    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    /// The supported locale that matches `wanted`: the same language and region, else the same language.
    static func supportedLocale(for wanted: Locale) async -> Locale? {
        let supported: [Locale] = Array(await SpeechTranscriber.supportedLocales)
        let tag = wanted.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == tag }) { return exact }
        guard let language = wanted.language.languageCode?.identifier else { return nil }
        let region = wanted.region?.identifier
        return supported.first { $0.language.languageCode?.identifier == language && $0.region?.identifier == region }
            ?? supported.first { $0.language.languageCode?.identifier == language }
    }

    static func isInstalled(_ locale: Locale) async -> Bool {
        let installed: [Locale] = Array(await SpeechTranscriber.installedLocales)
        let tag = locale.identifier(.bcp47)
        return installed.contains { $0.identifier(.bcp47) == tag }
    }

    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installing: Set<String> = []

    /// Asks the system to download and install the model for `locale` (a system asset, shared between apps).
    static func install(_ locale: Locale) async {
        let tag = locale.identifier(.bcp47)
        installLock.lock()
        let already = installing.contains(tag)
        if !already { installing.insert(tag) }
        installLock.unlock()
        guard !already else { return }
        defer { installLock.lock(); installing.remove(tag); installLock.unlock() }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale)]) {
                Log.note("live words: installing the speech model for \(tag)")
                try await request.downloadAndInstall()
                Log.note("live words: speech model for \(tag) installed")
            }
        } catch {
            Log.note("live words: couldn't install the speech model for \(tag): \(error.localizedDescription)")
        }
    }

    static func make(locale: Locale, expecting: AVAudioFormat?, onWords: @escaping @Sendable (LiveWords) -> Void) async throws -> AnalyzerBackend? {
        let transcriber = makeTranscriber(locale)
        let best: AVAudioFormat? = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let format = best else { return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let backend = AnalyzerBackend(analyzer: analyzer, continuation: continuation, converter: LiveConverter(output: format, expecting: expecting))
        // User-initiated: results feed what you see while you talk, so they shouldn't wait behind background work.
        backend.results = Task.detached(priority: .userInitiated) {
            var settled = ""
            do {
                for try await result in transcriber.results {
                    if Task.isCancelled { break }
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        settled = LiveWords.join(settled, piece)
                        onWords(LiveWords(settled: settled, volatile: ""))
                    } else {
                        onWords(LiveWords(settled: settled, volatile: piece))
                    }
                }
            } catch {
                if !Task.isCancelled { Log.note("live words: SpeechAnalyzer stopped: \(error.localizedDescription)") }
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            backend.cancel()
            throw error
        }
        return backend
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func cancel() {
        continuation.finish()
        results?.cancel()
        let analyzer = self.analyzer
        Task.detached(priority: .utility) { try? await analyzer.cancelAndFinishNow() }
    }
}

// MARK: - SFSpeechRecognizer, on device only (fallback)

final class RecognizerBackend: LiveBackend, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let onWords: @Sendable (LiveWords) -> Void
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Words from earlier requests: a recognition task can end on its own (a long pause), and a new one carries on.
    private var before = ""
    private var latest = ""
    private var cancelled = false
    /// Restarts in a row that brought no words; after a few, stop trying for this session.
    private var emptyRestarts = 0
    private let converter = LiveConverter(output: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)

    private init(recognizer: SFSpeechRecognizer, onWords: @escaping @Sendable (LiveWords) -> Void) {
        self.recognizer = recognizer
        self.onWords = onWords
    }

    /// Nil unless on-device recognition is possible right now and permission was already given. Never asks.
    static func make(locale: Locale, onWords: @escaping @Sendable (LiveWords) -> Void) -> RecognizerBackend? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition, r.isAvailable else { return nil }
        let b = RecognizerBackend(recognizer: r, onWords: onWords)
        b.lock.lock(); b.begin(); b.lock.unlock()
        return b
    }

    /// Starts a request. Called with `lock` held.
    private func begin() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handle(result, error, for: req)
        }
    }

    private func handle(_ result: SFSpeechRecognitionResult?, _ error: Error?, for req: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        guard !cancelled, req === request else { lock.unlock(); return }
        if let result { latest = result.bestTranscription.formattedString }
        if error != nil || result?.isFinal == true {
            if latest.isEmpty { emptyRestarts += 1 } else { emptyRestarts = 0 }
            before = LiveWords.join(before, latest)
            latest = ""
            task = nil
            if emptyRestarts < 3 { begin() } else { request = nil }
        }
        // Partial results revise freely; treat the last word as the volatile one.
        let all = LiveWords.join(before, latest)
        let words: LiveWords
        if let space = all.lastIndex(of: " "), !latest.isEmpty {
            words = LiveWords(settled: String(all[..<space]), volatile: String(all[all.index(after: space)...]))
        } else {
            words = LiveWords(settled: latest.isEmpty ? all : "", volatile: latest.isEmpty ? "" : all)
        }
        lock.unlock()
        onWords(words)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        lock.lock(); let req = cancelled ? nil : request; lock.unlock()
        req?.append(converted)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task, r = request
        task = nil; request = nil
        lock.unlock()
        t?.cancel()
        r?.endAudio()
    }
}
