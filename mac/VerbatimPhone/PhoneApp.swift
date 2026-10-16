import SwiftUI

@main
struct VerbatimPhoneApp: App {
    @StateObject private var app = PhoneState()
    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environmentObject(app)
                .preferredColorScheme(app.colorScheme)
                .tint(Ink.ink)
        }
    }
}

/// Four tabs in the system tab bar (Liquid Glass on iOS 26). Paper underneath; the recorder covers the screen.
struct PhoneRoot: View {
    @EnvironmentObject var app: PhoneState

    var body: some View {
        TabView(selection: $app.tab) {
            NavigationStack(path: $app.homePath) {
                HomeScreen()
                    .navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
                    .navigationDestination(for: DocumentRoute.self) { TranscriptScreen(id: $0.id, startMode: .document) }
            }
            .tabItem { Label("Home", systemImage: "house") }.tag(PhoneState.Tab.home)

            NavigationStack(path: $app.libraryPath) {
                LibraryScreen().navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }.tag(PhoneState.Tab.library)

            NavigationStack(path: $app.momentsPath) {
                MomentsScreen().navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
            }
            .tabItem { Label("Moments", systemImage: "bookmark") }.tag(PhoneState.Tab.moments)

            NavigationStack { SettingsScreen() }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(PhoneState.Tab.settings)
        }
        .fullScreenCover(isPresented: $app.showRecorder) { RecordScreen() }
        .sheet(isPresented: $app.showLinkSheet) { LinkSheet().presentationDetents([.medium]) }
        .fileImporter(isPresented: $app.showImporter, allowedContentTypes: [.audio, .movie, .audiovisualContent], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { app.importFiles(urls) }
        }
        .overlay(alignment: .top) {
            if let t = app.toast {
                Text(t).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.readerFixed)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Ink.inkFixed, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(Motion.settle, value: app.toast)
    }
}
