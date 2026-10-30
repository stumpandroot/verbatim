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

    /// Reading text at a size the reader picked (the Mac's ⌘+ and ⌘−), in the serif with the reading line height.
    func readingStyle(size: CGFloat, color: Color = Refined.ink) -> some View {
        let base = RefinedRules.TextRole.reading.size(mac: RefinedPlatform.mac)
        let spacing = RefinedRules.lineSpacing(.reading, mac: RefinedPlatform.mac) / base
        return font(.system(size: size, design: .serif)).lineSpacing(size * CGFloat(spacing)).foregroundStyle(color)
    }
}

// MARK: - Turns

/// The line above a turn's text: the time in the meta style with tabular digits (sage text while the turn plays), and
/// a small accent bookmark when the line is marked or bookmarked (never a butter wash). The caller puts the speaker's
/// chip before it when the speaker changes, and makes the time a button that plays from there.
struct TurnTime: View {
    var time: String
    var playing = false
    var marked = false

    var body: some View {
        HStack(spacing: 5) {
            Text(time).refinedFont(.meta).monospacedDigit().foregroundStyle(playing ? Refined.sageText : Refined.mute)
                .lineLimit(1).fixedSize()
            if marked { MomentMark() }
        }
    }
}

/// A marked or bookmarked line's mark: the bookmark glyph in the accent, 12 pt on the Mac and 13 on iPhone.
/// Decorative: the turn's spoken label says "marked".
struct MomentMark: View {
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = RefinedPlatform.mac ? 12 : 13
    init() {}
    var body: some View {
        IconGlyph(art: .iconMarked, size: size, color: Refined.accentText).accessibilityHidden(true)
    }
}

/// A moment marked while recording, under its line: the accent mark, "Moment 0:24", and where it came from
/// ("Lock Screen") on the neutral wash. The caller makes it a button that plays from the moment.
struct MomentChip: View {
    var time: String
    var source: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            MomentMark()
            Text("Moment").refinedFont(.chip, weight: .semibold)
            Text(time).refinedFont(.chip).monospacedDigit()
            if let source { Text("\u{00B7} \(source)").refinedFont(.chip).foregroundStyle(Refined.dim) }
        }
        .foregroundStyle(Refined.ink)
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Refined.neutral, in: Capsule())
    }
}

/// A turn's surface: the same padding on every turn, so the playing wash never moves the text. Playing takes the sage
/// `playing` wash; a selected line (a note links to it) the neutral wash with an accent bar at its leading edge; a
/// hovered line (Mac) the stripe.
struct ReadingTurnSurface: ViewModifier {
    var playing = false
    var selected = false
    var hovered = false
    private var mac: Bool { RefinedPlatform.mac }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .padding(.horizontal, mac ? 12 : 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(playing ? Refined.playing : selected ? Refined.neutral : hovered ? Refined.stripe : Color.clear, in: shape)
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Refined.accentText)
                        .frame(width: 3).padding(.vertical, 8)
                }
            }
            .padding(.horizontal, mac ? -12 : -10)
    }
}

extension View {
    func readingTurn(playing: Bool = false, selected: Bool = false, hovered: Bool = false) -> some View {
        modifier(ReadingTurnSurface(playing: playing, selected: selected, hovered: hovered))
    }
}

/// Search matches in reading text: butter behind the match with ink fixed on it, in light and dark.
enum ReadingHighlight {
    static func marked(_ text: AttributedString, query: String) -> AttributedString {
        var a = text
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return a }
        var from = a.startIndex
        while from < a.endIndex, let r = a[from...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Refined.badge(.butter)
            a[r].foregroundColor = Refined.onFill
            from = r.upperBound
        }
        return a
    }
}

extension Transcript {
    /// A template's result as a transcript's tab: named for its template ("Meeting notes"), "Results" with more than
    /// one, or the template that's running or waiting; nil when there's none.
    func resultTabTitle(busyName: String?) -> String? {
        let r = shownTemplateResults
        if r.count == 1 { return r[0].name }
        if r.count > 1 { return "Results" }
        if let busyName { return busyName }
        return autoRun.flatMap { $0.state == .waiting || $0.state == .failed ? $0.name : nil }
    }

    /// Each speaker's place in the chip rotation (DESIGN.md §13): the order they first talk, then anyone who never
    /// talks in the order the transcript lists them. Worked out once per render, not per line.
    var speakerOrder: [String: Int] {
        var out: [String: Int] = [:]
        for s in segments { if let sp = s.speaker, out[sp] == nil { out[sp] = out.count } }
        for sp in speakers where out[sp.id] == nil { out[sp.id] = out.count }
        return out
    }
}

// MARK: - Player bar

/// The player at the foot of a transcript (mockup: transcript): system glass in a capsule with the play disc (ink,
/// with the glyph in paper), the time, the waveform as the scrubber with the played part in sage and the moments as
/// accent ticks (iPhone) or a rail with the moments as ticks (Mac), the time left (iPhone) or length (Mac), and the
/// speed. Text sits on the system's glass, as in Apple's own players; Reduce Transparency and Increase Contrast make
/// it the solid card with a hairline. iPhone 60 pt tall, Mac 48; the caller places it and sets the Mac's width.
///
/// The speed is a button (`onSpeed`) or a menu of the caller's `options` (the speeds, skips, Reduce background noise,
/// Mark this moment, Follow). `status` takes the elapsed time's place for a moment ("Skipped a sponsor read"), and
/// `loading` puts a spinner in the play disc while the audio downloads. VoiceOver reads the play button, the position
/// as an adjustable value (15 seconds a swipe), and the speed.
struct GlassPlayerBar<Options: View>: View {
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double
    /// Levels 0...1 across the whole recording, for the iPhone's waveform. Empty draws a rail.
    var levels: [Float] = []
    /// Moments, in seconds: ticks on the Mac's rail and the iPhone's waveform.
    var moments: [Double] = []
    var speed = "1×"
    var status: String? = nil
    var loading = false
    var onPlayPause: () -> Void
    var onSeek: (Double) -> Void
    var onSpeed: (() -> Void)? = nil
    @ViewBuilder var options: Options

    private var mac: Bool { RefinedPlatform.mac }
    private var fraction: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlayPause) {
                Circle().fill(Refined.ink)
                    .frame(width: mac ? 34 : 40, height: mac ? 34 : 40)
                    .overlay {
                        if loading {
                            ProgressView().controlSize(.small).tint(Refined.paper)
                        } else {
                            IconGlyph(art: isPlaying ? .iconPause : .iconPlay, size: mac ? 15 : 17, color: Refined.paper)
                        }
                    }
                    .frame(minWidth: CGFloat(RefinedRules.minTapTarget), minHeight: CGFloat(RefinedRules.minTapTarget))
                    .contentShape(Rectangle())
            }
            .buttonStyle(RefinedPress())
            .disabled(loading)
            .accessibilityLabel(loading ? "Downloading audio" : isPlaying ? "Pause" : "Play")

            Group {
                if let status {
                    // Read aloud as it shows (a skipped sponsor read); never a dialog.
                    Text(status).refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1).fixedSize()
                        .onAppear { AccessibilityNotification.Announcement(status).post() }
                } else {
                    Text(RefinedRules.time(elapsed)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.dim)
                        .accessibilityHidden(true)
                }
            }
            scrubber
            Text(mac ? RefinedRules.time(duration) : "\u{2212}" + RefinedRules.time(max(0, duration - elapsed)))
                .refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.dim)
                .accessibilityHidden(true)
            speedControl
        }
        .padding(.leading, mac ? 4 : 6).padding(.trailing, mac ? 6 : 4)
        .frame(minHeight: mac ? 48 : 60)
        .modifier(PlayerGlass())
    }

    private var speedLabel: some View {
        Text(speed).refinedFont(.meta, weight: .semibold).monospacedDigit().foregroundStyle(Refined.ink)
            .frame(minWidth: CGFloat(RefinedRules.minTapTarget), minHeight: CGFloat(RefinedRules.minTapTarget))
            .contentShape(Rectangle())
    }

    @ViewBuilder private var speedControl: some View {
        if Options.self == EmptyView.self {
            Button { onSpeed?() } label: { speedLabel }
                .buttonStyle(.plain)
                .accessibilityLabel("Speed")
                .accessibilityValue(speed)
        } else {
            Menu { options } label: { speedLabel }
                #if os(macOS)
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                #endif
                .accessibilityLabel("Speed and playback options")
                .accessibilityValue(speed)
        }
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
        drawMoments(ctx, size, top: y - 3, height: h + 6)
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
        drawMoments(ctx, size, top: 0, height: size.height)
    }

    /// The moments as thin accent ticks across the rail or the waveform.
    private func drawMoments(_ ctx: GraphicsContext, _ size: CGSize, top: CGFloat, height: CGFloat) {
        guard duration > 0 else { return }
        for m in moments where m >= 0 && m <= duration {
            let x = min(size.width - 1, max(1, size.width * m / duration))
            ctx.fill(Path(CGRect(x: x - 1, y: top, width: 2, height: height)), with: .color(Refined.accentText))
        }
    }
}

extension GlassPlayerBar where Options == EmptyView {
    /// The bar with the speed as a button.
    init(isPlaying: Bool, elapsed: Double, duration: Double, levels: [Float] = [], moments: [Double] = [], speed: String = "1×",
         status: String? = nil, loading: Bool = false,
         onPlayPause: @escaping () -> Void, onSeek: @escaping (Double) -> Void, onSpeed: @escaping () -> Void) {
        self.init(isPlaying: isPlaying, elapsed: elapsed, duration: duration, levels: levels, moments: moments, speed: speed,
                  status: status, loading: loading, onPlayPause: onPlayPause, onSeek: onSeek, onSpeed: onSpeed) { EmptyView() }
    }
}

// MARK: - Audio only

/// An Audio only recording's player, its screen's main content (mockup "Verbose Brain Dump", section 4, on the refined
/// kit): the waveform with the played part in sage and the moments as accent ticks (drag or tap it to move), the time
/// and the length, back 5 seconds, the ink play disc, and the speed's menu (`options`), on a card. VoiceOver reads
/// the position as an adjustable value, 5 seconds a swipe.
struct AudioPlayerCard<Options: View>: View {
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double
    var levels: [Float]
    /// Moments, 0...1 of the way through.
    var moments: [Double] = []
    var speed = "1\u{00D7}"
    /// The play button's accessibility identifier, for the self-tests.
    var playID = "audio.play"
    var onPlayPause: () -> Void
    var onSeek: (Double) -> Void
    @ViewBuilder var options: Options

    private var mac: Bool { RefinedPlatform.mac }
    private var fraction: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { g in
                AudioWave(levels: levels, played: fraction, marks: moments,
                          bar: Refined.waveRest, playedColor: Refined.played, mark: Refined.accentText, bars: mac ? 90 : 64)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        guard g.size.width > 0, duration > 0 else { return }
                        onSeek(min(1, max(0, v.location.x / g.size.width)) * duration)
                    })
            }
            .frame(height: mac ? 72 : 76)
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue("\(RefinedRules.spokenTime(elapsed)) of \(RefinedRules.spokenTime(duration))")
            .accessibilityAdjustableAction { d in
                onSeek(d == .increment ? min(duration, elapsed + 5) : max(0, elapsed - 5))
            }
            HStack {
                Text(RefinedRules.time(elapsed))
                Spacer()
                Text(RefinedRules.time(duration))
            }
            .refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute)
            .accessibilityHidden(true)
            HStack(spacing: 32) {
                Button { onSeek(max(0, elapsed - 5)) } label: {
                    IconGlyph(art: .iconBack5, size: 22, color: Refined.ink)
                        .frame(minWidth: CGFloat(RefinedRules.minTapTarget), minHeight: CGFloat(RefinedRules.minTapTarget))
                        .contentShape(Rectangle())
                }
                .buttonStyle(RefinedPress())
                .help("Back 5 seconds")
                .accessibilityLabel("Back 5 seconds")
                Button(action: onPlayPause) {
                    Circle().fill(Refined.ink).frame(width: 56, height: 56)
                        .overlay(IconGlyph(art: isPlaying ? .iconPause : .iconPlay, size: 22, color: Refined.paper))
                        .contentShape(Circle())
                }
                .buttonStyle(RefinedPress())
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier(playID)
                Menu { options } label: {
                    Text(speed).refinedFont(.body, weight: .semibold).monospacedDigit().foregroundStyle(Refined.ink)
                        .frame(minWidth: CGFloat(RefinedRules.minTapTarget), minHeight: CGFloat(RefinedRules.minTapTarget))
                        .contentShape(Rectangle())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                #endif
                .accessibilityLabel("Speed")
                .accessibilityValue(speed)
            }
        }
        .padding(18)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.tile))
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
        // VoiceOver reads the time when you move to the panel, not on every tick: no `updatesFrequently`.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status)
        .accessibilityValue(RefinedRules.spokenTime(elapsed))
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

// MARK: - Recording card

/// The Mac's recording card (mockup: Mac Home while recording), which the Record card turns into while you record: the
/// persimmon panel with the status dot, what's recording and from where, the clock (SF Pro Ultralight), the live
/// waveform (newest on the right, moving only with your voice), your words as they're heard, and the actions the
/// caller puts in `controls` (Mark moment, Pause, and Stop and transcribe). Soft palette: the persimmon tint. The
/// fast-changing parts observe `live` on their own, so the rest of the card doesn't redraw with the meter.
///
/// Compact is the same card for the Mac's small recording surfaces (the menu bar panel, the meeting panel, and the
/// Thought bubble): the title and the clock on one line, the detail under them, a shorter waveform, and less padding.
struct RecordingCard<Words: View, Controls: View>: View {
    var title: String
    var detail: String
    var live: LiveMeter
    var paused = false
    var compact = false
    @ViewBuilder var words: Words
    @ViewBuilder var controls: Controls
    @CurrentPalette private var palette: AppPalette

    init(title: String, detail: String, live: LiveMeter, paused: Bool = false, compact: Bool = false,
         @ViewBuilder words: () -> Words, @ViewBuilder controls: () -> Controls) {
        self.title = title; self.detail = detail; self.live = live; self.paused = paused; self.compact = compact
        self.words = words(); self.controls = controls()
    }

    var body: some View {
        let ink = Refined.onFill(.persimmon, palette)
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if compact {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(ink).frame(width: 8, height: 8).opacity(paused ? 0.4 : 1).accessibilityHidden(true)
                        Text(title).refinedFont(.body, weight: .semibold).lineLimit(1)
                        Spacer(minLength: 8)
                        RecordingClock(live: live, size: 22)
                    }
                    if !detail.isEmpty { Text(detail).refinedFont(.meta).lineLimit(1).padding(.leading, 16) }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Circle().fill(ink).frame(width: 10, height: 10).opacity(paused ? 0.4 : 1).accessibilityHidden(true)
                    Text(title).refinedFont(.body, weight: .semibold).lineLimit(1).layoutPriority(1)
                    // Full ink, not the mockup's #3E4A43: that measures 3.4:1 on the fill.
                    Text(detail).refinedFont(.body).lineLimit(1)
                    Spacer(minLength: 8)
                    RecordingClock(live: live, size: CGFloat(RefinedRules.TextRole.clock.size(mac: RefinedPlatform.mac)))
                }
            }
            RecordingWave(live: live, color: ink, paused: paused, bar: compact ? 3 : 4).frame(height: compact ? 26 : 54)
            words
            HStack(spacing: compact ? 8 : 10) { controls }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, compact ? 14 : 24).padding(.vertical, compact ? 12 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.fill(.persimmon, palette), radius: RefinedPlatform.radius(compact ? .tile : .record))
        .accessibilityElement(children: .contain)
    }
}

/// The recording card's clock: minutes and seconds ("01:12") in SF Pro Ultralight with tabular digits. VoiceOver
/// reads it when you move to it, not on every tick.
private struct RecordingClock: View {
    @ObservedObject var live: LiveMeter
    var size: CGFloat
    var body: some View {
        Text(RefinedRules.minutesClock(live.elapsed))
            .font(.system(size: size, weight: .ultraLight))
            .monospacedDigit().tracking(-0.5).lineLimit(1)
            .accessibilityLabel("Elapsed")
            .accessibilityValue(RefinedRules.spokenTime(live.elapsed))
    }
}

/// The recording card's waveform: the recent levels as bars across the card, newest on the right. It moves only with
/// your voice (the meter), so Limit animation changes nothing; paused, it dims and holds.
private struct RecordingWave: View {
    @ObservedObject var live: LiveMeter
    var color: Color
    var paused: Bool
    var bar: CGFloat = 4
    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 3
            let slots = max(1, Int((size.width + gap) / (bar + gap)))
            let levels = live.levels
            for k in 0..<slots {
                // Spread the meter's recent levels across the width, oldest on the left.
                let i = levels.isEmpty ? 0 : min(levels.count - 1, k * levels.count / slots)
                let level = levels.isEmpty ? 0 : CGFloat(levels[i])
                let h = max(4, size.height * min(1, max(0.08, level * 1.4)))
                let rect = CGRect(x: CGFloat(k) * (bar + gap), y: (size.height - h) / 2, width: bar, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(color.opacity(paused ? 0.4 : 1)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Recording status, small

/// The live timer capsule (mockup MacRecorder's toolbar): the record dot in system red (an outline while paused), the
/// minutes and seconds in semibold tabular digits, and a round Stop with the ink stop square. The time is read once a
/// second, so the toolbar doesn't redraw with the meter. `onCard` draws the capsule's own card where there's no
/// glass group under it (the previews); in the toolbar, its glass is the capsule.
struct RecordingTimerCapsule: View {
    var live: LiveMeter
    var paused = false
    var onCard = false
    var stopLabel = "Stop"
    var stopHint = "Stops the recording and transcribes it."
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(paused ? Color.clear : Refined.recordRed)
                .overlay(Circle().strokeBorder(paused ? Refined.ink : Color.clear, lineWidth: 1.5))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(RefinedRules.minutesClock(live.elapsed))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Refined.ink)
                    .accessibilityLabel(paused ? "Paused" : "Recording")
                    .accessibilityValue(RefinedRules.spokenTime(live.elapsed))
            }
            Button(action: onStop) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Refined.ink).frame(width: 8, height: 8)
                    .frame(width: 22, height: 22)
                    .background(Refined.neutral, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(RefinedPress())
            .help("\(stopLabel) (⌥⇧.)")
            .accessibilityLabel(stopLabel)
            .accessibilityHint(stopHint)
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: 30)
        .background { if onCard { Capsule().fill(Refined.card) } }
        .overlay { if onCard { Capsule().strokeBorder(Refined.separator, lineWidth: 1) } }
        .fixedSize()
    }
}

#if os(iOS)
/// The minimized recorder (the iPhone): the persimmon dot (dimmed while paused), "Recording · 4:12" over
/// your newest words or the kind, then Pause or Resume and Stop (the red square). A tap on the text opens the recorder.
/// No background of its own: the tab bar's accessory draws the glass, or the bar's card before iOS 26.
/// VoiceOver reads one element ("Recording, 4 minutes 12 seconds") with Pause or Resume, Stop, and Open as actions.
struct MiniRecordingBar<Detail: View>: View {
    @ObservedObject var live: LiveMeter
    var paused: Bool
    var saving: Bool
    var inline = false
    var onOpen: () -> Void
    var onPause: () -> Void
    var onStop: () -> Void
    @ViewBuilder var detail: Detail
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Spelled out: the private environment value would keep the synthesized one to this file.
    init(live: LiveMeter, paused: Bool, saving: Bool, inline: Bool = false, onOpen: @escaping () -> Void,
         onPause: @escaping () -> Void, onStop: @escaping () -> Void, @ViewBuilder detail: () -> Detail) {
        self._live = ObservedObject(wrappedValue: live); self.paused = paused; self.saving = saving; self.inline = inline
        self.onOpen = onOpen; self.onPause = onPause; self.onStop = onStop; self.detail = detail()
    }

    private var status: String { saving ? "Saving\u{2026}" : paused ? "Paused" : "Recording" }
    /// "Recording, 4 minutes 12 seconds", as the bar always read.
    private var spoken: String { saving ? "Saving your recording" : "\(status), \(RefinedRules.spokenTime(live.elapsed))" }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Circle().fill(Refined.persimmon).frame(width: 10, height: 10).opacity(paused || saving ? 0.4 : 1)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(status) \u{00B7} \(RefinedRules.time(live.elapsed))")
                            .refinedFont(.body, weight: .semibold).monospacedDigit().lineLimit(1)
                            .foregroundStyle(Refined.ink)
                        if !inline, !typeSize.isAccessibilitySize { detail }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, inline ? 6 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onPause) {
                Group {
                    if paused { RecorderPlayGlyph().fill(Refined.ink).frame(width: 12, height: 14).offset(x: 1) }
                    else { RecorderPauseGlyph().fill(Refined.ink).frame(width: 12, height: 14) }
                }
                .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(RefinedPress())
            Button(action: onStop) {
                Group {
                    if saving { ProgressView().controlSize(.small) }
                    else { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Refined.recordRed).frame(width: 15, height: 15) }
                }
                .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(RefinedPress())
            .padding(.trailing, inline ? 2 : 6)
        }
        .disabled(saving)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens the recorder.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: Text(paused ? "Resume" : "Pause")) { onPause() }
        .accessibilityAction(named: "Stop") { onStop() }
        .accessibilityAction(named: "Open") { onOpen() }
    }
}

/// One of the recorder's round controls (mockup PhoneRecorder): a 56 pt circle on the neutral wash with its glyph, and
/// its name under it. Mark moment and Pause; Stop is `RecorderStopButton`.
struct RecorderControl<Glyph: View>: View {
    var label: String
    var action: () -> Void
    @ViewBuilder var glyph: Glyph

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                glyph
                    .frame(width: 56, height: 56)
                    .background(Refined.neutral, in: Circle())
                Text(label).refinedFont(.meta).foregroundStyle(Refined.ink)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.85)
            }
            .padding(.top, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(RefinedPress())
        .accessibilityLabel(label)
    }
}

/// The recorder's Stop: the system red stop square in a ring (76 pt), with "Stop" under it, or a spinner and
/// "Saving…" while the recording is saved. Red appears only here and on the record disc (DESIGN.md §13).
struct RecorderStopButton: View {
    var saving: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().strokeBorder(Refined.separator, lineWidth: 4)
                    if saving { ProgressView() }
                    else { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Refined.recordRed).frame(width: 30, height: 30) }
                }
                .frame(width: 76, height: 76)
                Text(saving ? "Saving\u{2026}" : "Stop").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RefinedPress())
        .accessibilityLabel(saving ? "Saving" : "Stop")
    }
}
#endif

/// Pause, drawn: two rounded bars (no SF Symbol in the recorder's controls).
struct RecorderPauseGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width * 0.34
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: w, height: r.height), cornerSize: CGSize(width: 1.5, height: 1.5))
        p.addRoundedRect(in: CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height), cornerSize: CGSize(width: 1.5, height: 1.5))
        return p
    }
}

/// Resume, drawn: a play triangle.
struct RecorderPlayGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Previews

#if DEBUG
struct ReadingText_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) { SpeakerChip(name: "Tim", index: 0); TurnTime(time: "0:00") }
                ReadingText("Okay, so the catalog needs to work for the folding wagon and the full wheel line.")
            }
            .readingTurn()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) { SpeakerChip(name: "Jonathan", index: 1); TurnTime(time: "0:06", playing: true) }
                ReadingText("Right. Jonathan wants the wheels first, then the wagons as a second section.")
            }
            .readingTurn(playing: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) { SpeakerChip(name: "Tim", index: 0); TurnTime(time: "0:11", marked: true) }
                ReadingText("Then we shoot the wheels on white, and the wagons out in the field by the shop in Ephrata.")
                MomentChip(time: "0:11", source: "Lock Screen")
            }
            .readingTurn(selected: true)
        }
        .padding(20).frame(width: 390).background(Refined.paper)
    }
}

struct TurnTime_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 12) { TurnTime(time: "0:06"); TurnTime(time: "0:11", playing: true); TurnTime(time: "0:19", marked: true) }
            .padding(20).background(Refined.paper)
    }
}

struct MomentChip_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 10) { MomentChip(time: "0:24", source: "Lock Screen"); MomentChip(time: "1:02") }
            .padding(20).background(Refined.paper)
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

struct AudioPlayerCard_Previews: PreviewProvider {
    static let levels: [Float] = (0..<90).map { Float(0.2 + 0.7 * abs(sin(Double($0) * 0.5))) }
    static var previews: some View {
        AudioPlayerCard(isPlaying: false, elapsed: 18, duration: 72, levels: levels, moments: [0.3, 0.7],
                        onPlayPause: {}, onSeek: { _ in }) { Button("1\u{00D7}") {} }
            .padding(20).frame(width: RefinedPlatform.mac ? 640 : 390).background(Refined.paper)
    }
}

struct RecordingCard_Previews: PreviewProvider {
    static var previews: some View {
        ForEach(AppPalette.allCases) { p in
            RecordingCard(title: "Recording a voice note", detail: "MacBook Pro microphone · Saved as you go", live: LiveMeter()) {
                Text("Chris mentioned the Lititz dealer wants a one-page sheet too.").readingStyle(Refined.onFill(.persimmon, p))
            } controls: {
                Button("Mark moment") {}.buttonStyle(RefinedActionStyle(ink: Refined.onFill(.persimmon, p), wash: Refined.readyChip(p)))
                Button("Pause") {}.buttonStyle(RefinedActionStyle(ink: Refined.onFill(.persimmon, p), wash: Refined.readyChip(p)))
                Spacer()
                Button("Stop and transcribe") {}.buttonStyle(RefinedActionStyle(kind: .strong, ink: Refined.onFill(.persimmon, p), light: p == .full ? Refined.lift : Refined.paper))
            }
            .padding(20).frame(width: 760).background(Refined.paper)
            .environment(\.paletteOverride, p)
            .previewDisplayName("Recording card, \(p.label)")
        }
    }
}

struct RecordingTimerCapsule_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            RecordingTimerCapsule(live: LiveMeter(), onCard: true, onStop: {})
            RecordingTimerCapsule(live: LiveMeter(), paused: true, onCard: true, onStop: {})
        }
        .padding(20).background(Refined.paper)
    }
}

struct RecordingCardCompact_Previews: PreviewProvider {
    static var previews: some View {
        RecordingCard(title: "Recording", detail: "MacBook Pro microphone", live: LiveMeter(), compact: true) {
            EmptyView()
        } controls: {
            Button("Pause") {}.buttonStyle(RefinedActionStyle(ink: Refined.onFill, wash: Refined.readyChip(.full)))
            Spacer()
            Button("Stop") {}.buttonStyle(RefinedActionStyle(kind: .strong, ink: Refined.onFill, light: Refined.lift))
        }
        .padding(20).frame(width: 320).background(Refined.paper)
    }
}

#if os(iOS)
struct MiniRecordingBar_Previews: PreviewProvider {
    static var previews: some View {
        MiniRecordingBar(live: LiveMeter(), paused: false, saving: false, onOpen: {}, onPause: {}, onStop: {}) {
            Text("Voice note").refinedFont(.meta).foregroundStyle(Refined.mute)
        }
        .frame(height: 56).refinedSurface(Refined.card, radius: 14)
        .padding(16).background(Refined.paper)
    }
}

struct RecorderControl_Previews: PreviewProvider {
    static var previews: some View {
        HStack(alignment: .top) {
            RecorderControl(label: "Mark moment", action: {}) { IconGlyph(art: .iconMark, size: 22, color: Refined.ink) }
            RecorderStopButton(saving: false, action: {})
            RecorderControl(label: "Pause", action: {}) { RecorderPauseGlyph().fill(Refined.ink).frame(width: 14, height: 18) }
        }
        .padding(20).frame(width: 390).background(Refined.paper)
    }
}
#endif

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
