import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            transcription.tabItem { Label("Transcription", systemImage: "text.alignleft") }
            storage.tabItem { Label("Storage", systemImage: "externaldrive") }
        }
        .frame(width: 560)
        .padding(.bottom, 10)
    }

    private var general: some View {
        Form {
            Toggle("Show in menu bar", isOn: $app.showMenuBar)
            Text("Record from anywhere with the menu bar item, or press ⌥⇧R while Verbatim is running.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute)
            Toggle("Sounds", isOn: $app.sounds)
            Text("A short chime when recording starts and a tick when a transcript is ready. Off automatically with Reduce Motion.")
                .font(.system(size: 12)).foregroundStyle(Ink.mute)
            Toggle("Show the welcome card on Home", isOn: Binding(get: { !app.heroDismissed }, set: { app.heroDismissed = !$0 }))
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
                    Text(app.recorder.elapsed.timecode).font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Button(app.recorder.isPaused ? "Resume" : "Pause") { app.togglePause() }
                    Button("Stop") { app.stopRecording() }.buttonStyle(.borderedProminent).tint(Ink.ink)
                }
                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if app.capture.isCapturing {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(Ink.iris)
                    Text("Capturing \(app.capture.appName) · \(app.capture.elapsed.timecode)").font(.system(size: 12.5))
                    Spacer()
                    Button("Stop") { app.stopCapture() }.buttonStyle(.borderedProminent).tint(Ink.ink)
                }
                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Button { NSApp.activate(ignoringOtherApps: true); app.requestRecord() } label: {
                    HStack(spacing: 10) { RecordButton(size: 26); Text("Record voice memo").font(.system(size: 13, weight: .medium)); Spacer() }
                        .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
                Button { NSApp.activate(ignoringOtherApps: true); app.pickApp() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(Ink.iris).frame(width: 26)
                        Text("Capture an app's audio").font(.system(size: 13, weight: .medium)); Spacer()
                    }
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pressable()
            }
            if let last = app.store.transcripts.first {
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
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
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
