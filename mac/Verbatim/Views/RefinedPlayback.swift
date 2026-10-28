import SwiftUI

// The refined look's reading and playback parts (DESIGN.md §13), shared by the Mac and iPhone apps: transcript
// reading text in the serif, the glass player bar (sage means playback), and the iPhone recorder's persimmon clock
// panel. Colors come from `Refined` (Tokens.swift) through `RefinedRules`, like the rest of the kit (RefinedKit.swift).

// MARK: - Reading text

/// A transcript line as you read it: the serif (New York) at 19 pt on iPhone and 18 on the Mac, scaled with Dynamic
/// Type, with room between lines (1.45 and 1.55 line height). Selectable, so a passage can be copied.
struct ReadingText: View {
    var text: String
    var color: Color = Refined.ink

    init(_ text: String, color: Color = Refined.ink) { self.text = text; self.color = color }

    var body: some View {
        Text(text).readingStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

extension View {
    /// The reading text style for any text (a `Text` built from runs, a text view's content).
    func readingStyle(_ color: Color = Refined.ink) -> some View {
        refinedFont(.reading).foregroundStyle(color)
    }
}

// MARK: - Player bar

/// The player at the foot of a transcript (mockup: transcript): system glass in a capsule with the play disc (ink,
/// with the glyph in paper), the time, the waveform as the scrubber with the played part in sage (iPhone) or a rail
/// with moment ticks (Mac), the time left (iPhone) or length (Mac), and the speed. Text sits on the system's glass, as
/// in Apple's own players; Reduce Transparency and Increase Contrast make it the solid card with a hairline. iPhone 60
/// pt tall, Mac 48; the caller places it and sets the Mac's width.
struct GlassPlayerBar: View {
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double
    /// Levels 0...1 across the whole recording, for the iPhone's waveform. Empty draws a rail.
    var levels: [Float] = []
    /// Moments, in seconds, ticked on the Mac's rail.
    var moments: [Double] = []
    var speed = "1×"
    var onPlayPause: () -> Void
    var onSeek: (Double) -> Void
    var onSpeed: () -> Void

    private let mac = RefinedPlatform.mac
    private var fraction: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlayPause) {
                Circle().fill(Refined.ink)
                    .frame(width: mac ? 34 : 40, height: mac ? 34 : 40)
                    .overlay(IconGlyph(art: isPlaying ? .iconPause : .iconPlay, size: mac ? 15 : 17, color: Refined.paper))
                    .frame(minWidth: CGFloat(RefinedRules.minTapTarget), minHeight: CGFloat(RefinedRules.minTapTarget))
                    .contentShape(Rectangle())
            }
            .buttonStyle(RefinedPress())
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Text(RefinedRules.time(elapsed)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.dim)
                .accessibilityHidden(true)
            scrubber
            Text(mac ? RefinedRules.time(duration) : "−" + RefinedRules.time(max(0, duration - elapsed)))
                .refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.dim)
                .accessibilityHidden(true)
            Button(action: onSpeed) {
                Text(speed).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink)
                    .frame(minWidth: CGFloat(RefinedRules.minTapTarget), minHeight: CGFloat(RefinedRules.minTapTarget))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speed")
            .accessibilityValue(speed)
        }
        .padding(.leading, mac ? 4 : 6).padding(.trailing, mac ? 6 : 4)
        .frame(minHeight: mac ? 48 : 60)
        .modifier(PlayerGlass())
    }

    private var scrubber: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                if levels.isEmpty || mac { drawRail(ctx, size) } else { drawWave(ctx, size) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard geo.size.width > 0, duration > 0 else { return }
                onSeek(min(1, max(0, g.location.x / geo.size.width)) * duration)
            })
        }
        .frame(height: mac ? 20 : 26)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(RefinedRules.spokenTime(elapsed)) of \(RefinedRules.spokenTime(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(duration, elapsed + 15))
            case .decrement: onSeek(max(0, elapsed - 15))
            @unknown default: break
            }
        }
    }

    private func drawRail(_ ctx: GraphicsContext, _ size: CGSize) {
        let h: CGFloat = 4, y = (size.height - h) / 2
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: h), cornerRadius: h / 2), with: .color(Refined.rail))
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width * fraction, height: h), cornerRadius: h / 2), with: .color(Refined.played))
        guard duration > 0 else { return }
        for m in moments where m >= 0 && m <= duration {
            let x = size.width * m / duration
            ctx.fill(Path(CGRect(x: x - 1, y: y - 3, width: 2, height: h + 6)), with: .color(Refined.accentText))
        }
    }

    private func drawWave(_ ctx: GraphicsContext, _ size: CGSize) {
        let bar: CGFloat = 3, gap: CGFloat = 2
        let count = max(1, Int((size.width + gap) / (bar + gap)))
        for i in 0..<count {
            let at = Double(i) / Double(max(1, count - 1))
            let level = CGFloat(levels[min(levels.count - 1, Int(at * Double(levels.count - 1)))])
            let h = max(3, size.height * min(1, max(0.12, level)))
            let rect = CGRect(x: CGFloat(i) * (bar + gap), y: (size.height - h) / 2, width: bar, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(at <= fraction ? Refined.played : Refined.waveRest))
        }
    }
}

/// The player's surface: system glass where the system has it (macOS 26 and iOS 26), the near-opaque card before
/// that, and the solid card with a hairline under Reduce Transparency or Increase Contrast.
private struct PlayerGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Refined.card, in: Capsule()).overlay(Capsule().strokeBorder(Refined.separator, lineWidth: 1))
        } else {
            glass(content)
        }
    }

    @ViewBuilder private func glass(_ content: Content) -> some View {
        if #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular, in: Capsule())   // brand: glass ok (the refined player, text allowed by DESIGN.md §13)
        } else {
            content.background(Refined.glassFallback, in: Capsule()).overlay(Capsule().strokeBorder(Refined.separator, lineWidth: 1))
        }
    }
}

// MARK: - Recorder clock panel

/// The iPhone recorder's clock (mockup: recorder): the persimmon panel with the ring drawing, the status chip
/// ("Recording" or "Paused"), the clock with hundredths in SF Pro Ultralight, and the live waveform under a playhead
/// at the middle, newest audio beside it and older audio fading to the left, with the marked moments as dots. Soft
/// palette: the persimmon tint. The waveform moves only with your voice (`levels` from the meter), so Limit animation
/// changes nothing here; the rings hold still under it. VoiceOver reads it as one element: the status and the time.
struct RecorderClockPanel: View {
    var status = "Recording"
    var elapsed: Double
    /// Recent levels 0...1, oldest first; the newest sits at the playhead.
    var levels: [Float]
    /// Moments as seconds before now (0 is now); those inside the strip's window show as dots.
    var momentsAgo: [Double] = []
    /// Seconds the strip's left half covers.
    var window: Double = 6
    @CurrentPalette private var palette: AppPalette
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = CGFloat(RefinedRules.TextRole.clock.size(mac: false))

    var body: some View {
        let ink = Refined.onFill(.persimmon, palette)
        VStack(alignment: .leading, spacing: 4) {
            ReadyChip(text: status)
            Text(RefinedRules.clock(elapsed))
                .font(.system(size: clockSize, weight: .ultraLight)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Canvas { ctx, size in draw(ctx, size, ink: ink) }
                .frame(height: 80)
                .padding(.top, 2)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            RecordRings(color: Refined.rings(palette), lineWidth: 2.4)
                .frame(width: 200, height: 200)
                .offset(x: 50, y: -40)
        }
        .refinedSurface(Refined.fill(.persimmon, palette), radius: RefinedPlatform.radius(.record))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status)
        .accessibilityValue(RefinedRules.spokenTime(elapsed))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, ink: Color) {
        let bar: CGFloat = 3, gap: CGFloat = 3, mid = size.width / 2
        let slots = max(1, Int((mid + gap) / (bar + gap)))
        let recent = levels.suffix(slots)
        for (k, level) in recent.reversed().enumerated() {
            let x = mid - CGFloat(k + 1) * (bar + gap) + gap / 2
            let h = max(3, size.height * CGFloat(min(1, max(0.06, level))))
            // The newest half of what shows is full ink; older audio fades.
            let opacity = k < slots / 2 ? 1 : 0.38
            ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h), cornerRadius: 1.5),
                     with: .color(ink.opacity(opacity)))
        }
        ctx.fill(Path(CGRect(x: mid - 1, y: 0, width: 2, height: size.height)), with: .color(ink))
        for ago in momentsAgo where ago >= 0 && ago <= window {
            let x = mid - mid * CGFloat(ago / window)
            ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 4, width: 8, height: 8)), with: .color(ink))
        }
    }
}

// MARK: - Previews

#if DEBUG
struct ReadingText_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) { SpeakerChip(name: "Tim", index: 0); Text("0:00").refinedFont(.meta).foregroundStyle(Refined.mute) }
                ReadingText("Okay, so the catalog needs to work for the folding wagon and the full wheel line.")
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) { SpeakerChip(name: "Jonathan", index: 1); Text("0:06").refinedFont(.meta).foregroundStyle(Refined.sageText) }
                ReadingText("Right. Jonathan wants the wheels first, then the wagons as a second section.")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Refined.playing, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(20).frame(width: 390).background(Refined.paper)
    }
}

struct GlassPlayerBar_Previews: PreviewProvider {
    static let levels: [Float] = (0..<80).map { Float(0.3 + 0.6 * abs(sin(Double($0) * 0.7))) }
    static var previews: some View {
        VStack(spacing: 20) {
            GlassPlayerBar(isPlaying: true, elapsed: 7, duration: 42, levels: levels, moments: [12.6],
                           onPlayPause: {}, onSeek: { _ in }, onSpeed: {})
            GlassPlayerBar(isPlaying: false, elapsed: 7, duration: 42, onPlayPause: {}, onSeek: { _ in }, onSpeed: {})
        }
        .padding(16).frame(width: RefinedPlatform.mac ? 600 : 390).background(Refined.paper)
    }
}

struct RecorderClockPanel_Previews: PreviewProvider {
    static let levels: [Float] = (0..<60).map { Float(0.25 + 0.6 * abs(sin(Double($0) * 0.9))) }
    static var previews: some View {
        ForEach(AppPalette.allCases) { p in
            RecorderClockPanel(elapsed: 72.48, levels: levels, momentsAgo: [4.2])
                .padding(20).frame(width: 390).background(Refined.paper)
                .environment(\.paletteOverride, p)
                .previewDisplayName("Recorder, \(p.label)")
        }
    }
}
#endif
