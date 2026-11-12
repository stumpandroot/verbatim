import Foundation

// A click, a highlight, or a double-click on a transcript line (Verbatim/Model/WordPick.swift): the word at a place in
// the text, when it was said, the phrase a fix starts from, and what counts as a double-click. Then the sources: a
// click moves the playhead without starting playback, and a double-click and a highlighted phrase open the one Fix
// box. Reads the Swift sources from the mac/ folder given as the first argument. Not part of any app target; run
// mac/tools/test-word-pick.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let line = "Hi, this is Jordan from Stompin'root."
let words = WordPick.words(line)
check("words: split on spaces", words.map(\.text) == ["Hi,", "this", "is", "Jordan", "from", "Stompin'root."], "\(words.map(\.text))")
check("words: punctuation at the ends is dropped, inside it stays", words.map(\.core) == ["Hi", "this", "is", "Jordan", "from", "Stompin'root"])
check("words: each knows where it sits", words[0].range == 0..<3 && words[1].range == 4..<8 && words[5].range == 24..<37, "\(words.map(\.range))")
check("words: the letters' place leaves the punctuation out", words[0].coreRange == 0..<2 && words[5].coreRange == 24..<36)
check("words: none in an empty line", WordPick.words("").isEmpty && WordPick.words("   ").isEmpty)
check("words: runs of spaces and new lines split once", WordPick.words("a  b\nc").map(\.text) == ["a", "b", "c"])
let accented = WordPick.words("café 🙂 naïve")
check("words: places count as the layout counts them (UTF-16)", accented[1].range == 5..<7 && accented[2].range == 8..<13, "\(accented.map(\.range))")

check("index: a place inside a word is that word", WordPick.index(at: 5, in: words) == 1 && WordPick.index(at: 30, in: words) == 5)
check("index: a word's first and last letters are that word", WordPick.index(at: 4, in: words) == 1 && WordPick.index(at: 7, in: words) == 1)
check("index: a space goes to the nearer word", WordPick.index(at: 3, in: words) == 0 || WordPick.index(at: 3, in: words) == 1)
check("index: past the end is the last word", WordPick.index(at: 500, in: words) == 5)
check("index: before the start is the first word", WordPick.index(at: -4, in: words) == 0)
check("index: no words, no word", WordPick.index(at: 0, in: []) == nil)

let timed: [Double?] = [9.0, 9.4, 9.7, 10.0, 11.2, 11.6]
func time(_ i: Int, _ t: [Double?] = timed, start: Double = 9, end: Double = 13, duration: Double = 1423) -> Double {
    WordPick.time(word: i, words: words, timed: t, lineStart: start, lineEnd: end, duration: duration)
}
check("time: a timed word plays from its own start", time(3) == 10.0 && time(5) == 11.6)
check("time: the first word is the line's start", time(0) == 9.0 && time(0, []) == 9.0)
let guess = time(5, [])
check("time: without timings, a word's place in the line gives the moment", guess > 11 && guess < 13, "\(guess)")
check("time: without timings, later words are later", time(1, []) < time(3, []) && time(3, []) < time(5, []))
check("time: a word with no timing among timed ones is placed the same way", time(3, [9.0, nil, nil, nil, 11.2, 11.6]) > 9 && time(3, [9.0, nil, nil, nil, 11.2, 11.6]) < 13)
check("time: a timing outside the line is kept inside it", time(2, [9, 9, 99, 9, 9, 9]) == 13 && time(2, [9, 9, 1, 9, 9, 9]) == 9)
check("time: never past the end of the recording", time(5, timed, duration: 10) == 9.95)
check("time: a word that isn't there gives the line's start", time(40) == 9.0 && time(-1) == 9.0)
check("time: a line with no length gives its start", time(4, [], start: 9, end: 9) == 9.0)

check("phrase: one word is its letters", WordPick.phrase(5, 5, words: words, text: line) == "Stompin'root")
check("phrase: several words keep what's between them", WordPick.phrase(3, 5, words: words, text: line) == "Jordan from Stompin'root")
check("phrase: picked backwards is the same phrase", WordPick.phrase(5, 3, words: words, text: line) == "Jordan from Stompin'root")
check("phrase: punctuation inside stays, at the ends goes", WordPick.phrase(0, 1, words: words, text: line) == "Hi, this")
let dashed = "Well — maybe."
check("phrase: a lone dash is nothing to fix", WordPick.phrase(1, 1, words: WordPick.words(dashed), text: dashed) == nil)
check("phrase: a dash at the end is left off", WordPick.phrase(0, 1, words: WordPick.words(dashed), text: dashed) == "Well")
check("phrase: words that aren't there give nothing", WordPick.phrase(4, 9, words: words, text: line) == nil)

check("double-click: a second click soon after, in the same place", WordPick.isDoubleClick(sinceLast: 0.2, distance: 1, interval: 0.5))
check("double-click: not after the interval", !WordPick.isDoubleClick(sinceLast: 0.7, distance: 1, interval: 0.5))
check("double-click: not somewhere else on the line", !WordPick.isDoubleClick(sinceLast: 0.2, distance: 40, interval: 0.5))

let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func read(_ path: String) -> String {
    guard let s = try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8) else {
        print("FAIL  can't read \(path)"); exit(1)
    }
    return s
}
let view = read("Verbatim/Views/SegmentLine.swift")
let pick = read("Verbatim/Views/LinePick.swift")
check("source: a click on a line moves the playhead", pick.contains("app.player.seek(to:"))
check("source: a click on a line never starts playback", !pick.contains("player.play(from") && !pick.contains("player.toggle()"))
check("source: the line's text takes clicks and highlights through LinePick", view.contains(".linePick("))
check("source: the line's own click no longer plays", !view.contains(".onTapGesture {"))
check("source: a double-click and a phrase open the one Fix box", view.contains("startFix(") && view.components(separatedBy: "Heard as").count == 2)
check("source: the engine's words can't be fixed", pick.contains("guard editable"))
let screen = read("Verbatim/Views/TranscriptView.swift")
check("source: Return opens Fix for the highlighted phrase", screen.contains(".onKeyPress(.return)") && screen.contains("PhrasePick.shared"))
let player = read("Verbatim/Audio/Player.swift")
check("source: a seek before the audio opens still shows on the playhead", player.contains("pendingStart = max(0, t); time = max(0, t)"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
