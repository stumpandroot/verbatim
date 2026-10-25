import Foundation

// Premium Native's pure rules (PremiumRules.swift): white text on the gradient cards (colors read from Tokens.swift),
// the recordings' date line, speakers' shares, This week's bars, the Library's scope bar, and back and forward. Not
// part of any app target; run mac/tools/test-premium.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

// MARK: Gradient cards (Tokens.swift)

let args = CommandLine.arguments
let tokens = args.count > 1 ? (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? "" : ""
func hexArray(_ name: String) -> [UInt32]? {
    guard let re = try? NSRegularExpression(pattern: "static let \(name): \\[UInt32\\] = \\[([^\\]]*)\\]"),
          let m = re.firstMatch(in: tokens, range: NSRange(tokens.startIndex..., in: tokens)),
          let r = Range(m.range(at: 1), in: tokens) else { return nil }
    let values = tokens[r].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        .compactMap { $0.hasPrefix("0x") ? UInt32($0.dropFirst(2), radix: 16) : nil }
    return values.isEmpty ? nil : values
}
func hexValue(_ name: String) -> UInt32? {
    guard let re = try? NSRegularExpression(pattern: "\(name): UInt32 = 0x([0-9A-Fa-f]{6})"),
          let m = re.firstMatch(in: tokens, range: NSRange(tokens.startIndex..., in: tokens)),
          let r = Range(m.range(at: 1), in: tokens) else { return nil }
    return UInt32(tokens[r], radix: 16)
}

check("Tokens.swift was passed", !tokens.isEmpty, "pass Tokens.swift's path as the first argument")
for card in PremiumCard.allCases {
    for mode in ["Light", "Dark"] {
        guard let stops = hexArray("\(card.rawValue)\(mode)") else {
            check("PremiumHex.\(card.rawValue)\(mode) is defined", false); continue
        }
        check("\(card.rawValue) \(mode.lowercased()): one color per stop position", stops.count == card.locations.count, "\(stops.count) colors, \(card.locations.count) positions")
        for text in PremiumCardText.all where text.card == card {
            let need = text.large ? 3.0 : 4.5
            let worst = PremiumContrast.worstWhite(from: text.from, to: text.to, stops: stops, locations: card.locations)
            check("\(card.rawValue) \(mode.lowercased()): white \(text.name) reaches \(need):1", worst >= need, String(format: "%.2f:1", worst))
        }
    }
}
check("every card carries some text", PremiumCard.allCases.allSatisfy { c in PremiumCardText.all.contains { $0.card == c } })
check("stop positions run top to bottom", PremiumCard.allCases.allSatisfy { $0.locations.first == 0 && $0.locations.last == 1 && $0.locations == $0.locations.sorted() })
check("text bands sit on the card", PremiumCardText.all.allSatisfy { $0.from >= 0 && $0.to <= 1 && $0.from < $0.to })
// Warm brand colors only: no purple or indigo (hue between 230° and 300°) anywhere in the gradients.
func hue(_ hex: UInt32) -> Double {
    let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    guard d > 0 else { return 0 }
    var h: Double
    if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    h *= 60
    return h < 0 ? h + 360 : h
}
let allStops = PremiumCard.allCases.flatMap { c in ["Light", "Dark"].flatMap { hexArray("\(c.rawValue)\($0)") ?? [] } }
check("no purple in the gradients", allStops.allSatisfy { !(230...300).contains(hue($0)) }, allStops.map { String(format: "%06X %.0f°", $0, hue($0)) }.joined(separator: ", "))
if let light = hexValue("windowLight"), let dark = hexValue("windowDark") {
    check("the light window is the warm off-white #F6F3F1", light == 0xF6F3F1)
    check("the dark window is near black", PremiumContrast.luminance(dark) < 0.01, String(format: "%06X", dark))
    // The Native accent (Tokens.swift) on the window: light #D5431F with white text; dark #FF6B47 with black text.
    if let accentLight = hexValue("nativeAccentLightHex"), let accentDark = hexValue("nativeAccentDarkHex") {
        // Small accent text: the accent on white cards, a deeper one on the warm window and the selection tint (the
        // accent at 11% over the window in light, 18% in dark).
        func over(_ base: UInt32, _ top: UInt32, _ a: Double) -> UInt32 {
            [16, 8, 0].reduce(UInt32(0)) { acc, s in
                let p = Double((base >> UInt32(s)) & 0xFF), q = Double((top >> UInt32(s)) & 0xFF)
                return acc | UInt32((p + (q - p) * a).rounded()) << UInt32(s)
            }
        }
        if let textLight = hexValue("accentTextLight"), let textDark = hexValue("accentTextDark") {
            for (name, bg) in [("the warm window", light), ("the selection tint", over(light, accentLight, 0.11)), ("a white card", UInt32(0xFFFFFF))] {
                check("light accent text reads on \(name) (4.5:1)", PremiumContrast.ratio(textLight, bg) >= 4.5, String(format: "%.2f:1", PremiumContrast.ratio(textLight, bg)))
            }
            for (name, bg) in [("the dark window", dark), ("the dark selection tint", over(dark, accentDark, 0.18)), ("a dark card", UInt32(0x1C1C1E))] {
                check("dark accent text reads on \(name) (4.5:1)", PremiumContrast.ratio(textDark, bg) >= 4.5, String(format: "%.2f:1", PremiumContrast.ratio(textDark, bg)))
            }
            check("the accent alone falls short on the warm window (why text deepens)", PremiumContrast.ratio(accentLight, light) < 4.5)
        } else {
            check("PremiumHex defines accent text", false)
        }
        check("black text on the dark accent reaches 4.5:1", PremiumContrast.ratio(accentDark, 0x000000) >= 4.5, String(format: "%.2f:1", PremiumContrast.ratio(accentDark, 0)))
        check("white text on the dark accent would fail (so it's black)", PremiumContrast.ratio(accentDark, 0xFFFFFF) < 4.5)
        check("white text on the light accent reaches 4.5:1", PremiumContrast.ratio(accentLight, 0xFFFFFF) >= 4.5)
    } else {
        check("Tokens.swift defines the Native accent", false)
    }
} else {
    check("PremiumHex defines the window colors", false)
}
check("the gradient mixes between stops", PremiumContrast.color(at: 0.5, stops: [0x000000, 0xFFFFFF], locations: [0, 1]) == 0x808080)
check("the gradient clamps past its ends", PremiumContrast.color(at: 1.4, stops: [0x102030, 0x405060], locations: [0, 1]) == 0x405060
      && PremiumContrast.color(at: -1, stops: [0x102030, 0x405060], locations: [0, 1]) == 0x102030)

// MARK: Date line

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!
let posix = Locale(identifier: "en_US")
func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}
let now = date(2026, 10, 23, 16, 0)
func normalized(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
check("today's recording", normalized(PremiumDateLine.line(date(2026, 10, 23, 9, 12), now: now, calendar: cal, locale: posix)) == "Today · 9:12 AM",
      PremiumDateLine.line(date(2026, 10, 23, 9, 12), now: now, calendar: cal, locale: posix))
check("yesterday's recording", normalized(PremiumDateLine.line(date(2026, 10, 22, 18, 20), now: now, calendar: cal, locale: posix)) == "Yesterday · 6:20 PM")
let older = normalized(PremiumDateLine.line(date(2026, 10, 20, 14, 5), now: now, calendar: cal, locale: posix))
check("an older recording names the day", older.hasPrefix("Tue, Oct 20") || older.hasPrefix("Tue Oct 20"), older)
let lastYear = normalized(PremiumDateLine.line(date(2025, 3, 2, 8, 0), now: now, calendar: cal, locale: posix))
check("last year's recording has the year", lastYear.contains("2025") && lastYear.hasSuffix("8:00 AM"), lastYear)

// MARK: Speakers

let shares = SpeakerShares.compute([("Ginna", 40), ("Allie", 10), ("Ginna", 28), ("Allie", 22)])
check("speakers rank by talk time", shares.map(\.id) == ["Ginna", "Allie"])
check("68% and 32%", shares.map(\.percent) == [68, 32], "\(shares.map(\.percent))")
let thirds = SpeakerShares.compute([("A", 1), ("B", 1), ("C", 1)])
check("percents always add up to 100", thirds.map(\.percent).reduce(0, +) == 100, "\(thirds.map(\.percent))")
check("ties keep the order they first spoke in", thirds.map(\.id) == ["A", "B", "C"])
check("no talk time, no speakers", SpeakerShares.compute([("A", 0)]).isEmpty && SpeakerShares.compute([]).isEmpty)

// MARK: This week's bars

let bars = WeekBars.bars(words: [180, 60, 130, 320, 220, 0, 0], future: [false, false, false, false, false, true, true], maxHeight: 70)
check("the busiest day is full height", bars[3].height == 70 && !bars[3].stub)
check("bars scale by words", abs(bars[0].height - 70 * 180 / 320) < 0.001)
check("days to come are stubs", bars[5].stub && bars[6].stub && bars[5].height == 4)
let quiet = WeekBars.bars(words: [0, 1, 1000], future: [false, false, false], maxHeight: 70)
check("a day with any words is never a stub", !quiet[1].stub && quiet[1].height == 8)
check("a past day without words is a stub", quiet[0].stub)
check("an empty week is all stubs", WeekBars.bars(words: [0, 0, 0], future: [], maxHeight: 70).allSatisfy(\.stub))

// MARK: Scope bar

let scopes = ["All", "Voice notes", "Meetings", "Journal", "Links"]
check("five scopes fit as segments in 600 pt", ScopeBarStyle.segmented(scopes, available: 600))
check("they don't fit in 300 pt (a menu instead)", !ScopeBarStyle.segmented(scopes, available: 300))
check("more than seven scopes are always a menu", !ScopeBarStyle.segmented(Array(repeating: "A", count: 8), available: 2000))
check("the estimate grows with the labels", ScopeBarStyle.segmentedWidth(["All"]) < ScopeBarStyle.segmentedWidth(["All", "Links"]))

// MARK: Back and forward

var h = NavHistory<String>()
h.visit("library"); h.visit("t1")
check("back goes where you were", h.canGoBack && h.goBack() == "library" && h.current == "library")
check("forward returns", h.canGoForward && h.goForward() == "t1" && !h.canGoForward)
_ = h.goBack(); h.visit("home")
check("a new place clears forward", !h.canGoForward && h.current == "home")
h.visit("home")
check("visiting where you are changes nothing", h.back == ["library"])
var g = NavHistory<String>()
for s in ["home", "t1", "library", "t1", "t2"] { g.visit(s) }
g.removeAll { $0 == "t1" }
check("a deleted transcript leaves the history", !g.back.contains("t1") && g.back == ["home", "library"], "\(g.back)")
var long = NavHistory<Int>(); long.limit = 3
for i in 0..<10 { long.visit(i) }
check("history keeps a limit", long.back == [6, 7, 8])
check("nothing to go back to", NavHistory<Int>().canGoBack == false && { var e = NavHistory<Int>(); return e.goBack() == nil }())

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
