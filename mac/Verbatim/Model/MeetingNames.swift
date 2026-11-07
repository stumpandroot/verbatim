import Foundation

/// Names for a call recorded from a calendar event (Mac, App/MeetingSession.swift): who the other side is, the
/// meeting's own words for the engine, and misheard names fixed after the call. Pure Foundation, so
/// mac/tools/test-meeting-names.sh checks it on Linux. Nothing here reads a calendar or leaves the device: the
/// caller passes the event's title and attendees (MeetingContext) and your names.
///
/// Why each part exists, from a real two-person Meet call: the other person was labeled "Chrome" for good (the call's
/// track is named for its app, and suggestions only ran on placeholders); "Thanks, <name>" came out as another name
/// on both sides (no meeting words reached the engine, and a name that sounds nothing like the right one can't be
/// rescored back); and an acronym in the event title came out misspelled.
enum MeetingNames {
    // MARK: Your names

    /// Your names as Verbose knows them: the name on the You page (`profile.name`) and the Mac account's full name,
    /// each whole and its first word ("Dana Reyes", "Dana"), each once.
    static func selfNames(stored: String, account: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard t.count >= 2, t.lowercased() != "you", t.contains(where: \.isLetter),
                  !out.contains(where: { $0.lowercased() == t.lowercased() }) else { return }
            out.append(t)
        }
        for full in [stored, account] {
            add(full)
            if let first = full.split(whereSeparator: { $0.isWhitespace }).first, full.contains(" ") { add(String(first)) }
        }
        return out
    }

    /// `selfNames(stored:account:)` for this device: the You page's name, and on the Mac the account's full name.
    static func selfNames() -> [String] {
        let stored = UserDefaults.standard.string(forKey: "profile.name") ?? ""
        #if os(macOS)
        return selfNames(stored: stored, account: NSFullUserName())
        #else
        return selfNames(stored: stored, account: "")
        #endif
    }

    /// A name that is you: one of your names, a lone first name that is yours, or the same first and last name.
    /// "Dana Baker" isn't "Dana Reyes", so someone who shares your first name still counts as someone else.
    static func isSelf(_ name: String, selfNames: [String]) -> Bool {
        let n = words(name)
        guard let nf = n.first else { return false }
        for s in selfNames {
            let w = words(s)
            guard let wf = w.first else { continue }
            if n == w { return true }
            if n.count == 1, nf == wf { return true }
            if n.count >= 2, w.count >= 2, nf == wf, n.last == w.last { return true }
        }
        return false
    }

    /// The attendees who aren't you, each once. A calendar that doesn't mark you as the current user (an account
    /// added as a plain CalDAV calendar, say) still lists you, and the one other person would look like two.
    static func others(_ attendees: [String], selfNames: [String]) -> [String] {
        var out: [String] = []
        for a in attendees {
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, !isSelf(t, selfNames: selfNames), !out.contains(where: { $0.lowercased() == t.lowercased() }) else { continue }
            out.append(t)
        }
        return out
    }

    // MARK: The other side

    struct RemoteName: Equatable {
        var name: String
        /// Why, for the suggestion: "the only other person invited", "named in the event title".
        var reason: String
    }

    static let onlyInviteeReason = "the only other person invited"
    static let invitedReason = "invited to the calendar event"
    static let titleReason = "named in the event title"

    /// Who the call's track is, from the event alone (Char's approach, research §2.1): the one other person invited;
    /// with nobody listed, the other half of a one-on-one title ("Dana x Priya") when the other half is you. Nil
    /// otherwise: a group call's names go to the speaker's menu instead.
    static func remoteName(_ m: MeetingContext, selfNames: [String]) -> RemoteName? {
        let people = others(m.attendees, selfNames: selfNames)
        if people.count == 1 { return RemoteName(name: people[0], reason: onlyInviteeReason) }
        guard people.isEmpty, let pair = titlePair(m.meetingTitle) else { return nil }
        let mine = pair.map { isSelf($0, selfNames: selfNames) }
        guard mine.filter({ $0 }).count == 1, let other = zip(pair, mine).first(where: { !$0.1 })?.0 else { return nil }
        return RemoteName(name: other, reason: titleReason)
    }

    /// The two people in a one-on-one title: "Dana x Priya", "Dana / Priya", "Dana <> Priya", "Dana and Priya",
    /// "Dana & Priya", with a description before or after it ("Weekly: Dana / Priya", "Dana x Priya - 1:1"). Each half
    /// must look like a person's name (one to three capitalized words); nil otherwise.
    static func titlePair(_ title: String) -> [String]? {
        var t = title.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
        var parts = [t]
        for s in [" - ", ": ", " | ", "|"] { parts = parts.flatMap { $0.components(separatedBy: s) } }
        let seps = [" <> ", "<>", " x ", " X ", " / ", "/", " & ", " + ", " and "]
        for part in parts {
            for sep in seps {
                let halves = part.components(separatedBy: sep)
                guard halves.count == 2 else { continue }
                let names = halves.compactMap { personHalf($0) }
                if names.count == 2, names[0].lowercased() != names[1].lowercased() { return names }
            }
        }
        return nil
    }

    /// One half of a title as a name: filler words around it dropped ("1:1", "sync", "call"), then one to three
    /// capitalized words of letters, none of them a common or generic word.
    private static func personHalf(_ s: String) -> String? {
        var w = s.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"“”'‘’")) }
            .filter { !$0.isEmpty }
        while let f = w.first, titleFiller.contains(f.lowercased()) { w.removeFirst() }
        while let l = w.last, titleFiller.contains(l.lowercased()) { w.removeLast() }
        guard (1...3).contains(w.count) else { return nil }
        for x in w {
            guard let f = x.first, f.isUppercase, x.allSatisfy({ $0.isLetter || "'’-.".contains($0) }), x.contains(where: \.isLowercase) else { return nil }
            let l = x.lowercased()
            if SpeakerNames.stopWords.contains(l) || genericTitleWords.contains(l) { return nil }
        }
        return w.joined(separator: " ")
    }

    /// Words a one-on-one title puts around the names.
    private static let titleFiller: Set<String> = [
        "1:1", "1-1", "1on1", "1x1", "one-on-one", "sync", "call", "meeting", "chat", "catch-up", "catchup", "intro",
        "check-in", "checkin", "weekly", "biweekly", "monthly", "coffee", "lunch", "zoom", "meet", "teams",
    ]

    /// The suggestions a call starts with, for the call's track (`speakerId`): every other invitee, so the speaker's
    /// menu offers them (Transcript.calendarNames); the one other invitee shows as a suggestion with Use and Dismiss.
    /// With nobody invited, the other half of a one-on-one title; with neither, the one other person the call app's
    /// window showed (`windowNames`, CallWindowNames), as "shown in the FaceTime window". Nothing is renamed until you
    /// choose Use.
    static func suggestions(_ m: MeetingContext, selfNames: [String], speakerId: String) -> [SpeakerSuggestion] {
        let people = others(m.attendees, selfNames: selfNames)
        if !people.isEmpty {
            let why = people.count == 1 ? onlyInviteeReason : invitedReason
            return people.map { SpeakerSuggestion(speakerId: speakerId, name: $0, reasons: [why], sources: [SpeakerSuggestion.calendarSource]) }
        }
        if let r = remoteName(m, selfNames: selfNames) {
            return [SpeakerSuggestion(speakerId: speakerId, name: r.name, reasons: [r.reason], sources: [SpeakerSuggestion.calendarSource])]
        }
        let seen = others(m.windowNames, selfNames: selfNames)
        guard seen.count == 1 else { return [] }
        return [SpeakerSuggestion(speakerId: speakerId, name: seen[0], reasons: [windowReason(app: m.app)], sources: [SpeakerSuggestion.windowSource])]
    }

    /// Why a name from the call window is suggested: "shown in the FaceTime window", or "shown in the call window" for
    /// all system audio.
    static func windowReason(app: String?) -> String {
        let a = (app ?? "").trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !["others", "them", "system audio", "app audio"].contains(a.lowercased()) else { return "shown in the call window" }
        return "shown in the \(a) window"
    }

    /// The other people on a call: the invitees who aren't you, or with none invited, the name the call window showed.
    static func people(_ m: MeetingContext, selfNames: [String]) -> [String] {
        let invited = others(m.attendees, selfNames: selfNames)
        return invited.isEmpty ? others(m.windowNames, selfNames: selfNames) : invited
    }

    // MARK: Who was this with?

    /// Names for "Who was this with?" as you type (Mac, Views/WhoWasThisRow.swift): the names whose whole start, or
    /// one word's start, matches what's typed (ignoring case and accents), whole-name matches first, each once, at most
    /// `limit`. Your own names never show. Nothing for fewer than one letter.
    static func typeahead(_ typed: String, in names: [String], selfNames: [String] = [], limit: Int = 4) -> [String] {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let q = fold(typed.trimmingCharacters(in: .whitespaces))
        guard q.contains(where: \.isLetter) else { return [] }
        var first: [String] = [], second: [String] = [], seen = Set<String>()
        for n in names {
            let f = fold(n)
            guard !isSelf(n, selfNames: selfNames), seen.insert(f).inserted else { continue }
            if f.hasPrefix(q) { first.append(n) }
            else if f.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { second.append(n) }
        }
        return Array((first + second).prefix(limit))
    }

    // MARK: The meeting's words

    /// At most this many words go to the engine for one meeting. FluidAudio keeps its spotter's acoustic rescue and
    /// its most permissive similarity gate (0.50) only at 10 terms or fewer (research §3.1, §5.2); the Dictionary's
    /// 100-term list for dictation runs without the rescue.
    static let maxTerms = 10
    /// Title words at most, so the names keep their places.
    static let maxTitleTerms = 3

    /// The meeting's own short word list, most telling first: the other people's first names (`people`), yours,
    /// distinctive words from the title (an acronym, a name; the call window's title without a calendar one), their
    /// full names, then your newest Dictionary words to fill the
    /// list (`dictionary`, ranked as BoostVocabulary.rank ranks them). Each once, at most `maxTerms`.
    static func vocabulary(_ m: MeetingContext, selfNames: [String], dictionary: [String] = []) -> [String] {
        let people = Self.people(m, selfNames: selfNames)
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard out.count < maxTerms, t.count >= 2, !out.contains(where: { $0.lowercased() == t.lowercased() }) else { return }
            out.append(t)
        }
        for p in people { if let f = p.split(separator: " ").first { add(String(f)) } }
        for s in selfNames where !s.contains(" ") { add(s) }
        for w in titleTerms(m.meetingTitle) { add(w) }
        for p in people where p.contains(" ") { add(p) }
        for s in selfNames where s.contains(" ") { add(s) }
        for d in dictionary { add(d) }
        return out
    }

    /// Words in a title an engine is likely to get wrong: acronyms ("ACME", "Q3OKR" stays out) and capitalized words
    /// that aren't common or generic ("Planning", "Call", and "Page" stay out), in title order, at most
    /// `maxTitleTerms`.
    static func titleTerms(_ title: String) -> [String] {
        var out: [String] = []
        let raw = title.components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'’-")).inverted)
        for w in raw {
            let t = w.trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
            guard out.count < maxTitleTerms, t.count >= 2, let f = t.first, f.isLetter,
                  !out.contains(where: { $0.lowercased() == t.lowercased() }) else { continue }
            let l = t.lowercased()
            let acronym = t.count <= 6 && t.allSatisfy { $0.isUppercase || $0.isNumber } && t.contains(where: \.isLetter)
            if acronym {
                if !commonAcronyms.contains(l) { out.append(t) }
                continue
            }
            guard t.count >= 3, f.isUppercase, t.allSatisfy({ $0.isLetter || "'’-".contains($0) }),
                  !SpeakerNames.stopWords.contains(l), !genericTitleWords.contains(l), !titleFiller.contains(l) else { continue }
            out.append(t)
        }
        return out
    }

    /// The meeting's words as a short transcript-styled line for Whisper's prompt ("Acme Planning Call. Dana,
    /// Priya."): Whisper follows the prompt's style and spelling, not instructions, and reads only its last 224 tokens
    /// (research §3.2), so it stays short. Empty when there's nothing to say.
    static func whisperPrompt(_ m: MeetingContext, terms: [String]) -> String {
        let title = m.meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = title.lowercased()
        let rest = terms.filter { !lowerTitle.contains($0.lowercased()) }
        var parts: [String] = []
        if !title.isEmpty { parts.append(title.hasSuffix(".") ? title : title + ".") }
        if !rest.isEmpty { parts.append(rest.joined(separator: ", ") + ".") }
        return String(parts.joined(separator: " ").prefix(200))
    }

    // MARK: Putting rescored words back on their times

    /// Runs of lines to rescore together: consecutive lines with word timings, about `maxSeconds` long at most (a
    /// longer line is a run of its own). The rescorer spots its words in that stretch of audio only.
    static func windows(_ segments: [Segment], maxSeconds: Double = 30) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int? = nil
        for (i, s) in segments.enumerated() {
            guard boostable(s) else {
                if let a = start { out.append(a..<i); start = nil }
                continue
            }
            if let a = start, s.end - segments[a].start > maxSeconds { out.append(a..<i); start = i }
            else if start == nil { start = i }
        }
        if let a = start { out.append(a..<segments.count) }
        return out
    }

    /// A line the rescorer can change and give back with its times: word timings whose words make up its text.
    static func boostable(_ s: Segment) -> Bool {
        guard let w = s.words, !w.isEmpty else { return false }
        return w.map(\.text).joined(separator: " ") == s.text
    }

    /// `segments[range]` with the rescored `text` (their words joined by spaces, changed) put back on the words'
    /// times: unchanged words keep theirs, and a changed run ("O Tess" for "OTAS") shares the time of the words it
    /// replaces. Each line keeps its id and the words that came from its own. Nil when nothing changed, when the lines
    /// can't take it back (no word timings), or when the text changed too much to be a vocabulary swap.
    static func rescored(_ segments: [Segment], range: Range<Int>, text: String) -> [Segment]? {
        let lines = Array(segments[range])
        guard !lines.isEmpty, lines.allSatisfy(boostable) else { return nil }
        let old = lines.flatMap { $0.words ?? [] }
        guard text != old.map(\.text).joined(separator: " "), let aligned = realign(old, to: text) else { return nil }
        var bounds: [Int] = []
        var n = 0
        for l in lines { n += l.words?.count ?? 0; bounds.append(n) }
        var out = lines
        for k in out.indices {
            let lo = k == 0 ? 0 : bounds[k - 1], hi = bounds[k]
            let mine = aligned.filter { $0.from >= lo && $0.from < hi }.map(\.word)
            guard let first = mine.first, let last = mine.last else { return nil }
            out[k].words = mine
            out[k].text = mine.map(\.text).joined(separator: " ")
            out[k].start = first.start; out[k].end = last.end
        }
        return out
    }

    /// The new words, each with the index of the old word it came from: a longest common subsequence over the words
    /// (letters and digits, lowercased), so matched words keep their times and each changed run takes the span of the
    /// words it replaced, shared evenly. Nil when more than half the words changed.
    static func realign(_ old: [WordSpan], to text: String) -> [(word: WordSpan, from: Int)]? {
        let new = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !old.isEmpty, !new.isEmpty, old.count <= 2_000, new.count <= 2_000 else { return nil }
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = old.map { key($0.text) }, b = new.map(key)
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] && !a[i].isEmpty ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        guard dp[0][0] * 2 >= n else { return nil }
        var out: [(word: WordSpan, from: Int)] = []
        var i = 0, j = 0
        var runA: [Int] = [], runB: [Int] = []
        func flush() {
            defer { runA = []; runB = [] }
            guard !runB.isEmpty else { return }
            if let f = runA.first, let l = runA.last {
                let start = old[f].start, end = max(old[l].end, start)
                let step = (end - start) / Double(runB.count)
                for (k, jb) in runB.enumerated() {
                    out.append((WordSpan(text: new[jb], start: start + step * Double(k), end: start + step * Double(k + 1)), f))
                }
            } else {
                // Words added with nothing replaced: on the word before, at its end (or the next word's start).
                let at = i > 0 ? old[i - 1].end : old[min(i, n - 1)].start
                let from = i > 0 ? i - 1 : 0
                for jb in runB { out.append((WordSpan(text: new[jb], start: at, end: at), from)) }
            }
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j], !a[i].isEmpty {
                flush()
                out.append((WordSpan(text: new[j], start: old[i].start, end: old[i].end, confidence: old[i].confidence), i))
                i += 1; j += 1
            } else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] {
                runB.append(j); j += 1
            } else {
                runA.append(i); i += 1
            }
        }
        flush()
        return out
    }

    // MARK: Fixing names after the call

    /// One misheard name and the name that goes there: `range` (UTF-16) in `segments[segment].text`.
    struct NameFix: Equatable {
        var segment: Int
        var range: NSRange
        var from: String
        var to: String
    }

    /// Words heard where someone is addressed ("Thanks, Sam." at a line's end, "Hey Sam", "Sam, can you…") that
    /// should be an invitee's name or yours, for a calendar call. Each fix can only put in a name from the invite or
    /// one of yours, and only when the line makes the word a name you call someone by. Never touched: a word that is
    /// already an invitee's, yours, or a speaker's name, a common word (or one heard in lowercase anywhere in the
    /// call), a word in the event's `title` ("Thanks, Acme." thanks the company), and a word in `known` (your
    /// Dictionary's words, which hold the contacts you added there).
    ///
    /// Who can be addressed depends on who is talking: on your line, the invitees; on the call's line, you, and any
    /// other invitee who isn't the one talking. One possible name is the fix; with more, only one that sounds like the
    /// word heard (SpeakerNames.soundsAlike). "Sam" for "Tim" sounds nothing alike, which is why this runs at all: the
    /// engine's rescoring can't make that swap (research §3.1).
    static func nameFixes(_ segments: [Segment], speakers: [Speaker], attendees: [String], selfNames: [String],
                          title: String = "", known: Set<String> = []) -> [NameFix] {
        let people = others(attendees, selfNames: selfNames)
        guard !people.isEmpty else { return [] }
        let firstOf: (String) -> String = { $0.split(separator: " ").first.map(String.init) ?? $0 }
        let mine = selfNames.filter { !$0.contains(" ") }
        let myFirst = mine.first ?? selfNames.first.map(firstOf)
        // Every word of a name that's already right: invitees', yours, speakers' you named.
        var protected = groupWords
        for n in people + selfNames + speakers.filter({ !$0.isUnnamed }).map(\.name) {
            for w in words(n) { protected.insert(w) }
        }
        for k in known.union([title]) { for w in words(k) { protected.insert(w) } }
        let common = SpeakerNames.lowercaseWords(segments)
        let youIDs = Set(speakers.filter { $0.name.lowercased() == "you" || isSelf($0.name, selfNames: selfNames) }.map(\.id))

        var out: [NameFix] = []
        for (i, s) in segments.enumerated() {
            for hit in vocatives(in: s.text) {
                let heard = hit.word
                let lw = heard.lowercased()
                guard !protected.contains(lw), SpeakerNames.isNameWord(heard, common: common), !lw.hasSuffix("ly") else { continue }
                var candidates: [String]
                if let sp = s.speaker, youIDs.contains(sp) {
                    candidates = people.map(firstOf)
                } else if let sp = s.speaker {
                    // The call's line: you, or another invitee. In a one-on-one the one invitee is the one talking.
                    let talker = speakers.first { $0.id == sp }.map { $0.isUnnamed ? "" : $0.name } ?? ""
                    let rest = people.count == 1 ? [] : people.filter { talker.isEmpty || !SpeakerNames.sameName($0, talker) }
                    candidates = (myFirst.map { [$0] } ?? []) + rest.map(firstOf)
                } else {
                    // No speakers: anyone could be addressed, so only a name that sounds like the word.
                    candidates = people.map(firstOf) + (myFirst.map { [$0] } ?? [])
                    candidates = candidates.filter { SpeakerNames.soundsAlike($0, heard) }
                }
                var seen = Set<String>()
                candidates = candidates.filter { seen.insert($0.lowercased()).inserted }
                if candidates.count > 1 { candidates = candidates.filter { SpeakerNames.soundsAlike($0, heard) } }
                guard candidates.count == 1, candidates[0].lowercased() != lw else { continue }
                out.append(NameFix(segment: i, range: hit.range, from: heard, to: candidates[0]))
            }
        }
        return out
    }

    /// Applies `nameFixes` through CorrectionEdits, so each one is a correction with its exact place: Review lists it
    /// beside what was heard ("Name from the invite"), and Undo puts the heard word back there and nowhere else.
    /// Returns how many words changed.
    @discardableResult
    static func correctNames(_ segments: inout [Segment], corrections: inout [Correction], speakers: [Speaker],
                             attendees: [String], selfNames: [String], title: String = "", known: Set<String> = []) -> Int {
        let fixes = nameFixes(segments, speakers: speakers, attendees: attendees, selfNames: selfNames, title: title, known: known)
        // From the end of each line backward, so the places still ahead stay where they were found.
        for f in fixes.sorted(by: { $0.segment != $1.segment ? $0.segment < $1.segment : $0.range.location > $1.range.location }) {
            guard CorrectionEdits.apply([f.range], in: &segments, at: f.segment, to: f.to, label: f.from, byDictionary: false,
                                        corrections: &corrections) != nil else { continue }
            corrections[corrections.count - 1].byName = true
        }
        return fixes.count
    }

    /// Words in a line that name someone being spoken to, with where they are: after thanks, a greeting, or a
    /// goodbye at a sentence's end ("Thanks, Sam." "Bye Sam"); after a comma at a sentence's end that speaks to
    /// someone ("Good to see you, Sam."); and before a comma at a sentence's start in a sentence that says "you" or
    /// asks something ("Sam, can you share it?").
    static func vocatives(in text: String) -> [(word: String, range: NSRange)] {
        let ns = text as NSString
        var out: [(word: String, range: NSRange)] = []
        func add(_ r: NSRange) {
            guard r.location != NSNotFound, !out.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) else { return }
            out.append((ns.substring(with: r), r))
        }
        for sentence in sentenceRanges(text) {
            let s = ns.substring(with: sentence)
            let sn = s as NSString
            let lower = s.lowercased()
            for m in cuedEnd.matches(in: s, range: NSRange(location: 0, length: sn.length)) {
                add(NSRange(location: sentence.location + m.range(at: 1).location, length: m.range(at: 1).length))
            }
            let speaksTo = lower.contains("?") || addressWords.contains { lower.range(of: "\\b" + $0 + "\\b", options: .regularExpression) != nil }
            if speaksTo {
                for m in commaEnd.matches(in: s, range: NSRange(location: 0, length: sn.length)) {
                    add(NSRange(location: sentence.location + m.range(at: 1).location, length: m.range(at: 1).length))
                }
            }
            if lower.contains("?") || lower.range(of: #"\byou\b|\byour\b"#, options: .regularExpression) != nil {
                for m in leading.matches(in: s, range: NSRange(location: 0, length: sn.length)) {
                    add(NSRange(location: sentence.location + m.range(at: 1).location, length: m.range(at: 1).length))
                }
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    private static let name = #"(\p{Lu}\p{Ll}+(?:['’-]\p{L}+)?)"#
    private static let end = #"(?=\s*[.!?…]*\s*$)"#
    /// "Thanks, Sam." "thank you so much Sam!" "Bye Sam." "Morning, Sam."
    private static let cuedEnd = try! NSRegularExpression(pattern:
        #"(?i:\b(?:thanks(?: so much| very much| again)?|thank you(?: so much| very much| again)?|hey|hi|hello|bye(?: now)?|goodbye|good ?bye|morning|good (?:morning|afternoon|evening|night)|see you|see ya|talk soon|cheers|welcome(?: back)?|night)),?\s+"#
        + name + end)
    /// "…good to see you, Sam."
    private static let commaEnd = try! NSRegularExpression(pattern: #",\s+"# + name + end)
    /// "Sam, can you…" (after an opener: "Okay, Sam, …", "So Sam, …").
    private static let leading = try! NSRegularExpression(pattern:
        #"^\s*(?:(?i:hey|hi|hello|okay|ok|so|well|and|but|yeah|thanks|alright|now),?\s+)?"# + name + #",\s+\S"#)
    private static let addressWords = ["you", "your", "thanks", "thank", "hey", "hi", "hello", "bye", "goodbye", "morning", "welcome", "appreciate", "see you"]

    /// Sentences in a line, as UTF-16 ranges, split after ".", "?", "!", or "…" followed by a space.
    static func sentenceRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var start = 0
        let len = ns.length
        var i = 0
        while i < len {
            let c = ns.character(at: i)
            if c == 46 || c == 63 || c == 33 || c == 0x2026 {
                var j = i + 1
                while j < len, let u = UnicodeScalar(ns.character(at: j)), "\"”’)".unicodeScalars.contains(u) { j += 1 }
                if j == len || (UnicodeScalar(ns.character(at: j)).map { CharacterSet.whitespaces.contains($0) } ?? false) {
                    out.append(NSRange(location: start, length: j - start))
                    start = j
                }
                i = j
                continue
            }
            i += 1
        }
        if start < len { out.append(NSRange(location: start, length: len - start)) }
        return out
    }

    // MARK: Words

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet.letters.inverted) }.filter { !$0.isEmpty }
    }

    /// Words a meeting title uses that say what the meeting is, not who or what it's about.
    static let genericTitleWords: Set<String> = [
        "meeting", "meetings", "call", "calls", "sync", "review", "reviews", "page", "pages", "project", "projects", "planning",
        "plan", "plans", "kickoff", "kick", "intro", "introduction", "update", "updates", "check", "chat", "team", "teams",
        "standup", "stand", "demo", "session", "discussion", "follow", "followup", "catch", "touch", "base", "website", "site",
        "design", "strategy", "lunch", "coffee", "interview", "onboarding", "training", "workshop", "brainstorm", "retro",
        "retrospective", "hands", "office", "hours", "hour", "quick", "time", "notes", "agenda", "prep", "debrief", "recap",
        "status", "roadmap", "budget", "contract", "proposal", "launch", "marketing", "sales", "product", "engineering",
        "board", "client", "customer", "partner", "partners", "group", "committee", "staff", "sprint", "conversation",
        "connect", "weekly", "biweekly", "monthly", "quarterly", "annual", "daily", "invitation", "invite", "event", "new",
        "video", "phone", "online", "virtual", "social", "media", "content", "planning", "working", "work", "kick-off",
    ]

    /// Words that address a group or anyone ("Thanks, Team."), never a misheard name.
    private static let groupWords: Set<String> = [
        "team", "all", "everyone", "everybody", "guys", "folks", "friends", "both", "y'all", "yall", "gang", "crew", "sir",
        "ma'am", "bud", "buddy", "man", "dude", "boss", "mate", "love", "dear", "honey", "babe", "pal", "friend", "kids",
    ]

    /// Acronyms too ordinary to boost.
    private static let commonAcronyms: Set<String> = ["ok", "am", "pm", "tbd", "fyi", "asap", "re", "fw", "fwd", "eod", "eta", "us", "tv", "i"]
}
