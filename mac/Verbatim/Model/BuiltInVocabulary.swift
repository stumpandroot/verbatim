import Foundation

/// One term from the built-in modern vocabulary (Resources/ModernVocabulary.json): its exact spelling and the ways
/// speech engines tend to write it instead.
struct BuiltInTerm: Codable, Identifiable, Hashable {
    let term: String
    let category: String
    /// Replaced wherever they appear, in any case ("chat gpt" → "ChatGPT").
    var heard: [String]? = nil
    /// Replaced only when written exactly so ("Linked In"), because another case is ordinary English.
    var exact: [String]? = nil
    /// Also ordinary English ("zoom", "slack", "notion"): replaced only next to a context word ("zoom call",
    /// "on slack", "notion page") or when the engine already capitalized it in the middle of a sentence. A form
    /// listed with a capital ("Kiev", "I phone") changes only next to a context word.
    var context: [String]? = nil
    /// Context words for this term, on top of the shared ones.
    var after: [String]? = nil
    /// false keeps the term out of recognition boosting.
    var boost: Bool? = nil
    /// true: a `context` form changes only right before one of this term's own `after` words, never for the shared
    /// context words or a capital ("pro bonus work", not "pro bonus account").
    var strict: Bool? = nil

    var id: String { term }
    /// The specialty field the term belongs to (from its category), or nil for a general term that's always on.
    var field: VocabularyField? { VocabularyField(category: category) }
    /// Every way the term is listed as heard, for search and display.
    var forms: [String] { (heard ?? []) + (exact ?? []) + (context ?? []) }
    /// Only fixed next to a context word.
    var isContextual: Bool { (heard ?? []).isEmpty && (exact ?? []).isEmpty }
    /// Worth boosting: not an ordinary word, and long enough that the keyword spotter can't confuse it with others.
    var boostable: Bool { (boost ?? true) && term.count >= 4 && !isContextual }
}

/// A specialty field (Settings › Dictation › Specialty words): the terms of its categories run only while it's on.
/// Film production and business are on unless you turn them off; medical, legal, and Bible and faith start off. Terms
/// in the other categories (apps, AI, devices, names, places, and the rest) are general: they run whenever the
/// built-in vocabulary is on, and no switch lists them. The choices sync between your Mac and iPhone with your name
/// and About me (Store.SyncedProfile).
enum VocabularyField: String, CaseIterable, Identifiable {
    case film, business, medical, legal, faith

    var id: String { rawValue }

    /// The switch's title in Settings.
    var title: String {
        switch self {
        case .film: return "Film production"
        case .business: return "Business and marketing"
        case .medical: return "Medical"
        case .legal: return "Legal"
        case .faith: return "Bible and faith"
        }
    }

    /// A few of the field's own terms, for the line under the switch.
    var examples: String {
        switch self {
        case .film: return "ARRI, Blackmagic RAW, S-Log3, and more"
        case .business: return "ROAS, EBITDA, Shopify POS, and more"
        case .medical: return "Ozempic, metformin, COPD, and more"
        case .legal: return "Prima facie, voir dire, habeas corpus, and more"
        case .faith: return "Habakkuk, Philippians, exegesis, and more"
        }
    }

    /// The categories in ModernVocabulary.json whose terms are in this field.
    var categories: Set<String> {
        switch self {
        case .film: return ["Film and video"]
        case .business: return ["Business"]
        case .medical: return ["Medical"]
        case .legal: return ["Legal"]
        case .faith: return ["Bible and faith"]
        }
    }

    var isOnByDefault: Bool { self == .film || self == .business }

    /// The line under the Specialty words group, on the Mac and iPhone.
    static let groupNote = "Fix how dictation spells the words of a field you work in."
    /// Shown under Medical while it's on: a word patch fixes spelling, never one drug heard as another.
    static let medicalNote = "Verbose fixes how drug names are spelled. It can't tell when one drug was heard as another, such as Humira heard as Humalog. Check medication names before you rely on them."

    /// The UserDefaults key for the field's switch (a Bool; missing means the default).
    var key: String {
        switch self {
        case .film: return "vocabulary.field.film"
        case .business: return "vocabulary.field.business"
        case .medical: return "vocabulary.field.medical"
        case .legal: return "vocabulary.field.legal"
        case .faith: return "vocabulary.field.faith"
        }
    }

    /// The field a category belongs to; nil for a general category.
    init?(category: String) {
        guard let f = Self.allCases.first(where: { $0.categories.contains(category) }) else { return nil }
        self = f
    }

    /// Whether the field is on in `defaults`.
    func isOn(in defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: key) as? Bool ?? isOnByDefault }

    /// The fields that are off in `defaults`.
    static func off(in defaults: UserDefaults = .standard) -> Set<VocabularyField> { Set(allCases.filter { !$0.isOn(in: defaults) }) }

    /// The switches you've set in `defaults` (fields you never touched are left out), by raw value, for syncing.
    static func chosen(in defaults: UserDefaults = .standard) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for f in allCases { if let v = defaults.object(forKey: f.key) as? Bool { out[f.rawValue] = v } }
        return out
    }

    /// Sets the switches in `chosen` (by raw value) that differ in `defaults`; unknown fields are ignored.
    static func apply(_ chosen: [String: Bool], to defaults: UserDefaults = .standard) {
        for (raw, v) in chosen {
            guard let f = VocabularyField(rawValue: raw), defaults.object(forKey: f.key) as? Bool != v else { continue }
            defaults.set(v, forKey: f.key)
        }
    }
}

/// Modern words Verbatim spells right without any setup: apps, AI, devices, platforms, brands, and internet terms.
///
/// It runs after your own Dictionary, as whole words, and never inside links, email addresses, file paths, or code.
/// Your Dictionary wins: a term you spell your own way, or a "heard as" form you already listed, is left alone.
/// Words that are also ordinary English ("zoom in", "a notion of", "cut some slack") change only next to a
/// context word, so everyday sentences stay as you said them.
enum BuiltInVocabulary {
    static let enabledKey = "vocabulary.builtIn"
    /// Term IDs you turned off, one per line (a plain string, so SwiftUI's @AppStorage can read it too).
    static let disabledKey = "vocabulary.builtIn.disabled"
    /// Built-in terms handed to the recognition booster after your Dictionary's words (BoostVocabulary caps the total).
    static let boostBudget = 25

    private struct File: Codable { var version: Int; var terms: [BuiltInTerm] }

    static let terms: [BuiltInTerm] = load(Bundle.main.url(forResource: "ModernVocabulary", withExtension: "json"))

    static func load(_ url: URL?) -> [BuiltInTerm] {
        guard let url, let data = try? Data(contentsOf: url) else { Log.note("built-in vocabulary: file missing"); return [] }
        do { return try JSONDecoder().decode(File.self, from: data).terms }
        catch { Log.note("built-in vocabulary: unreadable (\(error))"); return [] }
    }

    // MARK: Settings

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func disabled(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    static var disabledIDs: Set<String> {
        get { disabled(UserDefaults.standard.string(forKey: disabledKey) ?? "") }
        set { UserDefaults.standard.set(newValue.sorted().joined(separator: "\n"), forKey: disabledKey) }
    }

    /// `raw` with `id` turned on or off.
    static func setting(_ id: String, on: Bool, in raw: String) -> String {
        var set = disabled(raw)
        if on { set.remove(id) } else { set.insert(id) }
        return set.sorted().joined(separator: "\n")
    }

    /// The terms in use: none when the switch is off, never the ones you turned off, and none from a specialty field
    /// that's off.
    static var activeTerms: [BuiltInTerm] {
        active(terms, on: isOn, disabled: disabledIDs, fieldsOff: VocabularyField.off())
    }

    /// `terms` filtered by the switches (a pure function, so the Linux tests can check it).
    static func active(_ terms: [BuiltInTerm], on: Bool, disabled: Set<String>, fieldsOff: Set<VocabularyField>) -> [BuiltInTerm] {
        guard on else { return [] }
        if disabled.isEmpty && fieldsOff.isEmpty { return terms }
        return terms.filter { t in
            !disabled.contains(t.id) && !(t.field.map(fieldsOff.contains) ?? false)
        }
    }

    /// Whether anything can be fixed (callers skip the pass when neither this nor the Dictionary has words).
    static var isActive: Bool { isOn && !terms.isEmpty }

    /// Whether `word` is a built-in term (any case).
    static func contains(_ word: String) -> Bool { termKeys.contains(word.lowercased()) }
    private static let termKeys: Set<String> = Set(terms.map { $0.term.lowercased() })

    // MARK: Boosting

    /// Built-in terms for the recognition booster, as Dictionary entries dated before any of yours, so
    /// `BoostVocabulary.rank` puts your words first and drops these first when the cap is reached. Contextual
    /// terms ("Zoom", "Slack") and short ones ("API", "UI") stay out: boosting them swaps ordinary words.
    static func boostEntries(excluding user: [DictionaryEntry]) -> [DictionaryEntry] {
        let taken = Set(user.map { $0.preferred.lowercased() })
        let picked = activeTerms.filter { $0.boostable && !taken.contains($0.term.lowercased()) }.prefix(boostBudget)
        return picked.enumerated().map { i, t in
            DictionaryEntry(preferred: t.term, heardAs: (t.heard ?? []) + (t.exact ?? []), learnedFrom: "Built-in vocabulary",
                            createdAt: Date.distantPast.addingTimeInterval(Double(boostBudget - i)))
        }
    }

    // MARK: Rules

    enum Kind { case always, exact, context }

    struct Rule {
        let term: String
        let form: String
        let kind: Kind
        let re: NSRegularExpression
        let after: Set<String>
        /// Only `after` counts as context (BuiltInTerm.strict).
        var strict = false
        /// The form's first word, lowercased: a passage without it can't match.
        let key: String
        let order: Int
    }

    /// Words before a contextual term that mark it as the app ("on slack", "via zoom", "open notion").
    static let beforeWords: Set<String> = ["on", "via", "using", "open", "opened", "opening", "into"]
    /// Words after a contextual term that mark it as the app ("zoom call", "slack channel", "notion page").
    static let afterWords: Set<String> = [
        "call", "calls", "meeting", "meetings", "link", "links", "channel", "channels", "workspace", "workspaces",
        "account", "accounts", "page", "pages", "doc", "docs", "database", "app", "apps", "invite", "invites",
        "message", "messages", "thread", "threads", "profile", "integration", "integrations", "plugin", "plugins",
        "extension", "login", "subscription", "dashboard", "api", "bot", "server", "servers", "webinar", "template",
        "templates", "notification", "notifications",
    ]

    /// Whole-word pattern: not inside another word, a handle, a hashtag, a path, or a dotted name ("github.com").
    static func pattern(_ form: String) -> String {
        let parts = form.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        return "(?<![\\p{L}\\p{N}_@#/.\\-])" + parts.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}_@/]|[.\\-][\\p{L}\\p{N}])"
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func rules(for terms: [BuiltInTerm]) -> [Rule] {
        var list: [(term: String, form: String, kind: Kind, after: Set<String>, strict: Bool)] = []
        for t in terms {
            let after = Set((t.after ?? []).map { $0.lowercased() })
            let strict = t.strict ?? false
            for f in t.heard ?? [] { list.append((t.term, f, .always, after, strict)) }
            for f in t.exact ?? [] { list.append((t.term, f, .exact, after, strict)) }
            for f in t.context ?? [] { list.append((t.term, f, .context, after, strict)) }
        }
        // Longest forms first, so "macbook pro" is fixed as a whole before "macbook".
        let sorted = list.enumerated().sorted { a, b in
            a.element.form.count != b.element.form.count ? a.element.form.count > b.element.form.count : a.offset < b.offset
        }
        var out: [Rule] = []
        for (i, r) in sorted.map({ $0.element }).enumerated() {
            guard let key = words(r.form).first,
                  let re = try? NSRegularExpression(pattern: pattern(r.form), options: r.kind == .exact ? [] : [.caseInsensitive]) else { continue }
            out.append(Rule(term: r.term, form: r.form, kind: r.kind, re: re, after: r.after, strict: r.strict, key: key, order: i))
        }
        return out
    }

    /// Compiled once; NSRegularExpression is safe to share across threads.
    private static let allRules: [Rule] = rules(for: terms)

    // MARK: Applying

    /// Fixes built-in terms in `segments`, after your Dictionary has run, and records each change so it shows on the
    /// transcript and can be undone. `user` is your whole Dictionary: its words and "heard as" forms are left alone.
    static func apply(to segments: inout [Segment], respecting user: [DictionaryEntry]) -> [Correction] {
        var out: [Correction] = []
        apply(to: &segments, respecting: user, into: &out)
        return out
    }

    /// The same, recording into `corrections` (and moving the spans already there when it changes their passage).
    static func apply(to segments: inout [Segment], respecting user: [DictionaryEntry], into corrections: inout [Correction]) {
        let active = activeTerms
        guard !active.isEmpty else { return }
        let on = Set(active.map(\.id))
        apply(to: &segments, rules: allRules.filter { on.contains($0.term) }, respecting: user, into: &corrections)
    }

    /// The pass itself, with the rules given (the self-test passes its own).
    static func apply(to segments: inout [Segment], rules: [Rule], respecting user: [DictionaryEntry]) -> [Correction] {
        var out: [Correction] = []
        apply(to: &segments, rules: rules, respecting: user, into: &out)
        return out
    }

    static func apply(to segments: inout [Segment], rules: [Rule], respecting user: [DictionaryEntry], into out: inout [Correction]) {
        var userTerms = Set<String>(), userForms = Set<String>()
        for e in user {
            userTerms.insert(e.preferred.lowercased())
            userForms.insert(e.preferred.lowercased())
            for h in e.heardAs { userForms.insert(h.lowercased()) }
        }
        let usable = rules.filter { !userTerms.contains($0.term.lowercased()) && !userForms.contains($0.form.lowercased()) }
        guard !usable.isEmpty else { return }
        let byKey = Dictionary(grouping: usable, by: \.key)
        for i in segments.indices {
            var candidates = Set(words(segments[i].text)).flatMap { byKey[$0] ?? [] }
            guard !candidates.isEmpty else { continue }
            candidates.sort { $0.order < $1.order }
            for r in candidates {
                let text = segments[i].text
                let ranges = allowed(r, in: text)
                guard let first = ranges.first else { continue }
                // Recorded with where each fix went, so Undo restores exactly those words.
                CorrectionEdits.apply(ranges, in: &segments, at: i, to: r.term, label: (text as NSString).substring(with: first),
                                      byDictionary: true, corrections: &out)
            }
        }
    }

    /// Plain text through the same pass (self-tests and previews).
    static func fix(_ text: String, rules: [Rule], respecting user: [DictionaryEntry] = []) -> String {
        var segs = [Segment(start: 0, end: 1, text: text)]
        _ = apply(to: &segs, rules: rules, respecting: user)
        return segs[0].text
    }

    /// `text` with every allowed match of `r` replaced, and the first form that was replaced; nil when nothing changed.
    static func replace(_ r: Rule, in text: String) -> (text: String, from: String)? {
        let ranges = allowed(r, in: text)
        guard let first = ranges.first else { return nil }
        let ns = text as NSString
        let out = NSMutableString(string: text)
        for m in ranges.reversed() { out.replaceCharacters(in: m, with: r.term) }
        return (out as String, ns.substring(with: first))
    }

    /// The matches of `r` in `text` that may change, in order: not already the term, not in a link, address, or
    /// code, and (for a contextual form) with its context.
    static func allowed(_ r: Rule, in text: String) -> [NSRange] {
        let ns = text as NSString
        let matches = r.re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        let guarded = protectedRanges(text)
        return matches.map(\.range).filter { m in
            if ns.substring(with: m) == r.term { return false }
            if guarded.contains(where: { NSIntersectionRange($0, m).length > 0 }) { return false }
            if r.kind == .context, !contextAllows(ns, m, extra: r.after, capitalCounts: r.form.first?.isUppercase != true, shared: !r.strict) { return false }
            return true
        }
    }

    /// A contextual form changes only when the engine capitalized it mid-sentence, or a context word sits right
    /// before or after it. A form listed with a capital ("I phone", "Kiev", "Columbia") is a name or a capital
    /// that's always written so, where a capital says nothing (`capitalCounts` false): only a context word counts.
    /// A strict term (`shared` false) counts only its own `extra` words after the form.
    static func contextAllows(_ ns: NSString, _ range: NSRange, extra: Set<String>, capitalCounts: Bool = true, shared: Bool = true) -> Bool {
        if !shared {
            guard let w = wordAfter(ns.substring(from: NSMaxRange(range))) else { return false }
            return extra.contains(w)
        }
        let found = ns.substring(with: range)
        if capitalCounts, found.first?.isUppercase == true, !isSentenceStart(ns, at: range.location) { return true }
        if let w = wordBefore(ns.substring(to: range.location)), beforeWords.contains(w) { return true }
        if let w = wordAfter(ns.substring(from: NSMaxRange(range))), afterWords.contains(w) || extra.contains(w) { return true }
        return false
    }

    static func isSentenceStart(_ ns: NSString, at location: Int) -> Bool {
        let skip: Set<UInt16> = Set(" \t\"'“‘([".utf16)
        let ends: Set<UInt16> = Set(".!?…:\n".utf16)
        var j = location - 1
        while j >= 0, skip.contains(ns.character(at: j)) { j -= 1 }
        return j < 0 || ends.contains(ns.character(at: j))
    }

    /// The word right before, when only spaces separate it (punctuation ends the context).
    static func wordBefore(_ s: String) -> String? {
        guard let last = s.last, last == " " || last == "\t" else { return nil }
        let t = s.reversed().drop(while: { $0 == " " || $0 == "\t" })
        let w = t.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" })
        return w.isEmpty ? nil : String(w.reversed()).lowercased()
    }

    /// The word right after, when only spaces separate it.
    static func wordAfter(_ s: String) -> String? {
        guard let first = s.first, first == " " || first == "\t" else { return nil }
        let w = s.drop(while: { $0 == " " || $0 == "\t" }).prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" })
        return w.isEmpty ? nil : String(w).lowercased()
    }

    /// Links, email addresses, domains, paths, and code, which are never changed.
    private static let guards: [NSRegularExpression] = [
        "(?i)\\b(?:https?|ftp)://\\S+",
        "(?i)\\bwww\\.\\S+",
        "\\S+@\\S+\\.\\S+",
        "(?i)\\b[\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)*\\.(?:com|org|net|io|ai|app|dev|co|me|gg|tv|ly|so|xyz|us|uk|ca|edu|gov|fm|to|sh|new|page|site|link)\\b(?:/\\S*)?",
        "`[^`\\n]*`",
        "(?<!\\S)[~.]{0,2}/\\S+",
        "\\S*(?:[={}<>\\\\]|::|\\(\\))\\S*",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func protectedRanges(_ text: String) -> [NSRange] {
        // Most passages have none of these characters.
        guard text.contains(where: { "./@`=<>{}\\:(".contains($0) }) else { return [] }
        let all = NSRange(location: 0, length: (text as NSString).length)
        return guards.flatMap { $0.matches(in: text, range: all).map(\.range) }
    }
}
