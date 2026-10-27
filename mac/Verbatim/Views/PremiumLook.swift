import SwiftUI
import AppKit

// brand: native file
//
// Premium Native on the Mac (DESIGN.md §13.2, mockup "Premium Native", section 01): the first Native look with more
// feel. A warm off-white window (black in dark) with a soft persimmon glow at the top, white cards with a soft shadow,
// gradient cards in the warm brand colors for This week, the stats, and summaries, big numbers in SF Pro Rounded, and a
// floating record button. Titles stay SF Pro (no serif); the accent stays `Ink.nativeAccent`, with black text on it in
// dark. Hex values and the colors both devices share live in Tokens.swift (`PremiumInk`); the rules the Linux tests check are in PremiumRules.swift.

// MARK: - Colors

extension PremiumInk {
    /// The window: #F6F3F1 in light, near black in dark. `NativeRole.window` (paper under Native) resolves to it too.
    static let windowNS = NSColor(name: nil) { a in NSColor(hex: a.isDark ? PremiumInk.windowDarkHex : PremiumInk.paperLightHex) }
    static let window = Color(nsColor: windowNS)
    /// White cards (#1C1C1E-ish in dark): the system's content background.
    static let card = Color(nsColor: .controlBackgroundColor)
    // The selection tint and soft accent fills (`accentSoft`) and text on the accent (`onAccent`, white in light and
    // black in dark, because white on #FF6B47 measures 2.8:1) are shared with iPhone, in Tokens.swift.
    /// Small accent text on the window, cards, and the selection tint (5.2:1 in light; the accent itself in dark).
    static let accentText = Color(nsColor: NSColor(name: nil) { a in NSColor(hex: a.isDark ? Ink.nativeAccentDarkHex : PremiumInk.accentTextLightHex) })
    /// Fills for tracks, chips, and bordered buttons.
    static let fill = Color.primary.opacity(0.07)
    static let fillStrong = Color.primary.opacity(0.12)
    static let separator = Color(nsColor: .separatorColor)
    /// The card shadow: soft and warm in light, a faint edge in dark.
    static let shadow = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor.black.withAlphaComponent(0.5) : NSColor.black.withAlphaComponent(0.1)
    })
    static let cardEdge = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.04)
    })
    static let glow = Color(nsColor: NSColor(name: nil) { a in NSColor(hex: Ink.persimmonHex).withAlphaComponent(a.isDark ? 0.16 : 0.17) })

    /// A gradient card's colors, top to bottom, following light and dark.
    static func gradient(_ card: PremiumCard) -> LinearGradient {
        let (light, dark): ([UInt32], [UInt32]) = {
            switch card {
            case .persimmon: return (PremiumInk.macPersimmonLight, PremiumInk.macPersimmonDark)
            case .ink: return (PremiumInk.inkLight, PremiumInk.inkDark)
            case .sage: return (PremiumInk.macSageLight, PremiumInk.macSageDark)
            }
        }()
        let stops = zip(light.indices, card.locations).map { i, at in
            Gradient.Stop(color: Color(nsColor: NSColor(name: nil) { a in NSColor(hex: a.isDark ? dark[min(i, dark.count - 1)] : light[i]) }), location: at)
        }
        // The mockup's 160°: nearly top to bottom, leaning a little to the right.
        return LinearGradient(stops: stops, startPoint: UnitPoint(x: 0.36, y: 0), endPoint: UnitPoint(x: 0.64, y: 1))
    }
}

// MARK: - Surfaces

/// The window's background: the warm off-white (or black) with the persimmon glow at the top left.
/// The window glow's size: its radius follows the width, and its frame is never shorter than the radius.
enum PremiumGlow {
    static func radius(width: CGFloat) -> CGFloat { max(320, width * 0.62) }
    static func height(width: CGFloat) -> CGFloat { max(420, radius(width: width).rounded(.up)) }
}

struct PremiumBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            PremiumInk.window
            GeometryReader { g in
                // The frame is as tall as the glow's radius, so the gradient reaches clear before the frame ends (at
                // 420 pt it was cut off at a hard line while still tinted, on any window wider than 677 pt).
                let radius = PremiumGlow.radius(width: g.size.width)
                RadialGradient(colors: [PremiumInk.glow, PremiumInk.glow.opacity(0)], center: UnitPoint(x: 0.3, y: 0),
                               startRadius: 0, endRadius: radius)
                    .frame(height: PremiumGlow.height(width: g.size.width))
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// A white card with a soft shadow (no outline), as the mockup's tiles, preview, and inspector boxes.
    func premiumCard(radius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            shape.fill(PremiumInk.card)
                .shadow(color: PremiumInk.shadow, radius: 11, y: 6)
                .overlay(shape.strokeBorder(PremiumInk.cardEdge, lineWidth: 0.5))
        }
    }

    /// A gradient card: the brand gradient, a light edge along the top, and a soft colored shadow. White text on it
    /// sits where PremiumRules.swift says it reads.
    func gradientCard(_ card: PremiumCard, radius: CGFloat = 24) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // The card's own controls (a menu) draw for a dark surface; the gradient behind follows light and dark.
        return environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .background {
                shape.fill(PremiumInk.gradient(card))
                    .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 1))
            }
            .clipShape(shape)
            .background { shape.fill(Color.black.opacity(0.18)).blur(radius: 12).offset(y: 10).padding(.horizontal, 10).allowsHitTesting(false) }
    }
}

/// SF Pro Rounded, heavy, with tabular digits: every big number.
enum PremiumType {
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded).monospacedDigit() }
}

// MARK: - Buttons

/// The accent button: a capsule in `Ink.nativeAccent` with white text in light and black text in dark.
struct PremiumProminentButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, height: height) }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        var height: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(PremiumInk.onAccent)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background(Capsule().fill(Ink.nativeAccent).brightness(configuration.isPressed ? -0.08 : (hover ? 0.04 : 0)))
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover = $0 }
        }
    }
}

/// The gray capsule button beside it.
struct PremiumBorderedButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    var tinted = false
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, height: height, tinted: tinted) }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        var height: CGFloat
        var tinted: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: tinted ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(tinted ? AnyShapeStyle(PremiumInk.accentText) : AnyShapeStyle(Color.primary))
                .padding(.horizontal, 14)
                .frame(height: height)
                .background(Capsule().fill(tinted ? PremiumInk.accentSoft : (configuration.isPressed || hover ? PremiumInk.fillStrong : PremiumInk.fill)))
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover = $0 }
        }
    }
}

/// The floating record button (Home and Library): the brand persimmon disc with a light ring, bottom right, with an
/// opaque "Record" label beside it on Home. A click starts a voice note; right-click offers the other ways to start.
struct PremiumRecordButton: View {
    @EnvironmentObject var app: AppState
    var label = true
    @State private var hover = false
    @Environment(\.limitMotion) private var limitMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            if label {
                Text("Record")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 32)
                    .premiumCard(radius: 16)
                    .accessibilityHidden(true)
            }
            Button { app.requestRecord() } label: {
                Circle()
                    .fill(RadialGradient(colors: [Color(nsColor: NSColor(hex: Ink.persimmonHex)).opacity(0.55), Ink.persimmonFixed],
                                         center: UnitPoint(x: 0.34, y: 0.28), startRadius: 0, endRadius: 34))
                    .overlay(Circle().fill(Color.black.opacity(0.08)).mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)))
                    .frame(width: 58, height: 58)
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(scheme == .dark ? 0.14 : 0.75)))
                    .shadow(color: Ink.persimmonFixed.opacity(0.45), radius: 12, y: 8)
                    .scaleEffect(hover && !limitMotion ? 1.04 : 1)
                    .animation(limitMotion ? nil : Motion.touch, value: hover)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("Record a voice note (⌥⇧R)")
            .accessibilityLabel("Record")
            .accessibilityHint("Starts a voice note.")
            .contextMenu {
                Button("Record a Voice Note") { app.requestRecord() }
                Button("Dictate…") { app.goHome(); app.captureMode = "dictate" }
                Button("Live Captions") { app.toggleLiveCaptions() }
                Button("Import Files…") { app.chooseFiles() }
                Divider()
                RecordMenu(onChange: {})
            }
            .uiTarget("native-record")
        }
    }
}

// MARK: - Gradient cards

/// This week on Home: "This week ›", the words in a big rounded number, and the seven days as white bars, today solid.
struct PremiumWeekCard: View {
    var week: HomeWeek
    var height: CGFloat = 208

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("This week").font(.system(size: 15, weight: .bold))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).opacity(0.85)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 8)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(week.words.formatted()).font(PremiumType.number(64)).lineLimit(1).minimumScaleFactor(0.5)
                    Text(week.words == 1 ? "word dictated" : "words dictated").font(.system(size: 17, weight: .semibold)).opacity(0.94)
                }
                Spacer(minLength: 8)
                bars
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .gradientCard(.persimmon, radius: 26)
    }

    private var bars: some View {
        let shown = WeekBars.bars(words: week.days.map(\.words), future: week.days.map(\.isFuture), maxHeight: 70)
        return HStack(alignment: .bottom, spacing: 9) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { i, day in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(day.isToday ? 1 : (shown[i].stub ? 0.18 : 0.36)))
                        .frame(width: 14, height: shown[i].height)
                    Text(Formats.pattern("EEEEE").string(from: day.start)).font(.system(size: 11, weight: .semibold)).opacity(0.8)
                }
            }
        }
        .frame(height: 92, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// A stat card on Home: the number in big rounded type, its name and period on the right.
struct PremiumStatCard: View {
    var card: PremiumCard
    var value: String
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: 10) {
            Text(value).font(PremiumType.number(40)).lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .bold))
                Text(detail).font(.system(size: 14, weight: .bold)).opacity(0.82)
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gradientCard(card, radius: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(detail): \(value)")
    }
}

/// A transcript's summary on a persimmon gradient card: "Summary", the overview as a headline, the key points, and
/// "Made by Apple Intelligence" at the foot (small text sits low, where the gradient is deepest). `menu` adds Edit
/// and Regenerate.
struct PremiumSummaryCard: View {
    var summary: TranscriptSummary
    var byModel: Bool
    var compact = false
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                Text("Summary").font(.system(size: 14, weight: .bold))
                Spacer(minLength: 0)
                if onEdit != nil || onRegenerate != nil {
                    Menu {
                        if let onEdit { Button("Edit Summary", action: onEdit) }
                        if let onRegenerate { Button("Regenerate", action: onRegenerate) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).frame(width: 24, height: 20).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Summary options")
                }
            }
            if !summary.overview.isEmpty {
                Text(summary.overview).font(.system(size: compact ? 16 : 17, weight: .bold)).lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.top, 10)
            }
            if !summary.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.keyPoints.prefix(compact ? 3 : 6).enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").font(.system(size: 13, weight: .bold))
                            Text(p).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Key points")
            }
            if byModel {
                Text(AIGeneratedNote.summary).font(.system(size: 11.5, weight: .medium)).opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gradientCard(.persimmon, radius: 20)
    }
}
