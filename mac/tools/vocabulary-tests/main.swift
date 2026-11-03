import Foundation

// Runs the app's own BuiltInVocabulary.swift and EverydayFixes.swift (compiled with this file by
// test-vocabulary.sh) on the cases vocab_check.py wrote with its results, so the gate's Python matching and the
// app's NSRegularExpression matching can't drift apart. Then checks the specialty fields (VocabularyField): which
// categories each switch covers, the defaults, that a field that's off doesn't run, and real sentences per field.
// The stubs below stand in for the app types those files use.
//   Usage: vocabulary-tests ModernVocabulary.json EverydayFixes.json cases.json

enum Log { static func note(_ s: String) { print("log: \(s)") } }

struct Segment {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

struct DictionaryEntry {
    var preferred: String
    var heardAs: [String]
    var learnedFrom: String
    var createdAt = Date()
}

struct Correction {}

enum CorrectionEdits {
    /// The app's replacement (Model/CorrectionEdits.swift) without the bookkeeping: non-overlapping ranges, in order,
    /// skipping any that already read as the term.
    @discardableResult
    static func apply(_ ranges: [NSRange], in segments: inout [Segment], at i: Int, to: String, label from: String,
                      byDictionary: Bool, corrections: inout [Correction]) -> Correction? {
        let ns = segments[i].text as NSString
        var chosen: [NSRange] = []
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            guard r.location >= 0, r.length > 0, NSMaxRange(r) <= ns.length else { continue }
            if let last = chosen.last, NSMaxRange(last) > r.location { continue }
            if ns.substring(with: r) == to { continue }
            chosen.append(r)
        }
        guard !chosen.isEmpty else { return nil }
        let out = NSMutableString(string: segments[i].text)
        for r in chosen.reversed() { out.replaceCharacters(in: r, with: to) }
        segments[i].text = out as String
        return Correction()
    }
}

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: vocabulary-tests ModernVocabulary.json EverydayFixes.json cases.json"); exit(2) }
let terms = BuiltInVocabulary.load(URL(fileURLWithPath: args[1]))
let rules = BuiltInVocabulary.rules(for: terms)
let fixes = EverydayFixes.load(URL(fileURLWithPath: args[2]))
guard let data = FileManager.default.contents(atPath: args[3]),
      let cases = try? JSONSerialization.jsonObject(with: data) as? [String: [[String]]] else { print("FAIL unreadable cases"); exit(1) }

var fails = 0
var total = 0
for pair in cases["vocabulary"] ?? [] {
    total += 1
    let got = BuiltInVocabulary.fix(pair[0], rules: rules)
    if got != pair[1] {
        fails += 1
        if fails <= 40 { print("FAIL vocabulary: \(pair[0]) -> app \(got), gate \(pair[1])") }
    }
}
for pair in cases["everyday"] ?? [] {
    total += 1
    let got = EverydayFixes.apply(pair[0], fixes: fixes)
    if got != pair[1] {
        fails += 1
        if fails <= 40 { print("FAIL everyday: \(pair[0]) -> app \(got), gate \(pair[1])") }
    }
}
print("\(terms.count) terms, \(rules.count) rules, \(fixes.count) everyday fixes; \(total) cases compared")
if terms.isEmpty || fixes.isEmpty { print("FAIL nothing loaded"); exit(1) }
if fails > 0 { print("\(fails) case(s) differ between the app's code and vocab_check.py"); exit(1) }
print("The app's code and vocab_check.py agree on every case.")

// MARK: - Specialty fields (Settings › Dictation › Specialty words)

var fieldFails = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { fieldFails += 1; print("FAIL fields: \(name)" + { let d = detail(); return d.isEmpty ? "" : " (\(d))" }()) }
}

// Mapping: each field's categories, and every other category in the file is general.
let general: Set<String> = ["AI", "Software", "Platforms", "Devices", "Internet", "Creative tools", "Brands", "Finance", "Places",
                            "People", "General"]
check("Film and video is Film production", VocabularyField(category: "Film and video") == .film)
check("Business is Business and marketing", VocabularyField(category: "Business") == .business)
check("Medical is Medical", VocabularyField(category: "Medical") == .medical)
check("Legal is Legal", VocabularyField(category: "Legal") == .legal)
check("Bible and faith is Bible and faith", VocabularyField(category: "Bible and faith") == .faith)
check("general categories have no field", general.allSatisfy { VocabularyField(category: $0) == nil })
let unknown = Set(terms.map(\.category)).filter { VocabularyField(category: $0) == nil && !general.contains($0) }
check("every category is a field's or general", unknown.isEmpty, "\(unknown.sorted())")
for f in VocabularyField.allCases {
    let mine = terms.filter { $0.field == f }
    check("\(f.title) has terms", mine.count >= 30, "\(mine.count)")
    // The line under the switch names the field's own terms.
    let named = f.examples.replacingOccurrences(of: ", and more", with: "").components(separatedBy: ", ")
    let missing = named.filter { n in !mine.contains { $0.term.lowercased() == n.lowercased() } }
    check("\(f.title)'s example line uses its own terms", missing.isEmpty, "\(missing)")
    check("\(f.title)'s key is its own", f.key == "vocabulary.field.\(f.rawValue)")
}

// Defaults: film and business on, medical, legal, and Bible and faith off.
let suite = "verbose.vocabulary-tests.\(UUID().uuidString)"
let d = UserDefaults(suiteName: suite)!
defer { d.removePersistentDomain(forName: suite) }
check("film and business start on", VocabularyField.film.isOn(in: d) && VocabularyField.business.isOn(in: d))
check("specialty fields start off", VocabularyField.off(in: d) == [.medical, .legal, .faith], "\(VocabularyField.off(in: d))")
check("nothing is chosen at first", VocabularyField.chosen(in: d).isEmpty)

func activeRules(_ off: Set<VocabularyField>, on: Bool = true, disabled: Set<String> = []) -> [BuiltInVocabulary.Rule] {
    BuiltInVocabulary.rules(for: BuiltInVocabulary.active(terms, on: on, disabled: disabled, fieldsOff: off))
}
let byDefault = BuiltInVocabulary.active(terms, on: true, disabled: [], fieldsOff: VocabularyField.off(in: d))
check("by default no medical, legal, or Bible and faith term runs",
      !byDefault.contains { [.medical, .legal, .faith].contains($0.field) })
check("by default film, business, and general terms run",
      byDefault.contains { $0.field == .film } && byDefault.contains { $0.field == .business } && byDefault.contains { $0.term == "ChatGPT" })
check("the master switch turns every field off", BuiltInVocabulary.active(terms, on: false, disabled: [], fieldsOff: []).isEmpty)
check("a term turned off stays off with its field on",
      !BuiltInVocabulary.active(terms, on: true, disabled: ["Ozempic"], fieldsOff: []).contains { $0.term == "Ozempic" })

// Real sentences per field: each changes only with its field on, and the master switch stops it.
let fieldCases: [(VocabularyField, String, String)] = [
    (.film, "We shot it on the arri alexa with dnxhr proxies.", "We shot it on the ARRI Alexa with DNxHR proxies."),
    (.film, "Grade it from s log 3 to rec 709.", "Grade it from S-Log3 to Rec. 709."),
    (.business, "Our roas dropped but ebitda held.", "Our ROAS dropped but EBITDA held."),
    (.medical, "Start metforman 500 mg twice a day.", "Start metformin 500 mg twice a day."),
    (.medical, "She switched from ozempic to zep bound in May.", "She switched from Ozempic to Zepbound in May."),
    (.medical, "History of copd and crohns disease.", "History of COPD and Crohn's disease."),
    (.legal, "The court found a prima facia case.", "The court found a prima facie case."),
    (.legal, "We filed a motion under 12 b 6 and a writ of habeus corpus.", "We filed a motion under 12(b)(6) and a writ of habeas corpus."),
    (.legal, "She does pro bonus work on weekends.", "She does pro bono work on weekends."),
    (.legal, "It's a claim for tortuous interference.", "It's a claim for tortious interference."),
    (.faith, "Read phillipians 4 and galations 5 tonight.", "Read Philippians 4 and Galatians 5 tonight."),
    (.faith, "The sermon was on habbakuk and nebuchadnezzer.", "The sermon was on Habakkuk and Nebuchadnezzar."),
    (.faith, "Turn to hosier chapter 6.", "Turn to Hosea chapter 6."),
]
for (f, said, fixed) in fieldCases {
    let on = BuiltInVocabulary.fix(said, rules: activeRules([]))
    check("\(f.title) fixes “\(said)”", on == fixed, on)
    let off = BuiltInVocabulary.fix(said, rules: activeRules([f]))
    check("\(f.title) off leaves “\(said)”", off == said, off)
    check("master off leaves “\(said)”", BuiltInVocabulary.fix(said, rules: activeRules([], on: false)) == said)
}

// Ordinary sentences that must stay with every field on.
let ordinary = [
    "The Philippines meeting moved to Thursday.",
    "We walked down Hosier Lane after lunch.",
    "That was the tightest call of the season.",
    "The trail was tortuous and slow.",
    "We have this corpus database for the model.",
    "The pro bonus account pays out in March.",
    "The war dire straits ended in 1945.",
    "The Hashimotos came over for dinner.",
    "Gillian Barre joined the team in May.",
    "Their imminent arrival changed the plan.",
    "The systolic number was a little high.",
    "He found a millennialism that fit his view.",
    "She shared a few revelations about the merger.",
]
let all = activeRules([])
for s in ordinary {
    let got = BuiltInVocabulary.fix(s, rules: all)
    check("“\(s)” stays", got == s, got)
}

// Syncing: the switches you set travel; the ones you never touched don't.
d.set(true, forKey: VocabularyField.medical.key)
d.set(false, forKey: VocabularyField.film.key)
check("chosen lists only the switches set", VocabularyField.chosen(in: d) == ["medical": true, "film": false], "\(VocabularyField.chosen(in: d))")
check("a field turned on runs", VocabularyField.medical.isOn(in: d) && !VocabularyField.off(in: d).contains(.medical))
let other = UserDefaults(suiteName: suite + ".other")!
defer { other.removePersistentDomain(forName: suite + ".other") }
VocabularyField.apply(VocabularyField.chosen(in: d).merging(["unknown": true]) { a, _ in a }, to: other)
check("the other device takes the same switches", VocabularyField.off(in: other) == VocabularyField.off(in: d), "\(VocabularyField.off(in: other))")

if fieldFails > 0 { print("\(fieldFails) specialty field check(s) failed"); exit(1) }
print("Specialty fields: mapping, defaults, switches, \(fieldCases.count) field sentences, and \(ordinary.count) ordinary sentences pass.")
