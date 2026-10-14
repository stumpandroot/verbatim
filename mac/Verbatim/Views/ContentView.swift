import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var sidebarOpen = true

    var body: some View {
        if UITest.enabled { Log.note("UITEST render screen=\(screenKey) nav=\(app.navCount)") }
        return HStack(spacing: 0) {
            if sidebarOpen {
                Sidebar().frame(width: 236).transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                Ink.paper
                // Pin each screen to the space it has. Without this a wide screen pushes the whole row
                // outward and the sidebar slides off the left edge.
                GeometryReader { g in
                    screenView.frame(width: g.size.width, height: g.size.height).id(screenKey).transition(transition).zIndex(Double(app.navCount))
                }
            }
            .clipped()
            .animation(Motion.settle, value: app.navCount)
            .overlay(alignment: .bottom) { ToastView() }
        }
        .background(Ink.paper)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(Motion.settle) { sidebarOpen.toggle() } } label: { Image(systemName: "sidebar.left") }
                    .help("Hide or show the sidebar")
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if case .transcript(let id) = app.screen, let t = app.store.transcript(id) { ExportMenu(transcript: t) }
                }
            }
        }
        .searchable(text: $app.search, placement: .toolbar, prompt: "Search transcripts")
        .onChange(of: app.search) { _, v in if !v.isEmpty, app.screen != .library { app.go(.library) } }
        .sheet(isPresented: $app.showMicSheet) { MicSheet() }
        .sheet(isPresented: $app.showAppPicker) { AppPickerSheet() }
        .onDrop(of: [.fileURL], isTargeted: nil) { app.handleDrop($0) }
        .onAppear { UITest.run(app: app) }
    }

    private var title: String {
        switch app.screen {
        case .home: return "Verbatim"
        case .library: return app.projectFilter.flatMap { id in app.store.projects.first { $0.id == id }?.name } ?? "Library"
        case .dictionary: return "Dictionary"
        case .transcript(let id): return app.store.transcript(id)?.title ?? "Transcript"
        }
    }

    private var screenKey: String {
        switch app.screen {
        case .home: return "home"
        case .library: return "library"
        case .dictionary: return "dict"
        case .transcript(let id): return "t-\(id)"
        }
    }

    @ViewBuilder private var screenView: some View {
        switch app.screen {
        case .home: HomeView()
        case .library: LibraryView()
        case .dictionary: DictionaryView()
        case .transcript(let id): TranscriptView(id: id)
        }
    }

    /// Slides by direction: push from the right, pop to the right, sidebar order up or down.
    /// Both ends of every transition go through `ScreenSlide`, which turns hit-testing off while a screen is
    /// entering or leaving. An outgoing screen can linger when springs are interrupted, and a lingering screen
    /// that still takes clicks is exactly the "have to click twice" bug.
    private var transition: AnyTransition {
        // Removal is instant on purpose: an outgoing screen that animates can get stuck on top, fully drawn,
        // until the next navigation (seen on macOS 26). The incoming screen still slides and fades in.
        switch app.direction {
        case .push: return .asymmetric(insertion: ScreenSlide.transition(x: 60), removal: .identity)
        case .pop: return .asymmetric(insertion: ScreenSlide.transition(x: -60), removal: .identity)
        case .up: return .asymmetric(insertion: ScreenSlide.transition(y: 40), removal: .identity)
        case .down: return .asymmetric(insertion: ScreenSlide.transition(y: -40), removal: .identity)
        }
    }
}

/// A slide-and-fade whose off-screen state cannot be clicked.
struct ScreenSlide: ViewModifier {
    var active: Bool
    var x: CGFloat = 0
    var y: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .offset(x: active ? x : 0, y: active ? y : 0)
            .opacity(active ? 0 : 1)
            .allowsHitTesting(!active)
    }
    static func transition(x: CGFloat = 0, y: CGFloat = 0) -> AnyTransition {
        .modifier(active: ScreenSlide(active: true, x: x, y: y), identity: ScreenSlide(active: false, x: x, y: y))
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @State private var newProject = false
    @State private var projectName = ""
    @Namespace private var pill

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                BrandBars().frame(width: 20, height: 24)
                Text("Verbatim").font(Ink.serif(23))
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 20)

            SideItem(label: "Home", symbol: "house", selected: app.screen == .home, pill: pill) { app.go(.home) }
                .uiTarget("side-home")
            SideItem(label: "Library", symbol: "doc.text", selected: app.screen == .library && app.projectFilter == nil, pill: pill) { app.projectFilter = nil; app.go(.library) }
                .uiTarget("side-library")
            SideItem(label: "Dictionary", symbol: "book", selected: app.screen == .dictionary, badge: app.store.dictionary.isEmpty ? nil : "\(app.store.dictionary.count)", pill: pill) { app.go(.dictionary) }
                .uiTarget("side-dict")

            HStack {
                Text("Projects").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.mute)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 22, height: 22).hoverChip().tapArea { newProject = true }
                    .help("New project")
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.top, 18).padding(.bottom, 4)
            ForEach(app.store.projects) { p in
                SideItem(label: p.name, symbol: "folder.fill", symbolColor: [Ink.coral, Color(hex: 0x9CCB44), Ink.iris][p.colorIndex % 3],
                         selected: app.screen == .library && app.projectFilter == p.id, pill: pill) { app.projectFilter = p.id; app.go(.library) }
                    .contextMenu { Button("Delete project", role: .destructive) { app.store.projects.removeAll { $0.id == p.id }; if app.projectFilter == p.id { app.projectFilter = nil } } }
            }
            if app.store.projects.isEmpty && !newProject {
                Text("Group transcripts by client or job.").font(.system(size: 11.5)).foregroundStyle(Ink.mute).padding(.horizontal, 12).padding(.top, 2)
            }
            if newProject {
                TextField("Project name", text: $projectName, onCommit: {
                    let n = projectName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { app.projectFilter = app.store.addProject(n).id; app.go(.library) }
                    projectName = ""; newProject = false
                })
                .textFieldStyle(.roundedBorder).font(.system(size: 12.5)).padding(.horizontal, 6)
                .onExitCommand { newProject = false; projectName = "" }
            }
            Spacer()
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 8).padding(.bottom, 8)
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").frame(width: 19)
                Text("On this Mac")
            }
            .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .help("Recordings, transcripts, and models stay in ~/Library/Application Support/Verbatim. Nothing is uploaded.")
            SettingsLink {
                HStack(spacing: 12) { Image(systemName: "gearshape").frame(width: 19); Text("Settings"); Spacer(); Text("⌘,").font(.system(size: 11)).foregroundStyle(Ink.mute) }
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
                    .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverChip(radius: 10)
        }
        .padding(.horizontal, 12).padding(.top, 40).padding(.bottom, 12)
        .font(.system(size: 14.5))
        .foregroundStyle(Ink.ink)
        .frame(maxHeight: .infinity, alignment: .top)
        // Glass belongs to navigation: the system sidebar material (blends with the desktop behind the
        // window), a faint lavender tint, and a fine trailing separator. Labels sit on it at full contrast.
        .background(Color(hex: 0xF1EDFA).opacity(0.55))
        .background(VisualEffect(material: .sidebar, blending: .behindWindow))
        .overlay(alignment: .trailing) { Ink.iris.opacity(0.14).frame(width: 1) }
        .ignoresSafeArea(edges: .top)
    }
}

struct SideItem: View {
    var label: String
    var symbol: String?
    var symbolColor: Color? = nil
    var selected: Bool
    var badge: String? = nil
    var pill: Namespace.ID
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            if let s = symbol { Image(systemName: s).font(.system(size: 15, weight: .regular)).frame(width: 19).foregroundStyle(symbolColor ?? (selected ? Ink.iris : Ink.ink)) }
            Text(label).lineLimit(1)
            Spacer(minLength: 0)
            if let b = badge { Text(b).font(.system(size: 11)).foregroundStyle(Ink.mute) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            ZStack {
                // Hover previews (light iris tint); selection says where you are (lifted white glass + iris marker).
                if hover && !selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.iris.opacity(0.07)) }
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.66))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5))
                        .shadow(color: Ink.ink.opacity(0.06), radius: 1.5, y: 1)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
        }
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Ink.iris).frame(width: 3, height: 20).offset(x: -12).matchedGeometryEffect(id: "marker", in: pill) }
        }
        .foregroundStyle(Ink.ink)
        .fontWeight(selected ? .semibold : .regular)
        .tapArea(action)
        .onHover { hover = $0 }
        .animation(Motion.touch, value: hover)
        .animation(Motion.snap, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
    }
}

/// The three-bar brand mark: iris, coral, lime.
struct BrandBars: View {
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            Capsule().fill(Ink.iris).frame(width: 4, height: 16)
            Capsule().fill(Ink.coral).frame(width: 4, height: 24)
            Capsule().fill(Color(hex: 0x9CCB44)).frame(width: 4, height: 13)
        }
    }
}

/// The old square app mark (menu bar panel).
struct BrandMark: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x8C78FF), Color(hex: 0x5D48D8)], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(alignment: .bottom, spacing: 2) {
                Capsule().fill(.white).frame(width: 3.5, height: 14)
                Capsule().fill(Color(hex: 0xFF8A6A)).frame(width: 3.5, height: 10)
                Capsule().fill(Color(hex: 0xC4EA7E)).frame(width: 3.5, height: 7)
            }
            .padding(.bottom, 5)
        }
    }
}

/// A native AppKit material (sidebar, popover, HUD) for SwiftUI.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .withinWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = blending; v.state = .followsWindowActiveState; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending }
}

// MARK: - Toast

struct ToastView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let t = app.toast {
            HStack(spacing: 14) {
                Text(t.message).font(.system(size: 13)).lineLimit(2)
                if let a = t.action {
                    Button(a) { t.onAction?(); app.toast = nil }
                        .buttonStyle(.plain).foregroundStyle(Color(hex: 0xC9BFFF)).fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Ink.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(.white)
            .frame(maxWidth: 520)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: t.id) {
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                if app.toast == t { withAnimation(Motion.settle) { app.toast = nil } }
            }
        }
    }
}

// MARK: - Sheets

struct MicSheet: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 8) {
            VerbieView(pose: .permission, tracksPointer: false).frame(width: 80, height: 110)
            Text("Verbatim wants to use the microphone").font(.system(size: 15, weight: .semibold))
            Text("Voice memos are recorded and transcribed on this Mac. Nothing is uploaded.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Not now") { app.showMicSheet = false; app.verbiePose = .ready }.buttonStyle(.bordered).uiTarget("sheet-notnow")
                Button("Allow") { app.allowMic() }.buttonStyle(.borderedProminent).tint(Ink.iris).keyboardShortcut(.defaultAction)
            }.padding(.top, 8)
        }
        .padding(24).frame(width: 360).background(Ink.paper)
    }
}

struct AppPickerSheet: View {
    @EnvironmentObject var app: AppState
    @State private var apps: [AppAudioCapture.RunningApp] = []
    @State private var error: String?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture audio from").font(.system(size: 15, weight: .semibold))
            Text("Pick the app that is playing. macOS asks once for Screen & System Audio Recording; Verbatim keeps only the audio, on this Mac.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.dim)
            TextField("Filter apps", text: $filter).textFieldStyle(.roundedBorder)
            if let e = error {
                Text(e).font(.system(size: 12.5)).foregroundStyle(Ink.coral)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(apps.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { a in
                        Button { app.startCapture(a) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.id)?.path ?? ""))
                                    .resizable().frame(width: 22, height: 22)
                                Text(a.name).font(.system(size: 13))
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 280)
            HStack { Spacer(); Button("Cancel") { app.showAppPicker = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 420).background(Ink.paper)
        .task {
            do { apps = try await AppAudioCapture.runningApps() }
            catch { self.error = "Couldn't list apps: \(error.localizedDescription). Allow Verbatim under Privacy & Security › Screen & System Audio Recording, then try again." }
        }
    }
}

/// Copy and Export with the options people expect: which text, speaker names, timecodes, one paragraph.
struct ExportMenu: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var open = false
    @State private var options = ExportOptions.saved
    var body: some View {
        HStack(spacing: 6) {
            Button {
                Exporter.copy(transcript, options: options)
                app.toast = Toast("Copied " + (options.source == .document ? "document" : "transcript"))
                Sounds.done()
            } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the text to the clipboard (⌘⇧C)").keyboardShortcut("c", modifiers: [.command, .shift])
            Button { open.toggle() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .popover(isPresented: $open, arrowEdge: .bottom) { ExportPanel(transcript: transcript, options: $options, done: { open = false }) }
        }
        .disabled(transcript.status != .ready)
        .onChange(of: options) { _, o in o.save() }
    }
}

struct ExportPanel: View {
    var transcript: Transcript
    @Binding var options: ExportOptions
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.system(size: 14, weight: .bold))
            Picker("Text", selection: $options.source) { ForEach(ExportOptions.Source.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Text(options.source == .document ? "Paragraphs with your edits and polish." : "Line by line, as transcribed.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Speaker names", isOn: $options.speakers).disabled(transcript.speakers.count < 2)
                Toggle("Timecodes", isOn: $options.timecodes)
                Toggle("One paragraph", isOn: $options.singleParagraph)
                Toggle("Add a “transcribed with” footer", isOn: $options.provenance)
            }
            .toggleStyle(.checkbox).font(.system(size: 12.5))
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ExportFormat.allCases) { f in
                    Button { done(); Exporter.save(transcript, as: f, options: options) } label: {
                        HStack { Text(f.rawValue).fontWeight(.medium); Spacer(); Text(f.timed ? "with timecodes" : f.note).foregroundStyle(.secondary) }
                            .font(.system(size: 12.5)).padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { done(); Exporter.copy(transcript, options: options) } label: { Label("Copy to clipboard", systemImage: "doc.on.doc") }
                .buttonStyle(.borderedProminent).tint(Ink.iris).frame(maxWidth: .infinity)
        }
        .padding(16).frame(width: 300)
    }
}
