import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Brand artwork (from Verbatim_Brand_Starter_Kit SVGs)
//
// The kit's SVGs are simple geometry, so they're drawn natively from their own path data (copied verbatim)
// rather than shipped as images: they stay sharp at every size and recolor for dark mode and selection.

/// Parses SVG path data (M L H V C S Q Z, absolute and relative) into a CGPath.
enum SVGPathData {
    static func parse(_ d: String) -> CGMutablePath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var num = ""
        func flush() { if !num.isEmpty { tokens.append(num); num = "" } }
        var prev: Character = " "
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" { flush(); tokens.append(String(ch)) }
            else if ch == "," || ch == " " || ch == "\n" || ch == "\t" { flush() }
            else if ch == "-" && !(prev == "e" || prev == "E") { flush(); num.append(ch) }
            else if ch == "." && num.contains(".") { flush(); num.append(ch) }
            else { num.append(ch) }
            prev = ch
        }
        flush()

        var i = 0, cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint? = nil
        func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        func hasNum() -> Bool { i < tokens.count && Double(tokens[i]) != nil }
        while i < tokens.count {
            if let c = tokens[i].first, tokens[i].count == 1, c.isLetter { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            switch cmd {
            case "M", "m":
                guard hasNum() else { i += 1; continue }
                cur = pt(n(), n()); start = cur; path.move(to: cur); lastCtrl = nil
                cmd = rel ? "l" : "L"   // subsequent pairs are line-tos
            case "L", "l":
                guard hasNum() else { i += 1; continue }
                cur = pt(n(), n()); path.addLine(to: cur); lastCtrl = nil
            case "H", "h":
                guard hasNum() else { i += 1; continue }
                let x = n(); cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur); lastCtrl = nil
            case "V", "v":
                guard hasNum() else { i += 1; continue }
                let y = n(); cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur); lastCtrl = nil
            case "C", "c":
                guard hasNum() else { i += 1; continue }
                let c1 = pt(n(), n()), c2 = pt(n(), n()), e = pt(n(), n())
                path.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2
            case "S", "s":
                guard hasNum() else { i += 1; continue }
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(n(), n()), e = pt(n(), n())
                path.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2
            case "Q", "q":
                guard hasNum() else { i += 1; continue }
                let c = pt(n(), n()), e = pt(n(), n())
                path.addQuadCurve(to: e, control: c); cur = e; lastCtrl = nil
            case "Z", "z":
                path.closeSubpath(); cur = start; lastCtrl = nil
                if hasNum() { cmd = rel ? "l" : "L" }   // numbers after Z continue as line-tos (never loop)
            default:
                i += 1
            }
        }
        return path
    }
}

/// One piece of artwork: path data plus circles, lines, and rects, in a design-space box.
struct BrandArt {
    enum Element {
        case path(String)
        case circle(CGFloat, CGFloat, CGFloat)
        case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    }
    var box: CGRect
    var strokes: [Element] = []
    var fills: [Element] = []
    var strokeWidth: CGFloat = 4.5
    /// Elements drawn only inside the region every `clip` element shares (the hatched Understand intersection:
    /// the part all three circles overlap, not their union).
    var clipped: [Element] = []
    var clip: [Element] = []
    var clippedWidth: CGFloat = 2.4
    /// Dashed strokes (the icon set's construction lines), each group with its own on/off pattern in box units.
    struct Dash { var elements: [Element]; var pattern: [CGFloat] }
    var dashes: [Dash] = []

    static func cgPath(_ els: [Element]) -> CGMutablePath {
        let p = CGMutablePath()
        for e in els {
            switch e {
            case .path(let d): p.addPath(SVGPathData.parse(d))
            case .circle(let x, let y, let r): p.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            case .rect(let x, let y, let w, let h, let rx): p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerWidth: rx, cornerHeight: rx)
            }
        }
        return p
    }
}

extension BrandArt {
    /// The app-icon mark: two bars and a last bar with a speech tail, on the 120-unit grid (brand/verbatim-mark-bars.svg).
    static let markBars = BrandArt(box: CGRect(x: 22, y: 18, width: 76, height: 80), fills: [
        .rect(22, 18, 76, 14, 0), .rect(22, 43, 58, 14, 0), .path("M22 68 L98 68 L98 82 L44 82 L22 98 Z")
    ])

    // Interface icons (icon_*.svg, 128 × 128, stroke 4.5, round caps and joins).
    static let iconBox = CGRect(x: 8, y: 8, width: 112, height: 112)
    static let capture = BrandArt(box: iconBox, strokes: [.rect(50, 21, 28, 51, 14), .path("M38 59c0 21 11 33 26 33s26-12 26-33 M64 92v16 M47 108h34")])
    static let refine = BrandArt(box: iconBox, strokes: [.path("M24 83h49 M24 69h59 M24 55h39 M27 41h54"), .path("M92 16l5.1 15.9L113 37l-15.9 5.1L92 58l-5.1-15.9L71 37l15.9-5.1z")])
    static let document = BrandArt(box: iconBox, strokes: [.path("M43 22h34l17 17v68H43z M77 22v19h17 M52 56h31 M52 71h31 M52 86h21")])
    static let search = BrandArt(box: iconBox, strokes: [.circle(57, 54, 28), .path("M78 76l27 27")])
    static let library = BrandArt(box: iconBox, strokes: [.rect(28, 38, 55, 70, 3), .path("M40 23h55v72 M53 10h53v72 M40 58h31 M40 71h31")])
    static let export = BrandArt(box: iconBox, strokes: [.path("M39 73v34h52V73 M65 83V15 M43 37l22-22 22 22")])
    static let bookmark = BrandArt(box: iconBox, strokes: [.path("M39 20h51v87L64 89l-25 18z")])
    static let play = BrandArt(box: iconBox, strokes: [.circle(64, 64, 42), .path("M55 43l29 21-29 21z")])

    // Process diagrams (diagram_*.svg, 600 × 500; boxes trimmed to the drawing).
    static let diagramCapture = BrandArt(box: CGRect(x: 168, y: 88, width: 264, height: 342), strokes: [
        .circle(300, 259, 124), .circle(300, 281, 102), .circle(300, 303, 80), .circle(300, 325, 58),
        .path("M300 96 L300 421"), .path("M280 93h40 M282 425h36"),
    ], fills: [.circle(300, 383, 6)], strokeWidth: 2.8)

    static let diagramRefine = BrandArt(box: CGRect(x: 70, y: 92, width: 426, height: 314), strokes: [
        .path("M75 128 C155 150, 185 100, 246 196 Q258 214 270 247"),
        .path("M75 168 C155 133, 185 203, 246 213 Q258 225 270 247"),
        .path("M75 207 C155 229, 185 179, 246 230 Q258 236 270 247"),
        .path("M75 247 C155 212, 185 282, 246 247 Q258 247 270 247"),
        .path("M75 287 C155 309, 185 259, 246 264 Q258 258 270 247"),
        .path("M75 327 C155 292, 185 362, 246 281 Q258 269 270 247"),
        .path("M75 367 C155 389, 185 339, 246 298 Q258 280 270 247"),
        .path("M325 128H490"), .path("M325 168H465"), .path("M325 207H440"), .path("M325 247H490"),
        .path("M325 287H465"), .path("M325 327H440"), .path("M325 367H490"), .path("M299 96 L299 402"),
    ], strokeWidth: 2.7)

    static let diagramUnderstand = BrandArt(box: CGRect(x: 100, y: 75, width: 400, height: 382), strokes: [
        .circle(300, 205, 126), .circle(230, 327, 126), .circle(370, 327, 126),
    ], strokeWidth: 2.7, clipped: understandHatch,
       clip: [.circle(300, 205, 126), .circle(230, 327, 126), .circle(370, 327, 126)])

    /// Evenly spaced diagonal hatch, every 22 units, wide enough to cover the triple intersection wherever the
    /// circles sit (the animated variant moves them). Clipping trims it to the shared region.
    static let understandHatch: [Element] = (0..<21).map { k in .path("M\(200 + 22 * k) 120l-200 290") }

    // BEGIN ICONS (generated by mac/tools/gen_icons.py; edit that file, not this block)
    // Fine-line interface icons (icon set canvas, October 18, 2026): 24-unit grid, stroke 1.5, round ends.
    static let iconGrid = CGRect(x: 0, y: 0, width: 24, height: 24)
    static let iconHome = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 7), .circle(12, 15, 4), .path("M12 2.5V21.5"), .path("M10 2.5H14"), .path("M10 21.5H14")], strokeWidth: 1.5)
    static let iconLibrary = BrandArt(box: iconGrid, strokes: [.path("M3.5 20.5H20.5"), .path("M5 20.5V6H8.5V20.5"), .path("M10.5 20.5V9H14V20.5"), .path("M15.6 20.5L18.2 8.8L21 9.4L18.6 20.5")], strokeWidth: 1.5)
    static let iconLinks = BrandArt(box: iconGrid, strokes: [.circle(6.5, 12, 3.5), .circle(17.5, 12, 3.5), .path("M10 12H14")], fills: [.circle(6.5, 12, 1), .circle(17.5, 12, 1)], strokeWidth: 1.5)
    static let iconMoments = BrandArt(box: iconGrid, strokes: [.path("M3 15H21"), .path("M6 13.5V16.5"), .path("M18 13.5V16.5"), .circle(12, 15, 4.5), .path("M12 4.5V10.5")], fills: [.circle(12, 15, 1.6)], strokeWidth: 1.5)
    static let iconQueue = BrandArt(box: iconGrid, strokes: [.circle(5, 12, 1.4), .circle(5, 17, 1.4), .path("M9 7H20"), .path("M9 12H18"), .path("M9 17H15.5")], fills: [.circle(5, 7, 1.6)], strokeWidth: 1.5)
    static let iconDictations = BrandArt(box: iconGrid, strokes: [.path("M3 9C4.5 4.5 6 4.5 7.5 9S10.5 13.5 12 9 15 4.5 16.5 9 19.5 13.5 21 9"), .path("M3 15.5H21"), .path("M3 19.5H14")], strokeWidth: 1.5)
    static let iconActivity = BrandArt(box: iconGrid, strokes: [], fills: [.circle(6, 6, 1.2), .circle(12, 6, 2.3), .circle(18, 6, 1.2), .circle(6, 12, 2.3), .circle(12, 12, 1.2), .circle(18, 12, 2.3), .circle(6, 18, 1.2), .circle(12, 18, 2.3), .circle(18, 18, 2.3)], strokeWidth: 1.5)
    static let iconDictionary = BrandArt(box: iconGrid, strokes: [.path("M12 6.5C9.5 4.8 6.5 4.5 3.5 5.2V18.7C6.5 18 9.5 18.3 12 20C14.5 18.3 17.5 18 20.5 18.7V5.2C17.5 4.5 14.5 4.8 12 6.5Z"), .path("M12 6.5V20")], strokeWidth: 1.5)
    static let iconSettings = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 6.5), .path("M12 12V7.5"), .path("M12 2.5V4"), .path("M20.23 16.75L18.93 16"), .path("M3.77 16.75L5.07 16")], fills: [.circle(12, 12, 1.2)], strokeWidth: 1.5)
    static let iconDeleted = BrandArt(box: iconGrid, strokes: [.path("M14 3.5V7.5H18")], strokeWidth: 1.5, dashes: [.init(elements: [.path("M6 3.5H14L18 7.5V20.5H6Z")], pattern: [1.6, 1.9])])
    static let iconLanguage = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 8.5), .path("M3.5 12H20.5"), .path("M12 3.5C9 6 9 18 12 20.5C15 18 15 6 12 3.5")], strokeWidth: 1.5)
    static let iconVoice = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 8), .circle(15, 12, 5), .circle(18, 12, 2)], strokeWidth: 1.5)
    static let iconAboutMe = BrandArt(box: iconGrid, strokes: [.circle(12, 8.5, 3.5), .path("M5.5 19.5C5.5 15.5 8.4 13.5 12 13.5S18.5 15.5 18.5 19.5"), .path("M3.5 19.5H20.5")], strokeWidth: 1.5)
    static let iconSummaries = BrandArt(box: iconGrid, strokes: [.path("M4 6H16"), .path("M4 11H13"), .path("M4 16H10"), .path("M17 4H20V19H17")], strokeWidth: 1.5)
    static let iconAppearance = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 8.5)], fills: [.path("M12 3.5 C16.69 3.5 20.5 7.31 20.5 12 C20.5 16.69 16.69 20.5 12 20.5 Z")], strokeWidth: 1.5)
    static let iconLimitMotion = BrandArt(box: iconGrid, strokes: [.path("M12 3V15.5"), .path("M8.5 3H15.5")], fills: [.circle(12, 18, 2.5)], strokeWidth: 1.5, dashes: [.init(elements: [.path("M5.5 14.5 C7 16.59 9.42 17.84 12 17.84 C14.58 17.84 17 16.59 18.5 14.5")], pattern: [1.2, 1.8])])
    static let iconQuality = BrandArt(box: iconGrid, strokes: [.path("M4 4H20V20H4Z"), .path("M12 6L18 12L12 18L6 12Z"), .path("M10 10H14V14H10Z")], strokeWidth: 1.5)
    static let iconSpeakers = BrandArt(box: iconGrid, strokes: [.circle(9, 12, 5.5), .circle(15, 12, 5.5)], fills: [.circle(9, 12, 1.1), .circle(15, 12, 1.1)], strokeWidth: 1.5)
    static let iconApplyDictionary = BrandArt(box: iconGrid, strokes: [.path("M5 6H13C17.5 6 17.5 12 12 12C6.5 12 6.5 18 11 18H19")], fills: [.circle(4, 6, 1.4), .circle(20, 18, 1.4)], strokeWidth: 1.5)
    static let iconNameAndSort = BrandArt(box: iconGrid, strokes: [.path("M12 3V21"), .path("M3 12H21"), .path("M10.5 7.5H13.5"), .path("M10.5 16.5H13.5"), .path("M7.5 10.5V13.5"), .path("M16.5 10.5V13.5"), .circle(6.2, 6.5, 1.6), .circle(18, 8, 1.6), .circle(7, 17.6, 1.6), .circle(17.6, 17, 1.6)], strokeWidth: 1.5)
    static let iconFiller = BrandArt(box: iconGrid, strokes: [], fills: [.circle(12, 12, 1.1)], strokeWidth: 1.5, dashes: [.init(elements: [.circle(12, 12, 8.5)], pattern: [3, 2.6]), .init(elements: [.circle(12, 12, 4.5)], pattern: [2, 2.4])])
    static let iconMainSpeaker = BrandArt(box: iconGrid, strokes: [.path("M3.5 3.5H20.5V20.5H3.5Z"), .path("M8 8H16V16H8Z"), .path("M3.5 3.5L8 8"), .path("M20.5 3.5L16 8"), .path("M3.5 20.5L8 16"), .path("M20.5 20.5L16 16"), .circle(12, 12, 1.6)], strokeWidth: 1.5)
    static let iconSync = BrandArt(box: iconGrid, strokes: [.circle(5, 16.5, 2), .circle(19, 16.5, 2), .path("M5 14.5C5 6.5 19 6.5 19 14.5")], fills: [.circle(12, 8.5, 1.2)], strokeWidth: 1.5)
    static let iconSyncOff = BrandArt(box: iconGrid, strokes: [.circle(5, 16.5, 2), .circle(19, 16.5, 2), .path("M5 14.5C5 11 6.6 9 8.6 8.1"), .path("M15.4 8.1C17.4 9 19 11 19 14.5")], strokeWidth: 1.5)
    static let iconExport = BrandArt(box: iconGrid, strokes: [.path("M4 13V20H20V13"), .path("M12 3.5V15"), .path("M8 11L12 15L16 11")], strokeWidth: 1.5)
    static let iconDeleteAll = BrandArt(box: iconGrid, strokes: [.path("M5 7H19"), .path("M5 12H19"), .path("M5 17H19"), .path("M4.5 20.5L19.5 3.5")], strokeWidth: 1.5)
    static let iconSupport = BrandArt(box: iconGrid, strokes: [.path("M12 3.5 C16.69 3.5 20.5 7.31 20.5 12 V20.5 H12 C7.31 20.5 3.5 16.69 3.5 12 C3.5 7.31 7.31 3.5 12 3.5 Z"), .path("M8.5 12H15.5")], strokeWidth: 1.5)
    static let iconFeedback = BrandArt(box: iconGrid, strokes: [.path("M15.5 4.5L19.5 8.5L8.5 19.5H4.5V15.5Z"), .path("M13 7L17 11")], strokeWidth: 1.5)
    static let iconDiagnosticLog = BrandArt(box: iconGrid, strokes: [.path("M8 7H14"), .path("M8 12H17"), .path("M8 17H11"), .path("M14.5 19.5L20 14"), .path("M16.5 14H20V17.5")], fills: [.circle(5, 7, 1), .circle(5, 12, 1), .circle(5, 17, 1)], strokeWidth: 1.5)
    static let iconPrivacy = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 8.5), .circle(12, 10.3, 2.2), .path("M12 12.5V16.5")], strokeWidth: 1.5)
    static let iconTerms = BrandArt(box: iconGrid, strokes: [.path("M6 3.5H18V20.5H6Z"), .path("M9 8H15"), .path("M9 12H15"), .path("M9 16H12.5")], strokeWidth: 1.5)
    static let iconShare = BrandArt(box: iconGrid, strokes: [.path("M8 10H5V20.5H19V10H16"), .path("M12 3V14"), .path("M8.5 6.5L12 3L15.5 6.5")], strokeWidth: 1.5)
    static let iconTour = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 8.5), .path("M10 8.5L15.5 12L10 15.5Z")], strokeWidth: 1.5)
    static let iconTranscribing = BrandArt(box: iconGrid, strokes: [.path("M12 3.5 C16.31 3.5 19.94 6.73 20.44 11.01 C20.94 15.3 18.15 19.28 13.96 20.27 C9.76 21.27 5.49 18.96 4.01 14.91")], fills: [.circle(12, 12, 1.6)], strokeWidth: 1.5, dashes: [.init(elements: [.path("M4.01 14.91 C3.06 12.3 3.44 9.4 5.03 7.12 C6.63 4.85 9.23 3.5 12 3.5")], pattern: [1.2, 1.8])])
    static let iconWaitingForMac = BrandArt(box: iconGrid, strokes: [.circle(4.5, 12, 2), .path("M15 8H21V14H15Z"), .path("M14 16.5H22")], strokeWidth: 1.5, dashes: [.init(elements: [.path("M7.5 12H13")], pattern: [0.8, 1.8])])
    static let iconAttention = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 8.5), .path("M12 7V13")], fills: [.circle(12, 16.3, 1.1)], strokeWidth: 1.5)
    static let iconRecovered = BrandArt(box: iconGrid, strokes: [.path("M12.89 3.55 C15.91 3.87 18.53 5.77 19.77 8.54"), .path("M20.31 10.23 C20.95 13.2 19.95 16.29 17.69 18.32"), .path("M16.25 19.36 C13.62 20.88 10.38 20.88 7.75 19.36"), .path("M6.31 18.32 C4.05 16.29 3.05 13.2 3.69 10.23"), .path("M4.23 8.54 C5.47 5.77 8.09 3.87 11.11 3.55")], fills: [.circle(12, 12, 1.6)], strokeWidth: 1.5)
    static let iconCaptions = BrandArt(box: iconGrid, strokes: [.path("M4 6.5C8.5 3.2 15.5 3.2 20 6.5"), .path("M4 11.5H20"), .path("M4 15.5H17"), .path("M4 19.5H12")], strokeWidth: 1.5)
    static let iconCopy = BrandArt(box: iconGrid, strokes: [.path("M5.5 15.5V3.5H15.5"), .path("M8.5 6.5H18.5V20.5H8.5Z")], strokeWidth: 1.5)
    static let iconPaste = BrandArt(box: iconGrid, strokes: [.path("M9 3.5H15V6.5H9Z"), .path("M9 5H6V20.5H18V5H15"), .path("M9 11H15"), .path("M9 15H13")], strokeWidth: 1.5)
    static let iconNotes = BrandArt(box: iconGrid, strokes: [.path("M4.5 4.5H19.5V14.5L14.5 19.5H4.5Z"), .path("M14.5 19.5V14.5H19.5"), .path("M8 9H16"), .path("M8 12.5H12.5")], strokeWidth: 1.5)
    static let iconTextSize = BrandArt(box: iconGrid, strokes: [.path("M3 19L7.5 6.5L12 19"), .path("M4.6 14.5H10.4"), .path("M13.5 19L16.75 10.5L20 19"), .path("M14.6 16H18.9")], strokeWidth: 1.5)
    static let iconSelect = BrandArt(box: iconGrid, strokes: [.path("M12 5V19"), .path("M9.5 5H14.5"), .path("M9.5 19H14.5"), .path("M4.5 8V4.5H7"), .path("M4.5 16V19.5H7"), .path("M19.5 8V4.5H17"), .path("M19.5 16V19.5H17")], strokeWidth: 1.5)
    static let iconPlay = BrandArt(box: iconGrid, strokes: [.path("M7.5 4.5L19 12L7.5 19.5Z")], strokeWidth: 1.5)
    static let iconPause = BrandArt(box: iconGrid, strokes: [.path("M8.5 5V19"), .path("M15.5 5V19")], strokeWidth: 1.5)
    static let iconStop = BrandArt(box: iconGrid, strokes: [.path("M6.5 6.5H17.5V17.5H6.5Z")], strokeWidth: 1.5)
    static let iconBack5 = BrandArt(box: iconGrid, strokes: [.path("M12 5.5 C15.39 5.5 18.36 7.78 19.24 11.06 C20.12 14.34 18.68 17.8 15.74 19.5 C12.8 21.19 9.09 20.7 6.69 18.3 C4.29 15.9 3.8 12.19 5.5 9.25"), .path("M14 3.5L12 5.5L14 7.5"), .path("M13.6 10H10.6L10.3 13C11.9 12.3 13.9 12.9 13.9 14.7C13.9 16.5 11.6 17.1 10.1 16.2")], strokeWidth: 1.5)
    static let iconForward5 = BrandArt(box: iconGrid, strokes: [.path("M18.5 9.25 C20.2 12.19 19.71 15.9 17.31 18.3 C14.91 20.7 11.2 21.19 8.26 19.5 C5.32 17.8 3.88 14.34 4.76 11.06 C5.64 7.78 8.61 5.5 12 5.5"), .path("M10 3.5L12 5.5L10 7.5"), .path("M13.6 10H10.6L10.3 13C11.9 12.3 13.9 12.9 13.9 14.7C13.9 16.5 11.6 17.1 10.1 16.2")], strokeWidth: 1.5)
    static let iconPin = BrandArt(box: iconGrid, strokes: [.path("M8.5 3.5H15.5"), .path("M10 3.5V9.5L7 13.5H17L14 9.5V3.5"), .path("M12 13.5V20.5")], strokeWidth: 1.5)
    static let iconProject = BrandArt(box: iconGrid, strokes: [.path("M3.5 5.5H9.5L11.5 7.5H20.5V18.5H3.5Z"), .path("M3.5 10.5H20.5")], strokeWidth: 1.5)
    static let iconAI = BrandArt(box: iconGrid, strokes: [.path("M12 3.5L13.9 10.1L20.5 12L13.9 13.9L12 20.5L10.1 13.9L3.5 12L10.1 10.1Z")], strokeWidth: 1.5)
    static let iconRecent = BrandArt(box: iconGrid, strokes: [.circle(10, 12, 6.5), .path("M10 8.5V12L12.5 13.5"), .path("M19 8.5H21"), .path("M19.5 12H21"), .path("M19 15.5H21")], strokeWidth: 1.5)
    static let iconHide = BrandArt(box: iconGrid, strokes: [.path("M3.5 10.5C7.5 16 16.5 16 20.5 10.5"), .path("M6.5 13.8L5 16"), .path("M12 15.6V18.3"), .path("M17.5 13.8L19 16")], strokeWidth: 1.5)
    static let iconMultitrack = BrandArt(box: iconGrid, strokes: [.path("M3 6.5H8C9 4.5 10 4.5 11 6.5S13 8.5 14 6.5H21"), .path("M3 12H6C7 10 8 10 9 12S11 14 12 12H21"), .path("M3 17.5H10C11 15.5 12 15.5 13 17.5S15 19.5 16 17.5H21")], strokeWidth: 1.5)
    static let iconQuote = BrandArt(box: iconGrid, strokes: [.path("M4.5 12.5H9.5V17.5H4.5V12.5C4.5 9.5 5.8 7.5 8.5 6.5"), .path("M14.5 12.5H19.5V17.5H14.5V12.5C14.5 9.5 15.8 7.5 18.5 6.5")], strokeWidth: 1.5)
    static let iconSwap = BrandArt(box: iconGrid, strokes: [.path("M4 8.5H19"), .path("M16 5.5L19 8.5L16 11.5"), .path("M20 15.5H5"), .path("M8 12.5L5 15.5L8 18.5")], strokeWidth: 1.5)
    static let iconFollow = BrandArt(box: iconGrid, strokes: [.path("M4 7H13"), .path("M4 12H10"), .path("M4 17H13"), .path("M15.5 9L20.5 12L15.5 15Z")], strokeWidth: 1.5)
    static let iconDetails = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 8.5), .path("M12 11V16.5")], fills: [.circle(12, 7.8, 1.1)], strokeWidth: 1.5)
    static let iconServer = BrandArt(box: iconGrid, strokes: [.path("M4.5 4.5H19.5V10.5H4.5Z"), .path("M4.5 13.5H19.5V19.5H4.5Z")], fills: [.circle(8, 7.5, 1), .circle(8, 16.5, 1)], strokeWidth: 1.5)
    static let iconLowerAudio = BrandArt(box: iconGrid, strokes: [.path("M4 9.5H7.5L12 5.5V18.5L7.5 14.5H4Z"), .path("M15.5 9.5C16.8 10.8 16.8 13.2 15.5 14.5"), .path("M18.5 15.5L20 17L21.5 15.5")], strokeWidth: 1.5)
    static let iconAccessibility = BrandArt(box: iconGrid, strokes: [.circle(12, 5, 1.8), .path("M5 8.5L12 10L19 8.5"), .path("M12 10V14.5"), .path("M12 14.5L9 20.5"), .path("M12 14.5L15 20.5")], strokeWidth: 1.5)
    static let iconNoSpeaker = BrandArt(box: iconGrid, strokes: [.circle(12, 8.5, 3.5), .path("M5.5 19.5C5.5 15.5 8.4 13.5 12 13.5S18.5 15.5 18.5 19.5"), .path("M4 4L20 20")], strokeWidth: 1.5)
    static let iconDownload = BrandArt(box: iconGrid, strokes: [.path("M12 3.5V15"), .path("M8 11L12 15L16 11"), .path("M5 20.5H19")], strokeWidth: 1.5)
    // END ICONS

    // Kind and feature diagrams (capture-and-archive canvas, October 2026): the same geometric line family as the
    // process diagrams, on a 100 × 100 grid. Generated from the approved mockup's SVG; arcs are cubic curves.
    static let glyphBox = CGRect(x: 4, y: 4, width: 92, height: 92)
    static let kindJournal = BrandArt(box: glyphBox, strokes: [
        .path("M6 74 L94 74"),
        .path("M14 74 C14 54.12 30.12 38 50 38 C69.88 38 86 54.12 86 74"),
        .path("M26 74 C26 60.75 36.75 50 50 50 C63.25 50 74 60.75 74 74"),
        .path("M38 74 C38 67.37 43.37 62 50 62 C56.63 62 62 67.37 62 74"),
        .path("M50 12 L50 22"),
        .path("M19 25 L25 32"),
        .path("M81 25 L75 32"),
        .path("M20 86 L80 86"),
        .path("M34 94 L66 94"),
    ], strokeWidth: 2.2)
    static let kindIdea = BrandArt(box: glyphBox, strokes: [
        .path("M80 50 L94 50"),
        .path("M62 50 L70 50"),
        .path("M71.92 71.92 L81.11 81.11"),
        .path("M58.49 58.49 L64.14 64.14"),
        .path("M50 80 L50 94"),
        .path("M50 62 L50 70"),
        .path("M28.08 71.92 L18.89 81.11"),
        .path("M41.51 58.49 L35.86 64.14"),
        .path("M20 50 L6 50"),
        .path("M38 50 L30 50"),
        .path("M28.08 28.08 L18.89 18.89"),
        .path("M41.51 41.51 L35.86 35.86"),
        .path("M50 20 L50 6"),
        .path("M50 38 L50 30"),
        .path("M71.92 28.08 L81.11 18.89"),
        .path("M58.49 41.51 L64.14 35.86"),
    ], fills: [.circle(50, 50, 3)], strokeWidth: 2.2)
    static let kindMeeting = BrandArt(box: glyphBox, strokes: [
        .path("M28 28 L72 72"),
        .path("M72 28 L28 72"),
        .circle(28, 28, 18),
        .circle(72, 28, 18),
        .circle(28, 72, 18),
        .circle(72, 72, 18),
        .circle(50, 50, 30),
    ], fills: [.circle(28, 28, 2.6), .circle(72, 28, 2.6), .circle(28, 72, 2.6), .circle(72, 72, 2.6)], strokeWidth: 2.2)
    static let kindNote = BrandArt(box: glyphBox, strokes: [
        .path("M50 14 L90 32 L50 50 L10 32 Z"),
        .path("M10 44 L50 62 L90 44"),
        .path("M10 56 L50 74 L90 56"),
        .path("M10 68 L50 86 L90 68"),
    ], strokeWidth: 2.2)
    static let kindDictation = BrandArt(box: glyphBox, strokes: [
        .path("M12 52 C12 26 34 26 34 52 C34 78 50 82 50 52 C50 22 66 26 66 52 C66 78 88 78 88 52"),
        .path("M12 80 L88 80"),
        .path("M12 90 L60 90"),
        .circle(12, 52, 4),
        .circle(34, 52, 4),
        .circle(50, 52, 4),
        .circle(66, 52, 4),
        .circle(88, 52, 4),
    ], strokeWidth: 2.2)
    static let featureBackground = BrandArt(box: glyphBox, strokes: [
        .circle(50, 50, 38),
        .circle(50, 50, 18),
        .circle(78, 22, 6),
        .circle(16, 70, 4),
        .circle(74, 84, 3),
    ], strokeWidth: 2.2)
    static let featureFiller = BrandArt(box: glyphBox, strokes: [
        .path("M50 10 C53.85 10 57.67 10.55 61.36 11.65"),
        .path("M70 15.36 C73.33 17.28 76.37 19.68 79.01 22.47"),
        .path("M84.64 30 C86.56 33.33 88 36.92 88.89 40.66"),
        .path("M90 50 C90 53.85 89.45 57.67 88.35 61.36"),
        .path("M84.64 70 C82.72 73.33 80.32 76.37 77.53 79.01"),
        .path("M70 84.64 C66.67 86.56 63.08 88 59.34 88.89"),
        .path("M50 90 C46.15 90 42.33 89.45 38.64 88.35"),
        .path("M30 84.64 C26.67 82.72 23.63 80.32 20.99 77.53"),
        .path("M15.36 70 C13.44 66.67 12 63.08 11.11 59.34"),
        .path("M10 50 C10 46.15 10.55 42.33 11.65 38.64"),
        .path("M15.36 30 C17.28 26.67 19.68 23.63 22.47 20.99"),
        .path("M30 15.36 C33.33 13.44 36.92 12 40.66 11.11"),
        .path("M50 24 C53.03 24 56.04 24.53 58.89 25.57"),
        .path("M66.71 30.08 C69.04 32.03 71 34.37 72.52 37"),
        .path("M75.61 45.49 C76.13 48.47 76.13 51.53 75.61 54.51"),
        .path("M72.52 63 C71 65.63 69.04 67.97 66.71 69.92"),
        .path("M58.89 74.43 C56.04 75.47 53.03 76 50 76"),
        .path("M41.11 74.43 C38.26 73.39 35.61 71.87 33.29 69.92"),
        .path("M27.48 63 C25.97 60.37 24.92 57.5 24.39 54.51"),
        .path("M24.39 45.49 C24.92 42.5 25.97 39.63 27.48 37"),
        .path("M33.29 30.08 C35.61 28.13 38.26 26.61 41.11 25.57"),
        .path("M50 38 C52.28 38 54.51 38.65 56.43 39.87"),
        .path("M61.41 46.29 C62.12 48.46 62.19 50.78 61.62 52.98"),
        .path("M57.05 59.71 C55.21 61.05 53.03 61.83 50.75 61.98"),
        .path("M42.95 59.71 C41.1 58.37 39.68 56.53 38.84 54.42"),
        .path("M38.59 46.29 C39.29 44.13 40.6 42.21 42.35 40.75"),
    ], fills: [.circle(50, 50, 2.6)], strokeWidth: 2.2)
    static let featureLabel = BrandArt(box: glyphBox, strokes: [
        .path("M50 8 L50 92"),
        .path("M8 50 L92 50"),
        .path("M45 22 L55 22"),
        .path("M22 45 L22 55"),
        .path("M45 36 L55 36"),
        .path("M36 45 L36 55"),
        .path("M45 64 L55 64"),
        .path("M64 45 L64 55"),
        .path("M45 78 L55 78"),
        .path("M78 45 L78 55"),
        .circle(26, 24, 5),
        .circle(76, 30, 5),
        .circle(22, 78, 5),
        .circle(80, 74, 5),
    ], strokeWidth: 2.2)
    static let featureTags = BrandArt(box: glyphBox, strokes: [
        .path("M20.43 52.58 L29.57 41.42"),
        .path("M36.96 42.34 L45.04 59.66"),
        .path("M53.94 62.29 L58.06 59.71"),
        .path("M67.67 50.04 L76.33 35.96"),
        .path("M69.2 60.68 L78.8 69.32"),
        .circle(16, 58, 7),
        .circle(34, 36, 7),
        .circle(48, 66, 7),
        .circle(64, 56, 7),
        .circle(80, 30, 7),
        .circle(84, 74, 7),
    ], strokeWidth: 2.2)
    static let featureSegments = BrandArt(box: glyphBox, strokes: [
        .path("M50 10 C64.29 10 77.5 17.62 84.64 30"),
        .path("M88.04 37.64 C91.55 48.42 90.31 60.18 84.64 70"),
        .path("M79.73 76.77 C71.16 86.28 58.55 91.12 45.82 89.78"),
        .path("M37.64 88.04 C24.05 83.63 13.85 72.29 10.87 58.32"),
        .path("M10 50 C10 33.18 20.52 18.16 36.32 12.41"),
        .path("M50 26 C60.09 26 69.1 32.31 72.55 41.79"),
        .path("M73.64 54.17 C71.88 64.1 64.1 71.88 54.17 73.64"),
        .path("M41.79 72.55 C30.85 68.57 24.34 57.3 26.36 45.83"),
    ], fills: [.circle(50, 10, 3), .circle(88.04, 37.64, 3), .circle(79.73, 76.77, 3), .circle(37.64, 88.04, 3), .circle(10, 50, 3)], strokeWidth: 2.2)
    static let featureMain = BrandArt(box: glyphBox, strokes: [
        .path("M8 8 L32 32"),
        .path("M92 8 L68 32"),
        .path("M8 92 L32 68"),
        .path("M92 92 L68 68"),
        .rect(8, 8, 84, 84, 0),
        .rect(20, 20, 60, 60, 0),
        .rect(32, 32, 36, 36, 0),
        .circle(50, 50, 8),
    ], strokeWidth: 2.2)

}

/// Draws a BrandArt scaled to fit, keeping its stroke weight proportional (with a legibility floor).
struct BrandGlyph: View {
    var art: BrandArt
    var color: Color = Ink.ink
    var minLineWidth: CGFloat = 1.1

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / art.box.width, size.height / art.box.height)
            let dx = (size.width - art.box.width * s) / 2 - art.box.minX * s
            let dy = (size.height - art.box.height * s) / 2 - art.box.minY * s
            let t = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
            let shading = GraphicsContext.Shading.color(color)
            if !art.fills.isEmpty { ctx.fill(Path(BrandArt.cgPath(art.fills)).applying(t), with: shading) }
            let width = max(minLineWidth, art.strokeWidth * s)
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            if !art.strokes.isEmpty { ctx.stroke(Path(BrandArt.cgPath(art.strokes)).applying(t), with: shading, style: style) }
            for group in art.dashes {
                // Dash lengths scale with the drawing; a floored line width keeps its dashes proportionally longer.
                let k = width / max(0.001, art.strokeWidth * s)
                let dash = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: group.pattern.map { $0 * s * k })
                ctx.stroke(Path(BrandArt.cgPath(group.elements)).applying(t), with: shading, style: dash)
            }
            if !art.clipped.isEmpty {
                // Clip to each shape in turn: the hatch shows only where all of them overlap.
                var c = ctx
                for shape in art.clip { c.clip(to: Path(BrandArt.cgPath([shape])).applying(t)) }
                c.stroke(Path(BrandArt.cgPath(art.clipped)).applying(t), with: shading, style: StrokeStyle(lineWidth: max(minLineWidth * 0.8, art.clippedWidth * s)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One of the fine-line interface icons (`BrandArt.icon*`) at a fixed point size. Decorative: the label beside it
/// carries the meaning. The line keeps at least 1.2 pt so it holds up at sidebar and row sizes.
struct IconGlyph: View {
    var art: BrandArt
    var size: CGFloat = 20
    var color: Color = Ink.ink
    var body: some View {
        BrandGlyph(art: art, color: color, minLineWidth: 1.2).frame(width: size, height: size)
    }
}

/// A brand icon that takes the surrounding foreground style (a button's label color, a menu's tint), for `Label`
/// icons and toolbar buttons in place of SF Symbols. Decorative; the label carries the meaning.
struct ArtIcon: View {
    var art: BrandArt
    var size: CGFloat = 16
    var lineWidth: CGFloat = 1.3
    var body: some View {
        Canvas { ctx, sz in
            let sp = ArtSpace(box: art.box, size: sz)
            let w = max(lineWidth, art.strokeWidth * sp.s)
            let style = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
            if !art.fills.isEmpty { ctx.fill(Path(BrandArt.cgPath(art.fills)).applying(sp.transform), with: .foreground) }
            if !art.strokes.isEmpty { ctx.stroke(Path(BrandArt.cgPath(art.strokes)).applying(sp.transform), with: .foreground, style: style) }
            for group in art.dashes {
                let dash = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round, dash: group.pattern.map { $0 * sp.s })
                ctx.stroke(Path(BrandArt.cgPath(group.elements)).applying(sp.transform), with: .foreground, style: dash)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Label where Title == Text, Icon == ArtIcon {
    /// A label with a brand icon: `Label("Copy", art: .iconCopy)`.
    init(_ title: String, art: BrandArt, size: CGFloat = 16) {
        self.init { Text(title) } icon: { ArtIcon(art: art, size: size) }
    }
}

/// A keyboard shortcut as a keycap: mono inside an outlined capsule (DESIGN.md §2.3). Takes the foreground style.
struct Keycap: View {
    var keys: String
    var size: CGFloat = 11
    var body: some View {
        Text(keys).font(Ink.mono(size))
            .padding(.horizontal, size * 0.5).padding(.vertical, size * 0.25)
            .overlay(Capsule().strokeBorder(.foreground.opacity(0.75), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel(Keycap.spoken(keys))
    }

    /// "⌥⇧R" → "Option Shift R", for VoiceOver.
    static func spoken(_ keys: String) -> String {
        let names: [Character: String] = ["⌘": "Command", "⌥": "Option", "⇧": "Shift", "⌃": "Control", "⏎": "Return", "⎋": "Escape", "⌫": "Delete", "␣": "Space"]
        return keys.map { names[$0] ?? String($0) }.joined(separator: " ")
    }
}

/// An empty state's illustration: the icon drawn large inside a thin dashed construction circle with four ticks,
/// like a plate in a technical drawing.
struct IconPlate: View {
    var art: BrandArt
    var size: CGFloat = 120
    var color: Color = Ink.ink
    var body: some View {
        ZStack {
            Circle().inset(by: size * 0.042)
                .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [size * 0.033, size * 0.042]))
            Canvas { ctx, sz in
                var p = Path(); let w = sz.width, h = sz.height, t = w * 0.085
                p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: t))
                p.move(to: CGPoint(x: w / 2, y: h - t)); p.addLine(to: CGPoint(x: w / 2, y: h))
                p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: t, y: h / 2))
                p.move(to: CGPoint(x: w - t, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                ctx.stroke(p, with: .color(color.opacity(0.55)), lineWidth: 1)
            }
            BrandGlyph(art: art, color: color, minLineWidth: 1.4).frame(width: size * 0.55, height: size * 0.55)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#if os(iOS)
extension BrandArt {
    /// The icon as a template image for places that only take an Image (tab bar items), so the system tints it
    /// for selection, Dark mode, and Liquid Glass. Rendered once per art and size.
    @MainActor func templateImage(size: CGFloat, key: String, lineWidth: CGFloat = 1.6) -> UIImage {
        let cacheKey = "\(key)@\(size)" as NSString
        if let img = BrandArt.imageCache.object(forKey: cacheKey) { return img }
        let format = UIGraphicsImageRendererFormat.default()
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { r in
            let c = r.cgContext
            let s = min(size / box.width, size / box.height)
            c.translateBy(x: (size - box.width * s) / 2 - box.minX * s, y: (size - box.height * s) / 2 - box.minY * s)
            c.scaleBy(x: s, y: s)
            UIColor.black.setFill(); UIColor.black.setStroke()
            c.setLineCap(.round); c.setLineJoin(.round); c.setLineWidth(lineWidth / s)
            if !fills.isEmpty { c.addPath(BrandArt.cgPath(fills)); c.fillPath() }
            if !strokes.isEmpty { c.addPath(BrandArt.cgPath(strokes)); c.strokePath() }
            for g in dashes {
                c.setLineDash(phase: 0, lengths: g.pattern); c.addPath(BrandArt.cgPath(g.elements)); c.strokePath()
            }
            c.setLineDash(phase: 0, lengths: [])
        }.withRenderingMode(.alwaysTemplate)
        BrandArt.imageCache.setObject(img, forKey: cacheKey)
        return img
    }
    private static let imageCache = NSCache<NSString, UIImage>()
}
#endif

#if os(macOS)
extension BrandArt {
    /// The art as a template image for places that only take an image (the menu bar item, toolbars), so the
    /// system tints it for the menu bar, Dark mode, and selection. `size` is the image's points; the art fits inside.
    @MainActor func templateImage(size: CGFloat, key: String, lineWidth: CGFloat = 1.5) -> NSImage {
        if let img = BrandArt.nsImageCache[key + "@\(size)"] { return img }
        let art = self
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            let s = min(rect.width / art.box.width, rect.height / art.box.height)
            c.translateBy(x: (rect.width - art.box.width * s) / 2 - art.box.minX * s, y: (rect.height - art.box.height * s) / 2 - art.box.minY * s)
            c.scaleBy(x: s, y: s)
            c.setFillColor(NSColor.black.cgColor); c.setStrokeColor(NSColor.black.cgColor)
            c.setLineCap(.round); c.setLineJoin(.round); c.setLineWidth(lineWidth / s)
            if !art.fills.isEmpty { c.addPath(BrandArt.cgPath(art.fills)); c.fillPath() }
            if !art.strokes.isEmpty { c.addPath(BrandArt.cgPath(art.strokes)); c.strokePath() }
            return true
        }
        img.isTemplate = true
        BrandArt.nsImageCache[key + "@\(size)"] = img
        return img
    }
    @MainActor private static var nsImageCache: [String: NSImage] = [:]
}
#endif

/// The bars mark, flat, in one color. One color per mark; never pink or sage.
struct BarsMark: View {
    var color: Color = Ink.persimmon
    var body: some View { BrandGlyph(art: .markBars, color: color).aspectRatio(76.0 / 80.0, contentMode: .fit).accessibilityLabel("Verbatim") }
}

// MARK: - Editorial structure

/// "Recent ··········· 01": a sentence-case label, a dotted rule, and a mono index, with an optional serif title
/// below. No uppercase tracked labels (DESIGN.md §2.1); the index is the only mono.
struct EditorialSectionHeader<Trailing: View>: View {
    var index: String
    var label: String
    var title: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.dim).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                DottedRule().frame(height: 1)
                Text(index).font(Ink.mono(11)).foregroundStyle(Ink.mute).accessibilityHidden(true)
            }
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(Ink.serif(26)).foregroundStyle(Ink.ink).accessibilityAddTraits(.isHeader) }
                    Spacer(minLength: 12)
                    trailing()
                }
            }
        }
    }
}
extension EditorialSectionHeader where Trailing == EmptyView {
    init(index: String, label: String, title: String? = nil) { self.init(index: index, label: label, title: title, trailing: { EmptyView() }) }
}

struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath(); return p
    }
}

/// A fine dotted micro-rule.
struct DottedRule: View {
    var color: Color = Ink.faint
    var body: some View {
        GeometryReader { g in
            Path { p in p.move(to: CGPoint(x: 0, y: g.size.height / 2)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2)) }
                .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0.5, 4]))
        }
    }
}

/// A small registration tick in a card's corner (editorial surfaces only).
struct CornerTick: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); return p
    }
}

/// Text that links somewhere: ink with an underline on hover.
struct InlineLink: View {
    var title: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { Text(title); Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) }
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.ink)
                .underline(hover, color: Ink.ink.opacity(0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: - Feature cards (Capture / Refine / Understand)

enum BrandFeature: CaseIterable {
    case capture, refine, understand
    var index: String { switch self { case .capture: return "01"; case .refine: return "02"; case .understand: return "03" } }
    var title: String { switch self { case .capture: return "Capture"; case .refine: return "Refine"; case .understand: return "Understand" } }
    var art: BrandArt { switch self { case .capture: return .diagramCapture; case .refine: return .diagramRefine; case .understand: return .diagramUnderstand } }
}

// MARK: - Card motion (shared by Mac and iPhone)

/// Pointer-driven card motion, shared by every card in the app family.
/// - Tilt: the side under the pointer dips away, as if the pointer were resting on it (a few degrees at most).
/// - Lift: the card rises 2 pt and its shadow deepens, shifted away from the pointer.
/// - Edge light: a thin rim, brightest at the point nearest the pointer, over a hairline that firms on hover.
/// - Press: the card presses in (scale 0.98, a little more tilt) fast, and springs back over 300 ms.
/// Visual only. Callers keep hit-testing on a flat, untransformed layer, because a 3D-rotated view loses
/// clicks on macOS 26. On iPhone there is no hover, so only the press shows. Reduce Motion keeps the edge light and shadow and drops tilt, lift, and scale.
struct CardMotion: ViewModifier {
    var hover: CGPoint?
    var size: CGSize
    var pressed: Bool
    var radius: CGFloat
    var tilt: Double = 3
    var lift: Double = 2
    /// Rows that sit on paper use a quieter shadow than cards that float.
    var shadow: Bool = true
    @Environment(\.limitMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let w: CGFloat = max(size.width, 1)
        let h: CGFloat = max(size.height, 1)
        var nx: CGFloat = 0                                  // -0.5 … 0.5
        var ny: CGFloat = 0
        if let p = hover {
            nx = min(max(p.x / w, 0), 1) - 0.5
            ny = min(max(p.y / h, 0), 1) - 0.5
        }
        let on: Bool = hover != nil
        let move: Bool = !reduceMotion
        // Wide rows tilt less: the same angle moves a long edge much farther.
        let aspect: Double = Double(min(1, 2.2 * h / w + 0.25))
        let strength: Double = Double(min(1, 2 * (nx * nx + ny * ny).squareRoot()))
        let baseTilt: Double = tilt + (pressed ? 1 : 0)
        let angle: Double = (move && on) ? baseTilt * strength * aspect : 0
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let light = UnitPoint(x: Double(nx) + 0.5, y: Double(ny) + 0.5)
        let rimReach: CGFloat = max(w, h) * 0.55
        let dark: Bool = scheme == .dark
        let shadowOpacity: Double = on ? (dark ? 0.35 : 0.13) : 0
        let shadowX: CGFloat = move ? -nx * 6 : 0
        let liftY: CGFloat = (move && on && !pressed) ? -CGFloat(lift) : 0
        let hoverKey: String = hover.map { "\(Int($0.x / 2)),\(Int($0.y / 2))" } ?? ""

        return content
            // Sheen: a soft glow on the surface under the pointer.
            .overlay {
                shape.fill(RadialGradient(colors: [Color.white.opacity(dark ? 0.07 : 0.16), .clear],
                                          center: light, startRadius: 0, endRadius: rimReach))
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // Edge: the hairline firms up, and a light rim travels with the pointer.
            .overlay {
                shape.strokeBorder(Ink.outlineStrong.opacity(on ? 0.45 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(RadialGradient(colors: [Color.white.opacity(dark ? 0.55 : 0.95), Color.white.opacity(0)],
                                                  center: light, startRadius: 0, endRadius: rimReach), lineWidth: 1.25)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .background {
                if shadow {
                    shape.fill(Color.black.opacity(0.001))
                        .shadow(color: .black.opacity(shadowOpacity), radius: on ? 14 : 0, x: shadowX, y: on ? 8 : 0)
                }
            }
            .rotation3DEffect(.degrees(angle), axis: (x: -ny, y: nx, z: 0), perspective: 0.55)
            .offset(y: liftY)
            .scaleEffect(move && pressed ? 0.98 : 1)
            .animation(pressed ? Motion.press : Motion.card, value: pressed)
            .animation(Motion.card, value: hoverKey)
    }
}

extension View {
    func cardMotion(hover: CGPoint?, size: CGSize, pressed: Bool, radius: CGFloat, tilt: Double = 3, lift: Double = 2, shadow: Bool = true) -> some View {
        modifier(CardMotion(hover: hover, size: size, pressed: pressed, radius: radius, tilt: tilt, lift: lift, shadow: shadow))
    }
}

// MARK: - Buttons

/// Ink fill, reader-white label (cream fill, ink label in dark). The reliable primary control.
struct BrandPrimaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, large: large) }
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        var large: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .semibold))
                .foregroundStyle(Ink.onInteractive)
                .padding(.horizontal, large ? 16 : 12).frame(minHeight: large ? 34 : 28)
                .background(Ink.interactive.opacity(configuration.isPressed ? 0.85 : hover ? 0.92 : 1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.14), value: hover)
        }
    }
}

/// Reader-white surface, ink label, hairline edge.
struct BrandSecondaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, large: large) }
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        var large: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .medium))
                .foregroundStyle(Ink.ink)
                .padding(.horizontal, large ? 16 : 12).frame(minHeight: large ? 34 : 28)
                .background(configuration.isPressed ? Ink.wash : hover ? Ink.cardHover : Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(hover ? Ink.outlineStrong : Ink.hairline))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.14), value: hover)
        }
    }
}

extension ButtonStyle where Self == BrandPrimaryButtonStyle {
    static var brandPrimary: BrandPrimaryButtonStyle { BrandPrimaryButtonStyle() }
    static var brandPrimaryLarge: BrandPrimaryButtonStyle { BrandPrimaryButtonStyle(large: true) }
}
extension ButtonStyle where Self == BrandSecondaryButtonStyle {
    static var brandSecondary: BrandSecondaryButtonStyle { BrandSecondaryButtonStyle() }
    static var brandSecondaryLarge: BrandSecondaryButtonStyle { BrandSecondaryButtonStyle(large: true) }
}

// MARK: - Status and empty states

/// Concentric rings (the Capture diagram's language) for recording and processing. Still: movement on screen
/// means a real level (DESIGN.md §7), so the rings don't pulse on a loop.
struct SignalRings: View {
    var active = true
    var color: Color = Ink.persimmon
    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(color.opacity(0.7 - Double(i) * 0.2), lineWidth: max(1, d * 0.045))
                        .frame(width: d * (0.42 + CGFloat(i) * 0.29), height: d * (0.42 + CGFloat(i) * 0.29))
                }
                Circle().fill(color).frame(width: d * 0.22, height: d * 0.22)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// A compact, task-related empty-state picture: a brand icon on a soft tinted disc.
struct EmptyStateArt: View {
    var art: BrandArt = .document
    var tint: Color = Ink.butterTint
    var body: some View {
        ZStack {
            Circle().fill(tint)
            BrandGlyph(art: art, color: Ink.ink, minLineWidth: 1.4).padding(13)
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
    }
}

// MARK: - Drawing helpers

/// Damped springs stepped once per frame (semi-implicit Euler). Each spring chases its own target, so several
/// driven by one signal still move independently. A reference type kept in @State: stepping it while drawing
/// doesn't invalidate the view.
final class SpringBank {
    struct Spring { var k: Double; var d: Double; var gain: Double; var x = 0.0; var v = 0.0 }
    private(set) var springs: [Spring]
    private var last: Date?

    init(_ specs: [(k: Double, d: Double, gain: Double)]) {
        springs = specs.map { Spring(k: $0.k, d: $0.d, gain: $0.gain) }
    }

    /// Seconds since the previous frame, at most 50 ms; a long gap (paused, off screen) counts as one frame.
    func tick(_ now: Date) -> Double {
        defer { last = now }
        guard let prev = last else { return 0 }
        let dt = now.timeIntervalSince(prev)
        if dt <= 0 { return 0 }
        return dt > 0.25 ? 1.0 / 60 : min(0.05, dt)
    }

    func step(_ dt: Double, targets: [Double]) {
        guard dt > 0 else { return }
        for i in springs.indices where i < targets.count {
            let a = springs[i].k * (targets[i] - springs[i].x) - springs[i].d * springs[i].v
            springs[i].v += a * dt
            springs[i].x += springs[i].v * dt
        }
    }

    /// 1 + displacement × gain: the scale for spring `i`.
    func scale(_ i: Int) -> CGFloat { 1 + CGFloat(springs[i].x * springs[i].gain) }
    func value(_ i: Int) -> Double { springs[i].x }
}

/// CSS-style cubic-bezier easing, for drawings that animate by the clock.
enum CubicEase {
    /// cubic-bezier(x1, y1, x2, y2) at progress t (0…1).
    static func value(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ t: Double) -> Double {
        let x = min(1, max(0, t))
        func bez(_ a: Double, _ b: Double, _ s: Double) -> Double { 3 * a * (1 - s) * (1 - s) * s + 3 * b * (1 - s) * s * s + s * s * s }
        var lo = 0.0, hi = 1.0, s = x
        for _ in 0..<24 {
            s = (lo + hi) / 2
            if bez(x1, x2, s) < x { lo = s } else { hi = s }
        }
        return bez(y1, y2, s)
    }
    /// The prototype's ease: cubic-bezier(.22, .7, .2, 1).
    static func gentle(_ t: Double) -> Double { value(0.22, 0.7, 0.2, 1, t) }
    static func inOut(_ t: Double) -> Double { value(0.42, 0, 0.58, 1, t) }
}

/// Maps a design-space box onto a canvas, aspect fit and centered (as BrandGlyph does).
struct ArtSpace {
    let s: CGFloat, dx: CGFloat, dy: CGFloat
    init(box: CGRect, size: CGSize) {
        s = min(size.width / box.width, size.height / box.height)
        dx = (size.width - box.width * s) / 2 - box.minX * s
        dy = (size.height - box.height * s) / 2 - box.minY * s
    }
    var transform: CGAffineTransform { CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s) }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: dx + (x - r) * s, y: dy + (y - r) * s, width: 2 * r * s, height: 2 * r * s))
    }
}


/// The AI label (privacy policy and App Store AI disclosure): shown wherever Verbatim shows text a language model
/// rewrote, so nobody mistakes it for a word-for-word transcript.
struct AIGeneratedNote: View {
    /// The default is for rewritten text; summaries pass `AIGeneratedNote.summary`.
    var text: String = "Rewritten by Apple Intelligence. It can be wrong, so check names, numbers, and quotes against the transcript."
    static let summary = "Summarized by Apple Intelligence. It can be wrong, so check names, numbers, and quotes against the transcript."
    var body: some View {
        Label {
            Text(text)
        } icon: {
            ArtIcon(art: .iconAI, size: 13)
        }
        .font(.system(size: 12))
        .foregroundStyle(Ink.mute)
        .accessibilityElement(children: .combine)
    }
}
