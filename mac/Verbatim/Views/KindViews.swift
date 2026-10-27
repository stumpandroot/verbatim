import SwiftUI

// Capture and archive: kinds, tags, hidden filler lines, and background voices, shared by the Mac and iPhone apps.
// Design rules (claude/verbatim-capture-archive-design.md): every piece takes a form the app already has (chips,
// row cards, meta lines, dotted-leader headings); kinds are neutral, so action hues keep one meaning each.

extension RecordingKind {
    /// Kinds are neutral (DESIGN.md §1): ink at 6% behind `dim` text and the kind's own diagram, so a category
    /// never borrows an action hue (persimmon Record, butter Dictate, sage Import, petal App audio).
    var fill: Color { Ink.neutralChip }
    /// Text and diagram color on `fill`.
    var onFill: Color { Ink.ink }
    /// The tint for row icon tiles.
    var tint: Color { Ink.neutralChip }
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
        }
    }
    var plural: String {
        switch self {
        case .journal: return "Journal"
        case .idea: return "Thoughts"
        case .meeting: return "Meetings"
        case .note: return "Notes"
        case .dictation: return "Dictations"
        case .podcast: return "Podcasts"
        case .video: return "Videos"
        case .talk: return "Talks"
        case .interview: return "Interviews"
        }
    }
    var index: String {
        switch self {
        case .journal: return "01"
        case .idea: return "02"
        case .meeting: return "03"
        case .note: return "04"
        case .dictation: return "05"
        case .podcast: return "06"
        case .video: return "07"
        case .talk: return "08"
        case .interview: return "09"
        }
    }
    /// The hero card's one line.
    var line: String {
        switch self {
        case .journal: return "Your days, in order."
        case .idea: return "Thinking out loud."
        case .meeting: return "Calls and conversations."
        case .note: return "Everything else."
        case .dictation: return "Words you sent elsewhere."
        case .podcast: return "Shows and conversations you listened to."
        case .video: return "Things you watched."
        case .talk: return "One voice, at length."
        case .interview: return "Questions and answers."
        }
    }
}

// brand: native begin
extension RecordingKind {
    /// The kind's SF Symbol in the Native look, in place of its diagram. Thoughts draw their own icon instead
    /// (`BrandArt.iconThought`) where there's room for a view; this is the stand-in where only a symbol fits.
    var nativeSymbol: String {
        switch self {
        case .journal: return "book"
        case .idea: return "lightbulb"
        case .meeting: return "person.2"
        case .note: return "doc.text"
        case .dictation: return "text.bubble"
        case .podcast: return "mic"
        case .video: return "play.rectangle"
        case .talk: return "person.wave.2"
        case .interview: return "quote.bubble"
        }
    }
}
// brand: native end

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

// MARK: - Kind chip

/// The transcript's kind: a chip filled with the kind's color and carrying its diagram. Opens a menu of the kinds a
/// person can pick (`RecordingKind.pickable`); a pick is never overwritten.
struct KindChip: View {
    var kind: RecordingKind?
    var isAuto: Bool
    var compact = false
    var onPick: (RecordingKind) -> Void
    @Environment(\.look) private var look

    var body: some View {
        Menu {
            Section(isAuto ? "Suggested by Verbose. Pick another and it stays." : "You picked this. Verbose won't change it.") {
                ForEach(RecordingKind.pickable) { k in
                    Button { onPick(k) } label: {
                        if k == kind { Label(k.label, systemImage: "checkmark") } else { Text(k.label) }
                    }
                }
            }
        } label: {
            label
        }
        #if os(macOS)
        // .borderlessButton draws the label as plain text; .button with a plain style keeps the filled chip.
        .menuStyle(.button)
        .buttonStyle(.plain)
        #endif
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(kind.map { "Kind: \($0.label). Change" } ?? "Choose a kind")
    }

    @ViewBuilder private var label: some View {
        let h: CGFloat = compact ? 28 : 36
        if look == .native {
            nativeLabel(h)
        } else if let kind {
            HStack(spacing: 6) {
                BrandGlyph(art: kind.art, color: kind.onFill, minLineWidth: 1).frame(width: h - 8, height: h - 8)
                Text(kind.label).font(.system(size: compact ? 13 : 15, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: compact ? 9 : 10, weight: .bold))
            }
            .foregroundStyle(kind.onFill)
            .padding(.leading, 5).padding(.trailing, compact ? 11 : 12)
            .frame(minHeight: h)
            .background(kind.fill, in: Capsule())
            .contentShape(Capsule())
        } else {
            // "Kind ▾", the same menu control as a set kind ("Meeting ▾"), so it never reads as a second add button.
            HStack(spacing: 5) {
                Text("Kind").font(.system(size: compact ? 13 : 15))
                Image(systemName: "chevron.down").font(.system(size: compact ? 9 : 10, weight: .bold))
            }
            .foregroundStyle(Ink.dim)
            .padding(.horizontal, 12).frame(minHeight: h)
            .overlay(Capsule().strokeBorder(Ink.hairline))
            .contentShape(Capsule())
        }
    }

    // brand: native begin
    /// The Native capsule's tint: the system accent color on the Mac (DESIGN.md §13.2); the Native accent on iPhone.
    private static var nativeTint: Color {
        #if os(macOS)
        return Color.accentColor
        #else
        return Ink.nativeAccent
        #endif
    }

    /// Native: a tinted menu capsule with the kind's symbol, or a gray "Kind" capsule when there's none.
    @ViewBuilder private func nativeLabel(_ h: CGFloat) -> some View {
        if let kind {
            HStack(spacing: 6) {
                if kind == .idea {
                    // Thoughts have no SF Symbol: the Thoughts icon, in the same tint.
                    ArtIcon(art: .iconThought, size: compact ? 14 : 16, lineWidth: 1.5)
                } else {
                    Image(systemName: kind.nativeSymbol).font(.system(size: compact ? 12 : 14, weight: .semibold))
                }
                Text(kind.label).font(.system(size: compact ? 13 : 15, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: compact ? 9 : 10, weight: .bold))
            }
            .foregroundStyle(Self.nativeTint)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(minHeight: h)
            .background(Self.nativeTint.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        } else {
            HStack(spacing: 5) {
                Text("Kind").font(.system(size: compact ? 13 : 15))
                Image(systemName: "chevron.down").font(.system(size: compact ? 9 : 10, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(minHeight: h)
            .background(.fill.tertiary, in: Capsule())
            .contentShape(Capsule())
        }
    }
    // brand: native end
}

// MARK: - Tags

/// Tag chips with an add control. Long-press (iPhone) or right-click (Mac) a tag to remove it.
struct TagChips: View {
    var tags: [String]
    var compact = false
    var onAdd: (String) -> Void
    var onRemove: (String) -> Void
    @State private var adding = false
    @State private var draft = ""

    // No container of its own: each chip and the + button are separate children, so `FlowRow` (KindAndTags) wraps
    // them onto as many lines as they need instead of running off the edge.
    @Environment(\.look) private var look

    var body: some View {
        let h: CGFloat = compact ? 28 : 36
        ForEach(tags, id: \.self) { tag in
            Text(tag).font(.system(size: compact ? 13 : 15)).foregroundStyle((look == .native) ? Color.primary : Ink.ink)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, compact ? 10 : 13).frame(minHeight: h)
                .modifier(TagSurface(native: look == .native))
                .contextMenu { Button(role: .destructive) { onRemove(tag) } label: { Label("Remove tag", systemImage: "xmark") } }
                .accessibilityLabel("Tag: \(tag)")
        }
        // "+ Tag" while there are no tags; after the last tag a bare "+" reads as adding another.
        Button { draft = ""; adding = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: compact ? 11 : 13, weight: .semibold))
                if tags.isEmpty { Text("Tag").font(.system(size: compact ? 13 : 15)) }
            }
            .foregroundStyle((look == .native) ? Color.secondary : Ink.dim)
            .padding(.horizontal, tags.isEmpty ? (compact ? 10 : 12) : 0)
            .frame(minWidth: h, minHeight: h)
            .modifier(TagSurface(native: look == .native, filled: false))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a tag")
        .alert("Add a tag", isPresented: $adding) {
            TextField("Tag", text: $draft)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !t.isEmpty { onAdd(t) }
            }
        }
    }
}

/// A tag's capsule: card white with a hairline (the + button: the hairline alone) in Verbose style; a gray system
/// fill with no edge in Native.
private struct TagSurface: ViewModifier {
    var native: Bool
    var filled = true
    func body(content: Content) -> some View {
        if native {
            content.background(.fill.tertiary, in: Capsule())   // brand: native
        } else {
            content
                .background(filled ? Ink.card : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(Ink.hairline))
        }
    }
}

/// Kind chip and tags on one wrapping line, under the transcript's meta line.
struct KindAndTags: View {
    var transcript: Transcript
    var compact = false
    var onPick: (RecordingKind) -> Void
    var onTags: ([String]) -> Void

    var body: some View {
        FlowRow(spacing: 8, lineSpacing: 8) {
            if transcript.kind != .dictation {
                KindChip(kind: transcript.kind, isAuto: transcript.kindIsAuto, compact: compact, onPick: onPick)
            }
            TagChips(tags: transcript.tags, compact: compact,
                     onAdd: { t in if !transcript.tags.contains(t) { onTags(transcript.tags + [t]) } },
                     onRemove: { t in onTags(transcript.tags.filter { $0 != t }) })
        }
    }
}

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
                .font(.system(size: 13.5)).foregroundStyle(Ink.mute)
                .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Under a title Apple Intelligence wrote (AI-label rule): small, mute, gone once the person renames it.
struct AITitleNote: View {
    var body: some View {
        Label { Text("Title by Apple Intelligence") } icon: { ArtIcon(art: .iconAI, size: 14) }
            .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            .accessibilityElement(children: .combine)
    }
}

/// The Cleaned tab's persistent label: "Cleaned by Apple Intelligence" or "Cleaned with rules". Plain text on the
/// page, never on a blur.
struct CleanedLabel: View {
    var source: CleanupSource
    /// Mono, as the Mac's Cleaned tab shows it (DESIGN.md §11); the iPhone keeps the sans.
    var mono = false
    var body: some View {
        Label { Text(source.label) } icon: { ArtIcon(art: source == .model ? .iconAI : .iconApplyDictionary, size: 14) }
            .font(mono ? Ink.mono(12) : .system(size: 12.5, weight: .medium)).foregroundStyle(Ink.dim)
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
                    BrandGlyph(art: .featureBackground, color: Ink.ink, minLineWidth: 1)
                        .frame(width: compact ? 18 : 28, height: compact ? 18 : 28)
                        .frame(width: compact ? 28 : 46, height: compact ? 28 : 46)
                        .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: compact ? 7 : Radius.row, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background voices").font(.system(size: compact ? 14 : 17, weight: .semibold)).foregroundStyle(Ink.ink)
                        Text(segments.count == 1 ? "1 short line from people nearby" : "\(segments.count) short lines from people nearby")
                            .font(.system(size: compact ? 12.5 : 14)).foregroundStyle(Ink.mute)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
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
                            Text(s.start.timecode).font(Ink.mono(compact ? 11.5 : 13)).foregroundStyle(Ink.mute).frame(width: 44, alignment: .leading)
                                .onTapGesture { onPlay(s) }
                            Text(s.text).font(.system(size: compact ? 14 : 16)).foregroundStyle(Ink.mute).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        .contextMenu { Button { onMoveBack(s) } label: { Label("This was me: move it back", systemImage: "arrow.uturn.backward") } }
                    }
                    Text(moveHint).font(.system(size: 12.5)).foregroundStyle(Ink.mute).padding(.leading, 60)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .background(Ink.card, in: RoundedRectangle(cornerRadius: compact ? Radius.row : Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? Radius.row : Radius.tile, style: .continuous).strokeBorder(Ink.hairline))
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

/// The bold block at the top of a kind's Library view, in the Home method-card form.
struct KindHeroCard: View {
    var kind: RecordingKind
    var meta: String
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.index).font(Ink.mono(11)).foregroundStyle(Ink.mute)
                    Rectangle().fill(kind.onFill.opacity(0.5)).frame(width: 14, height: 1)
                }
                Spacer(minLength: 12)
                Text(kind.plural).font(Ink.serif(compact ? 32 : 36)).lineLimit(1).minimumScaleFactor(0.8)
                Text(kind.line).font(.system(size: compact ? 14 : 15)).foregroundStyle(Ink.dim).padding(.top, 4)
                Text(meta).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Ink.mute).padding(.top, 8)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                CornerTick().stroke(kind.onFill, lineWidth: 1.4).frame(width: 12, height: 12)
                Spacer(minLength: 6)
                BrandGlyph(art: kind.art, color: kind.onFill, minLineWidth: 1).frame(width: compact ? 92 : 104, height: compact ? 92 : 104)
            }
        }
        .foregroundStyle(kind.onFill)
        .padding(compact ? 16 : 18)
        .frame(maxWidth: .infinity, minHeight: compact ? 150 : 168, alignment: .topLeading)
        // A paper card with the kind's diagram in ink: no colored fill on a working screen.
        .cardSurface(radius: Radius.tile)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.plural). \(kind.line) \(meta)")
    }
}

/// Journal entries grouped by day, newest first: "Today · Sat Oct 17" headings, in the same date order as every other
/// day header (`DayHeader`; review M-15).
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
