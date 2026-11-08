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
/// A refined tone's light and dark values, from the table in Tokens.swift (`static let paper = Tone(0x…, 0x…)`).
func tone(_ name: String) -> (light: UInt32, dark: UInt32)? {
    guard let m = matches("static let " + name + #" = Tone\(0x([0-9A-Fa-f]{6}), 0x([0-9A-Fa-f]{6})"#, in: tokens).first,
          let l = UInt32(m[1], radix: 16), let d = UInt32(m[2], radix: 16) else { return nil }
    return (l, d)
}

if let paperTone = tone("paper"), let inkTone = tone("ink"), let persimmonTone = tone("persimmon"), let muteTone = tone("mute"),
   let onFillTone = tone("onFill"),
   let dimAlpha = matches(#"static let onBlackDim = paperFixed\.opacity\(([0-9.]+)\)"#, in: tokens).first.flatMap({ Double($0[1]) }) {
    let paper = paperTone.light, ink = inkTone.light, persimmon = persimmonTone.light, dark = paperTone.dark
    // The fixed values the Live Activities use are the table's (Tokens.swift, "Fixed values").
    check("the fixed values come from the table", tokens.contains("static let paperFixed = Color(hex: RefinedHex.paper.light)")
          && tokens.contains("static let darkPaperFixed = Color(hex: RefinedHex.paper.dark)")
          && tokens.contains("static let muteOnPaper = Color(hex: RefinedHex.mute.light)")
          && tokens.contains("static let muteOnInk = Color(hex: RefinedHex.mute.dark)"))
    // W-08: the Lock Screen activities on paper (light) and on the dark paper (dark), ActivitySkin.swift.
    check("Lock Screen, light: ink on paper", contrast(ink, paper) >= 7, ratio(contrast(ink, paper)))
    let dimLight = over(ink, 0.8, paper)
    check("Lock Screen, light: the line under the title (ink at 80%) keeps 4.5:1", contrast(dimLight, paper) >= 4.5, ratio(contrast(dimLight, paper)))
    check("Lock Screen, light: mute keeps 4.5:1", contrast(muteTone.light, paper) >= 4.5, ratio(contrast(muteTone.light, paper)))
    check("Lock Screen, dark: the dark paper is the app's near-black green", dark == 0x18241F)
    check("Lock Screen, dark: paper text on the dark paper", contrast(paper, dark) >= 7, ratio(contrast(paper, dark)))
    let dimDark = over(paper, dimAlpha, dark)
    check("Lock Screen, dark: the line under the title (onBlackDim) keeps 4.5:1", contrast(dimDark, dark) >= 4.5, ratio(contrast(dimDark, dark)))
    check("Lock Screen, dark: mute keeps 4.5:1", contrast(muteTone.dark, dark) >= 4.5, ratio(contrast(muteTone.dark, dark)))
    check("Stop: ink on persimmon keeps 4.5:1", contrast(ink, persimmon) >= 4.5, ratio(contrast(ink, persimmon)))
    check("the persimmon Stop stands out from the dark paper", contrast(persimmon, dark) >= 3, ratio(contrast(persimmon, dark)))
    // W-01: text on the persimmon fill (the keyboard's Start, Tap to talk, Done, and the widgets' New thought pill).
    check("persimmon fill, light: its ink keeps 4.5:1", contrast(onFillTone.light, persimmonTone.light) >= 4.5, ratio(contrast(onFillTone.light, persimmonTone.light)))
    check("persimmon fill, dark: its ink keeps 4.5:1", contrast(onFillTone.dark, persimmonTone.dark) >= 4.5, ratio(contrast(onFillTone.dark, persimmonTone.dark)))
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
check("one Stop for a voice note and a thought", !recording.contains("ThoughtStopButton") && recording.contains("StopButton(wide: true, hint: thoughtStopHint"))

// MARK: W-07: Resume on a paused thought

if let lock = recording.range(of: "private struct ThoughtLockScreen") {
    let body = String(recording[lock.lowerBound...].prefix(2400))
    check("a paused thought on the Lock Screen offers Resume", body.contains("if state.isPaused { PauseButton("))
}
check("Mark stays on the voice note's Lock Screen and Island", recording.contains("MarkButton(tone: .lock(skin), source: \"lockScreen\")")
      && recording.contains("MarkButton(tone: .island, source: \"island\")"))

// MARK: W-08: Lock Screen follows light and dark

for (name, s) in [("session", session), ("recording", recording)] {
    check("the \(name) Lock Screen reads its appearance", s.contains("ActivityLockSurface") && !s.contains("activityBackgroundTint(Refined.paperFixed)"))
}
let skin = source("VerbatimWidgets/ActivitySkin.swift")
check("the skin uses the dark paper and paper text in dark", skin.contains("dark ? Refined.darkPaperFixed : Refined.paperFixed") && skin.contains("dark ? Refined.onBlack : Refined.inkFixed"))

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
check("Today's thoughts is sentence case", !home.contains("\"Today's Thoughts\""))

// MARK: W-05 and W-01: type sizes and the keyboard's accent text

var small: [String] = []
for f in widgetFiles {
    let s = source("VerbatimWidgets/" + f)
    for (i, line) in s.components(separatedBy: "\n").enumerated() where !matches(#"Refined\.mono\(([0-9]|1[01])(\.[0-9]+)?[,)]"#, in: line).isEmpty {
        small.append("\(f):\(i + 1)")
    }
}
let keyboard = source("VerbatimKeyboard/KeyboardView.swift")
for (i, line) in keyboard.components(separatedBy: "\n").enumerated() where !matches(#"KB\.mono\(([0-9]|1[01])(\.[0-9]+)?[,)]"#, in: line).isEmpty {
    small.append("KeyboardView.swift:\(i + 1)")
}
check("widgets and the keyboard never set mono under 12 pt", small.isEmpty, small.joined(separator: ", "))
check("no faded ink on the Record panel", !home.contains("skin.onPanel.opacity(0.75)") && !home.contains("skin.onPanel.opacity(0.85)"))
if let panel = home.range(of: "private struct RecordPanel") {
    let body = String(home[panel.lowerBound...].prefix(1600))
    check("the small Record widget says what it records (a voice note), not a thought",
          body.contains("Text(\"Voice note\")") && !body.contains("Text(\"a thought\")"))
} else {
    check("the small Record widget's panel exists", false)
}
// The one look (DESIGN.md §13): the keyboard's action, dictation, is the persimmon fill with ink on it (bold 16 or
// larger, as ink on persimmon is 4.45:1), and the outline style takes the accent's text color.
check("the keyboard's filled dictate button is ink on persimmon", keyboard.contains("style == .filled ? KB.inkFixed : Refined.accentText")
      && keyboard.contains("static let dictate = Refined.persimmon") && keyboard.contains("static let inkFixed = Refined.onFill"))
if let done = keyboard.range(of: "private struct DictateDone") {
    let body = String(keyboard[done.lowerBound...].prefix(1400))
    check("the keyboard's Done reads as Done to VoiceOver", body.contains(".accessibilityLabel(\"Done\")") && body.contains(".accessibilityHint("))
} else {
    check("the keyboard has DictateDone", false)
}

// MARK: SF-01, GPT-31: a Live Activity whose updates stop says so (LiveFreshness, RibbonRules.swift)

for c in LiveFreshness.cadences {
    check("stale after \(Int(LiveFreshness.staleAfter)) s covers \(LiveFreshness.missedUpdates) missed updates every \(c) s", LiveFreshness.covers(cadence: c))
}
check("the threshold isn't longer than a minute (it still tells you soon)", LiveFreshness.staleAfter <= 60)
check("the threshold would fail a cadence it can't cover", !LiveFreshness.covers(cadence: LiveFreshness.staleAfter))
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
check("a live update goes stale staleAfter later", LiveFreshness.staleDate(now: t0, holdsStill: false) == t0.addingTimeInterval(LiveFreshness.staleAfter))
check("paused content holds still: no stale date", LiveFreshness.staleDate(now: t0, holdsStill: true) == nil)
check("stale shows only for live content", LiveFreshness.showsStale(isStale: true, final: false) && !LiveFreshness.showsStale(isStale: true, final: true)
      && !LiveFreshness.showsStale(isStale: false, final: false))
for w in [LiveFreshness.recordingTitle, LiveFreshness.sessionTitle, LiveFreshness.detail, LiveFreshness.compact] {
    check("stale words never claim it stopped, and follow the copy rules: \(w)", !w.lowercased().contains("stop") && !w.lowercased().contains("ended")
          && !w.contains("\u{2014}") && !w.contains("!"))
}
let presence = source("VerbatimPhone/RecordingPresence.swift")
let sessionApp = source("VerbatimPhone/KeyboardSession.swift")
check("the recording's updates carry a stale date", presence.contains("staleDate: LiveFreshness.staleDate(now: Date(), holdsStill: state.isPaused || state.saved)")
      && presence.contains("await a.update(content(state))") && presence.contains("content: content(state), pushType: nil"))
check("the recording ticks at the cadence the threshold was checked against",
      presence.contains("startTicker(every: thought ? LiveFreshness.thoughtTick : LiveFreshness.voiceNoteTick)"))
check("the session's updates carry a stale date", sessionApp.contains("staleDate: LiveFreshness.staleDate(now: Date(), holdsStill: state.shown == .paused)")
      && sessionApp.contains("await a.update(activityContent(state))") && sessionApp.contains("content: activityContent(activityState())"))
check("the session refreshes its Live Activity while nothing else changes",
      sessionApp.contains("if Date().timeIntervalSince(lastActivityPush) >= LiveFreshness.sessionRefresh { updateActivity() }"))
check("the session pushes its level at the cadence the threshold was checked against",
      sessionApp.contains("Date().timeIntervalSince(lastLevelPush) >= LiveFreshness.sessionLevelTick {"))
for (name, s, title) in [("recording", recording, "recordingTitle"), ("session", session, "sessionTitle")] {
    check("the \(name) Lock Screen draws the stale presentation", s.contains("LiveFreshness.showsStale(isStale: context.isStale")
          && s.contains("StaleLockScreen(title: LiveFreshness.\(title), skin: skin)"))
    check("the \(name) Island draws it in every presentation", s.contains("StaleIslandBottom(title: LiveFreshness.\(title))")
          && s.contains("StaleCompactWord(title: LiveFreshness.\(title))") && s.contains("label: LiveFreshness.\(title))"))
}
if let r = skin.range(of: "struct StaleLockScreen") {
    let body = String(skin[r.lowerBound...].prefix(1200))
    check("the stale Lock Screen has no timer and no buttons", !body.contains("Timer") && !body.contains("Button") && !body.contains("timerInterval"))
} else {
    check("StaleLockScreen exists", false)
}

// MARK: SF-09: a thought saved in the background plays no alert

check("no Live Activity update sets off an alert (a saved thought plays no sound)",
      !presence.contains("alertConfiguration") && !sessionApp.contains("alertConfiguration"))

// MARK: SF-02: every view that draws your words is marked private

/// The struct bodies (from `struct Name` to the next top-level declaration) in a widget source.
func structBody(_ name: String, in s: String) -> String? {
    guard let r = s.range(of: "struct \(name):") ?? s.range(of: "struct \(name) ") else { return nil }
    let rest = s[r.lowerBound...]
    let next = rest.dropFirst(8).range(of: "\n}\n")
    return String(next.map { rest[..<$0.upperBound] } ?? rest)
}
/// The source without its comments, so a note like "never reads `state.liveWords`" isn't a read.
func code(_ s: String) -> String {
    s.components(separatedBy: "\n").map { l in l.range(of: "//").map { String(l[..<$0.lowerBound]) } ?? l }.joined(separator: "\n")
}
var wordViews = 0
for (file, s) in [("RecordingLiveActivity.swift", code(recording)), ("VerbatimWidgets.swift", code(session))] {
    // Words reach a view as `if let line = s.words` (a thought) or `s.liveWords` (a session's take), then `View(line: line)`.
    for m in matches(#"if let line = s\.(words|liveWords), !line\.isEmpty \{ (\w+)\(line: line\)"#, in: s) {
        wordViews += 1
        let view = m[2]
        check("\(file): \(view), which draws your words, is privacySensitive", structBody(view, in: s)?.contains(".privacySensitive()") == true)
    }
    // No other view reads them.
    let reads = matches(#"\.(liveWords)\b"#, in: s).count
    check("\(file): liveWords is read only to pass the words to a private view", reads == matches(#"s\.liveWords, !line\.isEmpty"#, in: s).count, "\(reads)")
}
check("both Islands' words views were found", wordViews == 2, "\(wordViews)")
check("the Lock Screens never read words", (structBody("RibbonLockScreen", in: code(session)).map { !$0.contains(".liveWords") } ?? false)
      && (structBody("ThoughtLockScreen", in: code(recording)).map { !$0.contains("state.words") } ?? false))
// MARK: Dynamic Type on widgets, the Lock Screen's Live Activities, the watch, and the keyboard (SF-11, SF-23, GPT-07)

/// Lines that set a fixed size on text (not an SF Symbol, not a self-counting timer in a measured frame).
func fixedText(_ text: String) -> [String] {
    text.components(separatedBy: "\n").enumerated().compactMap { i, l in
        guard let r = l.range(of: ".font(.system(size:") ?? l.range(of: ".font(Refined.serif(") ?? l.range(of: ".font(Refined.mono(") else { return nil }
        let before = l[..<r.lowerBound]
        if before.contains("Image(") || l.contains("Timer(") || l.contains("// type: fixed") { return nil }
        return "\(i + 1): \(l.trimmingCharacters(in: .whitespaces).prefix(80))"
    }
}
/// A private struct's text, from its declaration to the next top-level declaration.
func structBody(_ text: String, _ name: String) -> String {
    guard let r = text.range(of: "private struct \(name)") else { return "" }
    let rest = text[r.lowerBound...]
    return String(rest.dropFirst(10).range(of: "\nprivate ").map { rest[..<$0.lowerBound] } ?? rest)
}
for f in ["VerbatimWidgets/HomeWidgets.swift", "VerbatimWidgets/StartSessionWidgets.swift", "VerbatimWatch/WatchScreens.swift", "VerbatimWatchWidgets/WatchWidgets.swift"] {
    let bad = fixedText(source(f))
    check("\(f): text scales with Dynamic Type (scaledFont), no fixed sizes", bad.isEmpty, bad.joined(separator: " | "))
}
let recordingActivity = source("VerbatimWidgets/RecordingLiveActivity.swift"), sessionActivity = source("VerbatimWidgets/VerbatimWidgets.swift")
for (name, text) in [("RecordingLockScreen", recordingActivity), ("ThoughtLockScreen", recordingActivity), ("RibbonLockScreen", sessionActivity)] {
    let body = structBody(text, name)
    check("the Lock Screen's \(name) scales its text (only its timer keeps a measured size)", !body.isEmpty && fixedText(body).isEmpty, fixedText(body).joined(separator: " | "))
}
check("the Live Activities' Lock Screen and the widgets cap Dynamic Type so text stays inside them",
      source("VerbatimWidgets/ActivitySkin.swift").contains(".dynamicTypeSize(...DynamicTypeSize.xxLarge)")
      && source("VerbatimWidgets/HomeWidgets.swift").components(separatedBy: ".dynamicTypeSize(...DynamicTypeSize.xxLarge)").count
         == source("VerbatimWidgets/HomeWidgets.swift").components(separatedBy: ".containerBackground(for: .widget)").count)
var tiny: [String] = []
for f in ["VerbatimWidgets/HomeWidgets.swift", "VerbatimWidgets/RecordingLiveActivity.swift", "VerbatimWidgets/VerbatimWidgets.swift", "VerbatimWatch/WatchScreens.swift", "VerbatimWatchWidgets/WatchWidgets.swift"] {
    for (i, line) in source(f).components(separatedBy: "\n").enumerated() where !matches(#"scaledFont\(([0-9]|10|11\.[0-9]+)[,)]"#, in: line).isEmpty {
        tiny.append("\(f):\(i + 1)")
    }
}
check("widget, Live Activity, and watch text starts at 11 pt or more (the week's day letters), 12 for data (SF-23)", tiny.isEmpty, tiny.joined(separator: ", "))
check("the week's day letters are SF Pro 11 semibold, not 8 pt Rounded", source("VerbatimWidgets/HomeWidgets.swift").contains(".scaledFont(11, weight: .semibold).foregroundStyle(color)")
      && !source("VerbatimWidgets/HomeWidgets.swift").contains("design: .rounded"))
check("the keyboard's notices, lists, and status lines scale, capped short of the accessibility sizes (GPT-07)",
      keyboard.contains(".dynamicTypeSize(...DynamicTypeSize.xxxLarge)") && keyboard.contains("Text(meta).scaledFont(12).monospacedDigit()")
      && keyboard.contains("Text(Self.oneLine(text)).scaledFont(14.5)") && keyboard.contains("Text(i).scaledFont(12.5, weight: .medium)"))

// MARK: SF-14: the Lock Screen's Live Activities on an Always On display

check("Always On: the bars rest at the resting level while dimmed", AlwaysOn.level(0.9, dimmed: true, fallback: 0) == AlwaysOn.restingLevel
      && AlwaysOn.level(nil, dimmed: true, fallback: 0) == AlwaysOn.restingLevel)
check("Always On: lit, the bars follow the update's level, clamped, or the fallback", AlwaysOn.level(0.3, dimmed: false, fallback: 0) == 0.3
      && AlwaysOn.level(4, dimmed: false, fallback: 0) == 1 && AlwaysOn.level(nil, dimmed: false, fallback: 0.5) == 0.5
      && AlwaysOn.level(.nan, dimmed: false, fallback: 0.5) == 0.5)
check("Always On: the resting level matches Limit animation's (ActivityLevel.resting)", AlwaysOn.restingLevel == 0.5
      && source("Verbatim/Model/MotionRules.swift").contains("static let resting: Double = 0.5"))
check("Always On: Stop and the primary button fill only while lit", AlwaysOn.filled(dimmed: false) && !AlwaysOn.filled(dimmed: true))
check("the Lock Screen surface reads isLuminanceReduced into the skin", skin.contains("@Environment(\\.isLuminanceReduced) private var dimmed")
      && skin.contains("ActivitySkin(dark: scheme == .dark, dimmed: dimmed)"))
check("dimmed, the line under the title takes mute (one step quieter, still 4.5:1 above)", skin.contains("var dim: Color { dimmed ? mute :"))
for (name, text) in [("RecordingLockScreen", recordingActivity), ("ThoughtLockScreen", recordingActivity)] {
    let body = structBody(text, name)
    check("\(name): the bars rest and Stop is outlined while dimmed", body.contains("skin.level(state.level") && body.contains("outlined: skin.fillsPrimary ? nil : skin"))
}
let ribbonLock = structBody(sessionActivity, "RibbonLockScreen")
check("the session's Lock Screen: the bars rest and the primary button is outlined while dimmed",
      ribbonLock.contains("skin.level(state.level") && ribbonLock.contains("outlinePrimary: !skin.fillsPrimary"))
check("the outlined Stop draws no fill and rings in the listening mark's color", structBody(recordingActivity, "StopButton").contains("outlined == nil ? Refined.persimmonFixed : Color.clear")
      && structBody(recordingActivity, "StopButton").contains("strokeBorder(o.mark"))
/// The Dynamic Island's part of a Live Activity's source: from `dynamicIsland:` to the text after it.
func island(_ text: String, until end: String) -> String {
    guard let r = text.range(of: "dynamicIsland:") else { return "" }
    let rest = text[r.lowerBound...]
    return String(rest.range(of: end).map { rest[..<$0.lowerBound] } ?? rest)
}
let recordingIsland = island(code(recordingActivity), until: "private let recordLink"), sessionIsland = island(code(sessionActivity), until: "private let restartLink")
check("the Dynamic Island never dims (it doesn't read the skin)", !recordingIsland.isEmpty && !sessionIsland.isEmpty
      && !recordingIsland.contains("skin.") && !sessionIsland.contains("skin.") && !sessionIsland.contains("outlinePrimary"))

// MARK: SF-10, SF-13, SF-17: the watch's complications and one Record glyph

let watchWidgets = source("VerbatimWatchWidgets/WatchWidgets.swift"), watchScreens = source("VerbatimWatch/WatchScreens.swift")
check("the watch's Record is circular or a corner, with its kind unchanged", watchWidgets.contains("kind: \"co.stumpandroot.verbatim.watch.record\"")
      && watchWidgets.contains(".supportedFamilies([.accessoryCircular, .accessoryCorner])") && watchWidgets.contains(".widgetLabel(\"Record\")"))
check("the watch's Today's thoughts is rectangular or inline, with its kind unchanged", watchWidgets.contains("kind: \"co.stumpandroot.verbatim.watch.thoughts\"")
      && watchWidgets.contains(".supportedFamilies([.accessoryRectangular, .accessoryInline])") && watchWidgets.contains("family == .accessoryInline"))
let watchGlyph = structBody(watchWidgets, "WatchRecordGlyph")
check("the watch's Record is the record disc, not the bars mark", !watchGlyph.isEmpty && watchGlyph.contains("Circle().fill(Refined.recordRed)")
      && !structBody(watchWidgets, "WatchRecordView").contains("BarsMark") && !watchGlyph.contains("BarsMark"))
check("tinted faces draw Record as a white, accentable glyph on the system's plate (SF-17)", watchWidgets.contains("@Environment(\\.widgetRenderingMode)")
      && watchGlyph.contains("Color.white") && watchGlyph.contains(".widgetAccentable()") && watchWidgets.contains("AccessoryWidgetBackground()"))
check("the watch app's Record is the record disc too (no capture glyph)", watchScreens.contains("Circle().fill(Refined.recordRed).frame(width: 16, height: 16)")
      && !watchScreens.contains("art: .capture"))
check("a recording's Lock Screen leads with the recording dot or the Thoughts symbol, not the session's bars mark",
      !structBody(recordingActivity, "RecordingLockScreen").contains("BarsMark") && !structBody(recordingActivity, "ThoughtLockScreen").contains("BarsMark")
      && structBody(recordingActivity, "ThoughtLockScreen").contains("Image(\"thought\")"))

// MARK: SF-28: rows fade before Record's accessory

check("Home's scroll view has the soft bottom edge under Record's accessory (iOS 26)",
      source("VerbatimPhone/RecordAccessory.swift").contains("content.scrollEdgeEffectStyle(.soft, for: .bottom)")
      && source("VerbatimPhone/HomeScreen.swift").contains("ScrollView { content }\n                .modifier(AccessoryScrollEdge())"))

// MARK: SF-16, SF-18, SF-30: controls and widgets that show what's running

let controlsNow = source("VerbatimWidgets/StartSessionWidgets.swift"), homeNow = source("VerbatimWidgets/HomeWidgets.swift")
let snapshotSource = source("VerbatimWidgets/WidgetSnapshot.swift"), thoughtRules = source("VerbatimWidgets/ThoughtRules.swift")
check("placed widgets and controls keep their kinds", Ribbon.sessionWidgetKind == "co.stumpandroot.verbatim.ios.widget.startSession"
      && Ribbon.dictateControlKind == "co.stumpandroot.verbatim.ios.control.dictate"
      && snapshotSource.contains("static let recordWidgetKind = \"co.stumpandroot.verbatim.widget.record\"")
      && snapshotSource.contains("static let recordControlKind = \"co.stumpandroot.verbatim.ios.control.record\"")
      && thoughtRules.contains("static let controlKind = \"co.stumpandroot.verbatim.ios.control.thought\"")
      && controlsNow.contains("static let kind = Ribbon.sessionWidgetKind") && controlsNow.contains("static let kind = RecordingMirror.recordControlKind")
      && controlsNow.contains("static let kind = Ribbon.dictateControlKind") && controlsNow.contains("static let kind = ThoughtRules.controlKind")
      && homeNow.contains("static let kind = RecordingMirror.recordWidgetKind"))
check("one phrase to turn the session on, and one for its state", Ribbon.startSessionTitle == "Start a session" && Ribbon.sessionOnTitle == "Session on"
      && !controlsNow.contains("Session off") && !controlsNow.contains("\"Start dictating\"") && !controlsNow.contains("\"Start dictation session\"")
      && !controlsNow.contains("Start a Verbose dictation session"))
for (name, intent, value) in [("Record voice note", "SetRecordingIntent()", "RecordingSwitchValue()"), ("Dictate", "SetTakeIntent()", "TakeSwitchValue()"),
                              ("New thought", "SetThoughtIntent()", "ThoughtSwitchValue()")] {
    check("Control Center's \(name) is a switch that shows what's running", controlsNow.contains("provider: \(value)") && controlsNow.contains("action: \(intent)")
          && controlsNow.contains("ControlWidgetToggle(\"\(name == "Record voice note" ? "Record" : name)\""))
}
check("no control says to press it again: it shows Recording a thought instead", !controlsNow.contains("Press it again") && controlsNow.contains("\"Recording a thought\""))
let recordIntent = source("VerbatimWidgets/RecordVoiceNoteIntent.swift"), thoughtIntent = source("VerbatimWidgets/NewThoughtIntent.swift"), dictateIntents = source("VerbatimWidgets/DictateIntents.swift")
check("the Record and New thought switches start in place as audio recording intents, and act only when out of step",
      recordIntent.contains("extension SetRecordingIntent: AudioRecordingIntent {}") && thoughtIntent.contains("extension SetThoughtIntent: AudioRecordingIntent {}")
      && recordIntent.contains("RecordingMirror.switchActs(on: on, running: running)") && thoughtIntent.contains("RecordingMirror.switchActs(on: on, running: recording)")
      && dictateIntents.contains("RecordingMirror.switchActs(on: on, running: listening)"))
check("the Record switch turned off never stops a thought", recordIntent.contains("RecordingControl.recordingOtherThanThought()")
      && presence.contains("$0.recorder.isRecording && !$0.recordingThought"))
check("the app mirrors the recording, refreshes its heartbeat, and reloads what reads it", presence.contains("RecordingMirror.write(m)")
      && presence.contains("Timer(timeInterval: RecordingMirror.heartbeatEvery") && presence.contains("reloadTimelines(ofKind: RecordingMirror.recordWidgetKind)")
      && presence.contains("reloadControls(ofKind: RecordingMirror.recordControlKind)") && presence.contains("reloadControls(ofKind: ThoughtRules.controlKind)"))
check("a mirror left by a recording iOS ended is cleared at launch and by Stop with nothing recording",
      presence.contains("if !app.recorder.isRecording { Self.clearMirror() }") && source("VerbatimWidgets/RecordingActivity.swift").contains("RecordingPresence.clearMirror()"))
check("the Record widget shows a running recording with Stop, and looks again while one runs",
      homeNow.contains("Button(intent: StopRecordingIntent())") && homeNow.contains("if let r = entry.recording, entry.recordingOn {")
      && homeNow.contains("policy: .after(e.date.addingTimeInterval(RecordingMirror.recheckEvery))") && homeNow.contains("provider: RecordProvider()"))
check("the Lock Screen session widget shows Session on with its time, and its bars are accentable",
      controlsNow.contains("KeyboardBridge.sessionLive ? (KeyboardBridge.sessionStartedAt ?? now) : nil")
      && controlsNow.contains("Text(started, style: .relative)") && controlsNow.contains("BarsMark(color: .white).padding(12).widgetAccentable()")
      && controlsNow.contains("BarsMark(color: .white).frame(width: 26, height: 26).widgetAccentable()")
      && controlsNow.contains(".after(entry.date.addingTimeInterval(Ribbon.sessionWidgetRecheck)) : .never"))
check("the session writes when it started and reloads the Lock Screen widget and the Dictate switch",
      sessionApp.contains("forKey: KeyboardBridge.Key.startedAt)") && sessionApp.contains("reloadTimelines(ofKind: Ribbon.sessionWidgetKind)")
      && sessionApp.contains("reloadControls(ofKind: Ribbon.dictateControlKind)") && sessionApp.contains("reloadTakeControl(listening: phase == .listening)"))
for w in [Ribbon.startSessionTitle, Ribbon.sessionOnTitle, "Recording a thought", "Listening", "Recording"] {
    check("switch words follow the copy rules: \(w)", !w.contains("\u{2014}") && !w.contains("!") && w.first?.isUppercase == true)
}

// MARK: SF-33: the Watch's Smart Stack (the small activity family)

check("Smart Stack: a recording's first line is Recording or Paused before its timer",
      SmartStack.recordingLead(paused: false) == "Recording · " && SmartStack.recordingLead(paused: true) == "Paused · ")
check("Smart Stack: a recording leads with the bars, the pause glyph, a check once saved, still bars when stale",
      SmartStack.recordingGlyph(paused: false, saved: false, stale: false) == .bars
      && SmartStack.recordingGlyph(paused: true, saved: false, stale: false) == .pause
      && SmartStack.recordingGlyph(paused: true, saved: true, stale: false) == .check
      && SmartStack.recordingGlyph(paused: false, saved: false, stale: true) == .still
      && SmartStack.recordingGlyph(paused: true, saved: false, stale: true) == .still)
check("Smart Stack: takes read 1 take, 4 takes, never a negative count",
      SmartStack.takesLabel(1) == "1 take" && SmartStack.takesLabel(4) == "4 takes" && SmartStack.takesLabel(0) == "0 takes"
      && SmartStack.takesLabel(-2) == "0 takes")
check("Smart Stack: a session between takes reads On · 4 takes, or On before the first",
      SmartStack.sessionLine(.ready, takes: 4, words: 0, gettingReady: false, hasStart: false) == "On · 4 takes"
      && SmartStack.sessionLine(.ready, takes: 1, words: 0, gettingReady: false, hasStart: false) == "On · 1 take"
      && SmartStack.sessionLine(.ready, takes: 0, words: 0, gettingReady: false, hasStart: false) == "On")
check("Smart Stack: a listening take reads Listening before its timer, or Getting ready with no timer",
      SmartStack.sessionLine(.listening, takes: 3, words: 0, gettingReady: false, hasStart: true) == "Listening · "
      && SmartStack.sessionTimes(.listening, gettingReady: false, hasStart: true)
      && SmartStack.sessionLine(.listening, takes: 3, words: 0, gettingReady: false, hasStart: false) == "Listening"
      && !SmartStack.sessionTimes(.listening, gettingReady: false, hasStart: false)
      && SmartStack.sessionLine(.listening, takes: 1, words: 0, gettingReady: true, hasStart: true) == Ribbon.gettingReadyTitle
      && !SmartStack.sessionTimes(.listening, gettingReady: true, hasStart: true)
      && !SmartStack.sessionTimes(.ready, gettingReady: false, hasStart: true))
check("Smart Stack: other session states read the Lock Screen's headline (a count, never words)",
      SmartStack.sessionLine(.copied, takes: 2, words: 42, gettingReady: false, hasStart: false) == "Copied · 42 words"
      && SmartStack.sessionLine(.paused, takes: 2, words: 0, gettingReady: false, hasStart: false) == "Paused for a call"
      && SmartStack.sessionLine(.ended, takes: 2, words: 0, gettingReady: false, hasStart: false) == "Session ended"
      && SmartStack.sessionLine(.transcribing, takes: 2, words: 0, gettingReady: false, hasStart: false) == "Writing it down")
check("Smart Stack: a session leads with a neutral dot between takes, the bars while listening",
      SmartStack.sessionGlyph(.ready, stale: false) == .dot && SmartStack.sessionGlyph(.listening, stale: false) == .bars
      && SmartStack.sessionGlyph(.paused, stale: false) == .pause && SmartStack.sessionGlyph(.copied, stale: false) == .check
      && SmartStack.sessionGlyph(.inserted, stale: false) == .check && SmartStack.sessionGlyph(.ended, stale: false) == .dot
      && SmartStack.sessionGlyph(.listening, stale: true) == .still)
check("Smart Stack: the first line takes the listening color only while active and lit (Always On quiets it)",
      SmartStack.accentLine(active: true, dimmed: false) && !SmartStack.accentLine(active: true, dimmed: true)
      && !SmartStack.accentLine(active: false, dimmed: false) && !SmartStack.accentLine(active: false, dimmed: true))
for w in [SmartStack.sessionTitle, SmartStack.staleLine, SmartStack.recordingLead(paused: false), SmartStack.recordingLead(paused: true),
          SmartStack.sessionLine(.ready, takes: 4, words: 0, gettingReady: false, hasStart: false)] {
    check("Smart Stack words follow the copy rules: \(w)", !w.contains("\u{2014}") && !w.contains("!") && w.first?.isUppercase == true
          && !w.lowercased().contains("stopped"))
}
check("both Live Activities add the small family through the iOS 18 guard",
      code(recordingActivity).contains(".smartStackFamily()") && code(sessionActivity).contains(".smartStackFamily()")
      && skin.contains("if #available(iOS 18.0, *) {\n            return supplementalActivityFamilies([.small])")
      && skin.contains("@Environment(\\.activityFamily) private var family") && skin.contains("if family == .small { small() } else { full() }"))
let recordingSmall = code(structBody(recordingActivity, "RecordingSmallView")), sessionSmall = code(structBody(sessionActivity, "SessionSmallView"))
check("the small layouts are drawn inside the Lock Screen surface, so they read Always On",
      recordingActivity.contains("ActivityFamilySwitch {\n                    // The Watch's Smart Stack") && recordingActivity.contains("RecordingSmallView(attributes:")
      && sessionActivity.contains("ActivityFamilySwitch {\n                    // The Watch's Smart Stack") && sessionActivity.contains("SessionSmallView(state:"))
check("the small layouts never read words", !recordingSmall.isEmpty && !sessionSmall.isEmpty
      && !recordingSmall.contains(".words") && !sessionSmall.contains("liveWords") && !sessionSmall.contains(".message"))
check("the small layouts' bars follow the mic and rest while dimmed", recordingSmall.contains("skin.level(state.level")
      && sessionSmall.contains("skin.level(state.level, fallback: AlwaysOn.restingLevel)"))
check("the small layouts' first line uses the rule's color, with a self-counting timer", recordingSmall.contains("skin.smartStackLine(active: active)")
      && sessionSmall.contains("skin.smartStackLine(active: active)") && recordingSmall.contains("RecordingTimer(state: state)")
      && sessionSmall.contains("TakeTimer(start: start)") && skin.contains("SmartStack.accentLine(active: active, dimmed: dimmed) ? mark : mute"))
check("the small layouts scale their text", fixedText(recordingSmall).isEmpty && fixedText(sessionSmall).isEmpty,
      (fixedText(recordingSmall) + fixedText(sessionSmall)).joined(separator: " | "))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
