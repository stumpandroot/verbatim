import SwiftUI
import AppKit

/// The source page under the title, on a card (DESIGN.md §13): thumbnail, channel · site · date, and the video one
/// click away.
struct LinkCard: View {
    @EnvironmentObject var app: AppState
    var info: LinkInfo
    var transcript: Transcript
    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(info: info).frame(width: 72, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text([info.channel, info.site].compactMap { $0 }.joined(separator: " · ")).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                Text([info.uploadDisplay, URL(string: info.url)?.host?.replacingOccurrences(of: "www.", with: "")].compactMap { $0 }.joined(separator: " · "))
                    .refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { if let u = info.webURL { NSWorkspace.shared.open(u) } } label: { Text("Open video") }
                .disabled(info.webURL == nil)
                .buttonStyle(RefinedActionStyle())
            KeepButton(transcript: transcript)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info.url, forType: .string); app.toast = Toast("Link copied") } label: { IconGlyph(art: .iconLinks, size: 14, color: Refined.ink) }
                .buttonStyle(RefinedActionStyle()).help("Copy link").accessibilityLabel("Copy link")
        }
        .padding(8)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .frame(maxWidth: 640, alignment: .leading)
        .onAppear { KeptMedia.shared.refresh() }
    }
}

/// Keep the video, watch it save, then find it.
struct KeepButton: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var kept = KeptMedia.shared
    var transcript: Transcript
    var body: some View {
        if let busy = app.keeping[transcript.id] {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(busy.replacingOccurrences(of: "Keeping video", with: "Keeping")).monospacedDigit() }
                .refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize()
        } else if let v = transcript.keptVideo, kept.exists(v) {
            Button { app.showKept(v) } label: { Label("Kept", systemImage: "checkmark") }
                .buttonStyle(RefinedActionStyle()).help("Show the MP4 in Finder")
        } else {
            Button { app.keepVideo(transcript.id) } label: { Text("Keep video") }
                .buttonStyle(RefinedActionStyle()).help("Save the video as an MP4 in your Keep folder")
        }
    }
}
