import SwiftUI
import AppKit

/// The source page under the title: thumbnail, channel · site · date, and the video one click away.
struct LinkCard: View {
    @EnvironmentObject var app: AppState
    var info: LinkInfo
    var transcript: Transcript
    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(info: info).frame(width: 72, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text([info.channel, info.site].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                Text([info.uploadDisplay, URL(string: info.url)?.host?.replacingOccurrences(of: "www.", with: "")].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { if let u = URL(string: info.url) { NSWorkspace.shared.open(u) } } label: { Label("Open video", art: .iconPlay, size: 13) }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
            KeepButton(transcript: transcript)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info.url, forType: .string); app.toast = Toast("Link copied") } label: { ArtIcon(art: .iconLinks, size: 14) }
                .buttonStyle(.bordered).controlSize(.small).help("Copy link")
        }
        .padding(8)
        .cardSurface(radius: Radius.row)
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
                .font(.system(size: 12)).foregroundStyle(Ink.iris).fixedSize()
        } else if let v = transcript.keptVideo, kept.exists(v) {
            Button { app.showKept(v) } label: { Label("Kept", systemImage: "checkmark") }
                .buttonStyle(.bordered).controlSize(.small).fixedSize().help("Show the MP4 in Finder")
        } else {
            Button { app.keepVideo(transcript.id) } label: { Label("Keep video", art: .iconDownload, size: 13) }
                .buttonStyle(.bordered).controlSize(.small).fixedSize().help("Save the video as an MP4 in your Keep folder")
        }
    }
}
