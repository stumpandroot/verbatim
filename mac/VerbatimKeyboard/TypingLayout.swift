import Foundation

// The typing layout's pure rules: which keys each layer has, where they sit, which key a touch lands on, and the
// shift, auto-capitalization, and double-space decisions. Foundation only (no UIKit), so
// mac/tools/test-keyboard.sh compiles and checks it on Linux. `TypingModel` (TypingKeys.swift) applies it to
// the text field.

// MARK: - Surfaces

/// The keyboard's two views: dictation (the record card) and typing (letter keys).
enum KeyboardSurface: String, Equatable {
    case dictation, typing

    /// The extension's own defaults key for the last view you used. Not the App Group: it works without Full Access.
    static let rememberedKey = "kb.surface"

    /// The view the keyboard opens in. Without Full Access, dictation can't work, so it always opens in typing.
    /// Number pads open in typing too. With Full Access, the last view you used, or dictation the first time.
    static func initial(remembered: String?, hasFullAccess: Bool, field: FieldKind) -> KeyboardSurface {
        guard hasFullAccess else { return .typing }
        if field == .numberPad || field == .decimalPad { return .typing }
        return remembered.flatMap(KeyboardSurface.init(rawValue:)) ?? .dictation
    }

    var toggled: KeyboardSurface { self == .dictation ? .typing : .dictation }
}

// MARK: - Field traits

/// What kind of text field you're typing in, from its `keyboardType`.
enum FieldKind: Equatable {
    case standard, email, url, numbersAndPunctuation, numberPad, decimalPad
}

/// The field's `autocapitalizationType`.
enum AutoCapMode: Equatable {
    case none, words, sentences, allCharacters
}

/// The field's `returnKeyType`, as the return key shows it.
enum ReturnKind: Equatable {
    case standard, go, search, join, next, route, send, done, emergencyCall, `continue`

    /// The key's word, in sentence case. Nil for the plain return key, which shows the return symbol.
    var label: String? {
        switch self {
        case .standard: return nil
        case .go: return "Go"
        case .search: return "Search"
        case .join: return "Join"
        case .next: return "Next"
        case .route: return "Route"
        case .send: return "Send"
        case .done: return "Done"
        case .emergencyCall: return "Emergency call"
        case .continue: return "Continue"
        }
    }

    /// What VoiceOver says for the key.
    var spoken: String { label ?? "Return" }

    /// An action key (Go, Send, Search) gets the ink fill, like the system's blue return key.
    var isAction: Bool { self != .standard }
}

// MARK: - Keys

enum TypingLayer: Equatable {
    case letters, numbers, symbols
}

enum ShiftState: Equatable {
    case off, on, locked
}

enum KeyKind: Equatable, Hashable {
    /// Inserts this text (letters follow shift).
    case character(String)
    case shift, delete, space, returnKey, globe
    /// Switches to a layer: "123", "#+=", or "ABC".
    case layer(TypingLayer)
}

/// How wide a key or gap is: in letter-key units, or a share of what's left in the row.
enum KeyWidth: Equatable {
    case units(Double)
    case flex(Double)
}

/// One item in a row: a key, or an empty stretch (no key, no gaps around it) that centers or spreads the keys.
enum RowItem: Equatable {
    case key(KeyKind, KeyWidth)
    case spacer(Double)

    static func char(_ s: String, _ w: Double = 1) -> RowItem { .key(.character(s), .units(w)) }
}

struct KeyID: Hashable {
    var row: Int
    var index: Int
}

/// A key with its place in the key area.
struct PlacedKey: Identifiable, Equatable {
    var id: KeyID
    var kind: KeyKind
    var frame: CGRect
}

/// Spacing that follows the system keyboard on iPhone: 3 pt side margins, 6 pt between keys, 11 pt between rows
/// (less when the key area is short), and keys at most 46 pt tall.
struct KeyMetrics: Equatable {
    var sideMargin: CGFloat = 3
    var keyGap: CGFloat = 6
    var rowGap: CGFloat = 11
    var topInset: CGFloat = 6
    var bottomInset: CGFloat = 4
    var maxKeyHeight: CGFloat = 46
    var minKeyHeight: CGFloat = 30

    /// Metrics for a key area of this size. Wide areas (landscape, iPad) get wider margins and gaps.
    static func forSize(_ size: CGSize, rows: Int) -> KeyMetrics {
        var m = KeyMetrics()
        if size.width > 600 { m.sideMargin = 6; m.keyGap = 7 }
        let n = CGFloat(max(1, rows))
        let usable = size.height - m.topInset - m.bottomInset
        // Shrink the row gap before the keys when the area is short.
        let natural = (usable - (n - 1) * m.rowGap) / n
        if natural < m.minKeyHeight + 4 { m.rowGap = max(6, (usable - n * (m.minKeyHeight + 4)) / max(1, n - 1)) }
        return m
    }

    func keyHeight(in height: CGFloat, rows: Int) -> CGFloat {
        let n = CGFloat(max(1, rows))
        let h = (height - topInset - bottomInset - (n - 1) * rowGap) / n
        return min(maxKeyHeight, max(minKeyHeight, h))
    }
}

enum TypingLayout {
    // MARK: Rows

    static let lettersRow1 = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    static let lettersRow2 = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
    static let lettersRow3 = ["z", "x", "c", "v", "b", "n", "m"]
    static let numbersRow1 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    static let numbersRow2 = ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
    static let symbolsRow1 = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
    static let symbolsRow2 = ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
    static let punctuationRow = [".", ",", "?", "!", "'"]

    /// Shift, delete, and the layer keys are 1.3 letter keys wide; return is 2.25; the globe 1.1.
    static let modifierWidth = 1.3
    static let returnWidth = 2.25
    static let globeWidth = 1.1

    /// The rows for a layer and a field. `showsGlobe` follows `needsInputModeSwitchKey`.
    static func rows(layer: TypingLayer, field: FieldKind, showsGlobe: Bool) -> [[RowItem]] {
        if field == .numberPad || field == .decimalPad {
            return numberPad(decimal: field == .decimalPad, showsGlobe: showsGlobe)
        }
        var rows: [[RowItem]]
        switch layer {
        case .letters:
            rows = [
                lettersRow1.map { .char($0) },
                [.spacer(1)] + lettersRow2.map { .char($0) } + [.spacer(1)],
                [.key(.shift, .units(modifierWidth)), .spacer(1)] + lettersRow3.map { .char($0) }
                    + [.spacer(1), .key(.delete, .units(modifierWidth))],
            ]
        case .numbers:
            rows = [
                numbersRow1.map { .char($0) },
                numbersRow2.map { .char($0) },
                [.key(.layer(.symbols), .units(modifierWidth)), .spacer(1)] + punctuationRow.map { .char($0, 1.4) }
                    + [.spacer(1), .key(.delete, .units(modifierWidth))],
            ]
        case .symbols:
            rows = [
                symbolsRow1.map { .char($0) },
                symbolsRow2.map { .char($0) },
                [.key(.layer(.numbers), .units(modifierWidth)), .spacer(1)] + punctuationRow.map { .char($0, 1.4) }
                    + [.spacer(1), .key(.delete, .units(modifierWidth))],
            ]
        }
        var bottom: [RowItem] = [.key(.layer(layer == .letters ? .numbers : .letters), .units(modifierWidth))]
        if showsGlobe { bottom.append(.key(.globe, .units(globeWidth))) }
        switch field {
        case .email:
            bottom += [.key(.space, .flex(1)), .char("@"), .char(".")]
        case .url:
            bottom += [.char("/"), .key(.space, .flex(1)), .char(".")]
        default:
            bottom.append(.key(.space, .flex(1)))
        }
        bottom.append(.key(.returnKey, .units(returnWidth)))
        rows.append(bottom)
        return rows
    }

    /// A phone-style number pad: 1 to 9 in three columns, then 0 with delete, and a decimal point on a decimal pad.
    static func numberPad(decimal: Bool, showsGlobe: Bool) -> [[RowItem]] {
        func digits(_ d: [String]) -> [RowItem] { d.map { .key(.character($0), .flex(1)) } }
        var bottom: [RowItem] = []
        switch (decimal, showsGlobe) {
        case (true, true): bottom = [.key(.globe, .flex(0.5)), .key(.character("."), .flex(0.5))]
        case (true, false): bottom = [.key(.character("."), .flex(1))]
        case (false, true): bottom = [.key(.globe, .flex(1))]
        case (false, false): bottom = [.spacer(1)]
        }
        bottom += [.key(.character("0"), .flex(1)), .key(.delete, .flex(1))]
        return [digits(["1", "2", "3"]), digits(["4", "5", "6"]), digits(["7", "8", "9"]), bottom]
    }

    // MARK: Frames

    /// Width of one letter key: ten keys and nine gaps fill the row (number pads have three columns instead).
    static func unit(width: CGFloat, metrics m: KeyMetrics) -> CGFloat {
        max(0, (width - 2 * m.sideMargin - 9 * m.keyGap) / 10)
    }

    /// Every key's frame, row by row, in a key area of `size`. Keys in a row are `keyGap` apart; spacers take
    /// what's left with no gaps beside them; flexible keys share what's left with spacers by weight.
    static func place(_ rows: [[RowItem]], in size: CGSize, metrics m: KeyMetrics) -> [PlacedKey] {
        let u = unit(width: size.width, metrics: m)
        let h = m.keyHeight(in: size.height, rows: rows.count)
        var out: [PlacedKey] = []
        for (r, row) in rows.enumerated() {
            let y = m.topInset + CGFloat(r) * (h + m.rowGap)
            var fixed: CGFloat = 0
            var weights: Double = 0
            var gaps = 0
            for (i, item) in row.enumerated() {
                switch item {
                case .key(_, .units(let w)): fixed += CGFloat(w) * u
                case .key(_, .flex(let w)): weights += w
                case .spacer(let w): weights += w
                }
                if i > 0, case .key = item, case .key = row[i - 1] { gaps += 1 }
            }
            let avail = size.width - 2 * m.sideMargin
            let left = max(0, avail - fixed - CGFloat(gaps) * m.keyGap)
            // A row with nothing flexible is centered (its keys are narrower than the row).
            var x = m.sideMargin + (weights == 0 ? left / 2 : 0)
            var index = 0
            for (i, item) in row.enumerated() {
                if i > 0, case .key = item, case .key = row[i - 1] { x += m.keyGap }
                switch item {
                case .key(let kind, let width):
                    let w: CGFloat
                    switch width {
                    case .units(let n): w = CGFloat(n) * u
                    case .flex(let n): w = weights > 0 ? left * CGFloat(n / weights) : 0
                    }
                    out.append(PlacedKey(id: KeyID(row: r, index: index), kind: kind, frame: CGRect(x: x, y: y, width: w, height: h)))
                    index += 1
                    x += w
                case .spacer(let n):
                    x += weights > 0 ? left * CGFloat(n / weights) : 0
                }
            }
        }
        return out
    }

    // MARK: Hit testing

    /// The key a touch at `point` belongs to. Rows split halfway between them; in a row, the key whose span is
    /// nearest, so a touch in a gap or beside a spacer still lands on a key (as on the system keyboard).
    static func hit(_ point: CGPoint, in keys: [PlacedKey]) -> PlacedKey? {
        guard !keys.isEmpty else { return nil }
        var rowTops: [Int: (min: CGFloat, max: CGFloat)] = [:]
        for k in keys {
            let cur = rowTops[k.id.row]
            rowTops[k.id.row] = (min(cur?.min ?? .greatestFiniteMagnitude, k.frame.minY), max(cur?.max ?? 0, k.frame.maxY))
        }
        // Nearest row by vertical distance (0 inside it); a touch exactly halfway goes to the upper row.
        let row = rowTops.min { a, b in
            let da = dist(point.y, a.value.min, a.value.max), db = dist(point.y, b.value.min, b.value.max)
            return da != db ? da < db : a.key < b.key
        }?.key
        guard let row else { return nil }
        return keys.filter { $0.id.row == row }.min { a, b in
            dist(point.x, a.frame.minX, a.frame.maxX) < dist(point.x, b.frame.minX, b.frame.maxX)
        }
    }

    private static func dist(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        v < lo ? lo - v : (v > hi ? v - hi : 0)
    }
}

// MARK: - Typing rules

enum TypingRules {
    /// Two taps on shift within this long turn on caps lock.
    static let doubleTapWindow: TimeInterval = 0.35

    /// Shift after a tap on it. Off → on → off; caps lock → off; two quick taps → caps lock.
    static func tapShift(_ s: ShiftState, sinceLastTap: TimeInterval?) -> ShiftState {
        if s == .locked { return .off }
        if let t = sinceLastTap, t >= 0, t <= doubleTapWindow { return .locked }
        return s == .off ? .on : .off
    }

    /// Shift after a character, space, return, or delete: caps lock stays; otherwise it follows auto-capitalization.
    static func shiftAfterInput(_ s: ShiftState, capitalizeNext: Bool) -> ShiftState {
        s == .locked ? .locked : (capitalizeNext ? .on : .off)
    }

    /// Whether the next letter should be a capital, from the field's `autocapitalizationType` and the text before
    /// the cursor (nil when the field doesn't say; treated as the start of the field).
    static func shouldCapitalize(_ mode: AutoCapMode, before: String?) -> Bool {
        let text = before ?? ""
        switch mode {
        case .none: return false
        case .allCharacters: return true
        case .words:
            guard let last = text.last else { return true }
            return last.isWhitespace
        case .sentences:
            guard let last = text.last else { return true }
            if last.isNewline { return true }
            // Only after a space: "e.g" and "example.com" stay lowercase.
            guard last == " " || last == "\t" else { return false }
            var body = Substring(text)
            while let c = body.last, c == " " || c == "\t" { body = body.dropLast() }
            // Closing quotes and brackets after the period: “Done.” Then…
            while let c = body.last, "\"')]”’»".contains(c) { body = body.dropLast() }
            guard let end = body.last else { return true }
            return end.isNewline || ".!?…".contains(end)
        }
    }

    /// Double-space for a period: the second of two spaces in a row, right after a letter or number, becomes ". ".
    /// `lastKeyWasSpace` is true when the keyboard's previous key was space (not a moved cursor). Off in email and
    /// link fields and on number pads.
    static func periodShortcut(before: String?, lastKeyWasSpace: Bool, field: FieldKind) -> Bool {
        guard lastKeyWasSpace, field == .standard || field == .numbersAndPunctuation, let text = before else { return false }
        let chars = Array(text.suffix(2))
        guard chars.count == 2, chars[1] == " " else { return false }
        let c = chars[0]
        return c.isLetter || c.isNumber || "\"')”’".contains(c)
    }

    /// The layer after a key. In the 123 and #+= layers, space, return, and an apostrophe go back to letters,
    /// as on the system keyboard; a numbers-and-punctuation field stays where it is.
    static func layer(after key: KeyKind, in layer: TypingLayer, field: FieldKind) -> TypingLayer {
        if case .layer(let l) = key { return l }
        guard layer != .letters, field != .numbersAndPunctuation else { return layer }
        switch key {
        case .space, .returnKey, .character("'"): return .letters
        default: return layer
        }
    }

    /// The layer a field starts in.
    static func initialLayer(for field: FieldKind) -> TypingLayer {
        field == .numbersAndPunctuation ? .numbers : .letters
    }

    /// The text a character key inserts: letters follow shift, everything else as it is.
    static func text(for character: String, layer: TypingLayer, shift: ShiftState) -> String {
        layer == .letters && shift != .off ? character.uppercased() : character
    }

    /// Delete repeats after a short hold, then faster.
    static let repeatDelay: TimeInterval = 0.45
    static let repeatInterval: TimeInterval = 0.09
}

// MARK: - Labels

extension KeyKind {
    /// What VoiceOver says for a key. Character keys say their character (VoiceOver names punctuation).
    func spokenLabel(shift: ShiftState, layer: TypingLayer, returnKind: ReturnKind) -> String {
        switch self {
        case .character(let s): return TypingRules.text(for: s, layer: layer, shift: shift)
        case .shift: return "Shift"
        case .delete: return "Delete"
        case .space: return "Space"
        case .returnKey: return returnKind.spoken
        case .globe: return "Next keyboard"
        case .layer(.letters): return "Letters"
        case .layer(.numbers): return "Numbers"
        case .layer(.symbols): return "More symbols"
        }
    }

    /// The text on a layer key.
    var layerTitle: String? {
        switch self {
        case .layer(.letters): return "ABC"
        case .layer(.numbers): return "123"
        case .layer(.symbols): return "#+="
        default: return nil
        }
    }

    var isCharacter: Bool { if case .character = self { return true } else { return false } }
}
