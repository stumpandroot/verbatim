import Foundation
import UniformTypeIdentifiers

/// The drop box in the App Group between Verbatim's share and broadcast extensions and the iPhone app. Compiled into
/// VerbatimPhone, VerbatimShare, and VerbatimBroadcast.
///
/// - `Inbox/<id>.<ext>` + `<id>.json`: a video or audio file shared to Verbatim (VerbatimShare).
/// - `Inbox/<id>.url` + `<id>.json`: a web link shared to Verbatim. The app hands it to the link flow.
/// - `Broadcasts/<id>.m4a` + `<id>.json`: app audio from Transcribe what's playing (VerbatimBroadcast).
///
/// The manifest (`.json`) is written last and atomically, so the app never picks up a half-written file. The app
/// imports each item on launch and each time it becomes active, then deletes both files. Nothing here downloads
/// anything: a shared TikTok link is refused, because App Store guideline 5.2.3 and TikTok's terms rule out
/// fetching its media.
enum VerbatimInbox {
    /// Must match `com.apple.security.application-groups` in every target's entitlements (project.yml).
    static let appGroup = "group.co.stumpandroot.verbatim.ios"
    /// The broadcast upload extension, preferred by the picker in Transcribe what's playing.
    static let broadcastExtensionID = "co.stumpandroot.verbatim.ios.broadcast"
    /// Posted (Darwin) by the broadcast extension when a recording is saved, so an open app imports it at once.
    static let broadcastFinishedNote = "co.stumpandroot.verbatim.broadcast.finished"
    /// How many attachments one share takes.
    static let maxShared = 5

    enum Kind: String, Codable { case file, link, broadcast }

    /// One item's manifest.
    struct Item: Codable, Equatable {
        var id: UUID
        var kind: Kind
        /// The media or link file beside the manifest, in the same folder.
        var fileName: String? = nil
        /// The file's name where it came from ("IMG_2041.MOV").
        var originalName: String? = nil
        /// A shared web link.
        var url: String? = nil
        /// When the item was added.
        var date: Date
        /// The app it came from, when a public API says so (share extensions get none today, so this stays nil).
        var sourceApp: String? = nil
        /// A broadcast's start and length of recorded audio, in seconds.
        var started: Date? = nil
        var duration: Double? = nil
    }

    // MARK: Folders

    /// The App Group container. In the simulator without signing there may be none; the app then uses a folder of
    /// its own so the screenshot tour can still run the import path.
    static var container: URL? {
        if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return u }
        #if targetEnvironment(simulator)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AppGroupFallback", isDirectory: true)
        #else
        return nil
        #endif
    }

    static var inbox: URL? { folder("Inbox") }
    static var broadcasts: URL? { folder("Broadcasts") }

    private static func folder(_ name: String) -> URL? {
        guard let base = container else { return nil }
        let u = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: Writing

    static func manifestURL(_ id: UUID, in folder: URL) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    static func writeManifest(_ item: Item, in folder: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(item).write(to: manifestURL(item.id, in: folder), options: .atomic)
    }

    /// Saves a web link for the app's link flow: the link as text in `<id>.url`, then the manifest.
    static func addLink(_ url: URL, in folder: URL) throws {
        let id = UUID()
        let name = id.uuidString + ".url"
        try Data(url.absoluteString.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        try writeManifest(Item(id: id, kind: .link, fileName: name, originalName: url.host, url: url.absoluteString, date: Date()), in: folder)
    }

    // MARK: Reading

    /// Every finished item in a folder, oldest first.
    static func pending(in folder: URL) -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var items: [Item] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f) else { continue }
            if let item = try? dec.decode(Item.self, from: data) { items.append(item) } else { try? FileManager.default.removeItem(at: f) }
        }
        return items.sorted { $0.date < $1.date }
    }

    /// Deletes an item's manifest and its file (if it's still there).
    static func remove(_ item: Item, in folder: URL) {
        if let name = item.fileName { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        try? FileManager.default.removeItem(at: manifestURL(item.id, in: folder))
    }

    // MARK: Rules

    /// tiktok.com, vm.tiktok.com, vt.tiktok.com, www.tiktok.com, m.tiktok.com.
    static func isTikTok(_ u: URL) -> Bool {
        let host = (u.host ?? "").lowercased()
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
    }

    /// Audio or video, by file extension or type.
    static func isMedia(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .audio) || t.conforms(to: .movie) || t.conforms(to: .audiovisualContent)
    }

    // MARK: Darwin notifications

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}
