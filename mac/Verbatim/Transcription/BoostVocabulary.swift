import Foundation
import FluidAudio

/// Chooses and shapes the Dictionary words handed to FluidAudio's vocabulary booster (CTC keyword spotting plus
/// rescoring) for a dictation. Pure functions, no state, so both the Mac and the iPhone can use them.
enum BoostVocabulary {
    /// FluidAudio's size buckets tighten matching above 100 terms (minSimilarity 0.55 → 0.60), so stay at 100.
    static let maxTerms = 100

    /// Short names ("Root", "Lapp", "Yu") collide with ordinary words; demand a closer match for them.
    /// FluidAudio's own guards (0.80 for short words with a length mismatch, 0.85 across stopwords) still apply.
    static let shortTermLength = 4
    static let shortTermMinSimilarity: Float = 0.75

    /// FluidAudio's recommended short-vocabulary opt-in (ContextBiasingConstants, #702): taper the boost for terms
    /// under 5 tokens and require some string similarity before the acoustic-only rescue may swap words in.
    /// The profile can be overridden with the `fluidBoostProfile` default (`strict`, `norescue`, `legacy`) so the
    /// bench can compare them; the app ships `strict`.
    static var rescorerConfig: VocabularyRescorer.Config {
        switch UserDefaults.standard.string(forKey: "fluidBoostProfile") ?? "strict" {
        case "legacy":
            return .default
        case "norescue":
            // No acoustic-only rescue at all (FluidAudio #724): far fewer over-fires on short vocabularies.
            return VocabularyRescorer.Config(shortTermCbwTaperPivot: 5, shortTermCbwTaperExponent: 2.0, spotterRescueEnabled: false)
        default:
            return VocabularyRescorer.Config(
                shortTermCbwTaperPivot: 5,
                shortTermCbwTaperExponent: 2.0,
                spotterRescueMinSimilarity: 0.45,
                spotterRescueMultiWordMinSimilarity: 0.75
            )
        }
    }

    /// Ranks Dictionary entries for one dictation: the active project's words first, then the newest, then the
    /// rest, capped at `maxTerms`. Disabled entries and other projects' words are left out.
    static func rank(_ entries: [DictionaryEntry], project: UUID?) -> [(text: String, aliases: [String])] {
        let usable = entries.enumerated().filter {
            $0.element.enabled && !$0.element.preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ($0.element.projectId == nil || $0.element.projectId == project)
        }
        let ordered = usable.sorted { a, b in
            let pa = project != nil && a.element.projectId == project
            let pb = project != nil && b.element.projectId == project
            if pa != pb { return pa }
            if a.element.createdAt != b.element.createdAt { return a.element.createdAt > b.element.createdAt }
            return a.offset > b.offset
        }
        return ordered.prefix(maxTerms).map { (text: $0.element.preferred, aliases: $0.element.heardAs) }
    }

    /// Ranks terms that arrive without dates or projects (the older `transcribeBoosted(terms:)` call). The
    /// Dictionary appends new words at the end, so the end of the list is the newest: take from the end.
    static func rankByPosition(_ terms: [(text: String, aliases: [String])]) -> [(text: String, aliases: [String])] {
        Array(terms.reversed())
    }

    /// Builds FluidAudio terms from ranked entries: merges duplicates, drops "heard as" forms made only of very
    /// common English words (they raise similarity for ordinary phrases and cause false swaps; the Dictionary's
    /// exact replacements still use them), and raises the bar for short terms. `key` identifies the set, so the
    /// boosting session is rebuilt only when it changes.
    static func terms(_ ranked: [(text: String, aliases: [String])]) -> (terms: [CustomVocabularyTerm], key: [String]) {
        var order: [String] = []
        var canonical: [String: String] = [:]
        var aliases: [String: [String]] = [:]
        for t in ranked {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let k = text.lowercased()
            if canonical[k] == nil {
                guard order.count < maxTerms else { continue }
                order.append(k); canonical[k] = text; aliases[k] = []
            }
            for a in t.aliases {
                let alias = a.trimmingCharacters(in: .whitespacesAndNewlines)
                let ak = alias.lowercased()
                guard !alias.isEmpty, ak != k, !CommonWords.isOrdinary(alias),
                      !(aliases[k] ?? []).contains(where: { $0.lowercased() == ak }) else { continue }
                aliases[k, default: []].append(alias)
            }
        }
        var out: [CustomVocabularyTerm] = []
        var key: [String] = []
        for k in order {
            guard let text = canonical[k] else { continue }
            let al = aliases[k] ?? []
            out.append(CustomVocabularyTerm(text: text, aliases: al.isEmpty ? nil : al,
                                            minSimilarity: text.count <= shortTermLength ? shortTermMinSimilarity : nil))
            key.append(text + "|" + al.joined(separator: ","))
        }
        return (out, key.sorted())
    }
}

/// About 300 of the most frequent English words. A "heard as" form made only of these ("and", "of the", "it's")
/// is too ordinary to use as a boosting alias. A fixed list rather than NSSpellChecker so it works on iOS too.
enum CommonWords {
    static func isOrdinary(_ phrase: String) -> Bool {
        let words = phrase.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy { set.contains($0) }
    }

    static let set: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "also", "always", "am", "an", "and", "another",
        "any", "are", "around", "as", "ask", "at", "away", "back", "bad", "be", "because", "been", "before", "being",
        "below", "best", "better", "between", "big", "both", "bring", "but", "buy", "by", "call", "came", "can",
        "can't", "car", "change", "come", "could", "couldn't", "day", "did", "didn't", "different", "do", "does",
        "doesn't", "doing", "don't", "done", "down", "each", "end", "even", "ever", "every", "eye", "far", "feel",
        "few", "find", "first", "five", "for", "four", "from", "get", "give", "go", "going", "good", "got", "great",
        "had", "hand", "has", "have", "he", "he's", "head", "hear", "help", "her", "here", "high", "him", "his",
        "home", "house", "how", "i", "i'd", "i'll", "i'm", "i've", "if", "in", "into", "is", "isn't", "it", "it's",
        "its", "just", "keep", "kind", "know", "last", "late", "later", "leave", "left", "less", "let", "let's",
        "life", "like", "line", "little", "live", "long", "look", "lot", "made", "make", "man", "many", "may",
        "maybe", "me", "mean", "might", "more", "most", "move", "much", "must", "my", "name", "need", "never", "new",
        "next", "nice", "night", "no", "not", "now", "number", "of", "off", "often", "oh", "ok", "okay", "old", "on",
        "once", "one", "only", "open", "or", "other", "our", "out", "over", "own", "part", "people", "place", "play",
        "point", "put", "read", "real", "really", "right", "room", "run", "said", "same", "saw", "say", "see",
        "seem", "seen", "send", "set", "she", "should", "show", "side", "since", "small", "so", "some", "something",
        "soon", "start", "still", "stop", "such", "sure", "take", "talk", "tell", "than", "thank", "thanks", "that",
        "that's", "the", "their", "them", "then", "there", "there's", "these", "they", "they're", "thing", "things",
        "think", "this", "those", "though", "thought", "three", "through", "time", "to", "today", "together", "told",
        "too", "took", "try", "turn", "two", "under", "until", "up", "us", "use", "used", "very", "want", "was",
        "wasn't", "watch", "way", "we", "we're", "week", "well", "went", "were", "what", "what's", "when", "where",
        "which", "while", "who", "why", "will", "with", "without", "won't", "word", "work", "world", "would",
        "wouldn't", "write", "yeah", "year", "yes", "yet", "you", "you're", "your", "you'll", "yours",
    ]
}
