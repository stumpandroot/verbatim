import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            transcription.tabItem { Label("Transcription", systemImage: "text.alignleft") }
            DictationSettings().tabItem { Label("Dictate", systemImage: "keyboard") }
            KeepSettings().tabItem { Label("Keep", systemImage: "arrow.down.circle") }
            storage.tabItem { Label("Storage", systemImage: "externaldrive") }
        }
        .frame(width: 560)
        .padding(.bottom, 10)
    }

    private var general: some View {
        Form {
            Picker("Appearance", selection: Binding(get: { app.appearance }, set: { app.appearance = $0; app.applyAppearance() })) {
                Text("Match the system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            Toggle("Show in menu bar", isOn: $app.showMenuBar)
            Text("Record from anywhere with the menu bar item, or press ⌥⇧R while Verbatim is running.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute)
            Toggle("Sounds", isOn: $app.sounds)
            Text("A short chime when recording starts and a tick when a transcript is ready. Off automatically with Reduce Motion.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute)
            Toggle("Show the welcome card on Home", isOn: Binding(get: { !app.heroDismissed }, set: { app.heroDismissed = !$0 }))
            Section("Microphone") {
                LabeledContent("Record from") { MicSourceMenu(status: "No microphone found") }
                Text("Built-in mic, a USB interface, AirPods, or your iPhone (Continuity). “System default” follows the Mac's Sound settings.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
        }
        .formStyle(.grouped)
    }

    private var transcription: some View {
        Form {
            Section {
                Picker("Quality", selection: $app.presetRaw) {
                    ForEach(QualityPreset.allCases) { p in Text("\(p.title) · \(p.note)").tag(p.rawValue) }
                }
                if app.preset == .advanced {
                    Picker("Engine and model", selection: Binding(get: { app.advEngine + "/" + app.advModel }, set: { v in
                        let parts = v.split(separator: "/", maxSplits: 1).map(String.init)
                        if parts.count == 2 { app.advEngine = parts[0]; app.advModel = parts[1] }
                    })) {
                        ForEach(Engines.options) { o in Text("\(o.name) · \(o.note)").tag(o.id) }
                    }
                }
                Text("Parakeet (NVIDIA, via FluidAudio) is the default: fast on Apple silicon with word timings. Whisper is the alternate for languages Parakeet misses. Pick by testing on your own recordings; the labels are starting points, not benchmarks.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                Toggle("Identify speakers", isOn: $app.identifySpeakers)
                Text("Labels turns as Speaker 1, Speaker 2… so you can name them. Runs on this Mac and adds time to each transcript.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
                Toggle("Apply Dictionary to new transcripts", isOn: $app.applyDictionary)
                Text("Only words listed under “Heard as” are replaced, and every fix shows on the transcript.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                Text("Models download once from Hugging Face into Application Support and run on this Mac. Transcription never leaves your computer; fetching a link does need the internet.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
        }
        .formStyle(.grouped)
    }

    private var storage: some View {
        Form {
            LabeledContent("Transcripts and audio") { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) } }
            LabeledContent("Models") { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.models]) } }
            LabeledContent("Launch log") { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) } }
            Text(Paths.root.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.mute)
        }
        .formStyle(.grouped)
    }
}

/// Keep: where kept video and audio go, and whether links keep their video by default.
struct KeepSettings: View {
    @EnvironmentObject var app: AppState
    @State private var folder = Keep.folder
    var body: some View {
        Form {
            Section {
                LabeledContent("Keep folder") {
                    HStack(spacing: 8) {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).foregroundStyle(Ink.dim)
                        Button("Change…") { choose() }
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                }
                Toggle("Keep the video of every link I transcribe", isOn: $app.keepVideoByDefault)
                Text("Video is saved as MP4 (H.264, up to 1080p) with its sound; audio as M4A. Nothing is re-encoded. Notes pinned to a moment get a still from the video.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                Text("Keep only what you have the right to save: your own uploads, Creative Commons, or with permission. Some sites' terms don't allow downloading.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
        }
        .formStyle(.grouped)
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = folder; panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let u = panel.url { Keep.folder = u; folder = u }
    }
}

/// Dictate: the hold-to-talk hotkey, Accessibility status, and project vocabulary.
struct DictationSettings: View {
    @EnvironmentObject var app: AppState
    var body: some View { DictationForm(dictation: app.dictation) }
}

struct DictationForm: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dictation: DictationController
    @State private var trusted = false

    var body: some View {
        Form {
            Section {
                Toggle("Dictate anywhere", isOn: $dictation.enabled)
                Picker("Hold to talk", selection: $dictation.hotkey) {
                    ForEach(DictationController.Hotkey.allCases) { Text($0.title).tag($0) }
                }
                Text("Hold the key in any app, speak, let go. The words are transcribed on this Mac and pasted where your cursor is. Recordings shorter than half a second are dropped.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                LabeledContent("Accessibility access") {
                    HStack(spacing: 8) {
                        Circle().fill(trusted ? Ink.lime : Ink.coral).frame(width: 8, height: 8)
                        Text(trusted ? "Allowed" : "Needed")
                        if !trusted {
                            Button("Allow…") { dictation.requestAccessibility() }
                            Button("Open System Settings") { dictation.openAccessibilitySettings() }
                        }
                    }
                }
                Text("macOS requires this so Verbatim can notice the hold key and press ⌘V in the other app. Nothing is read from other apps.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
            Section {
                Toggle("Project vocabulary", isOn: $app.projectScopedVocabulary)
                Text("Dictionary fixes you save from a transcript inside a project apply only to that project. Off, every fix applies everywhere.")
                    .font(.system(size: 12)).foregroundStyle(Ink.mute)
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = dictation.accessibilityTrusted }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let now = dictation.accessibilityTrusted
            if now != trusted { trusted = now; dictation.refreshMonitors() }
        }
    }
}

struct ElapsedText: View {
    @ObservedObject var live: LiveMeter
    var body: some View { Text(live.elapsed.timecode).font(.system(size: 13, design: .monospaced)) }
}

/// The menu bar panel: record from anywhere, jump back to the app.
struct MenuBarPanel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandMark().frame(width: 20, height: 20)
                Text("Verbatim").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌥⇧R to record").font(.system(size: 11)).foregroundStyle(Ink.mute)
            }
            if app.recorder.isRecording {
                HStack(spacing: 10) {
                    RecordButton(size: 22)
                    ElapsedText(live: app.recorder.live)
                    Spacer()
                    Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }
                    Button("Stop") { app.stopRecording() }.buttonStyle(.borderedProminent).tint(Ink.ink)
                }
                .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if app.capture.isCapturing {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(Ink.iris)
                    HStack(spacing: 4) { Text("Capturing \(app.capture.appName) ·").font(.system(size: 12.5)); ElapsedText(live: app.capture.live) }
                    Spacer()
                    Button("Stop") { app.stopCapture() }.buttonStyle(.borderedProminent).tint(Ink.ink)
                }
                .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Button { NSApp.activate(ignoringOtherApps: true); app.requestRecord() } label: {
                    HStack(spacing: 10) { RecordButton(size: 26); Text("Record voice memo").font(.system(size: 13, weight: .medium)); Spacer() }
                        .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
                Button { NSApp.activate(ignoringOtherApps: true); app.pickApp() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(Ink.iris).frame(width: 26)
                        Text("Capture an app's audio").font(.system(size: 13, weight: .medium)); Spacer()
                    }
                    .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
            }
            if let last = app.store.live.first {
                Button { NSApp.activate(ignoringOtherApps: true); app.go(.transcript(last.id)) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: last.source.symbol).foregroundStyle(.white).frame(width: 26, height: 26)
                            .background(Ink.coral, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(last.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text("Last transcript · \(last.duration.timecode)").font(.system(size: 11)).foregroundStyle(Ink.mute)
                        }
                        Spacer()
                    }
                    .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let last = app.dictation.lastResult, !last.isEmpty {
                Button { app.dictation.copyLast() } label: {
                    HStack(spacing: 8) { Image(systemName: "doc.on.clipboard").foregroundStyle(Ink.iris).frame(width: 26); Text("Copy last dictation").font(.system(size: 12.5, weight: .medium)); Spacer() }
                        .padding(10).background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Open Verbatim") { NSApp.activate(ignoringOtherApps: true); app.go(.home) }.buttonStyle(.plain).foregroundStyle(Ink.iris).fontWeight(.medium)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Ink.mute)
            }
            .font(.system(size: 12.5))
        }
        .padding(12).frame(width: 320).background(Ink.paper)
    }
}
