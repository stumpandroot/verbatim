import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var sidebarOpen = true

    var body: some View {
        if UITest.enabled { Log.note("UITEST render screen=\(screenKey) nav=\(app.navCount)") }
        return HStack(spacing: 0) {
            if sidebarOpen {
                Sidebar().frame(width: 244).transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .identity))
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
            .animation(Motion.nav, value: app.navCount)
            .overlay(alignment: .bottom) { ToastView() }
        }
        .background(Ink.paper)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(Motion.settle) { sidebarOpen.toggle() } } label: { Image(systemName: "sidebar.left") }
                    .help("Hide or show the sidebar")
            }
        }
        .searchable(text: $app.search, placement: .toolbar, prompt: "Search transcripts")
        .onChange(of: app.search) { _, v in if !v.isEmpty, app.screen != .library { app.go(.library) } }
        .sheet(isPresented: $app.showMicSheet) { MicSheet() }
        .sheet(isPresented: $app.showAppPicker) { AppPickerSheet() }
        .onDrop(of: [.fileURL], isTargeted: nil) { app.handleDrop($0) }
        .onAppear { UITest.run(app: app) }
        .onReceive(NotificationCenter.default.publisher(for: .verbatimOpenSettings)) { _ in openSettings() }
        .tint(Ink.switchOn)   // switches and checkboxes in brand sage instead of the system blue
        .sheet(isPresented: $app.showOnboarding) { OnboardingView(startStep: UITest.onboardingStep).environmentObject(app) }
    }

    private var title: String {
        switch app.screen {
        case .home: return "Verbatim"
        case .library: return app.projectFilter.flatMap { id in app.store.projects.first { $0.id == id }?.name } ?? "Library"
        case .queue: return "Queue"
        case .links: return "Links"
        case .moments: return "Moments"
        case .trash: return "Recently Deleted"
        case .dictionary: return "Dictionary"
        case .dictations: return "Dictations"
        case .activity: return "Activity"
        case .transcript(let id): return app.store.transcript(id)?.title ?? "Transcript"
        }
    }

    private var screenKey: String {
        switch app.screen {
        case .home: return "home"
        case .library: return "library"
        case .queue: return "queue"
        case .links: return "links"
        case .moments: return "moments"
        case .trash: return "trash"
        case .dictionary: return "dict"
        case .dictations: return "dictations"
        case .activity: return "activity"
        case .transcript(let id): return "t-\(id)"
        }
    }

    @ViewBuilder private var screenView: some View {
        switch app.screen {
        case .home: HomeView()
        case .library: LibraryView()
        case .queue: QueueView()
        case .links: LinksView()
        case .moments: MomentsView()
        case .trash: TrashView()
        case .dictionary: DictionaryView()
        case .dictations: DictationsView()
        case .activity: ActivityView()
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
        case .push: return .asymmetric(insertion: ScreenSlide.transition(x: 24), removal: .identity)
        case .pop: return .asymmetric(insertion: ScreenSlide.transition(x: -24), removal: .identity)
        case .up: return .asymmetric(insertion: ScreenSlide.transition(y: 14), removal: .identity)
        case .down: return .asymmetric(insertion: ScreenSlide.transition(y: -14), removal: .identity)
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
            // Compact lockup: the ribbon mark and the tracked uppercase wordmark (logo_lockup, small).
            HStack(spacing: 9) {
                RibbonMark(color: Ink.persimmon).frame(width: 26, height: 20)
                Text("VERBATIM").font(.system(size: 13.5, weight: .bold)).tracking(2.2).foregroundStyle(Ink.ink)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 22)
            .accessibilityElement(children: .ignore).accessibilityLabel("Verbatim")

            SideItem(label: "Home", symbol: "house", selected: app.screen == .home, pill: pill) { app.go(.home) }
                .uiTarget("side-home")
            SideItem(label: "Library", symbol: "doc.text", selected: app.screen == .library && app.projectFilter == nil, pill: pill, onDropIDs: { app.move($0, to: nil) }) { app.projectFilter = nil; app.go(.library) }
                .uiTarget("side-library")
            SideItem(label: "Links", symbol: "link", selected: app.screen == .links, badge: nil, pill: pill) { app.go(.links) }
                .uiTarget("side-links")
            SideItem(label: "Moments", symbol: "bookmark", selected: app.screen == .moments, pill: pill) { app.go(.moments) }
                .uiTarget("side-moments")
            SideItem(label: "Queue", symbol: "list.bullet", selected: app.screen == .queue,
                     badge: app.queue.count + (app.runningID == nil ? 0 : 1) == 0 ? nil : "\(app.queue.count + (app.runningID == nil ? 0 : 1))", busy: app.runningID != nil, pill: pill) { app.go(.queue) }
                .uiTarget("side-queue")
            SideItem(label: "Dictations", symbol: "waveform", selected: app.screen == .dictations, badge: nil, pill: pill) { app.go(.dictations) }
                .uiTarget("side-dictations")
            SideItem(label: "Activity", symbol: "chart.bar.xaxis", selected: app.screen == .activity, badge: nil, pill: pill) { app.go(.activity) }
                .uiTarget("side-activity")
            SideItem(label: "Dictionary", symbol: "book", selected: app.screen == .dictionary, badge: app.store.dictionary.isEmpty ? nil : "\(app.store.dictionary.count)", pill: pill) { app.go(.dictionary) }
                .uiTarget("side-dict")

            HStack {
                Overline(text: "Projects", color: Ink.mute)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 22, height: 22).hoverChip().tapArea { newProject = true }
                    .help("New project")
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.top, 18).padding(.bottom, 4)
            ForEach(app.store.projects) { p in
                SideItem(label: p.name, symbol: "folder.fill", symbolColor: [Ink.persimmon, Ink.sageText, Ink.petal][p.colorIndex % 3],
                         selected: app.screen == .library && app.projectFilter == p.id, pill: pill, onDropIDs: { app.move($0, to: p.id) }) { app.projectFilter = p.id; app.go(.library) }
                    .contextMenu { Button("Delete project", role: .destructive) {
                        app.store.projects.removeAll { $0.id == p.id }
                        if app.projectFilter == p.id { app.projectFilter = nil }
                        if FlowSettings.shared.activeProject == p.id { FlowSettings.shared.activeProject = nil }
                        // Its words would never apply again; they go back to working everywhere.
                        for i in app.store.dictionary.indices where app.store.dictionary[i].projectId == p.id { app.store.dictionary[i].projectId = nil }
                    } }
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
            if !app.store.trash.isEmpty || app.screen == .trash {
                SideItem(label: "Recently Deleted", symbol: "trash", selected: app.screen == .trash, badge: "\(app.store.trash.count)", pill: pill) { app.go(.trash) }
                    .padding(.bottom, 6)
            }
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 8).padding(.bottom, 8)
            HStack(spacing: 12) {
                Image(systemName: Cloud.enabled ? "icloud" : "laptopcomputer").frame(width: 19)
                Text(Cloud.enabled ? "Syncing with iCloud" : "On this Mac")
            }
            .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .help(Cloud.enabled
                  ? "Transcripts, notes, projects, and the Dictionary sync with your iPhone through your iCloud Drive. Models and recordings in progress stay on this Mac."
                  : "iCloud is off for Verbatim, so everything stays in ~/Library/Application Support/Verbatim. Sign in to iCloud with iCloud Drive on, and run a build signed with your team, to sync with your iPhone.")
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
        .modifier(SidebarGlass())
        .ignoresSafeArea(edges: .top)
    }
}

/// The sidebar as a floating pane of glass, inset from the window edges (the macOS 26 inset sidebar).
/// Native Liquid Glass on macOS 26, lightly warmed with paper, with a thin light rim along the top-left edge;
/// the native sidebar material on earlier versions. Reduce Transparency and Increase Contrast make it opaque
/// automatically. Text on it is navigation only, at full ink, never body copy.
struct SidebarGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let rim = shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.85), Color.white.opacity(0), Color.white.opacity(scheme == .dark ? 0.08 : 0.3)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        return Group {
            if #available(macOS 26, *) {
                content
                    .glassEffect(.regular.tint(Ink.paper.opacity(scheme == .dark ? 0.25 : 0.4)), in: shape)
                    .overlay(rim.allowsHitTesting(false))
            } else {
                content
                    .background(VisualEffect(material: .sidebar, blending: .withinWindow).clipShape(shape))
                    .overlay(shape.strokeBorder(Ink.hairline))
                    .overlay(rim.allowsHitTesting(false))
            }
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.08), radius: 12, x: 0, y: 4)
        .padding(.leading, 8).padding(.vertical, 8)
    }
}

struct SideItem: View {
    var label: String
    var symbol: String?
    var symbolColor: Color? = nil
    var selected: Bool
    var badge: String? = nil
    var busy = false
    var pill: Namespace.ID
    /// Makes the row a drop target for dragged transcripts.
    var onDropIDs: (([UUID]) -> Void)? = nil
    var action: () -> Void
    @State private var hover = false
    @State private var dropping = false

    var body: some View {
        HStack(spacing: 12) {
            if let s = symbol { Image(systemName: s).font(.system(size: 14.5, weight: .regular)).frame(width: 19).foregroundStyle(symbolColor ?? Ink.ink) }
            Text(label).lineLimit(1)
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.mini) }
            if let b = badge { Text(b).font(.system(size: 11)).foregroundStyle(Ink.mute) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            ZStack {
                // Hover previews (light iris tint); selection says where you are (lifted white glass + iris marker).
                if dropping { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.accentSubtle).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.persimmon, lineWidth: 1.5)) }
                else if hover && !selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.ink.opacity(0.06)) }
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.selectedPill)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.selectedPillEdge, lineWidth: 0.5))
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
        }
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Ink.persimmon).frame(width: 3, height: 18).offset(x: -12).matchedGeometryEffect(id: "marker", in: pill) }
        }
        .foregroundStyle(Ink.ink)
        .fontWeight(selected ? .semibold : .regular)
        .tapArea(action)
        .onHover { hover = $0 }
        .modifier(TranscriptDropTarget(enabled: onDropIDs != nil, dropping: $dropping) { onDropIDs?($0) })
        .animation(Motion.touch, value: hover)
        .animation(Motion.touch, value: dropping)
        .animation(Motion.snap, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
    }
}

/// The ribbon mark in the brand's small spaces.
struct BrandBars: View {
    var body: some View { RibbonMark(color: Ink.persimmon) }
}

/// The app mark for the menu bar panel: the persimmon app icon geometry (app_icon_persimmon).
struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.persimmon)
            RibbonMark(color: Ink.inkFixed).padding(3.5)
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
                        .buttonStyle(.plain).foregroundStyle(Color(nsColor: NSColor(hex: Ink.butterHex))).fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Ink.inkFixed, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(Ink.readerFixed)
            .frame(maxWidth: 520)
            .padding(.bottom, 24)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .identity))
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
            EmptyStateArt(art: .capture, tint: Ink.persimmonTint).padding(.bottom, 4)
            Text("Verbatim wants to use the microphone").font(.system(size: 15, weight: .semibold))
            Text("Voice memos are recorded and transcribed on this Mac. Nothing is uploaded.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Not now") { app.showMicSheet = false; app.verbiePose = .ready }.buttonStyle(.bordered).uiTarget("sheet-notnow")
                Button("Allow") { app.allowMic() }.buttonStyle(.brandPrimary).keyboardShortcut(.defaultAction)
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
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            Button { ExportMenu.copy(transcript, app: app) } label: { ToolLabel(title: "Copy", symbol: "doc.on.doc", compact: compact) }
                .buttonStyle(.plain).help("Copy the text to the clipboard (⌘⇧C)")
            Button { open.toggle() } label: { ToolLabel(title: "Export", symbol: "square.and.arrow.up", compact: compact) }
                .buttonStyle(.plain).help("Export as text, Markdown, Word, subtitles, or JSON")
                .popover(isPresented: $open, arrowEdge: .bottom) { ExportPanel(transcript: transcript, options: $options, done: { open = false }) }
        }
        .disabled(transcript.status != .ready)
        .onChange(of: options) { _, o in o.save() }
    }

    /// Copy with the saved export options. Also bound to ⌘⇧C once per transcript screen.
    static func copy(_ t: Transcript, app: AppState) {
        guard t.status == .ready else { return }
        let options = ExportOptions.saved
        Exporter.copy(t, options: options)
        app.toast = Toast("Copied " + (options.source == .document ? "document" : "transcript"))
        Sounds.done()
    }
}

/// A quiet text-and-icon tool button for the transcript's mode bar.
struct ToolLabel: View {
    var title: String
    var symbol: String
    var compact = false
    var on = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
            if !compact { Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).fixedSize() }
        }
        .foregroundStyle(on ? Ink.iris : Ink.dim)
        .padding(.horizontal, compact ? 7 : 9).frame(height: 28)
        .background(on ? Ink.iris.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .hoverChip()
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
                .buttonStyle(.brandPrimary).frame(maxWidth: .infinity)
        }
        .padding(16).frame(width: 300)
    }
}

/// Accepts transcripts dragged from Home, Library, or the Queue.
struct TranscriptDropTarget: ViewModifier {
    var enabled: Bool
    @Binding var dropping: Bool
    var perform: ([UUID]) -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.plainText, .utf8PlainText, .text], isTargeted: $dropping) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    let ids = TranscriptDrag.ids(from: s)
                    if !ids.isEmpty { DispatchQueue.main.async { perform(ids) } }
                }
                return true
            }
        } else { content }
    }
}
