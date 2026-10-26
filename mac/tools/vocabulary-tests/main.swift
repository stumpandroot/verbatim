import Foundation

// Runs the app's own BuiltInVocabulary.swift and EverydayFixes.swift (compiled with this file by
// test-vocabulary.sh) on the cases vocab_check.py wrote with its results, so the gate's Python matching and the
// app's NSRegularExpression matching can't drift apart. The stubs below stand in for the app types those files use.
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
