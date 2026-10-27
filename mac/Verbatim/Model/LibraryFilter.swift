import Foundation

/// Where a link came from, as people say it: "YouTube", "TikTok", "Apple Podcasts". One mapping for the whole app:
/// yt-dlp extractor keys ("Youtube", "TwitchVod"), host names ("m.tiktok.com"), and site names a page reported
/// ("Instagram") all land on the same names, so the Library's platform filter and the link card agree.
enum Platform {
    static let youTube = "YouTube", tikTok = "TikTok", instagram = "Instagram", vimeo = "Vimeo", x = "X",
               applePodcasts = "Apple Podcasts", twitch = "Twitch", facebook = "Facebook", rumble = "Rumble",
               soundCloud = "SoundCloud", spotify = "Spotify"
    /// A link from a site this list doesn't name.
    static let otherWeb = "Other web"
    /// A video file imported from disk.
    static let localFile = "Local file"

    /// Display order for the platform chips; anything else sorts after, by name.
    static let order = [youTube, tikTok, instagram, vimeo, x, applePodcasts, spotify, twitch, facebook, rumble, soundCloud, otherWeb, localFile]

    /// Platforms whose links are videos (the Videos filter includes them).
    static let video: Set<String> = [youTube, tikTok, instagram, vimeo, x, twitch, facebook, rumble]

    /// The platform for an extractor key, host, or site name, or nil when it isn't one Verbatim names.
    static func name(_ key: String) -> String? {
        var k = key.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://"] where k.hasPrefix(p) { k = String(k.dropFirst(p.count)) }
        if let slash = k.firstIndex(of: "/") { k = String(k[..<slash]) }
        for p in ["www.", "m.", "mobile.", "vm.", "music."] where k.hasPrefix(p) { k = String(k.dropFirst(p.count)) }
        guard !k.isEmpty else { return nil }
        if k.contains("youtu") { return youTube }
        if k.contains("tiktok") { return tikTok }
        if k.contains("instagram") || k == "instagr.am" { return instagram }
        if k.contains("vimeo") { return vimeo }
        if k.hasPrefix("twitter") || k == "x" || k == "x.com" || k.hasSuffix(".x.com") || k == "t.co" { return x }
        if k == "podcasts.apple.com" || k.hasPrefix("applepodcasts") || k == "apple podcasts" || k == "itunes.apple.com" { return applePodcasts }
        if k.contains("spotify") { return spotify }
        if k.contains("twitch") { return twitch }
        if k.hasPrefix("facebook") || k.contains("facebook.com") || k == "fb.watch" { return facebook }
        if k.contains("rumble") { return rumble }
        if k.contains("soundcloud") { return soundCloud }
        return nil
    }

    /// The platform for a transcript: a link's site (from its URL first, then the site name the page gave, then the
    /// source label), "Local file" for an imported video file, or nil for everything else.
    static func of(_ t: Transcript) -> String? {
        if LibrarySource.isLink(t) {
            let url = t.link?.url ?? t.sourceURL
            let host = url.flatMap { URL(string: $0)?.host }
            for k in [host, t.link?.site, t.sourceLabel].compactMap({ $0 }) { if let p = name(k) { return p } }
            return otherWeb
        }
        if LibrarySource.isVideoFile(t) { return localFile }
        return nil
    }
}

/// The Library's type filter: what a transcript is, from where it came. Instant, combines with search and kinds.
enum LibrarySource: String, CaseIterable, Identifiable, Codable {
    case all, voiceMemos, videos, audioFiles, links, appAudio, dictations
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .voiceMemos: return "Voice notes"
        case .videos: return "Videos"
        case .audioFiles: return "Audio files"
        case .links: return "Links"
        case .appAudio: return "App audio"
        case .dictations: return "Dictations"
        }
    }

    /// Videos and links break down by platform.
    var hasPlatforms: Bool { self == .videos || self == .links }

    static func isLink(_ t: Transcript) -> Bool { t.source == .link || t.link != nil || (t.source != .file && t.sourceURL != nil) }

    /// An imported file that's a video: by its original file when this device has it, else by the "MP4 file" label.
    static func isVideoFile(_ t: Transcript) -> Bool {
        guard t.source == .file, !isLink(t) else { return false }
        if let p = t.originalMedia { return MediaImport.videoExts.contains(URL(fileURLWithPath: p).pathExtension.lowercased()) }
        let first = t.sourceLabel.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return MediaImport.videoExts.contains(first)
    }

    func matches(_ t: Transcript) -> Bool {
        switch self {
        case .all: return true
        case .dictations: return t.isDictation
        case .voiceMemos: return !t.isDictation && t.source == .voiceMemo && !Self.isLink(t)
        case .appAudio: return !t.isDictation && t.source == .app
        case .links: return !t.isDictation && Self.isLink(t)
        case .videos:
            guard !t.isDictation else { return false }
            if Self.isVideoFile(t) { return true }
            return Self.isLink(t) && Platform.of(t).map { Platform.video.contains($0) } == true
        case .audioFiles: return !t.isDictation && t.source == .file && !Self.isLink(t) && !Self.isVideoFile(t)
        }
    }
}

/// The type filter plus, for videos and links, a platform. Stored per device as "videos" or "videos|YouTube".
struct LibraryFilter: Equatable, Hashable {
    var source: LibrarySource = .all
    var platform: String? = nil

    static let all = LibraryFilter()

    init(source: LibrarySource = .all, platform: String? = nil) {
        self.source = source; self.platform = source.hasPlatforms ? platform : nil
    }

    init(raw: String) {
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        let s = parts.first.flatMap(LibrarySource.init(rawValue:)) ?? .all
        self.init(source: s, platform: parts.count > 1 ? parts[1] : nil)
    }

    var raw: String { platform.map { "\(source.rawValue)|\($0)" } ?? source.rawValue }

    /// UserDefaults keys for the last filter: the Library's, and the Add from Library sheet's.
    static let libraryKey = "library.filter"
    static let addSheetKey = "library.addFilter"
    static func saved(_ key: String) -> LibraryFilter { LibraryFilter(raw: UserDefaults.standard.string(forKey: key) ?? "") }
    func save(_ key: String) { UserDefaults.standard.set(raw, forKey: key) }

    func matches(_ t: Transcript) -> Bool {
        guard source.matches(t) else { return false }
        guard let p = platform else { return true }
        return Platform.of(t) == p
    }

    /// The list to show: dictations stay out unless you're searching or chose Dictations (they live in their own list).
    func apply(_ items: [Transcript], searching: Bool) -> [Transcript] {
        items.filter { (searching || source == .dictations || !$0.isDictation) && matches($0) }
    }

    /// Each type with how many of `items` it would show; types with none are left out, except All and the chosen one.
    func sourceCounts(_ items: [Transcript], searching: Bool) -> [(LibrarySource, Int)] {
        LibrarySource.allCases.compactMap { s in
            let n = LibraryFilter(source: s).apply(items, searching: searching).count
            return (n > 0 || s == .all || s == source) ? (s, n) : nil
        }
    }

    /// Platforms within the chosen type, in `Platform.order`, with counts. Empty for types without platforms, and when
    /// everything is on one platform (a single chip filters nothing).
    func platformCounts(_ items: [Transcript], searching: Bool) -> [(String, Int)] {
        guard source.hasPlatforms else { return [] }
        var counts: [String: Int] = [:]
        for t in LibraryFilter(source: source).apply(items, searching: searching) { if let p = Platform.of(t) { counts[p, default: 0] += 1 } }
        if counts.count < 2 && platform == nil { return [] }
        if let p = platform, counts[p] == nil { counts[p] = 0 }
        return counts.sorted { a, b in
            let i = Platform.order.firstIndex(of: a.key) ?? Int.max, j = Platform.order.firstIndex(of: b.key) ?? Int.max
            return i != j ? i < j : a.key < b.key
        }.map { ($0.key, $0.value) }
    }

    /// "Meeting · YouTube", "Voice note", "MP4 file", "Dictation": what a row says it is.
    static func describe(_ t: Transcript) -> String {
        let what: String
        if t.isDictation { return "Dictation" }
        else if LibrarySource.isLink(t) { what = Platform.of(t).map { $0 == Platform.otherWeb ? (t.linkInfo?.site ?? "Link") : $0 } ?? "Link" }
        else if t.source == .voiceMemo { what = "Voice note" }
        else { what = t.sourceLabel.isEmpty ? "File" : t.sourceLabel }
        return t.kind.map { "\($0.label) · \(what)" } ?? what
    }
}

/// Adding Library transcripts to a project. A transcript belongs to at most one project (`Transcript.projectId`), so
/// adding one that's in another project moves it.
enum ProjectAdd {
    /// What the sheet lists: live transcripts (not in Recently Deleted) that aren't already in the project, matching the
    /// search by title, tags, or text. `text` returns lowercased transcript text (Store.searchText).
    static func candidates(_ all: [Transcript], project: UUID, query: String, text: (Transcript) -> String) -> [Transcript] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { t in
            t.deletedAt == nil && t.projectId != project &&
            (q.isEmpty || t.title.lowercased().contains(q) || t.tags.contains { $0.lowercased().contains(q) } || text(t).contains(q))
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// For each chosen transcript that would change, the project it's in now (nil for none): what Undo puts back.
    /// Transcripts already in the project, deleted, or unknown are left out.
    static func plan(_ ids: [UUID], in all: [Transcript], to project: UUID) -> [UUID: UUID?] {
        var out: [UUID: UUID?] = [:]
        for id in ids {
            guard let t = all.first(where: { $0.id == id }), t.deletedAt == nil, t.projectId != project else { continue }
            out[id] = .some(t.projectId)
        }
        return out
    }

    /// The chosen transcripts that are in a different project and would move out of it.
    static func moves(_ plan: [UUID: UUID?]) -> [UUID] { plan.compactMap { $0.value != nil ? $0.key : nil } }
}
