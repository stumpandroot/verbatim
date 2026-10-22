import Foundation

// Suggestions for the Dictionary screen: names from About me and fixes you keep making. Nothing is added to the
// Dictionary until you choose Add, and a dismissed suggestion stays dismissed.

/// A word the Dictionary screen offers to add.
struct VocabularySuggestion: Identifiable, Equatable {
    enum Source: String { case aboutMe, edits }
    let source: Source
    let preferred: String
    let heard: [String]
    /// How many times you made the fix (edits only).
    var count = 0

    var id: String { VocabularySuggestions.key(source, heard: heard.first ?? "", preferred: preferred) }

    var title: String {
        switch source {
        case .aboutMe: return "Add \(preferred) to your Dictionary?"
        case .edits: return "Always write \(preferred) for \u{201C}\(heard.first ?? "")\u{201D}?"
        }
    }

    var detail: String {
        switch source {
        case .aboutMe: return "From About me. Verbose listens for it and spells it this way."
        case .edits: return "You made this change \(count) times."
        }
    }

    var learnedFrom: String { source == .aboutMe ? "About me" : "Learned from your edits" }
}

enum VocabularySuggestions {
    /// Dismissed suggestion keys, one per line (a plain string so @AppStorage can read it).
    static let dismissedKey = "vocabulary.dismissedSuggestions"

    static func key(_ source: VocabularySuggestion.Source, heard: String, preferred: String) -> String {
        source == .aboutMe ? "name:\(preferred.lowercased())" : "edit:\(heard.lowercased())→\(preferred.lowercased())"
    }

    static func dismissed(_ raw: String) -> Set<String> { Set(raw.split(separator: "\n").map(String.init)) }

    /// `raw` with `id` added, keeping the newest 300.
    static func dismissing(_ id: String, in raw: String) -> String {
        var lines = raw.split(separator: "\n").map(String.init).filter { $0 != id }
        lines.append(id)
        return lines.suffix(300).joined(separator: "\n")
    }

    /// What the Dictionary screen shows, names from About me first. `dismissedRaw` and `pairs` are passed in so a
    /// SwiftUI view that reads them from @AppStorage refreshes when they change.
    static func current(aboutMe: String, extraNames: [String] = [], dictionary: [DictionaryEntry],
                        dismissedRaw: String, pairs: [EditPair]) -> [VocabularySuggestion] {
        let gone = dismissed(dismissedRaw)
        func bare(_ s: String) -> String { s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        // Dictionary words count as offered, so a part of one ("Steadfast" of "Steadfast Films") isn't offered either.
        var seen = Set(dictionary.map { bare($0.preferred) })
        var out: [VocabularySuggestion] = []
        for name in NameExtractor.names(in: aboutMe) + extraNames {
            let b = bare(name)
            // A name that overlaps one already offered ("Stump & Root" and "Stump & Root Co.") is offered once.
            guard !b.isEmpty, !BuiltInVocabulary.contains(name),
                  !seen.contains(where: { " \($0) ".contains(" \(b) ") || " \(b) ".contains(" \($0) ") }) else { continue }
            seen.insert(b)
            let s = VocabularySuggestion(source: .aboutMe, preferred: name, heard: NameExtractor.heardForms(name))
            if !gone.contains(s.id) { out.append(s) }
        }
        for p in EditLearner.ready(pairs) {
            let listed = dictionary.contains { e in
                e.preferred.caseInsensitiveCompare(p.fixed) == .orderedSame
                    && e.heardAs.contains { $0.caseInsensitiveCompare(p.heard) == .orderedSame }
            }
            let s = VocabularySuggestion(source: .edits, preferred: p.fixed, heard: [p.heard], count: p.count)
            if !listed, !gone.contains(s.id) { out.append(s) }
        }
        return out
    }
}

extension Store {
    /// Adds a suggestion to the Dictionary in one write, and forgets the counted fix behind it.
    func addSuggestion(_ s: VocabularySuggestion) {
        var d = dictionary
        if let i = d.firstIndex(where: { $0.preferred.caseInsensitiveCompare(s.preferred) == .orderedSame && $0.projectId == nil }) {
            for h in s.heard where !d[i].heardAs.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) { d[i].heardAs.append(h) }
        } else {
            d.append(DictionaryEntry(preferred: s.preferred, heardAs: s.heard, learnedFrom: s.learnedFrom))
        }
        dictionary = d
        if s.source == .edits, let h = s.heard.first { EditLearner.forget(heard: h, fixed: s.preferred) }
    }

    /// Adds names (from Contacts) in one write, skipping any already listed.
    func addNames(_ names: [String], learnedFrom: String) {
        var d = dictionary
        for n in names where !d.contains(where: { $0.preferred.caseInsensitiveCompare(n) == .orderedSame }) {
            d.append(DictionaryEntry(preferred: n, heardAs: NameExtractor.heardForms(n), learnedFrom: learnedFrom))
        }
        if d.count != dictionary.count { dictionary = d }
    }
}

// MARK: - Names from About me

/// Finds proper nouns in About me: multi-word names ("Star Quality", "Tim Medina"), company names with their
/// suffix ("Stump & Root Co.", "Firn LLC"), and single names that aren't ordinary words ("Strasburg").
enum NameExtractor {
    /// Joins capitalized words inside a name ("Stump & Root", "Bank of America").
    static let connectors: Set<String> = ["&", "of", "de", "da", "du", "la", "le", "van", "von", "der", "del"]
    /// Abbreviations whose period belongs to the name.
    static let abbreviations: Set<String> = ["co.", "inc.", "ltd.", "corp.", "jr.", "sr.", "bros.", "st."]
    /// Roles and other capitalized words that start a phrase but aren't part of a name.
    static let roleWords: Set<String> = [
        "founder", "co-founder", "cofounder", "ceo", "cto", "cfo", "coo", "owner", "director", "creative", "president",
        "partner", "manager", "head", "lead", "editor", "designer", "producer", "photographer", "filmmaker", "writer",
        "developer", "engineer", "chief", "officer", "executive", "vp", "senior", "junior", "principal", "consultant",
        "freelance", "freelancer", "artist", "father", "mother", "dad", "mom", "husband", "wife", "based", "member",
        "team", "art", "former", "current", "currently", "also", "runs", "run", "running", "own", "work", "working",
        "i", "i'm", "i’m", "my", "we", "we're", "our", "me", "hi", "hello", "call", "named", "name", "mr", "mrs", "ms", "dr",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "english", "american", "christian",
    ]

    private struct Token { let text: String; let range: NSRange; let capitalized: Bool; let startsSentence: Bool; let endsRun: Bool }

    private static let wordRE = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}&][\\p{L}\\p{N}&'’.\\-]*")

    /// Names in `text`, in order, without duplicates.
    static func names(in text: String) -> [String] {
        let ns = text as NSString
        let matches = wordRE.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var tokens: [Token] = []
        var previousEnd = 0
        var sentenceStart = true
        var breakBefore = false
        for m in matches {
            let gap = ns.substring(with: NSRange(location: previousEnd, length: m.range.location - previousEnd))
            if gap.contains(where: { ",;:()[]{}\n\"“”/—–!?".contains($0) }) { breakBefore = true }
            if gap.contains(where: { "!?\n".contains($0) }) { sentenceStart = true }
            var word = ns.substring(with: m.range)
            var range = m.range
            var endsRun = false
            var endsSentence = false
            if word.hasSuffix(".") {
                endsRun = true
                if !abbreviations.contains(word.lowercased()) {
                    // A sentence's last word: drop its period.
                    endsSentence = true
                    while word.hasSuffix(".") { word.removeLast(); range.length -= 1 }
                }
            }
            while word.hasSuffix("-") || word.hasSuffix("'") || word.hasSuffix("’") { word.removeLast(); range.length -= 1 }
            previousEnd = NSMaxRange(m.range)
            guard !word.isEmpty else { continue }
            if breakBefore, var last = tokens.popLast() {
                last = Token(text: last.text, range: last.range, capitalized: last.capitalized, startsSentence: last.startsSentence, endsRun: true)
                tokens.append(last)
            }
            breakBefore = false
            let cap = word.first.map { $0.isUppercase } ?? false
            tokens.append(Token(text: word, range: range, capitalized: cap, startsSentence: sentenceStart, endsRun: endsRun))
            sentenceStart = endsSentence
        }

        var runs: [[Token]] = []
        var run: [Token] = []
        func close() { if !run.isEmpty { runs.append(run) }; run = [] }
        for (i, t) in tokens.enumerated() {
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            if t.capitalized && t.text != "&" {
                run.append(t)
            } else if connectors.contains(t.text.lowercased()), !run.isEmpty, next?.capitalized == true, !t.endsRun {
                run.append(t)
            } else {
                close()
                continue
            }
            if t.endsRun { close() }
        }
        close()

        var out: [String] = []
        var seen = Set<String>()
        for var r in runs {
            // Drop roles, sentence-start common words, and connectors from the front; connectors from the back.
            while let f = r.first, connectors.contains(f.text.lowercased()) || roleWords.contains(f.text.lowercased())
                    || (f.startsSentence && CommonWords.set.contains(f.text.lowercased())) {
                r.removeFirst()
            }
            while let l = r.last, connectors.contains(l.text.lowercased()) || roleWords.contains(l.text.lowercased()) { r.removeLast() }
            guard let first = r.first, let last = r.last else { continue }
            let name: String
            if r.count == 1 {
                guard acceptsSingle(first) else { continue }
                name = first.text
            } else {
                name = ns.substring(with: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location))
            }
            guard name.count >= 3, name.count <= 40, name.rangeOfCharacter(from: .decimalDigits) == nil || r.count > 1 else { continue }
            if seen.insert(name.lowercased()).inserted { out.append(name) }
        }
        return out
    }

    /// A lone capitalized word is a name only mid-sentence, at least three letters, and not an ordinary word.
    private static func acceptsSingle(_ t: Token) -> Bool {
        let lower = t.text.lowercased()
        if t.text.dropFirst().contains(where: { $0.isUppercase }) && t.text.contains(where: { $0.isLowercase }) { return true }   // HubSpot
        return !t.startsSentence && t.text.count >= 3 && !CommonWords.set.contains(lower) && !roleWords.contains(lower)
            && !ContactNames.commonNames.contains(lower)
            && !(t.text.count <= 3 && t.text == t.text.uppercased())
    }

    /// Other ways a name is heard: "&" said as "and".
    static func heardForms(_ name: String) -> [String] {
        name.contains("&") ? [name.replacingOccurrences(of: "&", with: "and")] : []
    }

    /// Names from Apple's on-device model, when it's available: only ones that appear in `text` as written.
    static func modelNames(in text: String) async -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, Summarizer.available else { return [] }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let instructions = "List the proper names in the text: people, companies, brands, products, and places. One per line, exactly as written in the text. No other words, no numbering. If there are none, answer NONE."
            guard let answer = try? await OnDeviceText.respond(instructions: instructions, prompt: t), !OnDeviceTextRefusal.isRefusal(answer) else { return [] }
            return answer.split(whereSeparator: \.isNewline)
                .map { String($0).replacingOccurrences(of: "^[\\s\\-•*\\d.)\"]+", with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\""))) }
                .filter { !$0.isEmpty && $0 != "NONE" && $0.count <= 40 && t.contains($0) && $0.first?.isUppercase == true
                    && !CommonWords.isOrdinary($0) && !$0.split(separator: " ").allSatisfy { roleWords.contains($0.lowercased()) } }
        }
        #endif
        return []
    }
}

// MARK: - Learning from edits

/// One fix and how many editing sessions made it.
struct EditPair: Codable, Equatable {
    var heard: String
    var fixed: String
    var count: Int
    var last: Date
}

/// Counts the word fixes you make in transcripts and dictations. When you make the same fix in two separate
/// edits, the Dictionary screen asks "Always write … for …?". Kept on this device only, capped at 200 fixes.
enum EditLearner {
    static let storeKey = "vocabulary.editPairs"
    static let threshold = 2
    static let maxPairs = 200

    static func load(_ data: Data) -> [EditPair] { (try? JSONDecoder().decode([EditPair].self, from: data)) ?? [] }

    static func load(_ d: UserDefaults = .standard) -> [EditPair] { load(d.data(forKey: storeKey) ?? Data()) }

    static func save(_ pairs: [EditPair], _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(pairs) { d.set(data, forKey: storeKey) }
    }

    /// Fixes made at least `threshold` times, most frequent first.
    static func ready(_ pairs: [EditPair]) -> [EditPair] {
        pairs.filter { $0.count >= threshold }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
    }

    /// Records one editing session's fixes: each distinct fix counts once, and trivial ones are skipped.
    static func record(_ fixes: [(heard: String, fixed: String)], at sentenceStarts: Set<Int> = [], in d: UserDefaults = .standard, now: Date = Date()) {
        var pairs = load(d)
        var seen = Set<String>()
        var changed = false
        for (i, f) in fixes.enumerated() {
            let heard = clean(f.heard), fixed = clean(f.fixed)
            guard !isTrivial(heard: heard, fixed: fixed, atSentenceStart: sentenceStarts.contains(i)) else { continue }
            let k = heard.lowercased() + "→" + fixed
            guard seen.insert(k).inserted else { continue }
            if let j = pairs.firstIndex(where: { $0.heard.lowercased() == heard.lowercased() && $0.fixed == fixed }) {
                pairs[j].count += 1; pairs[j].last = now
            } else {
                pairs.append(EditPair(heard: heard, fixed: fixed, count: 1, last: now))
            }
            changed = true
        }
        guard changed else { return }
        if pairs.count > maxPairs {
            // Keep the most used, then the most recent.
            pairs = Array(pairs.sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }.prefix(maxPairs))
        }
        save(pairs, d)
    }

    /// Diffs one editing session's text and records the word fixes in it.
    static func record(before: String, after: String, in d: UserDefaults = .standard) {
        let found = diff(before, after)
        guard !found.isEmpty else { return }
        record(found.map { (heard: $0.heard, fixed: $0.fixed) },
               at: Set(found.enumerated().filter { $0.element.sentenceStart }.map { $0.offset }), in: d)
    }

    /// Forgets a fix (after it's added to the Dictionary, or dismissed).
    static func forget(heard: String, fixed: String, in d: UserDefaults = .standard) {
        let pairs = load(d)
        let kept = pairs.filter { !($0.heard.lowercased() == heard.lowercased() && $0.fixed == fixed) }
        if kept.count != pairs.count { save(kept, d) }
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "&+#")))
    }

    /// Not a vocabulary fix: punctuation only, a case change at a sentence start (or to lowercase), grammar between
    /// everyday words, a rewrite into a different word, numbers, or something long.
    static func isTrivial(heard: String, fixed: String, atSentenceStart: Bool) -> Bool {
        guard !heard.isEmpty, !fixed.isEmpty, heard != fixed, heard.count <= 40, fixed.count <= 40 else { return true }
        if heard.split(separator: " ").count > 3 || fixed.split(separator: " ").count > 3 { return true }
        if fixed.allSatisfy({ $0.isNumber || $0.isPunctuation || $0.isWhitespace }) { return true }
        if heard.lowercased() == fixed.lowercased() {
            // Case only: a sentence start, or a word lowercased, is grammar.
            return atSentenceStart || fixed == fixed.lowercased()
        }
        if CommonWords.isOrdinary(fixed) { return true }
        let a = heard.lowercased().filter { $0.isLetter || $0.isNumber }, b = fixed.lowercased().filter { $0.isLetter || $0.isNumber }
        // The same letters spaced or joined differently ("git hub" → "GitHub") is a fix.
        if a == b { return false }
        let hasCaps = fixed.dropFirst().contains { $0.isUppercase } || fixed.first?.isUppercase == true
        return similarity(a, b) < 0.4 && !hasCaps
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count), cur = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Word replacements between two versions of a text: up to three words replaced by up to three words,
    /// compared without surrounding punctuation. Unchanged starts and ends are skipped first, so long documents
    /// stay quick; a middle longer than 400 words is left alone.
    static func diff(_ before: String, _ after: String) -> [(heard: String, fixed: String, sentenceStart: Bool)] {
        let a = before.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let b = after.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let na = a.map(clean), nb = b.map(clean)
        var lo = 0
        while lo < na.count, lo < nb.count, na[lo] == nb[lo] { lo += 1 }
        var ha = na.count, hb = nb.count
        while ha > lo, hb > lo, na[ha - 1] == nb[hb - 1] { ha -= 1; hb -= 1 }
        let x = Array(na[lo..<ha]), y = Array(nb[lo..<hb])
        guard !(x.isEmpty && y.isEmpty), x.count <= 400, y.count <= 400 else { return [] }
        let n = x.count, m = y.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = x[i] == y[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var out: [(heard: String, fixed: String, sentenceStart: Bool)] = []
        var i = 0, j = 0
        var delStart = 0
        var del: [String] = [], ins: [String] = []
        func startsSentence(_ k: Int) -> Bool {
            let at = lo + k
            guard at > 0 else { return true }
            return a[at - 1].last.map { ".!?".contains($0) } ?? false
        }
        func flush() {
            if (1...3).contains(del.count), (1...3).contains(ins.count) {
                out.append((del.joined(separator: " "), ins.joined(separator: " "), startsSentence(delStart)))
            }
            del = []; ins = []
        }
        while i < n || j < m {
            if i < n, j < m, x[i] == y[j] { flush(); i += 1; j += 1 }
            else if j >= m || (i < n && dp[i + 1][j] >= dp[i][j + 1]) { if del.isEmpty { delStart = i }; del.append(x[i]); i += 1 }
            else { ins.append(y[j]); j += 1 }
        }
        flush()
        return out
    }
}

/// Collects typing in a transcript's document and, once you pause for 8 seconds (or leave), records the fixes
/// between the text before you started and after. Edits from Clean up, Tone, or accepting a suggestion don't
/// pass through here.
@MainActor
final class EditSessions {
    static let shared = EditSessions()
    private var base: [UUID: String] = [:]
    private var latest: [UUID: String] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    func typed(_ id: UUID, before: String, after: String) {
        if base[id] == nil { base[id] = before }
        latest[id] = after
        timers[id]?.cancel()
        timers[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(id)
        }
    }

    func finish(_ id: UUID) {
        timers[id]?.cancel(); timers[id] = nil
        guard let b = base.removeValue(forKey: id), let a = latest.removeValue(forKey: id), a != b else { return }
        EditLearner.record(before: b, after: a)
    }
}
