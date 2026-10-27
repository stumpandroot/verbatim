import Foundation

// The iPhone's system surfaces after the build 228 review (W-01 to W-10). Not part of any app target; run
// mac/tools/test-live-activity.sh, which passes the mac folder as the first argument.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let mac = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func source(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: mac + "/" + path, encoding: .utf8) else {
        check("reads \(path)", false); return ""
    }
    return s
}
func matches(_ pattern: String, in s: String) -> [[String]] {
    let re = try! NSRegularExpression(pattern: pattern)
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}

// MARK: Contrast (WCAG), from Tokens.swift

func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func luminance(_ h: UInt32) -> Double {
    0.2126 * channel(Double((h >> 16) & 0xFF) / 255) + 0.7152 * channel(Double((h >> 8) & 0xFF) / 255) + 0.0722 * channel(Double(h & 0xFF) / 255)
}
func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let x = luminance(a), y = luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
/// `top` at `alpha` over `bottom`.
func over(_ top: UInt32, _ alpha: Double, _ bottom: UInt32) -> UInt32 {
    func c(_ shift: UInt32) -> UInt32 {
        let t = Double((top >> shift) & 0xFF), b = Double((bottom >> shift) & 0xFF)
        return UInt32((t * alpha + b * (1 - alpha)).rounded()) << shift
    }
    return c(16) | c(8) | c(0)
}
func ratio(_ x: Double) -> String { String(format: "%.2f:1", x) }

let tokens = source("Verbatim/Views/Tokens.swift")
func hex(_ name: String) -> UInt32? {
    guard let m = matches(name + #": UInt32 = 0x([0-9A-Fa-f]{6})"#, in: tokens).first else { return nil }
    return UInt32(m[1], radix: 16)
}
func colorHex(_ name: String) -> UInt32? {
    guard let m = matches("static let " + name + #" = Color\(hex: 0x([0-9A-Fa-f]{6})\)"#, in: tokens).first else { return nil }
    return UInt32(m[1], radix: 16)
}

if let paper = hex("paperHex"), let ink = hex("inkHex"), let persimmon = hex("persimmonHex"), let dark = hex("darkPaperHex"),
   let muteOnPaper = colorHex("muteOnPaper"), let muteOnInk = colorHex("muteOnInk"),
   let dimAlpha = matches(#"static let onBlackDim = Color\(hex: paperHex\)\.opacity\(([0-9.]+)\)"#, in: tokens).first.flatMap({ Double($0[1]) }),
   let accentDark = hex("nativeAccentDarkHex"), let accentLight = hex("nativeAccentLightHex"),
   let onAccentDark = hex("onAccentDarkHex"), let onAccentLight = hex("onAccentLightHex") {
    // W-08: the Lock Screen activities on paper (light) and on the dark paper (dark), ActivitySkin.swift.
    check("Lock Screen, light: ink on paper", contrast(ink, paper) >= 7, ratio(contrast(ink, paper)))
    let dimLight = over(ink, 0.8, paper)
    check("Lock Screen, light: the line under the title (ink at 80%) keeps 4.5:1", contrast(dimLight, paper) >= 4.5, ratio(contrast(dimLight, paper)))
    check("Lock Screen, light: mute keeps 4.5:1", contrast(muteOnPaper, paper) >= 4.5, ratio(contrast(muteOnPaper, paper)))
    check("Lock Screen, dark: the dark paper is the app's near-black green", dark == 0x18241F && tokens.contains("static let paper = dyn(paperHex, 0x18241F)"))
    check("Lock Screen, dark: paper text on the dark paper", contrast(paper, dark) >= 7, ratio(contrast(paper, dark)))
    let dimDark = over(paper, dimAlpha, dark)
    check("Lock Screen, dark: the line under the title (onBlackDim) keeps 4.5:1", contrast(dimDark, dark) >= 4.5, ratio(contrast(dimDark, dark)))
    check("Lock Screen, dark: mute keeps 4.5:1", contrast(muteOnInk, dark) >= 4.5, ratio(contrast(muteOnInk, dark)))
    check("Stop: ink on persimmon is 4.45:1, so its word is semibold 14 or larger", contrast(ink, persimmon) >= 4.4, ratio(contrast(ink, persimmon)))
    check("the persimmon Stop stands out from the dark paper", contrast(persimmon, dark) >= 3, ratio(contrast(persimmon, dark)))
    // W-01: text on the Native accent (the keyboard's Start, Tap to talk, Done, and the widget's New Thought pill).
    check("Native accent, dark: black text keeps 7:1", contrast(onAccentDark, accentDark) >= 7, ratio(contrast(onAccentDark, accentDark)))
    check("Native accent, dark: white would fail 3:1, so it isn't used", contrast(0xFFFFFF, accentDark) < 3, ratio(contrast(0xFFFFFF, accentDark)))
    check("Native accent, light: white text keeps 4.5:1", contrast(onAccentLight, accentLight) >= 4.5, ratio(contrast(onAccentLight, accentLight)))
} else {
    check("Tokens.swift has the colors the Live Activities and the keyboard use", false)
}

// MARK: W-04: timers that fit past an hour

let monoEm = 1233.0 / 2048
for size in [12.0, 13, 15] {
    let w = Ribbon.timerWidth(size: size, showsHours: true)
    check("a \(Int(size)) pt timer's frame holds 0:00:00", w >= size * monoEm * 7, "\(w)")
}
check("the compact Island's timer stays narrow", Ribbon.timerWidth(size: 13, showsHours: true) <= 60, "\(Ribbon.timerWidth(size: 13, showsHours: true))")
check("without hours, 00:00", Ribbon.timerWidth(size: 12, showsHours: false) >= 12 * monoEm * 5)
let recording = source("VerbatimWidgets/RecordingLiveActivity.swift")
check("every recording timer's frame uses the timer width", recording.components(separatedBy: "RecordingTimer.width(").count - 1 >= 3
      && matches(#"RecordingTimer\(state: [^)]*\)[^\n]*\n[^\n]*\.frame\(width: [0-9]"#, in: recording).isEmpty)

// MARK: W-06: capsules

let session = source("VerbatimWidgets/VerbatimWidgets.swift")
for (name, s) in [("the session's", session), ("the recording's", recording)] {
    check("\(name) Live Activity buttons are capsules", !s.contains("RoundedRectangle(cornerRadius: Radius.row"))
}
check("one Stop for a voice note and a thought", !recording.contains("ThoughtStopButton") && recording.contains("StopButton(wide: true, hint: thoughtStopHint)"))

// MARK: W-07: Resume on a paused thought

if let lock = recording.range(of: "private struct ThoughtLockScreen") {
    let body = String(recording[lock.lowerBound...].prefix(2400))
    check("a paused thought on the Lock Screen offers Resume", body.contains("if state.isPaused { PauseButton("))
}
check("Mark stays on the voice note's Lock Screen and Island", recording.contains("MarkButton(tone: .lock(skin), source: \"lockScreen\")")
      && recording.contains("MarkButton(tone: .island, source: \"island\")"))

// MARK: W-08: Lock Screen follows light and dark

for (name, s) in [("session", session), ("recording", recording)] {
    check("the \(name) Lock Screen reads its appearance", s.contains("ActivityLockSurface") && !s.contains("activityBackgroundTint(Ink.paperFixed)"))
}
let skin = source("VerbatimWidgets/ActivitySkin.swift")
check("the skin uses the dark paper and paper text in dark", skin.contains("dark ? Ink.darkPaperFixed : Ink.paperFixed") && skin.contains("dark ? Ink.onBlack : Ink.inkFixed"))

// MARK: W-03: label in name

let lines = session.components(separatedBy: "\n")
var labelled = 0
for (i, line) in lines.enumerated() {
    guard let title = matches(#"RibbonButton\(title: "([^"]+)""#, in: line).first?[1] else { continue }
    for next in lines[(i + 1)..<min(i + 2, lines.count)] {
        if let label = matches(#"\.accessibilityLabel\("([^"]+)"\)"#, in: next).first?[1] {
            labelled += 1
            check("\"\(title)\"'s label starts with its word (\(label))", label.hasPrefix(title))
        }
    }
}
check("the session's buttons were read", labelled >= 3, "\(labelled)")
check("Done has no label of its own (its word is the label) and one hint", !session.contains("Stop and copy") && Ribbon.doneHint.hasPrefix("Stops listening"))

// MARK: W-10: custom symbols and the Action button's name

let fm = FileManager.default
let catalog = mac + "/VerbatimWidgets/Assets.xcassets"
let sets = Set(((try? fm.contentsOfDirectory(atPath: catalog)) ?? []).filter { $0.hasSuffix(".symbolset") }.map { String($0.dropLast(10)) })
check("the controls' symbols are exported", ["bars", "record", "dictate", "captions", "thought", "mark", "marked"].allSatisfy(sets.contains), "\(sets.sorted())")
let phoneSets = Set(((try? fm.contentsOfDirectory(atPath: mac + "/VerbatimPhone/Assets.xcassets")) ?? []).filter { $0.hasSuffix(".symbolset") }.map { String($0.dropLast(10)) })
check("the app's catalog has the same symbols", sets == phoneSets, "\(sets.symmetricDifference(phoneSets).sorted())")
let widgetFiles = ((try? fm.contentsOfDirectory(atPath: mac + "/VerbatimWidgets")) ?? []).filter { $0.hasSuffix(".swift") }
var named = Set<String>()
for f in widgetFiles {
    let s = source("VerbatimWidgets/" + f)
    for m in matches(#"(?:Image\(|image: )"([a-z]+)""#, in: s) { named.insert(m[1]) }
}
check("every custom image the widgets name is in the catalog", named.isSubset(of: sets), "\(named.subtracting(sets).sorted())")
let controls = source("VerbatimWidgets/StartSessionWidgets.swift")
check("Control Center shows one family: no SF Symbols on the controls", !controls.contains("systemImage:"))
check("before the app names it, the control says Verbose action", Ribbon.actionControl(nil) == ("Verbose action", "bars") && Ribbon.actionControl("") == ("Verbose action", "bars"))
for choice in Ribbon.ActionChoice.allCases {
    let c = Ribbon.actionControl(choice.rawValue)
    check("the control is named \(choice.title)", c.title == choice.title && sets.contains(c.symbol), "\(c)")
}
check("Record or mark shows the Mark symbol", Ribbon.actionControl("recordOrMark").symbol == "mark")
check("an unknown value falls back to Dictate, as the button does", Ribbon.actionControl("bogus").title == "Dictate")
check("the control's kind is unchanged, so an assigned Action button keeps it", Ribbon.actionControlKind == "co.stumpandroot.verbatim.ios.control.action")
check("the gallery name matches Settings › Action button's steps", controls.contains(".displayName(\"\(Ribbon.actionControlName)\")")
      && source("VerbatimPhone/ActionButtonScreen.swift").contains("choose \(Ribbon.actionControlName)."))
check("the app mirrors the choice and reloads the control", source("VerbatimPhone/ActionButtonScreen.swift").contains("reloadControls(ofKind: Ribbon.actionControlKind)")
      && source("VerbatimPhone/PhoneApp.swift").contains("ActionChoiceMirror.sync()"))

// MARK: W-09: widget names

let home = source("VerbatimWidgets/HomeWidgets.swift")
var names: [String] = []
for s in [home, controls] { names += matches(#"\.configurationDisplayName\("([^"]+)"\)"#, in: s).map { $0[1] } }
check("every widget has a gallery name", names.count >= 7, "\(names)")
check("widget names are unique", Set(names).count == names.count, "\(names)")
let proper: Set<String> = ["Verbose", "Lock", "Screen"]
for n in names {
    let rest = n.split(separator: " ").dropFirst()
    check("\"\(n)\" is sentence case", rest.allSatisfy { w in proper.contains(String(w)) || !(w.first?.isUppercase ?? false) })
}
check("Native draws Today's thoughts in sentence case too", !home.contains("\"Today's Thoughts\""))

// MARK: W-05 and W-01: type sizes and the keyboard's accent text

var small: [String] = []
for f in widgetFiles {
    let s = source("VerbatimWidgets/" + f)
    for (i, line) in s.components(separatedBy: "\n").enumerated() where !matches(#"Ink\.mono\(([0-9]|1[01])(\.[0-9]+)?[,)]"#, in: line).isEmpty {
        small.append("\(f):\(i + 1)")
    }
}
let keyboard = source("VerbatimKeyboard/KeyboardView.swift")
for (i, line) in keyboard.components(separatedBy: "\n").enumerated() where !matches(#"KB\.mono\(([0-9]|1[01])(\.[0-9]+)?[,)]"#, in: line).isEmpty {
    small.append("KeyboardView.swift:\(i + 1)")
}
check("widgets and the keyboard never set mono under 12 pt", small.isEmpty, small.joined(separator: ", "))
check("no faded ink on the Record panel", !home.contains("skin.onPanel.opacity(0.75)") && !home.contains("skin.onPanel.opacity(0.85)"))
if let panel = home.range(of: "private struct VerboseRecordPanel") {
    let body = String(home[panel.lowerBound...].prefix(1600))
    check("the small Record widget says what it records (a voice note), not a thought",
          body.contains("Text(\"Voice note\")") && !body.contains("Text(\"a thought\")"))
} else {
    check("the small Record widget's Verbose panel exists", false)
}
// The Native redesign (October 27, 2026): the keyboard's accent is system blue, like the system keyboard's return key,
// with white on it (Apple's own filled keys); the old rule against white held only on the dark persimmon (2.8:1).
check("the keyboard's filled Native button is white on system blue", keyboard.contains("style == .filled ? Color.white : KB.nativeAccent")
      && keyboard.contains("static let nativeAccent = Color(uiColor: .systemBlue)") && !keyboard.contains("Ink.nativeAccent"))
if let done = keyboard.range(of: "private struct DictateDone") {
    let body = String(keyboard[done.lowerBound...].prefix(1400))
    check("the keyboard's Done reads as Done to VoiceOver", body.contains(".accessibilityLabel(\"Done\")") && body.contains(".accessibilityHint("))
} else {
    check("the keyboard has DictateDone", false)
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
