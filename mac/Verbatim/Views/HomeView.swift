import SwiftUI
import UniformTypeIdentifiers

/// Home, "Color Pop": headline, the lime capture card with Verbie, Bring something in, recent transcripts.
struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var filter = "all"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Make room for your thoughts.")
                        .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.7)
                    Ticks().frame(width: 34, height: 30).offset(y: -8)
                }
                .staggerIn(0)
                HStack(alignment: .top, spacing: 16) {
                    CaptureCard().frame(maxWidth: .infinity).staggerIn(1)
                    BringInCard().frame(width: 330).staggerIn(2)
                }
                .frame(minHeight: 330)
                recent
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0x4FB056)).frame(width: 8, height: 8)
                    Text("Transcription runs on this Mac").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Ink.mute)
                        .help("Models download once and run locally. Fetching a link needs the internet; nothing else does.")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 1040)
            .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private var recent: some View {
        let items = Array(app.filtered.filter { filter == "all" || (filter == "rec" ? ($0.source == .voiceMemo || $0.source == .app) : ($0.source == .file || $0.source == .link)) }.prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Recent transcripts").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink)
                HStack(spacing: 6) {
                    Chip(label: "All", selected: filter == "all") { filter = "all" }
                    Chip(label: "Recordings", selected: filter == "rec") { filter = "rec" }
                    Chip(label: "Imports", selected: filter == "imp") { filter = "imp" }
                }
                Spacer()
                HStack(spacing: 4) { Text("View all"); Image(systemName: "arrow.right") }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.iris)
                    .tapArea { app.go(.library) }
            }
            .staggerIn(3)
            if items.isEmpty {
                emptyState.staggerIn(4)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    HistoryRow(transcript: t, open: { app.go(.transcript(t.id)) })
                        .uiTarget(i == 0 ? "row-0" : "row-\(i)")
                        .staggerIn(4 + i)
                        .contextMenu { RowMenu(transcript: t) }
                }
            }
        }
        .animation(Motion.settle, value: items.map(\.id))
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            VerbieView(pose: app.search.isEmpty ? .ready : .nothing, tracksPointer: false).frame(width: 54, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.search.isEmpty ? "Nothing here yet" : "Nothing found for “\(app.search)”").font(.system(size: 15, weight: .semibold))
                Text(app.search.isEmpty ? "Your transcripts will collect here. Record something, or bring a link or file in." : "Search looks at titles and every transcript's text.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
            }
            Spacer()
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.06)))
    }
}

/// The two tick marks beside the headline (coral and lime).
struct Ticks: View {
    var body: some View {
        ZStack {
            Capsule().fill(Ink.coral).frame(width: 7, height: 20).rotationEffect(.degrees(28)).offset(x: 4, y: -6)
            Capsule().fill(Ink.lime).frame(width: 7, height: 16).rotationEffect(.degrees(-62)).offset(x: 2, y: 8)
        }
    }
}

struct Chip: View {
    var label: String
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Text(label).font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(selected ? Ink.iris : Color(hex: 0xECE8F3), in: Capsule())
            .foregroundStyle(selected ? .white : Ink.ink)
            .tapArea(action)
            .animation(Motion.snap, value: selected)
    }
}

// MARK: - Capture card (the hero object)

struct CaptureCard: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Scribble().stroke(Ink.limeDeep.opacity(0.12), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                .frame(width: 420, height: 90).offset(x: 260, y: 150).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                Text("Say it. Keep it.").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink)
                ModeSwitch()
                Text(app.captureMode == "dictate" ? "Hold a key anywhere, speak, release. The words land in the app in front." : "Record a thought. Verbatim keeps the words on this Mac.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.limeDeep.opacity(0.8)).frame(maxWidth: 330, alignment: .leading)
                Spacer(minLength: 0)
                if app.recorder.isRecording {
                    RecordPanel().transition(.scale(scale: 0.96).combined(with: .opacity))
                } else if app.capture.isCapturing {
                    CapturePanel().transition(.scale(scale: 0.96).combined(with: .opacity))
                } else if app.captureMode == "dictate" {
                    DictateControls().transition(.scale(scale: 0.96).combined(with: .opacity))
                } else {
                    VStack(spacing: 8) {
                        CardButton(tilt: 0, lift: 2, radius: 60, action: { app.requestRecord() }) { RecordButton(size: 112) }
                            .uiTarget("tile-record")
                        Text("Start recording").font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.ink)
                    }
                    .frame(width: 160)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)

            VerbieView(pose: verbiePose)
                .frame(width: 150, height: 230)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 36).padding(.bottom, 14)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 330)
        .background(Ink.lime, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .tiltCard(tilt: 1.5, lift: 0, radius: 26)
        .animation(Motion.settle, value: app.recorder.isRecording)
        .animation(Motion.settle, value: app.capture.isCapturing)
        .animation(Motion.settle, value: app.captureMode)
    }

    private var verbiePose: VerbiePose {
        if app.recorder.isRecording || app.capture.isCapturing || app.dictation.isListening { return app.recorder.isPaused ? .paused : .listening }
        return app.verbiePose
    }
}

struct ModeSwitch: View {
    @EnvironmentObject var app: AppState
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            seg("Voice note", "waveform", "voice")
            seg("Dictate", "text.cursor", "dictate")
        }
        .padding(3)
        .background(Color.white.opacity(0.55), in: Capsule())
        .fixedSize()
    }
    private func seg(_ title: String, _ icon: String, _ key: String) -> some View {
        let on = app.captureMode == key
        return HStack(spacing: 7) { Image(systemName: icon); Text(title) }
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background { if on { Capsule().fill(Ink.iris).matchedGeometryEffect(id: "seg", in: ns) } }
            .foregroundStyle(on ? .white : Ink.ink)
            .tapArea { withAnimation(Motion.snap) { app.captureMode = key } }
            .uiTarget("mode-" + key)
    }
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
                        Text(app.dictation.enabled ? "Ready in every app. Change the key in Settings › Dictation." : "Dictation is off. Turn it on in Settings › Dictation.").font(.system(size: 12.5)).foregroundStyle(Ink.limeDeep.opacity(0.8))
                    }
                }
                .padding(14).background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").font(.system(size: 18)).foregroundStyle(Ink.coral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs Accessibility access").font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.ink)
                        Text("To hear the key and paste into other apps. Verbatim reads nothing from them.").font(.system(size: 12.5)).foregroundStyle(Ink.limeDeep.opacity(0.8))
                    }
                    Spacer()
                    Button("Allow") { app.dictation.requestAccessibility(); app.dictation.openAccessibilitySettings() }.buttonStyle(.borderedProminent).tint(Ink.iris)
                }
                .padding(14).background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let last = app.dictation.lastResult, !last.isEmpty {
                Text("Last: “\(last.prefix(80))\(last.count > 80 ? "…" : "")”").font(.system(size: 12)).foregroundStyle(Ink.limeDeep.opacity(0.7)).lineLimit(1)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

/// A loose "m" scribble, the brand's doodle.
struct Scribble: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: 0, y: h * 0.8))
        p.addCurve(to: CGPoint(x: w * 0.25, y: h * 0.2), control1: CGPoint(x: w * 0.05, y: h * 0.1), control2: CGPoint(x: w * 0.2, y: h * 0.0))
        p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.8), control1: CGPoint(x: w * 0.3, y: h * 0.4), control2: CGPoint(x: w * 0.4, y: h * 1.1))
        p.addCurve(to: CGPoint(x: w * 0.75, y: h * 0.2), control1: CGPoint(x: w * 0.55, y: h * 0.1), control2: CGPoint(x: w * 0.7, y: h * 0.0))
        p.addCurve(to: CGPoint(x: w, y: h * 0.8), control1: CGPoint(x: w * 0.8, y: h * 0.4), control2: CGPoint(x: w * 0.9, y: h * 1.1))
        return p
    }
}

// MARK: - Bring something in

struct BringInCard: View {
    @EnvironmentObject var app: AppState
    @State private var link = ""
    @State private var fileOver = false
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bring something in").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink)
            HStack(spacing: 8) {
                Image(systemName: app.fetching == nil ? "link" : "arrow.down.circle").foregroundStyle(Ink.mute)
                if let f = app.fetching {
                    Text(f).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(1)
                    Spacer()
                    ProgressView().controlSize(.small)
                } else {
                    TextField("Paste a video or audio link", text: $link).textFieldStyle(.plain).font(.system(size: 13.5)).focused($linkFocused).onSubmit(submit)
                    Button { submit() } label: {
                        Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 34, height: 34).background(Ink.iris, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain).pressable().disabled(link.trimmingCharacters(in: .whitespaces).isEmpty).opacity(link.isEmpty ? 0.5 : 1)
                }
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 48)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.1)))
            .onChange(of: app.focusLink) { _, _ in linkFocused = true }

            BringRow(title: "Import file", hint: fileOver ? "Drop to transcribe" : "Audio or video", tint: Ink.irisTint, fg: Ink.iris, icon: "doc.text", highlighted: fileOver) { openFile() }
                .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }
            BringRow(title: "Capture app audio", hint: "Choose an app", tint: Ink.limeTint, fg: Color(hex: 0x4F7D12), icon: "waveform") { app.pickApp() }
                .uiTarget("tile-app")
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0xF3F0FA), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.black.opacity(0.05)))
        .animation(Motion.settle, value: fileOver)
    }

    private func submit() {
        let l = link.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return }
        app.transcribeLink(l); link = ""
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff, .quickTimeMovie, UTType("public.mpeg-4-audio") ?? .audio]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach { app.importFile($0) } }
    }
}

struct BringRow: View {
    var title: String, hint: String, tint: Color, fg: Color, icon: String
    var highlighted = false
    var action: () -> Void
    var body: some View {
        CardButton(tilt: 4, lift: 2, radius: 14, action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(fg)
                    .frame(width: 44, height: 44).background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(hint).font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
            }
            .padding(12)
            .background(highlighted ? Color(hex: 0xE4F3C4) : .white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(highlighted ? Color(hex: 0x5F8C28) : Color.black.opacity(0.06), lineWidth: highlighted ? 1.5 : 1))
        }
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
        HStack(spacing: 14) {
            ZStack { Circle().fill(Ink.coral).frame(width: 12, height: 12); Circle().stroke(Ink.coral.opacity(0.4), lineWidth: 3).frame(width: 20, height: 20) }
            Text(app.recorder.isPaused ? "Paused" : "Recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink).frame(width: 72, alignment: .leading)
            Text(app.recorder.elapsed.timecode).font(.system(size: 14, design: .monospaced)).foregroundStyle(Ink.ink).frame(minWidth: 56, alignment: .leading)
            Meter(levels: app.recorder.levels, frozen: app.recorder.isPaused).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
            Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }.buttonStyle(.bordered)
            Button("Stop") { app.stopRecording() }.buttonStyle(.borderedProminent).tint(Ink.ink).keyboardShortcut(".", modifiers: [.option, .shift])
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 520)
    }
}

struct CapturePanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform").foregroundStyle(Ink.iris)
            Text("Capturing \(app.capture.appName)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
            Text(app.capture.elapsed.timecode).font(.system(size: 14, design: .monospaced)).foregroundStyle(Ink.ink).frame(minWidth: 56, alignment: .leading)
            Meter(levels: app.capture.levels, color: NSColor(red: 0x6F/255, green: 0x5A/255, blue: 0xF0/255, alpha: 1)).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop") { app.stopCapture() }.buttonStyle(.borderedProminent).tint(Ink.ink)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 520)
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
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        CardButton(tilt: 2, lift: 1, radius: 14, action: open) {
            HStack(spacing: 14) {
                Image(systemName: transcript.source.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(tileFg)
                    .frame(width: 48, height: 48).background(tileBg, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if transcript.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.mute) }
                        Text(transcript.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(transcript.sourceLabel)
                        Text("·"); Text(transcript.duration.timecode)
                        if !transcript.speakers.isEmpty { Text("·"); Text("\(transcript.speakers.count) speakers") }
                        if transcript.status == .processing { Text("·"); Text(transcript.stage ?? "Transcribing").foregroundStyle(Ink.iris); ProgressView().controlSize(.mini) }
                        if transcript.status == .failed { Text("·"); Text("Needs retry").foregroundStyle(Ink.coral) }
                    }
                    .font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
                Spacer(minLength: 10)
                WaveformThumb(values: transcript.waveform.isEmpty ? placeholder : Waveform.resample(transcript.waveform, to: 48))
                    .fill(waveColor).frame(width: 190, height: 26)
                Text(dateLine).font(.system(size: 13)).foregroundStyle(Ink.mute).frame(width: 130, alignment: .trailing)
                Menu { RowMenu(transcript: transcript) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(hover ? Color(hex: 0xFBF9FF) : .white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.06)))
        }
        .onHover { hover = $0 }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var placeholder: [Float] { (0..<48).map { _ in Float.random(in: 0.08...0.25) } }
    private var tileBg: Color { switch transcript.source { case .voiceMemo: return Ink.coralTint; case .app: return Ink.limeTint; default: return Ink.irisTint } }
    private var tileFg: Color { switch transcript.source { case .voiceMemo: return Ink.coral; case .app: return Color(hex: 0x4F7D12); default: return Ink.iris } }
    private var waveColor: Color { transcript.source == .voiceMemo ? Ink.coral.opacity(0.85) : Ink.iris.opacity(0.75) }
    private var dateLine: String {
        let f = DateFormatter(); let cal = Calendar.current
        if cal.isDateInToday(transcript.createdAt) { f.dateFormat = "'Today,' h:mm a" }
        else if cal.isDateInYesterday(transcript.createdAt) { f.dateFormat = "'Yesterday,' h:mm a" }
        else { f.dateFormat = "MMM d, yyyy" }
        return f.string(from: transcript.createdAt)
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
        Divider()
        Button("Delete", role: .destructive) { withAnimation(Motion.settle) { app.store.delete(transcript) } }
    }
}
