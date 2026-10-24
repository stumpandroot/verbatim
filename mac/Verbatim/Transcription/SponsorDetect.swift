import Foundation

/// Finds sponsor reads in a podcast or long video by rule, with no model: the deterministic first pass of sponsor
/// detection (Apple Intelligence may confirm and name what it finds afterward, SponsorRefine). Pure Foundation, so
/// mac/tools/test-sponsors.sh runs it on Linux against a real episode.
///
/// How it reads a transcript:
/// 1. **Anchors.** A line is an anchor when it carries a strong call to action: a cue phrase ("brought to you by",
///    "today's sponsor", "use code", "promo code"), a web address with a vanity path ("goodranchers.com slash
///    alley"), or an address with an offer ("$50 off", "20 percent off", "code alley"). A bare address, the word
///    "sponsor", "partner with", or "link in the description" counts only alongside another sign, so a guest naming
///    their own website isn't an ad.
/// 2. **Clusters.** Anchors close together in one speaker's turn, for one brand, are one read.
/// 3. **Bounds.** The read grows backward over the same speaker's lines that name the brand (each within a minute
///    of the next), then to an intro cue ("Next sponsor is…") or, without one, to the start of the speaker's turn
///    when that's under 45 seconds away: hosts usually start a read as their turn begins. It ends at the last
///    anchor or brand mention, where the host goes back to the topic.
/// Granularity is the line (segment): a read that starts or ends mid-turn starts or ends at a line.
enum SponsorDetect {
    /// One transcript line, as the rules see it.
    struct Line: Equatable {
        var start: Double
        var end: Double
        var text: String
        /// Diarization label; nil when speakers weren't identified.
        var speaker: String?
        init(start: Double, end: Double, text: String, speaker: String? = nil) {
            self.start = start; self.end = end; self.text = text; self.speaker = speaker
        }
    }

    /// A sponsor read: the first and last line it covers, their times, and the sponsor's name when one was found.
    struct Found: Equatable {
        var first: Int
        var last: Int
        var start: Double
        var end: Double
        var name: String?
    }

    // MARK: Tuning

    /// How far apart two brand mentions (or anchors) can be and still belong to one read.
    static let chainGap: Double = 60
    /// Without speaker labels a turn can't bound the read, so the chain is held tighter.
    static let chainGapNoSpeakers: Double = 45
    /// How far back a read may reach for its intro cue or the start of the speaker's turn.
    static let leadIn: Double = 45
    /// At most this many lines of lead-in before the first brand mention.
    static let leadInLines = 6
    /// The longest read: longer stretches are almost always the episode's own topic.
    static let maxRead: Double = 300

    // MARK: Detection

    static func detect(_ lines: [Line]) -> [Found] {
        guard !lines.isEmpty else { return [] }
        let feats = lines.map { Features($0.text) }
        let anchors = lines.indices.filter { feats[$0].isAnchor }
        guard !anchors.isEmpty else { return [] }
        let labeled = lines.contains { $0.speaker != nil }
        let gap = labeled ? chainGap : chainGapNoSpeakers

        // Where each line's speaker turn starts.
        var runStart = [Int](repeating: 0, count: lines.count)
        for i in lines.indices where i > 0 { runStart[i] = lines[i].speaker == lines[i - 1].speaker ? runStart[i - 1] : i }
        func sameRun(_ a: Int, _ b: Int) -> Bool { runStart[a] == runStart[b] }

        // 2. Clusters of anchors: one speaker's turn, one brand, close together.
        var clusters: [[Int]] = []
        for a in anchors {
            if var c = clusters.last, let prev = c.last, sameRun(prev, a), lines[a].start - lines[prev].end <= gap,
               compatible(Features.keys(c.map { feats[$0] }), feats[a].ownKeys) {
                c.append(a); clusters[clusters.count - 1] = c
            } else {
                clusters.append([a])
            }
        }

        var out: [Found] = []
        var outKeys: [Set<String>] = []
        for c in clusters {
            let keys = Features.keys(c.map { feats[$0] })
            var lo = c.first!, hi = c.last!
            // A read never reaches back into the one before it, unless it's the same sponsor's (an intro cue a
            // minute before the offer: "Next sponsor is Crowd Health… joincrowdhealth.com code alley").
            let prev = out.last, prevKeys = outKeys.last ?? []
            let samePrev = prev.map { sameRun($0.last, lo) && compatible(prevKeys, keys) } ?? false
            let floor = prev.map { samePrev ? $0.first : $0.last + 1 } ?? 0
            let anchorStart = lines[lo].start
            // 3a. Back over brand mentions in the same turn, each within `gap` of the read so far.
            var j = lo - 1
            while j >= floor, sameRun(j, lo), lines[lo].start - lines[j].end <= gap, anchorStart - lines[j].start <= maxRead {
                if feats[j].mentions(keys) || feats[j].isAnchor { lo = j }
                j -= 1
            }
            var keysNow = keys
            if samePrev, let p = prev, lo <= p.last + 1 {
                // It reached the earlier read: one read from the earlier start.
                lo = p.first
                keysNow.formUnion(prevKeys)
                out.removeLast(); outKeys.removeLast()
            }
            // 3b. Forward over brand mentions right after the last anchor ("Crowdhealth is not insurance.").
            var k = hi + 1
            while k < lines.count, sameRun(k, hi), lines[k].start - lines[hi].end <= 12 {
                if feats[k].mentions(keysNow) || feats[k].isAnchor { hi = k }
                k += 1
            }
            // 3c. An intro cue just before ("Next sponsor is…"), or the start of the turn.
            let base = out.last.map { $0.last + 1 } ?? 0
            if !feats[lo].hasIntro {
                var m = lo - 1
                var cue: Int? = nil
                while m >= base, sameRun(m, lo), lines[lo].start - lines[m].start <= leadIn, lo - m <= leadInLines {
                    if feats[m].hasIntro { cue = m; break }
                    m -= 1
                }
                if let cue { lo = cue }
                else {
                    let rs = runStart[lo]
                    // Without speaker labels the only turn start that means anything is the recording's own.
                    let usable = labeled || rs == 0
                    if usable, rs >= base, lo - rs <= leadInLines, lines[lo].start - lines[rs].start <= leadIn {
                        // From the turn's start, past a stray "Well." or "Yeah." the other speaker's turn left behind.
                        var s = rs
                        while s < lo, lines[s].text.split(whereSeparator: { $0.isWhitespace }).count <= 2 { s += 1 }
                        lo = s
                    }
                }
            }
            let name = displayName(keys: keysNow, lines: Array(lines[lo...hi]), feats: Array(feats[lo...hi]))
            out.append(Found(first: lo, last: hi, start: lines[lo].start, end: lines[hi].end, name: name))
            outKeys.append(keysNow)
        }
        return out
    }

    /// Two brand-key sets can share a read when either is empty (no brand named) or they overlap.
    private static func compatible(_ a: Set<String>, _ b: Set<String>) -> Bool {
        a.isEmpty || b.isEmpty || !a.isDisjoint(with: b)
    }

    // MARK: Naming

    /// Prefixes and suffixes vanity domains add to a brand: joinadf.com, getcrowdhealth.com, drinkag1.com.
    static let domainPrefixes = ["join", "get", "try", "go", "shop", "drink", "use", "my", "the", "buy", "visit", "with", "hello", "meet"]
    static let domainSuffixes = ["app", "hq", "now", "official", "online"]

    /// The words a domain's brand is matched by: the label itself and, when it starts or ends with a vanity word,
    /// the label without it. "joinadf" → ["joinadf", "adf"].
    static func keys(fromDomain label: String) -> [String] {
        let l = label.lowercased().filter { $0.isLetter || $0.isNumber }
        guard l.count >= 3 else { return [] }
        var out = [l]
        for p in domainPrefixes where l.hasPrefix(p) && l.count - p.count >= 3 { out.append(String(l.dropFirst(p.count))) }
        for s in domainSuffixes where l.hasSuffix(s) && l.count - s.count >= 3 { out.append(String(l.dropLast(s.count))) }
        return out
    }

    /// A sponsor's name from a domain alone: the brand part, title-cased, or in capitals when it's an acronym.
    /// "goodranchers" → "Goodranchers", "joinadf" → "ADF", "drinkag1" → "AG1".
    static func name(fromDomain label: String) -> String? {
        guard let k = keys(fromDomain: label).last else { return nil }
        if k.count <= 4 { return k.uppercased() }
        return k.prefix(1).uppercased() + k.dropFirst()
    }

    /// The sponsor's name as the read says it: the spoken form of the brand key ("Good Ranchers" for goodranchers,
    /// "Alliance Defending Freedom" for adf), preferring one written in camel case ("CrowdHealth"), then one in
    /// capitals, then the most frequent. Falls back to the domain, then to the words after a cue.
    static func displayName(keys: Set<String>, lines: [Line], feats: [Features]) -> String? {
        struct Candidate { var count = 0; var order = 0; var keyLength = Int.max; var spelledOut = false }
        var candidates: [String: Candidate] = [:]
        for l in lines {
            let words = Self.words(l.text)
            for i in words.indices {
                for n in 1...4 where i + n <= words.count {
                    let span = Array(words[i..<i + n])
                    let squashed = span.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.joined()
                    let acronym = n >= 3 && span[0].first?.isUppercase == true ? String(span.compactMap { $0.lowercased().first }) : ""
                    let key = keys.contains(squashed) ? squashed : keys.contains(acronym) ? acronym : nil
                    guard let key else { continue }
                    let form = span.joined(separator: " ")
                    var c = candidates[form] ?? Candidate(order: candidates.count)
                    c.count += 1
                    c.keyLength = min(c.keyLength, key.count)
                    c.spelledOut = c.spelledOut || key == acronym
                    candidates[form] = c
                }
            }
        }
        func rank(_ s: String) -> Int {
            let ws = s.split(separator: " ")
            var r = 0
            if ws.contains(where: { w in w.dropFirst().contains { $0.isUppercase } && w.contains { $0.isLowercase } }) { r = 2 }
            else if ws.allSatisfy({ $0.first?.isUppercase == true }) { r = 1 }
            return s.contains("-") ? r - 2 : r
        }
        // The most specific brand ("crowdhealth" over "joincrowdhealth"), spelled out over an acronym, then camel
        // case over capitals over lowercase (hyphens last), then the most frequent, then the first.
        if let best = candidates.max(by: { a, b in
            let ka = a.value.spelledOut ? 0 : a.value.keyLength, kb = b.value.spelledOut ? 0 : b.value.keyLength
            if ka != kb { return ka > kb }
            if rank(a.key) != rank(b.key) { return rank(a.key) < rank(b.key) }
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            return a.value.order > b.value.order
        })?.key {
            return titleCased(best)
        }
        if let domain = feats.lazy.compactMap({ $0.domains.first }).first, let n = name(fromDomain: domain) { return n }
        return feats.lazy.compactMap(\.cueName).first
    }

    /// "good ranchers" → "Good Ranchers"; words with capitals inside ("CrowdHealth") stay as they are.
    static func titleCased(_ s: String) -> String {
        s.split(separator: " ").map { w -> String in
            if w.dropFirst().contains(where: { $0.isUppercase }) { return String(w) }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    /// Words with their edge punctuation trimmed; tokens that are web addresses are left out.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            if raw.contains(".") && raw.split(separator: ".").count > 1 && raw.last?.isLetter == true { return nil }
            let w = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            return w.isEmpty ? nil : w
        }
    }

    // MARK: Apple Intelligence's answer

    /// What the on-device model said about one read (SponsorRefine asks; this part is pure, for the tests).
    enum Verdict: Equatable {
        case sponsor(name: String?)
        case notSponsor
        /// Declined, failed, or answered in a shape this can't read: the rules' span stays as it is.
        case unknown
    }

    /// Reads "SPONSOR: yes / NAME: Good Ranchers". Anything else is `.unknown`.
    static func verdict(from answer: String) -> Verdict {
        var yes: Bool? = nil
        var name: String? = nil
        for raw in answer.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*-• "))
            let lower = line.lowercased()
            if lower.hasPrefix("sponsor:") {
                let v = lower.dropFirst(8).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                if v.hasPrefix("yes") { yes = true } else if v.hasPrefix("no") { yes = false }
            } else if lower.hasPrefix("name:") {
                let v = line.dropFirst(5).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'.“”")))
                if !v.isEmpty, !["none", "unknown", "n/a", "no"].contains(v.lowercased()), v.count <= 40 { name = v }
            }
        }
        switch yes {
        case true?: return .sponsor(name: name)
        case false?: return .notSponsor
        case nil: return .unknown
        }
    }

    /// The name to show once the model has answered: the model's when the rules had none or it spells the same
    /// brand ("PreBorn" for "Preborn", "CrowdHealth" for "Crowd Health"), otherwise the rules' (the read says it).
    static func pickName(rule: String?, model: String?) -> String? {
        guard let model, !model.isEmpty else { return rule }
        guard let rule, !rule.isEmpty else { return model }
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let r = squash(rule), m = squash(model)
        return !r.isEmpty && (r == m || m.contains(r)) && model.count <= rule.count + 12 ? model : rule
    }

    // MARK: Line features

    /// What one line says, worked out once.
    struct Features {
        /// Lowercased, curly apostrophes made straight.
        let lower: String
        /// Letters and digits only, for matching brand names spoken with or without spaces.
        let squashed: String
        /// Lowercased words, for acronyms.
        let tokens: [String]
        /// Whether each word starts with a capital, in the original text.
        let capitalized: [Bool]
        /// Labels of the web addresses in the line: "goodranchers" for goodranchers.com.
        let domains: [String]
        /// A name after a sponsor cue: "Squarespace" in "brought to you by Squarespace".
        let cueName: String?
        let score: Int
        let hasIntro: Bool

        var isAnchor: Bool { score >= 2 }

        /// Brand keys this line names by itself: its domains, and a cue's name.
        var ownKeys: Set<String> {
            var out = Set(domains.flatMap { SponsorDetect.keys(fromDomain: $0) })
            if let n = cueName { let k = n.lowercased().filter { $0.isLetter || $0.isNumber }; if k.count >= 3 { out.insert(k) } }
            return out
        }

        static func keys(_ fs: [Features]) -> Set<String> { fs.reduce(into: Set<String>()) { $0.formUnion($1.ownKeys) } }

        /// True when the line names the brand: a long key anywhere in the squashed text, a short one as a word, or
        /// as the initials of capitalized words ("Alliance defending freedom" for adf).
        func mentions(_ keys: Set<String>) -> Bool {
            for k in keys {
                if k.count >= 5 { if squashed.contains(k) { return true } ; continue }
                if tokens.contains(k) { return true }
                let n = k.count
                guard n >= 3, tokens.count >= n else { continue }
                for i in 0...(tokens.count - n) where capitalized[i] {
                    if String(tokens[i..<i + n].compactMap(\.first)) == k { return true }
                }
            }
            return false
        }

        init(_ text: String) {
            let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            self.lower = lower
            squashed = lower.filter { $0.isLetter || $0.isNumber }
            let ws = SponsorDetect.words(text)
            tokens = ws.map { $0.lowercased() }
            capitalized = ws.map { $0.first?.isUppercase == true }

            var score = 0
            var domains: [String] = []
            var vanity = false, codeAfterURL = false
            for m in Rx.url.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
                guard let r = Range(m.range(at: 1), in: lower) else { continue }
                domains.append(String(lower[r]))
                let after = lower[Range(m.range, in: lower)!.upperBound...]
                let tail = String(after.prefix(40))
                if Rx.matches(Rx.vanity, tail) { vanity = true }
                if Rx.matches(Rx.codeAfter, tail) { codeAfterURL = true }
            }
            self.domains = domains
            let strongCue = Rx.matches(Rx.strongCue, lower)
            let codeCue = Rx.matches(Rx.codeCue, lower) || codeAfterURL
            let offer = Rx.matches(Rx.offer, lower)
            if strongCue { score += 2 }
            if !domains.isEmpty { score += 1 }
            if vanity { score += 2 }
            if codeCue { score += 2 }
            if offer { score += 2 }
            if Rx.matches(Rx.weakCue, lower) { score += 1 }
            self.score = score
            hasIntro = Rx.matches(Rx.intro, lower)

            // "brought to you by Squarespace", "today's sponsor is Athletic Greens": up to three capitalized words.
            var cue: String? = nil
            if let m = Rx.cueName.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) {
                let ws = text[r].split(separator: " ").prefix(3).prefix { $0.first?.isUppercase == true || $0.first?.isNumber == true }
                let n = ws.map { $0.trimmingCharacters(in: .punctuationCharacters) }.joined(separator: " ")
                cue = n.isEmpty ? nil : n
            }
            cueName = cue
        }
    }

    /// The patterns, compiled once.
    enum Rx {
        static func make(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
            // Constant patterns, compiled by mac/tools/test-sponsors.sh on every push.
            try! NSRegularExpression(pattern: p, options: o)
        }
        static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
            r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        /// A web address as speech-to-text writes it: "goodranchers.com", "athletic greens dot com".
        static let url = make(#"\b([a-z0-9][a-z0-9-]{1,40})(?:\.|\s+dot\s+)(?:com|org|net|co|io|tv|us|app|ai|fm|ly|gg|shop|store)\b(?!-)"#)
        /// "… slash alley", "…/podcast" right after the address.
        static let vanity = make(#"^\s*(?:/|(?:forward\s+)?slash)\s*[a-z0-9]"#)
        /// "… code alley" right after the address.
        static let codeAfter = make(#"^\s*(?:and\s+)?(?:use\s+|using\s+|enter\s+)?(?:promo\s+|my\s+|the\s+)?code\s+[a-z0-9]"#)
        static let strongCue = make(#"brought to you by|today's sponsor|our sponsor|next sponsor|this (?:episode|video|show|podcast) is sponsored|sponsored by|word from (?:our|today's) sponsor|thanks to (?:our|today's) sponsor|use my link|link in (?:the )?(?:description|show notes) (?:to|for)"#)
        static let codeCue = make(#"\b(?:promo|discount|coupon)\s+code\b|\b(?:use|using|enter)\s+(?:my\s+|the\s+|promo\s+)?code\b"#)
        static let offer = make(#"\b\d+\s*(?:%|percent)\s+off\b|\$\s?\d[\d,]*\s+off\b|\b(?:\d+|five|ten|fifteen|twenty|twenty-five|thirty|forty|fifty|hundred)\s+dollars?\s+off\b|first (?:month|box|order) (?:is )?free|free (?:trial|shipping)"#)
        static let weakCue = make(#"\bsponsors?\b|\bpartner(?:ed|ing)? with\b|link in (?:the )?description|\bsign up\b|\bfree\b"#)
        /// A read's first line: "Next sponsor is Crowd Health", "a quick word from…".
        static let intro = make(#"brought to you by|\bsponsor|word from|quick break|support for (?:this|the|today's) (?:show|episode|podcast|video)|partnered with"#)
        /// The name after a cue, in the original text (case matters).
        static let cueName = make(#"(?i:brought to you by|sponsored by|sponsor (?:today )?is|sponsor,|word from)\s+([A-Za-z0-9][^.,!?;:]{0,40})"#)
    }
}
