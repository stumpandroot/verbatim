import Foundation

// Typing help's pure rules (VerbatimKeyboard/TypingCorrection.swift and TypingHelp.swift): fields, the word at the cursor,
// words left alone, corrections, text replacements, putting a correction back, the suggestion strip, languages and
// layouts, long-press letters, the long-press row, and the cursor drag. Not part of any app target; run
// mac/tools/test-typing-correction.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// MARK: Fields

let plain = TypingFieldPolicy(kind: .standard)
check("a plain field corrects, suggests, and expands", plain.corrects && plain.suggests && plain.expandsReplacements)
let noAuto = TypingFieldPolicy(kind: .standard, autocorrection: .no)
check("autocorrection off: no corrections, no strip, no replacements", !noAuto.corrects && !noAuto.suggests && !noAuto.expandsReplacements)
let noSpell = TypingFieldPolicy(kind: .standard, spellChecking: .no)
check("spell checking off: no corrections, the strip still shows", !noSpell.corrects && noSpell.suggests)
check("autocorrection yes behaves like default", TypingFieldPolicy(kind: .standard, autocorrection: .yes).corrects)
check("email, link, and number fields get none",
      [FieldKind.email, .url, .numberPad, .decimalPad, .numbersAndPunctuation].allSatisfy { k in
          let p = TypingFieldPolicy(kind: k); return !p.corrects && !p.suggests && !p.expandsReplacements })
check("username, code, and phone content types get none",
      ["username", "oneTimeCode", "telephoneNumber", "emailAddress", "URL", "postalCode"].allSatisfy { t in
          let p = TypingFieldPolicy(kind: .standard, contentType: t); return !p.corrects && !p.suggests })
check("a name or message content type still corrects", TypingFieldPolicy(kind: .standard, contentType: "givenName").corrects)

// MARK: The word at the cursor

func w(_ s: String?) -> WordAtCursor { WordAtCursor.before(s) }
check("word: the last word", w("I think teh") == WordAtCursor(word: "teh", token: "teh"))
check("word: nothing after a space", w("I think ") == .empty)
check("word: nothing in an empty or unknown field", w("") == .empty && w(nil) == .empty)
check("word: a newline ends it", w("Hi\nteh").word == "teh")
check("word: keeps an inner apostrophe", w("I dont'").word == "" && w("I don't").word == "don't" && w("I don\u{2019}t").word == "don\u{2019}t")
check("word: an opening quote isn't part of it", w("He said \"teh").word == "teh" && w("He said \"teh").token == "\"teh")
check("word: a leading apostrophe isn't part of it", w("'teh").word == "teh")
check("word: after punctuation inside the run", w("example.com").word == "com" && w("example.com").token == "example.com")
check("word: keeps accents", w("Nos vemos mañana").word == "mañana")
check("word: keeps a combining mark", w("cafe\u{301}").word == "cafe\u{301}")
check("word: numbers are in it", w("abc123").word == "abc123")
check("word: a hyphenated word's last part", w("well-knwon") == WordAtCursor(word: "knwon", token: "well-knwon"))

// MARK: Words left alone

let none = Set<String>()
func alone(_ s: String, _ skip: Set<String> = none) -> Bool { TypingCorrection.leavesAlone(w(s), skip: skip) }
check("alone: one letter", alone("a"))
check("alone: a number in it", alone("abc123") && alone("3rd"))
check("alone: a capital inside", alone("iPhone") && alone("McDonld") && alone("NASA"))
check("alone: a first capital is fine", !alone("Teh"))
check("alone: links", alone("www.exmaple") && alone("https://exmaple") && alone("example.cmo"))
check("alone: email addresses", alone("name@exmaple"))
check("alone: paths and tags", alone("a/teh") && alone("#teh") && alone("@teh"))
check("alone: Dictionary and lexicon words", alone("Verbsoe", ["verbsoe"]))
check("alone: a word you put back", alone("teh", ["teh"]))
check("alone: an opening quote or bracket is fine", !alone("(teh") && !alone("\u{201C}teh") && !alone("\u{00BF}teh"))
check("alone: a hyphenated word is fine", !alone("well-knwon"))
check("alone: plain words are checked", !alone("teh"))

// MARK: Corrections

func fix(_ s: String, misspelled: Bool = true, _ guesses: [String], skip: Set<String> = none, lang: String = "en_US") -> String? {
    TypingCorrection.correction(for: w(s), misspelled: misspelled, guesses: guesses, skip: skip, language: lang)
}
check("fix: teh → the", fix("I think teh", ["the", "ten", "tech"]) == "the")
check("fix: a correctly spelled word stays", fix("the", misspelled: false, ["then"]) == nil)
check("fix: keeps a first capital", fix("Teh", ["the"]) == "The")
check("fix: keeps a guess's own capital", fix("monday", ["Monday"]) == "Monday")
check("fix: skips a guess too far off", fix("xqzt", ["quiz"]) == nil)
check("fix: takes the checker's first guess when it's close", fix("recieve", ["receive", "deceive"]) == "receive")
check("fix: passes over a far guess to a close one", fix("wrld", ["weird", "world"]) == "world", "\(String(describing: fix("wrld", ["weird", "world"])))")
check("fix: a swap of two letters is one edit", TypingCorrection.distance("teh", "the") == 1)
check("fix: accents count once", fix("manana", ["mañana"], lang: "es_ES") == "mañana")
check("fix: an apostrophe", fix("dont", ["don't"]) == "don't")
check("fix: two words", fix("alot", ["a lot"]) == "a lot")
check("fix: never a word left alone", fix("teh", ["the"], skip: ["teh"]) == nil && fix("iPhnoe", ["iPhone"]) == nil)
check("fix: never in a link", fix("example.cmo", ["com"]) == nil)
check("fix: no guesses, no change", fix("zzkq", []) == nil)
check("fix: a guess equal to the word isn't a change", fix("Paris", ["Paris"]) == nil)
check("fix: English i → I", fix("so i", misspelled: false, []) == "I")
check("fix: English i'm → I'm", fix("i'm", misspelled: false, []) == "I'm" && fix("i\u{2019}ll", misspelled: false, []) == "I\u{2019}ll")
check("fix: i stays i in Spanish", fix("y i", misspelled: false, [], lang: "es_ES") == nil)
check("fix: i you put back stays", fix("i", misspelled: false, [], skip: ["i"]) == nil)
check("fix: limits grow with length", TypingCorrection.editLimit(4) == 1 && TypingCorrection.editLimit(5) == 2
      && TypingCorrection.editLimit(8) == 2 && TypingCorrection.editLimit(9) == 3)
check("fix: long words take three edits", fix("acommodatoin", ["accommodation"]) == "accommodation")
check("fix: matchCase leaves all lowercase alone", TypingCorrection.matchCase("the", to: "teh") == "the")
check("boundaries: space, return, and punctuation", [" ", "\n", ".", ",", "!", "?", ";", ":"].allSatisfy(TypingCorrection.isBoundary))
check("boundaries: letters and apostrophes aren't", !TypingCorrection.isBoundary("a") && !TypingCorrection.isBoundary("'") && !TypingCorrection.isBoundary("-"))

// MARK: Text replacements

let lex = TextReplacements.build([("omw", "On my way!"), ("Jane", "Jane"), ("Okafor", "Okafor"), ("my addr", "1 Main St"), (";sig", "Best, J")])
check("replacements: a shortcut expands", lex.shortcuts["omw"] == "On my way!")
check("replacements: a contact only adds words", lex.shortcuts["jane"] == nil && lex.words.contains("jane") && lex.words.contains("okafor"))
check("replacements: a shortcut with a space doesn't expand", lex.shortcuts["my addr"] == nil)
check("replacements: phrase words are left alone", lex.words.contains("way") && lex.words.contains("omw"))
check("replacements: matched without regard to case", TypingCorrection.replacement(for: w("OMW"), shortcuts: lex.shortcuts)! == ("OMW", "On my way!"))
check("replacements: the whole run first", TypingCorrection.replacement(for: w("ok ;sig"), shortcuts: lex.shortcuts)! == (";sig", "Best, J"))
check("replacements: after an opening quote", TypingCorrection.replacement(for: w("\"omw"), shortcuts: lex.shortcuts)! == ("omw", "On my way!"))
check("replacements: not inside a link", TypingCorrection.replacement(for: w("a.omw"), shortcuts: lex.shortcuts) == nil)
check("replacements: nothing to expand", TypingCorrection.replacement(for: w("hello"), shortcuts: lex.shortcuts) == nil
      && TypingCorrection.replacement(for: w("hi "), shortcuts: lex.shortcuts) == nil)

// MARK: Putting a correction back

let applied = AppliedCorrection(original: "teh", replacement: "the", trailing: " ")
check("revert: Delete puts the word back and removes the space", TypingCorrection.revert(applied, before: "I think the ", keepTrailing: false)! == (4, "teh"))
check("revert: a tap keeps the space", TypingCorrection.revert(applied, before: "I think the ", keepTrailing: true)! == (4, "teh "))
check("revert: after punctuation", TypingCorrection.revert(AppliedCorrection(original: "teh", replacement: "the", trailing: "."), before: "the", keepTrailing: false) == nil
      && TypingCorrection.revert(AppliedCorrection(original: "teh", replacement: "the", trailing: "."), before: "So the.", keepTrailing: false)! == (4, "teh"))
check("revert: not once the text changed", TypingCorrection.revert(applied, before: "I think the c", keepTrailing: false) == nil
      && TypingCorrection.revert(applied, before: nil, keepTrailing: false) == nil)
check("revert: a replacement goes back too", TypingCorrection.revert(AppliedCorrection(original: "omw", replacement: "On my way!", trailing: " "),
                                                                    before: "OK On my way! ", keepTrailing: false)! == (11, "omw"))

// MARK: The suggestion strip

func strip(_ word: String, correction: String? = nil, misspelled: Bool = false, guesses: [String] = [], completions: [String] = [],
           pending: AppliedCorrection? = nil) -> SuggestionStrip {
    SuggestionStrip.make(word: word, correction: correction, misspelled: misspelled, guesses: guesses, completions: completions, pending: pending)
}
let s1 = strip("teh", correction: "the", misspelled: true, guesses: ["the", "ten"], completions: [])
check("strip: typed in quotes, the correction in bold, then another", s1.slots[0] == .init(text: "teh", quoted: true, action: .keep("teh"))
      && s1.slots[1] == .init(text: "the", bold: true, action: .use("the")) && s1.slots[2] == .init(text: "ten", action: .use("ten")), "\(s1)")
let s2 = strip("caf", correction: "café", misspelled: true, guesses: ["café", "cafe"], completions: ["cafetería"])
check("strip: the mockup's café row", s2.slots.compactMap { $0?.text } == ["caf", "café", "cafe"], "\(s2)")
let s3 = strip("hel", completions: ["hello", "help", "helmet"])
check("strip: a correct word shows completions, none bold", s3.slots.compactMap { $0?.text } == ["hel", "hello", "help"]
      && s3.slots.compactMap { $0 }.allSatisfy { !$0.bold }, "\(s3)")
let s4 = strip("teh", misspelled: true, guesses: ["the", "ten"])
check("strip: autocorrect off shows guesses without bold", s4.slots[1]?.text == "the" && s4.slots[1]?.bold == false)
check("strip: completions follow your capital", strip("Hel", completions: ["hello"]).slots[1]?.text == "Hello")
check("strip: no duplicates", strip("teh", correction: "the", misspelled: true, guesses: ["the", "The", "ten"]).slots.compactMap { $0?.text } == ["teh", "the", "ten"])
check("strip: never the word itself", strip("the", completions: ["the", "then"]).slots.compactMap { $0?.text } == ["the", "then"])
check("strip: a case-only correction shows", strip("monday", correction: "Monday", misspelled: true, guesses: ["Monday"]).slots[1]?.text == "Monday")
check("strip: empty with no word", strip("").isEmpty)
check("strip: one letter shows nothing", strip("a", completions: ["and"]).isEmpty)
check("strip: one letter with a correction shows it", strip("i", correction: "I").slots[1]?.text == "I")
let s5 = strip("", pending: applied)
check("strip: after a correction, the quoted word to put back", s5.slots[0] == .init(text: "teh", quoted: true, action: .revert)
      && s5.slots[1] == nil && s5.slots[2] == nil)
check("strip: split around a centered button", s1.slots(.leading).count == 2 && s1.slots(.trailing) == [s1.slots[2]] && s1.slots(.all) == s1.slots)

// MARK: Settings

let suite = "typing-correction-tests-\(UUID().uuidString)"
let d = UserDefaults(suiteName: suite)!
check("settings: both on by default", TypingHelp.read(d) == TypingHelp(autocorrect: true, suggestions: true))
check("settings: both on without the App Group", TypingHelp.read(nil) == .standard)
d.set(false, forKey: TypingHelp.Key.autocorrect)
check("settings: autocorrect off is read", TypingHelp.read(d) == TypingHelp(autocorrect: false, suggestions: true))
d.set(false, forKey: TypingHelp.Key.suggestions)
check("settings: suggestions off is read", TypingHelp.read(d) == TypingHelp(autocorrect: false, suggestions: false))
check("settings: keys are the App Group's kb. keys", [TypingHelp.Key.autocorrect, TypingHelp.Key.suggestions, TypingHelp.Key.languages,
                                                     TypingHelp.Key.words, TypingHelp.Key.picked].allSatisfy { $0.hasPrefix("kb.typing.") })
check("words: each word, lowercased, once", TypingHelp.skipWords(["Verbose", "Stump & Root", "verbose", "a", "Okafor-Lee,"]) == ["verbose", "stump", "root", "okafor-lee"])
check("words: capped", TypingHelp.skipWords((0..<5000).map { "word\($0)" }).count == TypingHelp.wordCap)
TypingHelp.writeWords(["Verbose", "Brindle"], to: d)
check("words: round trip", TypingHelp.readWords(d) == ["verbose", "brindle"] && TypingHelp.readWords(nil).isEmpty)
check("languages: none until the app writes them", TypingHelp.readLanguages(d) == nil)
TypingHelp.writeLanguages(["en_US", "es_ES"], to: d)
check("languages: round trip", TypingHelp.readLanguages(d) == ["en_US", "es_ES"])
d.removePersistentDomain(forName: suite)

// MARK: Languages

let available = ["en_US", "en_GB", "es", "es_MX", "fr", "fr_CA", "de", "pt_BR", "pt_PT", "it", "ru", "sv", "tr", "vi"]
check("languages: normalize", TypingLanguages.normalize("en-US") == "en_US" && TypingLanguages.code("zh-Hans-CN") == "zh")
check("languages: exact match", TypingLanguages.match("en-GB", available: available) == "en_GB")
check("languages: the bare code", TypingLanguages.match("es-ES", available: available) == "es")
check("languages: the first region", TypingLanguages.match("pt", available: available) == "pt_BR")
check("languages: none for a language the checker lacks", TypingLanguages.match("ja-JP", available: available) == nil)
let kb = TypingLanguages.keyboardLanguages(["en-US", "emoji", "es-MX", "ja-JP", "en-US", "fr-FR"], available: available)
check("languages: your keyboards, in order, once, none without a layout", kb == ["en_US", "es_MX", "fr"], "\(kb)")
check("languages: what this keyboard can't type", TypingLanguages.unsupported(["en-US", "emoji", "ru-RU", "ja-JP", "dictation", "zh-Hans"], available: available) == ["ja", "zh"])
check("current: the field's language when it's yours", TypingLanguages.current(chosen: kb, document: "es-MX", picked: "en_US", available: available) == "es_MX")
check("current: not a field language you didn't add", TypingLanguages.current(chosen: kb, document: "de-DE", picked: nil, available: available) == "en_US")
check("current: the one you picked", TypingLanguages.current(chosen: kb, document: nil, picked: "fr", available: available) == "fr")
check("current: a pick you removed falls back to the first", TypingLanguages.current(chosen: kb, document: nil, picked: "it", available: available) == "en_US")
check("current: no list follows the field", TypingLanguages.current(chosen: [], document: "de-DE", picked: nil, available: available) == "de")
check("current: not a field in a script with no layout", TypingLanguages.current(chosen: [], document: "ja-JP", picked: nil, available: available) == "en_US")
check("current: English with nothing to go on", TypingLanguages.current(chosen: [], document: nil, picked: nil, available: available) == "en_US")
check("next: wraps", TypingLanguages.next(after: "fr", in: kb) == "en_US" && TypingLanguages.next(after: "en_US", in: kb) == "es_MX")
check("next: none with one language", TypingLanguages.next(after: "en_US", in: ["en_US"]) == nil)
check("next: an unknown current starts at the first", TypingLanguages.next(after: "it", in: kb) == "en_US")

// MARK: Layouts

check("layout: English, Italian, Portuguese, Swedish are QWERTY", ["en_US", "it", "pt_BR", "sv", "pl", "tr", "vi", "nl"].allSatisfy { TypingLanguages.layout(for: $0) == .qwerty })
check("layout: Spanish adds ñ", TypingLanguages.layout(for: "es_MX") == .spanish && KeyLayout.spanish.letterRows[1].last == "ñ")
check("layout: French is AZERTY", TypingLanguages.layout(for: "fr") == .azerty && TypingLanguages.layout(for: "fr_FR") == .azerty
      && KeyLayout.azerty.letterRows[0].prefix(2) == ["a", "z"] && KeyLayout.azerty.letterRows[1].last == "m")
check("layout: Canadian French stays QWERTY", TypingLanguages.layout(for: "fr_CA") == .qwerty)
check("layout: German is QWERTZ with ü ö ä", TypingLanguages.layout(for: "de") == .qwertz && KeyLayout.qwertz.letterRows[0][5] == "z"
      && KeyLayout.qwertz.letterRows[0].last == "ü" && KeyLayout.qwertz.letterRows[1].suffix(2) == ["ö", "ä"] && KeyLayout.qwertz.letterRows[2].first == "y")
check("layout: columns", KeyLayout.qwerty.columns == 10 && KeyLayout.spanish.columns == 10 && KeyLayout.qwertz.columns == 11)
check("layout: every layout has 26 or more letters and each once", KeyLayout.allCases.allSatisfy { l in
    let all = l.letterRows.flatMap { $0 }; return Set(all).count == all.count && all.filter { $0 != "'" }.count >= 26 })
check("layout: titles", KeyLayout.allCases.map(\.title) == ["QWERTY", "QWERTY with ñ", "AZERTY", "QWERTZ", "ЙЦУКЕН", "ЙЦУКЕН with і and є",
                                                         "Greek, with an accent key", "Right to left", "Right to left"])

let qwertyRows = TypingLayout.rows(layer: .letters, field: .standard, showsGlobe: true)
check("rows: QWERTY's middle row is centered between spacers", qwertyRows[1].first == .spacer(1) && qwertyRows[1].last == .spacer(1) && qwertyRows[1].count == 11)
let esRows = TypingLayout.rows(layer: .letters, field: .standard, showsGlobe: true, letters: .spanish)
check("rows: Spanish's middle row is full, ending in ñ", esRows[1].count == 10 && esRows[1].last == .char("ñ"))
let deRows = TypingLayout.rows(layer: .letters, field: .standard, showsGlobe: true, letters: .qwertz)
check("rows: QWERTZ's top two rows have eleven keys", deRows[0].count == 11 && deRows[1].count == 11)
check("rows: the number layers don't change with the language",
      TypingLayout.rows(layer: .numbers, field: .standard, showsGlobe: true, letters: .azerty) == TypingLayout.rows(layer: .numbers, field: .standard, showsGlobe: true))
let size = CGSize(width: 390, height: 234)
let m = KeyMetrics.forSize(size, rows: 4)
let de = TypingLayout.place(deRows, in: size, metrics: m, columns: KeyLayout.qwertz.columns)
let deTop = de.filter { $0.id.row == 0 }
check("rows: eleven keys fit the width", (deTop.last?.frame.maxX ?? 999) <= size.width - m.sideMargin + 0.5 && abs((deTop.first?.frame.minX ?? 0) - m.sideMargin) < 0.5,
      "\(deTop.map(\.frame))")
check("rows: eleven-column keys are narrower", TypingLayout.unit(width: 390, metrics: m, columns: 11) < TypingLayout.unit(width: 390, metrics: m))
let es = TypingLayout.place(esRows, in: size, metrics: m)
let esMid = es.filter { $0.id.row == 1 }
check("rows: Spanish's middle row spans the width", esMid.count == 10 && abs((esMid.last?.frame.maxX ?? 0) - (size.width - m.sideMargin)) < 0.5)

// MARK: Long-press letters

check("accents: e in English", AccentSets.alternates(for: "e", language: "en_US") == ["è", "é", "ê", "ë", "ē", "ė", "ę", "ě"])
check("accents: French e leads with é", AccentSets.alternates(for: "e", language: "fr").prefix(4) == ["é", "è", "ê", "ë"])
check("accents: Spanish n leads with ñ, u with ú ü", AccentSets.alternates(for: "n", language: "es_MX").first == "ñ"
      && AccentSets.alternates(for: "u", language: "es").prefix(2) == ["ú", "ü"])
check("accents: German a, o, u, s", AccentSets.alternates(for: "a", language: "de").first == "ä" && AccentSets.alternates(for: "o", language: "de").first == "ö"
      && AccentSets.alternates(for: "u", language: "de").first == "ü" && AccentSets.alternates(for: "s", language: "de").first == "ß")
check("accents: Portuguese a leads with ã", AccentSets.alternates(for: "a", language: "pt_BR").first == "ã")
check("accents: Polish l is ł, z is ż", AccentSets.alternates(for: "l", language: "pl").first == "ł" && AccentSets.alternates(for: "z", language: "pl").first == "ż")
check("accents: Swedish a is å then ä", AccentSets.alternates(for: "a", language: "sv").prefix(2) == ["å", "ä"])
check("accents: Danish o is ø", AccentSets.alternates(for: "o", language: "da").first == "ø")
check("accents: every mockup letter has a row", ["a", "e", "i", "o", "u", "n", "c", "s", "y", "z", "l"].allSatisfy { !AccentSets.alternates(for: $0, language: "en_US").isEmpty })
check("accents: keys without a row", AccentSets.alternates(for: "q", language: "en_US").isEmpty && AccentSets.alternates(for: "m", language: "fr").isEmpty)
check("accents: g and d only where the language uses them", AccentSets.alternates(for: "g", language: "en_US").isEmpty
      && AccentSets.alternates(for: "g", language: "tr") == ["ğ"] && AccentSets.alternates(for: "d", language: "vi") == ["đ"]
      && AccentSets.alternates(for: "d", language: "fr").isEmpty)
check("accents: no letter twice", ["a", "e", "i", "o", "u", "n", "c", "s", "y", "z", "l"].allSatisfy { k in
    ["en", "es", "fr", "de", "pt", "pl", "tr", "vi", "cs", "ca"].allSatisfy { l in let r = AccentSets.alternates(for: k, language: l); return Set(r).count == r.count } })
check("accents: the held key isn't in its own row", AccentSets.alternates(for: "e", language: "fr").contains("e") == false)
check("accents: a capital row", AccentSets.capitals(["é", "è", "ß", "ı"]) == ["É", "È", "I"])
check("accents: a held capital key works", AccentSets.alternates(for: "E", language: "en") == AccentSets.alternates(for: "e", language: "en"))

// MARK: The long-press row

let row = AccentRow.layout(keyMinX: 80, keyWidth: 33, count: 5, areaWidth: 390)
check("row: starts over the key", row.originX == 80 && row.slot == 33 && row.width == 165)
check("row: a finger picks by slot", row.index(at: 90) == 0 && row.index(at: 114) == 1 && row.index(at: 80 + 33 * 4 + 1) == 4)
check("row: clamped to the ends", row.index(at: 0) == 0 && row.index(at: 1000) == 4)
let edge = AccentRow.layout(keyMinX: 350, keyWidth: 33, count: 8, areaWidth: 390)
check("row: shifted left to stay on the keyboard", edge.originX + edge.width <= 387 + 0.001 && edge.originX >= 3)
let narrow = AccentRow.layout(keyMinX: 0, keyWidth: 20, count: 3, areaWidth: 390)
check("row: slots at least 28 pt, inside the margin", narrow.slot == 28 && narrow.originX == 3)
check("row: the hold is 0.4 s", AccentRow.holdDelay == 0.4)

// MARK: The cursor drag

var drag = CursorDrag(startX: 100)
check("drag: holds 0.3 s, 8 pt a character", CursorDrag.holdDelay == 0.3 && CursorDrag.step == 8)
check("drag: under a step doesn't move", drag.move(to: 107) == 0)
check("drag: a step moves one", drag.move(to: 108) == 1)
check("drag: only the change", drag.move(to: 125) == 2 && drag.moved == 3)
check("drag: back to the left", drag.move(to: 92) == -4 && drag.moved == -1)
check("drag: back to the start", drag.move(to: 100) == 1 && drag.moved == 0)
var fast = CursorDrag(startX: 0)
check("drag: a long move at once", fast.move(to: -80) == -10)

// MARK: Round 2: languages in other scripts

let avail2 = ["en_US", "es", "fr", "ru", "el"]
check("other scripts: Russian takes the checker's language", TypingLanguages.resolve("ru-RU", available: avail2) == "ru")
check("other scripts: Hebrew, Arabic, and Ukrainian type without the checker", TypingLanguages.resolve("he-IL", available: avail2) == "he_IL"
      && TypingLanguages.resolve("ar", available: avail2) == "ar" && TypingLanguages.resolve("uk-UA", available: avail2) == "uk_UA")
check("other scripts: Greek takes the checker's language", TypingLanguages.resolve("el-GR", available: avail2) == "el")
check("other scripts: still none for a script with no layout", TypingLanguages.resolve("ja-JP", available: avail2) == nil
      && TypingLanguages.resolve("hi", available: avail2) == nil && TypingLanguages.resolve("emoji", available: avail2) == nil)
check("other scripts: a Latin language still needs the checker", TypingLanguages.resolve("it", available: avail2) == nil)
let kb2 = TypingLanguages.keyboardLanguages(["en-US", "ru-RU", "he-IL", "emoji", "ar", "uk-UA", "el-GR", "ru"], available: avail2)
check("other scripts: your keyboards, in order, once", kb2 == ["en_US", "ru", "he_IL", "ar", "uk_UA", "el"], "\(kb2)")
check("other scripts: none of them is unsupported", TypingLanguages.unsupported(["ru-RU", "he-IL", "ar", "uk-UA", "el-GR"], available: avail2).isEmpty)
check("corrections: only where the checker has the language", TypingLanguages.hasCorrections("ru", available: avail2)
      && TypingLanguages.hasCorrections("el", available: avail2) && !TypingLanguages.hasCorrections("he_IL", available: avail2)
      && !TypingLanguages.hasCorrections("ar", available: avail2))
check("corrections: Settings says which type without them", TypingLanguages.settingsLine("ru", available: avail2) == "ЙЦУКЕН"
      && TypingLanguages.settingsLine("he_IL", available: avail2) == "Right to left, without corrections")
check("current: a field in Hebrew types Hebrew", TypingLanguages.current(chosen: ["en_US", "he_IL"], document: "he-IL", picked: nil, available: avail2) == "he_IL")
check("current: with no list, a Russian field types Russian", TypingLanguages.current(chosen: [], document: "ru-RU", picked: nil, available: avail2) == "ru")
check("current: a Greek field you didn't add stays out", TypingLanguages.current(chosen: ["en_US"], document: "el-GR", picked: nil, available: avail2) == "en_US")
check("layout: each language's layout", TypingLanguages.layout(for: "ru") == .russian && TypingLanguages.layout(for: "uk_UA") == .ukrainian
      && TypingLanguages.layout(for: "el") == .greek && TypingLanguages.layout(for: "ar_SA") == .arabic && TypingLanguages.layout(for: "he_IL") == .hebrew)

// MARK: Round 2: the layouts

check("Russian: ЙЦУКЕН, 11, 11, and 9", KeyLayout.russian.letterRows.map(\.count) == [11, 11, 9] && KeyLayout.russian.columns == 11
      && KeyLayout.russian.letterRows[0].prefix(6).joined() == "йцукен" && KeyLayout.russian.letterRows[1].joined() == "фывапролджэ"
      && KeyLayout.russian.letterRows[2].joined() == "ячсмитьбю")
check("Russian: ё and ъ are on long-press", !KeyLayout.russian.readingRows.joined().contains("ё") && !KeyLayout.russian.readingRows.joined().contains("ъ")
      && AccentSets.alternates(for: "е", language: "ru_RU") == ["ё"] && AccentSets.alternates(for: "ь", language: "ru") == ["ъ"])
check("Russian: capitals on long-press", AccentSets.capitals(AccentSets.alternates(for: "е", language: "ru")) == ["Ё"]
      && AccentSets.capitals(["ъ"]) == ["Ъ"])
check("Ukrainian: і and є in Russian's ы and э places", KeyLayout.ukrainian.letterRows[1][1] == "і" && KeyLayout.ukrainian.letterRows[1].last == "є"
      && !KeyLayout.ukrainian.readingRows.joined().contains("ы") && !KeyLayout.ukrainian.readingRows.joined().contains("э"))
check("Ukrainian: ї and ґ are on long-press", AccentSets.alternates(for: "і", language: "uk") == ["ї"] && AccentSets.alternates(for: "г", language: "uk_UA") == ["ґ"]
      && AccentSets.alternates(for: "г", language: "ru").isEmpty && AccentSets.alternates(for: "е", language: "uk").isEmpty)
check("Greek: the accent key, then final sigma, 10, 9, and 7", KeyLayout.greek.letterRows[0].prefix(2) == [DeadKeys.tonos, "ς"]
      && KeyLayout.greek.letterRows.map(\.count) == [10, 9, 7] && KeyLayout.greek.letterRows[1].joined() == "ασδφγηξκλ"
      && KeyLayout.greek.letterRows[2].joined() == "ζχψωβνμ" && KeyLayout.greek.columns == 10)
check("Greek: tonos and diaeresis on long-press", AccentSets.alternates(for: "ο", language: "el") == ["ό"]
      && AccentSets.alternates(for: "ι", language: "el_GR") == ["ί", "ϊ", "ΐ"] && AccentSets.alternates(for: "υ", language: "el") == ["ύ", "ϋ", "ΰ"]
      && AccentSets.alternates(for: DeadKeys.tonos, language: "el") == [DeadKeys.dialytika, DeadKeys.dialytikaTonos])
check("Greek: capital rows", AccentSets.capitals(["ά"]) == ["Ά"] && AccentSets.capitals(["ί", "ϊ"]) == ["Ί", "Ϊ"]
      && AccentSets.capitals([DeadKeys.dialytika]) == [DeadKeys.dialytika])
check("Arabic: right to left, drawn ض to ج from the left", KeyLayout.arabic.isRightToLeft && KeyLayout.arabic.letterRows[0].first == "ض"
      && KeyLayout.arabic.letterRows[0].last == "ج" && KeyLayout.arabic.readingRows[0].first == "ج"
      && KeyLayout.arabic.letterRows[1].joined() == "شسيبلاتنمكة" && KeyLayout.arabic.letterRows[2].joined() == "ءظطذدزروى")
check("Arabic: 11 columns, no capitals", KeyLayout.arabic.columns == 11 && !KeyLayout.arabic.hasCase && KeyLayout.arabic.deleteRow == 2)
check("Arabic: hamza forms on long-press", AccentSets.alternates(for: "ا", language: "ar") == ["أ", "إ", "آ"]
      && AccentSets.alternates(for: "و", language: "ar") == ["ؤ"] && AccentSets.capitals(["أ", "إ"]) == ["أ", "إ"])
check("Hebrew: right to left, drawn ק to פ from the left", KeyLayout.hebrew.isRightToLeft && KeyLayout.hebrew.letterRows[0].joined() == "קראטוןםפ"
      && KeyLayout.hebrew.letterRows[1].joined() == "שדגכעיחלךף" && KeyLayout.hebrew.letterRows[2].joined() == "זסבהנמצתץ")
check("Hebrew: Delete ends the top row, no long-press letters", KeyLayout.hebrew.deleteRow == 0 && !KeyLayout.hebrew.hasCase
      && KeyLayout.hebrew.readingRows.joined().allSatisfy { AccentSets.alternates(for: $0, language: "he").isEmpty })
check("layouts: only Arabic and Hebrew are right to left", KeyLayout.allCases.filter(\.isRightToLeft) == [.arabic, .hebrew])

let alphabets: [(KeyLayout, String, String)] = [
    (.russian, "ru", "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"),
    (.ukrainian, "uk", "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя"),
    (.greek, "el", "αβγδεζηθικλμνξοπρσςτυφχψωάέήίόύώϊϋΐΰ"),
    (.arabic, "ar", "ابتثجحخدذرزسشصضطظعغفقكلمنهويةءىأإآؤئ"),
    (.hebrew, "he", "אבגדהוזחטיכלמנסעפצקרשתךםןףץ"),
]
for (layout, lang, letters) in alphabets {
    let missing = letters.filter { layout.taps(toType: String($0), language: lang) == nil }
    check("\(layout.rawValue): every letter of the alphabet can be typed", missing.isEmpty, "missing \(missing)")
}

func rowsFor(_ l: KeyLayout) -> [[RowItem]] { TypingLayout.rows(layer: .letters, field: .standard, showsGlobe: true, letters: l) }
func keyCount(_ rows: [[RowItem]], _ kind: KeyKind) -> Int { rows.joined().filter { if case .key(kind, _) = $0 { return true }; return false }.count }
check("rows: shift only where there are capitals", KeyLayout.allCases.allSatisfy { keyCount(rowsFor($0), .shift) == ($0.hasCase ? 1 : 0) })
check("rows: one Delete in every layout", KeyLayout.allCases.allSatisfy { keyCount(rowsFor($0), .delete) == 1 })
check("rows: Hebrew's Delete ends the top row", rowsFor(.hebrew)[0].last == .key(.delete, .flex(1)) && rowsFor(.hebrew)[2].first == .spacer(1))
check("rows: Arabic's third row has Delete and no shift", rowsFor(.arabic)[2].first == .spacer(1)
      && { if case .key(.delete, _)? = rowsFor(.arabic)[2].last { return true }; return false }())
check("rows: ЙЦУКЕН's shift and delete narrow to fit nine letters", TypingLayout.thirdRowModifierWidth(letters: 9, columns: 11) == 1
      && TypingLayout.thirdRowModifierWidth(letters: 7, columns: 10) == 1.3 && TypingLayout.thirdRowModifierWidth(letters: 7, columns: 11) == 1.3)
check("rows: the bottom row and return don't move", KeyLayout.allCases.allSatisfy { rowsFor($0)[3] == rowsFor(.qwerty)[3] })
check("rows: Arabic's punctuation has ، and ؟", TypingLayout.rows(layer: .numbers, field: .standard, showsGlobe: true, letters: .arabic)[2].contains(.char("\u{060C}", 1.4))
      && TypingLayout.rows(layer: .symbols, field: .standard, showsGlobe: true, letters: .arabic)[2].contains(.char("\u{061F}", 1.4))
      && TypingLayout.rows(layer: .numbers, field: .standard, showsGlobe: true, letters: .russian) == TypingLayout.rows(layer: .numbers, field: .standard, showsGlobe: true))

// Every layout fits the keyboard at each width: keys in order, no overlaps, inside the side margins.
for width in [320.0, 375.0, 390.0, 430.0] {
    let sz = CGSize(width: width, height: 234)
    let met = KeyMetrics.forSize(sz, rows: 4)
    for l in KeyLayout.allCases {
        let placed = TypingLayout.place(rowsFor(l), in: sz, metrics: met, columns: l.columns)
        var ok = true
        for r in 0..<4 {
            let row = placed.filter { $0.id.row == r }
            if (row.first?.frame.minX ?? 0) < met.sideMargin - 0.5 || (row.last?.frame.maxX ?? .infinity) > width - met.sideMargin + 0.5 { ok = false }
            for (a, b) in zip(row, row.dropFirst()) where b.frame.minX < a.frame.maxX - 0.01 { ok = false }
            if row.contains(where: { $0.frame.width < 20 }) { ok = false }
        }
        check("fit: \(l.rawValue) at \(Int(width)) pt", ok, "\(placed.map { ($0.kind, $0.frame.minX, $0.frame.width) })")
    }
}

/// Types a word through a layout as fingers would: each tap lands on its key's center, the hit test must find that key,
/// and the taps (with the long-press rows and the accent key) must type the word.
func typeOnKeys(_ word: String, _ l: KeyLayout, _ lang: String) -> String? {
    guard let taps = l.taps(toType: word, language: lang) else { return nil }
    let sz = CGSize(width: 390, height: 234)
    let placed = TypingLayout.place(rowsFor(l), in: sz, metrics: KeyMetrics.forSize(sz, rows: 4), columns: l.columns)
    for t in taps {
        let base: String
        switch t { case .key(let k): base = k; case .hold(let k, _): base = k }
        guard let key = placed.first(where: { $0.kind == .character(base) }),
              TypingLayout.hit(CGPoint(x: key.frame.midX, y: key.frame.midY), in: placed)?.id == key.id else { return nil }
    }
    return KeyLayout.replay(taps)
}
for (word, l, lang) in [("привет", KeyLayout.russian, "ru"), ("єдність", .ukrainian, "uk"), ("їжак", .ukrainian, "uk"), ("ґанок", .ukrainian, "uk"),
                        ("γεια", .greek, "el"), ("λόγος", .greek, "el"), ("μυστήριο", .greek, "el"), ("مرحبا", .arabic, "ar"),
                        ("أهلا", .arabic, "ar"), ("שלום", .hebrew, "he"), ("ספר", .hebrew, "he")] {
    check("type: \(word) on \(l.rawValue)", typeOnKeys(word, l, lang) == word, "\(String(describing: l.taps(toType: word, language: lang)))")
}
check("type: a letter no layout key has", KeyLayout.hebrew.taps(toType: "a", language: "he") == nil && KeyLayout.russian.taps(toType: "ї", language: "ru") == nil)

let heKeys = TypingLayout.place(rowsFor(.hebrew), in: size, metrics: m, columns: 10)
let order = TypingLayout.readingOrder(heKeys, rightToLeftRows: [0, 1, 2])
check("VoiceOver: Hebrew's rows read right to left, starting at Delete", order.first?.kind == .delete && order[1].kind == .character("פ")
      && order.filter { $0.id.row == 1 }.first?.kind == .character("ף"))
check("VoiceOver: the bottom row reads left to right", order.filter { $0.id.row == 3 }.map(\.kind) == heKeys.filter { $0.id.row == 3 }.map(\.kind))
check("VoiceOver: a left-to-right layout keeps its order", TypingLayout.readingOrder(de, rightToLeftRows: []) == de)
check("VoiceOver: the accent key says Accent", KeyKind.character(DeadKeys.tonos).spokenLabel(shift: .off, layer: .letters, returnKind: .standard) == "Accent")

// MARK: Round 2: Greek's accent key

func press(_ inputs: [String]) -> String {
    var text = "", pending: String?
    for i in inputs { let r = DeadKeys.press(pending: pending, input: i); text += r.insert; pending = r.pending }
    return text + (pending.map { "[\($0)]" } ?? "")
}
check("accent key: waits for the vowel", DeadKeys.press(pending: nil, input: DeadKeys.tonos) == .init(insert: "", pending: DeadKeys.tonos))
check("accent key: ΄ then ο is ό, capitals too", press([DeadKeys.tonos, "ο"]) == "ό" && press([DeadKeys.tonos, "Ο"]) == "Ό" && press([DeadKeys.tonos, "ω"]) == "ώ")
check("accent key: diaeresis and both", press([DeadKeys.dialytika, "ι"]) == "ϊ" && press([DeadKeys.dialytikaTonos, "υ"]) == "ΰ" && press([DeadKeys.dialytika, "Υ"]) == "Ϋ")
check("accent key: space types the mark", press([DeadKeys.tonos, " "]) == DeadKeys.tonos)
check("accent key: twice types the mark", press([DeadKeys.tonos, DeadKeys.tonos]) == DeadKeys.tonos)
check("accent key: a consonant gets the mark before it", press([DeadKeys.tonos, "κ"]) == DeadKeys.tonos + "κ")
check("accent key: another mark replaces the first", press([DeadKeys.tonos, DeadKeys.dialytika, "ι"]) == DeadKeys.tonos + "ϊ")
check("accent key: nothing waiting types as is", press(["α", "β"]) == "αβ")
check("accent key: decompose finds the mark", DeadKeys.decompose("ό")! == (DeadKeys.tonos, "ο") && DeadKeys.decompose("ΰ")! == (DeadKeys.dialytikaTonos, "υ")
      && DeadKeys.decompose("ο") == nil)
check("accent key: the key types ό when long-press is skipped", KeyLayout.replay([.key(DeadKeys.tonos), .key("ο")]) == "ό"
      && KeyLayout.replay([.hold(DeadKeys.tonos, pick: DeadKeys.dialytika), .key("ι")]) == "ϊ")
check("accent key: names", DeadKeys.spokenName(DeadKeys.dialytika) == "Diaeresis" && DeadKeys.spokenName("α") == nil)

// MARK: Round 2: words in each script

check("script: each word's", WritingScript.of(word: "привет") == .cyrillic && WritingScript.of(word: "λόγος") == .greek
      && WritingScript.of(word: "مرحبا") == .arabic && WritingScript.of(word: "שלום") == .hebrew && WritingScript.of(word: "hello") == .latin
      && WritingScript.of(word: "mañana") == .latin)
check("script: marks and apostrophes have none", WritingScript.of(word: "كَتَبَ") == .arabic && WritingScript.of(word: "м\u{02BC}ята") == .cyrillic
      && WritingScript.of(word: "123") == nil && WritingScript.of(word: "don't") == .latin)
check("script: mixed is other", WritingScript.of(word: "приvet") == .other)
check("script: each language's", WritingScript.of(language: "ru_RU") == .cyrillic && WritingScript.of(language: "uk") == .cyrillic
      && WritingScript.of(language: "el") == .greek && WritingScript.of(language: "ar") == .arabic && WritingScript.of(language: "he_IL") == .hebrew
      && WritingScript.of(language: "en_US") == .latin && WritingScript.of(language: "ja") == .other)
check("script: right to left", WritingScript.arabic.isRightToLeft && WritingScript.hebrew.isRightToLeft && !WritingScript.greek.isRightToLeft)

// Cyrillic
check("Cyrillic: the last word", w("Я думаю превет").word == "превет")
check("Cyrillic: hyphenated", w("кто-нибуть") == WordAtCursor(word: "нибуть", token: "кто-нибуть") && !alone("кто-нибуть"))
check("Cyrillic: after an opening guillemet", w("«превет").word == "превет" && !alone("«превет"))
check("Cyrillic: the closing guillemet ends a word", TypingCorrection.isBoundary("\u{00BB}"))
check("Cyrillic: corrected in Russian", fix("Я думаю превет", ["привет"], lang: "ru") == "привет" && fix("Превет", ["привет"], lang: "ru") == "Привет")
check("Cyrillic: ё is one edit", fix("еще", ["ещё"], lang: "ru") == "ещё")
check("Cyrillic: inner capital left alone", alone("ВКонтакте"))
check("Cyrillic: Ukrainian apostrophe stays in the word", w("м'ята").word == "м'ята" && w("м\u{02BC}ята").word == "м\u{02BC}ята")
check("Cyrillic: an English word isn't corrected in Russian", fix("helo", ["хело"], lang: "ru") == nil
      && TypingCorrection.leavesAlone(w("helo"), skip: none, language: "ru"))
check("Cyrillic: a Russian word isn't corrected in English", fix("превет", ["prevent"], lang: "en_US") == nil)
check("Cyrillic: a mixed word isn't corrected", TypingCorrection.leavesAlone(w("приvet"), skip: none, language: "ru"))

// Greek
check("Greek: final sigma is a letter of the word", w("ο καλός").word == "καλός" && w("ο λογοσ").word == "λογοσ")
check("Greek: σ at the end becomes ς", fix("ο λογοσ", misspelled: false, [], lang: "el") == "λογος" && fix("καλόσ", misspelled: false, [], lang: "el_GR") == "καλός")
check("Greek: in your case", fix("Λογοσ", misspelled: false, [], lang: "el") == "Λογος")
check("Greek: capitals have no final form", fix("ΛΟΓΟΣ", misspelled: false, [], lang: "el") == nil)
check("Greek: σ alone or inside stays", fix("σ", misspelled: false, [], lang: "el") == nil && fix("σπίτι", misspelled: false, [], lang: "el") == nil)
check("Greek: final sigma before the checker's guess", fix("λογοσ", misspelled: true, ["λόγος"], lang: "el") == "λογος")
check("Greek: final sigma only in Greek", fix("λογοσ", misspelled: false, [], lang: "en_US") == nil)
check("Greek: not in a word you put back", fix("λογοσ", misspelled: false, [], skip: ["λογοσ"], lang: "el") == nil)
check("Greek: final sigma rule", TypingScripts.finalSigma("λογοσ") == "λογος" && TypingScripts.finalSigma("bus") == nil
      && TypingScripts.finalSigma("2σ") == nil && TypingScripts.finalSigma("λογος") == nil)
check("Greek: question mark and ano teleia end a word", TypingCorrection.isBoundary("\u{037E}") && TypingCorrection.isBoundary("\u{0387}"))
check("Greek: corrected with the checker", fix("καλιμερα", ["καλημέρα"], lang: "el") == "καλημέρα")

// Arabic
check("Arabic: the last word", w("مرحبا بكم").word == "بكم")
check("Arabic: vowel marks stay in the word", w("كَتَبَ").word == "كَتَبَ" && w("كَتَبَ").word.count == 3)
check("Arabic: tatweel stays in the word", w("كـتاب").word == "كـتاب")
check("Arabic: comma, semicolon, and question mark end a word", ["\u{060C}", "\u{061B}", "\u{061F}"].allSatisfy(TypingCorrection.isBoundary))
check("Arabic: Arabic-Indic digits are numbers", alone("ب٣"))
check("Arabic: corrected with the checker", fix("مرحيا", ["مرحبا"], lang: "ar") == "مرحبا")
check("Arabic: an English word isn't corrected in Arabic", fix("helo", ["هلو"], lang: "ar") == nil)

// Hebrew
check("Hebrew: the last word", w("שלום עולם").word == "עולם")
check("Hebrew: an acronym with gershayim is one word, left alone", w("צה\u{05F4}ל").word == "צה\u{05F4}ל" && alone("צה\u{05F4}ל")
      && fix("צה\u{05F4}ל", ["צהל"], lang: "he") == nil)
check("Hebrew: an abbreviation ending in geresh isn't a word to correct", w("פרופ\u{05F3}").word == "")
check("Hebrew: maqaf joins like a hyphen", w("בית\u{05BE}ספר") == WordAtCursor(word: "ספר", token: "בית\u{05BE}ספר") && !alone("בית\u{05BE}ספר"))
check("Hebrew: final letters are letters", w("שלום").word == "שלום" && w("ארץ").word == "ארץ")
check("Hebrew: corrected with the checker", fix("שלומ", ["שלום"], lang: "he") == "שלום")
check("Hebrew: an English word isn't corrected in Hebrew", fix("helo", ["הלו"], lang: "he") == nil)

// MARK: Round 2: right to left

check("direction: a Hebrew line runs right to left", TypingScripts.paragraphIsRightToLeft(before: "שלום ", after: nil, fallback: false))
check("direction: an Arabic line after the cursor", TypingScripts.paragraphIsRightToLeft(before: "", after: "مرحبا", fallback: false))
check("direction: an English line runs left to right on the Hebrew layout", !TypingScripts.paragraphIsRightToLeft(before: "Hi שלום", after: nil, fallback: true))
check("direction: the first letter decides", TypingScripts.paragraphIsRightToLeft(before: "שלום hello", after: nil, fallback: false))
check("direction: only this paragraph", !TypingScripts.paragraphIsRightToLeft(before: "שלום\nhello ", after: nil, fallback: true)
      && TypingScripts.paragraphIsRightToLeft(before: "hello\n", after: "שלום\nhi", fallback: false))
check("direction: no letters yet follows the layout", TypingScripts.paragraphIsRightToLeft(before: "12 ", after: nil, fallback: true)
      && !TypingScripts.paragraphIsRightToLeft(before: nil, after: nil, fallback: false))

var rtlDrag = CursorDrag(startX: 100, rightToLeft: true)
check("drag: right to left, dragging left moves forward", rtlDrag.move(to: 84) == 2)
check("drag: right to left, dragging right moves back", rtlDrag.move(to: 116) == -4 && rtlDrag.moved == 2)
let rtlRow = AccentRow.layout(keyMinX: 300, keyWidth: 33, count: 3, areaWidth: 390, rightToLeft: true)
check("row: right to left, it ends over the key", rtlRow.originX == 234 && rtlRow.originX + rtlRow.width == 333)
check("row: right to left, the first letter is over the key", rtlRow.index(at: 320) == 0 && rtlRow.index(at: 240) == 2 && rtlRow.index(at: 280) == 1)
check("row: right to left, slots mirror", rtlRow.option(atSlot: 0) == 2 && rtlRow.option(atSlot: 2) == 0 && row.option(atSlot: 1) == 1)
let rtlEdge = AccentRow.layout(keyMinX: 3, keyWidth: 33, count: 4, areaWidth: 390, rightToLeft: true)
check("row: right to left, shifted right to stay on the keyboard", rtlEdge.originX == 3)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
