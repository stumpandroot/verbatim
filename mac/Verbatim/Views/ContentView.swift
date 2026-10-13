import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var sidebarOpen = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if sidebarOpen {
                Sidebar()
                    .frame(width: 208)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                Ink.paper
                screenView
                    .id(screenKey)
                    .transition(transition)
            }
            .clipped()
            .overlay(alignment: .bottom) { ToastView() }
        }
        .background(Ink.paper)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(Motion.settle) { sidebarOpen.toggle() } } label: { Image(systemName: "sidebar.left") }
                    .help("Hide or show the sidebar")
            }
            ToolbarItem(placement: .principal) {
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    TextField("Search transcripts", text: $app.search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($searchFocused)
                        .onChange(of: app.search) { _, v in if !v.isEmpty, case .transcript = app.screen { app.go(.home) } }
                    if case .transcript(let id) = app.screen, let t = app.store.transcript(id) {
                        ExportMenu(transcript: t)
                    }
                    Button { app.go(.home); app.focusLink.toggle() } label: {
                        Label("New Transcript", systemImage: "plus").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent).tint(Ink.ink)
                }
            }
        }
        .onChange(of: app.focusSearch) { _, _ in searchFocused = true }
        .sheet(isPresented: $app.showMicSheet) { MicSheet() }
        .onDrop(of: [.fileURL], isTargeted: nil) { app.handleDrop($0) }
    }

    private var title: String {
        switch app.screen {
        case .home: return "Verbatim"
        case .dictionary: return "Dictionary"
        case .transcript(let id): return app.store.transcript(id)?.title ?? "Transcript"
        }
    }

    private var screenKey: String {
        switch app.screen {
        case .home: return "home"
        case .dictionary: return "dict"
        case .transcript(let id): return "t-\(id)"
        }
    }

    @ViewBuilder private var screenView: some View {
        switch app.screen {
        case .home: HomeView()
        case .dictionary: DictionaryPlaceholder()
        case .transcript(let id): TranscriptView(id: id)
        }
    }

    /// Slides by direction: push from the right, pop to the right, sidebar order up or down.
    private var transition: AnyTransition {
        switch app.direction {
        case .push: return .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity))
        case .pop: return .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .move(edge: .trailing).combined(with: .opacity))
        case .up: return .asymmetric(insertion: .offset(y: 40).combined(with: .opacity), removal: .offset(y: -24).combined(with: .opacity))
        case .down: return .asymmetric(insertion: .offset(y: -40).combined(with: .opacity), removal: .offset(y: 24).combined(with: .opacity))
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                BrandMark().frame(width: 24, height: 24)
                Text("Verbatim").font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 9).padding(.top, 10).padding(.bottom, 10)

            SideItem(label: "Home", symbol: "house", selected: app.screen == .home) { app.go(.home) }
            SideItem(label: "All Transcripts", symbol: "list.bullet", selected: false) { app.go(.home) }
            SideItem(label: "Dictionary", symbol: "book.closed", selected: app.screen == .dictionary) { app.go(.dictionary) }

            if !app.store.transcripts.isEmpty {
                Text("Recent").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.mute)
                    .padding(.horizontal, 9).padding(.top, 16).padding(.bottom, 6)
                ForEach(app.store.transcripts.prefix(5)) { t in
                    SideItem(label: t.title, symbol: nil, selected: app.screen == .transcript(t.id)) { app.go(.transcript(t.id)) }
                }
            }
            Spacer()
            SettingsLink {
                HStack { Image(systemName: "gearshape"); Text("Settings"); Spacer(); Text("⌘,").font(.system(size: 11)).foregroundStyle(Ink.mute) }
                    .padding(.horizontal, 9).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .font(.system(size: 13))
        .foregroundStyle(Ink.ink)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ink.side)
        .overlay(alignment: .trailing) { Ink.hairline.frame(width: 1) }
    }
}

struct SideItem: View {
    var label: String
    var symbol: String?
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let s = symbol { Image(systemName: s).frame(width: 17) }
                Text(label).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color(hex: 0xE4DDFB) : hover ? Color.black.opacity(0.05) : .clear)
            )
            .foregroundStyle(selected ? Color(hex: 0x3B2FB0) : Ink.ink)
            .fontWeight(selected ? .medium : .regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.snap, value: selected)
    }
}

struct BrandMark: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x8C78FF), Color(hex: 0x5D48D8)], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(alignment: .bottom, spacing: 2) {
                Capsule().fill(.white).frame(width: 3, height: 13)
                Capsule().fill(Color(hex: 0xFF8A6A)).frame(width: 3, height: 9)
                Capsule().fill(Color(hex: 0xC4EA7E)).frame(width: 3, height: 6)
            }
            .padding(.bottom, 5)
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let t = app.toast {
            HStack(spacing: 14) {
                Text(t.message).font(.system(size: 13))
                if let a = t.action {
                    Button(a) { t.onAction?(); app.toast = nil }
                        .buttonStyle(.plain).foregroundStyle(Color(hex: 0xC9BFFF)).fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Ink.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(.white)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: t.id) {
                try? await Task.sleep(nanoseconds: 4_200_000_000)
                if app.toast == t { withAnimation(Motion.settle) { app.toast = nil } }
            }
        }
    }
}

// MARK: - Mic permission sheet

struct MicSheet: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 8) {
            VerbieView(pose: .permission).frame(width: 90, height: 100)
            Text("Verbatim wants to use the microphone").font(.system(size: 15, weight: .semibold))
            Text("Voice memos are recorded and transcribed on this Mac. Nothing is uploaded.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Not now") { app.showMicSheet = false; app.verbiePose = .ready }.buttonStyle(.bordered)
                Button("Allow") { app.allowMic() }.buttonStyle(.borderedProminent).tint(Ink.iris).keyboardShortcut(.defaultAction)
            }.padding(.top, 8)
        }
        .padding(24).frame(width: 360)
        .background(Ink.paper)
    }
}

struct DictionaryPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            VerbieView(pose: .working).frame(width: 110, height: 130)
            Text("Dictionary arrives in the next build").font(.system(size: 15, weight: .semibold))
            Text("Correct a word in a transcript, choose Remember, and Verbatim spells it your way from then on.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExportMenu: View {
    var transcript: Transcript
    var body: some View {
        Menu {
            ForEach(ExportFormat.allCases) { f in
                Button("Export \(f.rawValue)…") { Exporter.save(transcript, as: f) }
            }
            Divider()
            Button("Copy Text") { Exporter.copy(transcript) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(transcript.status != .ready)
    }
}
