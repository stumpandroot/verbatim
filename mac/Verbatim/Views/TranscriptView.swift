import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var app: AppState
    var id: UUID
    @State private var speakerFilter: String? = nil
    @State private var showOriginal = false

    private var transcript: Transcript? { app.store.transcript(id) }

    var body: some View {
        if let t = transcript {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    header(t)
                    if !t.speakers.isEmpty { speakerChips(t) }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if t.status == .processing { processing(t) }
                                else if t.status == .failed { failed(t) }
                                else {
                                    let list = showOriginal ? t.original : t.segments
                                    ForEach(list.filter { speakerFilter == nil || $0.speaker == speakerFilter }) { s in
                                        SegmentLine(transcript: t, segment: s, current: isCurrent(s), editable: !showOriginal).id(s.id)
                                    }
                                }
                            }
                            .frame(maxWidth: 600, alignment: .leading)
                            .padding(.bottom, 24)
                        }
                        .onChange(of: app.player.time) { _, now in
                            if app.player.isPlaying, let s = t.segments.first(where: { now >= $0.start && now < $0.end }) {
                                withAnimation(Motion.settle) { proxy.scrollTo(s.id, anchor: .center) }
                            }
                        }
                    }
                    if t.audioFileName != nil { playbar(t) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                inspector(t).frame(width: 280)
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 16)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
            .onAppear { if let u = app.store.audioURL(for: t) { app.player.load(u) } }
            .onDisappear { app.player.stop() }
        } else {
            Text("This transcript was deleted.").foregroundStyle(Ink.mute)
        }
    }

    private func header(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: Binding(get: { t.title }, set: { v in app.store.update(t.id) { $0.title = v } }))
                .textFieldStyle(.plain).font(.system(size: 26, weight: .semibold)).foregroundStyle(Ink.ink)
            HStack(spacing: 12) {
                Text(t.sourceLabel); Text(t.duration.timecode); Text(t.createdAt, style: .date)
                if let u = t.sourceURL, let url = URL(string: u) { Link("Open source", destination: url).font(.system(size: 12.5)) }
                if !t.corrections.isEmpty {
                    Picker("", selection: $showOriginal) { Text("Corrected").tag(false); Text("Original").tag(true) }
                        .pickerStyle(.segmented).controlSize(.small).frame(width: 160).labelsHidden()
                }
            }
            .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
        }
        .padding(.bottom, 12)
    }

    private func speakerChips(_ t: Transcript) -> some View {
        HStack(spacing: 6) {
            ForEach(t.speakers) { sp in
                SpeakerChip(speaker: sp, selected: speakerFilter == sp.id) {
                    speakerFilter = speakerFilter == sp.id ? nil : sp.id
                } rename: { name in app.renameSpeaker(transcript: t.id, speaker: sp.id, to: name) }
            }
            Text("Click a name to rename, click the chip to filter.").font(.system(size: 11.5)).foregroundStyle(Ink.mute)
        }
        .padding(.bottom, 12)
    }

    private func isCurrent(_ s: Segment) -> Bool {
        let now = app.player.time
        return now >= s.start && now < s.end && (app.player.isPlaying || now > 0)
    }

    private func processing(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VerbieView(pose: .working).frame(width: 44, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.stage ?? "Transcribing").font(.system(size: 14, weight: .semibold))
                    Text("On this Mac. The first run of a model downloads it once; after that it starts in seconds.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                }
            }
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.06)).frame(width: CGFloat([480, 420, 500, 300][i]), height: 14).padding(.vertical, 6)
            }
        }
        .padding(.top, 8)
    }

    private func failed(_ t: Transcript) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VerbieView(pose: .interrupted).frame(width: 60, height: 70)
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription did not finish").font(.system(size: 14, weight: .semibold))
                Text(t.error ?? "").font(.system(size: 13)).foregroundStyle(Ink.mute)
                Button("Retry") { app.retry(t) }.buttonStyle(.borderedProminent).tint(Ink.iris)
            }
        }
        .padding(.top, 8)
    }

    private func playbar(_ t: Transcript) -> some View {
        HStack(spacing: 12) {
            Button { app.player.toggle() } label: {
                Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white).frame(width: 30, height: 30).background(Ink.ink, in: Circle())
            }
            .buttonStyle(.plain).pressable().keyboardShortcut(.space, modifiers: [])
            Text("\(app.player.time.timecode) / \(max(app.player.duration, t.duration).timecode)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim).frame(minWidth: 92, alignment: .leading)
            Scrubber(progress: app.player.duration > 0 ? app.player.time / app.player.duration : 0) { p in app.player.seek(to: p * app.player.duration) }
            Menu("\(String(format: "%g", app.player.rate))×") {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button("\(String(format: "%g", r))×") { app.player.setRate(Float(r)) } }
            }
            .menuStyle(.borderlessButton).frame(width: 56).font(.system(size: 12))
        }
        .padding(.top, 12).padding(.bottom, 4)
        .frame(maxWidth: 600)
        .background(Ink.paper.opacity(0.92))
    }

    private func inspector(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details").font(.system(size: 12, weight: .semibold)).padding(.bottom, 10)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("Source", t.sourceLabel)
                row("Engine", t.model.isEmpty ? "—" : t.model)
                if let l = t.language { row("Language", l.uppercased()) }
                row("Speakers", t.speakers.isEmpty ? "Not identified" : "\(t.speakers.count)")
                row("Words", "\(t.text.split(separator: " ").count)")
                row("Dictionary", t.corrections.filter(\.byDictionary).isEmpty ? "No fixes" : "\(t.corrections.filter(\.byDictionary).count) fixes")
                row("Kept", "On this Mac")
            }
            .font(.system(size: 12.5))

            Divider().padding(.vertical, 16)
            Text("Project").font(.system(size: 12, weight: .semibold)).padding(.bottom, 6)
            Picker("", selection: Binding(get: { t.projectId }, set: { v in app.store.update(t.id) { $0.projectId = v } })) {
                Text("None").tag(UUID?.none)
                ForEach(app.store.projects) { p in Text(p.name).tag(UUID?.some(p.id)) }
            }
            .labelsHidden().controlSize(.small)

            if !t.corrections.isEmpty {
                Divider().padding(.vertical, 16)
                Text("Corrections").font(.system(size: 12, weight: .semibold)).padding(.bottom, 6)
                ForEach(t.corrections.suffix(8)) { c in
                    HStack(spacing: 6) {
                        Text(c.from).strikethrough().foregroundStyle(Ink.mute)
                        Image(systemName: "arrow.right").font(.system(size: 9))
                        Text(c.to).fontWeight(.medium)
                        if c.byDictionary { Image(systemName: "book.closed").font(.system(size: 9)).foregroundStyle(Ink.iris) }
                    }
                    .font(.system(size: 12)).padding(.vertical, 2)
                }
            }

            Divider().padding(.vertical, 16)
            Text("Notes").font(.system(size: 12, weight: .semibold)).padding(.bottom, 6)
            Text("Notes with photos and links arrive in a later build.").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            Spacer()
            Button(role: .destructive) {
                app.go(.home)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { withAnimation(Motion.settle) { app.store.delete(t) } }
            } label: { Label("Delete transcript", systemImage: "trash") }
            .buttonStyle(.plain).foregroundStyle(Ink.mute).font(.system(size: 12.5))
        }
        .padding(.leading, 22)
        .overlay(alignment: .leading) { Ink.hairline.frame(width: 1) }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Ink.mute)
            Text(v).foregroundStyle(Ink.ink).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// One transcript line: timecode, optional speaker, text. Double-click a word to correct it.
struct SegmentLine: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var segment: Segment
    var current: Bool
    var editable: Bool
    @State private var fixing: String? = nil
    @State private var replacement = ""
    @State private var remember = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(segment.start.timecode) { app.player.seek(to: segment.start) }
                .buttonStyle(.plain).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: 0x948C80))
                .frame(width: 52, alignment: .leading).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                if let sp = segment.speaker, let name = transcript.speakerName(sp) {
                    Menu {
                        ForEach(transcript.speakers) { s in Button(s.label) { app.assign(transcript: transcript.id, segment: segment.id, to: s.id) } }
                        Button("No speaker") { app.assign(transcript: transcript.id, segment: segment.id, to: nil) }
                    } label: { Text(name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Ink.mute) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                WrappedWords(text: segment.text) { word in
                    guard editable else { return }
                    fixing = word; replacement = word
                }
                .font(.system(size: 16)).lineSpacing(6).foregroundStyle(Ink.ink)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(current ? Ink.irisTint : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .popover(isPresented: Binding(get: { fixing != nil }, set: { if !$0 { fixing = nil } })) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Heard as").font(.system(size: 11)).foregroundStyle(Ink.mute) + Text("  \(fixing ?? "")").font(.system(size: 13, weight: .semibold))
                        TextField("Correct spelling", text: $replacement).textFieldStyle(.roundedBorder).onSubmit { commit() }
                        Toggle("Remember in Dictionary for future transcripts", isOn: $remember).font(.system(size: 12))
                        HStack { Spacer(); Button("Cancel") { fixing = nil }; Button("Fix") { commit() }.buttonStyle(.borderedProminent).tint(Ink.iris).keyboardShortcut(.defaultAction) }
                    }
                    .padding(14).frame(width: 300)
                }
            }
        }
        .padding(.vertical, 5)
        .animation(Motion.settle, value: current)
    }

    private func commit() {
        guard let from = fixing else { return }
        let to = replacement.trimmingCharacters(in: .whitespaces)
        if !to.isEmpty, to != from { app.correct(transcript: transcript.id, segment: segment.id, from: from, to: to, remember: remember) }
        fixing = nil
    }
}

/// Text that reports which word was double-clicked, without breaking selection or flow.
struct WrappedWords: View {
    var text: String
    var onWord: (String) -> Void
    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .contextMenu {
                ForEach(candidates, id: \.self) { w in Button("Correct “\(w)”…") { onWord(w) } }
            }
            .help("Right-click a line to correct a word")
    }
    /// The first eight distinct words that look like names or unusual spellings, longest first.
    private var candidates: [String] {
        let words = text.split { $0 == " " }.map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { $0.count > 2 }
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }.sorted { $0.count > $1.count }.prefix(8).map { $0 }
    }
}

struct SpeakerChip: View {
    var speaker: Speaker
    var selected: Bool
    var toggle: () -> Void
    var rename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            if editing {
                TextField("Name", text: $draft, onCommit: { rename(draft); editing = false }).textFieldStyle(.plain).frame(width: 90)
                    .onExitCommand { editing = false }
            } else {
                Text(speaker.label).onTapGesture(count: 2) { draft = speaker.name; editing = true }
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? Ink.irisTint : Color(hex: 0xEBE5DB), in: Capsule())
        .foregroundStyle(selected ? Color(hex: 0x3B2FB0) : Ink.ink)
        .onTapGesture { toggle() }
        .help("Double-click to rename")
    }
    private var color: Color {
        let palette = [Ink.iris, Ink.coral, Color(hex: 0x7FB83A), Color(hex: 0x2F9E5B), Color(hex: 0xE0A000)]
        let n = Int(speaker.id.dropFirst()) ?? 1
        return palette[(n - 1) % palette.count]
    }
}

/// The playback track: iris fill, white thumb, click or drag to seek.
struct Scrubber: View {
    var progress: Double
    var onSeek: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0xE8E2D8)).frame(height: 6)
                Capsule().fill(Ink.iris).frame(width: max(6, w * progress), height: 6)
                Circle().fill(.white).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.1)))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: max(0, min(w - 12, w * progress - 6)))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in onSeek(max(0, min(1, v.location.x / w))) })
        }
        .frame(height: 28)
    }
}
