import Foundation
import AVFoundation
import NaturalLanguage
import Speech
#if canImport(UIKit)
import UIKit
#endif

// The language check before a transcription: Parakeet has no language identification, so Verbatim transcribes the
// first ~30 seconds, asks NaturalLanguage which language the words are in, and, when that's unclear, asks Apple's
// on-device recognizer to try the languages you use on this device. LanguageRules.swift turns the answer into a
// route (keep, switch to v3, offer v3, Apple's recognizer, or not possible here).

enum LanguageDetection {
    /// Settings › Models and language › Detect the language. On unless turned off.
    static let enabledKey = "language.detect"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// How much of the start is checked.
    static let clipSeconds = 30.0

    /// "Spanish" for "es", in your language. Falls back to the code.
    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: LanguageRules.base(code))?.capitalized(with: Locale.current) ?? code.uppercased()
    }

    /// What the check found: the guess, and the first pass's words (reused when they already cover the whole
    /// recording with the model the job ends up using).
    struct Outcome {
        var guess: LanguageGuess
        var passModel: String
        var words: [SectionWord]
        var coveredWhole: Bool
    }

    /// Nil when the check couldn't run (unreadable audio, model trouble): the job then runs as set.
    static func check(url: URL, model: String, forceV3: Bool = false, progress: @escaping @Sendable (EngineProgress) -> Void) async -> Outcome? {
        do {
            let audio = try SectionAudio(url: url)
            let total = audio.totalSamples
            guard total >= 2 * SectionAudio.sampleRate else { return nil }
            // A recording barely longer than the clip is checked whole, so its first pass can be the transcript.
            let clip = Double(total) <= (clipSeconds + 5) * Double(SectionAudio.sampleRate) ? total : Int(clipSeconds) * SectionAudio.sampleRate
            let samples = try audio.read(start: 0, count: clip)
            // v3 when it's here (it can hear 25 languages); otherwise the model you picked.
            let passModel = LanguageRules.isMultilingual(model) || !(forceV3 || FluidEngine.isDownloaded("v3")) ? model : "v3"
            progress(.checkingLanguage)
            let words = try await FluidEngine.shared.sectionWords(samples: samples, model: passModel, language: nil, progress: progress)
            let text = words.map(\.text).joined(separator: " ")
            var guess = LanguageGuess.evaluate(hypotheses(text), words: words.count, englishOnlyPass: !LanguageRules.isMultilingual(passModel))
            if guess.wantsConfirmation, AppleSpeech.authorized {
                let candidates = guess.candidates(device: await deviceLanguages())
                var results: [(language: String, confidence: Double, words: Int)] = []
                for c in candidates where AppleSpeech.isAvailable(c) {
                    if let r = await AppleSpeech.confidence(samples: samples, language: c) { results.append((c, r.confidence, r.words)) }
                }
                if let picked = LanguageGuess.pick(results) {
                    Log.note("language check: Apple's recognizer heard \(picked) (Parakeet's guess was \(guess))")
                    guess = .known(picked, LanguageGuess.sure)
                }
            }
            Log.note("language check: \(guess) from \(words.count) words with \(passModel)")
            return Outcome(guess: guess, passModel: passModel, words: words, coveredWhole: clip >= total)
        } catch {
            Log.note("language check skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// NaturalLanguage's top guesses for some text, as (code, probability).
    static func hypotheses(_ text: String) -> [(String, Double)] {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.languageHypotheses(withMaximum: 5).map { ($0.key.rawValue, $0.value) }
    }

    /// Languages you use on this device: preferred languages, then (iPhone) keyboard languages.
    static func deviceLanguages() async -> [String] {
        var out = Locale.preferredLanguages
        #if canImport(UIKit)
        let keyboards = await MainActor.run { UITextInputMode.activeInputModes.compactMap(\.primaryLanguage) }
        out += keyboards.filter { $0 != "dictation" && $0 != "emoji" }
        #endif
        return out
    }

    /// Languages you can pick under Transcribe again in…: Parakeet v3's 25, by name.
    static let pickableV3: [String] = LanguageRules.parakeetV3.sorted { name($0) < name($1) }

    /// The languages Apple's recognizer adds, by name. Whether this device can run one on device is checked when
    /// the job runs.
    static let pickableApple: [String] = {
        let codes = Set(SFSpeechRecognizer.supportedLocales().map { LanguageRules.base($0.identifier) })
        return codes.filter { !LanguageRules.parakeetV3.contains($0) }.sorted { name($0) < name($1) }
    }()
}

/// Apple's speech recognizer, on device only (audio never leaves the device), for languages Parakeet doesn't cover.
/// SFSpeechRecognizer runs on iOS 17 and macOS 14, the apps' oldest systems.
enum AppleSpeech {
    /// The recognizer's locale for a language: one in your preferred languages first, then any.
    static func locale(for language: String) -> Locale? {
        let l = LanguageRules.base(language)
        let supported = SFSpeechRecognizer.supportedLocales().filter { LanguageRules.base($0.identifier) == l }
        guard !supported.isEmpty else { return nil }
        for p in Locale.preferredLanguages {
            let tag = p.replacingOccurrences(of: "_", with: "-").lowercased()
            if let match = supported.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == tag }) { return match }
        }
        if let region = Locale.current.region?.identifier,
           let match = supported.first(where: { $0.region?.identifier == region }) { return match }
        return supported.sorted { $0.identifier < $1.identifier }.first
    }

    static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Speech recognition permission, asked for once when it hasn't been yet. False when it's off.
    static func ensureAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            return status == .authorized
        default: return false
        }
    }

    /// Whether this device can transcribe the language on device, permission aside (it's asked for when the job
    /// runs). Off when permission was turned down.
    static func isAvailable(_ language: String) -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status != .denied, status != .restricted, let locale = locale(for: language),
              let r = SFSpeechRecognizer(locale: locale) else { return false }
        return r.supportsOnDeviceRecognition
    }

    /// Words for 16 kHz mono samples (one section), timed from their start. Words join without spaces in
    /// languages written that way; the caller handles that.
    static func words(samples: [Float], language: String) async throws -> [SectionWord] {
        let result = try await recognize(samples: samples, language: language)
        return result.map { $0.words } ?? []
    }

    /// Average confidence and word count for a short clip, for the language check. Nil when it couldn't run.
    static func confidence(samples: [Float], language: String) async -> (confidence: Double, words: Int)? {
        do {
            guard let r = try await recognize(samples: samples, language: language) else { return (0, 0) }
            return (r.confidence, r.words.count)
        } catch {
            return nil
        }
    }

    private static func recognize(samples: [Float], language: String) async throws -> (words: [SectionWord], confidence: Double)? {
        guard let locale = locale(for: language), let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition else { throw AppleSpeechError.unavailable(language) }
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SectionAudio.sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        recognizer.queue = OperationQueue()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.append(buffer)
        request.endAudio()
        let seconds = Double(samples.count) / Double(SectionAudio.sampleRate)
        let holder = TaskHolder()
        let outcome = await FluidEngine.race(seconds: max(60, seconds * 3)) {
            await withCheckedContinuation { (c: CheckedContinuation<Result<SFSpeechRecognitionResult?, Error>, Never>) in
                let once = Once()
                holder.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal { once.run { c.resume(returning: .success(result)) } }
                    else if let error {
                        // 1110: no speech detected. Silence isn't a failure.
                        let quiet = (error as NSError).code == 1110
                        once.run { c.resume(returning: quiet ? .success(nil) : .failure(error)) }
                    }
                }
            }
        }
        guard let outcome else { holder.task?.cancel(); throw AppleSpeechError.timedOut }
        guard let result = try outcome.get() else { return nil }
        let segments = result.bestTranscription.segments
        let words = segments.compactMap { s -> SectionWord? in
            let text = s.substring.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : SectionWord(text: text, start: s.timestamp, end: s.timestamp + s.duration)
        }
        let confidence = segments.isEmpty ? 0 : segments.reduce(0.0) { $0 + Double($1.confidence) } / Double(segments.count)
        return (words, confidence)
    }

    private final class TaskHolder: @unchecked Sendable { var task: SFSpeechRecognitionTask? }
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
    }
}

enum AppleSpeechError: LocalizedError {
    case unavailable(String)
    case timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable(let l): return LanguageRoute.unsupportedMessage(l)
        case .timedOut: return "Apple's speech recognizer stopped responding. Try again."
        }
    }
}

extension LanguageRoute {
    /// The message when nothing on this device can transcribe a language.
    static func unsupportedMessage(_ language: String) -> String {
        "Verbatim can't transcribe \(LanguageDetection.name(language)) on this device yet."
    }
}
