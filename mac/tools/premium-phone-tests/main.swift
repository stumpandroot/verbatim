import Foundation

// The iPhone's Premium Native rules (PremiumRules.swift) and its gradients' contrast (read from Tokens.swift). Not
// part of any app target; run mac/tools/test-premium-phone.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!
cal.firstWeekday = 1
func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}
typealias R = PremiumRules

// MARK: Week chart

let bars = R.barHeights([120, 0, 40, 300, 150, 0, 0], future: [false, false, false, false, false, true, true], maxHeight: 50)
check("the busiest day fills the chart", bars[3] == 50, "\(bars)")
check("other days scale to it", bars[0] == 20 && bars[4] == 25, "\(bars)")
check("a day without words is a stub", bars[1] == nil)
check("days still to come are stubs", bars[5] == nil && bars[6] == nil)
check("a small day still shows", R.barHeights([1, 1000], future: [false, false], maxHeight: 50)[0] == 4)
check("an empty week is all stubs", R.barHeights([0, 0, 0], future: [false, false, false], maxHeight: 50).allSatisfy { $0 == nil })
check("words on a future day don't draw", R.barHeights([0, 5], future: [false, true], maxHeight: 50)[1] == nil)

// MARK: Days used

let now = day(2026, 10, 23, 15)   // a Friday
let used = R.daysUsed([day(2026, 10, 23, 9), day(2026, 10, 22), day(2026, 10, 22, 18), day(2026, 10, 19), day(2026, 10, 17, 8), day(2026, 10, 16), day(2026, 9, 1)], now: now, calendar: cal)
check("seven days, oldest first, today last", used.count == 7 && used.last == true)
check("a day counts once however much was recorded", used.filter { $0 }.count == 4, "\(used)")
check("eight days ago doesn't count", !R.daysUsed([day(2026, 10, 15)], now: now, calendar: cal).contains(true))
check("today just after midnight counts", R.daysUsed([day(2026, 10, 23, 0)], now: now, calendar: cal).last == true)
check("the letters end on today (Friday)", R.dayLetters(now: now, calendar: cal) == ["S", "S", "M", "T", "W", "T", "F"], "\(R.dayLetters(now: now, calendar: cal))")
check("days label", R.daysLabel(5) == "5 days" && R.daysLabel(1) == "1 day" && R.daysLabel(0) == "0 days")
check("the sentence keeps the calm rule", R.daysSentence(5) == "You used Verbose on 5 of the last 7 days. No streak to keep. This is your week.")
check("an empty week says so without pressure", R.daysSentence(0).contains("No streak") && !R.daysSentence(0).contains("!"))

// MARK: Year

let months = R.monthCounts([day(2026, 1, 3), day(2026, 1, 30), day(2026, 10, 2), day(2025, 10, 2), day(2026, 12, 31, 23)], year: 2026, calendar: cal)
check("twelve months", months.count == 12)
check("each month counts its own", months[0] == 2 && months[9] == 1 && months[11] == 1, "\(months)")
check("other years are left out", months.reduce(0, +) == 4)

// MARK: Calendar

let october = R.month(day(2026, 10, 5), recorded: [day(2026, 10, 1), day(2026, 10, 2), day(2026, 10, 2, 20), day(2026, 11, 1)], now: now, calendar: cal)
check("October 2026 starts on a Thursday (4 blanks, Sunday first)", october.leadingBlanks == 4, "\(october.leadingBlanks)")
check("October has 31 days", october.days == 31)
check("today is the 23rd", october.today == 23)
check("dots on the 1st and 2nd only", october.recorded == [1, 2], "\(october.recorded)")
check("another month has no today", R.month(day(2026, 9, 1), recorded: [], now: now, calendar: cal).today == nil)
var monday = cal; monday.firstWeekday = 2
check("a Monday-first calendar moves the blanks", R.month(day(2026, 10, 1), recorded: [], now: now, calendar: monday).leadingBlanks == 3)
check("February 2028 has 29 days", R.month(day(2028, 2, 10), recorded: [], now: now, calendar: cal).days == 29)
check("headers follow the first weekday", R.weekdayHeaders(calendar: cal).first == "SUN" && R.weekdayHeaders(calendar: monday).first == "MON", "\(R.weekdayHeaders(calendar: cal))")
let prev = R.shiftMonth(day(2026, 1, 15), by: -1, calendar: cal)
check("the month before January is December of the year before", cal.component(.month, from: prev) == 12 && cal.component(.year, from: prev) == 2025)
check("shifting lands on the first", cal.component(.day, from: R.shiftMonth(day(2026, 3, 31), by: 1, calendar: cal)) == 1)

// MARK: Recorder

check("recorder clock", R.recorderClock(134) == "02:14" && R.recorderClock(0) == "00:00" && R.recorderClock(59.9) == "00:59" && R.recorderClock(3725) == "1:02:05")
check("negative time reads zero", R.recorderClock(-3) == "00:00")
let wave = R.waveBars([0.2, 0.9, 0.5], count: 10)
check("the waveform has the bars asked for", wave.count == 10)
check("the left half is heard, the right half to come", wave.prefix(5).allSatisfy(\.past) && wave.suffix(5).allSatisfy { !$0.past })
check("the newest level sits at the playhead", wave[4].height == Double(Float(0.5)), "\(wave.map(\.height))")
check("a short history pads with quiet bars", wave[0].height == 0.06 && wave[1].height == 0.06)
check("levels are clamped", R.waveBars([3], count: 2)[0].height == 1)
check("no bars for none asked", R.waveBars([0.5], count: 0).isEmpty)
check("saved line", R.savedLine(kind: "Voice note", length: "2:14", when: "Today, 4:12 PM", moments: 2) == "Voice note · 2:14 · Today, 4:12 PM · 2 moments")
check("saved line without moments", R.savedLine(kind: "Voice note", length: "0:09", when: "Today, 4:12 PM", moments: 0) == "Voice note · 0:09 · Today, 4:12 PM")
check("saved line with one moment", R.savedLine(kind: "Idea", length: "1:00", when: "Today", moments: 1).hasSuffix("1 moment"))

check("stage percent", R.stageFraction("Transcribing 42%") == 0.42 && R.stageFraction("Downloading model 7%") == 0.07)
check("no percent, no fraction", R.stageFraction("Queued") == nil && R.stageFraction(nil) == nil)
check("a percent over 100 is clamped", R.stageFraction("Joining 140%") == 1)

// MARK: Preview

check("lines join into one paragraph", R.preview(["Absolutely.", "  Thanks for\nhaving me. "]) == "Absolutely. Thanks for having me.")
let long = R.preview([String(repeating: "word ", count: 80)], limit: 40)
check("a long preview is cut at a word with an ellipsis", long.hasSuffix("…") && long.count <= 41 && !long.contains("wor…"), long)
check("empty lines are skipped", R.preview(["", " ", "Hi."]) == "Hi.")

// MARK: Contrast and gradients (Tokens.swift)

check("contrast of black and white is 21:1", abs(R.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
check("mix halfway", R.mix(0x000000, 0xFFFFFF, 0.5) == 0x808080)
check("gradient ends are its stops", R.gradientColor([0x112233, 0x445566, 0x778899], at: 0) == 0x112233 && R.gradientColor([0x112233, 0x445566, 0x778899], at: 1) == 0x778899)
check("gradient middle is the middle stop", R.gradientColor([0x112233, 0x445566, 0x778899], at: 0.5) == 0x445566)

let args = CommandLine.arguments
if args.count > 1, let tokens = try? String(contentsOfFile: args[1], encoding: .utf8) {
    let re = try! NSRegularExpression(pattern: #"static let (\w+): \[UInt32\] = \[([^\]]+)\]"#)
    var lists: [String: [UInt32]] = [:]
    for m in re.matches(in: tokens, range: NSRange(tokens.startIndex..., in: tokens)) {
        guard let n = Range(m.range(at: 1), in: tokens), let v = Range(m.range(at: 2), in: tokens) else { continue }
        lists[String(tokens[n])] = tokens[v].split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespaces).dropFirst(2), radix: 16) }
    }
    let names = ["persimmon", "ink", "sage", "rose"]
    check("Tokens.swift has light and dark stops for the four gradients", names.allSatisfy { lists[$0 + "Light"] != nil && lists[$0 + "Dark"] != nil }, "\(lists.keys.sorted())")
    for n in names {
        for mode in ["Light", "Dark"] {
            guard let s = lists[n + mode] else { continue }
            let low = R.minWhiteContrast(s, from: 1.0 / 3)
            check("white text reaches 4.5:1 on the lower two thirds of \(n) (\(mode.lowercased()))", low >= 4.5, String(format: "%.2f:1", low))
            let top = R.contrast(0xFFFFFF, R.mix(s[0], 0xFFFFFF, R.highlight))
            check("big numbers reach 3:1 at the top of \(n) under the highlight (\(mode.lowercased()))", top >= 3, String(format: "%.2f:1", top))
            check("\(n) (\(mode.lowercased())) has two or three stops, light at the top", (2...3).contains(s.count) && R.luminance(s[0]) > R.luminance(s[s.count - 1]))
        }
    }
    // The Summary card uses the persimmon's deeper half (PremiumStyle.persimmonDeep): 4.5:1 from the very top.
    for mode in ["Light", "Dark"] {
        if let s = lists["persimmon" + mode], s.count == 3 {
            let low = R.minWhiteContrast(Array(s.dropFirst()), from: 0)
            check("white text reaches 4.5:1 everywhere on the deep persimmon (\(mode.lowercased()))", low >= 4.5, String(format: "%.2f:1", low))
            let chip = R.contrast(0xFFFFFF, R.mix(s[1], 0x000000, 0.16))
            check("the Summary's count chips keep 4.5:1 (\(mode.lowercased()))", chip >= 4.5, String(format: "%.2f:1", chip))
        }
    }
    // Never purple: every stop's hue sits in the warm reds and oranges, or the greens.
    func hue(_ h: UInt32) -> Double {
        let r = Double((h >> 16) & 0xFF) / 255, g = Double((h >> 8) & 0xFF) / 255, b = Double(h & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0 else { return 0 }
        var x: Double
        if mx == r { x = (g - b) / d } else if mx == g { x = (b - r) / d + 2 } else { x = (r - g) / d + 4 }
        x *= 60; if x < 0 { x += 360 }
        return x
    }
    let all = names.flatMap { (lists[$0 + "Light"] ?? []) + (lists[$0 + "Dark"] ?? []) }
    let purple = all.filter { (250.0..<335).contains(hue($0)) }
    check("no gradient stop is purple or indigo", purple.isEmpty, purple.map { String(format: "#%06X", $0) }.joined(separator: " "))
    // Text on the accent: white on the light accent, black on the dark one.
    if let m = try! NSRegularExpression(pattern: #"nativeAccentLightHex: UInt32 = 0x([0-9A-Fa-f]{6}), nativeAccentDarkHex: UInt32 = 0x([0-9A-Fa-f]{6})"#).firstMatch(in: tokens, range: NSRange(tokens.startIndex..., in: tokens)),
       let a = Range(m.range(at: 1), in: tokens), let b = Range(m.range(at: 2), in: tokens),
       let light = UInt32(tokens[a], radix: 16), let dark = UInt32(tokens[b], radix: 16) {
        check("white on the light accent reaches 4.5:1", R.contrast(light, 0xFFFFFF) >= 4.5, String(format: "%.2f:1", R.contrast(light, 0xFFFFFF)))
        check("black on the dark accent reaches 7:1", R.contrast(dark, 0x000000) >= 7, String(format: "%.2f:1", R.contrast(dark, 0x000000)))
    } else {
        check("Tokens.swift defines the Native accent", false)
    }
    check("text on the accent is white in light and black in dark", tokens.contains("onAccentLightHex: UInt32 = 0xFFFFFF, onAccentDarkHex: UInt32 = 0x000000"))
} else {
    check("Tokens.swift's gradients", false, "pass Tokens.swift's path as the first argument")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
