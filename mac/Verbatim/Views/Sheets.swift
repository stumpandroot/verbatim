import SwiftUI
import AppKit

// The main window's small sheets on the refined kit (DESIGN.md §13): the microphone's ask and the app picker for
// capturing an app's audio. Paper, the kit's type, and the system's buttons.

struct MicSheet: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Refined.persimmon)
                BrandGlyph(art: .capture, color: Refined.onFill, minLineWidth: 1.4).padding(14)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            .padding(.bottom, 2)
            Text("Verbose wants to use the microphone").refinedFont(.sectionTitle).foregroundStyle(Refined.ink).multilineTextAlignment(.center)
            Text("Voice notes are recorded and transcribed on this Mac. Nothing is uploaded.")
                .refinedFont(.body).foregroundStyle(Refined.dim).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Not now") { app.showMicSheet = false }.keyboardShortcut(.cancelAction).uiTarget("sheet-notnow")
                Button("Allow") { app.allowMic() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(24).frame(width: 380).background(Refined.paper)
        .tint(Refined.accentText)
    }
}

struct AppPickerSheet: View {
    @EnvironmentObject var app: AppState
    @State private var apps: [AppAudioCapture.RunningApp] = []
    @State private var error: String?
    @State private var filter = ""
    static let consentKey = "consent.noticeShown"
    private let consentSeen = UserDefaults.standard.bool(forKey: AppPickerSheet.consentKey)

    var body: some View {
        RefinedSheet(title: "Capture audio from", message: "Pick the app that is playing. macOS asks once for Screen & System Audio Recording; Verbose keeps only the audio, on this Mac.", width: 440) {
            if !consentSeen {
                // One-time recording-consent notice: shown until the first capture starts.
                HStack(alignment: .top, spacing: 10) {
                    IconGlyph(art: .iconSpeakers, size: 16, color: Refined.ink)
                    Text("Many places require everyone's consent to record a conversation. Let people on a call know before you capture it.")
                        .refinedFont(.meta).foregroundStyle(Refined.ink)
                        .fixedSize(horizontal: false, vertical: true)   // wraps instead of cutting off
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            }
            RefinedSearchField(text: $filter, prompt: "Filter apps")
            if error != nil {
                // Plain words and a way to fix it, never the system's raw error (review M-11).
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        IconGlyph(art: .iconAttention, size: 16, color: Refined.ink)
                        Text(AppPickerSheet.permissionText).refinedFont(.meta).foregroundStyle(Refined.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Open System Settings") { NSWorkspace.shared.open(AppPickerSheet.screenCaptureSettings) }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                        .padding(.leading, 24)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(apps.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { a in
                        PaperRowButton(action: { UserDefaults.standard.set(true, forKey: AppPickerSheet.consentKey); app.startCapture(a) }) {
                            HStack(spacing: 10) {
                                AppIcon(key: .bundleID(a.id, generic: true), interpolation: nil) { Color.clear }
                                    .frame(width: 22, height: 22)
                                Text(a.name).refinedFont(.rowTitle).foregroundStyle(Refined.ink)
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    }
                }
            }
            .frame(height: 280)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        } footer: {
            Spacer()
            Button("Cancel") { app.showAppPicker = false }.keyboardShortcut(.cancelAction)
        }
        .task { await load() }
        // Back from System Settings: try again, so the list fills once the permission is on.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if error != nil { Task { await load() } }
        }
    }

    private func load() async {
        do {
            apps = try await AppAudioCapture.runningApps()
            error = nil
        } catch {
            Log.note("app picker: couldn't list apps: \(error.localizedDescription)")
            self.error = AppPickerSheet.permissionText
        }
    }

    static let permissionText = "Verbose needs permission to hear other apps. Turn on Verbose in System Settings › Privacy & Security › Screen & System Audio Recording."
    static let screenCaptureSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
