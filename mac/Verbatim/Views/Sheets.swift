import SwiftUI
import AppKit

struct MicSheet: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 8) {
            EmptyStateArt(art: .capture, tint: Ink.persimmonTint).padding(.bottom, 4)
            Text("Verbose wants to use the microphone").font(.system(size: 15, weight: .semibold))
            Text("Voice memos are recorded and transcribed on this Mac. Nothing is uploaded.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Not now") { app.showMicSheet = false }.buttonStyle(.bordered).uiTarget("sheet-notnow")
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
    static let consentKey = "consent.noticeShown"
    private let consentSeen = UserDefaults.standard.bool(forKey: AppPickerSheet.consentKey)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture audio from").font(.system(size: 15, weight: .semibold))
            Text("Pick the app that is playing. macOS asks once for Screen & System Audio Recording; Verbose keeps only the audio, on this Mac.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.dim)
            if !consentSeen {
                // One-time recording-consent notice: shown until the first capture starts.
                Label { Text("Many places require everyone's consent to record a conversation. Let people on a call know before you capture it.") }
                    icon: { ArtIcon(art: .iconSpeakers, size: 16) }
                    .font(.system(size: 12.5)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)   // wraps instead of cutting off
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            }
            TextField("Filter apps", text: $filter).textFieldStyle(.roundedBorder)
            if let e = error {
                Text(e).font(.system(size: 12.5)).foregroundStyle(Ink.danger)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(apps.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { a in
                        Button { UserDefaults.standard.set(true, forKey: AppPickerSheet.consentKey); app.startCapture(a) } label: {
                            HStack(spacing: 10) {
                                AppIcon(key: .bundleID(a.id, generic: true), interpolation: nil) { Color.clear }
                                    .frame(width: 22, height: 22)
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
            catch { self.error = "Couldn't list apps: \(error.localizedDescription). Allow Verbose under Privacy & Security › Screen & System Audio Recording, then try again." }
        }
    }
}
