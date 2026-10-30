import SwiftUI

// Capture and archive: kinds, tags, hidden filler lines, and background voices, shared by the Mac and iPhone apps.
// Kinds take their colors from the refined kit (`RefinedRules.kindHue`, DESIGN.md §13), always with their glyph and
// name.

extension RecordingKind {
    var art: BrandArt {
        switch self {
        case .journal: return .kindJournal
        case .idea: return .kindThought
        case .meeting: return .kindMeeting
        case .note: return .kindNote
        case .dictation: return .kindDictation
        case .podcast: return .kindPodcast
        case .video: return .kindVideo
        case .talk: return .kindTalk
        case .interview: return .kindInterview
        case .brainDump: return .kindBrainDump
        case .audio: return .kindAudio
        }
    }
}

extension Transcript {
    /// Settings › Main speaker only: other voices fold into Background voices. Off by default.
    static let mainSpeakerOnlyKey = "transcript.mainSpeakerOnly"
    static var mainSpeakerOnly: Bool { UserDefaults.standard.bool(forKey: mainSpeakerOnlyKey) }

    /// The reading lines: filler-only lines left out when `hideFiller`, and background voices left out when
    /// `mainOnly` (they show in their own card). Nothing is deleted; ids are unchanged.
    func displaySegments(hideFiller: Bool, mainOnly: Bool) -> [Segment] {
        var s = visibleSegments(hideFiller: hideFiller)
        if mainOnly {
            let bg = Set(backgroundSegments.map(\.id))
            if !bg.isEmpty { s = s.filter { !bg.contains($0.id) } }
        }
        return s
    }

    /// Lines the filler rule hides (`hidesAsFiller`), counted for "2 filler lines hidden".
    var fillerCount: Int { segments.count - visibleSegments(hideFiller: true).count }
}

// MARK: - Layout

/// Lays children out left to right, wrapping to a new line when the width runs out.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = Self.size(v, maxW)
            if x > 0, x + s.width > maxW { y += line + lineSpacing; x = 0; line = 0 }
            x += s.width + spacing; line = max(line, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    /// A child's natural size, but never wider than the row (a long tag truncates instead of overflowing).
    private static func size(_ v: LayoutSubview, _ maxW: CGFloat) -> CGSize {
        let s = v.sizeThatFits(.unspecified)
        guard maxW.isFinite, s.width > maxW else { return s }
        return v.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = Self.size(v, bounds.width)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y + (line > 0 ? 0 : 0)), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = max(line, s.height)
        }
    }
}

// MARK: - Filler and AI notes

/// "2 filler lines hidden · Show" under the reading lines; "Hide filler lines" once shown.
struct FillerToggle: View {
    var count: Int
    @Binding var shown: Bool
    var body: some View {
        Button { shown.toggle() } label: {
            Text(shown ? "Hide filler lines" : (count == 1 ? "1 filler line hidden · Show" : "\(count) filler lines hidden · Show"))
                .refinedFont(.hint).foregroundStyle(Refined.mute)
                .frame(minHeight: RefinedPlatform.mac ? 28 : CGFloat(RefinedRules.minTapTarget)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The Cleaned tab's persistent label: "Cleaned by Apple Intelligence" or "Cleaned with rules". Plain text on the
/// page, never on a blur, in the refined kit's meta style on both platforms.
struct CleanedLabel: View {
    var source: CleanupSource
    var body: some View {
        Label { Text(source.label) } icon: { ArtIcon(art: source == .model ? .iconAI : .iconApplyDictionary, size: 14) }
            .refinedFont(.meta, weight: .medium).foregroundStyle(Refined.dim)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cleaned-label")
    }
}

// MARK: - Background voices

/// Lines from voices other than the main speaker (Settings › Main speaker only), folded into one card.
struct BackgroundVoicesCard: View {
    var segments: [Segment]
    var compact = false
    var onPlay: (Segment) -> Void
    var onMoveBack: (Segment) -> Void
    @State private var open = false
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(limitMotion ? nil : Motion.settle) { open.toggle() } } label: {
                HStack(spacing: 12) {
                    BrandGlyph(art: .featureBackground, color: Refined.ink, minLineWidth: 1)
                        .frame(width: compact ? 18 : 28, height: compact ? 18 : 28)
                        .frame(width: compact ? 28 : 46, height: compact ? 28 : 46)
                        .background(Refined.neutralSquare, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.square), style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background voices").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        Text(segments.count == 1 ? "1 short line from people nearby" : "\(segments.count) short lines from people nearby")
                            .refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.mute)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 14).padding(.vertical, compact ? 9 : 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the lines" : "Shows the lines")
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(segments) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(RefinedRules.time(s.start)).refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute).frame(width: 44, alignment: .leading)
                                .onTapGesture { onPlay(s) }
                            Text(s.text).refinedFont(.body).foregroundStyle(Refined.dim).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        .contextMenu { Button { onMoveBack(s) } label: { Label("This was me: move it back", systemImage: "arrow.uturn.backward") } }
                    }
                    Text(moveHint).refinedFont(.meta).foregroundStyle(Refined.mute).padding(.leading, 60)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    private var moveHint: String {
        #if os(macOS)
        return "Right-click a line to move it back."
        #else
        return "Touch and hold a line to move it back."
        #endif
    }
}

// MARK: - Library

/// Journal entries grouped by day, newest first: "Today · Sat Oct 17" headings, in the same date order as every other
/// day header (review M-15).
enum JournalDays {
    struct Day: Identifiable { var id: Date; var label: String; var date: String; var entries: [Transcript] }

    /// The Library's, Dictations', and By day's date order.
    static let dateFormat = "EEE MMM d"

    static func group(_ items: [Transcript], now: Date = Date()) -> [Day] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: items) { cal.startOfDay(for: $0.createdAt) }
        let fmt = Formats.pattern(JournalDays.dateFormat)
        let weekday = Formats.pattern("EEEE")
        return byDay.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day) { label = "Today" }
            else if cal.isDateInYesterday(day) { label = "Yesterday" }
            else if let d = cal.dateComponents([.day], from: day, to: cal.startOfDay(for: now)).day, d < 7 { label = weekday.string(from: day) }
            else { label = fmt.string(from: day) }
            return Day(id: day, label: label, date: fmt.string(from: day),
                       entries: (byDay[day] ?? []).sorted { $0.createdAt > $1.createdAt })
        }
    }

    /// The first two lines' worth of what was said, filler left out.
    static func preview(_ t: Transcript) -> String {
        let text = t.visibleSegments(hideFiller: true).prefix(6).map(\.text).joined(separator: " ")
        return String(text.prefix(220))
    }
}
