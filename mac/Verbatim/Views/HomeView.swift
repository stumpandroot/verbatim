import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var link = ""
    @State private var fileOver = false
    @FocusState private var linkFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !app.heroDismissed { hero }
                dock
                history
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: app.focusLink) { _, _ in linkFocused = true }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What did they say?")
                    .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Ink.limeDeep)
                Text("Paste a link, drop a file, or press record. Verbatim keeps the words, spelled your way, with your notes beside them.")
                    .font(.system(size: 14)).foregroundStyle(Color(hex: 0x2F5C0B)).frame(maxWidth: 420, alignment: .leading)
            }
            .padding(.vertical, 22).padding(.leading, 24).padding(.trailing, 150)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(hex: 0xD9F0A6), Ink.lime], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button { withAnimation(Motion.settle) { app.heroDismissed = true } } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.limeDeep)
                    .frame(width: 26, height: 26).background(.white.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain).padding(10)

            VerbieView(pose: app.verbiePose)
                .frame(width: 128, height: 128)
                .padding(.trailing, 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(y: 8)
                .allowsHitTesting(false)
        }
        .tiltCard(tilt: 2.5, lift: 0, radius: 20)
        .shadow(color: Color(hex: 0x3C5A14).opacity(0.14), radius: 14, y: 8)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    // MARK: Capture dock

    private var dock: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(Ink.mute)
                TextField("Paste a YouTube, Vimeo, or TikTok link (next build)", text: $link)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($linkFocused)
                Button("Transcribe") { app.toast = Toast("Links arrive in the next build. Record or drop a file for now.") }
                    .buttonStyle(.borderedProminent).tint(Ink.iris).clipShape(Capsule())
                    .disabled(link.isEmpty)
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(height: 48)
            .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.black.opacity(0.12)))

            if app.recorder.isRecording {
                RecordPanel().transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                HStack(spacing: 10) {
                    SourceTile(title: "Open file", hint: fileOver ? "Drop to transcribe" : "Audio or video, or drop it here", tint: Ink.limeTint,
                               border: Color(hex: 0x5F8C28).opacity(0.45), dashed: true, highlighted: fileOver) {
                        Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(Color(hex: 0x4F7D12))
                    } action: { openFile() }
                    .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }

                    SourceTile(title: "Record voice", hint: "Use your microphone", tint: Ink.coralTint, border: Ink.coral.opacity(0.25)) {
                        RecordButton(size: 40)
                    } action: { app.requestRecord() }

                    SourceTile(title: "Capture app", hint: "Next build", tint: Ink.irisTint, border: Ink.iris.opacity(0.2)) {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 20)).foregroundStyle(Color(hex: 0x5A46D6))
                    } action: { app.toast = Toast("App audio capture arrives in a later build.") }
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Color(hex: 0xFFFDF9), Color(hex: 0xF5EFE6)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0x503CB4).opacity(0.12), lineWidth: 1.5))
        .shadow(color: Color(hex: 0x3C328C).opacity(0.12), radius: 15, y: 7)
        .tiltCard(tilt: 1.8, lift: 0, radius: 18)
        .animation(Motion.settle, value: app.recorder.isRecording)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff, .quickTimeMovie, UTType("public.mpeg-4-audio") ?? .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { app.importFile(url) }
    }

    // MARK: History

    private var history: some View {
        let groups = Store.group(app.filtered)
        return VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                VStack(spacing: 10) {
                    VerbieView(pose: app.search.isEmpty ? .ready : .nothing).frame(width: 110, height: 120)
                    if app.search.isEmpty {
                        Text("Your transcripts will collect here.").font(.system(size: 13)).foregroundStyle(Ink.mute)
                    } else {
                        Text("Nothing found for “\(app.search)”. Try another word.").font(.system(size: 13)).foregroundStyle(Ink.mute)
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 40)
            }
            ForEach(groups, id: \.label) { g in
                Text(g.label).font(.system(size: 12)).foregroundStyle(Ink.mute).padding(.leading, 16).padding(.top, 26).padding(.bottom, 6)
                ForEach(g.items) { t in
                    HistoryRow(transcript: t) { app.go(.transcript(t.id)) }
                        .contextMenu {
                            Button("Open") { app.go(.transcript(t.id)) }
                            Button("Delete", role: .destructive) { withAnimation(Motion.settle) { app.store.delete(t) } }
                        }
                }
            }
        }
        .animation(Motion.settle, value: app.filtered.map(\.id))
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon().frame(width: 40, height: 40)
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
            RecordButton(size: 28)
            Text("Microphone").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            Text(app.recorder.elapsed.timecode).font(.system(size: 13, design: .monospaced)).frame(minWidth: 64, alignment: .leading)
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(app.recorder.levels.enumerated()), id: \.offset) { _, v in
                    Capsule().fill(Ink.coral).frame(width: 3, height: max(3, CGFloat(v) * 22))
                }
            }
            .frame(height: 22).frame(maxWidth: .infinity, alignment: .leading)
            .animation(.linear(duration: 0.1), value: app.recorder.levels)
            Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }.buttonStyle(.bordered)
            Button("Stop") { app.stopRecording() }.buttonStyle(.borderedProminent).tint(Ink.ink).keyboardShortcut(".", modifiers: [.option, .shift])
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.1)))
    }
}

struct HistoryRow: View {
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
                    Text(transcript.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                    Text(transcript.preview).font(.system(size: 13)).foregroundStyle(transcript.status == .failed ? Ink.coral : Color(hex: 0x55504A))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        Text(transcript.sourceLabel)
                        if transcript.status == .processing { ProcessingDots() }
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

struct ProcessingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle().fill(Ink.iris).frame(width: 5, height: 5).opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: on)
            }
        }
        .onAppear { on = true }
    }
}
