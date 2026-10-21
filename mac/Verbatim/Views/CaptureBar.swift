import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Capture bar

struct CaptureBar: View {
    @EnvironmentObject var app: AppState
    @State private var importOpen = false
    @State private var fileOver = false
    @State private var mic: AudioDevices.Device? = AudioDevices.current()
    @ObservedObject private var captions = LiveCaptions.shared

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
            divider
            CaptureSegment(highlighted: captions.isOpen, action: { app.toggleLiveCaptions() }) {
                CaptionRingsMark(color: Ink.ink).frame(width: 22, height: 22).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live captions").font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    Text(captions.isOpen ? "On screen now" : "⌥⌘C").font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
                }
            }
            .help("Captions in a floating panel, from your mic or an app's audio")
            .uiTarget("tile-captions")
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
        Section("Hotkey") {
            ForEach(DictationController.Hotkey.allCases) { k in
                Button { app.dictation.hotkey = k } label: {
                    Label(k.title.replacingOccurrences(of: "Hold ", with: ""), systemImage: app.dictation.hotkey == k ? "checkmark" : "keyboard")
                }
            }
        }
        Divider()
        Picker("Cleanup", selection: Binding(get: { FlowSettings.shared.cleanup }, set: { FlowSettings.shared.cleanup = $0 })) {
            ForEach(CleanupLevel.allCases) { Text($0.title).tag($0) }
        }
        Picker("Start and stop", selection: Binding(get: { FlowSettings.shared.mode }, set: { FlowSettings.shared.mode = $0 })) {
            ForEach(FlowMode.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Show the floating button", isOn: Binding(get: { FlowSettings.shared.showBar }, set: { FlowSettings.shared.showBar = $0 }))
        Button { app.go(.dictations) } label: { Label("Dictation history", systemImage: "waveform") }
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

/// Which microphone: an icon for the transport, the device name, and a menu to switch. Lives on the capture card
/// and in Settings so you always know where the audio comes from.
struct MicSourceMenu: View {
    var status: String = ""
    @State private var devices: [AudioDevices.Device] = []
    @State private var current: AudioDevices.Device? = nil
    @State private var selectedUID: String? = AudioDevices.selectedUID
    @State private var defaultName: String? = nil

    var body: some View {
        Menu {
            Button { choose(nil) } label: { Label("System default" + (defaultName.map { " (\($0))" } ?? ""), systemImage: selectedUID == nil ? "checkmark" : "") }
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

    /// Reads the devices off the main thread: this menu appears as a recording starts, while the mic is being
    /// opened, and a Core Audio read can wait on a device that's busy switching.
    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let all = AudioDevices.inputs(), now = AudioDevices.current(), def = AudioDevices.defaultInput()?.name
            DispatchQueue.main.async { devices = all; current = now; defaultName = def }
        }
    }
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
                        Text(app.dictation.enabled ? "\(FlowSettings.shared.mode.title) in any app, or click the floating button at the edge of your screen. Settings › Dictate has cleanup, styles, and snippets." : "Dictation is off. Turn it on in Settings › Dictate.").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
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
            SignalRings(active: !app.recorder.isPaused && !starting).frame(width: 30, height: 30).padding(.leading, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(starting ? "Starting…" : app.recorder.isPaused ? "Paused" : "Recording").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                if let id = app.continuing, let t = app.store.transcript(id) {
                    Text("Adding to “\(t.title)”").font(.system(size: 12)).foregroundStyle(Ink.accentText).lineLimit(1)
                }
                // Muted, or only digital silence: said at once, and cleared as soon as the mic is back.
                if let w = app.recorder.micWarning, !starting, !app.recorder.isPaused {
                    Text("\(w.title). \(w.detail).")
                        .font(.system(size: 11.5, weight: w.isFirm ? .semibold : .medium)).foregroundStyle(Ink.accentText)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                MicSourceMenu(status: "Microphone").environment(\.colorScheme, .light)
            }
            .frame(width: 170, alignment: .leading)
            LiveReadout(live: app.recorder.live, frozen: app.recorder.isPaused)
            Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }.buttonStyle(.brandSecondaryLarge).disabled(starting)
            // While the mic is starting, Stop cancels the start.
            Button(starting ? "Cancel" : "Stop") { app.stopRecording() }.buttonStyle(.brandPrimaryLarge).keyboardShortcut(".", modifiers: [.option, .shift])
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 70)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.persimmon.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(starting ? "Starting the microphone" : app.recorder.isPaused ? "Recording paused" : app.recorder.micWarning.map { "Recording. \($0.title). \($0.detail)." } ?? "Recording")
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .identity))
    }

    private var starting: Bool { app.recorder.isStarting }
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
