import Foundation

// Which engine transcribes which language, and how a language guess becomes a decision. Pure Swift (Foundation
// only), so mac/tools/longfile-tests runs it on Linux. LanguageCheck.swift does the listening and recognizing.

enum LanguageRules {
    /// The 25 European languages Parakeet v3 transcribes (NVIDIA's model card), as ISO 639-1 codes.
    static let parakeetV3: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// Parakeet models trained on v3's languages: v3 itself, and Redux and Ultra (re-trainings of v3 with its
    /// vocabulary). v2 is English only.
    static func isMultilingual(_ model: String) -> Bool { model != "v2" }

    /// Languages written without spaces between words, so their words join with nothing between them.
    static let noSpaces: Set<String> = ["ja", "zh", "yue", "th", "lo", "km", "my", "bo"]

    static func joiner(for language: String?) -> String {
        guard let language else { return " " }
        return noSpaces.contains(base(language)) ? "" : " "
    }

    /// "zh-Hans" → "zh", "pt_BR" → "pt", "nb" → "nb". Lowercased.
    static func base(_ code: String) -> String {
        let lower = code.lowercased()
        let cut = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) ?? lower.endIndex
        return String(lower[..<cut])
    }
}

/// What the first ~30 seconds sound like, from a language recognizer's hypotheses about a first-pass transcript.
enum LanguageGuess: Equatable {
    /// One language, with the recognizer's probability for it.
    case known(String, Double)
    /// An English-only pass whose words read as English, but which the model wasn't sure it heard (low token
    /// confidence): English unless a second opinion hears another language.
    case likelyEnglish
    /// An English-only pass whose words don't read as English: probably another language, but which one is unclear.
    case notEnglish
    /// Too few words, or no clear winner.
    case unknown

    /// Fewer words than this and the guess is `unknown`.
    static let minimumWords = 6
    /// A guess this sure needs no second opinion.
    static let sure = 0.8

    /// Below this average token confidence, an English-only pass's English is only `likelyEnglish`.
    static let englishConfidence = 0.8

    /// `hypotheses` are (language code, probability) pairs; `englishOnlyPass` is true when the first pass used
    /// Parakeet v2, which writes any speech as English words, so its words reading as English prove little:
    /// `confidence` (the pass's average token confidence, 0…1) decides how sure that English is.
    static func evaluate(_ hypotheses: [(String, Double)], words: Int, englishOnlyPass: Bool, confidence: Double? = nil) -> LanguageGuess {
        guard words >= minimumWords else { return .unknown }
        var merged: [String: Double] = [:]
        for (code, p) in hypotheses { merged[LanguageRules.base(code), default: 0] += p }
        guard let top = merged.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) else {
            return englishOnlyPass ? .notEnglish : .unknown
        }
        if englishOnlyPass {
            guard top.key == "en" && top.value >= 0.6 else { return .notEnglish }
            return (confidence ?? 1) >= englishConfidence ? .known("en", top.value) : .likelyEnglish
        }
        return top.value >= 0.5 ? .known(top.key, top.value) : .unknown
    }

    var language: String? {
        if case .known(let l, _) = self { return l }
        return nil
    }

    /// Whether a second opinion (Apple's recognizer in candidate languages) could change the answer. English that
    /// reads as English never gets one: a stray second opinion must not move an English recording elsewhere.
    var wantsConfirmation: Bool {
        switch self {
        case .known(let l, let p): return l != "en" && p < Self.sure
        case .likelyEnglish, .notEnglish, .unknown: return true
        }
    }

    /// Languages worth a second opinion, at most `limit`: the guess itself (when it isn't English), then the
    /// languages you use on this device (preferred languages and keyboards), never English.
    func candidates(device: [String], limit: Int = 3) -> [String] {
        var out: [String] = []
        func add(_ code: String) {
            let b = LanguageRules.base(code)
            guard !b.isEmpty, b != "en", b != "und", !out.contains(b), out.count < limit else { return }
            out.append(b)
        }
        if let l = language { add(l) }
        for d in device { add(d) }
        return out
    }

    /// The candidate Apple's recognizer heard best: average confidence at least 0.5 over at least 4 words.
    /// Ties go to the earlier candidate.
    static func pick(_ results: [(language: String, confidence: Double, words: Int)]) -> String? {
        var best: (String, Double)? = nil
        for r in results where r.words >= 4 && r.confidence >= 0.5 {
            if best == nil || r.confidence > best!.1 { best = (r.language, r.confidence) }
        }
        return best?.0
    }
}

/// What to do with a job once its language is known.
enum LanguageRoute: Equatable {
    /// Run as set; the language is shown on the transcript (nil when it's unclear).
    case keep(String?)
    /// Run this job with Parakeet v3 instead of the English-only model.
    case useV3(String)
    /// Parakeet v3 is needed but isn't downloaded: run as set and offer the download (nil: language unclear).
    case offerV3(String?)
    /// Outside v3's languages: Apple's on-device recognizer for that language.
    case apple(String)
    /// Outside v3's languages and nothing on this device can transcribe it.
    case unsupported(String)

    /// `explicit` is true when you picked the language (Transcribe again in…): v3 then downloads as part of the
    /// job instead of being offered.
    static func decide(_ guess: LanguageGuess, model: String, v3Downloaded: Bool, appleSupports: (String) -> Bool,
                       explicit: Bool = false) -> LanguageRoute {
        switch guess {
        case .unknown:
            return .keep(nil)
        case .likelyEnglish:
            return .keep("en")
        case .notEnglish:
            if LanguageRules.isMultilingual(model) { return .keep(nil) }
            return v3Downloaded ? .keep(nil) : .offerV3(nil)
        case .known(let raw, _):
            let l = LanguageRules.base(raw)
            if l == "en" { return .keep("en") }
            if LanguageRules.parakeetV3.contains(l) {
                if LanguageRules.isMultilingual(model) { return .keep(l) }
                return v3Downloaded || explicit ? .useV3(l) : .offerV3(l)
            }
            return appleSupports(l) ? .apple(l) : .unsupported(l)
        }
    }
}
