import Foundation

/// Rule-based layout for dictation: numbered lists, bulleted lists, and paragraphs. Runs on the Mac with no
/// model, so lists and paragraphs work when Apple Intelligence is missing, slow, times out, or ignores the
/// instruction. `FlowCleanup` runs it on the cleaned text at Clean and Polished, after the model when the model
/// ran; never at Literal or in code apps. Foundation only.
///
/// What it does:
/// - Numbered lists from spoken enumeration: two or more items whose cues count up from one, from any family,
///   mixed freely: "first", "first of all", "first off", "firstly", "the first thing is", "number one", "step one",
///   "one,", "1st", "#1", "No. 1", "to start," → "second", "number two", "Number 2", … → "finally", "lastly".
///   "next" and "then" fill a place only between counted cues. Two items are enough when both cues are clear
///   ("first of all… number two…"); a bare mid-sentence ordinal takes three. "First of all" with no second
///   item stays a sentence. A lead-in sentence before the first item ends with a colon when it announces the
///   items ("We need three things:").
/// - Bulleted lists from spoken cues ("bullet", "next bullet", "bullet point", "dash"), and from an announced
///   comma series: "a few things", "the following", "here's what we need", "three things", or a colon, followed
///   by three or more short items. A colon announces only after a lead-in that names the list ("Agenda:", "Three
///   things:") or before clause-length items; "Quick update: we shipped, fixed the bug, and hired Sam" stays a
///   sentence. An ordinary sentence with a comma series stays a sentence.
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

    /// How long paragraphs run, by destination.
    enum Paragraphs: String, Equatable {
        /// Notes, documents, everything else: 4 sentences or 90 words.
        case normal
        /// Email, Normal: 1 to 4 sentences, up to 90 words, split before a closing ask when it runs long.
        case email
        /// Email, Short: 1 or 2 sentences, up to 50 words.
        case short
        /// Slack and Teams: 1 to 3 sentences, up to 60 words.
        case chat
        /// Messages and WhatsApp: one paragraph unless it runs past 60 words.
        case message

        struct Rule {
            /// Messages with fewer words keep their paragraphs as spoken.
            var minWords: Int
            var maxSentences: Int
            var maxWords: Int
            /// More than `maxSentences` sentences splits only past this many words (0: always).
            var sentenceSplitWords: Int
            /// Prefer a break before a closing ask ("Can you…", "Let me know…").
            var asks: Bool
        }

        var rule: Rule {
            switch self {
            case .normal: return Rule(minWords: 40, maxSentences: 4, maxWords: 90, sentenceSplitWords: 50, asks: false)
            case .email: return Rule(minWords: 40, maxSentences: 4, maxWords: 90, sentenceSplitWords: 0, asks: true)
            case .short: return Rule(minWords: 25, maxSentences: 2, maxWords: 50, sentenceSplitWords: 0, asks: true)
            case .chat: return Rule(minWords: 30, maxSentences: 3, maxWords: 60, sentenceSplitWords: 0, asks: true)
            case .message: return Rule(minWords: 60, maxSentences: 4, maxWords: 90, sentenceSplitWords: 50, asks: false)
            }
        }
    }

    struct Options: Equatable {
        var style: ListStyle = .markdown
        /// Puts a spoken greeting ("Hi Sarah,") and sign-off ("Thanks, Tim") on lines of their own.
        var email = false
        /// The cursor is inside a message that already has writing before it: no greeting or sign-off lines.
        var insertion = false
        var paragraphs: Paragraphs = .normal
        /// A blank line between a lead-in and the list under it (email reads cleaner that way in Gmail and Mail).
        var blankBeforeList = false
        /// Your name ("Tim Medina"), so "thanks Tim" at the end is your sign-off, not thanks to someone named Tim.
        var signer: [String] = []
    }

    /// The options for an app kind, or nil when the text goes in untouched.
    ///
    /// - Email (Mail, Outlook, Gmail): plain bullets. Mail composers paste text as typed, so "- " would stay a
    ///   dash; "•" reads as a bullet everywhere. Greetings and sign-offs get their own lines.
    /// - Personal messages (Messages, WhatsApp, Signal): plain bullets, for the same reason; short messages stay
    ///   one paragraph.
    /// - Work chat (Slack, Teams, Discord, Linear): Markdown, short paragraphs.
    /// - Everything else (Notion, notes, documents, browsers, ChatGPT and Claude): Markdown. These apps render it,
    ///   convert it on paste, or (AI prompts) read it as structure.
    /// - Code apps: nil. Words go in as spoken.
    static func options(for category: AppCategory) -> Options? {
        switch category {
        case .code: return nil
        case .email: return Options(style: .plain, email: true, paragraphs: .email, blankBeforeList: true)
        case .personal: return Options(style: .plain, paragraphs: .message)
        case .work: return Options(style: .markdown, paragraphs: .chat)
        case .other: return Options(style: .markdown)
        }
    }

    /// Settings › Dictation › Email: greeting and sign-off lines, and paragraph length. Stored on this device.
    enum EmailPrefs {
        static let ownLinesKey = "flow.email.ownLines"
        static let paragraphsKey = "flow.email.paragraphs"
        static var ownLines: Bool { UserDefaults.standard.object(forKey: ownLinesKey) as? Bool ?? true }
        static var short: Bool { UserDefaults.standard.string(forKey: paragraphsKey) == Paragraphs.short.rawValue }

        /// Email options with these settings.
        static func options(ownLines: Bool = EmailPrefs.ownLines, short: Bool = EmailPrefs.short, insertion: Bool = false, signer: [String] = []) -> Options {
            Options(style: .plain, email: ownLines, insertion: insertion, paragraphs: short ? .short : .email, blankBeforeList: true, signer: signer)
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
        var body = t
        var greetingLine: String?
        var greetingName: String?
        var signOff: [String] = []
        if o.email && !o.insertion {
            if let g = splitGreeting(body) { greetingLine = g.line; greetingName = g.name; body = g.rest }
            if let s = splitSignOff(body, signer: o.signer, greetingName: greetingName) { body = s.body; signOff = s.lines }
            else if greetingLine != nil { body = closeSentence(body) }
        }
        let rule = o.paragraphs.rule
        // Words with a letter, so list numbers ("1.") added by a first run don't count on the second.
        let auto = body.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter }) }.count >= rule.minWords
        let blocks = body.replacingOccurrences(of: "\\n[ \\t]*(?:\\n[ \\t]*)+", with: "\u{0}", options: .regularExpression)
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var parts: [String] = []
        if let greetingLine { parts.append(greetingLine) }
        let formatted = blocks.map { formatBlock($0, o, auto: auto) }.joined(separator: "\n\n")
        if !formatted.isEmpty { parts.append(formatted) }
        if !signOff.isEmpty { parts.append(signOff.joined(separator: "\n")) }
        return tidy(parts.joined(separator: "\n\n"))
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
                out += (afterList && !startsList) || (o.blankBeforeList && !afterList && startsList) ? "\n\n" : "\n"
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
                s += paragraphs(text, auto: auto, o.paragraphs.rule) + (colon && !o.blankBeforeList ? "\n" : "\n\n")
            }
            s += renderList(l.items, ordered: l.ordered, o)
            let trailer = l.trailer.trimmingCharacters(in: .whitespaces)
            if !trailer.isEmpty { s += "\n\n" + formatProse(trailer, o, auto: auto) }
            return s
        }
        return paragraphs(line, auto: auto, o.paragraphs.rule)
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

    private enum Kind: Equatable {
        /// Counts an item: "first", "number two", "secondly", "the third thing is", "2nd", "#2", "One,".
        case counted
        /// "finally", "lastly", "Last,", "the last thing is": the last item.
        case terminal
        /// "next" and "then": the next item, only between counted cues ("First… then… third…").
        case soft
    }

    private struct Marker {
        var range: NSRange
        var value: Int        // 0 for terminal and soft cues
        var kind: Kind
        var boundary: Bool    // starts a clause: line start, after punctuation, or after "and" or "then"
        /// Clear enough that two items make a list without punctuation: "first of all", "number two", "secondly",
        /// a cue at the start of a clause, or a bare ordinal before a subject ("second we need…").
        var strong: Bool
    }

    private static let numberWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
    private static let ordinalWords: [String: Int] = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]

    private static let ordinalPattern = "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth"
    private static let numberPattern = "one|two|three|four|five|six|seven|eight|nine|ten"

    /// Every spoken cue family. Families mix freely in one list ("first of all… number two… and lastly…").
    private static let markerRegex = try! NSRegularExpression(pattern:
        "(?i)(?<![\\p{L}\\p{N}'’#-])(?:" +
        "(first|second|third|fourth|fifth) (?:of all|off)|" +                                                    // 1
        "the (\(ordinalPattern)|next|last|final) (?:thing|point|item|step|one)(?: (?:is|was)\\b|(?=[,:]))|" +     // 2
        "(\(ordinalPattern))(ly)?|" +                                                                            // 3, 4
        "(\\d{1,2})(?:st|nd|rd|th)|" +                                                                           // 5
        "(finally|lastly|last)|" +                                                                               // 6
        "(number|step|point|item|option|reason|phase|part) (\(numberPattern)|\\d{1,2})|" +                       // 7, 8
        "(?:#|no\\. ?)(\\d{1,2})|" +                                                                             // 9
        "(to start(?: off| with)?|to begin(?: with)?|for starters)|" +                                           // 10
        "(next|then)|" +                                                                                         // 11
        "(\(numberPattern)|\\d{1,2})" +                                                                          // 12
        ")(?![\\p{L}\\p{N}'’-])")

    /// Words before "first" or "second" that make it an adjective or a noun ("the first time", "a second").
    private static let ordinalBlockedBefore: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their",
        "his", "her", "its", "every", "each", "per", "one", "at", "for", "in", "very", "came", "come", "comes", "finished", "ranked", "placed",
        "love", "split", "whose", "which", "what", "same", "no", "any", "some", "only", "just", "wait", "hold", "his", "is", "was", "be", "got"]
    private static let ordinalBlockedAfter: Set<String> = ["time", "times", "place", "half", "hand", "floor", "grade", "quarter", "year", "day",
        "week", "month", "round", "class", "person", "date", "draft", "version", "opinion", "guess", "nature", "rate", "of", "or", "and",
        "edition", "season", "episode", "chapter", "base", "aid", "impression", "name", "line", "cousin", "string", "team", "choice", "one",
        "ones", "to", "thing", "things", "step", "steps", "world", "language", "person's", "minute", "hour", "page", "item", "lady", "gen",
        "century", "birthday", "anniversary", "street", "avenue", "row", "seat", "inning", "period", "act", "scene", "take", "cut", "pass",
        "look", "glance", "sight", "thought", "thoughts"]
    /// Words after "number one" that make it a ranking ("number one priority"), not a cue.
    private static let prefixedBlockedAfter: Set<String> = ["priority", "priorities", "fan", "fans", "spot", "seed", "pick", "choice",
        "hit", "song", "rule", "draft", "overall", "ranked", "in", "on", "at", "of", "or", "and", "to"]
    /// Words after "next" that make it a time or an adjective ("next week", "next time").
    private static let nextBlockedAfter: Set<String> = ["week", "weeks", "time", "times", "year", "month", "day", "days", "morning",
        "weekend", "door", "one", "ones", "to", "few", "step", "steps", "thing", "things", "up"]
    /// A bare ordinal mid-sentence is a cue when a clause starts after it ("…the location second we need…").
    private static let clauseOpeners: Set<String> = ["we", "i", "you", "they", "let's", "lets", "we'll", "i'll", "you'll", "we're",
        "we've", "i've", "i'm", "make", "call", "send", "get", "check", "ask", "book", "confirm", "don't", "do", "please"]
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
            func add(_ value: Int, _ kind: Kind, strong: Bool) {
                out.append(Marker(range: m.range, value: value, kind: kind, boundary: boundary, strong: strong || boundary))
            }
            if let w = g(1) {
                // "first of all", "first off"
                guard boundary || !ordinalBlockedBefore.contains(prev), !next.isEmpty else { continue }
                add(ordinalWords[w] ?? 0, .counted, strong: true)
            } else if let w = g(2) {
                // "the second thing is", "the last point,"
                guard !next.isEmpty else { continue }
                switch w {
                case "next": add(0, .soft, strong: false)
                case "last", "final": add(0, .terminal, strong: true)
                default: add(ordinalWords[w] ?? 0, .counted, strong: true)
                }
            } else if let w = g(3) {
                let ly = g(4) != nil
                guard !ordinalBlockedBefore.contains(prev), ly || !ordinalBlockedAfter.contains(next), !next.isEmpty else { continue }
                add(ordinalWords[w] ?? 0, .counted, strong: ly || clauseOpeners.contains(next))
            } else if let d = g(5) {
                // "2nd", "3rd": like the words, when a digit stands in for one.
                guard !ordinalBlockedBefore.contains(prev), !ordinalBlockedAfter.contains(next), !next.isEmpty, let v = Int(d) else { continue }
                add(v, .counted, strong: clauseOpeners.contains(next))
            } else if let w = g(6) {
                // "finally" and "lastly" end a list only at the start of a clause; "last" needs a comma ("Last, …").
                guard boundary, !next.isEmpty, w != "last" || after.hasPrefix(",") || after.hasPrefix(":") else { continue }
                add(0, .terminal, strong: true)
            } else if let prefix = g(7), let n = g(8) {
                guard !determiners.contains(prev), let v = numberWords[n] ?? Int(n), !next.isEmpty else { continue }
                if prefix == "number" && prefixedBlockedAfter.contains(next) && !punctAfter { continue }
                add(v, .counted, strong: true)
            } else if let d = g(9) {
                // "#2", "No. 2"
                guard !determiners.contains(prev), let v = Int(d), !next.isEmpty else { continue }
                add(v, .counted, strong: true)
            } else if g(10) != nil {
                // "To start, …", "For starters, …": the first item, at the start of a clause and before a comma.
                guard boundary, punctAfter, !next.isEmpty else { continue }
                add(1, .counted, strong: true)
            } else if let w = g(11) {
                guard boundary, !next.isEmpty, w == "then" || !nextBlockedAfter.contains(next) else { continue }
                add(0, .soft, strong: false)
            } else if let n = g(12) {
                // "One, the photos." A bare number counts only at the start of a clause and before a mark.
                guard boundary, punctAfter, let v = numberWords[n] ?? Int(n) else { continue }
                if n.first?.isNumber == true, before.last.map({ "$£€".contains($0) }) == true { continue }
                if after.count > 1, after.dropFirst().first?.isNumber == true { continue }   // "1.5", "1,000"
                add(v, .counted, strong: true)
            }
        }
        return out
    }

    /// Finds a counted sequence and splits the line around it: two or more items whose cues count up from one,
    /// from any family ("first of all… number two… and lastly…"). "next" and "then" fill a place only between
    /// counted cues. Two items are enough when both cues are clear; otherwise it takes three.
    private static func enumeration(_ line: String) -> FoundList? {
        let all = markers(in: line)
        guard all.count >= 2 else { return nil }
        for (i, start) in all.enumerated() where start.value == 1 && start.kind == .counted {
            var seq = [start]
            var want = 2
            for (j, c) in all.enumerated() where j > i {
                switch c.kind {
                case .counted:
                    if c.value == want {
                        seq.append(c); want += 1
                    } else if c.value >= 2 && c.value < want, let k = seq.firstIndex(where: { $0.value == c.value }),
                              seq[k...].allSatisfy({ $0.kind == .soft }) {
                        // "First… and then… Second…": the "then" was inside the first item.
                        seq.removeSubrange(k...); seq.append(c); want = c.value + 1
                    }
                case .soft:
                    // "then" right before another cue ("then second") is a connector, not an item.
                    let nextStart = j + 1 < all.count ? all[j + 1].range.location : (line as NSString).length
                    let gap = (line as NSString).substring(with: NSRange(location: c.range.location + c.range.length,
                                                                         length: max(0, nextStart - c.range.location - c.range.length)))
                    guard j + 1 >= all.count || gap.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                    var s = c; s.value = want
                    seq.append(s); want += 1
                case .terminal:
                    if want >= 2 { seq.append(c) }
                }
                if seq.last?.kind == .terminal { break }
            }
            while seq.last?.kind == .soft { seq.removeLast() }   // "…then let me know" after the last item stays in it
            guard seq.filter({ $0.kind != .soft }).count >= 2 else { continue }
            if seq.count < 3 && seq.contains(where: { !$0.strong }) { continue }
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
        } else if items.contains(where: endsSentence) {
            // Longer items: when some end with a period ("First of all, X. Second, Y"), all of them do.
            items = items.map { $0.last.map { $0.isLetter || $0.isNumber || ")”’\"".contains($0) } == true ? $0 + "." : $0 }
        }
        items = items.map { CleanupPrepass.capitalizeFirst($0) }
        return FoundList(lead: lead, items: items, ordered: ordered, trailer: trailer)
    }

    private static func endsSentence(_ s: String) -> Bool { s.last.map { ".!?".contains($0) } ?? false }

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
            if lead.contains(where: { $0.isLetter }) && !lead.contains(","), colonAnnounces(lead: lead, items: rest) {
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

    /// Lead-in words that make a colon announce a list: "Three things:", "Here's the plan:", "Agenda:".
    private static let colonAnnouncer = try! NSRegularExpression(pattern:
        "(?i)\\b(?:things|items|steps|following|lists?|points|reasons|options|tasks|questions|ideas|issues|priorities|topics|" +
        "agenda|ingredients|groceries|to-?dos?|takeaways|action items)\\b|\\bhere[’']?s\\b|\\bhere are\\b|" +
        "\\b(?:a few|a couple of|several|two|three|four|five|six|seven|eight|nine|ten|\\d{1,2}) (?:[a-z]+ )?[a-z]{3,}s\\b")
    /// Lead-in endings that introduce news or a remark rather than a list ("Quick update:", "Heads up:").
    private static let colonRemarkEnd: Set<String> = ["update", "updates", "news", "note", "recap", "summary", "status", "reminder",
        "fyi", "up", "question", "thought", "said", "says", "is", "was", "honestly", "basically"]

    /// Whether "lead: items" is a list announcement. A short remark before a colon ("Quick update: we shipped, fixed
    /// the bug, and hired Sam") stays a sentence. The colon announces when the lead-in names the list ("three
    /// things", "the following", "here's", "agenda"), or when there are three or more clause-length items (three
    /// words or more each) after a lead-in of three words or more that doesn't end like a remark ("update").
    private static func colonAnnounces(lead: String, items: String) -> Bool {
        let ns = lead as NSString
        if colonAnnouncer.firstMatch(in: lead, range: NSRange(location: 0, length: ns.length)) != nil { return true }
        guard CleanupPrepass.wordCount(lead) >= 3, !colonRemarkEnd.contains(lastWord(lead).lowercased()),
              let parts = series(items) else { return false }
        return parts.allSatisfy { CleanupPrepass.wordCount($0) >= 3 }
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
    /// A sentence that asks something of the reader, where a long email or chat message reads best split.
    private static let askStart = try! NSRegularExpression(pattern: "^(?:Can|Could|Would|Will) you\\b|^(?:Let me know|Please|Do you|Are you|Is there|When can|Any chance|Feel free)\\b")

    /// Breaks a run of prose into paragraphs: at topic shifts, then inside paragraphs that run long.
    static func paragraphs(_ text: String, auto: Bool, _ rule: Paragraphs.Rule = Paragraphs.normal.rule) -> String {
        guard auto else { return text }
        let sents = sentences(text)
        guard sents.count > 1 else { return text }
        var groups: [[String]] = [[]]
        for (i, s) in sents.enumerated() {
            if i > 0, matches(topicShift, s), !groups[groups.count - 1].isEmpty { groups.append([]) }
            groups[groups.count - 1].append(s)
        }
        return groups.flatMap { splitLong($0, rule) }.map { $0.joined(separator: " ") }.joined(separator: "\n\n")
    }

    private static func isLong(_ group: [String], _ rule: Paragraphs.Rule) -> Bool {
        let words = group.reduce(0) { $0 + CleanupPrepass.wordCount($1) }
        return group.count > 1 && (words > rule.maxWords || (group.count > rule.maxSentences && words > rule.sentenceSplitWords))
    }

    /// Splits a long paragraph at the sentence boundary that best balances its halves, preferring a sentence
    /// that starts a new step of thought ("So", "But", "Now") over one that refers back ("It", "That").
    private static func splitLong(_ group: [String], _ rule: Paragraphs.Rule) -> [[String]] {
        guard isLong(group, rule) else { return [group] }
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
            if rule.asks && matches(askStart, group[k]) { score += 30 }
            if score > bestScore { bestScore = score; best = k }
        }
        return splitLong(Array(group[..<best]), rule) + splitLong(Array(group[best...]), rule)
    }

    // MARK: Email

    // Greetings and sign-offs go on lines of their own only when you said them; nothing is ever added.

    private static let greetWord = try! NSRegularExpression(pattern:
        "^(?i:(good (?:morning|afternoon|evening)|hello|hiya|hey|hi|dear|greetings|morning|afternoon|evening))(?![\\p{L}\\p{N}'’-])")
    private static let wordAt = try! NSRegularExpression(pattern: "[ \\t]*([\\p{L}][\\p{L}\\p{N}'’-]*)")
    private static let joinerAt = try! NSRegularExpression(pattern: "[ \\t]*,?[ \\t]+(?:and|&)(?=[ \\t])")
    private static let separatorAt = try! NSRegularExpression(pattern: "[ \\t]*([,.!:;—–-]*)")

    /// Who a greeting can address without a capital: "Hi team", "Hello everyone", "Hey all".
    private static let groupWords: Set<String> = ["team", "everyone", "everybody", "all", "folks", "guys", "there", "both", "y'all", "y’all",
                                                  "friends", "gang", "crew", "again"]
    private static let titleWords: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "miss", "mx"]
    /// Capitalized words that start the message rather than name someone: "Hi Sarah I wanted…" stops at "I".
    private static let notNames: Set<String> = ["i", "i'm", "i’m", "i've", "i’ve", "i'll", "i’ll", "i'd", "i’d", "we", "we're", "we’re", "we'll", "we’ll",
        "just", "hope", "hoping", "thanks", "thank", "can", "could", "would", "will", "quick", "so", "it", "it's", "it’s", "this", "that",
        "the", "a", "an", "please", "how", "what", "when", "where", "why", "who", "wanted", "following", "sorry", "happy", "good", "great",
        "let", "let's", "let’s", "are", "is", "do", "did", "have", "here", "here's", "here’s", "there's", "our", "my", "your", "per", "as",
        "attached", "welcome", "not", "any", "if", "one", "also", "okay", "ok", "yes", "no", "yeah", "hey", "hi", "hello", "dear", "god",
        "lord", "you", "they", "he", "she", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow",
        "tonight", "just", "long", "nice", "glad", "congrats", "congratulations", "best", "regards", "cheers", "sincerely", "and", "but", "or"]
    /// Lowercase words that never name anyone after "hi": "hey, can you…", "hi so…".
    private static let notLowercaseNames: Set<String> = ["so", "just", "um", "uh", "quick", "yeah", "okay", "ok", "well", "can", "could", "would",
        "how", "what", "i", "hope", "thanks", "thank", "sorry", "please", "is", "are", "do", "did", "there's", "here's", "it's", "man", "dude",
        "buddy", "mate", "bro", "you", "again", "and"]

    private static func isCapitalized(_ w: String) -> Bool { w.first?.isUppercase == true }

    private static func word(in ns: NSString, at p: Int) -> (text: String, end: Int)? {
        guard p < ns.length, let m = wordAt.firstMatch(in: ns as String, options: .anchored, range: NSRange(location: p, length: ns.length - p)) else { return nil }
        return (ns.substring(with: m.range(at: 1)), m.range.location + m.range.length)
    }

    /// "Hi Sarah, thanks for…" → ("Hi Sarah,", "Thanks for…"); "hi Sarah how are you" → ("Hi Sarah,", "How are
    /// you"); "Hi, Sarah." → "Hi Sarah,". A greeting with no name ("Hey,") counts only when a new sentence follows
    /// it, so "Hey, can you send…" and "Hello world is…" stay as they are. `name` is who was greeted, lowercased.
    private static func splitGreeting(_ text: String) -> (line: String, rest: String, name: String?)? {
        let ns = text as NSString
        guard let g = greetWord.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let greet = ns.substring(with: g.range(at: 1))
        let lowGreet = greet.lowercased()
        var p = g.range.location + g.range.length
        let sep1Match = separatorAt.firstMatch(in: text, options: .anchored, range: NSRange(location: p, length: ns.length - p))
        let sep1 = sep1Match.map { ns.substring(with: $0.range(at: 1)) } ?? ""
        if let s = sep1Match { p = s.range.location + s.range.length }
        let afterGreet = p

        // Names: "Sarah", "Sarah Jones", "Mr. Smith", "Sarah and Jake", "team", or one lowercase name before a comma.
        var names: [String] = []
        if !sep1.contains(".") && !sep1.contains("!") {
            while let (w, e) = word(in: ns, at: p) {
                let lw = w.lowercased()
                if names.isEmpty && groupWords.contains(lw) { names.append(lw); p = e; break }
                if titleWords.contains(lw) {
                    var e1 = e
                    if e1 < ns.length && ns.substring(with: NSRange(location: e1, length: 1)) == "." { e1 += 1 }
                    guard let (w2, e2) = word(in: ns, at: e1), isCapitalized(w2), !notNames.contains(w2.lowercased()) else { break }
                    names.append(CleanupPrepass.capitalizeFirst(lw) + ". " + w2); p = e2
                } else if isCapitalized(w) && !notNames.contains(lw) && !lw.hasSuffix("'s") && !lw.hasSuffix("’s") {
                    var name = w; p = e
                    if let (w2, e2) = word(in: ns, at: e), isCapitalized(w2), !notNames.contains(w2.lowercased()),
                       ns.substring(with: NSRange(location: e, length: e2 - e)).hasPrefix(" "),
                       !ns.substring(with: NSRange(location: e, length: e2 - e)).contains(",") {
                        // A surname, when another word follows it ("Hi Sarah Jones, …"), not the end of the text.
                        if let next = separatorAt.firstMatch(in: text, options: .anchored, range: NSRange(location: e2, length: ns.length - e2)),
                           ns.substring(with: next.range(at: 1)).isEmpty == false || e2 == ns.length {
                            name += " " + w2; p = e2
                        }
                    }
                    names.append(name)
                } else if names.isEmpty, !isCapitalized(w), !notLowercaseNames.contains(lw), !notNames.contains(lw), w.count >= 2,
                          e < ns.length, ns.substring(with: NSRange(location: e, length: 1)) == "," {
                    names.append(CleanupPrepass.capitalizeFirst(w)); p = e
                    break
                } else { break }
                // "and Jake", "& Jake"
                guard let j = joinerAt.firstMatch(in: text, options: .anchored, range: NSRange(location: p, length: ns.length - p)),
                      let (w3, _) = word(in: ns, at: j.range.location + j.range.length),
                      isCapitalized(w3), !notNames.contains(w3.lowercased()), names.count < 3 else { break }
                p = j.range.location + j.range.length
            }
        }
        if lowGreet == "dear" && names.isEmpty { return nil }
        if names.isEmpty { p = afterGreet }
        // What ends the greeting: a comma, a period, or nothing ("hi Sarah how are you").
        let sep2Match = separatorAt.firstMatch(in: text, options: .anchored, range: NSRange(location: p, length: ns.length - p))
        let sep2 = names.isEmpty ? sep1 : (sep2Match.map { ns.substring(with: $0.range(at: 1)) } ?? "")
        if !names.isEmpty, let s = sep2Match { p = s.range.location + s.range.length }
        let rest = ns.substring(from: p).trimmingCharacters(in: .whitespacesAndNewlines)
        if names.isEmpty {
            // "Hey." / "Hi, I wanted…" / "Good morning!" alone: a greeting only before a new sentence.
            guard !sep1.isEmpty || rest.isEmpty else { return nil }
            if let first = rest.first, !(first.isUppercase || first.isNumber) { return nil }
        } else if rest.isEmpty == false, sep2.isEmpty, let first = rest.first, !first.isLetter && !first.isNumber && first != "\"" && first != "“" {
            return nil
        }
        let greeting = CleanupPrepass.capitalizeFirst(lowGreet)
        let line = greeting + (names.isEmpty ? "" : " " + names.joined(separator: " and ")) + ","
        let name = names.isEmpty ? nil : names.joined(separator: " and ").lowercased()
        return (line, CleanupPrepass.capitalizeFirst(rest), name)
    }

    // MARK: Sign-off

    private static let thanksClosers = ["thank you so much", "thank you very much", "thanks so much", "thanks very much", "thanks a lot",
        "thanks a ton", "thanks again", "thanks in advance", "thank you again", "thank you", "many thanks", "thanks", "thx",
        "appreciate it", "much appreciated"]
    private static let otherClosers = ["best regards", "kind regards", "warm regards", "warmest regards", "warm wishes", "best wishes",
        "all the best", "regards", "best", "cheers", "sincerely", "warmly", "talk soon", "speak soon", "take care", "respectfully",
        "yours truly", "cordially", "with gratitude"]
    private static let closers: [[String]] = (thanksClosers + otherClosers).map { $0.split(separator: " ").map(String.init) }
        .sorted { $0.count > $1.count }
    /// Words before a closer that make it part of a sentence: "I wanted to say thanks", "no thanks", "we'll talk soon".
    private static let closerBlockedBefore: Set<String> = ["say", "said", "saying", "says", "give", "gave", "giving", "send", "sending", "sent",
        "a", "an", "the", "my", "our", "your", "his", "her", "their", "many", "big", "huge", "special", "no", "with", "and", "or", "extra",
        "all", "of", "for", "express", "owe", "deserve", "deserves", "get", "got", "i", "we", "you", "they", "he", "she", "it", "to", "can",
        "could", "will", "would", "should", "let's", "lets", "let’s", "i'll", "i’ll", "we'll", "we’ll", "gonna", "just", "so", "very", "really",
        "also", "must", "may", "might", "please", "us", "them", "him", "me", "is", "was", "be", "the", "at", "in", "on", "by", "very"]
    private static let questionStart = try! NSRegularExpression(pattern:
        "(?i)^(?:can|could|would|will|do|does|did|is|are|was|were|have|has|should|shall|may|what|when|where|why|who|how|which)\\b")

    /// Ends a run-on body ("…can you send it over") with "?" for a question, else ".". A list's last item stays as is.
    private static func closeSentence(_ body: String) -> String {
        guard let l = body.last, l.isLetter || l.isNumber || ")”’\"".contains(l) else { return body }
        let lastLine = body.components(separatedBy: "\n").last ?? body
        if listLine(lastLine) != nil { return body }
        let last = sentences(lastLine).last ?? lastLine
        return body + (matches(questionStart, last) ? "?" : ".")
    }

    private static func bare(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!;:"))
    }

    private static func signerMatches(_ name: String, _ signer: [String]) -> Bool {
        let n = name.lowercased()
        for s in signer {
            let full = s.lowercased().trimmingCharacters(in: .whitespaces)
            guard !full.isEmpty else { continue }
            if n == full { return true }
            let first = full.split(separator: " ").first.map(String.init) ?? full
            if !n.contains(" "), n.count >= 3, first.count >= 3, first.hasPrefix(n) || n.hasPrefix(first) { return true }
        }
        return false
    }

    /// "…let me know. Thanks, Tim" or "…let me know thanks Tim" → ("…let me know.", ["Thanks,", "Tim"]). Only at the
    /// very end, and only words you said. "Thanks for the update" is a sentence. "Thank you, Sarah" is thanks to the
    /// reader unless Sarah is you (`signer`) or the email greeted someone else.
    private static func splitSignOff(_ text: String, signer: [String], greetingName: String?) -> (body: String, lines: [String])? {
        let ns = text as NSString
        let tokens = try! NSRegularExpression(pattern: "\\S+").matches(in: text, range: NSRange(location: 0, length: ns.length)).suffix(9).map { $0.range }
        guard tokens.count >= 2 else { return nil }
        let words = tokens.map { ns.substring(with: $0) }
        for nameLen in 0...3 where nameLen < words.count {
            let nameWords = Array(words.suffix(nameLen))
            // Name words: letters only; only the last may end with "." or "!".
            let nameOK = nameWords.enumerated().allSatisfy { i, w in
                var core = w
                if i == nameWords.count - 1 { while let l = core.last, ".!".contains(l) { core.removeLast() } }
                if i == 0, titleWords.contains(core.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) { return true }
                return !core.isEmpty && core.allSatisfy { $0.isLetter || "'’-".contains($0) }
            }
            guard nameOK else { continue }
            let name = nameWords.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.!")) }.joined(separator: " ")
            let end = words.count - nameLen
            for closer in closers where closer.count <= end {
                let start = end - closer.count
                let cw = Array(words[start..<end])
                // Every closer word matches; only its last word may carry punctuation.
                guard zip(cw, closer).allSatisfy({ bare($0) == $1 }),
                      cw.dropLast().allSatisfy({ $0.lowercased() == bare($0) }) else { continue }
                let closerText = closer.joined(separator: " ")
                let isThanks = thanksClosers.contains(closerText)
                // The whole text is a sign-off: leave it, unless a greeting came before it ("Hi Sarah. Thanks, Tim").
                if start == 0 && greetingName == nil { return nil }
                let prev = start > 0 ? words[start - 1] : "."
                let gap = start > 0 ? ns.substring(with: NSRange(location: tokens[start - 1].location + tokens[start - 1].length,
                                                                 length: tokens[start].location - tokens[start - 1].location - tokens[start - 1].length)) : ""
                let standalone = gap.contains("\n") || (prev.last.map { ".!?;:,".contains($0) } ?? false)
                // The name: capitalized words, or your own name in any case.
                if nameLen > 0 {
                    let mine = signerMatches(name, signer)
                    let looksLikeName = nameWords.allSatisfy { isCapitalized($0) } && !nameWords.contains { notNames.contains(bare($0)) || groupWords.contains(bare($0)) }
                    guard mine || looksLikeName else { continue }
                    if isThanks && !mine {
                        // "Thank you, Sarah": thanks to the reader, unless the email greeted someone else.
                        guard let g = greetingName, !g.contains(name.lowercased()) else { continue }
                    }
                } else {
                    // A bare closer ends a sentence of its own ("…let me know. Thanks."), or runs on after one ("…know thanks").
                    if closerText == "best" && !standalone { continue }
                    if !standalone && !(isThanks || closerText == "cheers") { continue }
                }
                if !standalone {
                    guard !closerBlockedBefore.contains(bare(prev)), CleanupPrepass.wordCount(ns.substring(to: tokens[start].location)) >= 3 else { continue }
                }
                var body = ns.substring(to: tokens[start].location).trimmingCharacters(in: .whitespacesAndNewlines)
                while let l = body.last, ",;:—–-".contains(l) { body.removeLast(); body = body.trimmingCharacters(in: .whitespaces) }
                if start > 0 {
                    guard body.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
                    body = closeSentence(body)
                }
                var line = closerText
                line = line.prefix(1).uppercased() + line.dropFirst() + ","
                var lines = [line]
                if nameLen > 0 { lines.append(name.split(separator: " ").map { CleanupPrepass.capitalizeFirst(String($0)) }.joined(separator: " ")) }
                return (body, lines)
            }
        }
        return nil
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
