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
let kb = TypingLanguages.keyboardLanguages(["en-US", "emoji", "es-MX", "ru-RU", "en-US", "ja-JP", "fr-FR"], available: available)
check("languages: your keyboards, in order, Latin only, once", kb == ["en_US", "es_MX", "fr"], "\(kb)")
check("languages: what this keyboard can't type", TypingLanguages.unsupported(["en-US", "emoji", "ru-RU", "ja-JP", "dictation"], available: available) == ["ru", "ja"])
check("current: the field's language when it's yours", TypingLanguages.current(chosen: kb, document: "es-MX", picked: "en_US", available: available) == "es_MX")
check("current: not a field language you didn't add", TypingLanguages.current(chosen: kb, document: "de-DE", picked: nil, available: available) == "en_US")
check("current: the one you picked", TypingLanguages.current(chosen: kb, document: nil, picked: "fr", available: available) == "fr")
check("current: a pick you removed falls back to the first", TypingLanguages.current(chosen: kb, document: nil, picked: "it", available: available) == "en_US")
check("current: no list follows the field", TypingLanguages.current(chosen: [], document: "de-DE", picked: nil, available: available) == "de")
check("current: not a field in another script", TypingLanguages.current(chosen: [], document: "ru-RU", picked: nil, available: available) == "en_US")
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
check("layout: titles", KeyLayout.allCases.map(\.title) == ["QWERTY", "QWERTY with ñ", "AZERTY", "QWERTZ"])

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

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
