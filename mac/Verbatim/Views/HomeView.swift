import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Home, editorial: a serif invitation, one glass capture toolbar, and recent notes shown as notes, not rows.
/// Glass is for the controls; the note cards are paper.
struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Make room for\nyour thoughts.").font(Ink.serif(46, weight: .regular)).foregroundStyle(Ink.ink).lineSpacing(-4)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("A place for everything you think out loud.").font(.system(size: 16.5)).foregroundStyle(Ink.dim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VerbieView(pose: verbiePose).frame(width: 104, height: 150).padding(.trailing, 18).padding(.top, -6).allowsHitTesting(false)
                }
                .padding(.top, 26).staggerIn(0)

                Group {
                    if app.recorder.isRecording { RecordPanel() }
                    else if app.capture.isCapturing { CapturePanel() }
                    else { CaptureBar() }
                }
                .padding(.top, 22).staggerIn(1)
                .animation(Motion.settle, value: app.recorder.isRecording)
                .animation(Motion.settle, value: app.capture.isCapturing)
                if app.captureMode == "dictate" && !app.recorder.isRecording && !app.capture.isCapturing {
                    // Dictate's details drop down under the toolbar; click Dictate again (or ×) to close.
                    HStack(alignment: .top) {
                        DictateControls()
                        Spacer()
                        Button { withAnimation(Motion.settle) { app.captureMode = "voice" } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain).hoverChip(radius: 13).help("Close")
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.iris.opacity(0.18)))
                    .padding(.top, 10)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .identity))
                }

                Rectangle().fill(Ink.hairline).frame(height: 1).padding(.top, 24)
                RecentNotes().padding(.top, 16).staggerIn(2)
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 40).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private var verbiePose: VerbiePose {
        if app.recorder.isRecording || app.capture.isCapturing || app.dictation.isListening { return app.recorder.isPaused ? .paused : .listening }
        return app.verbiePose
    }
}

// MARK: - Capture toolbar (glass)

struct CaptureBar: View {
    @EnvironmentObject var app: AppState
    @State private var importOpen = false
    @State private var fileOver = false
    @State private var mic: AudioDevices.Device? = AudioDevices.current()

    var body: some View {
        HStack(spacing: 0) {
            CaptureSegment(action: { app.requestRecord() }) {
                RecordDot(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice note").font(.system(size: 16, weight: .medium)).fixedSize()
                    HStack(spacing: 4) {
                        Image(systemName: mic?.symbol ?? "mic").font(.system(size: 10.5))
                        Text(mic?.name ?? "Microphone").lineLimit(1)
                    }
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                    .help("Recording from \(mic?.name ?? "the system default"). Change it in Settings › General.")
                }
            }
            .uiTarget("tile-record")
            divider
            CaptureSegment(highlighted: app.captureMode == "dictate", action: { withAnimation(Motion.settle) { app.captureMode = app.captureMode == "dictate" ? "voice" : "dictate" } }) {
                Image(systemName: "keyboard").font(.system(size: 24, weight: .regular)).foregroundStyle(Ink.irisDeep).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictate").font(.system(size: 16, weight: .medium)).fixedSize()
                    Text(app.dictation.accessibilityTrusted ? app.dictation.hotkey.title.replacingOccurrences(of: "Hold ", with: "Hold ") : "Needs Accessibility").font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
                }
            }
            .uiTarget("mode-dictate")
            divider
            CaptureSegment(highlighted: fileOver, action: { importOpen = true }) {
                Image(systemName: "doc.badge.plus").font(.system(size: 22, weight: .regular)).foregroundStyle(Ink.ink).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import").font(.system(size: 16, weight: .medium)).fixedSize()
                    Text(fileOver ? "Drop to transcribe" : "File or link").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                }
            }
            .popover(isPresented: $importOpen, arrowEdge: .bottom) { ImportPanel(done: { importOpen = false }) }
            divider
            CaptureSegment(action: { app.pickApp() }) {
                Image(systemName: "speaker.wave.2").font(.system(size: 21, weight: .regular)).foregroundStyle(Ink.ink).frame(width: 36)
                Text("App audio").font(.system(size: 16, weight: .medium)).fixedSize()
            }
            .uiTarget("tile-app")
        }
        .padding(8)
        .frame(height: 82)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Ink.glassTint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Ink.ink.opacity(0.07)))
        .shadow(color: Ink.ink.opacity(0.06), radius: 12, y: 4)
        .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }
        .onChange(of: app.focusLink) { _, _ in importOpen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in mic = AudioDevices.current() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in let m = AudioDevices.current(); if m != mic { mic = m } }
    }

    private var divider: some View { Rectangle().fill(Ink.hairline).frame(width: 1, height: 34) }
}

/// One section of the capture toolbar: local tint on hover, slight compression on press.
struct CaptureSegment<Content: View>: View {
    var highlighted = false
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    @GestureState private var pressed = false

    var body: some View {
        HStack(spacing: 12) { content() }
            .foregroundStyle(Ink.ink)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Ink.iris.opacity(highlighted ? 0.12 : pressed ? 0.10 : hover ? 0.055 : 0)))
            .scaleEffect(pressed ? 0.985 : 1)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = true }.onEnded { v in
                if abs(v.translation.width) < 8 && abs(v.translation.height) < 8 { action() }
            })
            .animation(Motion.touch, value: hover)
            .animation(Motion.touch, value: pressed)
    }
}

/// The coral record dot: deepens on hover, compresses on press (handled by the segment).
struct RecordDot: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: 0xFF9278), Ink.coral, Color(hex: 0xF06A4A)], center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0, endRadius: size * 0.62))
                .shadow(color: Color(hex: 0xF06A4A).opacity(0.3), radius: 4, y: 2)
            Circle().fill(.white).frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
    }
}

/// Import a file or paste a link.
struct ImportPanel: View {
    @EnvironmentObject var app: AppState
    var done: () -> Void
    @State private var link = ""
    @State private var keepVideo = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import").font(.system(size: 14, weight: .bold))
            Button { done(); openFile() } label: { Label("Choose files or a folder…", systemImage: "doc.on.doc") }
                .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
            Text("Or paste a link").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("https://…", text: $link).textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit)
                Button("Fetch", action: submit).buttonStyle(.borderedProminent).tint(Ink.iris).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle("Also keep the video (MP4)", isOn: $keepVideo).toggleStyle(.checkbox).font(.system(size: 12.5))
            Text(keepVideo ? "Saved to \(Keep.folder.lastPathComponent) in \(Keep.folder.deletingLastPathComponent().lastPathComponent), up to 1080p. Keep only what you have the right to save." : "YouTube, Vimeo, podcasts, and most video pages. Only the audio is downloaded.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 360)
        .onAppear {
            keepVideo = app.keepVideoByDefault
            if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") { link = s }
            focused = true
        }
    }
    private func submit() {
        let l = link.trimmingCharacters(in: .whitespaces); guard !l.isEmpty else { return }
        app.transcribeLink(l, keepVideo: keepVideo); done()
    }
    private func openFile() { app.chooseFiles() }
}

// MARK: - Recent notes

struct RecentNotes: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let items = Array(app.filtered.prefix(3))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent notes").font(Ink.serif(26, weight: .regular)).foregroundStyle(Ink.ink)
                    Capsule().fill(Ink.coral).frame(width: 44, height: 5).padding(.leading, 12)
                }
                Spacer()
                HStack(spacing: 4) { Text("View library"); Image(systemName: "arrow.right") }
                    .font(.system(size: 14)).foregroundStyle(Ink.iris)
                    .tapArea { app.go(.library) }
            }
            .padding(.bottom, 14)
            if items.isEmpty {
                empty
            } else {
                // Side by side when there's room; one column in a narrow window.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        FeaturedNote(transcript: items[0]).uiTarget("row-0").frame(minWidth: 460, maxWidth: .infinity)
                        if items.count > 1 { sideColumn(items).frame(width: 320) }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        FeaturedNote(transcript: items[0]).uiTarget("row-0")
                        if items.count > 1 {
                            HStack(alignment: .top, spacing: 16) { ForEach(items.dropFirst()) { t in NoteTile(transcript: t).frame(maxWidth: .infinity) } }
                        }
                    }
                }
            }
        }
        .animation(Motion.settle, value: items.map(\.id))
    }

    private func sideColumn(_ items: [Transcript]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(items.dropFirst()) { t in NoteTile(transcript: t) }
            Text("Say it. Keep it.").font(Ink.serif(17, weight: .regular)).foregroundStyle(Ink.mute).padding(.leading, 4).padding(.top, 2)
        }
    }

    private var empty: some View {
        HStack(spacing: 16) {
            VerbieView(pose: app.search.isEmpty ? .ready : .nothing, tracksPointer: false).frame(width: 54, height: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.search.isEmpty ? "Nothing kept yet" : "Nothing found for “\(app.search)”").font(Ink.serif(20, weight: .regular))
                Text(app.search.isEmpty ? "Record a voice note, dictate, or import a file. It lands here." : "Search looks at titles and every transcript's text.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.mute)
            }
            Spacer()
        }
        .padding(20)
        .background(NoteCardBackground(hover: false))
    }
}

/// Paper card surface: opaque, warm white, a fine border that strengthens on hover.
struct NoteCardBackground: View {
    var hover: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hover ? Ink.cardHover : Ink.card)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.ink.opacity(hover ? 0.16 : 0.09)))
    }
}

/// The newest note, shown as a note: title, the passage you saved (or its opening), your note, and a player.
struct FeaturedNote: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var hover = false

    private var savedSegment: Segment? {
        let ids = transcript.notes.filter(\.isBookmark).compactMap(\.segmentId)
        return transcript.segments.first { ids.contains($0.id) }
    }
    private var quoteSegment: Segment? { savedSegment ?? transcript.segments.first }
    private var linkedNote: Note? { transcript.notes.first { !$0.isBookmark } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcript.title).font(Ink.serif(24, weight: .regular)).foregroundStyle(Ink.ink).lineLimit(2)
                    Text(meta(transcript)).font(.system(size: 13.5)).foregroundStyle(Ink.mute)
                }
                Spacer()
                RowMenuButton(transcript: transcript)
            }
            if transcript.status == .ready, let q = quoteSegment {
                quote(q).padding(.top, 14)
                Text(q.start.timecode).font(.system(size: 14)).foregroundStyle(Ink.iris).padding(.top, 6)
                    .tapArea { app.go(.transcript(transcript.id)); app.player.seek(to: q.start) }
            } else {
                Text(transcript.preview).font(.system(size: 14)).foregroundStyle(transcript.status == .failed ? Ink.coral : Ink.dim).lineLimit(2).padding(.top, 12)
            }
            if let n = linkedNote {
                Rectangle().fill(Ink.hairline).frame(height: 1).padding(.top, 12)
                HStack(spacing: 10) {
                    Image(systemName: "note.text").foregroundStyle(Ink.dim)
                    Text(n.text).font(.system(size: 13.5)).foregroundStyle(Ink.dim).lineLimit(1)
                }
                .padding(.top, 10)
            }
            if transcript.audioFileName != nil, transcript.status == .ready {
                MiniPlayer(transcript: transcript, clock: app.player.clock).padding(.top, 12)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(NoteCardBackground(hover: hover))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .onTapGesture { app.go(.transcript(transcript.id)) }
        .onDrag { NSItemProvider(object: TranscriptDrag.payload([transcript.id]) as NSString) }
        .contextMenu { RowMenu(transcript: transcript) }
    }

    private func quote(_ s: Segment) -> some View {
        let saved = savedSegment?.id == s.id
        return Text(s.text).font(.system(size: 20)).foregroundStyle(Ink.ink).lineSpacing(3).lineLimit(3)
            .padding(.horizontal, saved ? 6 : 0).padding(.vertical, saved ? 2 : 0)
            .background(saved ? Ink.saved : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help(saved ? "Saved passage" : "")
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @ObservedObject var clock: PlayerClock
    private var url: URL? { app.store.audioURL(for: transcript) }
    private var loaded: Bool { url != nil && app.player.loadedURL == url }

    var body: some View {
        let total = max(transcript.duration, 0.1)
        let t = loaded ? clock.time : 0
        HStack(spacing: 14) {
            Button {
                if let u = url { app.player.load(u) }
                app.player.toggle()
            } label: {
                Image(systemName: loaded && app.player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(Ink.ink)
                    .frame(width: 38, height: 38).background(Circle().fill(Ink.card)).overlay(Circle().strokeBorder(Ink.hairline))
            }
            .buttonStyle(PressStyle(scale: 0.92)).help("Play")
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.track).frame(height: 5)
                    Capsule().fill(LinearGradient(colors: [Color(hex: 0x8C78FF), Ink.iris], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(5, g.size.width * t / total), height: 5)
                    Circle().fill(Ink.card).overlay(Circle().strokeBorder(Ink.iris, lineWidth: 2)).frame(width: 15, height: 15)
                        .offset(x: max(0, g.size.width * t / total - 7.5))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    if let u = url { app.player.load(u) }
                    app.player.seek(to: max(0, min(1, v.location.x / g.size.width)) * total)
                })
            }
            .frame(height: 20)
            Text("\(t.timecode) / \(transcript.duration.timecode)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Ink.dim).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.hairline))
    }
}

/// A smaller note card: serif title, meta, your first note or the opening line; ribbon if bookmarked.
struct NoteTile: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(transcript.title).font(Ink.serif(20, weight: .regular)).foregroundStyle(Ink.ink).lineLimit(2)
                Spacer(minLength: 34)
                RowMenuButton(transcript: transcript)
            }
            Text(meta(transcript, short: true)).font(.system(size: 13)).foregroundStyle(Ink.mute)
            Text(transcript.notes.first(where: { !$0.isBookmark })?.text ?? transcript.preview)
                .font(.system(size: 14)).foregroundStyle(transcript.status == .failed ? Ink.coral : Ink.dim).lineLimit(2).padding(.top, 4)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(NoteCardBackground(hover: hover))
        .overlay(alignment: .topTrailing) {
            if transcript.notes.contains(where: \.isBookmark) || transcript.pinned {
                Ribbon().fill(Color(hex: 0x8C78FF)).frame(width: 16, height: 22).padding(.trailing, 54).offset(y: -1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .onTapGesture { app.go(.transcript(transcript.id)) }
        .onDrag { NSItemProvider(object: TranscriptDrag.payload([transcript.id]) as NSString) }
        .contextMenu { RowMenu(transcript: transcript) }
    }
}

struct Ribbon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.25)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        return p
    }
}

struct RowMenuButton: View {
    var transcript: Transcript
    var body: some View {
        Menu { RowMenu(transcript: transcript) } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.ink).frame(width: 30, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverChip()
    }
}

func meta(_ t: Transcript, short: Bool = false) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    let day: String
    if cal.isDateInToday(t.createdAt) { day = "Today" }
    else if cal.isDateInYesterday(t.createdAt) { day = "Yesterday" }
    else if let d = cal.dateComponents([.day], from: t.createdAt, to: Date()).day, d < 7 { f.dateFormat = "EEEE"; day = f.string(from: t.createdAt) }
    else { f.dateFormat = "MMM d"; day = f.string(from: t.createdAt) }
    var parts = [day]
    if !short { parts.append(t.source == .dictation ? "Dictation" : t.source == .voiceMemo ? "Voice note" : t.sourceLabel) }
    parts.append(t.duration.timecode)
    if !short, t.speakers.count >= 2 { parts.append("\(t.speakers.count) speakers") }
    return parts.joined(separator: " · ")
}


/// Which microphone: an icon for the transport, the device name, and a menu to switch. Lives on the capture card
/// and in Settings so you always know where the audio comes from.
struct MicSourceMenu: View {
    var status: String = ""
    @State private var devices: [AudioDevices.Device] = []
    @State private var current: AudioDevices.Device? = nil
    @State private var selectedUID: String? = AudioDevices.selectedUID

    var body: some View {
        Menu {
            Button { choose(nil) } label: { Label("System default" + (AudioDevices.defaultInput().map { " (\($0.name))" } ?? ""), systemImage: selectedUID == nil ? "checkmark" : "") }
            Divider()
            ForEach(devices) { d in
                Button { choose(AudioDevices.deviceUID(d.id)) } label: {
                    Label(d.name, systemImage: selectedUID == AudioDevices.deviceUID(d.id) ? "checkmark" : d.symbol)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: current?.symbol ?? "mic.slash").font(.system(size: 11.5, weight: .semibold))
                Text(current?.name ?? status).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 13)).foregroundStyle(Ink.dim)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Which microphone Verbatim records from")
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() { devices = AudioDevices.inputs(); current = AudioDevices.current() }
    private func choose(_ uid: String?) { AudioDevices.selectedUID = uid; selectedUID = uid; refresh() }
}

struct DictateControls: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if app.dictation.accessibilityTrusted {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard").font(.system(size: 18)).foregroundStyle(Ink.iris)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.dictation.hotkey.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.ink)
                        Text(app.dictation.enabled ? "Ready in every app. Change the key in Settings › Dictate." : "Dictation is off. Turn it on in Settings › Dictate.").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    }
                }
                
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").font(.system(size: 18)).foregroundStyle(Ink.coral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs Accessibility access").font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.ink)
                        Text("To hear the key and paste into other apps. Verbatim reads nothing from them.").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    }
                    Spacer()
                    Button("Allow") { app.dictation.requestAccessibility(); app.dictation.openAccessibilitySettings() }.buttonStyle(.borderedProminent).tint(Ink.iris)
                }
                
            }
            if let last = app.dictation.lastResult, !last.isEmpty {
                HStack(spacing: 8) {
                    Text("Last: “\(last.prefix(70))\(last.count > 70 ? "…" : "")”").font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(1)
                    Button("Copy") { app.dictation.copyLast() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.iris)
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

// MARK: - Shared pieces

struct RecordButton: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: 0xFFA48F), Ink.coral, Color(hex: 0xF06A4A)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: size > 60 ? 6 : 4))
                .shadow(color: Color(hex: 0x5B261D).opacity(0.25), radius: size > 60 ? 10 : 3, y: size > 60 ? 6 : 3)
            Image(systemName: "mic.fill").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct RecordPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 16) {
            ZStack { Circle().fill(Ink.coral).frame(width: 12, height: 12); Circle().stroke(Ink.coral.opacity(0.35), lineWidth: 3).frame(width: 22, height: 22) }
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.recorder.isPaused ? "Paused" : "Recording").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                MicSourceMenu(status: "Microphone").environment(\.colorScheme, .light)
            }
            .frame(width: 170, alignment: .leading)
            LiveReadout(live: app.recorder.live, frozen: app.recorder.isPaused)
            Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }.buttonStyle(.bordered).controlSize(.large)
            Button("Stop") { app.stopRecording() }.buttonStyle(.borderedProminent).tint(Ink.coral).controlSize(.large).keyboardShortcut(".", modifiers: [.option, .shift])
        }
        .padding(.horizontal, 16)
        .frame(height: 82)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Ink.glassTint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Ink.coral.opacity(0.35)))
        .shadow(color: Ink.ink.opacity(0.06), radius: 12, y: 4)
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .identity))
    }
}

struct CapturePanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "speaker.wave.2").font(.system(size: 18)).foregroundStyle(Ink.iris).padding(.leading, 8)
            Text("Capturing \(app.capture.appName)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1).frame(width: 170, alignment: .leading)
            LiveReadout(live: app.capture.live, color: NSColor(red: 0x6F/255, green: 0x5A/255, blue: 0xF0/255, alpha: 1))
            Button("Stop") { app.stopCapture() }.buttonStyle(.borderedProminent).tint(Ink.ink).controlSize(.large)
        }
        .padding(.horizontal, 16)
        .frame(height: 82)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Ink.iris.opacity(0.3)))
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .identity))
    }
}

/// Static waveform thumbnail from the stored envelope. A Shape, so it costs nothing after layout.
struct WaveformThumb: Shape {
    var values: [Float]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard !values.isEmpty else { return p }
        let n = values.count
        let step = r.width / CGFloat(n)
        let bw = max(1.5, step * 0.55)
        for (i, v) in values.enumerated() {
            let h = max(2, CGFloat(v) * r.height)
            let x = r.minX + CGFloat(i) * step + (step - bw) / 2
            p.addRoundedRect(in: CGRect(x: x, y: r.midY - h / 2, width: bw, height: h), cornerSize: CGSize(width: bw / 2, height: bw / 2))
        }
        return p
    }
}

struct HistoryRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    /// nil = not selecting; true/false = selection mode with this row's state.
    var selected: Bool? = nil
    /// The IDs a drag of this row carries (the whole selection when this row is part of it).
    var dragIDs: (() -> [UUID])? = nil
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        CardButton(tilt: 1, lift: 1, radius: 14, dragPayload: { TranscriptDrag.payload(dragIDs?() ?? [transcript.id]) }, action: open) {
            HStack(spacing: 14) {
                if let sel = selected {
                    Image(systemName: sel ? "checkmark.circle.fill" : "circle").font(.system(size: 19)).foregroundStyle(sel ? Ink.iris : Ink.mute)
                }
                Image(systemName: transcript.source.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(tileFg)
                    .frame(width: 48, height: 48).background(tileBg, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if transcript.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.mute) }
                        Text(transcript.title).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1).layoutPriority(1)
                    }
                    HStack(spacing: 6) {
                        Text(transcript.sourceLabel)
                        Text("·"); Text(transcript.duration.timecode)
                        if !transcript.speakers.isEmpty { Text("·"); Text("\(transcript.speakers.count) speakers") }
                        if transcript.status == .processing { Text("·"); Text(transcript.stage ?? "Transcribing").foregroundStyle(Ink.iris); ProgressView().controlSize(.mini) }
                        if transcript.status == .failed { Text("·"); Text("Needs retry").foregroundStyle(Ink.coral) }
                    }
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 10)
                WaveformThumb(values: transcript.waveform.isEmpty ? placeholder : Waveform.resample(transcript.waveform, to: 32))
                    .fill(waveColor).frame(width: 120, height: 24)
                Text(dateLine).font(.system(size: 13)).foregroundStyle(Ink.mute).frame(width: 96, alignment: .trailing).lineLimit(1)
                Color.clear.frame(width: 30, height: 28)   // room for the ⋯ menu, which sits above the click layer
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(selected == true ? Ink.irisTint.opacity(0.6) : hover ? Ink.cardHover : Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected == true ? Ink.iris.opacity(0.5) : Ink.ink.opacity(hover ? 0.14 : 0.07)))
        }
        .overlay(alignment: .trailing) {
            if selected == nil { RowMenuButton(transcript: transcript).padding(.trailing, 12) }
        }
        .onHover { hover = $0 }
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .identity))
    }

    private var placeholder: [Float] { (0..<48).map { _ in Float.random(in: 0.08...0.25) } }
    private var tileBg: Color { switch transcript.source { case .voiceMemo, .dictation: return Ink.coralTint; case .app: return Ink.limeTint; default: return Ink.irisTint } }
    private var tileFg: Color { switch transcript.source { case .voiceMemo, .dictation: return Ink.coral; case .app: return Ink.limeText; default: return Ink.iris } }
    private var waveColor: Color { transcript.source == .voiceMemo || transcript.source == .dictation ? Ink.coral.opacity(0.85) : Ink.iris.opacity(0.75) }
    private var dateLine: String {
        let f = DateFormatter(); let cal = Calendar.current
        if cal.isDateInToday(transcript.createdAt) { return "Today" }
        else if cal.isDateInYesterday(transcript.createdAt) { return "Yesterday" }
        else if cal.isDate(transcript.createdAt, equalTo: Date(), toGranularity: .year) { f.dateFormat = "MMM d" }
        else { f.dateFormat = "MMM d, yyyy" }
        return f.string(from: transcript.createdAt)
    }
}

/// Keep video (links) and Keep audio, or Show in Finder once kept.
struct KeepMenuItems: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var body: some View {
        if let busy = app.keeping[transcript.id] {
            Button(busy) {}.disabled(true)
        } else if let v = transcript.keptVideo, FileManager.default.fileExists(atPath: v) {
            Button("Show video in Finder") { app.showKept(v) }
        } else if transcript.linkInfo != nil {
            Button("Keep video (MP4)") { app.keepVideo(transcript.id) }
        }
        if let a = transcript.keptAudio, FileManager.default.fileExists(atPath: a) {
            Button("Show audio in Finder") { app.showKept(a) }
        } else if transcript.audioFileName != nil {
            Button("Keep audio (\((transcript.audioFileName.map { URL(fileURLWithPath: $0).pathExtension.uppercased() }) ?? "M4A"))") { app.keepAudio(transcript.id) }
        }
    }
}

struct RowMenu: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var body: some View {
        Button("Open") { app.go(.transcript(transcript.id)) }
        Button(transcript.pinned ? "Unpin" : "Pin") { app.store.update(transcript.id) { $0.pinned.toggle() } }
        if !app.store.projects.isEmpty {
            Menu("Move to project") {
                Button("No project") { app.store.update(transcript.id) { $0.projectId = nil } }
                ForEach(app.store.projects) { p in Button(p.name) { app.store.update(transcript.id) { $0.projectId = p.id } } }
            }
        }
        if transcript.status == .failed { Button("Retry transcription") { app.retry(transcript) } }
        if transcript.status == .processing { Button("Cancel transcription") { app.cancel(transcript.id) } }
        Divider()
        KeepMenuItems(transcript: transcript)
        Divider()
        Button("Delete", role: .destructive) { app.delete([transcript.id]) }
    }
}
