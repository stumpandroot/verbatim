import Foundation

// Local Only and the network activity log (Settings › Privacy), shared by the Mac and the iPhone. Foundation only, so
// mac/tools/test-privacy.sh compiles this file on its own and tests it. The app wires the shared log to its file in
// NetworkActivity+App.swift.
//
// Privacy rules for the log, matching App/Log.swift: an entry keeps the time, the purpose, the host, and a byte count
// when one is known. Never a path, a query, a key, a title, or any of your words.

/// Why Verbatim used the network.
enum NetworkPurpose: String, Codable, CaseIterable {
    case cloudCleanup, modelDownload, linkDownload, updateCheck

    /// The name the activity list shows.
    var label: String {
        switch self {
        case .cloudCleanup: return "Cloud cleanup"
        case .modelDownload: return "Model download"
        case .linkDownload: return "Link download"
        case .updateCheck: return "Update check"
        }
    }
}

/// One use of the network, or one that Local Only refused before it started.
struct NetworkEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    var purpose: NetworkPurpose
    /// The host only ("api.anthropic.com"), never a path or query.
    var host: String
    /// Bytes sent and received, when known.
    var bytes: Int64? = nil
    /// True when Local Only stopped it before anything was sent.
    var refused = false

    init(id: UUID = UUID(), date: Date = Date(), purpose: NetworkPurpose, host: String, bytes: Int64? = nil, refused: Bool = false) {
        self.id = id; self.date = date; self.purpose = purpose; self.host = NetworkHost.clean(host); self.bytes = bytes; self.refused = refused
    }

    /// Tolerant: an entry a newer build wrote with a purpose this build doesn't know is dropped by the log, not the file.
    init(from d: Decoder) throws {
        enum K: String, CodingKey { case id, date, purpose, host, bytes, refused }
        let c = try d.container(keyedBy: K.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        purpose = try c.decode(NetworkPurpose.self, forKey: .purpose)
        host = NetworkHost.clean(try c.decodeIfPresent(String.self, forKey: .host) ?? "")
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes)
        refused = try c.decodeIfPresent(Bool.self, forKey: .refused) ?? false
    }
}

/// Hosts, with everything else taken off.
enum NetworkHost {
    /// The host of a URL string, lowercased, without "www.", a port, or a sign-in. Strings that aren't URLs are
    /// treated as a bare host ("Apple"); anything with a path loses it.
    static func of(_ string: String) -> String {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: s), let h = u.host, !h.isEmpty { return clean(h) }
        return clean(s)
    }

    static func of(_ url: URL?) -> String { url?.host.map(clean) ?? "" }

    /// Keeps only a host: drops a scheme, a sign-in, a port, a path, a query, or a fragment, and "www.".
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<i]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if !s.hasPrefix("["), let colon = s.lastIndex(of: ":") { s = String(s[..<colon]) }
        let lower = s.lowercased()
        // Names like "Apple" (a system download) keep their case; real hosts are lowercased.
        if lower.contains(".") || lower.hasPrefix("[") {
            return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        }
        return s
    }
}

/// Local Only (Settings › Privacy). When it's on, every network call except iCloud sync is refused before it starts.
/// Model downloads can be allowed for a short while ("Allow this download"); nothing else can be.
enum LocalOnly {
    static let key = "privacy.localOnly"
    static var defaults: UserDefaults = .standard

    static var isOn: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }

    /// "Allow this download": model downloads may start until this time, even with Local Only on. In memory only, so
    /// it never outlives the app.
    private static let lock = NSLock()
    private static var modelsAllowedUntil: Date?

    /// Lets model downloads through for `seconds` (one transcription's worth of models: speech, speakers, the
    /// speech detector).
    static func allowModelDownloads(for seconds: TimeInterval = 600, now: Date = Date()) {
        lock.lock(); modelsAllowedUntil = now.addingTimeInterval(seconds); lock.unlock()
    }

    static func modelDownloadsAllowed(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = modelsAllowedUntil else { return false }
        if now < until { return true }
        modelsAllowedUntil = nil
        return false
    }

    /// Whether this purpose may use the network now.
    static func permits(_ purpose: NetworkPurpose, now: Date = Date()) -> Bool {
        guard isOn else { return true }
        return purpose == .modelDownload && modelDownloadsAllowed(now: now)
    }

    /// What a refused request tells you, and how to change it.
    static func message(_ purpose: NetworkPurpose) -> String {
        switch purpose {
        case .modelDownload: return "Local Only is on. Turn it off in Settings › Privacy to download this model."
        case .linkDownload: return "Local Only is on. Turn it off in Settings › Privacy to download this link."
        case .cloudCleanup: return "Local Only is on, so your words were cleaned on this device instead of in the cloud."
        case .updateCheck: return "Local Only is on. Turn it off in Settings › Privacy to check for updates."
        }
    }

    // Models that have loaded once are on disk; loading them again doesn't download. FluidAudio's speech detector,
    // keyword model, and speaker models load through calls that download when the files are missing, so Verbatim
    // remembers which ones have loaded on this device.
    private static func readyKey(_ name: String) -> String { "privacy.modelReady." + name }
    static func markModelReady(_ name: String) { defaults.set(true, forKey: readyKey(name)) }
    static func modelReady(_ name: String) -> Bool { defaults.bool(forKey: readyKey(name)) }
}

/// Thrown when Local Only refuses a request. Its description is the message the person sees.
struct LocalOnlyRefusal: LocalizedError, Equatable {
    var purpose: NetworkPurpose
    var errorDescription: String? { LocalOnly.message(purpose) }

    /// True when `message` is a refused model download, so the transcript can offer "Allow this download".
    static func isModelRefusal(_ message: String?) -> Bool { message?.contains(LocalOnly.message(.modelDownload)) == true }
}

/// The in-memory ring of network events, saved as a small JSON file (newest last, at most `cap`).
final class NetworkActivityLog: @unchecked Sendable {
    static let cap = 500
    private let lock = NSLock()
    private var items: [NetworkEvent] = []
    private let file: URL?
    private let queue = DispatchQueue(label: "co.stumpandroot.verbatim.network-activity", qos: .utility)
    private var saveScheduled = false
    /// Called on the main queue after every change, so a list on screen can refresh.
    var onChange: (() -> Void)?

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file) { items = Self.decode(data) }
    }

    /// Newest first, for the list.
    var events: [NetworkEvent] { lock.lock(); defer { lock.unlock() }; return items.reversed() }

    /// Records one event and returns its id (to add the byte count when it's known).
    @discardableResult
    func add(_ purpose: NetworkPurpose, host: String, bytes: Int64? = nil, refused: Bool = false, date: Date = Date()) -> UUID {
        let e = NetworkEvent(date: date, purpose: purpose, host: host, bytes: bytes, refused: refused)
        lock.lock()
        items.append(e)
        if items.count > Self.cap { items.removeFirst(items.count - Self.cap) }
        lock.unlock()
        changed()
        return e.id
    }

    /// Adds bytes to an event already in the log (a download's size once it's done).
    func addBytes(_ id: UUID, _ bytes: Int64) {
        guard bytes > 0 else { return }
        lock.lock()
        if let i = items.lastIndex(where: { $0.id == id }) { items[i].bytes = (items[i].bytes ?? 0) + bytes }
        lock.unlock()
        changed()
    }

    func clear() {
        lock.lock(); items = []; lock.unlock()
        changed()
    }

    /// Writes the file now (tests, and before quitting).
    func flush() { queue.sync { self.write() } }

    private func changed() {
        lock.lock()
        let schedule = !saveScheduled
        saveScheduled = true
        lock.unlock()
        if schedule { queue.asyncAfter(deadline: .now() + 0.5) { self.write() } }
        if let onChange { DispatchQueue.main.async(execute: onChange) }
    }

    private func write() {
        lock.lock()
        saveScheduled = false
        let snapshot = items
        lock.unlock()
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = Self.encode(snapshot) { try? data.write(to: file, options: .atomic) }
    }

    static func encode(_ list: [NetworkEvent]) -> Data? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try? e.encode(Array(list.suffix(cap)))
    }

    /// Reads the file, skipping entries this build can't read, and keeps the newest `cap`.
    static func decode(_ data: Data) -> [NetworkEvent] {
        struct Lenient: Decodable {
            var value: NetworkEvent?
            init(from d: Decoder) throws { value = try? NetworkEvent(from: d) }
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let list = ((try? dec.decode([Lenient].self, from: data)) ?? []).compactMap(\.value)
        return Array(list.suffix(cap))
    }
}

/// The one check every network call site makes: refuses (and logs the refusal) when Local Only is on, otherwise
/// logs the request. `log` is the app's shared log (NetworkActivity+App.swift); nil logs nothing.
enum NetworkGate {
    nonisolated(unsafe) static var log: NetworkActivityLog?

    /// Call just before a request starts. Returns the event's id, to add bytes once they're known.
    @discardableResult
    static func begin(_ purpose: NetworkPurpose, host: String) throws -> UUID? {
        guard LocalOnly.permits(purpose) else {
            log?.add(purpose, host: host, refused: true)
            throw LocalOnlyRefusal(purpose: purpose)
        }
        return log?.add(purpose, host: host)
    }

    /// Whether the purpose may use the network now (logs nothing).
    static func permits(_ purpose: NetworkPurpose) -> Bool { LocalOnly.permits(purpose) }

    static func addBytes(_ id: UUID?, _ bytes: Int64) {
        guard let id else { return }
        log?.addBytes(id, bytes)
    }
}

// MARK: - Where a transcript's data went

/// The data path badge on a transcript: where the audio came from and where the text was made.
/// "Local audio · local text", "Audio from youtube.com · local text", "Local audio · cloud cleanup (Anthropic)".
enum DataPath {
    static func badge(linkHost: String?, cloudCleanup: String?) -> String {
        let audio: String
        if let h = linkHost.map(NetworkHost.clean), !h.isEmpty { audio = "Audio from \(h)" } else { audio = "Local audio" }
        let text: String
        if let c = cloudCleanup?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { text = "cloud cleanup (\(c))" } else { text = "local text" }
        return audio + " · " + text
    }

    /// True when anything about this transcript left the device (a link download or cloud cleanup).
    static func leftDevice(linkHost: String?, cloudCleanup: String?) -> Bool {
        !(linkHost ?? "").isEmpty || !(cloudCleanup ?? "").isEmpty
    }
}

/// Byte counts for the activity list: "12 KB", "1.4 MB".
enum ByteText {
    static func format(_ bytes: Int64?) -> String? {
        guard let b = bytes, b > 0 else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }
}
