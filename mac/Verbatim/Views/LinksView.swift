import SwiftUI
import AppKit

/// Every link you've transcribed: the original page one click away, with its thumbnail, channel, and date.
struct LinksView: View {
    @EnvironmentObject var app: AppState
    @State private var site: String? = nil

    private var all: [Transcript] { app.filtered.filter { $0.linkInfo != nil } }
    private var sites: [String] { Array(Set(all.compactMap { $0.linkInfo?.site })).sorted() }
    private var shown: [Transcript] { all.filter { site == nil || $0.linkInfo?.site == site } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Links").font(Ink.serif(30, weight: .regular)).foregroundStyle(Ink.ink)
                    Text("\(shown.count) transcribed").font(.system(size: 13)).foregroundStyle(Ink.mute)
                    Spacer()
                    Button { app.goHome(); app.focusLink.toggle() } label: { Label("Paste a link", systemImage: "plus") }.buttonStyle(.bordered)
                }
                Text("The page each transcript came from. Right-click any line in a transcript to open the video at that moment.")
                    .font(.system(size: 13)).foregroundStyle(Ink.mute).padding(.top, 4)
                if sites.count > 1 {
                    HStack(spacing: 6) {
                        SiteChip(label: "All", on: site == nil) { site = nil }
                        ForEach(sites, id: \.self) { s in SiteChip(label: s, on: site == s) { site = s } }
                    }
                    .padding(.top, 14)
                }
                if shown.isEmpty {
                    HStack(spacing: 16) {
                        VerbieView(pose: .ready, tracksPointer: false).frame(width: 54, height: 76)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.search.isEmpty ? "No links yet" : "No links match “\(app.search)”").font(Ink.serif(20, weight: .regular))
                            Text("Paste a YouTube, Vimeo, or podcast link on Home. Verbatim keeps the page and transcribes the audio.")
                                .font(.system(size: 13.5)).foregroundStyle(Ink.mute)
                        }
                        Spacer()
                    }
                    .padding(20).background(NoteCardBackground(hover: false)).padding(.top, 20)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { t in LinkRow(transcript: t) }
                    }
                    .padding(.top, 18)
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

struct SiteChip: View {
    var label: String; var on: Bool; var action: () -> Void
    var body: some View {
        Text(label).font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(on ? Ink.iris : Ink.track, in: Capsule())
            .foregroundStyle(on ? .white : Ink.ink)
            .tapArea(action)
    }
}

/// Thumbnail, title, channel · site · date · length, and the two things you want: the video and the transcript.
struct LinkRow: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var hover = false

    var body: some View {
        let info = transcript.linkInfo!
        HStack(spacing: 16) {
            Thumbnail(info: info).frame(width: 128, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(transcript.title).font(Ink.serif(18, weight: .regular)).foregroundStyle(Ink.ink).lineLimit(2)
                Text([info.channel, info.site, info.uploadDisplay, transcript.duration > 0 ? transcript.duration.timecode : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute).lineLimit(1)
                if transcript.status == .processing { Text(transcript.stage ?? "Queued").font(.system(size: 12)).foregroundStyle(Ink.iris) }
                if transcript.status == .failed { Text("Transcription failed").font(.system(size: 12)).foregroundStyle(Ink.coral) }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button { if let u = URL(string: info.url) { NSWorkspace.shared.open(u) } } label: { Label("Open video", systemImage: "play.rectangle") }
                    .buttonStyle(.bordered)
                Button { app.go(.transcript(transcript.id)) } label: { Label("Transcript", systemImage: "text.alignleft") }
                    .buttonStyle(.borderedProminent).tint(Ink.iris).disabled(transcript.status != .ready)
                Menu {
                    Button("Copy link") { copy(info.url) }
                    Button("Copy title and link") { copy("\(transcript.title)\n\(info.url)") }
                    Divider()
                    RowMenu(transcript: transcript)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverChip()
            }
        }
        .padding(12)
        .background(NoteCardBackground(hover: hover))
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(object: TranscriptDrag.payload([transcript.id]) as NSString) }
        .contextMenu { Button("Open video") { if let u = URL(string: info.url) { NSWorkspace.shared.open(u) } }; Button("Copy link") { copy(info.url) }; Divider(); RowMenu(transcript: transcript) }
    }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); app.toast = Toast("Copied") }
}

struct Thumbnail: View {
    var info: LinkInfo
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Ink.track)
            if let f = info.thumbnailFile, let img = NSImage(contentsOf: Paths.thumbs.appendingPathComponent(f)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "play.rectangle").font(.system(size: 22)).foregroundStyle(Ink.mute)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Ink.hairline))
    }
}
