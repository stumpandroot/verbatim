import SwiftUI
import UniformTypeIdentifiers

/// Home: the library first, capture at the bottom. Verbie appears only for empty states and moments.
struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var link = ""
    @State private var fileOver = false
    @FocusState private var linkFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.projectFilter.flatMap { id in app.store.projects.first { $0.id == id }?.name } ?? "Home")
                        .font(.system(size: 28, weight: .bold)).foregroundStyle(Ink.ink).padding(.bottom, 10)
                    history
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 40).padding(.top, 36).padding(.bottom, 140)
                .frame(maxWidth: .infinity)
            }
            captureBar
        }
        .onChange(of: app.focusLink) { _, _ in linkFocused = true }
    }

    // MARK: Capture bar

    private var captureBar: some View {
        VStack(spacing: 10) {
            if app.recorder.isRecording {
                RecordPanel().transition(.scale(scale: 0.96).combined(with: .opacity))
            } else if app.capture.isCapturing {
                CapturePanel().transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: app.fetching == nil ? "link" : "arrow.down.circle").foregroundStyle(Ink.mute)
                        if let f = app.fetching {
                            Text(f).font(.system(size: 14)).foregroundStyle(Ink.dim)
                            Spacer()
                            ProgressView().controlSize(.small)
                        } else {
                            TextField("Paste a link, or drop a file anywhere", text: $link)
                                .textFieldStyle(.plain).font(.system(size: 14)).focused($linkFocused)
                                .onSubmit { submitLink() }
                            Button("Transcribe") { submitLink() }
                                .buttonStyle(.borderedProminent).tint(Ink.iris).clipShape(Capsule())
                                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.leading, 14).padding(.trailing, 6).frame(height: 46)
                    .background(.white, in: Capsule())
                    .overlay(Capsule().strokeBorder(fileOver ? Color(hex: 0x5F8C28) : Color.black.opacity(0.12), lineWidth: fileOver ? 2 : 1))
                    .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }

                    Button { openFile() } label: {
                        Image(systemName: "folder").font(.system(size: 15, weight: .semibold)).frame(width: 46, height: 46)
                            .background(.white, in: Circle()).overlay(Circle().strokeBorder(Color.black.opacity(0.12)))
                    }
                    .buttonStyle(.plain).pressable().help("Open an audio or video file")

                    Button { app.pickApp() } label: {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 14, weight: .semibold)).frame(width: 46, height: 46)
                            .background(.white, in: Circle()).overlay(Circle().strokeBorder(Color.black.opacity(0.12)))
                    }
                    .buttonStyle(.plain).pressable().help("Capture audio from an app")

                    Button { app.requestRecord() } label: { RecordButton(size: 46) }
                        .buttonStyle(.plain).pressable().help("Record a voice memo (⌥⇧R)")
                        .keyboardShortcut("r", modifiers: [.option, .shift])
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: Color(hex: 0x3C328C).opacity(0.14), radius: 18, y: 8)
        .frame(maxWidth: 760)
        .padding(.horizontal, 40).padding(.bottom, 20)
        .animation(Motion.settle, value: app.recorder.isRecording)
        .animation(Motion.settle, value: app.capture.isCapturing)
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

    // MARK: History

    private var history: some View {
        let groups = Store.group(app.filtered)
        return VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty { emptyState }
            ForEach(groups, id: \.label) { g in
                Text(g.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.mute).padding(.top, 22).padding(.bottom, 4)
                ForEach(g.items) { t in
                    HistoryRow(transcript: t, open: { app.go(.transcript(t.id)) })
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
            VerbieView(pose: app.search.isEmpty ? app.verbiePose : .nothing).frame(width: 120, height: 130)
            if app.search.isEmpty {
                Text(app.projectFilter == nil ? "Nothing here yet" : "Nothing in this project yet").font(.system(size: 15, weight: .semibold))
                Text("Paste a link, drop a file, or press the record button. Transcripts stay on this Mac.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).multilineTextAlignment(.center).frame(maxWidth: 360)
            } else {
                Text("Nothing found for “\(app.search)”").font(.system(size: 15, weight: .semibold))
                Text("Try another word. Search looks at titles and every transcript's text.").font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 70)
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

struct Meter: View {
    var levels: [Float]
    var color: Color = Ink.coral
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, v in
                Capsule().fill(color).frame(width: 3, height: max(3, CGFloat(v) * 22))
            }
        }
        .frame(height: 22).animation(.linear(duration: 0.1), value: levels)
    }
}

struct RecordPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 14) {
            VerbieView(pose: app.verbiePose).frame(width: 36, height: 44)
            Text("Recording").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.dim)
            Text(app.recorder.elapsed.timecode).font(.system(size: 13, design: .monospaced)).frame(minWidth: 64, alignment: .leading)
            Meter(levels: app.recorder.levels).frame(maxWidth: .infinity, alignment: .leading)
            Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }.buttonStyle(.bordered)
            Button("Stop") { app.stopRecording() }.buttonStyle(.borderedProminent).tint(Ink.ink).keyboardShortcut(".", modifiers: [.option, .shift])
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.1)))
    }
}

struct CapturePanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 14) {
            VerbieView(pose: .listening).frame(width: 36, height: 44)
            Text("Capturing \(app.capture.appName)").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.dim)
            Text(app.capture.elapsed.timecode).font(.system(size: 13, design: .monospaced)).frame(minWidth: 64, alignment: .leading)
            Meter(levels: app.capture.levels, color: Ink.iris).frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop") { app.stopCapture() }.buttonStyle(.borderedProminent).tint(Ink.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.1)))
    }
}

struct HistoryRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if transcript.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.mute) }
                    Text(transcript.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(2)
                }
                Text(transcript.preview).font(.system(size: 13.5)).lineSpacing(3)
                    .foregroundStyle(transcript.status == .failed ? Ink.coral : Color(hex: 0x55504A))
                    .lineLimit(3).multilineTextAlignment(.leading)
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: transcript.status == .processing ? "hourglass" : "play.fill").font(.system(size: 9, weight: .bold))
                        Text(transcript.duration.timecode).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(hex: 0xEBE5DB), in: Capsule())
                    Image(systemName: transcript.source.symbol).font(.system(size: 10)).foregroundStyle(Ink.mute)
                    Text(dateLine).font(.system(size: 12)).foregroundStyle(Ink.mute)
                    if !transcript.speakers.isEmpty { Text("\(transcript.speakers.count) speakers").font(.system(size: 12)).foregroundStyle(Ink.mute) }
                    if transcript.status == .processing { ProcessingDots() }
                    if transcript.status == .failed { Button("Retry") { app.retry(transcript) }.buttonStyle(.link).font(.system(size: 12)) }
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(hover ? Color(hex: 0xF1ECE3) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tiltCard(tilt: 2.5, lift: 1, radius: 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var dateLine: String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(transcript.createdAt) { f.dateFormat = "'Today ·' h:mm a" }
        else if cal.isDateInYesterday(transcript.createdAt) { f.dateFormat = "'Yesterday ·' h:mm a" }
        else { f.dateFormat = "MMM d · h:mm a" }
        return f.string(from: transcript.createdAt)
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
