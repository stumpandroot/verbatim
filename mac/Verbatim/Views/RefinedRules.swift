import Foundation

// The refined look's pure rules (DESIGN.md §13): the Palette setting, which fill each hue gets in each palette and
// what sits on it, the kinds' colors, the speakers' fixed rotation, the type sizes and radii on each device, and the
// WCAG contrast math, and the Mac's recording date line, speakers' shares, Library table sort, and Back and Forward
// history. Foundation only, so mac/tools/test-refined.sh compiles it on Linux with the `RefinedHex` table it lifts out
// of Views/Tokens.swift. The SwiftUI kit (Views/RefinedKit.swift, Views/RefinedPlayback.swift) reads everything here;
// it never picks a fill on its own.

/// Settings › Personalization › Palette: how much color the refined look puts on its big surfaces. Stored per device
/// with the other appearance settings (`AppearanceStore`: the App Group on iPhone, the Mac's own defaults), never synced.
enum AppPalette: String, CaseIterable, Identifiable, Sendable {
    /// The brand fills: the persimmon Record card, butter, sage, and petal tiles. The default.
    case full
    /// Light tints of the same four, with ink on them.
    case soft

    var id: String { rawValue }
    static let key = "appearance.palette"

    var label: String {
        switch self {
        case .full: return "Full"
        case .soft: return "Soft"
        }
    }

    var detail: String {
        switch self {
        case .full: return "A persimmon Record card and bright tiles"
        case .soft: return "Light tints on the Record card and tiles"
        }
    }

    /// The stored value; nothing stored (a new install) or anything unknown reads as Full.
    init(stored: String?) { self = stored.flatMap(AppPalette.init(rawValue:)) ?? .full }
}

/// The four brand hues, plus neutral (the off-white card). One color, one meaning holds by place: on Home's tiles a
/// hue says which action; on a kind badge it says which kind; on a speaker chip it only tells speakers apart.
enum RefinedHue: String, CaseIterable, Sendable {
    case persimmon, butter, sage, petal, neutral
}

enum RefinedRules {
    // MARK: Palette

    /// The fill of a palette surface (the Record card and Home's tiles). Full uses the brand fills, Soft their tints;
    /// neutral is the card in both.
    static func fill(_ hue: RefinedHue, palette: AppPalette) -> RefinedHex.Tone {
        switch (hue, palette) {
        case (.neutral, _): return RefinedHex.card
        case (_, .full): return badgeFill(hue)
        case (.persimmon, .soft): return RefinedHex.persimmonTint
        case (.butter, .soft): return RefinedHex.butterTint
        case (.sage, .soft): return RefinedHex.sageTint
        case (.petal, .soft): return RefinedHex.petalTint
        }
    }

    /// Text and glyphs on a palette surface: ink fixed on a Full fill (the fills stay light in dark mode), the
    /// reading ink on a Soft tint or the card (they turn dark in dark mode).
    static func onFill(_ hue: RefinedHue, palette: AppPalette) -> RefinedHex.Tone {
        hue != .neutral && palette == .full ? RefinedHex.onFill : RefinedHex.ink
    }

    /// The Record card's fill, its rings, and its ready chip.
    static func recordFill(_ palette: AppPalette) -> RefinedHex.Tone { fill(.persimmon, palette: palette) }
    static func recordInk(_ palette: AppPalette) -> RefinedHex.Tone { onFill(.persimmon, palette: palette) }
    static func rings(_ palette: AppPalette) -> RefinedHex.Wash { palette == .full ? RefinedHex.ringFull : RefinedHex.ringSoft }
    static func readyChip(_ palette: AppPalette) -> RefinedHex.Wash { palette == .full ? RefinedHex.chipFull : RefinedHex.chipSoft }

    /// Which surfaces follow the palette. Kind badges, speaker and kind chips, and icon squares are small and keep
    /// the Full fills in both palettes, as in the mockup.
    static let paletteSurfaces = ["Record card", "tiles", "recorder clock panel"]

    // MARK: Badges, chips, and squares

    /// The Full fill for a hue (kind badges, chips, icon squares). Neutral is the icon square's quiet fill.
    static func badgeFill(_ hue: RefinedHue) -> RefinedHex.Tone {
        switch hue {
        case .persimmon: return RefinedHex.persimmon
        case .butter: return RefinedHex.butter
        case .sage: return RefinedHex.sage
        case .petal: return RefinedHex.petal
        case .neutral: return RefinedHex.neutralSquare
        }
    }

    /// The glyph or text on a badge: ink fixed on a hue, the reading ink on the neutral square.
    static func onBadge(_ hue: RefinedHue) -> RefinedHex.Tone { hue == .neutral ? RefinedHex.ink : RefinedHex.onFill }

    /// A kind's color, by `RecordingKind` raw value (nil is a voice note: a recording Verbose hasn't given a kind).
    /// Meeting and voice note persimmon, interview and talk sage, audio and journal petal, thought and brain dump
    /// butter. The kinds the mockup doesn't show follow what they are: a note is a voice note, a dictation is
    /// butter (Dictate), a podcast petal (listening), a video sage (imported).
    static func kindHue(_ raw: String?) -> RefinedHue {
        switch raw {
        case nil, "note", "meeting": return .persimmon
        case "interview", "talk", "video": return .sage
        case "audio", "journal", "podcast": return .petal
        case "idea", "brainDump", "dictation": return .butter
        default: return .persimmon
        }
    }

    /// Speakers in a transcript take the four hues in a fixed order by speaker order, and around again. The name is
    /// always on the chip; the hue only tells speakers apart.
    static let speakerRotation: [RefinedHue] = [.persimmon, .petal, .sage, .butter]
    static func speakerHue(_ index: Int) -> RefinedHue {
        let n = speakerRotation.count
        return speakerRotation[((index % n) + n) % n]
    }

    /// A project's chip in a transcript's header takes a hue by the project's color index: butter, sage, petal, then
    /// persimmon, and around again.
    static func projectHue(_ colorIndex: Int) -> RefinedHue {
        let hues: [RefinedHue] = [.butter, .sage, .petal, .persimmon]
        return hues[((colorIndex % hues.count) + hues.count) % hues.count]
    }

    // MARK: Settings

    /// The iPhone's Settings rows take their icon squares' hues in turn down each card (mockup PhoneSettings):
    /// persimmon, butter, sage, petal, and around again. A destructive row's square is neutral, with a red title.
    static let settingsRotation: [RefinedHue] = [.persimmon, .butter, .sage, .petal]
    static func settingsHue(_ index: Int, destructive: Bool = false) -> RefinedHue {
        if destructive { return .neutral }
        let n = settingsRotation.count
        return settingsRotation[((index % n) + n) % n]
    }

    /// A Mac Settings pane's square in the sidebar and beside its title, by `SettingsTab` raw value (mockup
    /// MacSettings): Personalization and Recording persimmon, Dictation and Watched folders butter, Ribbon and notch,
    /// Account, and What's new petal, Meetings, Sync, and Features sage, and Privacy and Support neutral.
    static func settingsPaneHue(_ raw: String) -> RefinedHue {
        switch raw {
        case "general", "transcription": return .persimmon
        case "dictate", "watched": return .butter
        case "floatingButton", "account", "whatsNew": return .petal
        case "meetings", "storage", "features": return .sage
        default: return .neutral
        }
    }

    /// Your initial on the You card and the You page: the first letter of your name, capitalized; nil without a name
    /// (the badge shows a person instead).
    static func initial(_ name: String) -> String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
    }

    // MARK: Type and size

    /// The kit's type roles. Serif (New York) for large titles, section titles, the Record card's title, and the
    /// transcript's reading text; SF Pro for everything else.
    enum TextRole: CaseIterable, Sendable {
        case largeTitle, transcriptTitle, sectionTitle, recordTitle, reading, body, rowTitle, hint, meta, chip, tileName, caption, clock

        var serif: Bool {
            switch self {
            case .largeTitle, .transcriptTitle, .sectionTitle, .recordTitle, .reading: return true
            default: return false
            }
        }

        /// Point size at the default text size (iPhone) or on the Mac. iPhone sizes scale with Dynamic Type.
        func size(mac: Bool) -> Double {
            switch self {
            case .largeTitle: return mac ? 36 : 34
            case .transcriptTitle: return mac ? 32 : 28
            case .sectionTitle: return mac ? 20 : 22
            case .recordTitle: return mac ? 34 : 32
            case .reading: return mac ? 18 : 19
            case .body: return mac ? 13.5 : 16
            case .rowTitle: return mac ? 13.5 : 16
            case .hint: return mac ? 13.5 : 14
            case .meta: return mac ? 12.5 : 13
            case .chip: return mac ? 12 : 13
            case .tileName: return mac ? 15 : 16
            case .caption: return mac ? 11 : 12
            case .clock: return mac ? 34 : 60
            }
        }

        /// Line height as a multiple of the size (the mockup's CSS line-height); only reading text sets it.
        func lineHeight(mac: Bool) -> Double {
            self == .reading ? (mac ? 1.55 : 1.45) : 1.2
        }
    }

    /// SwiftUI's `lineSpacing` (the space added between lines) for a role: the line height less the font's own
    /// line, which is about 1.2 times its size.
    static func lineSpacing(_ role: TextRole, mac: Bool) -> Double {
        max(0, (role.lineHeight(mac: mac) - 1.2) * role.size(mac: mac))
    }

    /// The smallest tap target (Apple's 44 pt).
    static let minTapTarget: Double = 44

    enum RadiusRole: CaseIterable, Sendable {
        /// Grouped cards (Library rows, Settings groups, Recent).
        case card
        /// Home's tiles.
        case tile
        /// The Record card and the recorder's clock panel.
        case record
        /// Icon squares.
        case square
        /// Search fields.
        case field
    }

    static func radius(_ role: RadiusRole, mac: Bool) -> Double {
        switch role {
        case .card: return mac ? 12 : 14
        case .tile: return mac ? 14 : 16
        case .record: return mac ? 18 : 22
        case .square: return mac ? 6 : 8
        case .field: return mac ? 8 : 10
        }
    }

    // MARK: The Record card's drawing

    /// Where the Record card's rings and record disc sit. The rings are three circles on one vertical axis (radii
    /// 120, 90, and 60 in a 300-unit square, centered at y 150, 180, and 210); the disc sits at the center of the
    /// innermost one, so the two are placed together from one point: the disc's center, inset from the card's
    /// trailing edge and from its bottom (or its middle, in the slim Compact row). The rings grow out of that point,
    /// so the disc stays centered at every card size, with Dynamic Type, and in both palettes.
    struct RecordArt: Equatable, Sendable {
        /// The rings' square side.
        var side: Double
        /// The disc's diameter.
        var disc: Double
        /// The disc's center from the card's trailing edge.
        var trailing: Double
        /// The disc's center from the card's bottom edge; nil centers it vertically (Compact).
        var bottom: Double?
        /// The text's horizontal padding, for the room the text leaves the disc.
        var padding: Double

        /// The innermost ring's center in the rings' square, as fractions of its side (150/300, 210/300).
        static let innerCenter = (x: 0.5, y: 0.7)

        /// The disc's center on a card of this size.
        func discCenter(width: Double, height: Double) -> (x: Double, y: Double) {
            (width - trailing, bottom.map { height - $0 } ?? height / 2)
        }

        /// The rings' square on a card of this size: its top-left corner, so its innermost circle centers on the disc.
        func ringOrigin(width: Double, height: Double) -> (x: Double, y: Double) {
            let c = discCenter(width: width, height: height)
            return (c.x - side * Self.innerCenter.x, c.y - side * Self.innerCenter.y)
        }

        /// The width the text keeps clear at its trailing edge, past its own padding, so it never runs under the disc.
        var textReserve: Double { trailing + disc / 2 - padding }
    }

    /// iPhone: the mockup's 210 pt rings and 56 pt disc, the disc's center 59 pt from the trailing edge and 35 from the
    /// bottom (on the 168 pt card that's the mockup's rings at right −46, top −14, and its disc at right 31, top 105).
    /// Mac: 260 pt rings around the disc where the mockup puts it (22 pt in from the trailing edge, 18 from the
    /// bottom). Compact: 140 pt rings around a 40 pt disc, centered in the slim row.
    static func recordArt(mac: Bool, compact: Bool) -> RecordArt {
        switch (mac, compact) {
        case (false, false): return RecordArt(side: 210, disc: 56, trailing: 59, bottom: 35, padding: 18)
        case (true, false): return RecordArt(side: 260, disc: 56, trailing: 50, bottom: 46, padding: 22)
        case (false, true): return RecordArt(side: 140, disc: 40, trailing: 36, bottom: nil, padding: 16)
        case (true, true): return RecordArt(side: 140, disc: 40, trailing: 40, bottom: nil, padding: 20)
        }
    }

    // MARK: Tile patterns

    /// A Home tile's quiet line pattern in its top-right corner (mockup: Home), by what the tile does.
    enum TilePattern: String, CaseIterable, Sendable {
        /// Dictate: stacked sine lines.
        case waves
        /// Import: stacked down-pointing chevrons.
        case chevrons
        /// What's playing and App audio: offset circles sharing one side.
        case offsetCircles
        /// New thought: short lines.
        case shortLines
        /// Live captions: caption lines of different lengths, centered in pairs.
        case captionLines
        /// Dictionary: an open book's page lines either side of its spine.
        case pageLines
        /// Journal: a page with its corner curling.
        case pageCurl
        /// Brain dump: checklist ticks with their lines.
        case checklist
        /// Projects: a folder with its tab, and one behind it.
        case folderTab
        /// Today's page: thought bubbles rising.
        case bubbles
        /// Dictations: one wave over ruled lines.
        case dictationLines
    }

    /// The pattern for a tile, by `HomeTile`'s raw value. Every tile in the catalog has one; an unknown tile has none.
    static func tilePattern(forTile raw: String) -> TilePattern? {
        switch raw {
        case "dictate": return .waves
        case "import": return .chevrons
        case "whatsPlaying", "appAudio": return .offsetCircles
        case "newThought": return .shortLines
        case "captions": return .captionLines
        case "dictionary": return .pageLines
        case "journal": return .pageCurl
        case "brainDump": return .checklist
        case "projects": return .folderTab
        case "thoughtPad": return .bubbles
        case "dictations": return .dictationLines
        default: return nil
        }
    }

    /// The pattern's ink: 13% on a Full fill, 9% on a Soft tint and on the off-white tile. Hidden under Increase
    /// Contrast.
    static func tilePatternInk(_ hue: RefinedHue, palette: AppPalette) -> RefinedHex.Wash {
        hue != .neutral && palette == .full ? RefinedHex.patternFull : RefinedHex.patternSoft
    }

    /// An icon square's side and the glyph inside it.
    static func squareSize(mac: Bool) -> (side: Double, glyph: Double) { mac ? (22, 16) : (30, 18) }

    // MARK: Times

    /// A time or length as the player and rows show it: "0:07", "12:30", "1:02:14".
    static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The recorder's clock, with hundredths: "01:12.48", and "1:01:12.48" past an hour.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int((seconds.isFinite ? seconds : 0) * 100))
        let cs = total % 100, s = total / 100
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, sec, cs) : String(format: "%02d:%02d.%02d", m, sec, cs)
    }

    /// The Mac recording card's clock: "01:12", and "1:01:12" past an hour.
    static func minutesClock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// A length read aloud: "1 minute 12 seconds".
    static func spokenTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        func unit(_ n: Int, _ one: String) -> String? { n == 0 ? nil : "\(n) \(one)\(n == 1 ? "" : "s")" }
        let parts = [unit(h, "hour"), unit(m, "minute"), unit(sec, "second")].compactMap { $0 }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    // MARK: The recorder

    /// The recorder's live words split for drawing (mockup PhoneRecorder): what's older in `mute`, and the newest in
    /// ink. The newest part starts after the last sentence that ended before the final word, and always holds the
    /// words still changing (`changing`, counted from the end). With no sentence end, the last `newestWords` are ink.
    static func liveWords(_ text: String, changing: Int = 0, newestWords: Int = 8) -> (older: String, newest: String) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let n = words.count
        guard n > 0 else { return ("", "") }
        var start = 0
        if n > 1, let end = words[..<(n - 1)].lastIndex(where: { w in [".", "?", "!", "\u{2026}"].contains { w.hasSuffix($0) } }) {
            start = end + 1
        } else {
            start = max(0, n - max(1, newestWords))
        }
        start = min(start, max(0, n - max(0, changing)))
        return (words[..<start].joined(separator: " "), words[start...].joined(separator: " "))
    }

    /// The recorder's moments line: "2 moments · 0:31 · 0:58", with the newest three times. Empty with none.
    static func momentsLine(_ times: [Double]) -> String {
        guard !times.isEmpty else { return "" }
        let count = times.count == 1 ? "1 moment" : "\(times.count) moments"
        return ([count] + times.suffix(3).map { time($0) }).joined(separator: " \u{00B7} ")
    }

    /// A day as the Mac Library's Date column says it (mockup MacLibrary): "Today", the weekday for the rest of the
    /// last week ("Mon"), the month and day this year ("Oct 12"), and the date with its year before that ("Oct 12, 2025").
    static func shortDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        func formatted(_ template: String) -> String {
            let f = DateFormatter()
            f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let today = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), date >= weekAgo, date < today { return formatted("EEE") }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return formatted("MMM d") }
        return formatted("MMM d yyyy")
    }

    /// When a transcript was recorded, as its header says it (mockup: transcript): "Today, 8:35 PM", "Yesterday,
    /// 8:35 PM", the weekday with the date this year ("Tuesday, Oct 27, 8:35 PM"), and the date with its year before
    /// that ("Oct 27, 2025, 8:35 PM").
    static func transcriptWhen(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        func formatted(_ template: String) -> String {
            let f = DateFormatter()
            f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        let time = formatted("jmm")
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday, \(time)" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return "\(formatted("EEEEMMMd")), \(time)" }
        return "\(formatted("MMMdyyyy")), \(time)"
    }

    /// The transcript header's meta line after its chips: when, the length, the speakers ("2 speakers"), and the
    /// language, joined with middle dots. A length of zero (a dictation's text, a link still coming) is left out.
    static func transcriptMeta(when: String, duration: Double, speakers: Int, language: String? = nil) -> String {
        var parts = [when]
        if duration > 0 { parts.append(time(duration)) }
        if speakers >= 2 { parts.append("\(speakers) speakers") }
        if let language, !language.isEmpty { parts.append(language) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Contrast (WCAG 2.x)

    /// Relative luminance of an sRGB color given as 0xRRGGBB.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// The contrast ratio between two opaque colors, 1...21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// A wash laid over an opaque color, as the opaque color you see.
    static func over(_ wash: RefinedHex.Wash, _ under: UInt32, dark: Bool, increased: Bool) -> UInt32 {
        blend(wash.base.value(dark: dark, increased: increased), wash.alpha(dark: dark, increased: increased), under)
    }

    static func blend(_ top: UInt32, _ alpha: Double, _ under: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for shift in [16, 8, 0] as [UInt32] {
            let t = Double((top >> shift) & 0xFF), u = Double((under >> shift) & 0xFF)
            out |= UInt32((t * alpha + u * (1 - alpha)).rounded()) << shift
        }
        return out
    }
}

// MARK: - Recordings, the Library table, and the window's history (Mac)

/// A recording's date line on Home's recent rows.
enum RecordingDateLine {
    /// "Today · 9:12 AM", "Yesterday · 6:20 PM", "Thu Oct 22 · 2:05 PM", or with the year when it isn't this year.
    static func line(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale; time.timeZone = calendar.timeZone
        time.dateStyle = .none; time.timeStyle = .short
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            day = "Yesterday"
        } else {
            let f = DateFormatter()
            f.locale = locale; f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "EEE MMM d" : "MMM d yyyy")
            day = f.string(from: date)
        }
        return "\(day) · \(time.string(from: date))"
    }
}

/// Who talked how much, for the transcript's Speakers box.
enum SpeakerShares {
    struct Share: Equatable { var id: String; var seconds: Double; var percent: Int }

    /// Talk time per speaker, most first (ties keep first-seen order), with whole percents that add up to 100
    /// (largest remainder). Speakers with no time are left out.
    static func compute(_ turns: [(speaker: String, seconds: Double)]) -> [Share] {
        var order: [String] = []
        var total: [String: Double] = [:]
        for t in turns where t.seconds > 0 {
            if total[t.speaker] == nil { order.append(t.speaker) }
            total[t.speaker, default: 0] += t.seconds
        }
        let sum = total.values.reduce(0, +)
        guard sum > 0 else { return [] }
        let ranked = order.enumerated().sorted { a, b in
            let x = total[a.element]!, y = total[b.element]!
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        let exact = ranked.map { total[$0]! / sum * 100 }
        var whole = exact.map { Int($0.rounded(.down)) }
        var left = 100 - whole.reduce(0, +)
        let byRemainder = exact.indices.sorted { (exact[$0] - Double(whole[$0])) > (exact[$1] - Double(whole[$1])) }
        for i in byRemainder where left > 0 { whole[i] += 1; left -= 1 }
        return ranked.indices.map { Share(id: ranked[$0], seconds: total[ranked[$0]]!, percent: whole[$0]) }
    }
}

/// The Library table's columns and how each one sorts. Sorting by date keeps the day headers (Today, Yesterday);
/// any other column lists the recordings flat, as Finder does.
enum LibraryTableSort: String, CaseIterable {
    case name, kind, people, date, length

    /// Each column's first click: dates and lengths newest and longest first, words A to Z.
    var startsDescending: Bool { self == .date || self == .length }

    /// The Library's sort (LibrarySort's raw value: newest, oldest, longest, title) for a column and direction, when
    /// there is one.
    static func librarySort(_ column: LibraryTableSort, descending: Bool) -> String? {
        switch (column, descending) {
        case (.date, true): return "newest"
        case (.date, false): return "oldest"
        case (.length, true): return "longest"
        case (.name, false): return "title"
        default: return nil
        }
    }

    /// The column and direction a stored Library sort starts the table on.
    static func column(forLibrarySort raw: String) -> (LibraryTableSort, Bool) {
        switch raw {
        case "oldest": return (.date, false)
        case "longest": return (.length, true)
        case "title": return (.name, false)
        default: return (.date, true)
        }
    }

    /// Whether the table shows day headers: only while it's sorted by date.
    var grouped: Bool { self == .date }

    /// The refined Library's sort, as its menu at the end of the chips says it (mockup MacLibrary): "Newest first",
    /// "Oldest first", "Longest first", "Shortest first", and "Title A–Z", "Kind Z–A", and so on for the words.
    func title(descending: Bool) -> String {
        switch self {
        case .date: return descending ? "Newest first" : "Oldest first"
        case .length: return descending ? "Longest first" : "Shortest first"
        case .name: return descending ? "Title Z–A" : "Title A–Z"
        case .kind: return descending ? "Kind Z–A" : "Kind A–Z"
        case .people: return descending ? "People Z–A" : "People A–Z"
        }
    }

    /// The column's title in the refined Library's table.
    var header: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .people: return "People or source"
        case .date: return "Date"
        case .length: return "Length"
        }
    }

    /// Orders two rows by this column's values; ties keep the newest first.
    static func ordered(_ a: (name: String, kind: String, people: String, date: Date, length: Double),
                        _ b: (name: String, kind: String, people: String, date: Date, length: Double),
                        by column: LibraryTableSort, descending: Bool) -> Bool {
        func cmp(_ x: String, _ y: String) -> ComparisonResult { x.localizedStandardCompare(y) }
        let r: ComparisonResult
        switch column {
        case .name: r = cmp(a.name, b.name)
        case .kind: r = cmp(a.kind, b.kind)
        case .people:
            // Rows with no people sort after the rest either way.
            if a.people.isEmpty != b.people.isEmpty { return !a.people.isEmpty }
            r = cmp(a.people, b.people)
        case .date: r = a.date == b.date ? .orderedSame : (a.date < b.date ? .orderedAscending : .orderedDescending)
        case .length: r = a.length == b.length ? .orderedSame : (a.length < b.length ? .orderedAscending : .orderedDescending)
        }
        if r == .orderedSame { return a.date > b.date }
        return descending ? r == .orderedDescending : r == .orderedAscending
    }
}

/// Back and forward through the screens you visited (the window's Back and Forward, App/NavTrail.swift), like a
/// browser's history: going somewhere new starts a new trail from here (Forward clears), and Back and Forward walk it.
struct NavHistory<Element: Equatable> {
    private(set) var back: [Element] = []
    private(set) var forward: [Element] = []
    private(set) var current: Element?
    var limit = 50

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// You went somewhere new: the place you left goes on the back list and the forward list clears. Going to the
    /// place you're on changes nothing.
    mutating func visit(_ e: Element) {
        guard e != current else { return }
        if let c = current { back.append(c); if back.count > limit { back.removeFirst(back.count - limit) } }
        forward.removeAll()
        current = e
    }

    /// Where Back goes, without going.
    var previous: Element? { back.last }

    /// The place you're on changed in place (the Library showing another project): the trail keeps its shape.
    mutating func replaceCurrent(_ e: Element) {
        guard current != nil else { current = e; return }
        current = e
        if back.last == e { back.removeLast() }
    }

    /// Steps back: returns where to go, and keeps the place you left for Forward.
    mutating func goBack() -> Element? {
        guard let prev = back.popLast() else { return nil }
        if let c = current { forward.append(c) }
        current = prev
        return prev
    }

    /// Steps forward again after Back.
    mutating func goForward() -> Element? {
        guard let next = forward.popLast() else { return nil }
        if let c = current { back.append(c) }
        current = next
        return next
    }

    /// Drops every entry that no longer exists (a deleted transcript), so Back never lands on nothing.
    mutating func removeAll(where gone: (Element) -> Bool) {
        back.removeAll(where: gone)
        forward.removeAll(where: gone)
        // Two entries that met after a removal collapse into one.
        let b = back
        back = b.enumerated().filter { i, e in i == 0 || b[i - 1] != e }.map(\.element)
        if let c = current, back.last == c { back.removeLast() }
    }
}
