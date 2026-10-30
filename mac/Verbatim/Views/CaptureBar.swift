import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Capture bar menus (right-click a segment)

/// Record's right-click menu: the six ways to record, the microphone, and Settings.
struct RecordMenu: View {
    @EnvironmentObject var app: AppState
    var onChange: () -> Void = {}
    var body: some View {
        let selected = AudioDevices.selectedUID
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

/// The six ways to record, in the iPhone tray's order (mockup "Record as", October 26, 2026; `RecordChoice.all`):
/// Record (a voice note; Verbose picks the kind), Record a meeting (the meeting capture, which files its transcript as a
/// Meeting), an interview, a journal entry, or a talk (yours from the start, so AutoLabel leaves the kind and Run
/// automatically runs its template), and New thought (as ⌃⌥P). Each item carries Verbose's glyph for it as a custom
/// symbol (`mac/tools/gen_symbol.py`), so the menu draws it in its own text color: neutral, and white when highlighted.
/// `activate` brings Verbose forward first (the menu bar's panel); a thought never does.
struct RecordKindMenuItems: View {
    @EnvironmentObject var app: AppState
    var titles: KeyPath<RecordChoice, String> = \.menuTitle
    var activate = false
    @ObservedObject private var meeting = MeetingSession.shared
    /// The rows you show (consolidation, October 28, 2026: five by default; Edit Record As… turns the others on).
    @ObservedObject private var rows = RecordAsStore.shared
    var body: some View {
        ForEach(rows.visible) { c in
            Button {
                if activate, c != .thought { NSApp.activate(ignoringOtherApps: true) }
                app.startRecordChoice(c)
            } label: { Label(c[keyPath: titles], image: c.symbolName) }
            .disabled(c == .kind(.meeting) && meeting.isActive)
        }
        Divider()
        Button("Edit Record As…") { EditRecordAsWindow.open() }
    }
}

/// Edit Record As (the last item of every Record As menu on the Mac): every way to record with a switch, so a row you
/// hid (Interview, Journal entry, and Talk start hidden) comes back. Voice note always shows. A small window of its
/// own, sized here and never from its content.
@MainActor
enum EditRecordAsWindow {
    private static var window: NSWindow?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: RecordAsEditor().limitMotionRoot())
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = "Edit Record As"
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 380, height: 440))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.orderOut(nil) }
    static var isOpen: Bool { window?.isVisible == true }
}

/// The rows of Record As with a switch each, in its order, and what each one does, on the refined kit (DESIGN.md §13):
/// the rows in a card on paper, each with its kind's colored square.
struct RecordAsEditor: View {
    @ObservedObject private var rows = RecordAsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose the ways to record that Record As shows. The others stay kinds you can pick with Change kind.")
                .refinedFont(.meta).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
            PaperCard {
                ForEach(RecordChoice.all) { c in
                    HStack(spacing: 10) {
                        IconSquare(art: c.art, hue: c.refinedHue)
                        Text(c.name).refinedFont(.rowTitle).foregroundStyle(Refined.ink)
                        Spacer(minLength: 8)
                        Toggle(c.name, isOn: Binding(get: { rows.rows.isShown(c) }, set: { rows.set(c, shown: $0) }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            .refinedSwitchTint()
                            .disabled(!RecordAsRows.canHide(c))
                            .uiTarget("record-as-edit-\(c.id)")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    if c != RecordChoice.all.last { PaperDivider(leading: 44, trailing: 12) }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Refined.paper)
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
                .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
            Button { done(); app.chooseMultitrack() } label: { Label("Multi-track recording…", art: .iconMultitrack, size: 15) }
                .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
                .help("One audio file per mic, recorded at the same time. Each file becomes a speaker.")
            Text("Or paste a link").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("https://…", text: $link).textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit)
                Button("Fetch", action: submit).buttonStyle(.borderedProminent).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
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
            .font(.system(size: 13)).foregroundStyle(Refined.dim)
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
                    IconGlyph(art: .iconDictations, size: 20, color: Refined.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.dictation.hotkey.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Refined.ink)
                        Text(app.dictation.enabled ? "\(app.dictation.hotkey.shortTitle.prefix(1).uppercased() + app.dictation.hotkey.shortTitle.dropFirst()) in any app, or click \(DictationSurface.stored().clickHint). Settings › Dictation and keyboard has cleanup, styles, and snippets." : "Dictation is off. Turn it on in Settings › Dictation and keyboard.").font(.system(size: 12.5)).foregroundStyle(Refined.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                // The reason wraps (a popover sizes to one line otherwise and cuts it off), then one prominent button.
                HStack(alignment: .top, spacing: 10) {
                    IconGlyph(art: .iconAccessibility, size: 20, color: Refined.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs Accessibility access").font(.system(size: 15, weight: .bold)).foregroundStyle(Refined.ink)
                        Text("Verbose needs it to hear the key and paste into other apps. It reads nothing from them.").font(.system(size: 12.5)).foregroundStyle(Refined.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("Open Accessibility settings") { app.dictation.requestAccessibility(); app.dictation.openAccessibilitySettings() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .padding(.leading, 30)
            }
            if let last = app.dictation.lastResult, !last.isEmpty {
                HStack(spacing: 8) {
                    Text("Last: “\(last.prefix(70))\(last.count > 70 ? "…" : "")”").font(.system(size: 12)).foregroundStyle(Refined.mute).lineLimit(1)
                    Button("Copy") { app.dictation.copyLast() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.ink).underline()
                }
            }
        }
        .frame(width: DictateControls.width, alignment: .leading)
    }
    /// A fixed width, so the popover's text wraps instead of truncating (review M-01).
    static let width: CGFloat = 320
}

// MARK: - Shared pieces

struct RecordButton: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Refined.persimmon)
            BrandGlyph(art: .capture, color: Refined.inkFixed, minLineWidth: 1.2).padding(size * 0.2)
        }
        .frame(width: size, height: size)
    }
}
