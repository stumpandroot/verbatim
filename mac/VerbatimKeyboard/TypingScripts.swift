import Foundation

// Typing help in other scripts (round 2, decided November 8, 2026): the Russian, Ukrainian, Greek, Arabic, and Hebrew
// letter rows, each following Apple's keyboard for that language; their long-press letters; Greek's accent key; which
// script a word is in; the word rules each script needs (Greek final sigma, Hebrew geresh and gershayim, Arabic and Greek
// punctuation); and which way a line runs, for the space bar's cursor drag. Foundation only (no UIKit), so
// mac/tools/test-typing-correction.sh and test-keyboard.sh compile and check it on Linux. Compiled into the keyboard and
// into the iPhone app (Settings › Keyboard › Languages and the self-test), with TypingHelp.swift.

// MARK: - Scripts

/// A writing system, from a letter's Unicode block. Marks, digits, and punctuation have none.
enum WritingScript: Equatable {
    case latin, cyrillic, greek, arabic, hebrew, other

    /// Arabic and Hebrew run right to left.
    var isRightToLeft: Bool { self == .arabic || self == .hebrew }

    /// The script of one letter; nil for anything that isn't a letter (a mark, a digit, punctuation, an apostrophe).
    static func of(_ s: Unicode.Scalar) -> WritingScript? {
        let p = s.properties
        guard p.isAlphabetic, p.generalCategory != .nonspacingMark, p.generalCategory != .spacingMark,
              s.value != 0x02BC else { return nil } // ʼ, Ukrainian's apostrophe, belongs to no script
        switch s.value {
        case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0x24F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xFB00...0xFB06:
            return .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF:
            return .greek
        case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x590...0x5FF, 0xFB1D...0xFB4F:
            return .hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        default:
            return .other
        }
    }

    /// A character's script, from its first letter (a letter with marks on it is one character).
    static func of(character c: Character) -> WritingScript? {
        c.unicodeScalars.lazy.compactMap(of).first
    }

    /// A word's script: its letters' one script, `.other` when they mix scripts, nil with no letters.
    static func of(word: String) -> WritingScript? {
        var found: WritingScript?
        for s in word.unicodeScalars {
            guard let w = of(s) else { continue }
            if found == nil { found = w } else if found != w { return .other }
        }
        return found
    }

    /// The script a language is written in, from its code ("ru_RU" → Cyrillic). `.other` when the keyboard doesn't know.
    static func of(language: String) -> WritingScript {
        let c = TypingLanguages.code(language)
        if TypingLanguages.latinScript.contains(c) { return .latin }
        switch c {
        case "ru", "uk", "be", "bg", "mk": return .cyrillic
        case "el": return .greek
        case "ar", "fa", "ur": return .arabic
        case "he", "yi": return .hebrew
        default: return .other
        }
    }
}

// MARK: - Word rules

enum TypingScripts {
    /// More marks that end a word and let it be corrected: Arabic's comma, semicolon, and question mark, the closing
    /// guillemet (Russian and Ukrainian quotes), and Greek's question mark and ano teleia.
    static let boundaries: Set<String> = ["\u{060C}", "\u{061B}", "\u{061F}", "\u{00BB}", "\u{037E}", "\u{0387}"]

    /// Hebrew's geresh and gershayim (׳ ״), which sit inside abbreviations and acronyms. They're part of the word, and a
    /// word with one is never corrected; at the end of a word they mark an abbreviation, like an apostrophe.
    static let innerMarks: Set<Character> = ["\u{05F3}", "\u{05F4}"]

    /// Hebrew's maqaf (־), its hyphen.
    static let maqaf: Character = "\u{05BE}"

    /// True when a word isn't in the language's script (an English word typed while Russian is on, or Russian while
    /// English is on): that language's spell checker would only make it worse, so it's left alone. A word mixing scripts
    /// is left alone too. Languages the keyboard doesn't know a script for leave every word to the checker.
    static func isForeign(_ word: String, language: String) -> Bool {
        let lang = WritingScript.of(language: language)
        guard lang != .other, let w = WritingScript.of(word: word) else { return false }
        return w != lang
    }

    /// Greek's final sigma: a word of two or more letters ending in σ ends in ς instead ("λογοσ" gives "λογος"), as the
    /// system keyboard writes it. Nil when there's nothing to change. Capitals (Σ) have no final form.
    static func finalSigma(_ word: String) -> String? {
        guard word.count >= 2, word.last == "σ", let prev = word.dropLast().last,
              WritingScript.of(character: prev) == .greek else { return nil }
        return String(word.dropLast()) + "ς"
    }

    /// Which way the paragraph at the cursor runs, from its first letter with a direction (as Unicode's bidirectional
    /// algorithm decides a paragraph's direction): Hebrew or Arabic is right to left, any other script left to right.
    /// With no letters yet, the keyboard's layout decides (`fallback`). The cursor drag uses it to move in visual order.
    static func paragraphIsRightToLeft(before: String?, after: String?, fallback: Bool) -> Bool {
        var para = ""
        if let before {
            if let nl = before.lastIndex(where: { $0.isNewline }) { para = String(before[before.index(after: nl)...]) } else { para = before }
        }
        if let after { para += after.prefix { !$0.isNewline } }
        for s in para.unicodeScalars {
            guard let w = WritingScript.of(s) else { continue }
            return w.isRightToLeft
        }
        return fallback
    }
}

// MARK: - Greek's accent key

/// Greek's accent key (΄, top left, as on Apple's Greek keyboard) waits for the next letter: ΄ then ο types ό. Hold it for
/// the diaeresis (¨: ϊ, ϋ) or both (΅: ΐ, ΰ). The key shows as held until the next key.
enum DeadKeys {
    static let tonos = "\u{0384}"
    static let dialytika = "\u{00A8}"
    static let dialytikaTonos = "\u{0385}"
    static let marks: Set<String> = [tonos, dialytika, dialytikaTonos]

    static func isDead(_ s: String) -> Bool { marks.contains(s) }

    /// What each mark makes of a vowel.
    static let table: [String: [String: String]] = [
        tonos: ["α": "ά", "ε": "έ", "η": "ή", "ι": "ί", "ο": "ό", "υ": "ύ", "ω": "ώ",
                "Α": "Ά", "Ε": "Έ", "Η": "Ή", "Ι": "Ί", "Ο": "Ό", "Υ": "Ύ", "Ω": "Ώ"],
        dialytika: ["ι": "ϊ", "υ": "ϋ", "Ι": "Ϊ", "Υ": "Ϋ"],
        dialytikaTonos: ["ι": "ΐ", "υ": "ΰ"],
    ]

    /// The vowel a mark makes, or nil when the mark doesn't go on it.
    static func compose(_ mark: String, _ next: String) -> String? { table[mark]?[next] }

    /// A letter's mark and plain vowel ("ό" → ΄ and ο), for typing it with the accent key.
    static func decompose(_ letter: String) -> (mark: String, base: String)? {
        for (mark, row) in table { if let base = row.first(where: { $0.value == letter })?.key { return (mark, base) } }
        return nil
    }

    /// What a key types with a mark waiting (`pending`), and what's waiting after. A mark waits; the same mark twice types
    /// it; another mark types the first and waits with the second; space types the mark alone; a vowel takes the mark;
    /// anything else types the mark and then itself.
    struct Result: Equatable {
        var insert: String
        var pending: String?
    }

    static func press(pending: String?, input: String) -> Result {
        if isDead(input) {
            guard let p = pending else { return Result(insert: "", pending: input) }
            return p == input ? Result(insert: input, pending: nil) : Result(insert: p, pending: input)
        }
        guard let p = pending else { return Result(insert: input, pending: nil) }
        if input == " " { return Result(insert: p, pending: nil) }
        if let c = compose(p, input) { return Result(insert: c, pending: nil) }
        return Result(insert: p + input, pending: nil)
    }

    /// What VoiceOver says for a mark's key.
    static func spokenName(_ s: String) -> String? {
        switch s {
        case tonos: return "Accent"
        case dialytika: return "Diaeresis"
        case dialytikaTonos: return "Accent and diaeresis"
        default: return nil
        }
    }
}

// MARK: - Layouts

/// The letter rows for the other scripts, in reading order: left to right, and right to left for Arabic and Hebrew (the
/// first letter is the rightmost key). `KeyLayout.letterRows` turns them into drawing order. Each follows Apple's keyboard
/// for the language.
enum ScriptLayouts {
    /// ЙЦУКЕН: ё and ъ are on long-press (е and ь).
    static let russian: [[String]] = [
        ["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х"],
        ["ф", "ы", "в", "а", "п", "р", "о", "л", "д", "ж", "э"],
        ["я", "ч", "с", "м", "и", "т", "ь", "б", "ю"],
    ]
    /// Ukrainian ЙЦУКЕН: і and є where Russian has ы and э; ї and ґ are on long-press (і and г).
    static let ukrainian: [[String]] = [
        ["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х"],
        ["ф", "і", "в", "а", "п", "р", "о", "л", "д", "ж", "є"],
        ["я", "ч", "с", "м", "и", "т", "ь", "б", "ю"],
    ]
    /// Greek: the accent key (΄) top left, then final sigma; tonos and diaeresis vowels are also on long-press.
    static let greek: [[String]] = [
        [DeadKeys.tonos, "ς", "ε", "ρ", "τ", "υ", "θ", "ι", "ο", "π"],
        ["α", "σ", "δ", "φ", "γ", "η", "ξ", "κ", "λ"],
        ["ζ", "χ", "ψ", "ω", "β", "ν", "μ"],
    ]
    /// Arabic, right to left (drawn ض ص ث … ج from the left): hamza forms on long-press (ا, ء, و, ي, ى). No capitals, so no
    /// shift key.
    static let arabic: [[String]] = [
        ["ج", "ح", "خ", "ه", "ع", "غ", "ف", "ق", "ث", "ص", "ض"],
        ["ة", "ك", "م", "ن", "ت", "ا", "ل", "ب", "ي", "س", "ش"],
        ["ى", "و", "ر", "ز", "د", "ذ", "ط", "ظ", "ء"],
    ]
    /// Hebrew, right to left (drawn ק ר א … פ from the left), with the final letters as keys. No capitals, so no shift
    /// key; Delete ends the top row, as on Apple's Hebrew keyboard.
    static let hebrew: [[String]] = [
        ["פ", "ם", "ן", "ו", "ט", "א", "ר", "ק"],
        ["ף", "ך", "ל", "ח", "י", "ע", "כ", "ג", "ד", "ש"],
        ["ץ", "ת", "צ", "מ", "נ", "ה", "ב", "ס", "ז"],
    ]

    /// Each language's long-press letters, as on Apple's keyboards. Hebrew has none.
    static let alternates: [String: [String: [String]]] = [
        "ru": ["е": ["ё"], "ь": ["ъ"]],
        "uk": ["і": ["ї"], "г": ["ґ"]],
        "el": ["α": ["ά"], "ε": ["έ"], "η": ["ή"], "ι": ["ί", "ϊ", "ΐ"], "ο": ["ό"], "υ": ["ύ", "ϋ", "ΰ"], "ω": ["ώ"],
               DeadKeys.tonos: [DeadKeys.dialytika, DeadKeys.dialytikaTonos]],
        "ar": ["ا": ["أ", "إ", "آ"], "ء": ["أ", "إ", "ؤ", "ئ"], "و": ["ؤ"], "ي": ["ئ"], "ى": ["ئ"]],
    ]

    /// Arabic's punctuation in the 123 layer: its own comma and question mark.
    static let arabicPunctuation = [".", "\u{060C}", "\u{061F}", "!", "'"]
}

// MARK: - Typing a word

/// One way to type a letter: its key, or a key held and a letter picked from its long-press row.
enum KeyTap: Equatable {
    case key(String)
    case hold(String, pick: String)
}

extension KeyLayout {
    /// The taps that type `word` (lowercase) on this layout: each letter's key, else a held key whose row has it, else
    /// Greek's accent key and then the vowel. Nil when a letter can't be typed here. For the self-test and Linux checks.
    func taps(toType word: String, language: String) -> [KeyTap]? {
        let keys = readingRows.flatMap { $0 }
        var out: [KeyTap] = []
        for ch in word {
            let s = String(ch)
            if keys.contains(s) { out.append(.key(s)); continue }
            if let base = keys.first(where: { AccentSets.alternates(for: $0, language: language).contains(s) }) {
                out.append(.hold(base, pick: s)); continue
            }
            if let d = DeadKeys.decompose(s), keys.contains(d.mark), keys.contains(d.base) {
                out += [.key(d.mark), .key(d.base)]; continue
            }
            return nil
        }
        return out
    }

    /// The text those taps type, with the accent key's rules (`DeadKeys.press`).
    static func replay(_ taps: [KeyTap]) -> String {
        var text = "", pending: String?
        for t in taps {
            let input: String
            switch t {
            case .key(let k): input = k
            case .hold(_, let pick): input = pick
            }
            let r = DeadKeys.press(pending: pending, input: input)
            text += r.insert
            pending = r.pending
        }
        return text + (pending ?? "")
    }
}
