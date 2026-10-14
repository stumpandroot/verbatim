import SwiftUI

/// Transcript workspace (Listening Desk composition, Soft Instrument playback dock).
/// Calm reading surface; the player and the notes carry the interaction.
struct TranscriptView: View {
    @EnvironmentObject var app: AppState
    var id: UUID
    @State private var view: Mode = .original
    @State private var notesOpen = true
    @State private var detailsOpen = false
    @State private var selectedSegment: UUID? = nil
    @State private var textSize: CGFloat = 16
    @Namespace private var segNS

    enum Mode: String, CaseIterable { case original = "Original", cleaned = "Cleaned", summary = "Summary", review = "Review" }
    /// Summary ships with the local language model build; until then it stays out of the capsule.
    static let visibleModes: [Mode] = [.original, .cleaned, .review]
    @State private var narrow = false

    private var transcript: Transcript? { app.store.transcript(id) }

    var body: some View {
        if let t = transcript {
            GeometryReader { g in
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header(t).staggerIn(0)
                                modeBar(t).staggerIn(1).padding(.bottom, 8)
                                content(t)
                            }
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, t.audioFileName != nil ? 124 : 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: app.player.time) { _, now in
                            if app.player.isPlaying, let s = t.segments.first(where: { now >= $0.start && now < $0.end }) {
                                withAnimation(Motion.settle) { proxy.scrollTo(s.id, anchor: .center) }
                            }
                        }
                    }
                    if t.audioFileName != nil, t.status == .ready { PlayerDock(transcript: t).padding(.horizontal, 24).padding(.bottom, 18).staggerIn(3) }
                }
                .frame(maxWidth: .infinity)
                if notesOpen && !narrow {
                    NotesPanel(transcript: t, selectedSegment: selectedSegment, detailsOpen: $detailsOpen, onClose: { withAnimation(Motion.settle) { notesOpen = false } })
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .trailing) {
                // Narrow window: Notes becomes a drawer over the text instead of squeezing it.
                if notesOpen && narrow {
                    NotesPanel(transcript: t, selectedSegment: selectedSegment, detailsOpen: $detailsOpen, onClose: { withAnimation(Motion.settle) { notesOpen = false } })
                        .frame(width: 300)
                        .shadow(color: .black.opacity(0.12), radius: 24, x: -6)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.settle, value: narrow)
            .onAppear { narrow = g.size.width < 900 }
            .onChange(of: g.size.width) { _, w in narrow = w < 900 }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        Toggle(isOn: $notesOpen.animation(Motion.settle)) { Label("Notes", systemImage: "note.text") }.toggleStyle(.button)
                        Menu { Button("Smaller text") { textSize = max(13, textSize - 1) }; Button("Larger text") { textSize = min(22, textSize + 1) } } label: { Image(systemName: "textformat.size") }
                    }
                }
            }
            .onAppear { if let u = app.store.audioURL(for: t) { app.player.load(u) } }
            .onDisappear { app.player.stop() }
            .onKeyPress(.space) { app.player.toggle(); return .handled }
            .onKeyPress(.leftArrow) { app.player.seek(to: app.player.time - 5); return .handled }
            .onKeyPress(.rightArrow) { app.player.seek(to: app.player.time + 5); return .handled }
            .onKeyPress("b") { bookmark(t); return .handled }
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
                .textFieldStyle(.plain).font(.system(size: 30, weight: .bold)).foregroundStyle(Ink.ink).lineLimit(2)
            HStack(spacing: 8) {
                Text(t.sourceLabel); Text("·"); Text(t.duration.timecode)
                if !t.speakers.isEmpty { Text("·"); Text("\(t.speakers.count) speakers") }
                if let u = t.sourceURL, let url = URL(string: u) { Text("·"); Link("Open source", destination: url) }
            }
            .font(.system(size: 14)).foregroundStyle(Ink.mute)
        }
        .padding(.bottom, 14)
    }

    private func modeBar(_ t: Transcript) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Self.visibleModes, id: \.self) { m in
                    Text(m.rawValue).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 13).padding(.vertical, 5)
                        .background { if view == m { Capsule().fill(Ink.iris).matchedGeometryEffect(id: "mode", in: segNS) } }
                        .foregroundStyle(view == m ? .white : Ink.ink)
                        .tapArea { withAnimation(Motion.snap) { view = m } }
                }
            }
            .padding(3).background(Color(hex: 0xEEEBF4), in: Capsule()).fixedSize()
            Divider().frame(height: 18)
            HStack(spacing: 5) {
                Text("Original preserved").font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1).layoutPriority(-1)
                Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Ink.mute)
                    .help("The engine's output is stored untouched. Corrections and Cleaned are separate layers you can always compare against it.")
            }
            Spacer()
        }
    }

    // MARK: Content per mode

    @ViewBuilder private func content(_ t: Transcript) -> some View {
        if t.status == .processing { processing(t) }
        else if t.status == .failed { failed(t) }
        else {
            switch view {
            case .original: lines(t, segments: t.segments, editable: true)
            case .cleaned: lines(t, segments: Cleanup.light(t.segments), editable: false)
            case .summary: placeholder("Summary", "Key points, decisions, and quotes, each linked to the passage it came from. Arrives with the local language model build.")
            case .review: review(t)
            }
        }
    }

    private func lines(_ t: Transcript, segments: [Segment], editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                let showSpeaker = s.speaker != nil && (i == 0 || segments[i - 1].speaker != s.speaker)
                SegmentLine(transcript: t, segment: s, showSpeaker: showSpeaker, current: isCurrent(s), selected: selectedSegment == s.id, editable: editable, size: textSize) {
                    selectedSegment = selectedSegment == s.id ? nil : s.id
                }
                .id(s.id)
                .staggerIn(min(i, 12) + 2)
            }
        }
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
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            VerbieView(pose: .working, tracksPointer: false).frame(width: 46, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(body).font(.system(size: 13.5)).foregroundStyle(Ink.mute)
            }
        }
        .padding(16).background(Color(hex: 0xF3F0FA), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func isCurrent(_ s: Segment) -> Bool {
        let now = app.player.time
        return now >= s.start && now < s.end && (app.player.isPlaying || now > 0)
    }

    private func processing(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VerbieView(pose: .working, tracksPointer: false).frame(width: 46, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.stage ?? "Transcribing").font(.system(size: 15, weight: .semibold))
                    Text("On this Mac. The first run of a model downloads it once; after that it starts in seconds.").font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
            }
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.06)).frame(width: CGFloat([480, 420, 500, 300][i]), height: 14).padding(.vertical, 6)
            }
        }
    }

    private func failed(_ t: Transcript) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VerbieView(pose: .interrupted, tracksPointer: false).frame(width: 52, height: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription did not finish").font(.system(size: 14, weight: .semibold))
                Text(t.error ?? "").font(.system(size: 13)).foregroundStyle(Ink.mute)
                Button("Retry") { app.retry(t) }.buttonStyle(.borderedProminent).tint(Ink.iris)
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
    var selected: Bool
    var editable: Bool
    var size: CGFloat
    var select: () -> Void
    @State private var fixing: String? = nil
    @State private var replacement = ""
    @State private var remember = true
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(segment.start.timecode).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color(hex: 0xA39B8E))
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
                                HStack { Spacer(); Button("Cancel") { renaming = false }; Button("Save") { app.renameSpeaker(transcript: transcript.id, speaker: sp, to: newName); renaming = false }.buttonStyle(.borderedProminent).tint(Ink.iris) }
                            }
                            .padding(14)
                        }
                    }
                    .padding(.top, 8)
                }
                Text(segment.text)
                    .font(.system(size: size)).lineSpacing(size * 0.3).foregroundStyle(Ink.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(current ? Ink.irisTint : selected ? Color(hex: 0xF3F0FA) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 2).fill(Ink.iris).frame(width: 3).padding(.vertical, 4).offset(x: -10) } }
                    .contentShape(Rectangle())
                    .onTapGesture { select() }
                    .contextMenu {
                        ForEach(candidates, id: \.self) { w in Button("Correct “\(w)”…") { fixing = w; replacement = w } }
                        Divider()
                        Button("Note on this passage") { select(); NotificationCenter.default.post(name: .verbatimFocusNote, object: nil) }
                        Button("Play from here") { app.player.seek(to: segment.start); if !app.player.isPlaying { app.player.toggle() } }
                    }
                    .popover(isPresented: Binding(get: { fixing != nil }, set: { if !$0 { fixing = nil } })) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("Heard as").font(.system(size: 11)).foregroundStyle(Ink.mute); Text(fixing ?? "").font(.system(size: 13, weight: .semibold)) }
                            TextField("Correct spelling", text: $replacement).textFieldStyle(.roundedBorder).onSubmit { commit() }
                            Toggle("Remember in Dictionary", isOn: $remember).font(.system(size: 12))
                            HStack { Spacer(); Button("Cancel") { fixing = nil }; Button("Fix") { commit() }.buttonStyle(.borderedProminent).tint(Ink.iris).keyboardShortcut(.defaultAction) }
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
        let palette = [Ink.iris, Ink.coral, Color(hex: 0x4F9A2E), Color(hex: 0x2F7FA0), Color(hex: 0xC08A00)]
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

    var body: some View {
        let total = max(app.player.duration, transcript.duration)
        HStack(spacing: 12) {
            Button { app.player.toggle() } label: {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(hex: 0x8C78FF), Ink.irisDeep], startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
                        .shadow(color: Ink.irisDeep.opacity(0.3), radius: 8, y: 4)
                    Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white).offset(x: app.player.isPlaying ? 0 : 1.5)
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
                Image(systemName: "bookmark.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0x4F7D12))
                    .frame(width: 38, height: 38).background(Ink.limeTint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(PressStyle(scale: 0.94)).help("Bookmark this moment (B)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: Color(hex: 0x3C328C).opacity(0.14), radius: 16, y: 6)
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
                WaveformThumb(values: vals).fill(Color(hex: 0xD9D4E6))
                WaveformThumb(values: vals).fill(Ink.iris)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * progress)) }
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    Capsule().fill(Color(hex: 0x7FB83A)).frame(width: 3, height: g.size.height).offset(x: w * m - 1.5)
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
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Ink.iris.opacity(0.5) : Color.black.opacity(0.08)))
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(transcript.notes.enumerated()), id: \.element.id) { i, n in
                        NoteCard(note: n, onSeek: { if let at = n.at { app.player.seek(to: at) } }, onDelete: { app.deleteNote(transcript: transcript.id, note: n.id) })
                            .staggerIn(i)
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { withAnimation(Motion.settle) { app.store.delete(transcript) } }
                } label: { Label("Delete transcript", systemImage: "trash") }
                .buttonStyle(.plain).foregroundStyle(Ink.mute).font(.system(size: 12.5)).padding(.top, 8)
            } label: {
                HStack(spacing: 8) { Image(systemName: "info.circle"); Text("Details") }.font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.ink)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0xF8F6FB))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let at = note.at {
                    HStack(spacing: 5) {
                        if note.isBookmark { Image(systemName: "bookmark.fill").font(.system(size: 10)) }
                        Text(at.timecode).font(.system(size: 11.5, design: .monospaced))
                    }
                    .foregroundStyle(note.isBookmark ? Color(hex: 0x4F7D12) : Ink.iris)
                    .tapArea(onSeek)
                }
                Spacer()
                Menu { Button("Delete", role: .destructive) { onDelete() } } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 22, height: 18)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Text(note.text).font(.system(size: 14)).foregroundStyle(Ink.ink).lineSpacing(3).textSelection(.enabled)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        // Solid tinted blocks by kind: coral for a loose note, lime for a bookmark, iris for a passage note.
        .background(note.isBookmark ? Color(hex: 0xF1F8E0) : note.segmentId != nil ? Ink.irisTint : Ink.coralTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(hover ? 0.1 : 0.05)))
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
    }
}
