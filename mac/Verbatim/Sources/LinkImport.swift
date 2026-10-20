import Foundation
import Combine

/// One link on its way into the Library: what the source says about itself and how far along the fetch is.
/// A "link added" view can observe it on either platform; the iPhone drives it from `PhoneLinkFetcher`.
/// It holds no platform types, so the Mac can drive the same object later.
@MainActor
final class LinkImport: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// Working out what the link points at (the page, the feed, the stream).
        case resolving
        /// Downloading the audio; `progress` moves from 0 to 1.
        case downloading
        /// The audio is in the Library and waiting for (or in) the transcription queue.
        case queued
        /// Handed to the Mac, which fetches the audio the next time it's open.
        case waitingForMac
        /// Stopped with a message you can show as is.
        case failed(String)
    }

    /// The transcript this link fills in.
    let id: UUID
    /// The link as pasted.
    let url: String
    @Published var title: String?
    /// The site as people say it: "YouTube", "Vimeo", "Apple Podcasts", or the host name.
    @Published var site: String?
    @Published var thumbnailURL: URL?
    /// 0…1 while downloading; nil when the size isn't known yet.
    @Published var progress: Double?
    @Published var phase: Phase = .resolving

    init(id: UUID, url: String, site: String? = nil) {
        self.id = id; self.url = url; self.site = site
    }

    var isFinished: Bool {
        switch phase {
        case .queued, .waitingForMac, .failed: return true
        case .resolving, .downloading: return false
        }
    }
}
