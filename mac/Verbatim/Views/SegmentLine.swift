import SwiftUI
import AppKit

/// One turn of a transcript in the refined look (DESIGN.md §13): the speaker's chip when the
/// speaker changes (click it to move the line to someone else or rename them) and the time (click to play from
/// there), with a small accent mark on a bookmarked or marked line, over the serif reading text. The line being played
/// takes the sage `playing` wash, a selected line (a note links to it) the neutral wash with an accent bar, and a
/// hovered line the stripe. Click the text to select it and play from it; right-click to correct a word, add a note,
/// open the video at that moment, copy a quote, or mark a sponsor read. A moment marked while recording shows its chip
/// under the text.
struct SegmentLine: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var segment: Segment
    var showSpeaker: Bool
    /// The speaker's place in the chip rotation (`Transcript.speakerOrder`).
    var speakerIndex: Int = 0
    var current: Bool
    /// Bookmarked, or marked while recording: the accent mark beside the time.
    var marked: Bool = false
    /// A moment marked on this line while recording (Model/Marks.swift): its chip under the text.
    var mark: Note? = nil
    var selected: Bool
    var editable: Bool
    var size: CGFloat
    /// The first line in the column: no extra space above its speaker.
    var first = false
    var select: () -> Void
    @State private var hover = false
    @State private var fixing: String? = nil
    @State private var replacement = ""
    @State private var remember = true
    @State private var renaming = false
    @State private var newName = ""

    /// “Quote” — Speaker, Title (12:34) and, when it came from a link, the video at that second.
    private func copyQuote(withLink: Bool) {
        var s = "“\(segment.text)”"
        if let sp = transcript.speakerName(segment.speaker), transcript.speakers.count >= 2 { s += " — \(sp)" }
        s += "\n\(transcript.title) (\(segment.start.timecode))"
        if withLink, let u = transcript.linkInfo?.url(at: segment.start) { s += "\n\(u.absoluteString)" }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        app.toast = Toast(withLink ? "Quote and link copied" : "Quote copied")
    }

    /// The line's text, with search matches in butter and low-confidence words underlined; while it plays with fresh
    /// word timings, the playing word takes the playing wash too.
    @ViewBuilder private var lineText: some View {
        let base = UnclearStyle.marked(ReadingHighlight.marked(AttributedString(segment.text), query: app.search), segment)
        if current, PlaybackSync.timingsFresh(segment) {
            PlayingWordText(segment: segment, base: base, clock: app.player.clock, tint: Refined.playing)
        } else {
            Text(base)
        }
    }

    private func play() {
        app.player.seek(to: PlaybackSync.seekTime(segment, duration: app.player.duration))
    }

    var body: some View {
        let name = showSpeaker ? segment.speaker.flatMap { sp in transcript.speakerName(sp).map { (sp, $0) } } : nil
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let n = name { speakerMenu(n.0, name: n.1) }
                TurnTime(time: RefinedRules.time(segment.start), playing: current, marked: marked)
                    .contentShape(Rectangle())
                    .tapArea { play() }
                    .help("Play from here")
                    .accessibilityLabel("Play from \(RefinedRules.spokenTime(segment.start))\(marked ? ", marked" : "")")
                    .accessibilityAddTraits(.isButton)
            }
            lineText
                .readingStyle(size: size)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // A click selects the line (for a passage note) and, once the audio is open, plays from it.
                .onTapGesture {
                    select()
                    if app.player.canPlay { app.player.play(from: PlaybackSync.seekTime(segment, duration: app.player.duration)) }
                }
                .accessibilityLabel([name.map { "\($0.1)," }, RefinedRules.spokenTime(segment.start) + ",", segment.text].compactMap { $0 }.joined(separator: " "))
                .accessibilityValue([current ? "Playing" : nil, marked ? "Marked" : nil, selected ? "Selected" : nil].compactMap { $0 }.joined(separator: ", "))
                .contextMenu {
                    CorrectionItems(text: segment.text, editable: editable) { w in fixing = w; replacement = w }
                    Divider()
                    Button("Note on This Passage") { select(); NotificationCenter.default.post(name: .verbatimFocusNote, object: nil) }
                    Button("Play from Here") { app.player.play(from: PlaybackSync.seekTime(segment, duration: app.player.duration)) }
                    Button("Bookmark") { app.addNote(transcript: transcript.id, text: String(segment.text.prefix(60)), at: segment.start, segment: segment.id, bookmark: true) }
                    if let info = transcript.linkInfo {
                        Button(info.supportsTimestamps ? "Open Video at \(RefinedRules.time(segment.start))" : "Open Video") {
                            if let u = info.url(at: segment.start) { NSWorkspace.shared.open(u) }
                        }
                    }
                    Divider()
                    Button("Copy Quote") { copyQuote(withLink: false) }
                    if transcript.linkInfo != nil { Button("Copy Quote with Link") { copyQuote(withLink: true) } }
                    if transcript.offersSponsorMarking, transcript.sponsorSpan(for: segment) == nil {
                        Divider()
                        Button("Mark as Sponsor") { app.store.update(transcript.id) { $0.markSponsor(segment: segment.id) } }
                    }
                }
                .popover(isPresented: Binding(get: { fixing != nil }, set: { if !$0 { fixing = nil } })) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Heard as").refinedFont(.caption).foregroundStyle(Refined.mute)
                            Text(fixing ?? "").refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink)
                        }
                        TextField("Correct spelling", text: $replacement).textFieldStyle(.roundedBorder).onSubmit { commit() }
                        Toggle("Remember in Dictionary", isOn: $remember).refinedFont(.meta)
                        HStack {
                            Spacer()
                            Button("Cancel") { fixing = nil }.buttonStyle(RefinedActionStyle())
                            Button("Fix") { commit() }.buttonStyle(RefinedActionStyle(kind: .strong)).keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(14).frame(width: 300)
                }
            if let mark {
                MomentChip(time: Marks.clock(mark.at ?? segment.start), source: Marks.shortSource(mark))
                    .contentShape(Capsule())
                    .tapArea { app.player.play(from: mark.at ?? segment.start) }
                    .help("Play from this moment")
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Marks.chip(mark) ?? "Moment")
                    .accessibilityHint("Plays from this moment.")
                    .accessibilityAction { app.player.play(from: mark.at ?? segment.start) }
                    .padding(.top, 3)
            }
        }
        .readingTurn(playing: current, selected: selected, hovered: hover)
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
        // About 16 pt more between speakers; lines from the same speaker sit closer.
        .padding(.top, showSpeaker && !first ? 10 : 0)
    }

    /// The speaker's chip: a menu that moves the line to someone else, renames them, or takes the speaker off.
    private func speakerMenu(_ sp: String, name: String) -> some View {
        Menu {
            ForEach(transcript.speakers) { s in Button(s.label) { app.assign(transcript: transcript.id, segment: segment.id, to: s.id) } }
            Divider()
            Button("Rename \(name)…") { renaming = true; newName = name }
            Button("No speaker") { app.assign(transcript: transcript.id, segment: segment.id, to: nil) }
        } label: {
            SpeakerChip(name: name, index: speakerIndex).contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Change or rename the speaker")
        .accessibilityLabel("Speaker \(name)")
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name this speaker").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.ink)
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { app.renameSpeaker(transcript: transcript.id, speaker: sp, to: newName); renaming = false }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = false }.buttonStyle(RefinedActionStyle())
                    Button("Save") { app.renameSpeaker(transcript: transcript.id, speaker: sp, to: newName); renaming = false }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                }
            }
            .padding(14)
        }
    }

    private func commit() {
        guard let from = fixing else { return }
        let to = replacement.trimmingCharacters(in: .whitespaces)
        if !to.isEmpty, to != from { app.correct(transcript: transcript.id, segment: segment.id, from: from, to: to, remember: remember) }
        fixing = nil
    }
}

/// A folded sponsor read in the Mac transcript, with the app at hand for its menu (the lines themselves don't watch
/// the app state).
private struct SponsorFoldLine: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var span: SponsorSpan
    var open: Bool
    var toggle: () -> Void

    var body: some View {
        SponsorFoldRow(span: span, open: open, onToggle: toggle,
                       onPlay: app.player.canPlay ? { app.player.play(from: span.start) } : nil,
                       onNotSponsor: { app.store.update(transcript.id) { $0.dismissSponsor(span.id) } })
            .frame(maxWidth: 520, alignment: .leading)
            .help("A sponsor read. Click to show it; copy, export, and summaries leave it out.")
    }
}

/// A line's "Correct …" menu items: its longer words, longest first. A view of its own so the words are
/// worked out when the menu is built, not every time the line renders.
private struct CorrectionItems: View {
    var text: String
    var editable: Bool
    var pick: (String) -> Void

    var body: some View {
        ForEach(Self.candidates(text, editable: editable), id: \.self) { w in Button("Correct “\(w)”…") { pick(w) } }
    }

    static func candidates(_ text: String, editable: Bool) -> [String] {
        guard editable else { return [] }
        let words = text.split { $0 == " " }.map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { $0.count > 2 }
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }.sorted { $0.count > $1.count }.prefix(8).map { $0 }
    }
}

/// The reading lines. Reads the playhead without observing it: the lines re-render only when the playing
/// passage changes (`playingIDs`), not on every 20 Hz tick, so the rest of the screen stays still too.
struct TranscriptLines: View {
    @EnvironmentObject var app: AppState
    var clock: PlayerClock
    var isPlaying: Bool
    var transcript: Transcript
    var segments: [Segment]
    /// Where sponsor reads fold, one entry per line in `segments` (`Store.sponsorFolds`, worked out once per change).
    var folds: [SponsorFold.Place?]
    var editable: Bool
    var textSize: CGFloat
    @Binding var selected: UUID?
    /// The passages under the playhead as of the last tick. Only a change here re-renders the lines; the tint
    /// itself is worked out from the clock in `body`.
    @State private var playingIDs: Set<UUID> = []
    /// Sponsor reads opened from their folded row.
    @State private var openSponsors: Set<UUID> = []

    /// The playing rule: under the playhead, and either playing or moved off the start.
    static func playing(_ segments: [Segment], at now: Double, isPlaying: Bool) -> Set<UUID> {
        guard isPlaying || now > 0 else { return [] }
        var out = Set<UUID>()
        for s in segments where now >= s.start && now < s.end { out.insert(s.id) }
        return out
    }

    var body: some View {
        let _ = playingIDs
        let current = Self.playing(segments, at: clock.time, isPlaying: isPlaying)
        let saved = Set(transcript.notes.filter(\.isBookmark).compactMap(\.segmentId))
        let order = transcript.speakerOrder
        // Moments marked while recording, by line, for their chips (the first on a line).
        let marked = Dictionary(transcript.notes.filter(\.isMark).compactMap { n in n.segmentId.map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
        // Lazy: a long recording has hundreds of lines, each with menus and a popover. Build only what's on screen.
        // Sponsor reads fold into one row at their first line; their lines show once the row is opened.
        let folds = self.folds.count == segments.count ? self.folds : SponsorFold.places(segments, in: transcript)
        // "unclear 2:10" chips where speech was heard but no words came through (UnclearRules), between the lines.
        let chips = UnclearStyle.chips(transcript, lines: segments)
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                // After a folded read, name the speaker again: the line above on screen is someone else's.
                let afterFold = i > 0 && folds[i - 1].map { !openSponsors.contains($0.span.id) } == true
                let showSpeaker = transcript.speakers.count >= 2 && s.speaker != nil && (i == 0 || afterFold || segments[i - 1].speaker != s.speaker)
                let fold = folds[i]
                if let spans = chips[i] { unclearChips(spans) }
                if let fold, fold.first {
                    SponsorFoldLine(transcript: transcript, span: fold.span, open: openSponsors.contains(fold.span.id)) {
                        if openSponsors.remove(fold.span.id) == nil { openSponsors.insert(fold.span.id) }
                    }
                    .padding(.top, i == 0 ? 0 : 8).padding(.bottom, 6)
                }
                SegmentLine(transcript: transcript, segment: s, showSpeaker: showSpeaker, speakerIndex: s.speaker.flatMap { order[$0] } ?? 0,
                            current: current.contains(s.id), marked: saved.contains(s.id) || marked[s.id] != nil, mark: marked[s.id],
                            selected: selected == s.id, editable: editable, size: textSize, first: i == 0) {
                    selected = selected == s.id ? nil : s.id
                }
                .id(s.id)
                .foldedAway(fold.map { !openSponsors.contains($0.span.id) } ?? false)
            }
            if let spans = chips[segments.count] { unclearChips(spans) }
        }
        .onReceive(clock.$time) { now in syncPlaying(at: now) }
        .onChange(of: isPlaying) { _, _ in syncPlaying(at: clock.time) }
        // The lines' ids and times, not the whole lines (words included): only those decide what's playing.
        .onChange(of: segments.timingKey) { _, _ in syncPlaying(at: clock.time) }
    }

    /// The chips before a line.
    private func unclearChips(_ spans: [UnclearSpan]) -> some View {
        ForEach(spans, id: \.start) { sp in
            UnclearChip(span: sp, onPlay: { app.player.play(from: sp.start) })
                .padding(.vertical, 6)
        }
    }

    @MainActor private func syncPlaying(at now: Double) {
        let ids = Self.playing(segments, at: now, isPlaying: isPlaying)
        if ids != playingIDs { playingIDs = ids }
    }
}

/// Speaker pills' fixed rotation (DESIGN.md §1): record, petal, sage, butter, by the order speakers first talk. The
/// multitrack sheet colors its tracks in the same order, so a speaker keeps one color from the sheet to the transcript.
enum SpeakerRotation {
    static let fills: [Color] = [Refined.persimmon, Refined.petal, Refined.sage, Refined.butter]

    /// The speaker's place in the order of first appearance in `segments`, or nil when they never talk. Stops at
    /// their first line, so speakers who talk early are found at once.
    static func firstAppearance(_ id: String, in segments: [Segment]) -> Int? {
        var seen: [String] = []
        for s in segments {
            guard let sp = s.speaker else { continue }
            if sp == id { return seen.count }
            if !seen.contains(sp) { seen.append(sp) }
        }
        return nil
    }
}
