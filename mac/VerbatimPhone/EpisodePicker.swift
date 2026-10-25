import SwiftUI

/// A podcast show or feed's latest episodes (up to 20): title, date, and length. Tapping one adds it as a link.
/// Shown inside the link sheet for a show link, or as its own sheet when a pasted link turned out to be a feed.
struct EpisodePicker: View {
    let link: URL
    /// Already loaded (a feed found while fetching), or nil to load it here.
    @State var show: PodcastShow?
    var onPick: (PodcastEpisode) -> Void
    /// The link wasn't a show after all: add it as an ordinary link.
    var onNotAShow: () -> Void
    @State private var failure: String?

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        List {
            if let show {
                Section {
                    ForEach(show.episodes) { ep in
                        Button { onPick(ep) } label: { row(ep) }
                            .accessibilityHint("Adds this episode and transcribes it")
                    }
                } header: {
                    Text(show.title ?? "Latest episodes")
                } footer: {
                    Text(show.episodes.count == 1 ? "The latest episode." : "The latest \(show.episodes.count) episodes. Tap one to transcribe it.")
                }
            } else if let failure {
                Text(failure).font(.system(size: 15)).foregroundStyle(.lookDim)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding episodes…").font(.system(size: 15)).foregroundStyle(.lookDim)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .phonePage()
        .navigationTitle("Choose an episode")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard show == nil else { return }
            do {
                if let s = try await PhoneLinkFetcher.episodes(link) { show = s } else { onNotAShow() }
            } catch let refused as LocalOnlyRefusal {
                failure = refused.localizedDescription
            } catch {
                failure = "Couldn't load the episodes: \(error.localizedDescription)"
            }
        }
    }

    private func row(_ ep: PodcastEpisode) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(2)
                let meta = [ep.date.map { Self.dateFormat.string(from: $0) }, ep.duration.map(Self.length)].compactMap { $0 }
                if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.lookMute) }
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(Ink.sageText).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private static func length(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(max(1, m)) min" }
        return m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min"
    }
}
