import Foundation

/// Rule-based layout for dictation: numbered lists, bulleted lists, and paragraphs. Runs on the Mac with no
/// model, so lists and paragraphs work when Apple Intelligence is missing, slow, times out, or ignores the
/// instruction. `FlowCleanup` runs it on the cleaned text at Clean and Polished, after the model when the model
/// ran; never at Literal or in code apps. Foundation only.
///
/// What it does:
/// - Numbered lists from spoken enumeration: "first… second… third…", "firstly… secondly… finally…",
///   "one, … two, …", "number one… number two…", "step one… step two…". A lead-in sentence before the
///   first item ends with a colon when it announces the items ("We need three things:").
/// - Bulleted lists from spoken cues ("bullet", "next bullet", "bullet point", "dash"), and from an announced
///   comma series: "a few things", "the following", "here's what we need", "three things", or a colon, followed
///   by three or more short items. An ordinary sentence with a comma series stays a sentence.
/// - Paragraphs: a break before a spoken topic shift ("Also,", "Anyway,", "One more thing", "Moving on"), and
///   inside a paragraph longer than about 4 sentences or 90 words, at the most natural sentence boundary.
///   A message under 40 words keeps its paragraphs as spoken.
/// - Lists the model already wrote ("* item", "1) item") are rewritten in the destination's list style.
///
/// Guarantees: words keep their order, and the only words removed are the list cues themselves ("first",
/// "number two", "bullet", and the "and" before the last item). Running it twice changes nothing.
enum DictationFormatter {

    /// How list items are written.
    enum ListStyle: Equatable {
        /// "- item" and "1. item". Notes, documents, chat apps, and AI prompts read Markdown or convert it.
        case markdown
        /// "• item" and "1. item". Mail and Messages show text as typed, where "- " reads as a stray dash.
        case plain
    }

    struct Options: Equatable {
        var style: ListStyle = .markdown
        /// Puts a spoken greeting ("Hi Sarah,") and sign-off ("Best, Tim") on lines of their own.
        var email = false
    }

    /// The options for an app kind, or nil when the text goes in untouched.
    ///
    /// - Email (Mail, Outlook, Gmail): plain bullets. Mail composers paste text as typed, so "- " would stay a
    ///   dash; "•" reads as a bullet everywhere. Greetings and sign-offs get their own lines.
    /// - Personal messages (Messages, WhatsApp, Signal): plain bullets, for the same reason.
    /// - Work chat and everything else (Slack, Linear, Notion, notes, documents, browsers, ChatGPT and Claude):
    ///   Markdown. These apps render it, convert it on paste, or (AI prompts) read it as structure.
    /// - Code apps: nil. Words go in as spoken.
    static func options(for category: AppCategory) -> Options? {
        switch category {
        case .code: return nil
        case .email: return Options(style: .plain, email: true)
        case .personal: return Options(style: .plain)
        case .work, .other: return Options(style: .markdown)
        }
    }

    /// Formats `text` for the app kind; returns it unchanged for code apps.
    static func format(_ text: String, for category: AppCategory) -> String {
        guard let o = options(for: category) else { return text }
        return format(text, o)
    }

    /// Messages shorter than this keep their paragraphs as spoken (explicit "new paragraph" still works).
    static let shortMessageWords = 40

    static func format(_ text: String, _ o: Options) -> String {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return text }
        // Words with a letter, so list numbers ("1.") added by a first run don't count on the second.
        let auto = t.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter }) }.count >= shortMessageWords
        var blocks = t.replacingOccurrences(of: "\\n[ \\t]*(?:\\n[ \\t]*)+", with: "\u{0}", options: .regularExpression)
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if o.email, let first = blocks.first, let (greeting, rest) = splitGreeting(first) {
            blocks.replaceSubrange(0...0, with: [greeting, rest])
        }
        var out = blocks.map { formatBlock($0, o, auto: auto) }.joined(separator: "\n\n")
        if o.email { out = splitSignOff(out) }
        return tidy(out)
    }

    // MARK: Blocks and lines

    private static func formatBlock(_ block: String, _ o: Options, auto: Bool) -> String {
        let lines = spokenBulletLines(block.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        var out = ""
        for line in lines {
            let piece = listLine(line).map { render($0, o) } ?? formatProse(line, o, auto: auto)
            if !out.isEmpty {
                // Lines stay lines, and a list stays under the line before it. A line after a list gets a blank
                // line, so Markdown doesn't fold it into the last item.
                let afterList = listLine(out.components(separatedBy: "\n").last ?? "") != nil
                let startsList = listLine(piece.components(separatedBy: "\n").first ?? "") != nil
                out += afterList && !startsList ? "\n\n" : "\n"
            }
            out += piece
        }
        return out
    }

    private struct Item { var number: Int?; var text: String }

    private static let listLineRegex = try! NSRegularExpression(pattern: "^(?:([-*•–+])|(\\d{1,2})[.)])\\s+(\\S.*)$")

    /// A line that is already a list item ("- milk", "• milk", "2) milk", "2. milk").
    private static func listLine(_ line: String) -> Item? {
        let ns = line as NSString
        guard let m = listLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let text = ns.substring(with: m.range(at: 3))
        if m.range(at: 2).location != NSNotFound { return Item(number: Int(ns.substring(with: m.range(at: 2))), text: text) }
        return Item(number: nil, text: text)
    }

    private static func render(_ item: Item, _ o: Options) -> String {
        if let n = item.number { return "\(n). \(item.text)" }
        return (o.style == .markdown ? "- " : "• ") + item.text
    }

    private static func renderList(_ items: [String], ordered: Bool, _ o: Options) -> String {
        items.enumerated().map { render(Item(number: ordered ? $0.offset + 1 : nil, text: $0.element), o) }.joined(separator: "\n")
    }

    // MARK: Prose

    /// One line of prose: a list when it holds one, then paragraphs.
    private static func formatProse(_ line: String, _ o: Options, auto: Bool) -> String {
        if let l = findList(line) {
            var s = ""
            let lead = l.lead.trimmingCharacters(in: .whitespaces)
            if !lead.isEmpty && findList(lead) != nil {
                // A list inside the lead-in that the whole line hid (rare): format it on its own, as a second run would.
                s += formatProse(lead, o, auto: auto) + "\n\n"
            } else if !lead.isEmpty {
                let (text, colon) = leadIn(lead)
                s += paragraphs(text, auto: auto) + (colon ? "\n" : "\n\n")
            }
            s += renderList(l.items, ordered: l.ordered, o)
            let trailer = l.trailer.trimmingCharacters(in: .whitespaces)
            if !trailer.isEmpty { s += "\n\n" + formatProse(trailer, o, auto: auto) }
            return s
        }
        return paragraphs(line, auto: auto)
    }

    /// The list in a line of prose. The one that starts first wins; later ones are in its trailer.
    private static func findList(_ line: String) -> FoundList? {
        [enumeration(line), spokenBullets(line), announcedList(line)].compactMap { $0 }.min { $0.lead.count < $1.lead.count }
    }

    private struct FoundList {
        var lead: String
        var items: [String]
        var ordered: Bool
        var trailer: String
    }

    /// Words that, as the last sentence of a lead-in, make it announce a list, so its period becomes a colon.
    private static let announcesItems = try! NSRegularExpression(pattern: "(?i)\\b(?:things|items|points|steps|reasons|questions|options|ideas|issues|changes|tasks|priorities|goals|parts|ways|updates|following|agenda|list|plan|here[’']?s|here are|here is|as follows)\\b")

    /// The lead-in's text and whether the list follows it directly (it ends with a colon).
    private static func leadIn(_ lead: String) -> (String, Bool) {
        var t = lead
        if t.hasSuffix(":") { return (t, true) }
        while let last = t.last, ",;—–- ".contains(last) { t.removeLast() }
        guard let last = t.last else { return (lead, false) }
        if last.isLetter || last.isNumber || ")”’\"".contains(last) { return (t + ":", true) }
        if last == ".", let final = sentences(t).last, matches(announcesItems, final) {
            return (String(t.dropLast()) + ":", true)
        }
        return (t, false)
    }

    // MARK: Spoken enumeration

    private enum Family: Equatable { case ordinal, cardinal, terminal, prefixed(String) }

    private struct Marker {
        var range: NSRange
        var value: Int        // 0 for "finally" and "lastly"
        var family: Family
        var boundary: Bool    // starts a clause: line start, after punctuation, or after "and" or "then"
    }

    private static let numberWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
    private static let ordinalWords: [String: Int] = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]

    private static let markerRegex = try! NSRegularExpression(pattern:
        "(?i)(?<![\\p{L}\\p{N}'’-])(?:" +
        "(first|second|third) (?:of all|off)|" +
        "(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?:ly)?|" +
        "(finally|lastly|last)|" +
        "(number|step|point|item|option|reason|phase|part) (one|two|three|four|five|six|seven|eight|nine|ten|\\d{1,2})|" +
        "(one|two|three|four|five|six|seven|eight|nine|ten|\\d{1,2})" +
        ")(?![\\p{L}\\p{N}'’])")

    /// Words before "first" or "second" that make it an adjective or a noun ("the first time", "a second").
    private static let ordinalBlockedBefore: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their",
        "his", "her", "its", "every", "each", "per", "one", "at", "for", "in", "very", "came", "come", "comes", "finished", "ranked", "placed",
        "love", "split", "whose", "which", "what", "same", "no", "any", "some", "only", "just", "wait", "hold", "his", "is", "was", "be", "got"]
    private static let ordinalBlockedAfter: Set<String> = ["time", "times", "place", "half", "hand", "floor", "grade", "quarter", "year", "day",
        "week", "month", "round", "class", "person", "date", "draft", "version", "opinion", "guess", "nature", "rate", "of", "or", "and",
        "edition", "season", "episode", "chapter", "base", "aid", "impression", "name", "line", "cousin", "string", "team", "choice", "one",
        "ones", "to", "thing", "things", "step", "steps", "world", "language", "person's", "minute", "hour", "page", "item", "lady", "gen"]
    private static let determiners: Set<String> = ["a", "an", "the", "this", "that", "my", "your", "our", "their", "his", "her", "its",
        "any", "what", "which", "phone", "room", "each", "every", "no", "one", "same"]

    private static func markers(in line: String) -> [Marker] {
        let ns = line as NSString
        var out: [Marker] = []
        for m in markerRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: m.range.location)
            let after = ns.substring(from: m.range.location + m.range.length)
            let prev = lastWord(before).lowercased()
            let next = firstWord(after).lowercased()
            let boundary = isClauseStart(before)
            let punctAfter = after.first.map { ",.:)".contains($0) } ?? false
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)).lowercased() }
            if let w = g(1) {
                // "first of all", "first off"
                guard boundary || !ordinalBlockedBefore.contains(prev) else { continue }
                out.append(Marker(range: m.range, value: ordinalWords[w] ?? 0, family: .ordinal, boundary: boundary))
            } else if let w = g(2) {
                guard !ordinalBlockedBefore.contains(prev), !ordinalBlockedAfter.contains(next), !next.isEmpty else { continue }
                out.append(Marker(range: m.range, value: ordinalWords[w] ?? 0, family: .ordinal, boundary: boundary))
            } else if let w = g(3) {
                // "finally" and "lastly" end a list only at the start of a clause; "last" needs a comma ("Last, …").
                guard boundary, !next.isEmpty, w != "last" || after.hasPrefix(",") || after.hasPrefix(":") else { continue }
                out.append(Marker(range: m.range, value: 0, family: .terminal, boundary: true))
            } else if let prefix = g(4), let n = g(5) {
                guard !determiners.contains(prev), let v = numberWords[n] ?? Int(n), !next.isEmpty else { continue }
                out.append(Marker(range: m.range, value: v, family: .prefixed(prefix), boundary: boundary))
            } else if let n = g(6) {
                // "One, the photos." A bare number counts only at the start of a clause and before a mark.
                guard boundary, punctAfter, let v = numberWords[n] ?? Int(n) else { continue }
                if n.first?.isNumber == true, before.last.map({ "$£€#".contains($0) }) == true { continue }
                if after.count > 1, after.dropFirst().first?.isNumber == true { continue }   // "1.5", "1,000"
                out.append(Marker(range: m.range, value: v, family: .cardinal, boundary: true))
            }
        }
        return out
    }

    /// Finds "first… second… third…" (or another family) and splits the line around it.
    private static func enumeration(_ line: String) -> FoundList? {
        let all = markers(in: line)
        guard all.count >= 2 else { return nil }
        for (i, start) in all.enumerated() where start.value == 1 && start.family != .terminal {
            var seq = [start]
            var want = 2
            for c in all[(i + 1)...] {
                if c.family == start.family && c.value == want { seq.append(c); want += 1 }
                else if c.family == .terminal && want >= 2 { seq.append(c); break }
            }
            guard seq.count >= 2 else { continue }
            // Without punctuation to mark the clauses, ask for three items before calling it a list.
            if seq.contains(where: { !$0.boundary }) && seq.count < 3 { continue }
            if let found = split(line, at: seq) { return found }
        }
        return nil
    }

    private static func split(_ line: String, at seq: [Marker]) -> FoundList? {
        let ns = line as NSString
        let lead = trimConnectors(ns.substring(to: seq[0].range.location))
        var items: [String] = []
        for (k, m) in seq.enumerated() {
            let from = m.range.location + m.range.length
            let to = k + 1 < seq.count ? seq[k + 1].range.location : ns.length
            guard to > from else { return nil }
            items.append(ns.substring(with: NSRange(location: from, length: to - from)))
        }
        return finish(lead: lead, rawItems: items, ordered: true)
    }

    /// Cleans the items; nil when one is empty. The last item keeps only its first sentence when every other
    /// item is one sentence; what follows it becomes the next paragraph.
    private static func finish(lead: String, rawItems: [String], ordered: Bool) -> FoundList? {
        var items = rawItems.map { trimConnectors(trimLeading($0)) }
        guard items.count >= 2, items.allSatisfy({ $0.contains(where: { $0.isLetter || $0.isNumber }) }) else { return nil }
        // "Okay, so first of all…": a lead-in of only discourse words joins the first item, not a line of its own.
        var lead = lead
        let leadWords = lead.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if !leadWords.isEmpty && leadWords.allSatisfy(discourseWords.contains) {
            items[0] = lead.trimmingCharacters(in: .whitespaces) + " " + items[0]
            lead = ""
        }
        var trailer = ""
        if let last = items.last {
            let parts = sentences(last)
            if parts.count > 1 && items.dropLast().allSatisfy({ sentences($0).count == 1 }) {
                items[items.count - 1] = parts[0]
                trailer = parts.dropFirst().joined(separator: " ")
            }
        }
        // Short fragments ("The photos") read better without a period, as long as every item is one.
        if items.allSatisfy({ CleanupPrepass.wordCount($0) <= 6 && sentences($0).count == 1 }) {
            items = items.map { $0.hasSuffix(".") && !$0.hasSuffix("..") ? String($0.dropLast()) : $0 }
        }
        items = items.map { CleanupPrepass.capitalizeFirst($0) }
        return FoundList(lead: lead, items: items, ordered: ordered, trailer: trailer)
    }

    private static let discourseWords: Set<String> = ["okay", "ok", "so", "well", "alright", "all", "right", "now", "and", "um", "uh",
                                                      "like", "yeah", "then", "anyway", "anyways", "basically", "alright"]

    // MARK: Spoken bullets

    private static let bulletCue = try! NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}'’-])(next bullet point|next bullet|new bullet point|new bullet|bullet point|bullet|dash)(?![\\p{L}\\p{N}'’-])")
    private static let bulletBlockedBefore: Set<String> = ["a", "an", "the", "this", "that", "silver", "magic", "one", "each", "every", "another",
        "rubber", "first", "last", "single", "stray", "his", "her", "my", "your", "our", "their", "its", "no", "to", "em", "en", "with", "plus", "minus"]
    private static let bulletBlockedAfter: Set<String> = ["train", "journal", "journals", "proof", "points", "wound", "hole", "holes", "list",
        "lists", "style", "of", "cam", "board", "for", "and"]

    private static func bulletCues(in line: String) -> [NSRange] {
        let ns = line as NSString
        return bulletCue.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let before = ns.substring(to: m.range.location)
            let after = ns.substring(from: m.range.location + m.range.length)
            if bulletBlockedBefore.contains(lastWord(before).lowercased()) || bulletBlockedAfter.contains(firstWord(after).lowercased()) { return nil }
            if after.hasPrefix("-") { return nil }
            // "dash" is a cue only at the start of a clause ("Groceries, dash milk, dash eggs").
            if ns.substring(with: m.range).lowercased() == "dash" && !isClauseStart(before) { return nil }
            return m.range
        }
    }

    /// "Groceries bullet milk bullet eggs": two or more cues in one line.
    private static func spokenBullets(_ line: String) -> FoundList? {
        let cues = bulletCues(in: line)
        guard cues.count >= 2 else { return nil }
        let ns = line as NSString
        let lead = trimConnectors(ns.substring(to: cues[0].location))
        var items: [String] = []
        for (k, r) in cues.enumerated() {
            let from = r.location + r.length
            let to = k + 1 < cues.count ? cues[k + 1].location : ns.length
            let piece = ns.substring(with: NSRange(location: from, length: max(0, to - from)))
            if trimConnectors(trimLeading(piece)).isEmpty { continue }   // "bullet bullet"
            items.append(piece)
        }
        return finish(lead: lead, rawItems: items, ordered: false)
    }

    /// Lines that start with a bullet cue ("new line, bullet milk"), when two or more do, become list lines.
    private static func spokenBulletLines(_ lines: [String]) -> [String] {
        let starts: [Int: Int] = Dictionary(uniqueKeysWithValues: lines.enumerated().compactMap { i, l in
            guard let r = bulletCues(in: l).first, r.location == 0, bulletCues(in: l).count == 1 else { return nil }
            return (i, r.length)
        })
        guard starts.count >= 2 else { return lines }
        return lines.enumerated().map { i, l in
            guard let len = starts[i] else { return l }
            let rest = CleanupPrepass.capitalizeFirst(trimConnectors(trimLeading(String((l as NSString).substring(from: len)))))
            return rest.isEmpty ? l : "- " + rest
        }
    }

    // MARK: Announced lists

    private static let announcement = try! NSRegularExpression(pattern:
        "(?i)(?:\\b(?:a few|a couple of|a couple|several|two|three|four|five|six|seven|eight|nine|ten|\\d{1,2}) " +
        "(?:main |key |big |quick |other |more )?(things|items|points|steps|tasks|questions|options|ideas|issues|changes|updates|priorities)\\b" +
        "(?: (?:are|is|include|were))?|" +
        "\\bthe following\\b(?: (?:are|is|include))?|" +
        "\\bhere[’']?s what\\b|\\bhere are\\b)")

    /// A sentence that announces a list ("We need a few things, the photos, the copy, and the price list", or
    /// "Agenda: budget, timeline, and hiring") with three or more short items after it.
    private static func announcedList(_ line: String) -> FoundList? {
        let sents = sentences(line)
        for (i, s) in sents.enumerated() {
            guard let last = s.last, last != "?" else { continue }
            var body = s
            if ".!".contains(last) { body.removeLast() }
            guard let (lead, rest, steps) = announcedParts(body), let items = series(rest) else { continue }
            let before = sents[..<i].joined(separator: " ")
            let trailer = sents[(i + 1)...].joined(separator: " ")
            guard var found = finish(lead: (before.isEmpty ? "" : before + " ") + lead + ":", rawItems: items, ordered: steps) else { continue }
            found.trailer = [found.trailer, trailer].filter { !$0.isEmpty }.joined(separator: " ")
            return found
        }
        return nil
    }

    /// The lead-in and the items' text of an announced list, and whether the items are steps (numbered).
    private static func announcedParts(_ body: String) -> (String, String, Bool)? {
        let ns = body as NSString
        // "Agenda: budget, timeline, and hiring." A colon announces, except in a time ("3:30").
        if let colon = body.range(of: ": ") {
            let lead = String(body[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(body[colon.upperBound...])
            if lead.contains(where: { $0.isLetter }) && !lead.contains(",") {
                return (lead, rest, lead.lowercased().contains("step"))
            }
        }
        guard let comma = body.range(of: ","), let m = announcement.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let matchEnd = m.range.location + m.range.length
        guard matchEnd <= NSRange(comma, in: body).location else { return nil }
        let segment0 = String(body[..<comma.lowerBound])
        let rest = String(body[comma.upperBound...])
        let steps = m.range(at: 1).location != NSNotFound && ns.substring(with: m.range(at: 1)).lowercased() == "steps"
        let afterMatch = (segment0 as NSString).substring(from: matchEnd).trimmingCharacters(in: .whitespaces)
        let isHere = ns.substring(with: m.range).lowercased().hasPrefix("here")
        let opensPhrase = ["for", "about", "from", "to", "on", "in", "with", "at", "before", "after", "today", "this", "that", "here", "so", "that's", "we", "i", "you"]
            .contains(firstWord(afterMatch).lowercased())
        if afterMatch.isEmpty || isHere || opensPhrase { return (segment0, rest, steps) }
        // "We need three things the photos, the copy, and the list": the first item shares the segment.
        let lead = (segment0 as NSString).substring(to: matchEnd)
        return (lead, afterMatch + ", " + rest, steps)
    }

    /// Splits "the photos, the copy, and the price list" into three or more short items; nil otherwise.
    private static func series(_ text: String) -> [String]? {
        var parts = text.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, var last = parts.popLast() else { return nil }
        if let r = last.range(of: #"^(?:and|or) "#, options: [.regularExpression, .caseInsensitive]) {
            last.removeSubrange(r)
            parts.append(last)
        } else if let r = last.range(of: " and ", options: .backwards) ?? last.range(of: " or ", options: .backwards) {
            parts.append(String(last[..<r.lowerBound]))
            parts.append(String(last[r.upperBound...]))
        } else {
            parts.append(last)
        }
        parts = parts.filter { !$0.isEmpty }
        guard parts.count >= 3, parts.allSatisfy({ (1...10).contains(CleanupPrepass.wordCount($0)) }) else { return nil }
        return parts
    }

    // MARK: Paragraphs

    private static let topicShift = try! NSRegularExpression(pattern:
        "^[\"“]?(?i:also,|another thing|one more thing|next,|next up|anyway,|anyways,|okay,? so\\b|ok,? so\\b|all right,? so\\b|alright,? so\\b|" +
        "so,? anyway\\b|on a (?:different|separate|related|side) note|on another note|separately,|second point|moving on|in other news|" +
        "besides that|apart from that|other than that|oh,? and\\b|oh,? also\\b|last thing|the last thing|lastly,|finally,|by the way|" +
        "switching gears|changing (?:topics|gears|subjects)|additionally,|meanwhile,|as for\\b|regarding\\b|the other thing)")
    private static let softStart = try! NSRegularExpression(pattern: "^(?:So|But|Now|Then|However|Still|Overall|After that|Once|For example|For instance|In the meantime|If|When|The (?:good|bad|main|other|big|real)|My|Our|I think|We should|What)\\b")
    private static let continuation = try! NSRegularExpression(pattern: "^(?:It|That|This|They|These|Those|He|She|Which|And|Or|Because|Plus|Even|Too)\\b")

    /// Breaks a run of prose into paragraphs: at topic shifts, then inside paragraphs that run long.
    static func paragraphs(_ text: String, auto: Bool) -> String {
        guard auto else { return text }
        let sents = sentences(text)
        guard sents.count > 1 else { return text }
        var groups: [[String]] = [[]]
        for (i, s) in sents.enumerated() {
            if i > 0, matches(topicShift, s), !groups[groups.count - 1].isEmpty { groups.append([]) }
            groups[groups.count - 1].append(s)
        }
        return groups.flatMap(splitLong).map { $0.joined(separator: " ") }.joined(separator: "\n\n")
    }

    private static func isLong(_ group: [String]) -> Bool {
        let words = group.reduce(0) { $0 + CleanupPrepass.wordCount($1) }
        return group.count > 1 && (words > 90 || (group.count > 4 && words > 50))
    }

    /// Splits a long paragraph at the sentence boundary that best balances its halves, preferring a sentence
    /// that starts a new step of thought ("So", "But", "Now") over one that refers back ("It", "That").
    private static func splitLong(_ group: [String]) -> [[String]] {
        guard isLong(group) else { return [group] }
        let n = group.count
        let minSide = n >= 4 ? 2 : 1
        let counts = group.map(CleanupPrepass.wordCount)
        let total = counts.reduce(0, +)
        var best = minSide, bestScore = Int.min
        var left = counts[..<minSide].reduce(0, +)
        for k in minSide...(n - minSide) {
            if k > minSide { left += counts[k - 1] }
            var score = -abs(total - 2 * left)
            if matches(softStart, group[k]) { score += 30 }
            if matches(continuation, group[k]) { score -= 30 }
            if score > bestScore { bestScore = score; best = k }
        }
        return splitLong(Array(group[..<best])) + splitLong(Array(group[best...]))
    }

    // MARK: Email

    private static let greeting = try! NSRegularExpression(pattern: "^((?:Hi|Hello|Hey|Dear|Good (?:morning|afternoon|evening))(?:\\s+[\\p{L}][\\p{L}'’.-]*){0,3}\\s*,)\\s+(\\S[\\s\\S]*)$")

    /// "Hi Sarah, thanks for…" → ("Hi Sarah,", "Thanks for…"), when the rest is a message of its own.
    private static func splitGreeting(_ block: String) -> (String, String)? {
        let ns = block as NSString
        guard let m = greeting.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let rest = ns.substring(with: m.range(at: 2))
        guard CleanupPrepass.wordCount(rest) >= 6, listLine(rest) == nil else { return nil }
        return (ns.substring(with: m.range(at: 1)), CleanupPrepass.capitalizeFirst(rest))
    }

    private static let signOff = try! NSRegularExpression(pattern: "([.!?])[ \\t]+((?:Best|Best regards|Kind regards|Warm regards|Regards|Cheers|Sincerely|Talk soon|All the best),?)[ \\t]+(\\p{Lu}[\\p{L}'’-]*)\\.?$")

    /// "…see you then. Best, Tim" → the sign-off and name on lines of their own. "Thanks, Sarah" is left alone:
    /// it may thank the reader rather than sign the email.
    private static func splitSignOff(_ text: String) -> String {
        let ns = text as NSString
        guard let m = signOff.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
        var word = ns.substring(with: m.range(at: 2))
        if !word.hasSuffix(",") { word += "," }
        return ns.substring(to: m.range(at: 1).location + 1) + "\n\n" + word + "\n" + ns.substring(with: m.range(at: 3))
    }

    // MARK: Sentences and words

    private static let sentenceEnd = try! NSRegularExpression(pattern: "[.!?][\"”’)]?\\s+(?=[\"“‘(]?[\\p{Lu}\\p{N}])")
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "etc", "e.g", "i.e", "inc", "jr", "sr", "no", "approx", "prof", "mt", "ft", "u.s"]

    /// Splits prose into sentences at ". ", "? ", and "! " before a capital or a digit, not after "Dr." or "e.g.".
    static func sentences(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        var start = 0
        for m in sentenceEnd.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let head = ns.substring(with: NSRange(location: start, length: m.range.location - start))
            if ns.substring(with: m.range).hasPrefix("."), abbreviations.contains(lastWord(head, keepingDots: true).lowercased()) { continue }
            let end = m.range.location + m.range.length
            let s = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { out.append(s) }
            start = end
        }
        let tail = ns.substring(from: start).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// True when `before` ends where a clause starts: nothing, punctuation, or "and" or "then".
    private static func isClauseStart(_ before: String) -> Bool {
        let t = before.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return true }
        if ".!?;:,—–-(".contains(last) { return true }
        return ["and", "then", "also", "plus"].contains(lastWord(t).lowercased())
    }

    private static func lastWord(_ s: String, keepingDots: Bool = false) -> String {
        var t = Substring(s)
        while let ch = t.last, ch == " " || ch == "\t" || ",.;:!?".contains(ch) { t = t.dropLast() }
        var w = ""
        while let ch = t.last, ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || (keepingDots && ch == ".") { w.insert(ch, at: w.startIndex); t = t.dropLast() }
        return w
    }

    private static func firstWord(_ s: String) -> String {
        var t = Substring(s)
        while let ch = t.first, ch == " " || ch == "\t" || ",.;:!?".contains(ch) { t = t.dropFirst() }
        return String(t.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }))
    }

    /// Drops the punctuation and spaces a cue leaves before its item (", " in "First, the photos").
    private static func trimLeading(_ s: String) -> String {
        String(s.drop(while: { " \t,.:;)-–—".contains($0) }))
    }

    private static let trailingConnector = try! NSRegularExpression(pattern: "(?i)[\\s,;]*(?:\\b(?:and then|and|then|or|also|plus))?[\\s,;]*$")

    /// Drops what joins one item to the next cue: a trailing comma, "and", or "and then".
    private static func trimConnectors(_ s: String) -> String {
        let ns = s as NSString
        let t = trailingConnector.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
