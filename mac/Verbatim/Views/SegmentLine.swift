import SwiftUI
import AppKit

// brand: web style

/// One line: timecode, speaker only when it changes, text. Click to select (for a passage-linked note),
/// right-click to correct a word. The current line during playback carries the iris tint.
struct SegmentLine: View {
    @Environment(\.look) private var look
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var segment: Segment
    var showSpeaker: Bool
    var current: Bool
    var saved: Bool = false
    /// A moment marked on this line while recording (Model/Marks.swift): its chip under the text.
    var mark: Note? = nil
    var selected: Bool
    var editable: Bool
    var size: CGFloat
    /// The first line in the sheet: no extra space above its speaker.
    var first = false
    var select: () -> Void
    @State private var hover = false
    @State private var tsHover = false
    @State private var fixing: String? = nil
    @State private var replacement = ""
    @State private var remember = true
    @State private var renaming = false
    @State private var newName = ""

    /// The search term, highlighted where it appears in this line.
    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let q = app.search.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return a }
        var searchStart = a.startIndex
        while searchStart < a.endIndex, let r = a[searchStart...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Ink.match
            searchStart = r.upperBound
        }
        return a
    }

    /// “Quote” — Speaker, Title (12:34) and, when it came from a link, the video at that second.
    private func copyQuote(withLink: Bool) {
        var s = "“\(segment.text)”"
        if let sp = transcript.speakerName(segment.speaker), transcript.speakers.count >= 2 { s += " — \(sp)" }
        s += "\n\(transcript.title) (\(segment.start.timecode))"
        if withLink, let u = transcript.linkInfo?.url(at: segment.start) { s += "\n\(u.absoluteString)" }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        app.toast = Toast(withLink ? "Quote and link copied" : "Quote copied")
    }

    /// The line's text; while it plays with fresh word timings, the playing word is tinted too.
    @ViewBuilder private var lineText: some View {
        // Low-confidence words carry a quiet dotted underline (UnclearStyle), as a best guess.
        if current, PlaybackSync.timingsFresh(segment) {
            PlayingWordText(segment: segment, base: UnclearStyle.marked(highlighted(segment.text), segment), clock: app.player.clock,
                            tint: look == .native ? NativeInk.accentSoft : Ink.iris.opacity(0.22))
        } else {
            Text(UnclearStyle.marked(highlighted(segment.text), segment))
        }
    }

    private var highlight: Color {
        if look == .native {
            // brand: native begin
            // Native (mockup section 9): the line being played gets a light neutral fill, and marks lose the butter
            // wash (the chip under the line says it's marked).
            if current { return Color.primary.opacity(0.07) }
            if selected { return Ink.wash }
            if hover { return Color.primary.opacity(0.035) }
            return .clear
            // brand: native end
        }
        if current { return Ink.playing }
        if saved { return Ink.saved }
        if selected { return Ink.wash }
        if hover { return Ink.iris.opacity(0.045) }
        return .clear
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(segment.start.timecode).font(Ink.mono(12)).foregroundStyle(tsHover ? Ink.ink : Ink.mute)
                .underline(tsHover, color: Ink.ink).onHover { tsHover = $0 }.help("Play from here")
                .lineLimit(1).fixedSize()
                .frame(width: 64, alignment: .leading).padding(.top, showSpeaker && segment.speaker != nil ? 6 : 10)
                .tapArea { app.player.seek(to: PlaybackSync.seekTime(segment, duration: app.player.duration)) }
            VStack(alignment: .leading, spacing: 4) {
                if showSpeaker, let sp = segment.speaker, let name = transcript.speakerName(sp) {
                    HStack(spacing: 7) {
                        Menu {
                            ForEach(transcript.speakers) { s in Button(s.label) { app.assign(transcript: transcript.id, segment: segment.id, to: s.id) } }
                            Divider()
                            Button("Rename \(name)…") { renaming = true; newName = name }
                            Button("No speaker") { app.assign(transcript: transcript.id, segment: segment.id, to: nil) }
                        } label: {
                            // A speaker pill: the speaker's color, fixed ink text. Native: the name in semibold, no hue.
                            Text(name).font(.system(size: 12.5, weight: look == .native ? .semibold : .bold))
                                .foregroundStyle(look == .native ? Ink.ink : Ink.inkFixed).lineLimit(1)
                                .padding(.horizontal, look == .native ? 0 : 11).frame(height: 26)
                                .background(look == .native ? Color.clear : speakerColor(sp), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Change or rename the speaker")
                        .accessibilityLabel("Speaker \(name)")
                        .popover(isPresented: $renaming, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Name this speaker").font(.system(size: 12.5, weight: .semibold))
                                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 200)
                                    .onSubmit { app.renameSpeaker(transcript: transcript.id, speaker: sp, to: newName); renaming = false }
                                HStack { Spacer(); Button("Cancel") { renaming = false }.buttonStyle(.pillLine()); Button("Save") { app.renameSpeaker(transcript: transcript.id, speaker: sp, to: newName); renaming = false }.buttonStyle(.pillDark()) }
                            }
                            .padding(14)
                        }
                    }
                    .padding(.leading, 10)
                }
                lineText
                    .font(.system(size: size)).lineSpacing(size * 0.45).foregroundStyle(Ink.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    // Three highlights, never confused: saved (lime, persistent), playing (iris, moves), hover (light, temporary).
                    .background(highlight, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onHover { hover = $0 }
                    .animation(Motion.touch, value: hover)
                    .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 2).fill(look == .native ? NativeInk.accent : Ink.iris).frame(width: 3).padding(.vertical, 4).offset(x: -10) } }
                    .contentShape(Rectangle())
                    // A click selects the line (for a passage note) and, once the audio is open, plays from it.
                    .onTapGesture {
                        select()
                        if app.player.canPlay { app.player.play(from: PlaybackSync.seekTime(segment, duration: app.player.duration)) }
                    }
                    .contextMenu {
                        CorrectionItems(text: segment.text, editable: editable) { w in fixing = w; replacement = w }
                        Divider()
                        Button("Note on this passage") { select(); NotificationCenter.default.post(name: .verbatimFocusNote, object: nil) }
                        Button("Play from here") { app.player.play(from: PlaybackSync.seekTime(segment, duration: app.player.duration)) }
                        if let info = transcript.linkInfo {
                            Button(info.supportsTimestamps ? "Open video at \(segment.start.timecode)" : "Open video") {
                                if let u = info.url(at: segment.start) { NSWorkspace.shared.open(u) }
                            }
                        }
                        Divider()
                        Button("Copy quote") { copyQuote(withLink: false) }
                        if transcript.linkInfo != nil { Button("Copy quote with link") { copyQuote(withLink: true) } }
                        if transcript.offersSponsorMarking, transcript.sponsorSpan(for: segment) == nil {
                            Divider()
                            Button("Mark as sponsor") { app.store.update(transcript.id) { $0.markSponsor(segment: segment.id) } }
                        }
                    }
                    .popover(isPresented: Binding(get: { fixing != nil }, set: { if !$0 { fixing = nil } })) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("Heard as").font(.system(size: 11)).foregroundStyle(Ink.mute); Text(fixing ?? "").font(.system(size: 13, weight: .semibold)) }
                            TextField("Correct spelling", text: $replacement).textFieldStyle(.roundedBorder).onSubmit { commit() }
                            Toggle("Remember in Dictionary", isOn: $remember).font(.system(size: 12))
                            HStack { Spacer(); Button("Cancel") { fixing = nil }.buttonStyle(.pillLine()); Button("Fix") { commit() }.buttonStyle(.pillDark()).keyboardShortcut(.defaultAction) }
                        }
                        .padding(14).frame(width: 300)
                    }
                if let mark {
                    MarkChip(note: mark) { app.player.play(from: mark.at ?? segment.start) }
                        .padding(.leading, 10).padding(.bottom, 4)
                }
            }
        }
        // About 24 pt between speakers; lines from the same speaker sit closer.
        .padding(.top, showSpeaker && !first ? 18 : 0)
        .padding(.vertical, 2)
        .animation(Motion.settle, value: current)
        .animation(Motion.snap, value: selected)
    }

    /// The speaker pill's fill (the website's transcript): the source fills in turn, Record, petal, sage, butter, by
    /// the order speakers first talk (review M-30). Always with fixed ink text, so the name carries the meaning.
    private func speakerColor(_ id: String) -> Color {
        let i = SpeakerRotation.firstAppearance(id, in: transcript.segments) ?? transcript.speakers.firstIndex { $0.id == id } ?? 0
        return SpeakerRotation.fills[i % SpeakerRotation.fills.count]
    }
    private func commit() {
        guard let from = fixing else { return }
        let to = replacement.trimmingCharacters(in: .whitespaces)
        if !to.isEmpty, to != from { app.correct(transcript: transcript.id, segment: segment.id, from: from, to: to, remember: remember) }
        fixing = nil
    }
}

/// A marked line's chip (mockup "Library features", section 3c): the Marked icon, "Moment 4:12", and where it came
/// from ("· from the Lock Screen"), on butter, the saved wash's color, in ink. Native: the accent's symbol and the same
/// words on a neutral capsule. Click it to play from the moment.
struct MarkChip: View {
    @Environment(\.look) private var look
    var note: Note
    var play: () -> Void

    var body: some View {
        let native = look == .native
        HStack(spacing: 6) {
            if native {
                Image(systemName: "bookmark.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(NativeInk.accent)   // brand: native
            } else {
                ArtIcon(art: .iconMarked, size: 13)
            }
            Text("Moment").font(.system(size: 12.5, weight: .semibold))
            Text(Marks.clock(note.at ?? 0)).font(native ? .system(size: 12.5, weight: .medium).monospacedDigit() : Ink.mono(12))
            // The short form, as the Moments screen says it ("Lock Screen", "Mac · ⌃⌥B"); VoiceOver hears the
            // sentence (review M-56).
            if let from = Marks.shortSource(note) { Text("· \(from)").font(.system(size: 12.5)).opacity(0.78) }
        }
        .foregroundStyle(native ? Ink.ink : Ink.inkFixed)
        .lineLimit(1)
        .padding(.horizontal, 10).frame(height: 24)
        .background(native ? Ink.ink.opacity(0.07) : Ink.panelButter, in: Capsule())
        .contentShape(Capsule())
        .tapArea(play)
        .help("Play from this moment")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Marks.chip(note) ?? "Moment")
        .accessibilityHint("Plays from this moment.")
        .accessibilityAction { play() }
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
        // Moments marked while recording, by line, for their chips (the first on a line).
        let marked = Dictionary(transcript.notes.filter(\.isMark).compactMap { n in n.segmentId.map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
        // Lazy: a long recording has hundreds of lines, each with menus and a popover. Build only what's on screen.
        // Sponsor reads fold into one row at their first line; their lines show once the row is opened.
        let folds = self.folds.count == segments.count ? self.folds : SponsorFold.places(segments, in: transcript)
        // "unclear 2:10" chips where speech was heard but no words came through (UnclearRules), between the lines.
        let chips = UnclearStyle.chips(transcript, lines: segments)
        LazyVStack(alignment: .leading, spacing: 0) {
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
                    .padding(.leading, 74).padding(.top, i == 0 ? 0 : 8).padding(.bottom, 6)
                }
                SegmentLine(transcript: transcript, segment: s, showSpeaker: showSpeaker, current: current.contains(s.id), saved: saved.contains(s.id), mark: marked[s.id], selected: selected == s.id, editable: editable, size: textSize, first: i == 0) {
                    selected = selected == s.id ? nil : s.id
                }
                .id(s.id)
                .staggerIn(i < 10 ? i + 2 : -1)
                .foldedAway(fold.map { !openSponsors.contains($0.span.id) } ?? false)
            }
            if let spans = chips[segments.count] { unclearChips(spans) }
        }
        .onReceive(clock.$time) { now in syncPlaying(at: now) }
        .onChange(of: isPlaying) { _, _ in syncPlaying(at: clock.time) }
        // The lines' ids and times, not the whole lines (words included): only those decide what's playing.
        .onChange(of: segments.timingKey) { _, _ in syncPlaying(at: clock.time) }
    }

    /// The chips before a line, in the text column (past the timecodes).
    private func unclearChips(_ spans: [UnclearSpan]) -> some View {
        ForEach(spans, id: \.start) { sp in
            UnclearChip(span: sp, onPlay: { app.player.play(from: sp.start) })
                .padding(.leading, 84).padding(.vertical, 6)
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
    static let fills: [Color] = [Ink.panelRecord, Ink.panelPetal, Ink.panelSage, Ink.panelButter]
    static let tints: [Color] = [Ink.persimmonTint, Ink.petalTint, Ink.sageTint, Ink.butterTint]

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
