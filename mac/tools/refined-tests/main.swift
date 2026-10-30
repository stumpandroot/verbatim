import Foundation

// The refined look (DESIGN.md §13): contrast of every text pair the kit draws, the Palette setting's mapping, the
// kinds' colors, the speakers' rotation, type and radii, and that the kit takes its colors from the tokens. Run with
// mac/tools/test-refined.sh, which compiles this with the RefinedHex table from Tokens.swift and RefinedRules.swift.

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

typealias H = RefinedHex
typealias R = RefinedRules

/// The four ways a color resolves: light and dark, each with and without Increase Contrast.
let modes: [(name: String, dark: Bool, hc: Bool)] = [("light", false, false), ("dark", true, false),
                                                      ("light, Increase Contrast", false, true), ("dark, Increase Contrast", true, true)]
func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }

/// What a text color sits on: an opaque tone, or a wash over one.
enum Under {
    case tone(H.Tone)
    case wash(H.Wash, over: H.Tone)
    func value(dark: Bool, hc: Bool) -> UInt32 {
        switch self {
        case .tone(let t): return t.value(dark: dark, increased: hc)
        case .wash(let w, let base): return R.over(w, base.value(dark: dark, increased: hc), dark: dark, increased: hc)
        }
    }
}

/// Checks one text pair in all four modes against `minimum` (4.5:1 for text, 3:1 for marks that carry meaning).
func pair(_ name: String, _ text: H.Tone, _ under: Under, minimum: Double = 4.5) {
    var worst = 21.0, at = ""
    for m in modes {
        let fg = text.value(dark: m.dark, increased: m.hc), bg = under.value(dark: m.dark, hc: m.hc)
        let c = R.contrast(fg, bg)
        if c < worst { worst = c; at = "\(m.name): \(hex(fg)) on \(hex(bg))" }
    }
    check("\(name) reaches \(minimum):1 in every mode", worst >= minimum, String(format: "%.2f:1 at %@", worst, at))
}

// MARK: - Contrast math

check("black on white is 21:1", abs(R.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
check("a color on itself is 1:1", abs(R.contrast(0xFB7350, 0xFB7350) - 1) < 0.001)
check("a wash at 0 is what's under it, at 1 its own color", R.blend(0x26352E, 0, 0xFFFFFF) == 0xFFFFFF && R.blend(0x26352E, 1, 0xFFFFFF) == 0x26352E)
check("the mockup's persimmon #FA6B47 fails ink text (4.45:1), so fills use #FB7350", R.contrast(0x26352E, 0xFA6B47) < 4.5 && H.persimmon.light == 0xFB7350)
check("the color panels' dark persimmon #E2694B fails ink text, so dark fills use #F27A57", R.contrast(0x26352E, 0xE2694B) < 4.5 && H.persimmon.dark == 0xF27A57)
check("the mockup's ready chip (ink at 10%) fails, so it's reader white at 30%",
      R.contrast(0x26352E, R.blend(0x26352E, 0.10, 0xFB7350)) < 4.5 && H.chipFull.base == H.lift)

// MARK: - Text on the page, cards, and fields

let surfaces: [(String, H.Tone)] = [("paper", H.paper), ("the card", H.card), ("a search field", H.field)]
for (sname, s) in surfaces {
    pair("ink on \(sname)", H.ink, .tone(s))
    pair("dim on \(sname)", H.dim, .tone(s))
    pair("mute on \(sname)", H.mute, .tone(s))
}
pair("accent text on paper", H.accentText, .tone(H.paper))
pair("a destructive title (danger) on the card", H.danger, .tone(H.card))
pair("a destructive title (danger) on paper", H.danger, .tone(H.paper))
// The Mac's sidebar: its labels, counts, headers, and the accent glyphs on the side gray, and a selected row's tint.
for (n, t) in [("ink", H.ink), ("dim", H.dim), ("mute", H.mute), ("accent text", H.accentText)] {
    pair("\(n) on the sidebar (side)", t, .tone(H.side))
}
pair("mute counts on the sidebar's selected row (persimmon tint)", H.mute, .tone(H.persimmonTint))
pair("accent text on the card", H.accentText, .tone(H.card))
pair("accent text on a selected chip or row (persimmon tint)", H.accentText, .tone(H.persimmonTint))
pair("ink on a selected chip or row (persimmon tint)", H.ink, .tone(H.persimmonTint))
pair("ink on a quiet chip on paper", H.ink, .wash(H.neutral, over: H.paper))
pair("ink on a quiet chip on the card", H.ink, .wash(H.neutral, over: H.card))
pair("mute on a selected row (persimmon tint), the Library table's other columns", H.mute, .tone(H.persimmonTint))
pair("dim on a selected row (persimmon tint)", H.dim, .tone(H.persimmonTint))
for (n, t) in [("ink", H.ink), ("dim", H.dim), ("mute", H.mute)] {
    pair("\(n) on a striped row (the Library table's alternating wash)", t, .wash(H.stripe, over: H.card))
}
pair("the selected chip's accent text on the persimmon tint, on paper", H.accentText, .tone(H.persimmonTint))
pair("dim on a segmented track (the options not chosen)", H.dim, .tone(H.track))
pair("the playing line's time (sage text) on its wash, on paper", H.sageText, .wash(H.playing, over: H.paper))
pair("the playing line's time (sage text) on its wash, on the card", H.sageText, .wash(H.playing, over: H.card))
pair("ink reading text on the playing wash", H.ink, .wash(H.playing, over: H.paper))
pair("ink on the player bar without glass", H.ink, .wash(H.glassFallback, over: H.paper))
pair("dim times on the player bar without glass", H.dim, .wash(H.glassFallback, over: H.paper))
pair("the accent (selected tab, links) on the player bar without glass", H.accentText, .wash(H.glassFallback, over: H.paper))

// MARK: - Palette surfaces: the Record card and tiles

for palette in AppPalette.allCases {
    for hue in RefinedHue.allCases {
        pair("\(palette.label): text on a \(hue.rawValue) tile", R.onFill(hue, palette: palette), .tone(R.fill(hue, palette: palette)))
    }
    pair("\(palette.label): the ready chip's text", R.recordInk(palette), .wash(R.readyChip(palette), over: R.recordFill(palette)))
    pair("\(palette.label): the record disc on the card (a mark)", palette == .full ? H.onFill : H.ink, .tone(R.recordFill(palette)), minimum: 3)
    // The Mac's recording card: its quiet actions sit on the ready chip's wash (the neutral wash fails under Increase
    // Contrast, 3.95:1), and the strong action's light text.
    pair("\(palette.label): a quiet action on the recording card (the ready chip's wash)", R.recordInk(palette), .wash(R.readyChip(palette), over: R.recordFill(palette)))
    check("\(palette.label): the neutral wash would fail on the card under Increase Contrast, so it isn't used there",
          palette == .soft || R.contrast(R.recordInk(palette).hcLight, R.over(H.neutral, R.recordFill(palette).hcLight, dark: false, increased: true)) < 4.5)
    pair("\(palette.label): the strong action's text on its ink", palette == .full ? H.lift : H.paper, .tone(R.recordInk(palette)))
}
pair("a strong action on paper (paper text on ink)", H.paper, .tone(H.ink))

// MARK: - Tile patterns

check("tile patterns: ink at 13% on a Full fill, 9% on a Soft tint and on the off-white tile",
      R.tilePatternInk(.butter, palette: .full) == H.patternFull && H.patternFull.light == 0.13 && H.patternFull.base == H.onFill
      && R.tilePatternInk(.butter, palette: .soft) == H.patternSoft && R.tilePatternInk(.neutral, palette: .full) == H.patternSoft
      && H.patternSoft.light == 0.09 && H.patternSoft.base == H.ink)
for palette in AppPalette.allCases {
    for hue in RefinedHue.allCases where hue != .persimmon {
        // Where a long name runs under the pattern: the tile's text over the pattern's ink on the fill.
        pair("\(palette.label): text on a \(hue.rawValue) tile, over its line pattern", R.onFill(hue, palette: palette),
             .wash(R.tilePatternInk(hue, palette: palette), over: R.fill(hue, palette: palette)))
    }
}

// MARK: - The Record card's rings and disc

for (mac, compact) in [(false, false), (true, false), (false, true), (true, true)] {
    let art = R.recordArt(mac: mac, compact: compact)
    let label = "\(mac ? "Mac" : "iPhone")\(compact ? " Compact" : "")"
    // Card sizes from a narrow phone to a wide Mac column, and taller cards for larger text.
    let sizes: [(Double, Double)] = [(320, 168), (350, 168), (402, 168), (350, 240), (350, 320), (760, 150), (860, 210), (300, 72), (600, 96)]
    let centered = sizes.allSatisfy { (w, h) in
        let o = art.ringOrigin(width: w, height: h), c = art.discCenter(width: w, height: h)
        return abs(o.x + art.side * 0.5 - c.x) < 0.001 && abs(o.y + art.side * 0.7 - c.y) < 0.001
    }
    check("\(label): the record disc sits at the center of the innermost ring at every card size", centered)
    check("\(label): the disc stays on the card and inside the innermost ring",
          art.disc / 2 < art.side * 60 / 300 && art.trailing > art.disc / 2 && (art.bottom ?? 36) > art.disc / 2 - 0.001)
    check("\(label): the text keeps clear of the disc", art.textReserve + art.padding >= art.trailing + art.disc / 2)
}
let phone = R.recordArt(mac: false, compact: false)
let phoneDisc = phone.discCenter(width: 350, height: 168), phoneRings = phone.ringOrigin(width: 350, height: 168)
check("iPhone: on the mockup's 350 by 168 card, the rings sit at right −46, top −14 and the disc at right 31, top 105",
      phoneRings.x == 350 - 210 + 46 && phoneRings.y == -14 && phoneDisc.x == 350 - 31 - 28 && phoneDisc.y == 105 + 28,
      "rings \(phoneRings), disc \(phoneDisc)")
check("iPhone: a taller card (larger text) keeps the disc the same distance from the bottom",
      phone.discCenter(width: 350, height: 260).y == 260 - 35)
check("Compact: the disc is in the middle of the slim row", R.recordArt(mac: false, compact: true).discCenter(width: 300, height: 72).y == 36)

// MARK: - Badges, chips, and squares (Full in both palettes)

for hue in RefinedHue.allCases {
    pair("text and glyphs on a \(hue.rawValue) badge, chip, or square", R.onBadge(hue), .tone(R.badgeFill(hue)))
}

// MARK: - Marks that carry meaning (3:1)

pair("the played part of the waveform on the card", H.played, .tone(H.card), minimum: 3)
pair("the played part of the waveform on the player bar", H.played, .wash(H.glassFallback, over: H.paper), minimum: 3)
pair("an on switch on the Mac against paper", H.macSwitch, .tone(H.paper), minimum: 3)
pair("the white knob on the Mac's on switch", H.Tone(0xFFFFFF, 0xFFFFFF), .tone(H.macSwitch), minimum: 3)

// MARK: - Increase Contrast

check("Increase Contrast darkens secondary text", H.dim.hcLight == H.ink.light && H.mute.hcLight != H.mute.light)
check("Increase Contrast strengthens separators", H.separator.hcLight > H.separator.light && H.separator.hcDark > H.separator.dark)
check("Increase Contrast makes the player bar solid", H.glassFallback.hcLight == 1 && H.glassFallback.hcDark == 1)
check("every tone has a dark value that differs from its light one, except the fixed ink and white",
      [H.paper, H.card, H.field, H.track, H.rail, H.side, H.ink, H.dim, H.mute, H.faint, H.accentText, H.sageText, H.persimmon, H.butter,
       H.sage, H.petal, H.persimmonTint, H.butterTint, H.sageTint, H.petalTint, H.neutralSquare, H.played, H.waveRest, H.macSwitch]
        .allSatisfy { $0.light != $0.dark })

// MARK: - The Palette setting

check("the palette is stored as appearance.palette", AppPalette.key == "appearance.palette")
check("a new install starts on Full", AppPalette(stored: nil) == .full)
check("Soft reads back", AppPalette(stored: "soft") == .soft && AppPalette(stored: "full") == .full)
check("an unknown value reads as Full", AppPalette(stored: "Soft") == .full && AppPalette(stored: "") == .full)
check("two palettes, Full first", AppPalette.allCases == [.full, .soft])
check("Full: the Record card is persimmon, the tiles butter, sage, and petal",
      R.fill(.persimmon, palette: .full) == H.persimmon && R.fill(.butter, palette: .full) == H.butter &&
      R.fill(.sage, palette: .full) == H.sage && R.fill(.petal, palette: .full) == H.petal)
check("Soft: the same four as tints", R.fill(.persimmon, palette: .soft) == H.persimmonTint && R.fill(.butter, palette: .soft) == H.butterTint &&
      R.fill(.sage, palette: .soft) == H.sageTint && R.fill(.petal, palette: .soft) == H.petalTint)
check("the neutral tile is the card in both", R.fill(.neutral, palette: .full) == H.card && R.fill(.neutral, palette: .soft) == H.card)
check("Full puts fixed ink on its fills; Soft and the card put the reading ink",
      R.onFill(.butter, palette: .full) == H.onFill && R.onFill(.butter, palette: .soft) == H.ink && R.onFill(.neutral, palette: .full) == H.ink)
check("the rings and ready chip follow the palette", R.rings(.full) == H.ringFull && R.rings(.soft) == H.ringSoft &&
      R.readyChip(.full) == H.chipFull && R.readyChip(.soft) == H.chipSoft)
check("badges keep the Full fills in both palettes", RefinedHue.allCases.allSatisfy { R.badgeFill($0) == R.fill($0, palette: .full) || $0 == .neutral })

// MARK: - Kinds and speakers

let kinds: [(String?, RefinedHue)] = [("meeting", .persimmon), (nil, .persimmon), ("note", .persimmon), ("interview", .sage), ("talk", .sage),
                                      ("audio", .petal), ("journal", .petal), ("idea", .butter), ("brainDump", .butter),
                                      ("dictation", .butter), ("podcast", .petal), ("video", .sage)]
for (raw, hue) in kinds { check("kind \(raw ?? "voice note") is \(hue.rawValue)", R.kindHue(raw) == hue) }
check("a kind a newer build adds still gets a color", R.kindHue("someday") != .neutral)
check("speakers rotate persimmon, petal, sage, butter", (0..<4).map(R.speakerHue) == [.persimmon, .petal, .sage, .butter])
check("the fifth speaker starts the rotation again", R.speakerHue(4) == .persimmon && R.speakerHue(9) == .petal)
check("a bad index still gets a hue", R.speakerHue(-1) == .butter)
check("no speaker is neutral", !R.speakerRotation.contains(.neutral))

// MARK: - Type and radii

typealias T = R.TextRole
check("reading text is serif", T.reading.serif)
check("large titles, transcript titles, section titles, and Record are serif", [T.largeTitle, .transcriptTitle, .sectionTitle, .recordTitle].allSatisfy(\.serif))
check("everything else is SF Pro", T.allCases.filter(\.serif).count == 5)
check("reading text is 19 pt on iPhone and 18 on the Mac", T.reading.size(mac: false) == 19 && T.reading.size(mac: true) == 18)
check("reading text has room between lines", R.lineSpacing(.reading, mac: false) > 4 && R.lineSpacing(.reading, mac: true) > 6)
check("only reading text adds line spacing", T.allCases.filter { R.lineSpacing($0, mac: false) > 0 } == [.reading])
check("no text under 11 pt", T.allCases.allSatisfy { $0.size(mac: true) >= 11 && $0.size(mac: false) >= 12 })
check("cards round 14 to 16", [false, true].allSatisfy { m in (12...16).contains(R.radius(.card, mac: m)) && (14...16).contains(R.radius(.tile, mac: m)) })
check("the Record card rounds 22 on iPhone and 18 on the Mac", R.radius(.record, mac: false) == 22 && R.radius(.record, mac: true) == 18)
check("radii aren't all the same", Set(R.RadiusRole.allCases.map { R.radius($0, mac: false) }).count >= 4)
check("tap targets are at least 44 pt", R.minTapTarget >= 44)

// MARK: - Times

check("the player's times: 0:07, 12:30, 1:02:14", R.time(7.9) == "0:07" && R.time(750) == "12:30" && R.time(3734) == "1:02:14")
check("a time never goes negative or breaks on NaN", R.time(-3) == "0:00" && R.time(.nan) == "0:00")
check("the recorder's clock has hundredths", R.clock(72.48) == "01:12.48" && R.clock(0) == "00:00.00")
check("the Mac recording card's clock: 01:12, and hours past an hour", R.minutesClock(72.9) == "01:12" && R.minutesClock(0) == "00:00"
      && R.minutesClock(3672) == "1:01:12" && R.minutesClock(-4) == "00:00" && R.minutesClock(.nan) == "00:00")
check("the clock shows hours past an hour", R.clock(3672.5) == "1:01:12.50")

// MARK: - The recorder

let mockWords = "and the wagons out in the field by the shop in Ephrata. Chris mentioned the Lititz dealer wants a one-page sheet too."
let split = R.liveWords(mockWords)
check("the recorder's newest sentence is ink, everything before it mute (mockup PhoneRecorder)",
      split.older.hasSuffix("Ephrata.") && split.newest == "Chris mentioned the Lititz dealer wants a one-page sheet too.",
      "\(split.older) | \(split.newest)")
check("words still changing are always in the newest part",
      R.liveWords("One. Two three four", changing: 4).newest == "One. Two three four" && R.liveWords("One. Two three", changing: 1).older == "One.")
check("with no sentence end, the last eight words are ink", R.liveWords((1...12).map(String.init).joined(separator: " ")).older == "1 2 3 4")
check("a sentence end on the last word doesn't empty the newest part", R.liveWords("Done.").newest == "Done." && R.liveWords("Done.").older.isEmpty)
check("no words, no parts", R.liveWords("  ") == ("", ""))
check("the moments line: the count and the newest three times",
      R.momentsLine([31, 58]) == "2 moments \u{00B7} 0:31 \u{00B7} 0:58" && R.momentsLine([5]) == "1 moment \u{00B7} 0:05"
      && R.momentsLine([1, 2, 3, 4]) == "4 moments \u{00B7} 0:02 \u{00B7} 0:03 \u{00B7} 0:04" && R.momentsLine([]).isEmpty)
let spokenWeek = R.weekDaysSpoken([("Monday", 120, false, false), ("Tuesday", 0, false, false), ("Wednesday", 1, true, false),
                                   ("Thursday", 0, false, true), ("Friday", 1200, false, false)])
check("You's week reads each day for VoiceOver: words, no words, today, and days to come (review fix 5)",
      spokenWeek == "Monday, 120 words; Tuesday, no words; Wednesday, today, 1 word; Thursday, to come; Friday, \(1200.formatted()) words", spokenWeek)

let gmt = { () -> Calendar in var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date { gmt.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
let posix = Locale(identifier: "en_US_POSIX"), tuesday = day(2026, 10, 27, 15)
func short(_ d: Date) -> String { R.shortDay(d, now: tuesday, calendar: gmt, locale: posix) }
check("the Library's Date column: Today, a weekday this week, the month and day, then the year",
      short(day(2026, 10, 27, 1)) == "Today" && short(day(2026, 10, 26)) == "Mon" && short(day(2026, 10, 21)) == "Wed"
      && short(day(2026, 10, 20)) == "Oct 20" && short(day(2025, 3, 2)) == "Mar 2, 2025",
      [short(day(2026, 10, 27, 1)), short(day(2026, 10, 26)), short(day(2026, 10, 21)), short(day(2026, 10, 20)), short(day(2025, 3, 2))].joined(separator: " | "))
check("lengths read aloud", R.spokenTime(72) == "1 minute 12 seconds" && R.spokenTime(1) == "1 second" && R.spokenTime(0) == "0 seconds" &&
      R.spokenTime(3600) == "1 hour")

// MARK: - Settings

check("Settings' squares go persimmon, butter, sage, petal down a card, and around again",
      (0..<6).map { R.settingsHue($0) } == [.persimmon, .butter, .sage, .petal, .persimmon, .butter] && R.settingsHue(-1) == .petal)
check("a destructive row's square is neutral", R.settingsHue(0, destructive: true) == .neutral)
let paneRaws = ["general", "transcription", "dictate", "floatingButton", "meetings", "watched", "storage", "privacy", "account", "about", "features", "whatsNew"]
check("the Mac's panes follow the mockup: Personalization and Recording persimmon, Dictation butter, Privacy and Support neutral",
      R.settingsPaneHue("general") == .persimmon && R.settingsPaneHue("transcription") == .persimmon && R.settingsPaneHue("dictate") == .butter
      && R.settingsPaneHue("meetings") == .sage && R.settingsPaneHue("watched") == .butter && R.settingsPaneHue("storage") == .sage
      && R.settingsPaneHue("privacy") == .neutral && R.settingsPaneHue("account") == .petal && R.settingsPaneHue("about") == .neutral)
check("most of the Mac's panes carry a color", paneRaws.filter { R.settingsPaneHue($0) == .neutral }.count * 4 <= paneRaws.count)
check("your initial", R.initial(" tim medina") == "T" && R.initial("") == nil && R.initial("  ") == nil && R.initial("élise") == "É")

// MARK: - The transcript

check("a project's chip takes butter, sage, petal, then persimmon, and around again",
      (0..<6).map(R.projectHue) == [.butter, .sage, .petal, .persimmon, .butter, .sage] && R.projectHue(-1) == .persimmon)
let tz = TimeZone(identifier: "America/New_York")!
var tcal = Calendar(identifier: .gregorian); tcal.timeZone = tz
func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date { tcal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
let tnow = at(2026, 10, 28, 21, 0)
func when(_ d: Date) -> String {
    R.transcriptWhen(d, now: tnow, calendar: tcal, locale: Locale(identifier: "en_US"))
        .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}
check("a transcript's header says Today and Yesterday with the time, the weekday and date this year, and the year before",
      when(at(2026, 10, 28, 20, 35)) == "Today, 8:35 PM" && when(at(2026, 10, 27, 20, 35)) == "Yesterday, 8:35 PM"
      && when(at(2026, 10, 20, 9, 5)) == "Tuesday, Oct 20, 9:05 AM" && when(at(2025, 3, 2, 8, 0)) == "Mar 2, 2025, 8:00 AM",
      [when(at(2026, 10, 28, 20, 35)), when(at(2026, 10, 27, 20, 35)), when(at(2026, 10, 20, 9, 5)), when(at(2025, 3, 2, 8, 0))].joined(separator: " | "))
check("the meta line: when, the length, speakers from two, and the language; no length of zero",
      R.transcriptMeta(when: "Today, 8:35 PM", duration: 42, speakers: 1) == "Today, 8:35 PM \u{00B7} 0:42"
      && R.transcriptMeta(when: "Today, 8:35 PM", duration: 42, speakers: 2, language: "English") == "Today, 8:35 PM \u{00B7} 0:42 \u{00B7} 2 speakers \u{00B7} English"
      && R.transcriptMeta(when: "Today, 8:35 PM", duration: 0, speakers: 0) == "Today, 8:35 PM")

// MARK: - The sources

func read(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { print("FAIL can't read \(path)"); exit(1) }
    return s
}
let views = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let mac = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".."
let kitFiles = ["RefinedKit.swift", "RefinedPlayback.swift", "RefinedPages.swift"]
for f in kitFiles {
    let s = read("\(views)/\(f)")
    check("\(f) has no color literals", s.range(of: #"0x[0-9A-Fa-f]{6}|Color\((red|\.sRGB|hex)"#, options: .regularExpression) == nil)
    check("\(f) takes no old `Ink` tokens", s.range(of: #"\bInk\.(?!make)"#, options: .regularExpression) == nil)
    check("\(f) reads Limit animation, not only Reduce Motion", !s.contains("accessibilityReduceMotion") || s.contains("limitMotion"))
}
// One look (step 7): no target draws from the old tokens or reads a look setting any more.
var stale: [String] = []
let fm = FileManager.default
for dir in ["Verbatim", "VerbatimPhone", "VerbatimKeyboard", "VerbatimWidgets", "VerbatimMacWidgets", "VerbatimWatch",
            "VerbatimWatchWidgets", "VerbatimShare", "VerbatimBroadcast"] {
    guard let walk = fm.enumerator(atPath: "\(mac)/\(dir)") else { continue }
    for case let f as String in walk where f.hasSuffix(".swift") {
        let s = read("\(mac)/\(dir)/\(f)")
        if s.range(of: #"(?<![A-Za-z])(Ink|PremiumInk|NativeInk|PhoneInk)\.|\bAppLook\b|\.lookRoot\(|@Environment\(\\\.look\)"#, options: .regularExpression) != nil {
            stale.append("\(dir)/\(f)")
        }
    }
}
check("no target uses the old tokens or the look setting", stale.isEmpty, stale.joined(separator: ", "))
let kit = kitFiles.map { read("\(views)/\($0)") }.joined(separator: "\n")
for c in ["RecordCard", "ColorTile", "PaperCard", "KindBadge", "SpeakerChip", "KindChip", "IconSquare", "SectionTitle",
          "LargeSerifTitle", "ReadingText", "GlassPlayerBar", "RecorderClockPanel", "PaperRow", "WeekCard", "RecordingCard",
          "RefinedActionStyle", "RefinedChip", "RefinedSearchField", "IconSquareRow", "PaperTable", "PaperRowBackground",
          "RefinedSegmented", "KindPickerChip", "RefinedTagChips", "RefinedCircleButton", "TurnTime", "MomentChip", "AudioPlayerCard",
          "RecordingTimerCapsule", "MiniRecordingBar", "RecorderControl", "InitialBadge", "PaperSection",
          "RefinedPageHeader", "RefinedEmptyState", "PaperRowButton", "PaperGroup", "RefinedStatus"] {
    check("the kit has \(c) with a preview", kit.contains("struct \(c)") && kit.contains("\(c)_Previews"))
}
check("the kit reads the palette from where Settings stores it", kit.contains("AppPalette.key, store: AppearanceStore.defaults"))
check("the Record card draws its rings and disc in one coordinate system",
      kit.contains("struct RecordArtLayer") && kit.contains("RecordArtLayer(art: art") && kit.contains("RefinedRules.RecordArt.innerCenter")
      && !kit.contains("RecordDiscMark(size: 56)") && !kit.contains("RecordDiscMark(size: 40)"))
check("tile patterns are hidden from VoiceOver, off under Increase Contrast, and don't animate",
      kit.contains("struct TilePatternArt") && kit.contains("if let pattern, contrast != .increased")
      && kit.components(separatedBy: "struct TilePatternArt")[1].components(separatedBy: "// MARK: - Actions")[0].contains(".accessibilityHidden(true)")
      && !kit.components(separatedBy: "struct TilePatternArt")[1].components(separatedBy: "// MARK: - Actions")[0].contains("TimelineView")
      && !kit.components(separatedBy: "struct TilePatternArt")[1].components(separatedBy: "// MARK: - Actions")[0].contains("withAnimation"))
check("every tile pattern has a drawing", R.TilePattern.allCases.allSatisfy { kit.contains("case .\($0.rawValue):") })
check("Clean up in a row is a compact accent text action, not a capsule",
      kit.contains("struct RefinedTextActionStyle") && kit.contains("foregroundStyle(Refined.accentText)")
      && kit.contains(".font(.subheadline.weight(.semibold))"))

// Every tile in the catalog (Model/HomeLayout.swift) has a pattern.
let layoutSource = read("\(views)/../Model/HomeLayout.swift")
let tileBlock = layoutSource.components(separatedBy: "enum HomeTile: String, CaseIterable, Sendable {")[1].components(separatedBy: "var title: String")[0]
let tileRaws = tileBlock.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("case ") }
    .flatMap { $0.dropFirst(5).components(separatedBy: ",") }.map { c -> String in
        let parts = c.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : parts[0]
    }
check("the tile catalog was read", tileRaws.count >= 12 && tileRaws.contains("import") && tileRaws.contains("brainDump"), "\(tileRaws)")
let missingPatterns = tileRaws.filter { R.tilePattern(forTile: $0) == nil }
check("every Home tile has a line pattern", missingPatterns.isEmpty, "\(missingPatterns)")
check("tiles that do the same thing share a pattern, and Dictate, Import, What's playing, and New thought match the mockup",
      R.tilePattern(forTile: "whatsPlaying") == R.tilePattern(forTile: "appAudio") && R.tilePattern(forTile: "dictate") == .waves
      && R.tilePattern(forTile: "import") == .chevrons && R.tilePattern(forTile: "newThought") == .shortLines)
check("the player bar turns solid under Reduce Transparency", kit.contains("accessibilityReduceTransparency"))
check("cards take a hairline under Increase Contrast", kit.contains("colorSchemeContrast"))
check("the player ticks its moments on the iPhone's waveform as on the Mac's rail",
      kit.contains("drawMoments(ctx, size, top: 0, height: size.height)") && kit.contains("drawMoments(ctx, size, top: y - 3"))
check("a playing turn takes the playing wash, and a marked line the accent mark, never butter",
      kit.contains("playing ? Refined.playing") && kit.contains("art: .iconMarked, size: size, color: Refined.accentText"))
check("the segmented control draws the track token", kit.contains("Refined.track"))
check("the recorder's clocks are read on request, never announced on every tick", !kit.contains(".updatesFrequently"))
check("the recorder's Stop is the system red square", kit.contains("struct RecorderStopButton") && kit.contains("fill(Refined.recordRed).frame(width: 30, height: 30)"))

let tokens = read("\(views)/Tokens.swift")
let tableNames = Set((try! NSRegularExpression(pattern: #"static let (\w+) = (Tone|Wash)\("#)).matches(in: tokens, range: NSRange(tokens.startIndex..., in: tokens))
    .map { String(tokens[Range($0.range(at: 1), in: tokens)!]) })
check("the table was read", tableNames.count > 30, "\(tableNames.count)")
let rules = read("\(views)/RefinedRules.swift")
let unused = tableNames.filter { n in !tokens.contains("RefinedHex.\(n))") && !rules.contains("RefinedHex.\(n)") && !tokens.contains("Wash(\(n),") }
check("every value in the table is used", unused.isEmpty, "\(unused.sorted())")
let design = read("\(mac)/DESIGN.md")
let undocumented = tableNames.filter { !design.contains("`\($0)`") }
check("DESIGN.md §13 lists every value in the table", undocumented.isEmpty, "\(undocumented.sorted())")

// MARK: The Mac's recording date line, speakers' shares, Library table sort, and Back and Forward (RefinedRules.swift)


var mcal = Calendar(identifier: .gregorian)
mcal.timeZone = TimeZone(identifier: "America/New_York")!
let usLocale = Locale(identifier: "en_US")
func mdate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    mcal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}
let mnow = mdate(2026, 10, 23, 16, 0)
func spaced(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
check("today's recording", spaced(RecordingDateLine.line(mdate(2026, 10, 23, 9, 12), now: mnow, calendar: mcal, locale: usLocale)) == "Today · 9:12 AM",
      RecordingDateLine.line(mdate(2026, 10, 23, 9, 12), now: mnow, calendar: mcal, locale: usLocale))
check("yesterday's recording", spaced(RecordingDateLine.line(mdate(2026, 10, 22, 18, 20), now: mnow, calendar: mcal, locale: usLocale)) == "Yesterday · 6:20 PM")
let older = spaced(RecordingDateLine.line(mdate(2026, 10, 20, 14, 5), now: mnow, calendar: mcal, locale: usLocale))
check("an older recording names the day", older.hasPrefix("Tue, Oct 20") || older.hasPrefix("Tue Oct 20"), older)
let lastYear = spaced(RecordingDateLine.line(mdate(2025, 3, 2, 8, 0), now: mnow, calendar: mcal, locale: usLocale))
check("last year's recording has the year", lastYear.contains("2025") && lastYear.hasSuffix("8:00 AM"), lastYear)

// Speakers

let shares = SpeakerShares.compute([("Ginna", 40), ("Allie", 10), ("Ginna", 28), ("Allie", 22)])
check("speakers rank by talk time", shares.map(\.id) == ["Ginna", "Allie"])
check("68% and 32%", shares.map(\.percent) == [68, 32], "\(shares.map(\.percent))")
let thirds = SpeakerShares.compute([("A", 1), ("B", 1), ("C", 1)])
check("percents always add up to 100", thirds.map(\.percent).reduce(0, +) == 100, "\(thirds.map(\.percent))")
check("ties keep the order they first spoke in", thirds.map(\.id) == ["A", "B", "C"])
check("no talk time, no speakers", SpeakerShares.compute([("A", 0)]).isEmpty && SpeakerShares.compute([]).isEmpty)


typealias Cells = (name: String, kind: String, people: String, date: Date, length: Double)
let tableRows: [Cells] = [("Catalog call", "Meeting", "Anika", mdate(2026, 10, 23, 9, 0), 2292),
                     ("apple notes", "Thought", "", mdate(2026, 10, 22, 9, 0), 160),
                     ("Budget", "Journal", "Ben", mdate(2026, 10, 21, 9, 0), 372)]
func tableSorted(_ c: LibraryTableSort, _ d: Bool) -> [String] { tableRows.sorted { LibraryTableSort.ordered($0, $1, by: c, descending: d) }.map(\.name) }
check("sort by name, A to Z, ignoring case", tableSorted(.name, false) == ["apple notes", "Budget", "Catalog call"], "\(tableSorted(.name, false))")
check("sort by date, newest first", tableSorted(.date, true) == ["Catalog call", "apple notes", "Budget"])
check("sort by length, longest first", tableSorted(.length, true) == ["Catalog call", "Budget", "apple notes"])
check("rows with no people sort last either way", tableSorted(.people, false).last == "apple notes" && tableSorted(.people, true).last == "apple notes")
check("dates and lengths start newest and longest", LibraryTableSort.date.startsDescending && LibraryTableSort.length.startsDescending && !LibraryTableSort.name.startsDescending)
check("only the date sort keeps day headers", LibraryTableSort.allCases.filter(\.grouped) == [.date])
check("the table and the Library's sort agree", LibraryTableSort.librarySort(.date, descending: true) == "newest" && LibraryTableSort.librarySort(.name, descending: false) == "title"
      && LibraryTableSort.librarySort(.kind, descending: false) == nil)
check("a stored sort starts the table on its column", LibraryTableSort.column(forLibrarySort: "longest") == (.length, true) && LibraryTableSort.column(forLibrarySort: "newest") == (.date, true))
check("the refined Library's sort menu says Newest first, as the mockup", LibraryTableSort.date.title(descending: true) == "Newest first"
      && LibraryTableSort.date.title(descending: false) == "Oldest first" && LibraryTableSort.length.title(descending: false) == "Shortest first"
      && LibraryTableSort.name.title(descending: false) == "Title A–Z")
check("every column and direction has its own sort title", Set(LibraryTableSort.allCases.flatMap { [$0.title(descending: true), $0.title(descending: false)] }).count == 10)
check("the table's columns are the mockup's", LibraryTableSort.allCases.map(\.header) == ["Name", "Kind", "People or source", "Date", "Length"])

// Back and forward

var nh = NavHistory<String>()
nh.visit("library"); nh.visit("t1")
check("back goes where you were", nh.canGoBack && nh.goBack() == "library" && nh.current == "library")
check("forward returns", nh.canGoForward && nh.goForward() == "t1" && !nh.canGoForward)
_ = nh.goBack(); nh.visit("home")
check("a new place clears forward", !nh.canGoForward && nh.current == "home")
nh.visit("home")
check("visiting where you are changes nothing", nh.back == ["library"])
var ng = NavHistory<String>()
for s in ["home", "t1", "library", "t1", "t2"] { ng.visit(s) }
ng.removeAll { $0 == "t1" }
check("a deleted transcript leaves the history", !ng.back.contains("t1") && ng.back == ["home", "library"], "\(ng.back)")
var nlong = NavHistory<Int>(); nlong.limit = 3
for i in 0..<10 { nlong.visit(i) }
check("history keeps a limit", nlong.back == [6, 7, 8])
check("nothing to go back to", NavHistory<Int>().canGoBack == false && { var e = NavHistory<Int>(); return e.goBack() == nil }())
var nr = NavHistory<String>()
nr.replaceCurrent("library")
check("replacing with nothing there starts the trail", nr.current == "library" && !nr.canGoBack)
nr.visit("t1"); _ = nr.goBack(); nr.replaceCurrent("library:A")
check("a place changed in place keeps Forward", nr.current == "library:A" && nr.canGoForward && nr.previous == nil)
nr.visit("home"); nr.visit("library:B"); nr.replaceCurrent("home")
check("a replacement that meets Back's last entry collapses", nr.back == ["library:A"] && nr.current == "home", "\(nr.back)")
check("previous names where Back goes", nr.previous == "library:A")

// A Mac Home tile's trailing text (review fix 9): a state takes its own line and speaks as a state; only a shortcut
// is "Shortcut:", and a state isn't said twice in the value.
typealias TT = R.TileTrailing
let keys: (String) -> String = { $0.map { ["⌘": "Command", "⌥": "Option", "⌃": "Control"][$0] ?? String($0) }.joined(separator: " ") }
let needsAX = TT.state("Needs Accessibility", spoken: "Needs Accessibility access. Opens the setup.")
check("tile: a state always takes its own line under the name; a shortcut only when it doesn't fit",
      needsAX.alwaysBelow && TT.state("Drop to transcribe", spoken: "x").alwaysBelow && TT.state("On screen now", spoken: "x").alwaysBelow
      && !TT.shortcut("⌘O").alwaysBelow)
check("tile: a state's hint is the state, never \"Shortcut:\"",
      needsAX.hint(spokenKeys: keys) == "Needs Accessibility access. Opens the setup." && !needsAX.hint(spokenKeys: keys).hasPrefix("Shortcut"))
check("tile: a shortcut's hint names its keys", TT.shortcut("⌥⌘C").hint(spokenKeys: keys) == "Shortcut: Option Command C")
check("tile: a state matching the detail is said once",
      needsAX.value(detail: "Needs Accessibility", spokenKeys: keys) == "Needs Accessibility"
      && TT.state("On screen now", spoken: "Live captions are on screen.").value(detail: "On screen now", spokenKeys: keys) == "On screen now")
check("tile: a shortcut follows the detail", TT.shortcut("⌘O").value(detail: "Files or a link", spokenKeys: keys) == "Files or a link Command O")
let homeView = read("\(views)/HomeView.swift")
check("tile: the Mac's Home gives its states as states, and the kit's tile hint isn't a fixed \"Shortcut:\"",
      homeView.contains(".state(\"Needs Accessibility\", spoken: \"Needs Accessibility access. Opens the setup.\")")
      && homeView.contains(".state(\"Drop to transcribe\"") && homeView.contains(".state(\"On screen now\"")
      && !kit.contains("\"Shortcut: \" + Keycap.spoken") && kit.contains("trailing?.hint(spokenKeys: Keycap.spoken)"))

// You's week card reads the days for VoiceOver, built from the week's days (review fix 5).
let youScreen = read("\(mac)/VerbatimPhone/YouScreen.swift")
check("the iPhone You page's week card has the words-by-day value",
      youScreen.contains(".accessibilityValue(week.spokenDays)") && read("\(views)/HomeKit.swift").contains("RefinedRules.weekDaysSpoken(days.map"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
