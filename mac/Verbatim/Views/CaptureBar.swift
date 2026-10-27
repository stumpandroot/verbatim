import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Capture bar menus (right-click a segment)

/// Record's right-click menu: pick the microphone, start recording, or open Settings.
struct RecordMenu: View {
    @EnvironmentObject var app: AppState
    var onChange: () -> Void = {}
    var body: some View {
        let selected = AudioDevices.selectedUID
        Button { app.requestRecord() } label: { Label("Record", systemImage: "record.circle") }   // brand: system surface (context menu)
        Button { MeetingCoordinator.shared.recordFromMenu() } label: { Label("Record a meeting", systemImage: "person.2") }   // brand: system surface (context menu)
            .disabled(MeetingSession.shared.isActive)
        RecordKindMenuItems()
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
        SettingsLink { Label("Recording settings…", systemImage: "gearshape") }   // brand: system surface (context menu)
    }
}

/// Record with a kind you pick (Record an interview, a journal entry, a talk, or a note): the new transcript is that
/// kind as yours, so AutoLabel never replaces it, and Run automatically runs that kind's template (Templates.swift).
/// Record a meeting is the meeting capture beside it, which files its transcript as a Meeting.
struct RecordKindMenuItems: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        ForEach(RecordingKind.recordChoices.filter { $0 != .meeting }) { k in
            Button(k.recordTitle) { app.requestRecord(kind: k) }
        }
    }
}

/// Dictate's right-click menu: the hold key, on or off, and Accessibility access.
struct DictateMenu: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Section("Hotkey") {
            ForEach(DictationController.Hotkey.allCases.filter(\.isReady)) { k in
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
            ForEach(FlowMode.pickerOrder) { Text($0.title).tag($0) }
        }
        Toggle("Show the Ribbon", isOn: Binding(get: { FlowSettings.shared.showBar }, set: { FlowSettings.shared.showBar = $0 }))
        Button { app.go(.dictations) } label: { Label("Dictation history", systemImage: "waveform") }   // brand: system surface (context menu)
        Divider()
        Button { app.dictation.enabled.toggle() } label: {
            Label(app.dictation.enabled ? "Turn off Dictate" : "Turn on Dictate", systemImage: app.dictation.enabled ? "pause.circle" : "play.circle")
        }
        if !app.dictation.accessibilityTrusted {
            Button { app.dictation.requestAccessibility(); app.dictation.openAccessibilitySettings() } label: { Label("Allow Accessibility access…", systemImage: "hand.raised") }   // brand: system surface (context menu)
        }
        if let last = app.dictation.lastResult, !last.isEmpty {
            Button { app.dictation.copyLast() } label: { Label("Copy last dictation", systemImage: "doc.on.doc") }   // brand: system surface (context menu)
        }
        Divider()
        SettingsLink { Label("Dictate settings…", systemImage: "gearshape") }   // brand: system surface (context menu)
    }
}

/// Import's right-click menu: files, a link from the clipboard, and whether to keep link video.
struct ImportMenu: View {
    @EnvironmentObject var app: AppState
    var openPanel: () -> Void
    var body: some View {
        Button { app.chooseFiles() } label: { Label("Choose files or a folder…", systemImage: "doc.on.doc") }   // brand: system surface (context menu)
        Button { app.chooseMultitrack() } label: { Label("Multi-track recording…", systemImage: "square.3.layers.3d.down.right") }   // brand: system surface (context menu)
        if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("http"), !s.contains(" ") {
            Button { app.transcribeLink(s, keepVideo: nil) } label: { Label("Transcribe the copied link", systemImage: "link") }   // brand: system surface (context menu)
        }
        Button(action: openPanel) { Label("Paste a link…", systemImage: "link.badge.plus") }   // brand: system surface (context menu)
        Divider()
        Toggle("Keep the video of links", isOn: $app.keepVideoByDefault)
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
            Button { done(); openFile() } label: { Label("Choose files or a folder…", art: .document, size: 15) }
                .buttonStyle(.pillLine(large: true)).frame(maxWidth: .infinity, alignment: .leading)
            Button { done(); app.chooseMultitrack() } label: { Label("Multi-track recording…", art: .iconMultitrack, size: 15) }
                .buttonStyle(.pillLine(large: true)).frame(maxWidth: .infinity, alignment: .leading)
                .help("One audio file per mic, recorded at the same time. Each file becomes a speaker.")
            Text("Or paste a link").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("https://…", text: $link).textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit)
                Button("Fetch", action: submit).buttonStyle(.pillDark()).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
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
        .help("Which microphone Verbose records from")
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
                    IconGlyph(art: .iconDictations, size: 20, color: Ink.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.dictation.hotkey.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.ink)
                        Text(app.dictation.enabled ? "\(app.dictation.hotkey.shortTitle.prefix(1).uppercased() + app.dictation.hotkey.shortTitle.dropFirst()) in any app, or click \(DictationSurface.stored().clickHint). Settings › Dictation and keyboard has cleanup, styles, and snippets." : "Dictation is off. Turn it on in Settings › Dictation and keyboard.").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    }
                }
                
            } else {
                HStack(spacing: 10) {
                    IconGlyph(art: .iconAccessibility, size: 20, color: Ink.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs Accessibility access").font(.system(size: 15, weight: .bold)).foregroundStyle(Ink.ink)
                        Text("To hear the key and paste into other apps. Verbose reads nothing from them.").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    }
                    Spacer()
                    Button("Allow") { app.dictation.requestAccessibility(); app.dictation.openAccessibilitySettings() }.buttonStyle(.pillDark())
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
    /// Mark a moment (App/MarkCenter.swift): the Mark button and "Marked 4:12 · 3 moments" for two seconds.
    @ObservedObject private var marks = MarkCenter.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            // Show words while you record: the newest two lines, a preview only (RecordingWords.swift).
            RecordingWordsLine(words: app.recordingWords, insets: EdgeInsets(top: 0, leading: 52, bottom: 12, trailing: 16))
        }
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.persimmon.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(starting ? "Starting the microphone" : app.recorder.isPaused ? "Recording paused" : app.recorder.micWarning.map { "Recording. \($0.title). \($0.detail)." } ?? "Recording")
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .identity))
    }

    private var controls: some View {
        HStack(spacing: 16) {
            SignalRings(active: !app.recorder.isPaused && !starting).frame(width: 30, height: 30).padding(.leading, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(starting ? "Starting…" : app.recorder.isPaused ? "Paused" : "Recording").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                if let id = app.continuing, let t = app.store.transcript(id) {
                    Text("Adding to “\(t.title)”").font(.system(size: 12)).foregroundStyle(Ink.accentText).lineLimit(1)
                }
                if let c = marks.confirmation, !starting {
                    HStack(spacing: 5) {
                        ArtIcon(art: .iconMarked, size: 13)
                        Text("Marked").font(.system(size: 12, weight: .semibold))
                        Text(Marks.clock(c.at)).font(Ink.mono(12)).monospacedDigit()
                        Text("· \(Marks.count(c.count))").font(.system(size: 12))
                    }
                    .foregroundStyle(Ink.butterText)
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Marks.confirmation(c))
                    .uiTarget("record-panel-marked")
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
            // Mark a moment at the recording's time (also ⌃⌥B from any app while it records).
            Button { marks.mark(.macApp) } label: {
                HStack(spacing: 6) {
                    ArtIcon(art: .iconMark, size: 15)
                    Text("Mark")
                    Keycap(keys: MarkHotkeyStore.current().title, size: 12)
                }
            }
            .buttonStyle(.pillLine(large: true)).disabled(starting)
            .help("Mark this moment (\(MarkHotkeyStore.current().title) from any app while you record)")
            .accessibilityLabel("Mark a moment")
            .uiTarget("record-panel-mark")
            Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }.buttonStyle(.pillLine(large: true)).disabled(starting)
            // While the mic is starting, Stop cancels the start.
            Button(starting ? "Cancel" : "Stop") { app.stopRecording() }.buttonStyle(.pillDark(large: true)).keyboardShortcut(".", modifiers: [.option, .shift])
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 70)
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
            Button("Stop") { app.stopCapture() }.buttonStyle(.pillDark(large: true))
        }
        .padding(.horizontal, 16)
        .frame(height: 70)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.outlineStrong))
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .identity))
    }
}
