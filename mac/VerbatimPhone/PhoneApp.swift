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
                .limitMotionRoot()   // Reduce Motion or Settings › Limit animation → \.limitMotion everywhere
        }
    }
}

/// Four tabs in the system tab bar (Liquid Glass on iOS 26). Paper underneath; the recorder covers the screen.
struct PhoneRoot: View {
    @EnvironmentObject var app: PhoneState
    @State private var newProjectName = ""

    var body: some View {
        TabView(selection: $app.tab) {
            NavigationStack(path: $app.homePath) {
                HomeScreen()
                    .navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
                    .navigationDestination(for: DocumentRoute.self) { TranscriptScreen(id: $0.id, startMode: .document) }
            }
            .tabItem { Label { Text("Home") } icon: { Image(uiImage: BrandArt.iconHome.templateImage(size: 26, key: "iconHome")) } }.tag(PhoneState.Tab.home)

            NavigationStack(path: $app.libraryPath) {
                LibraryScreen().navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
            }
            .tabItem { Label { Text("Library") } icon: { Image(uiImage: BrandArt.iconLibrary.templateImage(size: 26, key: "iconLibrary")) } }.tag(PhoneState.Tab.library)

            NavigationStack(path: $app.momentsPath) {
                MomentsScreen().navigationDestination(for: UUID.self) { TranscriptScreen(id: $0) }
            }
            .tabItem { Label { Text("Moments") } icon: { Image(uiImage: BrandArt.iconMoments.templateImage(size: 26, key: "iconMoments")) } }.tag(PhoneState.Tab.moments)

            NavigationStack { SettingsScreen() }
                .tabItem { Label { Text("Settings") } icon: { Image(uiImage: BrandArt.iconSettings.templateImage(size: 26, key: "iconSettings")) } }.tag(PhoneState.Tab.settings)
        }
        .fullScreenCover(isPresented: $app.showRecorder) { RecordScreen() }
        // The "link added" card and the Library tab's count badge, above the tab bar (PhoneLinkCard.swift).
        .overlay { PhoneLinkCardLayer() }
        .overlay {
            // The keyboard's hand-off screen. A plain overlay rather than a second full-screen cover, so it shows
            // even when another sheet is up.
            if app.showHandoff {
                HandoffScreen(handoff: app.handoff)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onOpenURL { url in _ = app.handoff.handle(url) }
        .alert("Before you record others", isPresented: $app.showConsentNotice) {
            Button("Not Now", role: .cancel) { app.dismissConsentNotice() }
            Button("Record") { app.acknowledgeConsentNotice() }
        } message: {
            Text("Many places require everyone's consent to record a conversation. Let people know before you record them.")
        }
        .alert("New project", isPresented: Binding(get: { app.newProjectFor != nil }, set: { if !$0 { app.newProjectFor = nil } })) {
            TextField("Name", text: $newProjectName)
            Button("Cancel", role: .cancel) { newProjectName = "" }
            Button("Create") {
                let n = newProjectName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty, let id = app.newProjectFor { app.move(id, to: app.store.addProject(n).id); app.say("Moved to \(n)") }
                newProjectName = ""
            }
        } message: { Text("The transcript moves into it.") }
        .fullScreenCover(isPresented: $app.showOnboarding) { PhoneOnboarding(startStep: PhoneUITest.onboardingStep).environmentObject(app) }
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
