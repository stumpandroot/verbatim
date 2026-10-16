import SwiftUI
import AppKit

/// Transcript workspace (Listening Desk composition, Soft Instrument playback dock).
/// Calm reading surface; the player and the notes carry the interaction.
struct TranscriptView: View {
    /// True while any text field or text view in the key window is being edited.
    static var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    @EnvironmentObject var app: AppState
    var id: UUID
    @State private var view: Mode = .original
    /// nil = automatic (open when the window is wide). Set once the person toggles it.
    @State private var notesPref: Bool? = nil
    @State private var detailsOpen = false
    @State private var selectedSegment: UUID? = nil
    @State private var followed: UUID? = nil
    @State private var pendingSeek: Double? = nil
    @State private var textSize: CGFloat = 16
    /// True once the mode bar has scrolled under the top edge; a pinned copy shows there instead.
    @State private var barPinned = false
    @State private var runningAction: FlowAction? = nil
    @Namespace private var segNS

    enum Mode: String, CaseIterable { case original = "Transcript", document = "Document", cleaned = "Cleaned", summary = "Summary", review = "Review" }
    /// Cleaned lives inside Document now; Summary ships with a later build.
    static let visibleModes: [Mode] = [.original, .document, .review]


    private var transcript: Transcript? { app.store.transcript(id) }

    var body: some View {
        // One sheet for the screen: the tools row can exist twice (scrolled and pinned).
        screenBody.sheet(item: $runningAction) { a in
            if let t = transcript {
                ActionSheet(action: a, source: t.documentText, sourceLabel: "“\(t.title)”") { text in
                    app.store.addNote(Note(text: "\(a.name):\n\(text)"), to: t.id)
                }
                .environmentObject(app)
            }
        }
    }

    @ViewBuilder private var screenBody: some View {
        if let t = transcript {
            GeometryReader { g in
            // Decided from the geometry in the same pass, so the screen lays out once (no open-then-close).
            let narrow = g.size.width < 900
            let notesOpen = notesPref ?? !narrow
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header(t).staggerIn(0)
                                modeBar(t, notesOpen: notesOpen, narrow: narrow)
                                    .opacity(barPinned ? 0 : 1).allowsHitTesting(!barPinned)
                                    .background(GeometryReader { b in Color.clear.preference(key: BarOffsetKey.self, value: b.frame(in: .named("tscroll")).minY) })
                                    .staggerIn(1).padding(.bottom, 8)
                                content(t)
                            }
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, t.audioFileName != nil && view != .document ? 124 : 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .coordinateSpace(name: "tscroll")
                        .onPreferenceChange(BarOffsetKey.self) { y in
                            let pinned = y < 6
                            if pinned != barPinned { barPinned = pinned }
                        }
                        .overlay(alignment: .top) {
                            // The mode bar and tools stay reachable while reading: pinned under the top edge.
                            if barPinned {
                                VStack(spacing: 0) {
                                    modeBar(t, notesOpen: notesOpen, narrow: narrow)
                                        .frame(maxWidth: 720, alignment: .leading)
                                        .padding(.horizontal, 40).padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Ink.paper)
                                    Rectangle().fill(Ink.hairline).frame(height: 1)
                                }
                                .transition(.opacity)
                            }
                        }
                        .onReceive(app.player.clock.$time) { now in
                            // Follow playback, but only when the playing passage changes (not on every tick).
                            if app.player.isPlaying, let s = t.segments.first(where: { now >= $0.start && now < $0.end }), s.id != followed {
                                followed = s.id
                                withAnimation(Motion.settle) { proxy.scrollTo(s.id, anchor: .center) }
                            }
                        }
                        .onAppear {
                            // Opened from search, a link, or a note: land on that passage.
                            if let f = app.focusSegment, t.segments.contains(where: { $0.id == f }) {
                                app.focusSegment = nil
                                view = .original
                                selectedSegment = f
                                DispatchQueue.main.async { proxy.scrollTo(f, anchor: .center) }
                                if let s = t.segments.first(where: { $0.id == f }) { pendingSeek = s.start }
                            }
                        }
                    }
                    if t.audioFileName != nil, t.status == .ready, view != .document { PlayerDock(transcript: t, clock: app.player.clock).padding(.horizontal, 24).padding(.bottom, 18).staggerIn(3) }
                }
                .frame(maxWidth: .infinity)
                if notesOpen && !narrow {
                    NotesPanel(transcript: t, selectedSegment: selectedSegment, detailsOpen: $detailsOpen, onClose: { withAnimation(Motion.nav) { notesPref = false } })
                        .frame(width: 300)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .identity))
                }
            }
            .overlay(alignment: .trailing) {
                // Narrow window: Notes becomes a drawer over the text instead of squeezing it.
                if notesOpen && narrow {
                    NotesPanel(transcript: t, selectedSegment: selectedSegment, detailsOpen: $detailsOpen, onClose: { withAnimation(Motion.nav) { notesPref = false } })
                        .frame(width: 300)
                        .shadow(color: .black.opacity(0.12), radius: 24, x: -6)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .identity))
                }
            }

            }
            .background {
                // Shortcuts live here once, not on the mode bar (which can exist twice while pinned).
                ZStack {
                    Button("") { ExportMenu.copy(t, app: app) }.keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("") { textSize = min(22, textSize + 1) }.keyboardShortcut("=", modifiers: .command)
                    Button("") { textSize = max(13, textSize - 1) }.keyboardShortcut("-", modifiers: .command)
                }
                .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .onAppear {
                if UITest.enabled { Log.note("UITEST nav appear ms=\(Int(Date().timeIntervalSince(app.navStartedAt) * 1000)) segments=\(t.segments.count)") }
                if let u = app.store.audioURL(for: t) { app.player.loadAsync(u, startAt: pendingSeek) }
                if UITest.enabled { DispatchQueue.main.async { Log.note("UITEST nav settled ms=\(Int(Date().timeIntervalSince(app.navStartedAt) * 1000))") } }
            }
            .onDisappear { app.player.stop() }
            // Playback keys never steal typing: when a text field (renaming a speaker, a note, a correction) has
            // focus, the key goes to the field.
            .onKeyPress(.space) { if Self.typing { return .ignored }; app.player.toggle(); return .handled }
            .onKeyPress(.leftArrow) { if Self.typing { return .ignored }; app.player.seek(to: app.player.time - 5); return .handled }
            .onKeyPress(.rightArrow) { if Self.typing { return .ignored }; app.player.seek(to: app.player.time + 5); return .handled }
            .onKeyPress("b") { if Self.typing { return .ignored }; bookmark(t); return .handled }
            .onReceive(NotificationCenter.default.publisher(for: .verbatimShowMode)) { n in
                if let raw = n.object as? String, let m = Mode(rawValue: raw) { withAnimation(Motion.snap) { view = m } }
            }
        } else {
            Text("This transcript was deleted.").foregroundStyle(Ink.mute)
        }
    }

    private func bookmark(_ t: Transcript) {
        let at = app.player.time
        let seg = t.segments.first(where: { at >= $0.start && at < $0.end })
        app.addNote(transcript: t.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
    }

    // MARK: Header and mode bar

    private func header(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: Binding(get: { t.title }, set: { v in app.store.update(t.id) { $0.title = v } }))
                .textFieldStyle(.plain).font(Ink.serif(32)).foregroundStyle(Ink.ink).lineLimit(2)
            HStack(spacing: 8) {
                Text(t.sourceLabel); Text("·"); Text(t.duration.timecode)
                if t.speakers.count >= 2 { Text("·"); Text("\(t.speakers.count) speakers") }
            }
            .font(.system(size: 14)).foregroundStyle(Ink.mute)
            if let info = t.linkInfo { LinkCard(info: info, transcript: t).padding(.top, 10) }
        }
        .padding(.bottom, 14)
    }

    private func modeBar(_ t: Transcript, notesOpen: Bool, narrow: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Self.visibleModes, id: \.self) { m in
                    Text(m.rawValue).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 13).padding(.vertical, 5)
                        .background { if view == m { Capsule().fill(Ink.iris).matchedGeometryEffect(id: "mode", in: segNS) } }
                        .foregroundStyle(view == m ? Ink.onInteractive : Ink.ink)
                        .tapArea { withAnimation(Motion.snap) { view = m } }
                }
            }
            .padding(3).background(Ink.track, in: Capsule()).fixedSize()
            Divider().frame(height: 18)
            HStack(spacing: 5) {
                Text(view == .document ? "Original kept" : "Original preserved").font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1).layoutPriority(-1)
                Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Ink.mute)
                    .help("The engine's output is stored untouched. The Document, corrections, and polish are separate layers you can always compare against it.")
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            tools(t, notesOpen: notesOpen, compact: narrow)
        }
    }

    /// Copy, Export, Notes, and text size, beside the modes they act on.
    private func tools(_ t: Transcript, notesOpen: Bool, compact: Bool) -> some View {
        HStack(spacing: 2) {
            ExportMenu(transcript: t, compact: compact)
            Menu { ActionsMenuItems { runningAction = $0 } } label: { ToolLabel(title: "Actions", symbol: "wand.and.stars", compact: compact) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(t.status != .ready)
                .help("Run a saved action on this transcript: decisions and next steps, a brief, an email")
            Button { withAnimation(Motion.nav) { notesPref = !notesOpen } } label: { ToolLabel(title: "Notes", symbol: "note.text", compact: compact, on: notesOpen) }
                .buttonStyle(.plain).help(notesOpen ? "Hide notes" : "Show notes")
            Menu {
                Button("Larger text") { textSize = min(22, textSize + 1) }
                Button("Smaller text") { textSize = max(13, textSize - 1) }
                Button("Default size") { textSize = 16 }
            } label: { ToolLabel(title: "Text", symbol: "textformat.size", compact: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Text size (⌘+ and ⌘−)")
        }
        .fixedSize()
    }

    // MARK: Content per mode

    @ViewBuilder private func content(_ t: Transcript) -> some View {
        if t.status == .processing { processing(t) }
        else if t.status == .failed { failed(t) }
        else {
            switch view {
            case .original: lines(t, segments: t.segments, editable: true)
            case .document: DocumentView(transcript: t)
            case .cleaned: lines(t, segments: Cleanup.light(t.segments), editable: false)
            case .summary: placeholder("Summary", "Key points, decisions, and quotes, each linked to the passage it came from. Arrives with the local language model build.")
            case .review: review(t)
            }
        }
    }

    private func lines(_ t: Transcript, segments: [Segment], editable: Bool) -> some View {
        TranscriptLines(clock: app.player.clock, isPlaying: app.player.isPlaying, transcript: t, segments: segments, editable: editable, textSize: textSize, selected: $selectedSegment)
    }

    private func review(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if t.corrections.isEmpty {
                placeholder("Nothing changed yet", "Corrections you make, and Dictionary fixes, show here side by side with the original so you can accept or undo them.")
            } else {
                ForEach(t.corrections) { c in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: c.byDictionary ? "book.closed.fill" : "pencil").foregroundStyle(Ink.iris).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) { Text(c.from).strikethrough().foregroundStyle(Ink.mute); Image(systemName: "arrow.right").font(.system(size: 10)); Text(c.to).fontWeight(.semibold) }
                            if let seg = t.segments.first(where: { $0.id == c.segmentId }) {
                                Text(seg.text).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(2)
                                Button(seg.start.timecode) { app.player.seek(to: seg.start) }.buttonStyle(.link).font(.system(size: 11, design: .monospaced))
                            }
                        }
                        Spacer()
                        Button("Undo") { undo(t, c) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(12).background(Ink.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.06)))
                }
            }
        }
    }

    private func undo(_ t: Transcript, _ c: Correction) {
        app.store.update(t.id) { x in
            if let i = x.segments.firstIndex(where: { $0.id == c.segmentId }) { x.segments[i].text = x.segments[i].text.replacingOccurrences(of: c.to, with: c.from) }
            x.corrections.removeAll { $0.id == c.id }
        }
    }

    private func placeholder(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            EmptyStateArt(art: .refine, tint: Ink.petalTint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(body).font(.system(size: 13.5)).foregroundStyle(Ink.mute)
            }
        }
        .padding(16).background(Ink.wash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }


    private func processing(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SignalRings().frame(width: 40, height: 40).padding(6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.stageText).font(.system(size: 15, weight: .semibold))
                    Text("On this Mac. The first run of a model downloads it once; after that it starts in seconds.").font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
            }
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(Ink.ink.opacity(0.07)).frame(width: CGFloat([480, 420, 500, 300][i]), height: 14).padding(.vertical, 6)
            }
        }
    }

    private func failed(_ t: Transcript) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 22, weight: .light)).foregroundStyle(Ink.danger).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription did not finish").font(.system(size: 14, weight: .semibold))
                Text(t.error ?? "").font(.system(size: 13)).foregroundStyle(Ink.mute)
                Button("Retry") { app.retry(t) }.buttonStyle(.brandPrimary)
            }
        }
    }
}

/// One line: timecode, speaker only when it changes, text. Click to select (for a passage-linked note),
/// right-click to correct a word. The current line during playback carries the iris tint.
struct SegmentLine: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var segment: Segment
    var showSpeaker: Bool
    var current: Bool
    var saved: Bool = false
    var selected: Bool
    var editable: Bool
    var size: CGFloat
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
            a[r].backgroundColor = Ink.coral.opacity(0.28)
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

    private var highlight: Color {
        if current { return Ink.irisTint }
        if saved { return Ink.saved }
        if selected { return Ink.wash }
        if hover { return Ink.iris.opacity(0.045) }
        return .clear
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(segment.start.timecode).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(tsHover ? Ink.iris : Ink.faint)
                .underline(tsHover, color: Ink.iris).onHover { tsHover = $0 }.help("Play from here")
                .frame(width: 48, alignment: .leading).padding(.top, showSpeaker ? 24 : 6)
                .tapArea { app.player.seek(to: segment.start) }
            VStack(alignment: .leading, spacing: 2) {
                if showSpeaker, let sp = segment.speaker, let name = transcript.speakerName(sp) {
                    HStack(spacing: 7) {
                        Circle().fill(speakerColor(sp)).frame(width: 8, height: 8)
                        Menu {
                            ForEach(transcript.speakers) { s in Button(s.label) { app.assign(transcript: transcript.id, segment: segment.id, to: s.id) } }
                            Divider()
                            Button("Rename \(name)…") { renaming = true; newName = name }
                            Button("No speaker") { app.assign(transcript: transcript.id, segment: segment.id, to: nil) }
                        } label: { Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(speakerColor(sp)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .popover(isPresented: $renaming, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Name this speaker").font(.system(size: 12.5, weight: .semibold))
                                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 200)
                                    .onSubmit { app.renameSpeaker(transcript: transcript.id, speaker: sp, to: newName); renaming = false }
                                HStack { Spacer(); Button("Cancel") { renaming = false }; Button("Save") { app.renameSpeaker(transcript: transcript.id, speaker: sp, to: newName); renaming = false }.buttonStyle(.brandPrimary) }
                            }
                            .padding(14)
                        }
                    }
                    .padding(.top, 8)
                }
                Text(highlighted(segment.text))
                    .font(.system(size: size)).lineSpacing(size * 0.3).foregroundStyle(Ink.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    // Three highlights, never confused: saved (lime, persistent), playing (iris, moves), hover (light, temporary).
                    .background(highlight, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onHover { hover = $0 }
                    .animation(Motion.touch, value: hover)
                    .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 2).fill(Ink.iris).frame(width: 3).padding(.vertical, 4).offset(x: -10) } }
                    .contentShape(Rectangle())
                    .onTapGesture { select() }
                    .contextMenu {
                        ForEach(candidates, id: \.self) { w in Button("Correct “\(w)”…") { fixing = w; replacement = w } }
                        Divider()
                        Button("Note on this passage") { select(); NotificationCenter.default.post(name: .verbatimFocusNote, object: nil) }
                        Button("Play from here") { app.player.seek(to: segment.start); if !app.player.isPlaying { app.player.toggle() } }
                        if let info = transcript.linkInfo {
                            Button(info.supportsTimestamps ? "Open video at \(segment.start.timecode)" : "Open video") {
                                if let u = info.url(at: segment.start) { NSWorkspace.shared.open(u) }
                            }
                        }
                        Divider()
                        Button("Copy quote") { copyQuote(withLink: false) }
                        if transcript.linkInfo != nil { Button("Copy quote with link") { copyQuote(withLink: true) } }
                    }
                    .popover(isPresented: Binding(get: { fixing != nil }, set: { if !$0 { fixing = nil } })) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("Heard as").font(.system(size: 11)).foregroundStyle(Ink.mute); Text(fixing ?? "").font(.system(size: 13, weight: .semibold)) }
                            TextField("Correct spelling", text: $replacement).textFieldStyle(.roundedBorder).onSubmit { commit() }
                            Toggle("Remember in Dictionary", isOn: $remember).font(.system(size: 12))
                            HStack { Spacer(); Button("Cancel") { fixing = nil }; Button("Fix") { commit() }.buttonStyle(.brandPrimary).keyboardShortcut(.defaultAction) }
                        }
                        .padding(14).frame(width: 300)
                    }
            }
        }
        .padding(.vertical, 3)
        .animation(Motion.settle, value: current)
        .animation(Motion.snap, value: selected)
    }

    private func speakerColor(_ id: String) -> Color {
        // Speaker markers: brand hues as small markers only; the name is always written out.
        let palette = [Ink.accentText, Ink.sageText, Color(nsColor: NSColor(name: nil) { a in a.isDark ? NSColor(hex: 0xE3A3B8) : NSColor(hex: 0xA34D6B) }), Color(nsColor: NSColor(name: nil) { a in a.isDark ? NSColor(hex: 0xE8C27A) : NSColor(hex: 0x8A6414) }), Ink.dim]
        return palette[max(0, (Int(id.dropFirst()) ?? 1) - 1) % palette.count]
    }
    private var candidates: [String] {
        guard editable else { return [] }
        let words = segment.text.split { $0 == " " }.map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { $0.count > 2 }
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }.sorted { $0.count > $1.count }.prefix(8).map { $0 }
    }
    private func commit() {
        guard let from = fixing else { return }
        let to = replacement.trimmingCharacters(in: .whitespaces)
        if !to.isEmpty, to != from { app.correct(transcript: transcript.id, segment: segment.id, from: from, to: to, remember: remember) }
        fixing = nil
    }
}

extension Notification.Name { static let verbatimFocusNote = Notification.Name("verbatimFocusNote") }

/// Light, deterministic cleanup: fillers out, sentence case, double spaces gone. Never touches names or numbers.
/// Conservative on purpose: only sounds that are never words ("um", "uh"), and phrase fillers only when
/// they're set off by a comma ("you know," / ", like,"). "I like this" and "the kind of wagon" stay intact.
enum Cleanup {
    static let sounds = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm"]
    static let asides = ["you know", "i mean", "like", "sort of", "kind of", "basically", "actually", "literally"]
    static func light(_ segs: [Segment]) -> [Segment] {
        segs.map { s in
            var t = s.text
            for f in sounds {
                t = t.replacingOccurrences(of: "(?i)(^|\\s)" + f + ",?(?=\\s|$|[.!?])", with: "$1", options: .regularExpression)
            }
            for f in asides {
                // Only as an aside: ", like," in the middle, or "You know," at the start of a sentence.
                t = t.replacingOccurrences(of: "(?i),\\s*" + f + ",", with: ",", options: .regularExpression)
                t = t.replacingOccurrences(of: "(?i)(^|[.!?]\\s+)" + f + ",\\s*", with: "$1", options: .regularExpression)
            }
            // "the the" → "the"
            t = t.replacingOccurrences(of: "(?i)\\b(\\w+)\\s+\\1\\b", with: "$1", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            t = t.replacingOccurrences(of: "\\s,", with: ",", options: .regularExpression)
            if let f = t.first { t = f.uppercased() + t.dropFirst() }
            var c = s; c.text = t; return c
        }.filter { !$0.text.isEmpty }
    }
}

// MARK: - Player dock (Soft Instrument)

struct PlayerDock: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock

    var body: some View {
        let total = max(app.player.duration, transcript.duration)
        HStack(spacing: 12) {
            Button { app.player.toggle() } label: {
                ZStack {
                    Circle().fill(Ink.interactive)
                        .shadow(color: Ink.inkFixed.opacity(0.12), radius: 6, y: 2)
                    Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(Ink.onInteractive).offset(x: app.player.isPlaying ? 0 : 1.5)
                }
                .frame(width: 50, height: 50)
            }
            .buttonStyle(PressStyle(scale: 0.94)).help("Play or pause (Space)")

            skip("gobackward.5", -5, "Back 5 seconds (←)")
            HStack(spacing: 4) {
                Text(app.player.time.timecode).font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.ink)
                Text("/").foregroundStyle(Ink.mute)
                Text(total.timecode).font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Ink.mute)
            }
            .fixedSize()

            WaveTrack(values: transcript.waveform, progress: total > 0 ? app.player.time / total : 0,
                      marks: transcript.notes.filter(\.isBookmark).compactMap { $0.at }.map { $0 / max(total, 1) }) { p in
                app.player.seek(to: p * total)
            }
            .frame(height: 36)
            skip("goforward.5", 5, "Forward 5 seconds (→)")

            Menu { ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button("\(String(format: "%g", r))×") { app.player.setRate(Float(r)) } } } label: {
                Text("\(String(format: "%g", app.player.rate))×").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.ink)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton).fixedSize()

            Button {
                let at = app.player.time
                let seg = transcript.segments.first(where: { at >= $0.start && at < $0.end })
                app.addNote(transcript: transcript.id, text: seg.map { String($0.text.prefix(60)) } ?? "Bookmark", at: at, segment: seg?.id, bookmark: true)
            } label: {
                Image(systemName: "bookmark.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.limeText)
                    .frame(width: 38, height: 38).background(Ink.limeTint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(PressStyle(scale: 0.94)).help("Bookmark this moment (B)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Ink.glassTint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: Ink.inkFixed.opacity(0.08), radius: 10, y: 3)
        .frame(maxWidth: 760)
    }

    private func skip(_ symbol: String, _ by: Double, _ help: String) -> some View {
        Button { app.player.seek(to: app.player.time + by) } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Ink.ink).frame(width: 32, height: 32)
        }
        .buttonStyle(PressStyle(scale: 0.92)).help(help)
    }
}

struct WaveTrack: View {
    var values: [Float]
    var progress: Double
    var marks: [Double] = []
    var onSeek: (Double) -> Void
    @State private var hoverX: CGFloat? = nil

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let vals = values.isEmpty ? Array(repeating: Float(0.15), count: 96) : Waveform.resample(values, to: 96)
            ZStack(alignment: .leading) {
                WaveformThumb(values: vals).fill(Ink.track)
                WaveformThumb(values: vals).fill(Ink.iris)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * progress)) }
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    Capsule().fill(Ink.persimmon).frame(width: 3, height: g.size.height).offset(x: w * m - 1.5)
                }
                Rectangle().fill(Ink.ink).frame(width: 2, height: g.size.height + 6).offset(x: max(0, min(w - 2, w * progress - 1)), y: -3)
                if let hx = hoverX { Rectangle().fill(Ink.iris.opacity(0.25)).frame(width: 1).offset(x: hx) }
            }
            .contentShape(Rectangle())
            .onContinuousHover { ph in if case .active(let p) = ph { hoverX = p.x } else { hoverX = nil } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in onSeek(max(0, min(1, v.location.x / w))) })
        }
    }
}

// MARK: - Notes panel

struct NotesPanel: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var selectedSegment: UUID?
    @Binding var detailsOpen: Bool
    var onClose: () -> Void = {}
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var linked: Segment? { selectedSegment.flatMap { id in transcript.segments.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Notes").font(.system(size: 19, weight: .bold))
                Spacer()
                Text("\(transcript.notes.count)").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                Button { onClose() } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 26, height: 26).background(Color.black.opacity(0.05), in: Circle()) }
                    .buttonStyle(.plain).help("Hide notes")
            }
            VStack(alignment: .leading, spacing: 6) {
                if let s = linked {
                    HStack(spacing: 6) {
                        Image(systemName: "link").font(.system(size: 10, weight: .bold))
                        Text("On the passage at \(s.start.timecode)").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Ink.iris)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").foregroundStyle(Ink.mute)
                    TextField(linked == nil ? "Add note… (click a line to link it)" : "Add note on this passage…", text: $draft).textFieldStyle(.plain).font(.system(size: 13.5)).focused($focused).onSubmit(save)
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Ink.iris.opacity(0.5) : Color.black.opacity(0.08)))
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(transcript.notes.enumerated()), id: \.element.id) { i, n in
                        NoteCard(note: n, onSeek: { if let at = n.at { app.player.seek(to: at) } }, onDelete: { app.deleteNote(transcript: transcript.id, note: n.id) })
                            .staggerIn(i)
                            .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .identity))
                    }
                    if transcript.notes.isEmpty {
                        Text("Thoughts, quotes to use, things to check. Press B while listening to bookmark a moment.")
                            .font(.system(size: 12.5)).foregroundStyle(Ink.mute).padding(.top, 8)
                    }
                }
            }
            .animation(Motion.bounce, value: transcript.notes.map(\.id))
            Spacer(minLength: 0)
            DisclosureGroup(isExpanded: $detailsOpen) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Source", transcript.sourceLabel)
                    row("Engine", transcript.model.isEmpty ? "—" : transcript.model)
                    if let l = transcript.language { row("Language", l.uppercased()) }
                    row("Words", "\(transcript.text.split(separator: " ").count)")
                    row("Dictionary", "\(transcript.corrections.filter(\.byDictionary).count) fixes")
                    row("Kept", "On this Mac")
                }
                .font(.system(size: 12.5)).padding(.top, 6)
                Picker("Project", selection: Binding(get: { transcript.projectId }, set: { v in app.store.update(transcript.id) { $0.projectId = v } })) {
                    Text("None").tag(UUID?.none)
                    ForEach(app.store.projects) { p in Text(p.name).tag(UUID?.some(p.id)) }
                }
                .controlSize(.small).padding(.top, 6)
                Button(role: .destructive) {
                    app.go(.library)
                    app.delete([transcript.id])
                } label: { Label("Delete transcript", systemImage: "trash") }
                .buttonStyle(.plain).foregroundStyle(Ink.mute).font(.system(size: 12.5)).padding(.top, 8)
            } label: {
                HStack(spacing: 8) { Image(systemName: "info.circle"); Text("Details") }.font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.ink)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ink.notes)
        .overlay(alignment: .leading) { Ink.hairline.frame(width: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimFocusNote)) { _ in focused = true }
    }

    private func save() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        app.addNote(transcript: transcript.id, text: t, at: linked?.start ?? (app.player.time > 0 ? app.player.time : nil), segment: linked?.id)
        draft = ""
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(Ink.mute); Text(v).foregroundStyle(Ink.ink) }
    }
}

struct NoteCard: View {
    var note: Note
    var onSeek: () -> Void
    var onDelete: () -> Void
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let f = note.frameFile {
                FrameImage(file: f).frame(height: 120).padding(.bottom, 4).tapArea(onSeek)
            }
            if let at = note.at {
                HStack(spacing: 5) {
                    if note.isBookmark { Image(systemName: "bookmark.fill").font(.system(size: 10)) }
                    Text(at.timecode).font(.system(size: 11.5, design: .monospaced))
                }
                .foregroundStyle(note.isBookmark ? Ink.limeText : Ink.iris)
                .tapArea(onSeek)
            }
            Text(note.text).font(.system(size: 14)).foregroundStyle(Ink.ink).lineSpacing(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            Menu { Button("Delete", role: .destructive) { onDelete() } } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 22, height: 18)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hover ? 1 : 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        // Solid tinted blocks by kind: coral for a loose note, lime for a bookmark, iris for a passage note.
        .background(note.isBookmark ? Ink.limeTint : note.segmentId != nil ? Ink.irisTint : Ink.coralTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(hover ? 0.1 : 0.05)))
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
    }
}

struct BarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

extension Notification.Name { static let verbatimShowMode = Notification.Name("verbatimShowMode") }

/// The reading lines. Observes only the playhead, so the playing-passage tint moves without re-rendering
/// the rest of the screen.
struct TranscriptLines: View {
    @ObservedObject var clock: PlayerClock
    var isPlaying: Bool
    var transcript: Transcript
    var segments: [Segment]
    var editable: Bool
    var textSize: CGFloat
    @Binding var selected: UUID?

    var body: some View {
        let saved = Set(transcript.notes.filter(\.isBookmark).compactMap(\.segmentId))
        // Lazy: a long recording has hundreds of lines, each with menus and a popover. Build only what's on screen.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                let showSpeaker = transcript.speakers.count >= 2 && s.speaker != nil && (i == 0 || segments[i - 1].speaker != s.speaker)
                let now = clock.time
                let current = now >= s.start && now < s.end && (isPlaying || now > 0)
                SegmentLine(transcript: transcript, segment: s, showSpeaker: showSpeaker, current: current, saved: saved.contains(s.id), selected: selected == s.id, editable: editable, size: textSize) {
                    selected = selected == s.id ? nil : s.id
                }
                .id(s.id)
                .staggerIn(i < 10 ? i + 2 : -1)
            }
        }
    }
}

/// The source page under the title: thumbnail, channel · site · date, and the video one click away.
struct LinkCard: View {
    @EnvironmentObject var app: AppState
    var info: LinkInfo
    var transcript: Transcript
    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(info: info).frame(width: 72, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text([info.channel, info.site].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                Text([info.uploadDisplay, URL(string: info.url)?.host?.replacingOccurrences(of: "www.", with: "")].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { if let u = URL(string: info.url) { NSWorkspace.shared.open(u) } } label: { Label("Open video", systemImage: "play.rectangle") }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
            KeepButton(transcript: transcript)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info.url, forType: .string); app.toast = Toast("Link copied") } label: { Image(systemName: "link") }
                .buttonStyle(.bordered).controlSize(.small).help("Copy link")
        }
        .padding(8)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.hairline))
        .frame(maxWidth: 640, alignment: .leading)
    }
}

/// Keep the video, watch it save, then find it.
struct KeepButton: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var body: some View {
        if let busy = app.keeping[transcript.id] {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(busy.replacingOccurrences(of: "Keeping video", with: "Keeping")).monospacedDigit() }
                .font(.system(size: 12)).foregroundStyle(Ink.iris).fixedSize()
        } else if let v = transcript.keptVideo, FileManager.default.fileExists(atPath: v) {
            Button { app.showKept(v) } label: { Label("Kept", systemImage: "checkmark.circle") }
                .buttonStyle(.bordered).controlSize(.small).fixedSize().help("Show the MP4 in Finder")
        } else {
            Button { app.keepVideo(transcript.id) } label: { Label("Keep video", systemImage: "arrow.down.circle") }
                .buttonStyle(.bordered).controlSize(.small).fixedSize().help("Save the video as an MP4 in your Keep folder")
        }
    }
}
