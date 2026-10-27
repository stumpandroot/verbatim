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

    private static let lock = NSLock()
    private static var parsed: [String: CGPath] = [:]

    /// `parse`, once per path string: artwork redraws on every Canvas pass (looping drawings at 30 fps, the
    /// keyboard on every poll), and the strings are the fixed constants in this file. Safe from any thread.
    static func cached(_ d: String) -> CGPath {
        lock.lock()
        if let hit = parsed[d] { lock.unlock(); return hit }
        lock.unlock()
        let path = parse(d).copy() ?? CGMutablePath()
        lock.lock()
        if parsed.count >= 2048 { parsed.removeAll() }   // a guard only; the artwork has a few hundred strings
        parsed[d] = path
        lock.unlock()
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
            case .path(let d): p.addPath(SVGPathData.cached(d))
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

    // BEGIN ICONS (generated by mac/tools/gen_icons.py; edit that file, not this block)
    // Fine-line interface icons (icon set canvas, October 18, 2026): 24-unit grid, stroke 1.5, round ends.
    static let iconGrid = CGRect(x: 0, y: 0, width: 24, height: 24)
    static let iconHome = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 7), .circle(12, 15, 4), .path("M12 2.5V21.5"), .path("M10 2.5H14"), .path("M10 21.5H14")], strokeWidth: 1.5)
    static let iconLibrary = BrandArt(box: iconGrid, strokes: [.path("M3.5 20.5H20.5"), .path("M5 20.5V6H8.5V20.5"), .path("M10.5 20.5V9H14V20.5"), .path("M15.6 20.5L18.2 8.8L21 9.4L18.6 20.5")], strokeWidth: 1.5)
    static let iconLinks = BrandArt(box: iconGrid, strokes: [.circle(6.5, 12, 3.5), .circle(17.5, 12, 3.5), .path("M10 12H14")], fills: [.circle(6.5, 12, 1), .circle(17.5, 12, 1)], strokeWidth: 1.5)
    static let iconMoments = BrandArt(box: iconGrid, strokes: [.path("M3 15H21"), .path("M6 13.5V16.5"), .path("M18 13.5V16.5"), .circle(12, 15, 4.5), .path("M12 4.5V10.5")], fills: [.circle(12, 15, 1.6)], strokeWidth: 1.5)
    static let iconQueue = BrandArt(box: iconGrid, strokes: [.circle(5, 12, 1.4), .circle(5, 17, 1.4), .path("M9 7H20"), .path("M9 12H18"), .path("M9 17H15.5")], fills: [.circle(5, 7, 1.6)], strokeWidth: 1.5)
    static let iconDictations = BrandArt(box: iconGrid, strokes: [.path("M3 9C4.5 4.5 6 4.5 7.5 9S10.5 13.5 12 9 15 4.5 16.5 9 19.5 13.5 21 9"), .path("M3 15.5H21"), .path("M3 19.5H14")], strokeWidth: 1.5)
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
    static let iconDetails = BrandArt(box: iconGrid, strokes: [.circle(12, 12, 8.5), .path("M12 11V16.5")], fills: [.circle(12, 7.8, 1.1)], strokeWidth: 1.5)
    static let iconServer = BrandArt(box: iconGrid, strokes: [.path("M4.5 4.5H19.5V10.5H4.5Z"), .path("M4.5 13.5H19.5V19.5H4.5Z")], fills: [.circle(8, 7.5, 1), .circle(8, 16.5, 1)], strokeWidth: 1.5)
    static let iconLowerAudio = BrandArt(box: iconGrid, strokes: [.path("M4 9.5H7.5L12 5.5V18.5L7.5 14.5H4Z"), .path("M15.5 9.5C16.8 10.8 16.8 13.2 15.5 14.5"), .path("M18.5 15.5L20 17L21.5 15.5")], strokeWidth: 1.5)
    static let iconAccessibility = BrandArt(box: iconGrid, strokes: [.circle(12, 5, 1.8), .path("M5 8.5L12 10L19 8.5"), .path("M12 10V14.5"), .path("M12 14.5L9 20.5"), .path("M12 14.5L15 20.5")], strokeWidth: 1.5)
    static let iconDownload = BrandArt(box: iconGrid, strokes: [.path("M12 3.5V15"), .path("M8 11L12 15L16 11"), .path("M5 20.5H19")], strokeWidth: 1.5)
    static let iconActionButton = BrandArt(box: iconGrid, strokes: [.path("M5.5 3H15V21H5.5Z"), .path("M15 6.5H16.5V10.5H15"), .path("M19 7L20.5 6"), .path("M19 10L20.5 11")], fills: [.circle(10.25, 17.5, 1)], strokeWidth: 1.5)
    static let iconSponsor = BrandArt(box: iconGrid, strokes: [.path("M3.5 3.5H11.5L20.5 12.5L12.5 20.5L3.5 11.5Z"), .circle(8, 8, 1.6)], strokeWidth: 1.5)
    static let iconThought = BrandArt(box: iconGrid, strokes: [.path("M9.5 18 V16.3 C9.5 15.4 8.9 14.7 8.1 14.1 C5.99 12.44 5.17 9.62 6.05 7.09 C6.93 4.55 9.32 2.85 12 2.85 C14.68 2.85 17.07 4.55 17.95 7.09 C18.83 9.62 18.01 12.44 15.9 14.1 C15.1 14.7 14.5 15.4 14.5 16.3 V18"), .path("M8.5 18H15.5"), .path("M12 18V21.5"), .path("M10.5 21.5H13.5"), .path("M8.4 9.5C9.3 9.5 9.5 7.8 10.4 7.8S12.6 11.2 13.6 11.2S14.7 9.5 15.6 9.5")], strokeWidth: 1.5)
    static let iconCalendar = BrandArt(box: iconGrid, strokes: [.path("M5.5 5.5 H18.5 C19.33 5.5 20 6.17 20 7 V18.5 C20 19.33 19.33 20 18.5 20 H5.5 C4.67 20 4 19.33 4 18.5 V7 C4 6.17 4.67 5.5 5.5 5.5 Z"), .path("M4 10H20"), .path("M8.5 3.5V7.5"), .path("M15.5 3.5V7.5")], strokeWidth: 1.5)
    static let iconBackTap = BrandArt(box: iconGrid, strokes: [.path("M10 3 H14 C15.38 3 16.5 4.12 16.5 5.5 V18.5 C16.5 19.88 15.38 21 14 21 H10 C8.62 21 7.5 19.88 7.5 18.5 V5.5 C7.5 4.12 8.62 3 10 3 Z"), .path("M3.5 7C2.5 8.5 2.5 10.5 3.5 12"), .path("M20.5 7C21.5 8.5 21.5 10.5 20.5 12")], fills: [.circle(12, 8, 1.4)], strokeWidth: 1.5)
    static let iconSpeak = BrandArt(box: iconGrid, strokes: [.path("M5.5 20.5 V17 C3.05 15.17 2.22 11.88 3.49 9.1 C4.76 6.32 7.8 4.8 10.78 5.45 C13.77 6.1 15.9 8.74 15.9 11.8 L17.5 15.5 H15.3 V18 C15.46 18.61 15.32 19.26 14.93 19.75 C14.53 20.24 13.93 20.52 13.3 20.5 H11"), .path("M18.8 6.5C20 7.8 20 10.2 18.8 11.5"), .path("M21 4.5C23.2 6.9 23.2 11.6 21 14")], strokeWidth: 1.5)
    static let iconWidgets = BrandArt(box: iconGrid, strokes: [.path("M5 3.5 H9.5 C10.33 3.5 11 4.17 11 5 V9.5 C11 10.33 10.33 11 9.5 11 H5 C4.17 11 3.5 10.33 3.5 9.5 V5 C3.5 4.17 4.17 3.5 5 3.5 Z"), .path("M14.5 3.5 H19 C19.83 3.5 20.5 4.17 20.5 5 V9.5 C20.5 10.33 19.83 11 19 11 H14.5 C13.67 11 13 10.33 13 9.5 V5 C13 4.17 13.67 3.5 14.5 3.5 Z"), .path("M5 13 H19 C19.83 13 20.5 13.67 20.5 14.5 V19 C20.5 19.83 19.83 20.5 19 20.5 H5 C4.17 20.5 3.5 19.83 3.5 19 V14.5 C3.5 13.67 4.17 13 5 13 Z")], strokeWidth: 1.5)
    static let iconTabBar = BrandArt(box: iconGrid, strokes: [.path("M7 3 H17 C18.38 3 19.5 4.12 19.5 5.5 V18.5 C19.5 19.88 18.38 21 17 21 H7 C5.62 21 4.5 19.88 4.5 18.5 V5.5 C4.5 4.12 5.62 3 7 3 Z"), .path("M4.5 15.5H19.5")], fills: [.circle(8.5, 18.3, 1), .circle(12, 18.3, 1), .circle(15.5, 18.3, 1)], strokeWidth: 1.5)
    static let iconMark = BrandArt(box: iconGrid, strokes: [.path("M6.5 3.5H17.5V20.5L12 16.5L6.5 20.5Z"), .path("M12 7.5V12.5"), .path("M9.5 10H14.5")], strokeWidth: 1.5)
    static let iconMarked = BrandArt(box: iconGrid, strokes: [.path("M6.5 3.5H17.5V20.5L12 16.5L6.5 20.5Z"), .path("M9.3 10L11.3 12L14.8 8.5")], strokeWidth: 1.5)
    static let iconAsk = BrandArt(box: iconGrid, strokes: [.path("M4 5H20V16H11.5L7 20V16H4Z"), .path("M7.4 10.5C8.3 10.5 8.5 8.8 9.4 8.8S11.6 12.2 12.6 12.2S13.7 10.5 14.6 10.5H16.6")], strokeWidth: 1.5)
    static let iconHaptics = BrandArt(box: iconGrid, strokes: [.path("M10 3 H14 C15.38 3 16.5 4.12 16.5 5.5 V18.5 C16.5 19.88 15.38 21 14 21 H10 C8.62 21 7.5 19.88 7.5 18.5 V5.5 C7.5 4.12 8.62 3 10 3 Z"), .path("M5 9.5C4.3 10.9 4.3 13.1 5 14.5"), .path("M2.8 7.5C1.6 10.3 1.6 13.7 2.8 16.5"), .path("M19 9.5C19.7 10.9 19.7 13.1 19 14.5"), .path("M21.2 7.5C22.4 10.3 22.4 13.7 21.2 16.5")], strokeWidth: 1.5)
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
    // Thoughts (mockup "Thoughts", October 26, 2026; it replaced Idea's rays): the Thought icon's bulb, its filament a
    // sound wave with a dot at each end, and Home's axis with crossbars for a base.
    static let kindThought = BrandArt(box: glyphBox, strokes: [
        .path("M38 74 V66 C38 62 35.6 59.2 32.4 56.6 C24.51 49.35 21.88 38 25.78 28.02 C29.67 18.04 39.29 11.46 50 11.46 C60.71 11.46 70.33 18.04 74.22 28.02 C78.12 38 75.49 49.35 67.6 56.6 C64.4 59.2 62 62 62 66 V74"),
        .path("M30 37 C34 37 36 28 41 28 S54 46 59 46 S66 37 70 37"),
        .path("M32 74 L68 74"),
        .path("M50 74 L50 92"),
        .path("M40 92 L60 92"),
    ], fills: [.circle(30, 37, 3), .circle(70, 37, 3)], strokeWidth: 2.2)
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
    // Podcast, video, talk, and interview (October 2026): the same line family; a microphone, a frame and timeline,
    // a lectern, two people across a table.
    static let kindPodcast = BrandArt(box: glyphBox, strokes: [
        .path("M38 26 C38 19.37 43.37 14 50 14 C56.63 14 62 19.37 62 26 L62 46 C62 52.63 56.63 58 50 58 C43.37 58 38 52.63 38 46 Z"),
        .path("M44 30 L56 30"),
        .path("M44 38 L56 38"),
        .path("M44 46 L56 46"),
        .path("M72 46 C72 58.15 62.15 68 50 68 C37.85 68 28 58.15 28 46"),
        .path("M50 68 L50 84"),
        .path("M34 84 L66 84"),
        .path("M42 94 L58 94"),
        .path("M77.85 16.5 C86.05 28.21 86.05 43.79 77.85 55.5"),
        .path("M22.15 55.5 C13.95 43.79 13.95 28.21 22.15 16.5"),
        .path("M87.97 15.81 C94.68 28.43 94.68 43.57 87.97 56.19"),
        .path("M12.03 56.19 C5.32 43.57 5.32 28.43 12.03 15.81"),
    ], strokeWidth: 2.2)
    static let kindVideo = BrandArt(box: glyphBox, strokes: [
        .path("M8 18 L92 18 L92 70 L8 70 Z"),
        .path("M42 32 L62 44 L42 56 Z"),
        .path("M8 84 L92 84"),
        .circle(34, 84, 5),
        .path("M8 94 L34 94"),
    ], fills: [.circle(34, 84, 1.8)], strokeWidth: 2.2)
    static let kindTalk = BrandArt(box: glyphBox, strokes: [
        .circle(50, 22, 9),
        .path("M32 52 C32 42.06 40.06 34 50 34 C59.94 34 68 42.06 68 52"),
        .path("M22 52 L78 52"),
        .path("M32 60 L68 60 L62 94 L38 94 Z"),
        .path("M66.85 7.86 C73.72 16.04 73.72 27.96 66.85 36.14"),
        .path("M33.15 36.14 C26.28 27.96 26.28 16.04 33.15 7.86"),
        .path("M78.58 5.5 C84.47 15.71 84.47 28.29 78.58 38.5"),
        .path("M21.42 38.5 C15.53 28.29 15.53 15.71 21.42 5.5"),
    ], strokeWidth: 2.2)
    static let kindInterview = BrandArt(box: glyphBox, strokes: [
        .circle(24, 32, 11),
        .circle(76, 32, 11),
        .path("M8 72 C8 63.16 15.16 56 24 56 C32.84 56 40 63.16 40 72"),
        .path("M60 72 C60 63.16 67.16 56 76 56 C84.84 56 92 63.16 92 72"),
        .path("M6 72 L94 72"),
        .circle(50, 48, 6),
        .path("M50 54 L50 72"),
        .path("M20 72 L20 92"),
        .path("M80 72 L80 92"),
    ], fills: [.circle(24, 32, 2.2), .circle(76, 32, 2.2)], strokeWidth: 2.2)
    static let featureBackground = BrandArt(box: glyphBox, strokes: [
        .circle(50, 50, 38),
        .circle(50, 50, 18),
        .circle(78, 22, 6),
        .circle(16, 70, 4),
        .circle(74, 84, 3),
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

/// A keyboard shortcut as a keycap: mono inside an outlined rectangle with the button radius (DESIGN.md §2.3).
/// Takes the foreground style.
struct Keycap: View {
    var keys: String
    var size: CGFloat = 11
    var body: some View {
        Text(keys).font(Ink.mono(size))
            .padding(.horizontal, size * 0.5).padding(.vertical, size * 0.3)
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(ForegroundStyle().opacity(0.75), lineWidth: 1))
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
    var body: some View { BrandGlyph(art: .markBars, color: color).aspectRatio(76.0 / 80.0, contentMode: .fit).accessibilityLabel("Verbose") }
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
                .background(Ink.interactive.opacity(configuration.isPressed ? 0.85 : hover ? 0.92 : 1), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
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
                .background(configuration.isPressed ? Ink.wash : hover ? Ink.cardHover : Ink.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(hover ? Ink.outlineStrong : Ink.hairline))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
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


// MARK: - Looping drawings

/// Looping drawings (the panel art, the Record meter's breath) hold still in the screenshot tour
/// (VERBATIM_UITEST=1), so captures repeat.
enum LoopingArt {
    static let enabled = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] != "1"
}

/// A clock for drawings that loop: a TimelineView at most 30 frames a second that runs only while `running` is
/// true, the view is on screen (not scrolled away, not on another page), and the app is active. Paused, it holds
/// its last frame. Draw with a Canvas inside: on macOS 26 every SwiftUI transaction is expensive, so a loop never
/// drives state or a repeatForever animation, and it never runs while nobody can see it.
struct LoopTimeline<Content: View>: View {
    var running: Bool
    @ViewBuilder var content: (Date) -> Content
    @State private var onScreen = false
    @State private var scrolledIn = true
    #if os(macOS)
    @Environment(\.controlActiveState) private var activeState
    private var appActive: Bool { activeState != .inactive }
    #else
    @Environment(\.scenePhase) private var scenePhase
    private var appActive: Bool { scenePhase == .active }
    #endif

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(running && LoopingArt.enabled && onScreen && scrolledIn && appActive))) { timeline in
            content(timeline.date)
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .modifier(ScrollVisibility(visible: $scrolledIn))
    }
}

/// Tells a loop when its scroll view has scrolled it out of sight (macOS 15 and iOS 18; earlier systems rely on
/// appear and disappear).
private struct ScrollVisibility: ViewModifier {
    @Binding var visible: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        } else {
            content
        }
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

/// The end of some live words, cut only between words: the longest tail that fits in `lines` lines of
/// `lineHeight` at the width it's given, so nothing ever starts mid-word or behind an ellipsis (build 228 review,
/// P-23). `label` draws a candidate (its font and colors); the candidates drop one leading word at a time, and the
/// last word alone is the fallback.
struct TailWords<Label: View>: View {
    var text: String
    var lines: Int
    /// One line's height, line spacing included.
    var lineHeight: CGFloat
    @ViewBuilder var label: (String) -> Label

    /// At most this many candidates, the longest first; callers pass a few lines' worth of words.
    static var maxCandidates: Int { 32 }

    static func candidates(_ text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return [] }
        let first = max(0, words.count - maxCandidates)
        return (first..<words.count).map { words[$0...].joined(separator: " ") }
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach(Array(Self.candidates(text).enumerated()), id: \.offset) { _, tail in
                label(tail).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: lineHeight * CGFloat(lines) + 1, alignment: .topLeading)
        .clipped()   // only a single word longer than the space could overflow
    }
}
