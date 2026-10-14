import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Home, "Color Pop": headline, the lime capture card with Verbie, Bring something in, recent transcripts.
struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Make room for your thoughts.")
                    .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.7)
                    .staggerIn(0)
                CaptureCard().staggerIn(1)
                CaptureTiles().staggerIn(2)
                recent
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0x4FB056)).frame(width: 8, height: 8)
                    Text("Transcription runs on this Mac").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Ink.mute)
                        .help("Models download once and run locally. Fetching a link needs the internet; nothing else does.")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private var recent: some View {
        let items = Array(app.filtered.prefix(5))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Recent transcripts").font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.ink)
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
            // Faint sound bars behind Verbie: decoration, never a meter.
            StillBars().fill(Color.white.opacity(0.4))
                .frame(width: 520, height: 150)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 44).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 8) {
                ModeSwitch()
                Text("Say it. Keep it.").font(.system(size: 28, weight: .bold)).foregroundStyle(Ink.ink).padding(.top, 2)
                Text(app.captureMode == "dictate" ? "Hold a key anywhere, speak, release. The words land in the app in front." : "Record a thought. Keep every word on your Mac.")
                    .font(.system(size: 14)).foregroundStyle(Ink.limeDeep.opacity(0.8)).lineLimit(1)
                Spacer(minLength: 6)
                if app.recorder.isRecording {
                    RecordPanel().transition(.scale(scale: 0.96).combined(with: .opacity))
                } else if app.capture.isCapturing {
                    CapturePanel().transition(.scale(scale: 0.96).combined(with: .opacity))
                } else if app.captureMode == "dictate" {
                    DictateControls().transition(.scale(scale: 0.96).combined(with: .opacity))
                } else {
                    HStack(spacing: 18) {
                        CardButton(tilt: 0, lift: 2, radius: 40, action: { app.requestRecord() }) { RecordButton(size: 72) }
                            .uiTarget("tile-record")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start recording").font(.system(size: 17, weight: .bold)).foregroundStyle(Ink.ink)
                            Text(micStatus).font(.system(size: 13)).foregroundStyle(Ink.limeDeep.opacity(0.8))
                        }
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 22).padding(.trailing, 230)   // keep the text column clear of Verbie
            .frame(maxWidth: .infinity, alignment: .leading)

            VerbieView(pose: verbiePose)
                .frame(width: 122, height: 190)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 110).padding(.bottom, 10)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 228)
        .background(Ink.lime, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .tiltCard(tilt: 1, lift: 0, radius: 24, rotates: false)
        .animation(Motion.settle, value: app.recorder.isRecording)
        .animation(Motion.settle, value: app.capture.isCapturing)
        .animation(Motion.settle, value: app.captureMode)
    }

    private var micStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Microphone ready."
        case .notDetermined: return "Verbatim will ask for the microphone."
        default: return "Microphone access is off in System Settings."
        }
    }

    private var verbiePose: VerbiePose {
        if app.recorder.isRecording || app.capture.isCapturing || app.dictation.isListening { return app.recorder.isPaused ? .paused : .listening }
        return app.verbiePose
    }
}

/// Decorative sound bars (a Shape, drawn once).
struct StillBars: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = 56, step = r.width / CGFloat(n), w: CGFloat = 5
        for i in 0..<n {
            let t = Double(i)
            let v = 0.12 + abs(sin(t * 0.55) * 0.55 + sin(t * 1.9) * 0.2)
            let h = max(8, CGFloat(min(1, v)) * r.height)
            p.addRoundedRect(in: CGRect(x: r.minX + CGFloat(i) * step, y: r.midY - h / 2, width: w, height: h), cornerSize: CGSize(width: 2.5, height: 2.5))
        }
        return p
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
                HStack(spacing: 8) {
                    Text("Last: “\(last.prefix(70))\(last.count > 70 ? "…" : "")”").font(.system(size: 12)).foregroundStyle(Ink.limeDeep.opacity(0.7)).lineLimit(1)
                    Button("Copy") { app.dictation.copyLast() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.iris)
                }
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

/// Import file · Paste a link · Record app audio, in one compact row. The link tile opens a field in place.
struct CaptureTiles: View {
    @EnvironmentObject var app: AppState
    @State private var link = ""
    @State private var linkOpen = false
    @State private var fileOver = false
    @FocusState private var linkFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            BringRow(title: "Import file", hint: fileOver ? "Drop to transcribe" : "Audio or video", tint: Ink.irisTint, fg: Ink.iris, icon: "doc.text", highlighted: fileOver) { openFile() }
                .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }
            if linkOpen || app.fetching != nil {
                linkField
            } else {
                BringRow(title: "Paste a link", hint: "Video or audio URL", tint: Ink.irisTint, fg: Ink.iris, icon: "link") {
                    if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") { link = s }
                    withAnimation(Motion.snap) { linkOpen = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { linkFocused = true }
                }
            }
            BringRow(title: "Record app audio", hint: "Capture sound from an app", tint: Ink.coralTint, fg: Ink.coral, icon: "rectangle.on.rectangle") { app.pickApp() }
                .uiTarget("tile-app")
        }
        .onChange(of: app.focusLink) { _, _ in withAnimation(Motion.snap) { linkOpen = true }; linkFocused = true }
        .animation(Motion.settle, value: fileOver)
    }

    private var linkField: some View {
        HStack(spacing: 10) {
            Image(systemName: app.fetching == nil ? "link" : "arrow.down.circle").foregroundStyle(Ink.iris)
            if let f = app.fetching {
                Text(f).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(1)
                Spacer()
                ProgressView().controlSize(.small)
            } else {
                TextField("Paste a video or audio link", text: $link).textFieldStyle(.plain).font(.system(size: 13.5)).focused($linkFocused)
                    .onSubmit(submit)
                    .onExitCommand { withAnimation(Motion.snap) { linkOpen = false } }
                Button { submit() } label: {
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 30, height: 30).background(Ink.iris, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain).pressable().disabled(link.trimmingCharacters(in: .whitespaces).isEmpty).opacity(link.isEmpty ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 16).frame(height: 72)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.iris.opacity(0.5)))
        .transition(.scale(scale: 0.97).combined(with: .opacity))
    }

    private func submit() {
        let l = link.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return }
        app.transcribeLink(l); link = ""
        withAnimation(Motion.snap) { linkOpen = false }
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
        CardButton(tilt: 2, lift: 1, radius: 16, action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(fg)
                    .frame(width: 44, height: 44).background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(hint).font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.mute)
            }
            .padding(.horizontal, 16).frame(height: 72)
            .background(highlighted ? Color(hex: 0xE4F3C4) : .white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(highlighted ? Color(hex: 0x5F8C28) : Color.black.opacity(0.06), lineWidth: highlighted ? 1.5 : 1))
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
            LiveReadout(live: app.recorder.live, frozen: app.recorder.isPaused)
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
            LiveReadout(live: app.capture.live, color: NSColor(red: 0x6F/255, green: 0x5A/255, blue: 0xF0/255, alpha: 1))
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
        CardButton(tilt: 1, lift: 1, radius: 14, action: open) {
            HStack(spacing: 14) {
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
    private var tileBg: Color { switch transcript.source { case .voiceMemo, .dictation: return Ink.coralTint; case .app: return Ink.limeTint; default: return Ink.irisTint } }
    private var tileFg: Color { switch transcript.source { case .voiceMemo, .dictation: return Ink.coral; case .app: return Color(hex: 0x4F7D12); default: return Ink.iris } }
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
