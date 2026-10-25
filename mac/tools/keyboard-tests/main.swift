import Foundation

// The keyboard's modes and Home stats (VerbatimKeyboard/KeyboardHome.swift) and typing layout (TypingLayout.swift):
// which mode it opens in, the stats pages, shift and caps lock, auto-capitalization, double-space for a period, layer
// switching, rows, key frames, and hit testing. Not part of any app target; run mac/tools/test-keyboard.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// MARK: Which mode the keyboard opens in (KeyboardHome.swift)

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func opening(_ field: FieldKind = .standard, secure: Bool = false, available: Bool = true, inserted: Date? = nil) -> KeyboardSurface {
    KeyboardSurface.opening(field: field, secure: secure, dictationAvailable: available, lastInsertedAt: inserted, now: t0)
}
check("first time in a session: Home", opening() == .home)
check("without Full Access: Typing", opening(available: false) == .typing)
check("number, email, and link fields: Typing", [FieldKind.numberPad, .decimalPad, .numbersAndPunctuation, .email, .url]
      .allSatisfy { opening($0) == .typing })
check("password fields: Typing", opening(secure: true) == .typing)
check("after a dictation went in: Typing", opening(inserted: t0.addingTimeInterval(-60)) == .typing)
check("a new session after the window: Home", opening(inserted: t0.addingTimeInterval(-KeyboardSurface.sessionWindow - 1)) == .home)
check("a clock that moved back counts as a new session", opening(inserted: t0.addingTimeInterval(3600)) == .home)
check("a running dictation shows Listening", KeyboardMode.current(surface: .typing, dictating: true) == .listening
      && KeyboardMode.current(surface: .home, dictating: true) == .listening)
check("otherwise the resting view", KeyboardMode.current(surface: .home, dictating: false) == .home
      && KeyboardMode.current(surface: .typing, dictating: false) == .typing)
check("Inserted bar: 5 s, 12 s with a correction", !InsertedBar.expired(shownFor: 4.9, hasCorrection: false)
      && InsertedBar.expired(shownFor: 5, hasCorrection: false) && !InsertedBar.expired(shownFor: 8, hasCorrection: true)
      && InsertedBar.expired(shownFor: 12, hasCorrection: true))

// MARK: Home's stats pages (KeyboardHome.swift)

let full = KeyboardStatNumbers(weekWords: 3620, weekSecondsSaved: 8040, weekCurrent: true, totalWords: 48210,
                               paceWords: 14200, paceSeconds: 6000, typingWPM: 40)
let pages = KeyboardStatsCopy.pages(full, grouping: ",")
check("three pages", pages.count == 3, "\(pages)")
check("this week", pages.first == KeyboardStatPage(number: "3,620", unit: "words",
      line: "dictated this week. That's 2h 14m you didn't have to type."), "\(pages.first!)")
check("since you started", pages[1] == KeyboardStatPage(number: "48,210", unit: "words",
      line: "since you started. That's about half a novel."), "\(pages[1])")
check("speaking pace", pages[2] == KeyboardStatPage(number: "142", unit: "wpm",
      line: "your speaking pace, about four times faster than typing."), "\(pages[2])")
check("nothing dictated yet: no pages",
      KeyboardStatsCopy.pages(KeyboardStatNumbers(weekWords: 0, weekSecondsSaved: 0, weekCurrent: true, totalWords: 0,
                                                  paceWords: 0, paceSeconds: 0, typingWPM: 40)).isEmpty)
var stale = full; stale.weekCurrent = false
check("a week the app counted that has ended reads 0", KeyboardStatsCopy.pages(stale, grouping: ",").first
      == KeyboardStatPage(number: "0", unit: "words", line: "dictated this week."))
var brief = full; brief.paceSeconds = 30
check("no pace page under a minute of speech", KeyboardStatsCopy.pages(brief, grouping: ",").count == 2)
var one = full; one.weekWords = 1; one.weekSecondsSaved = 1
check("one word, no time saved", KeyboardStatsCopy.pages(one, grouping: ",").first
      == KeyboardStatPage(number: "1", unit: "word", line: "dictated this week."))
check("pace is words a minute", KeyboardStatsCopy.pace(words: 300, seconds: 120) == 150 && KeyboardStatsCopy.pace(words: 5, seconds: 10) == nil)
check("faster than typing", KeyboardStatsCopy.faster(pace: 120, typing: 40) == "about three times faster than typing"
      && KeyboardStatsCopy.faster(pace: 80, typing: 40) == "about twice as fast as typing"
      && KeyboardStatsCopy.faster(pace: 50, typing: 40) == nil
      && KeyboardStatsCopy.faster(pace: 520, typing: 40) == "about 13 times faster than typing")
check("pages and novels", KeyboardStatsCopy.comparison(100) == nil && KeyboardStatsCopy.comparison(250) == "about a page"
      && KeyboardStatsCopy.comparison(3000) == "about 12 pages" && KeyboardStatsCopy.comparison(25_000) == "about a quarter of a novel"
      && KeyboardStatsCopy.comparison(90_000) == "about a whole novel" && KeyboardStatsCopy.comparison(287_860) == "about 3 novels")
check("durations", KeyboardStatsCopy.duration(42) == "42s" && KeyboardStatsCopy.duration(18 * 60) == "18m"
      && KeyboardStatsCopy.duration(3600) == "1h" && KeyboardStatsCopy.duration(8040) == "2h 14m")
check("grouping", KeyboardStatsCopy.number(287860, grouping: ",") == "287,860" && KeyboardStatsCopy.number(999, grouping: ",") == "999"
      && KeyboardStatsCopy.number(1000, grouping: ".") == "1.000" && KeyboardStatsCopy.number(0, grouping: ",") == "0")

// MARK: Shift and caps lock

check("shift: off → on", TypingRules.tapShift(.off, sinceLastTap: nil) == .on)
check("shift: on → off", TypingRules.tapShift(.on, sinceLastTap: nil) == .off)
check("shift: on → off after a slow second tap", TypingRules.tapShift(.on, sinceLastTap: 0.8) == .off)
check("shift: double tap → caps lock", TypingRules.tapShift(.on, sinceLastTap: 0.2) == .locked)
check("shift: double tap from auto-capitalized → caps lock", TypingRules.tapShift(.off, sinceLastTap: 0.2) == .locked)
check("shift: caps lock → off", TypingRules.tapShift(.locked, sinceLastTap: nil) == .off)
check("shift: caps lock → off, even with a quick tap", TypingRules.tapShift(.locked, sinceLastTap: 0.1) == .off)
check("shift: window edge counts", TypingRules.tapShift(.on, sinceLastTap: TypingRules.doubleTapWindow) == .locked)
check("one capital, then lowercase", TypingRules.shiftAfterInput(.on, capitalizeNext: false) == .off)
check("caps lock survives typing", TypingRules.shiftAfterInput(.locked, capitalizeNext: false) == .locked)
check("auto-capitalization turns shift on", TypingRules.shiftAfterInput(.off, capitalizeNext: true) == .on)
check("letters follow shift", TypingRules.text(for: "a", layer: .letters, shift: .on) == "A"
      && TypingRules.text(for: "a", layer: .letters, shift: .locked) == "A"
      && TypingRules.text(for: "a", layer: .letters, shift: .off) == "a")
check("symbols ignore shift", TypingRules.text(for: "-", layer: .numbers, shift: .on) == "-")

// MARK: Auto-capitalization

let s = AutoCapMode.sentences
check("sentences: empty field", TypingRules.shouldCapitalize(s, before: ""))
check("sentences: unknown context counts as the start", TypingRules.shouldCapitalize(s, before: nil))
check("sentences: after a period and space", TypingRules.shouldCapitalize(s, before: "Hello. "))
check("sentences: after a question mark and spaces", TypingRules.shouldCapitalize(s, before: "Really?  "))
check("sentences: after an exclamation mark", TypingRules.shouldCapitalize(s, before: "Yes! "))
check("sentences: after a new line", TypingRules.shouldCapitalize(s, before: "Hi\n"))
check("sentences: after a quoted sentence", TypingRules.shouldCapitalize(s, before: "He said “done.” "))
check("sentences: after a period inside parentheses", TypingRules.shouldCapitalize(s, before: "(See above.) "))
check("sentences: only spaces so far", TypingRules.shouldCapitalize(s, before: "   "))
check("sentences: not mid-sentence", !TypingRules.shouldCapitalize(s, before: "Hello "))
check("sentences: not right after a period (e.g, example.com)", !TypingRules.shouldCapitalize(s, before: "e.g"))
check("sentences: not after a period with no space", !TypingRules.shouldCapitalize(s, before: "example."))
check("sentences: not after a comma", !TypingRules.shouldCapitalize(s, before: "Well, "))
check("words: start of each word", TypingRules.shouldCapitalize(.words, before: "Ada ")
      && !TypingRules.shouldCapitalize(.words, before: "Ada L"))
check("words: empty field", TypingRules.shouldCapitalize(.words, before: ""))
check("none: never", !TypingRules.shouldCapitalize(.none, before: "") && !TypingRules.shouldCapitalize(.none, before: "Hi. "))
check("all characters: always", TypingRules.shouldCapitalize(.allCharacters, before: "abc"))

// MARK: Double space for a period

check("double space after a word", TypingRules.periodShortcut(before: "Hello ", lastKeyWasSpace: true, field: .standard))
check("double space after a number", TypingRules.periodShortcut(before: "at 5 ", lastKeyWasSpace: true, field: .standard))
check("not when the cursor moved after an old space", !TypingRules.periodShortcut(before: "Hello ", lastKeyWasSpace: false, field: .standard))
check("not after a period (no triple period)", !TypingRules.periodShortcut(before: "Hello. ", lastKeyWasSpace: true, field: .standard))
check("not after two spaces", !TypingRules.periodShortcut(before: "Hello  ", lastKeyWasSpace: true, field: .standard))
check("not after a comma", !TypingRules.periodShortcut(before: "Well, ", lastKeyWasSpace: true, field: .standard))
check("not at the start", !TypingRules.periodShortcut(before: " ", lastKeyWasSpace: true, field: .standard))
check("not with no context", !TypingRules.periodShortcut(before: nil, lastKeyWasSpace: true, field: .standard))
check("not in email fields", !TypingRules.periodShortcut(before: "ada ", lastKeyWasSpace: true, field: .email))
check("not in link fields", !TypingRules.periodShortcut(before: "ada ", lastKeyWasSpace: true, field: .url))
check("after a closing quote", TypingRules.periodShortcut(before: "“yes” ", lastKeyWasSpace: true, field: .standard))

// MARK: Layers

check("123 opens numbers", TypingRules.layer(after: .layer(.numbers), in: .letters, field: .standard) == .numbers)
check("#+= opens symbols", TypingRules.layer(after: .layer(.symbols), in: .numbers, field: .standard) == .symbols)
check("space in numbers returns to letters", TypingRules.layer(after: .space, in: .numbers, field: .standard) == .letters)
check("return in symbols returns to letters", TypingRules.layer(after: .returnKey, in: .symbols, field: .standard) == .letters)
check("apostrophe returns to letters", TypingRules.layer(after: .character("'"), in: .numbers, field: .standard) == .letters)
check("a digit stays in numbers", TypingRules.layer(after: .character("4"), in: .numbers, field: .standard) == .numbers)
check("numbers-and-punctuation fields stay in numbers",
      TypingRules.layer(after: .space, in: .numbers, field: .numbersAndPunctuation) == .numbers)
check("numbers-and-punctuation fields start in numbers", TypingRules.initialLayer(for: .numbersAndPunctuation) == .numbers)
check("other fields start in letters", TypingRules.initialLayer(for: .email) == .letters)

// MARK: Return key

check("plain return shows the symbol", ReturnKind.standard.label == nil && ReturnKind.standard.spoken == "Return")
check("Go, Send, and Search are action keys", ReturnKind.go.isAction && ReturnKind.send.label == "Send" && ReturnKind.search.label == "Search")
check("labels are sentence case", ReturnKind.emergencyCall.label == "Emergency call")

// MARK: Rows

func kinds(_ row: [RowItem]) -> [KeyKind] { row.compactMap { if case .key(let k, _) = $0 { return k } else { return nil } } }
let letters = TypingLayout.rows(layer: .letters, field: .standard, showsGlobe: true)
check("letters: four rows", letters.count == 4)
check("letters: QWERTY", kinds(letters[0]) == "qwertyuiop".map { .character(String($0)) })
check("letters: shift and delete flank z to m",
      kinds(letters[2]).first == .shift && kinds(letters[2]).last == .delete && kinds(letters[2]).count == 9)
check("letters: 123, globe, space, return", kinds(letters[3]) == [.layer(.numbers), .globe, .space, .returnKey])
let noGlobe = TypingLayout.rows(layer: .letters, field: .standard, showsGlobe: false)
check("no globe when the system shows one", !kinds(noGlobe[3]).contains(.globe))
let numbers = TypingLayout.rows(layer: .numbers, field: .standard, showsGlobe: false)
check("numbers: digits, #+=, ABC", kinds(numbers[0]).first == .character("1") && kinds(numbers[2]).first == .layer(.symbols)
      && kinds(numbers[3]).first == .layer(.letters))
let symbols = TypingLayout.rows(layer: .symbols, field: .standard, showsGlobe: false)
check("symbols: back to 123", kinds(symbols[2]).first == .layer(.numbers) && kinds(symbols[0]).contains(.character("#")))
let email = TypingLayout.rows(layer: .letters, field: .email, showsGlobe: false)
check("email: @ and . beside space", kinds(email[3]) == [.layer(.numbers), .space, .character("@"), .character("."), .returnKey])
let url = TypingLayout.rows(layer: .letters, field: .url, showsGlobe: false)
check("links: / and . beside space", kinds(url[3]).contains(.character("/")) && kinds(url[3]).contains(.character(".")))
let pad = TypingLayout.rows(layer: .letters, field: .numberPad, showsGlobe: false)
check("number pad: 1 to 9, then 0 and delete", pad.count == 4 && kinds(pad[0]) == [.character("1"), .character("2"), .character("3")]
      && kinds(pad[3]) == [.character("0"), .delete])
let decimal = TypingLayout.rows(layer: .letters, field: .decimalPad, showsGlobe: true)
check("decimal pad: globe, point, 0, delete", kinds(decimal[3]) == [.globe, .character("."), .character("0"), .delete])
check("no shift on a number pad", !pad.flatMap(kinds).contains(.shift))

// MARK: Frames

let size = CGSize(width: 390, height: 230)
let m = KeyMetrics.forSize(size, rows: 4)
let placed = TypingLayout.place(letters, in: size, metrics: m)
let u = TypingLayout.unit(width: size.width, metrics: m)
let row0 = placed.filter { $0.id.row == 0 }
check("row 1 has ten keys", row0.count == 10)
check("row 1 fills the width with 3 pt margins",
      abs(row0.first!.frame.minX - 3) < 0.01 && abs(row0.last!.frame.maxX - (390 - 3)) < 0.01,
      "\(row0.first!.frame.minX) … \(row0.last!.frame.maxX)")
check("keys are 6 pt apart", abs(row0[1].frame.minX - row0[0].frame.maxX - 6) < 0.01)
let row1 = placed.filter { $0.id.row == 1 }
check("row 2 is centered half a key in", abs(row1.first!.frame.minX - (3 + (u + 6) / 2)) < 0.01
      && abs((390 - row1.last!.frame.maxX) - row1.first!.frame.minX) < 0.01)
let row2 = placed.filter { $0.id.row == 2 }
check("shift sits at the left margin, delete at the right", abs(row2.first!.frame.minX - 3) < 0.01 && abs(row2.last!.frame.maxX - 387) < 0.01)
check("z to m are centered", abs((row2[1].frame.minX - row2[0].frame.maxX) - (row2[8].frame.minX - row2[7].frame.maxX)) < 0.01)
let row3 = placed.filter { $0.id.row == 3 }
check("space takes the rest of the bottom row", row3.first(where: { $0.kind == .space })!.frame.width > 4 * u)
check("bottom row ends at the right margin", abs(row3.last!.frame.maxX - 387) < 0.01)
check("keys are at most 46 pt tall", placed.allSatisfy { $0.frame.height <= 46 })
check("rows don't overlap", zip(placed.dropLast(), placed.dropFirst()).allSatisfy { a, b in
    a.id.row == b.id.row || a.frame.maxY <= b.frame.minY })
check("every key fits inside the area", placed.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 390.01 && $0.frame.maxY <= 230.01 })
let short = KeyMetrics.forSize(CGSize(width: 390, height: 150), rows: 4)
check("short areas shrink the row gap", short.rowGap < 11)
let padPlaced = TypingLayout.place(pad, in: size, metrics: m)
check("number pad keys are three equal columns", {
    let r = padPlaced.filter { $0.id.row == 0 }
    return r.count == 3 && abs(r[0].frame.width - r[2].frame.width) < 0.01
}())

// MARK: Hit testing

let q = row0[0], w = row0[1], a = row1[0], shiftKey = row2[0]
check("a touch on q is q", TypingLayout.hit(CGPoint(x: q.frame.midX, y: q.frame.midY), in: placed)?.id == q.id)
check("a touch in the gap goes to the nearer key",
      TypingLayout.hit(CGPoint(x: q.frame.maxX + 2, y: q.frame.midY), in: placed)?.id == q.id
      && TypingLayout.hit(CGPoint(x: w.frame.minX - 2, y: q.frame.midY), in: placed)?.id == w.id)
check("a touch left of a is a (the inset counts)", TypingLayout.hit(CGPoint(x: 4, y: a.frame.midY), in: placed)?.id == a.id)
check("a touch between rows goes to the nearer row",
      TypingLayout.hit(CGPoint(x: q.frame.midX, y: q.frame.maxY + 2), in: placed)?.id.row == 0
      && TypingLayout.hit(CGPoint(x: q.frame.midX, y: a.frame.minY - 2), in: placed)?.id.row == 1)
check("a touch above the keys is the top row", TypingLayout.hit(CGPoint(x: q.frame.midX, y: 0), in: placed)?.id == q.id)
check("a touch beside shift is shift", TypingLayout.hit(CGPoint(x: shiftKey.frame.maxX + 3, y: shiftKey.frame.midY), in: placed)?.kind == .shift)
check("no keys, no hit", TypingLayout.hit(.zero, in: []) == nil)

// MARK: Labels

check("VoiceOver: letters follow shift", KeyKind.character("a").spokenLabel(shift: .on, layer: .letters, returnKind: .standard) == "A")
check("VoiceOver: return says its word", KeyKind.returnKey.spokenLabel(shift: .off, layer: .letters, returnKind: .send) == "Send")
check("VoiceOver: globe", KeyKind.globe.spokenLabel(shift: .off, layer: .letters, returnKind: .standard) == "Next keyboard")
check("layer key titles", KeyKind.layer(.numbers).layerTitle == "123" && KeyKind.layer(.symbols).layerTitle == "#+="
      && KeyKind.layer(.letters).layerTitle == "ABC" && KeyKind.space.layerTitle == nil)

// MARK: The dictate button (DictateButton.swift, Settings › Keyboard › Dictate button)

check("the default is today's keyboard: standard, right, filled", DictateButton.standard == DictateButton(size: .standard, position: .right, style: .filled))
check("nothing stored reads as the default", DictateButton(size: nil, position: nil, style: nil) == .standard)
check("unknown stored values read as the default", DictateButton(size: "huge", position: "top", style: "neon") == .standard)
check("stored values read back", DictateButton(size: "large", position: "left", style: "outline") == DictateButton(size: .large, position: .left, style: .outline))
let suite = "dictate-button-tests-\(UUID().uuidString)"
if let d = UserDefaults(suiteName: suite) {
    check("no defaults reads as the default", DictateButton.read(nil) == .standard)
    check("an empty App Group reads as the default", DictateButton.read(d) == .standard)
    var all: [DictateButton] = []
    for size in DictateButton.Size.allCases { for pos in DictateButton.Position.allCases { for style in DictateButton.Style.allCases {
        all.append(DictateButton(size: size, position: pos, style: style))
    } } }
    check("every combination round-trips through the App Group", all.allSatisfy { b in b.write(d); return DictateButton.read(d) == b })
    check("the stored keys are the keyboard's", d.string(forKey: "kb.dictate.size") != nil && d.string(forKey: "kb.dictate.position") != nil
          && d.string(forKey: "kb.dictate.style") != nil)
    check("twelve combinations", all.count == 12)
    d.removePersistentDomain(forName: suite)
}
check("Large is a 62 pt bar and 16 pt more keyboard", DictateButton(size: .large).barHeight == 62 && DictateButton(size: .large).keyboardHeight == 296)
check("Standard keeps the 46 pt bar and the 280 pt keyboard", DictateButton.standard.barHeight == 46 && DictateButton.standard.keyboardHeight == 280)
check("every combination's hit area is at least 46 pt", DictateButton.Size.allCases.allSatisfy { DictateButton(size: $0).barHeight >= DictateButton.minimumHit })
check("right: menu left, button right", DictateButton(position: .right).typingBar == [.menu, .spacer, .button])
check("left: button left, menu right", DictateButton(position: .left).typingBar == [.button, .spacer, .menu])
check("center: the button stays centered", DictateButton(position: .center).typingBar == [.menu, .spacer, .button, .spacer, .balance])
check("Done leads only for Left", DictateButton(position: .left).doneLeads && !DictateButton(position: .center).doneLeads && !DictateButton(position: .right).doneLeads)
check("segment titles match the mockup", DictateButton.Size.allCases.map(\.title) == ["Standard", "Large"]
      && DictateButton.Position.allCases.map(\.title) == ["Left", "Center", "Right"]
      && DictateButton.Style.allCases.map(\.title) == ["Filled", "Outline"])
check("VoiceOver label", DictateButton.accessibilityLabel == "Start dictation")

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
