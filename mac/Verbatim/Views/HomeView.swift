import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Home (BRAND_GUIDE §09A): one editorial headline, one capture bar with Record as the primary action,
/// three compact method cards that do real things, and recent work as document rows.
/// The most expressive screen in the app, and still a working surface: recent work is reachable without
/// scrolling past branding in a typical window.
struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead.staggerIn(0)

                Group {
                    if app.recorder.isRecording { RecordPanel() }
                    else if app.capture.isCapturing { CapturePanel() }
                    else { CaptureBar() }
                }
                .padding(.top, 20).staggerIn(1)
                .animation(Motion.settle, value: app.recorder.isRecording)
                .animation(Motion.settle, value: app.capture.isCapturing)
                if app.captureMode == "dictate" && !app.recorder.isRecording && !app.capture.isCapturing {
                    // Dictate's details drop down under the bar; click Dictate again (or ×) to close.
                    HStack(alignment: .top) {
                        DictateControls()
                        Spacer()
                        Button { withAnimation(Motion.settle) { app.captureMode = "voice" } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain).hoverChip(radius: 13).help("Close").accessibilityLabel("Close Dictate")
                    }
                    .padding(14)
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.hairline))
                    .padding(.top, 8)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }

                MethodCards().padding(.top, 30).staggerIn(2)
                RecentWork().padding(.top, 30).staggerIn(3)
            }
            .frame(maxWidth: 1040)
            .padding(.horizontal, 32).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Overline(text: "Verbatim / Ideas in order", color: Ink.dim)
                DottedRule().frame(height: 1)
                Overline(text: Self.today, color: Ink.mute)
            }
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        Text("Words worth keeping.").font(Ink.serif(46)).fixedSize()
                        Text("Words worth keeping.").font(Ink.serif(36)).fixedSize()
                        Text("Words worth\nkeeping.").font(Ink.serif(34)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                    Text("Capture what was said. Make it readable. Find what matters.")
                        .font(.system(size: 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // The process, as a small editorial index (wide windows only).
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(["Capture.", "Refine.", "Understand."], id: \.self) { Overline(text: $0, color: Ink.mute) }
                    }
                    .padding(.leading, 16)
                    .overlay(alignment: .leading) { Rectangle().fill(Ink.hairline).frame(width: 1) }
                    .fixedSize()
                    EmptyView()
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.top, 22)
    }

    private static var today: String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: Date())
    }
}

/// Capture / Refine / Understand: flat color, the kit's diagrams, and a real action each.
struct MethodCards: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let live = app.store.live
        let latest = live.first { $0.status == .ready && !$0.segments.isEmpty }
        let moments = live.reduce(0) { $0 + $1.notes.filter { $0.at != nil }.count }
        VStack(alignment: .leading, spacing: 14) {
            EditorialSectionHeader(index: "01", label: "Method")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)], alignment: .leading, spacing: 14) {
                BrandFeatureCard(feature: .capture, line: "Record, dictate, or import a file or link.",
                                 meta: live.count == 1 ? "1 transcript" : "\(live.count) transcripts") { app.requestRecord() }
                    .uiTarget("card-capture")
                BrandFeatureCard(feature: .refine, line: "Clean up a transcript. The original stays.",
                                 meta: latest.map { "Latest: \($0.title)" } ?? "Nothing to refine yet", enabled: latest != nil) {
                    guard let t = latest else { return }
                    app.go(.transcript(t.id))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .verbatimShowMode, object: "Document") }
                }
                BrandFeatureCard(feature: .understand, line: "Find what matters: moments, links, and search.",
                                 meta: moments == 1 ? "1 saved moment" : "\(moments) saved moments") { app.go(.moments) }
            }
        }
    }
}

// MARK: - Capture bar

struct CaptureBar: View {
    @EnvironmentObject var app: AppState
    @State private var importOpen = false
    @State private var fileOver = false
    @State private var mic: AudioDevices.Device? = AudioDevices.current()

    var body: some View {
        HStack(spacing: 0) {
            CaptureSegment(primary: true, action: { app.requestRecord() }) {
                RecordDot(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record").font(.system(size: 15, weight: .semibold)).fixedSize()
                    HStack(spacing: 4) {
                        Image(systemName: mic?.symbol ?? "mic").font(.system(size: 10.5))
                        Text(mic?.name ?? "Microphone").lineLimit(1)
                    }
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                    .help("Recording from \(mic?.name ?? "the system default"). Right-click Record to change it.")
                }
            }
            .contextMenu { RecordMenu(onChange: { mic = AudioDevices.current() }) }
            .uiTarget("tile-record")
            divider
            CaptureSegment(highlighted: app.captureMode == "dictate", action: { withAnimation(Motion.settle) { app.captureMode = app.captureMode == "dictate" ? "voice" : "dictate" } }) {
                Image(systemName: "keyboard").font(.system(size: 20, weight: .light)).foregroundStyle(Ink.ink).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictate").font(.system(size: 15, weight: .medium)).fixedSize()
                    Text(app.dictation.accessibilityTrusted ? app.dictation.hotkey.title.replacingOccurrences(of: "Hold ", with: "Hold ") : "Needs Accessibility").font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
                }
            }
            .contextMenu { DictateMenu() }
            .uiTarget("mode-dictate")
            divider
            CaptureSegment(highlighted: fileOver, action: { importOpen = true }) {
                BrandGlyph(art: .document, color: Ink.ink).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import").font(.system(size: 15, weight: .medium)).fixedSize()
                    Text(fileOver ? "Drop to transcribe" : "File or link").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                }
            }
            .popover(isPresented: $importOpen, arrowEdge: .bottom) { ImportPanel(done: { importOpen = false }) }
            .contextMenu { ImportMenu(openPanel: { importOpen = true }) }
            divider
            CaptureSegment(action: { app.pickApp() }) {
                Image(systemName: "speaker.wave.2").font(.system(size: 18, weight: .light)).foregroundStyle(Ink.ink).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("App audio").font(.system(size: 15, weight: .medium)).fixedSize()
                    Text("From another app").font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
                }
            }
            .contextMenu {
                Button { app.pickApp() } label: { Label("Choose an app…", systemImage: "speaker.wave.2") }
                Divider()
                Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) } label: {
                    Label("Screen & System Audio Recording settings…", systemImage: "lock.shield")
                }
            }
            .uiTarget("tile-app")
        }
        .padding(6)
        .frame(height: 70)
        // Paper, not glass: an opaque reader-white bar with an ink hairline.
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(fileOver ? Ink.persimmon : Ink.hairline, lineWidth: fileOver ? 1.5 : 1))
        .onDrop(of: [.fileURL], isTargeted: $fileOver) { app.handleDrop($0) }
        .onChange(of: app.focusLink) { _, _ in importOpen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in mic = AudioDevices.current() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in let m = AudioDevices.current(); if m != mic { mic = m } }
    }

    private var divider: some View { Rectangle().fill(Ink.hairline).frame(width: 1, height: 30) }
}

// MARK: - Capture bar menus (right-click a segment)

/// Record's right-click menu: pick the microphone, start recording, or open Settings.
struct RecordMenu: View {
    @EnvironmentObject var app: AppState
    var onChange: () -> Void = {}
    var body: some View {
        let selected = AudioDevices.selectedUID
        Button { app.requestRecord() } label: { Label("Record", systemImage: "record.circle") }
        Divider()
        Section("Microphone") {
            Button { AudioDevices.selectedUID = nil; onChange() } label: {
                Label("System default" + (AudioDevices.defaultInput().map { " (\($0.name))" } ?? ""), systemImage: selected == nil ? "checkmark" : "mic")
            }
            ForEach(AudioDevices.inputs()) { d in
                let uid = AudioDevices.deviceUID(d.id)
                Button { AudioDevices.selectedUID = uid; onChange() } label: {
                    Label(d.name, systemImage: selected != nil && selected == uid ? "checkmark" : d.symbol)
                }
            }
        }
        Divider()
        SettingsLink { Label("Recording settings…", systemImage: "gearshape") }
    }
}

/// Dictate's right-click menu: the hold key, on or off, and Accessibility access.
struct DictateMenu: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Section("Hold to dictate") {
            ForEach(DictationController.Hotkey.allCases) { k in
                Button { app.dictation.hotkey = k } label: {
                    Label(k.title.replacingOccurrences(of: "Hold ", with: ""), systemImage: app.dictation.hotkey == k ? "checkmark" : "keyboard")
                }
            }
        }
        Divider()
        Button { app.dictation.enabled.toggle() } label: {
            Label(app.dictation.enabled ? "Turn off Dictate" : "Turn on Dictate", systemImage: app.dictation.enabled ? "pause.circle" : "play.circle")
        }
        if !app.dictation.accessibilityTrusted {
            Button { app.dictation.requestAccessibility(); app.dictation.openAccessibilitySettings() } label: { Label("Allow Accessibility access…", systemImage: "hand.raised") }
        }
        if let last = app.dictation.lastResult, !last.isEmpty {
            Button { app.dictation.copyLast() } label: { Label("Copy last dictation", systemImage: "doc.on.doc") }
        }
        Divider()
        SettingsLink { Label("Dictate settings…", systemImage: "gearshape") }
    }
}

/// Import's right-click menu: files, a link from the clipboard, and whether to keep link video.
struct ImportMenu: View {
    @EnvironmentObject var app: AppState
    var openPanel: () -> Void
    var body: some View {
        Button { app.chooseFiles() } label: { Label("Choose files or a folder…", systemImage: "doc.on.doc") }
        if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("http"), !s.contains(" ") {
            Button { app.transcribeLink(s, keepVideo: nil) } label: { Label("Transcribe the copied link", systemImage: "link") }
        }
        Button(action: openPanel) { Label("Paste a link…", systemImage: "link.badge.plus") }
        Divider()
        Toggle("Keep the video of links", isOn: $app.keepVideoByDefault)
    }
}

/// One section of the capture toolbar: local tint on hover, slight compression on press.
struct CaptureSegment<Content: View>: View {
    var highlighted = false
    /// The Record segment: a faint persimmon wash so the primary action reads first.
    var primary = false
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    @GestureState private var pressed = false

    var body: some View {
        HStack(spacing: 12) { content() }
            .foregroundStyle(Ink.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill))
            .scaleEffect(pressed ? 0.99 : 1)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = true }.onEnded { v in
                if abs(v.translation.width) < 8 && abs(v.translation.height) < 8 { action() }
            })
            .animation(Motion.touch, value: hover)
            .animation(Motion.touch, value: pressed)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private var fill: Color {
        if highlighted || pressed { return Ink.accentSubtle }
        if hover { return primary ? Ink.persimmonTint : Ink.ink.opacity(0.045) }
        return primary ? Ink.persimmonTint.opacity(0.55) : .clear
    }
}

/// The record dot: flat persimmon with a reader-white center. No gradient, no glow.
struct RecordDot: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Ink.persimmon)
            Circle().fill(Ink.readerFixed).frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
                Button("Fetch", action: submit).buttonStyle(.brandPrimary).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
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

// MARK: - Recent work

/// Recent transcripts as document rows: title, source, duration, state, date.
struct RecentWork: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let items = Array(app.filtered.prefix(6))
        VStack(alignment: .leading, spacing: 14) {
            EditorialSectionHeader(index: "02", label: "Recent", title: "Pick up where you left off.") {
                InlineLink(title: "View library") { app.go(.library) }
            }
            if items.isEmpty {
                empty
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                        DocumentRow(transcript: t) { app.go(.transcript(t.id)) }
                            .uiTarget(i == 0 ? "row-0" : "row-\(i)")
                    }
                }
            }
        }
        .animation(Motion.settle, value: items.map(\.id))
    }

    private var empty: some View {
        HStack(spacing: 16) {
            EmptyStateArt(art: app.search.isEmpty ? .capture : .search, tint: app.search.isEmpty ? Ink.persimmonTint : Ink.butterTint)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.search.isEmpty ? "Record something new." : "Nothing found for “\(app.search)”").font(Ink.serif(21)).foregroundStyle(Ink.ink)
                Text(app.search.isEmpty ? "Recordings, dictations, and imports land here, ready to review." : "Search looks at titles and every transcript's text.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
            }
            Spacer()
            if app.search.isEmpty {
                Button("Record") { app.requestRecord() }.buttonStyle(.brandPrimaryLarge)
            }
        }
        .padding(20)
        .background(NoteCardBackground(hover: false))
    }
}

/// Neutral card surface: opaque reader white, an ink hairline that firms on hover.
struct NoteCardBackground: View {
    var hover: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Ink.cardHover : Ink.card)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hover ? Ink.outlineStrong.opacity(0.7) : Ink.hairline))
    }
}

struct RowMenuButton: View {
    var transcript: Transcript
    var body: some View {
        Menu { RowMenu(transcript: transcript) } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.dim).frame(width: 30, height: 26)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverChip()
        .help("More actions").accessibilityLabel("More actions for \(transcript.title)")
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
                    Image(systemName: "keyboard").font(.system(size: 18, weight: .light)).foregroundStyle(Ink.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.dictation.hotkey.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.ink)
                        Text(app.dictation.enabled ? "Ready in every app. Change the key in Settings › Dictate." : "Dictation is off. Turn it on in Settings › Dictate.").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    }
                }
                
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").font(.system(size: 18, weight: .light)).foregroundStyle(Ink.accentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs Accessibility access").font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.ink)
                        Text("To hear the key and paste into other apps. Verbatim reads nothing from them.").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    }
                    Spacer()
                    Button("Allow") { app.dictation.requestAccessibility(); app.dictation.openAccessibilitySettings() }.buttonStyle(.brandPrimary)
                }
                
            }
            if let last = app.dictation.lastResult, !last.isEmpty {
                HStack(spacing: 8) {
                    Text("Last: “\(last.prefix(70))\(last.count > 70 ? "…" : "")”").font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(1)
                    Button("Copy") { app.dictation.copyLast() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.ink).underline()
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
            Circle().fill(Ink.persimmon)
            BrandGlyph(art: .capture, color: Ink.inkFixed, minLineWidth: 1.2).padding(size * 0.2)
        }
        .frame(width: size, height: size)
    }
}

struct RecordPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 16) {
            SignalRings(active: !app.recorder.isPaused).frame(width: 30, height: 30).padding(.leading, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.recorder.isPaused ? "Paused" : "Recording").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                MicSourceMenu(status: "Microphone").environment(\.colorScheme, .light)
            }
            .frame(width: 170, alignment: .leading)
            LiveReadout(live: app.recorder.live, frozen: app.recorder.isPaused)
            Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }.buttonStyle(.brandSecondaryLarge)
            Button("Stop") { app.stopRecording() }.buttonStyle(.brandPrimaryLarge).keyboardShortcut(".", modifiers: [.option, .shift])
        }
        .padding(.horizontal, 16)
        .frame(height: 70)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.persimmon.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.recorder.isPaused ? "Recording paused" : "Recording")
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .identity))
    }
}

struct CapturePanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 16) {
            SignalRings(color: Ink.sageText).frame(width: 30, height: 30).padding(.leading, 6)
            Text("Capturing \(app.capture.appName)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1).frame(width: 170, alignment: .leading)
            LiveReadout(live: app.capture.live, color: NSColor(hex: Ink.inkHex))
            Button("Stop") { app.stopCapture() }.buttonStyle(.brandPrimaryLarge)
        }
        .padding(.horizontal, 16)
        .frame(height: 70)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.outlineStrong))
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
        CardButton(tilt: 2, lift: 2, radius: 14, dragPayload: { TranscriptDrag.payload(dragIDs?() ?? [transcript.id]) }, action: open) {
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
                        if transcript.status == .processing { Text("·"); Text(transcript.stageText).foregroundStyle(Ink.iris); ProgressView().controlSize(.mini) }
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
