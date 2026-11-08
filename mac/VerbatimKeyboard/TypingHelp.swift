import Foundation

// Typing help's settings and languages (approved mockup "Corrections, suggestions, and accents", November 7, 2026):
// Settings › Dictation and keyboard › Keyboard › Autocorrect, Suggestions, and Languages; which language and letter
// layout the keyboard types in; and the long-press alternates for each language. Foundation only (no UIKit), so
// mac/tools/test-typing-correction.sh compiles and checks it on Linux. Compiled into the keyboard, which reads it, and
// into the iPhone app, whose Settings writes it. The correction rules themselves are in TypingCorrection.swift.

// MARK: - Settings

/// Autocorrect and Suggestions, both on unless turned off. In the App Group (`KeyboardBridge.appGroup`): the app's
/// Settings writes them and the keyboard reads them each time it appears. Without Allow Full Access the keyboard can't
/// read the App Group, so both stay on.
struct TypingHelp: Equatable {
    var autocorrect = true
    var suggestions = true

    static let standard = TypingHelp()

    enum Key {
        static let autocorrect = "kb.typing.autocorrect"
        static let suggestions = "kb.typing.suggestions"
        /// [String]: the languages the keyboard can type in, from the keyboards added in the Settings app, written by
        /// the app (`TypingLanguages.keyboardLanguages`).
        static let languages = "kb.typing.languages"
        /// [String]: words from Verbose's Dictionary, which autocorrect leaves alone, written by the app.
        static let words = "kb.typing.words"
        /// String: the language last chosen in the keyboard's menu. In the keyboard's own defaults (no App Group), so it
        /// works without Full Access.
        static let picked = "kb.typing.picked"
    }

    static func read(_ d: UserDefaults?) -> TypingHelp {
        guard let d else { return .standard }
        return TypingHelp(autocorrect: d.object(forKey: Key.autocorrect) as? Bool ?? true,
                          suggestions: d.object(forKey: Key.suggestions) as? Bool ?? true)
    }

    /// The most Dictionary words the keyboard keeps (a small set, for the keyboard's memory limit).
    static let wordCap = 3_000

    /// The words autocorrect leaves alone, from Dictionary entries' preferred spellings: each word of each entry, without
    /// the punctuation around it, lowercased, once, at most `wordCap`.
    static func skipWords(_ phrases: [String], cap: Int = wordCap) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for p in phrases {
            for raw in p.split(whereSeparator: { $0.isWhitespace }) {
                let w = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
                guard w.count >= 2, seen.insert(w).inserted else { continue }
                out.append(w)
                if out.count >= cap { return out }
            }
        }
        return out
    }

    /// Writes the Dictionary's words for the keyboard, only when they changed.
    static func writeWords(_ phrases: [String], to d: UserDefaults?) {
        guard let d else { return }
        let words = skipWords(phrases)
        if d.stringArray(forKey: Key.words) == words { return }
        d.set(words, forKey: Key.words)
    }

    static func readWords(_ d: UserDefaults?) -> Set<String> {
        Set(d?.stringArray(forKey: Key.words) ?? [])
    }

    static func writeLanguages(_ languages: [String], to d: UserDefaults?) {
        guard let d, d.stringArray(forKey: Key.languages) != languages else { return }
        d.set(languages, forKey: Key.languages)
    }

    /// Nil when the app hasn't written the list (or without Full Access).
    static func readLanguages(_ d: UserDefaults?) -> [String]? {
        guard let list = d?.stringArray(forKey: Key.languages), !list.isEmpty else { return nil }
        return list
    }
}

// MARK: - Languages

/// The letter keys' layout for a language. QWERTY for English and most Latin-script languages; Spanish adds ñ; French
/// is AZERTY (Canadian French stays QWERTY, as on the system keyboard); German is QWERTZ with ü, ö, and ä. Russian and
/// Ukrainian are ЙЦУКЕН, and Greek, Arabic, and Hebrew follow Apple's keyboards; their rows are in TypingScripts.swift.
enum KeyLayout: String, Equatable, CaseIterable {
    case qwerty, spanish, azerty, qwertz, russian, ukrainian, greek, arabic, hebrew

    /// The three letter rows, top to bottom, in reading order: right to left for Arabic and Hebrew (the first letter is
    /// the rightmost key). The third row sits between shift and delete.
    var readingRows: [[String]] {
        switch self {
        case .qwerty:
            return [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                    ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
                    ["z", "x", "c", "v", "b", "n", "m"]]
        case .spanish:
            return [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                    ["a", "s", "d", "f", "g", "h", "j", "k", "l", "ñ"],
                    ["z", "x", "c", "v", "b", "n", "m"]]
        case .azerty:
            return [["a", "z", "e", "r", "t", "y", "u", "i", "o", "p"],
                    ["q", "s", "d", "f", "g", "h", "j", "k", "l", "m"],
                    ["w", "x", "c", "v", "b", "n", "'"]]
        case .qwertz:
            return [["q", "w", "e", "r", "t", "z", "u", "i", "o", "p", "ü"],
                    ["a", "s", "d", "f", "g", "h", "j", "k", "l", "ö", "ä"],
                    ["y", "x", "c", "v", "b", "n", "m"]]
        case .russian: return ScriptLayouts.russian
        case .ukrainian: return ScriptLayouts.ukrainian
        case .greek: return ScriptLayouts.greek
        case .arabic: return ScriptLayouts.arabic
        case .hebrew: return ScriptLayouts.hebrew
        }
    }

    /// The rows as drawn, left to right.
    var letterRows: [[String]] { isRightToLeft ? readingRows.map { Array($0.reversed()) } : readingRows }

    /// Arabic and Hebrew rows read right to left, as on Apple's keyboards. Delete, return, and the bottom row stay where
    /// they are on every layout.
    var isRightToLeft: Bool { self == .arabic || self == .hebrew }

    /// Arabic and Hebrew have no capitals, so their layouts have no shift key and shift stays off.
    var hasCase: Bool { !isRightToLeft }

    /// The letter row Delete ends: the third, or the first in Hebrew, as on Apple's Hebrew keyboard.
    var deleteRow: Int { self == .hebrew ? 0 : 2 }

    /// Letter keys across the widest row: 10, or 11 for QWERTZ, ЙЦУКЕН, and Arabic.
    var columns: Int { readingRows.map(\.count).max() ?? 10 }

    /// How Settings › Languages names the layout.
    var title: String {
        switch self {
        case .qwerty: return "QWERTY"
        case .spanish: return "QWERTY with ñ"
        case .azerty: return "AZERTY"
        case .qwertz: return "QWERTZ"
        case .russian: return "ЙЦУКЕН"
        case .ukrainian: return "ЙЦУКЕН with і and є"
        case .greek: return "Greek, with an accent key"
        case .arabic, .hebrew: return "Right to left"
        }
    }
}

enum TypingLanguages {
    /// Languages written in the Latin alphabet, which the keyboard's Latin layouts type when Apple's spell checker has
    /// them. Input-method languages (Chinese, Japanese, Korean, Hindi) and scripts without a layout here use the system
    /// keyboard through the globe key.
    static let latinScript: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "nb", "nn", "no", "fi", "pl", "tr", "id", "ms", "vi", "ro",
        "cs", "sk", "hu", "hr", "sl", "ca", "eu", "gl", "et", "lv", "lt", "sq", "af", "sw", "tl", "fil", "is", "ga", "cy",
        "mt", "az", "uz", "bs", "lb", "fo", "haw", "mi", "sm", "to",
    ]

    /// Languages in other scripts with a layout here (round 2): Russian and Ukrainian, Greek, Arabic, and Hebrew. They
    /// type whether or not the spell checker has them; corrections and suggestions come only where it does.
    static let otherScript: Set<String> = ["ru", "uk", "el", "ar", "he"]

    /// The spelling the spell checker uses: "en-US" becomes "en_US".
    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_")
    }

    /// "en_US" → "en"; "zh_Hans_CN" → "zh".
    static func code(_ s: String) -> String {
        String(normalize(s).split(separator: "_").first ?? "").lowercased()
    }

    /// The spell checker's language for a keyboard's or the system's language: the same identifier, else the same
    /// language (the bare code first, then the first region listed). Nil when the checker has none.
    static func match(_ s: String, available: [String]) -> String? {
        let n = normalize(s)
        guard !n.isEmpty else { return nil }
        if available.contains(n) { return n }
        let c = code(n)
        if let bare = available.first(where: { $0 == c }) { return bare }
        return available.first { code($0) == c }
    }

    /// The language identifier the keyboard types in for a keyboard's or the system's language: the spell checker's own
    /// for a Latin-script language it has; for Russian, Ukrainian, Greek, Arabic, and Hebrew, the checker's when it has
    /// one, else the identifier as given ("he-IL" → "he_IL"). Nil for a language no layout here types.
    static func resolve(_ s: String, available: [String]) -> String? {
        let c = code(s)
        if latinScript.contains(c) { return match(s, available: available) }
        guard otherScript.contains(c) else { return nil }
        return match(s, available: available) ?? normalize(s)
    }

    /// True when Apple's spell checker has the language, so autocorrect and the strip's words work in it.
    static func hasCorrections(_ language: String, available: [String]) -> Bool { available.contains(language) }

    /// Settings › Languages' line under a language: its layout, and "without corrections" when the checker lacks it.
    static func settingsLine(_ language: String, available: [String]) -> String {
        let title = layout(for: language).title
        return hasCorrections(language, available: available) ? title : title + ", without corrections"
    }

    /// The languages the keyboard types in, in the order of the keyboards (or the system's languages): each one a layout
    /// here can type (`resolve`), once.
    static func keyboardLanguages(_ candidates: [String], available: [String]) -> [String] {
        var out: [String] = []
        for c in candidates {
            guard let m = resolve(c, available: available), !out.contains(m) else { continue }
            out.append(m)
        }
        return out
    }

    /// The candidates the spell checker can't type in here (for Settings › Languages' note), by code, once.
    static func unsupported(_ candidates: [String], available: [String]) -> [String] {
        var out: [String] = []
        for c in candidates {
            let k = code(c)
            guard !k.isEmpty, !["emoji", "dictation", "mul", "und"].contains(k), !out.contains(k) else { continue }
            if resolve(c, available: available) != nil { continue }
            out.append(k)
        }
        return out
    }

    /// The language to type in now: the field's own language (`documentInputMode`, which some messaging apps keep per
    /// conversation) when it's one of yours, else the one you last chose in the keyboard's menu, else your first. With no
    /// list, the field's language or English.
    static func current(chosen: [String], document: String?, picked: String?, available: [String]) -> String {
        if let doc = document.flatMap({ resolve($0, available: available) }), chosen.isEmpty || chosen.contains(doc) {
            return doc
        }
        if let p = picked, chosen.contains(p) { return p }
        if let first = chosen.first { return first }
        return match("en_US", available: available) ?? "en_US"
    }

    /// The keyboard menu's Language row: the next of your languages, wrapping. Nil with fewer than two.
    static func next(after current: String, in chosen: [String]) -> String? {
        guard chosen.count > 1 else { return nil }
        guard let i = chosen.firstIndex(of: current) else { return chosen.first }
        return chosen[(i + 1) % chosen.count]
    }

    static func layout(for language: String) -> KeyLayout {
        let n = normalize(language)
        switch code(n) {
        case "es": return .spanish
        case "fr": return n.uppercased().hasSuffix("_CA") ? .qwerty : .azerty
        case "de": return .qwertz
        case "ru": return .russian
        case "uk": return .ukrainian
        case "el": return .greek
        case "ar": return .arabic
        case "he": return .hebrew
        default: return .qwerty
        }
    }
}

// MARK: - Long-press alternates

/// The row over a held letter key (about 0.4 s): the current language's letters first, then the rest, in the key popup's
/// style. Only the letters in the mockup have rows (a, e, i, o, u, n, c, s, y, z, l), plus g for Turkish ğ and d for
/// Vietnamese đ. Russian, Ukrainian, Greek, and Arabic letters' rows are in TypingScripts.swift (`ScriptLayouts`).
enum AccentSets {
    /// Every alternate for each letter, in the order the row lists them when the language has no preference.
    static let all: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā", "ą", "ă"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę", "ě"],
        "i": ["î", "ï", "í", "ī", "į", "ì", "ı"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ", "ő", "ơ"],
        "u": ["û", "ü", "ù", "ú", "ū", "ů", "ű", "ų", "ư"],
        "n": ["ñ", "ń", "ň"],
        "c": ["ç", "ć", "č"],
        "s": ["ß", "ś", "š", "ş", "ș"],
        "y": ["ÿ", "ý"],
        "z": ["ž", "ź", "ż"],
        "l": ["ł", "ľ", "ĺ"],
        "g": ["ğ"],
        "d": ["đ"],
    ]

    /// Each language's own letters, which lead the row in this order.
    static let preferred: [String: [String: [String]]] = [
        "es": ["a": ["á"], "e": ["é"], "i": ["í"], "o": ["ó"], "u": ["ú", "ü"], "n": ["ñ"]],
        "fr": ["a": ["à", "â", "æ"], "e": ["é", "è", "ê", "ë"], "i": ["î", "ï"], "o": ["ô", "œ"], "u": ["ù", "û", "ü"],
               "c": ["ç"], "y": ["ÿ"]],
        "de": ["a": ["ä"], "o": ["ö"], "u": ["ü"], "s": ["ß"]],
        "pt": ["a": ["ã", "á", "à", "â"], "e": ["é", "ê"], "i": ["í"], "o": ["õ", "ó", "ô"], "u": ["ú", "ü"], "c": ["ç"]],
        "it": ["a": ["à"], "e": ["è", "é"], "i": ["ì", "í"], "o": ["ò", "ó"], "u": ["ù", "ú"]],
        "nl": ["e": ["ë", "é", "è"], "i": ["ï"], "o": ["ö", "ó"], "u": ["ü"]],
        "sv": ["a": ["å", "ä"], "o": ["ö"], "e": ["é"]],
        "fi": ["a": ["ä", "å"], "o": ["ö"]],
        "da": ["a": ["å", "æ"], "o": ["ø"], "e": ["é"]],
        "nb": ["a": ["å", "æ"], "o": ["ø"], "e": ["é"]],
        "nn": ["a": ["å", "æ"], "o": ["ø"], "e": ["é"]],
        "no": ["a": ["å", "æ"], "o": ["ø"], "e": ["é"]],
        "pl": ["a": ["ą"], "c": ["ć"], "e": ["ę"], "l": ["ł"], "n": ["ń"], "o": ["ó"], "s": ["ś"], "z": ["ż", "ź"]],
        "tr": ["c": ["ç"], "g": ["ğ"], "i": ["ı"], "o": ["ö"], "s": ["ş"], "u": ["ü"]],
        "vi": ["a": ["ă", "â", "á", "à", "ã"], "d": ["đ"], "e": ["ê", "é", "è"], "o": ["ô", "ơ", "ó", "ò"], "u": ["ư", "ú", "ù"],
               "i": ["í", "ì"], "y": ["ý"]],
        "ro": ["a": ["ă", "â"], "i": ["î"], "s": ["ș"]],
        "cs": ["a": ["á"], "c": ["č"], "e": ["é", "ě"], "i": ["í"], "n": ["ň"], "o": ["ó"], "s": ["š"], "u": ["ú", "ů"],
               "y": ["ý"], "z": ["ž"]],
        "sk": ["a": ["á", "ä"], "c": ["č"], "e": ["é"], "i": ["í"], "l": ["ľ", "ĺ"], "n": ["ň"], "o": ["ó", "ô"], "s": ["š"],
               "u": ["ú"], "y": ["ý"], "z": ["ž"]],
        "hu": ["a": ["á"], "e": ["é"], "i": ["í"], "o": ["ó", "ö", "ő"], "u": ["ú", "ü", "ű"]],
        "ca": ["a": ["à"], "c": ["ç"], "e": ["è", "é"], "i": ["í", "ï"], "l": ["ŀ"], "o": ["ò", "ó"], "u": ["ú", "ü"]],
    ]

    /// Letters that only appear in some languages' rows: g and d have a row only where the language uses them.
    static let languageOnly: Set<String> = ["g", "d"]

    /// The alternates for a held key, lowercase: the language's own first, then the rest. Empty for keys without a row
    /// (and for g and d outside Turkish and Vietnamese). `language` is a spell checker identifier ("fr_FR") or a code.
    static func alternates(for base: String, language: String) -> [String] {
        let key = base.lowercased()
        let lang = TypingLanguages.code(language)
        let mine = preferred[lang]?[key] ?? ScriptLayouts.alternates[lang]?[key] ?? []
        if languageOnly.contains(key) { return mine }
        guard let rest = all[key] else { return mine }
        var out = mine
        for a in rest where !out.contains(a) { out.append(a) }
        return out
    }

    /// The same row for a capital (shift or caps lock on). A letter with no single capital (ß) is left out, and Turkish
    /// dotless ı becomes I. Letters and marks without case (Arabic's hamza forms, Greek's accent marks) stay as they are.
    static func capitals(_ row: [String]) -> [String] {
        row.compactMap { a in
            let up = a.uppercased()
            if up == a { return a.contains(where: \.isCased) ? nil : a }
            return up.count == 1 ? up : nil
        }
    }
}
