import SwiftUI
import UniformTypeIdentifiers

/// Home, the Listening Desk: welcome card with Verbie, the capture dock as the hero object, then the library.
struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var link = ""
    @State private var fileOver = false
    @FocusState private var linkFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !app.heroDismissed { hero.staggerIn(0) }
                dock.staggerIn(1)
                history
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: app.focusLink) { _, _ in linkFocused = true }
    }

    // MARK: Welcome card

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What did they say?")
                    .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Ink.limeDeep)
                Text("Paste a link, drop a file, or press record. Verbatim keeps the words, spelled your way, with your notes beside them.")
                    .font(.system(size: 14)).foregroundStyle(Color(hex: 0x2F5C0B)).frame(maxWidth: 420, alignment: .leading)
            }
            .padding(.vertical, 22).padding(.leading, 24).padding(.trailing, 160)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(hex: 0xD9F0A6), Ink.lime], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button { withAnimation(Motion.settle) { app.heroDismissed = true } } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.limeDeep)
                    .frame(width: 26, height: 26).background(.white.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain).pressable().padding(10)

            VerbieView(pose: app.verbiePose)
                .frame(width: 96, height: 132)
                .padding(.trailing, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(y: 10)
                .allowsHitTesting(false)
        }
        .tiltCard(tilt: 2.5, lift: 0, radius: 20)
        .shadow(color: Color(hex: 0x3C5A14).opacity(0.14), radius: 14, y: 8)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    // MARK: Capture dock (the hero object)

    private var dock: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: app.fetching == nil ? "link" : "arrow.down.circle").foregroundStyle(Ink.mute)
                if let f = app.fetching {
                    Text(f).font(.system(size: 14)).foregroundStyle(Ink.dim)
                    Spacer()
                    ProgressView().controlSize(.small)
                } else {
                    TextField("Paste a YouTube, Vimeo, or TikTok link", text: $link)
                        .textFieldStyle(.plain).font(.system(size: 14)).focused($linkFocused)
                        .onSubmit { submitLink() }
                    Button("Transcribe") { submitLink() }
                        .buttonStyle(.borderedProminent).tint(Ink.iris).clipShape(Capsule())
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(height: 48)
            .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.black.opacity(0.12)))

            if app.recorder.isRecording {
                RecordPanel().transition(.scale(scale: 0.96).combined(with: .opacity))
            } else if app.capture.isCapturing {
                CapturePanel().transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                HStack(spacing: 10) {
                    SourceTile(title: "Open file", hint: fileOver ? "Drop to transcribe" : "Audio or video, or drop it here",
                               tint: Ink.limeTint, border: Color(hex: 0x5F8C28).opacity(0.45), dashed: true, highlighted: fileOver) {
                        Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(Color(hex: 0x4F7D12))
                    } action: { openFile() }
                    .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }

                    SourceTile(title: "Record voice", hint: "Use your microphone", tint: Ink.coralTint, border: Ink.coral.opacity(0.25)) {
                        RecordButton(size: 40)
                    } action: { app.requestRecord() }

                    SourceTile(title: "Capture app", hint: "Zoom, Safari, FaceTime…", tint: Ink.irisTint, border: Ink.iris.opacity(0.2)) {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 20)).foregroundStyle(Color(hex: 0x5A46D6))
                    } action: { app.pickApp() }
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Color(hex: 0xFFFDF9), Color(hex: 0xF5EFE6)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0x503CB4).opacity(fileOver ? 0.4 : 0.12), lineWidth: 1.5))
        .shadow(color: Color(hex: 0x3C328C).opacity(0.12), radius: 15, y: 7)
        .tiltCard(tilt: 1.8, lift: 0, radius: 18)
        .animation(Motion.settle, value: app.recorder.isRecording)
        .animation(Motion.settle, value: app.capture.isCapturing)
        .animation(Motion.settle, value: fileOver)
    }

    private func submitLink() {
        let l = link.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return }
        app.transcribeLink(l)
        link = ""
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff, .quickTimeMovie, UTType("public.mpeg-4-audio") ?? .audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.forEach { app.importFile($0) } }
    }

    // MARK: Library

    private var history: some View {
        let groups = Store.group(app.filtered)
        return VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty { emptyState }
            ForEach(Array(groups.enumerated()), id: \.element.label) { gi, g in
                Text(g.label).font(.system(size: 12)).foregroundStyle(Ink.mute).padding(.leading, 16).padding(.top, 26).padding(.bottom, 6)
                    .staggerIn(2 + gi * 3)
                ForEach(Array(g.items.enumerated()), id: \.element.id) { ii, t in
                    HistoryRow(transcript: t, open: { app.go(.transcript(t.id)) })
                        .staggerIn(3 + gi * 3 + ii)
                        .contextMenu {
                            Button("Open") { app.go(.transcript(t.id)) }
                            Button(t.pinned ? "Unpin" : "Pin") { app.store.update(t.id) { $0.pinned.toggle() } }
                            if !app.store.projects.isEmpty {
                                Menu("Move to project") {
                                    Button("No project") { app.store.update(t.id) { $0.projectId = nil } }
                                    ForEach(app.store.projects) { p in Button(p.name) { app.store.update(t.id) { $0.projectId = p.id } } }
                                }
                            }
                            if t.status == .failed { Button("Retry") { app.retry(t) } }
                            Divider()
                            Button("Delete", role: .destructive) { withAnimation(Motion.settle) { app.store.delete(t) } }
                        }
                }
            }
        }
        .animation(Motion.settle, value: app.filtered.map(\.id))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if !app.search.isEmpty {
                VerbieView(pose: .nothing).frame(width: 100, height: 130)
                Text("Nothing found for “\(app.search)”").font(.system(size: 15, weight: .semibold))
                Text("Try another word. Search looks at titles and every transcript's text.").font(.system(size: 13)).foregroundStyle(Ink.mute)
            } else if app.heroDismissed {
                VerbieView(pose: app.verbiePose).frame(width: 100, height: 130)
                Text(app.projectFilter == nil ? "Your transcripts will collect here" : "Nothing in this project yet").font(.system(size: 15, weight: .semibold))
                Text("Paste a link, drop a file, or press record. Transcripts stay on this Mac.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).multilineTextAlignment(.center).frame(maxWidth: 360)
            } else {
                Text("Your transcripts will collect here.").font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }
}

struct SourceTile<Icon: View>: View {
    var title: String
    var hint: String
    var tint: Color
    var border: Color
    var dashed = false
    var highlighted = false
    @ViewBuilder var icon: () -> Icon
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon().frame(width: 40, height: 40)
                    .rotationEffect(.degrees(hover ? -6 : 0))
                    .offset(y: hover ? -2 : 0)
                    .animation(Motion.bounce, value: hover)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.ink)
                    Text(hint).font(.system(size: 12)).foregroundStyle(Ink.mute)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 68)
            .background(highlighted ? Color(hex: 0xE4F3C4) : tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(border, style: StrokeStyle(lineWidth: 1.5, dash: dashed && !highlighted ? [4, 3] : [])))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .pressable()
        .onHover { hover = $0 }
        .tiltCard(tilt: 9, lift: 3, radius: 12)
        .scaleEffect(highlighted ? 1.04 : 1)
        .animation(Motion.bounce, value: highlighted)
    }
}

struct RecordButton: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: 0xFFA48F), Ink.coral, Color(hex: 0xF06A4A)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 4))
                .shadow(color: Color(hex: 0x5B261D).opacity(0.22), radius: 3, y: 3)
            Circle().fill(.white).frame(width: size * 0.3, height: size * 0.3)
        }
        .frame(width: size, height: size)
    }
}

struct RecordPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 14) {
            VerbieView(pose: app.verbiePose, tracksPointer: false).frame(width: 36, height: 48)
            Text(app.recorder.isPaused ? "Paused" : "Recording").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.dim).frame(width: 64, alignment: .leading)
            Text(app.recorder.elapsed.timecode).font(.system(size: 13, design: .monospaced)).frame(minWidth: 56, alignment: .leading)
            Meter(levels: app.recorder.levels, frozen: app.recorder.isPaused).frame(height: 22).frame(maxWidth: .infinity, alignment: .leading)
            Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }.buttonStyle(.bordered)
            Button("Stop") { app.stopRecording() }.buttonStyle(.borderedProminent).tint(Ink.ink).keyboardShortcut(".", modifiers: [.option, .shift])
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.1)))
    }
}

struct CapturePanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 14) {
            VerbieView(pose: .listening, tracksPointer: false).frame(width: 36, height: 48)
            Text("Capturing \(app.capture.appName)").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.dim).lineLimit(1)
            Text(app.capture.elapsed.timecode).font(.system(size: 13, design: .monospaced)).frame(minWidth: 56, alignment: .leading)
            Meter(levels: app.capture.levels, color: NSColor(red: 0x6F/255, green: 0x5A/255, blue: 0xF0/255, alpha: 1)).frame(height: 22).frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop") { app.stopCapture() }.buttonStyle(.borderedProminent).tint(Ink.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.1)))
    }
}

struct HistoryRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(badgeColor)
                    Image(systemName: transcript.source.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if transcript.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.mute) }
                        Text(transcript.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                    }
                    Text(transcript.preview).font(.system(size: 13)).lineSpacing(3)
                        .foregroundStyle(transcript.status == .failed ? Ink.coral : Color(hex: 0x55504A))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        Text(transcript.sourceLabel)
                        if !transcript.speakers.isEmpty { Text("\(transcript.speakers.count) speakers") }
                        if !transcript.corrections.isEmpty { Text("\(transcript.corrections.count) fixes") }
                        if transcript.status == .processing { ProgressView().controlSize(.mini) }
                        if transcript.status == .failed { Button("Retry") { app.retry(transcript) }.buttonStyle(.link).font(.system(size: 12)) }
                    }
                    .font(.system(size: 12)).foregroundStyle(Ink.mute).padding(.top, 3)
                }
                Spacer(minLength: 8)
                Text(transcript.duration.timecode).font(.system(size: 12.5)).foregroundStyle(Ink.mute).monospacedDigit().padding(.top, 2)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(hover ? Color(hex: 0xF1ECE3) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .pressable()
        .onHover { hover = $0 }
        .tiltCard(tilt: 3.5, lift: 1, radius: 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var badgeColor: Color {
        switch transcript.source {
        case .voiceMemo: return Ink.coral
        case .link: return Ink.iris
        case .file: return Color(hex: 0x524D47)
        case .app: return Color(hex: 0x2F9E5B)
        }
    }
}
