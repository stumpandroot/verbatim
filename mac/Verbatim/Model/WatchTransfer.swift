import Foundation

// Apple Watch capture (mockup "Library features", section 4, October 26, 2026; DESIGN.md §20). The watch records a
// voice note or a thought, marks moments while it records, and sends the audio to the iPhone with Watch Connectivity
// (`WCSession.transferFile`). These are the pieces both ends share, so the Linux tests (`mac/tools/test-watch.sh`)
// cover them: what travels with the file (`WatchTransfer`), what the iPhone tells the watch (`WatchContext`), and the
// watch's own words and limits (`WatchRules`). Foundation only: the watch app, its widgets, the iPhone, and the Mac all
// compile this file. The iPhone's side of the import (kind, marks, source) is in WatchImport.swift.

/// What the watch recorded: a voice note for the Library, or a thought for today's page.
enum WatchCaptureKind: String, Codable, CaseIterable {
    case voiceNote, thought

    /// A kind a newer watch sends reads as a voice note, so its audio still lands in the Library.
    init(from decoder: Decoder) throws {
        self = WatchCaptureKind(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .voiceNote
    }

    /// "Voice note" or "Thought", on the watch's Sent screen and in the Smart Stack.
    var label: String { self == .thought ? "Thought" : "Voice note" }
}

/// One mark made on the watch while it recorded.
struct WatchTransferMark: Codable, Equatable {
    /// Seconds into the recording.
    var at: Double
    var createdAt: Date
}

/// What travels with each recording's file as `transferFile` metadata, and what the watch keeps beside the file in its
/// outbox until the iPhone has it. The metadata holds it as JSON under `metadataKey` (property list types only).
struct WatchTransfer: Codable, Equatable, Identifiable {
    /// The format's version. A newer watch may add fields; an older iPhone ignores them.
    static let currentVersion = 1
    static let metadataKey = "verbose.watch"
    /// `MarkSource.watch`'s raw value: where every mark from the watch came from.
    static let markSource = "watch"

    var version = WatchTransfer.currentVersion
    /// The recording's own ID: the iPhone imports each one once, however many times it arrives.
    var id = UUID()
    var kind: WatchCaptureKind
    /// When recording started: a thought lands on the page of the day it started.
    var startedAt: Date
    /// Seconds of audio.
    var duration: Double
    var marks: [WatchTransferMark] = []

    init(id: UUID = UUID(), kind: WatchCaptureKind, startedAt: Date, duration: Double, marks: [WatchTransferMark] = []) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.duration = duration; self.marks = marks
    }

    init(from d: Decoder) throws {
        enum K: String, CodingKey { case version, id, kind, startedAt, duration, marks }
        let c = try d.container(keyedBy: K.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? WatchTransfer.currentVersion
        id = try c.decode(UUID.self, forKey: .id)
        kind = (try? c.decodeIfPresent(WatchCaptureKind.self, forKey: .kind)) ?? .voiceNote
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = max(0, (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0)
        // A mark that doesn't read is dropped; the recording still comes through.
        let raw = (try? c.decodeIfPresent([Lossy<WatchTransferMark>].self, forKey: .marks)) ?? []
        marks = raw.compactMap(\.value).filter { $0.at.isFinite && $0.at >= 0 }
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from d: Decoder) throws { value = try? T(from: d) }
    }

    /// Dates travel as Foundation's own seconds (since 2001), so they come back exactly as they left.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    static let decoder = JSONDecoder()

    func encoded() -> Data? { try? Self.encoder.encode(self) }
    static func decode(_ data: Data) -> WatchTransfer? { try? decoder.decode(WatchTransfer.self, from: data) }

    /// The `transferFile` metadata: the JSON as Data, a property list type.
    func metadata() -> [String: Any] {
        guard let data = encoded() else { return [:] }
        return [Self.metadataKey: data]
    }

    /// The transfer a file's metadata describes; nil when it isn't one of Verbose's (or doesn't read).
    static func from(metadata: [String: Any]?) -> WatchTransfer? {
        guard let value = metadata?[metadataKey] else { return nil }
        if let data = value as? Data { return decode(data) }
        if let text = value as? String { return decode(Data(text.utf8)) }
        return nil
    }
}

/// What the iPhone tells the watch with `updateApplicationContext`: today's thought count for the home screen and the
/// complication, and the last capture for the Smart Stack. Property list values only.
struct WatchContext: Equatable {
    /// Thoughts on today's page (Settings › Features › Thoughts › New page each day at, on the iPhone).
    var thoughtsToday: Int
    /// When today's page ends. Past it, the count is yesterday's, so the watch shows none.
    var pageEnds: Date
    /// The newest recording that isn't a dictation, for the Smart Stack: its title, kind ("Thought", "Meeting"),
    /// length in seconds, and when it started. Nil with an empty library.
    var lastTitle: String? = nil
    var lastKind: String? = nil
    var lastDuration: Double? = nil
    var lastAt: Date? = nil
    /// When the iPhone sent it.
    var sentAt = Date()

    enum Key {
        static let thoughtsToday = "thoughtsToday", pageEnds = "pageEnds", lastTitle = "lastTitle", lastKind = "lastKind"
        static let lastDuration = "lastDuration", lastAt = "lastAt", sentAt = "sentAt"
    }

    /// The longest title sent: the Smart Stack shows two lines at most.
    static let titleLimit = 60

    func dictionary() -> [String: Any] {
        var d: [String: Any] = [Key.thoughtsToday: thoughtsToday, Key.pageEnds: pageEnds, Key.sentAt: sentAt]
        if let lastTitle { d[Key.lastTitle] = String(lastTitle.prefix(Self.titleLimit)) }
        if let lastKind { d[Key.lastKind] = lastKind }
        if let lastDuration { d[Key.lastDuration] = lastDuration }
        if let lastAt { d[Key.lastAt] = lastAt }
        return d
    }

    init(thoughtsToday: Int, pageEnds: Date, lastTitle: String? = nil, lastKind: String? = nil, lastDuration: Double? = nil,
         lastAt: Date? = nil, sentAt: Date = Date()) {
        self.thoughtsToday = thoughtsToday; self.pageEnds = pageEnds; self.lastTitle = lastTitle; self.lastKind = lastKind
        self.lastDuration = lastDuration; self.lastAt = lastAt; self.sentAt = sentAt
    }

    /// Nil when the dictionary isn't one (an empty context, or one from a build that sent something else).
    init?(dictionary d: [String: Any]) {
        guard let pageEnds = d[Key.pageEnds] as? Date else { return nil }
        let n = (d[Key.thoughtsToday] as? Int) ?? (d[Key.thoughtsToday] as? NSNumber)?.intValue ?? 0
        self.thoughtsToday = max(0, n)
        self.pageEnds = pageEnds
        lastTitle = d[Key.lastTitle] as? String
        lastKind = d[Key.lastKind] as? String
        lastDuration = (d[Key.lastDuration] as? Double) ?? (d[Key.lastDuration] as? NSNumber)?.doubleValue
        lastAt = d[Key.lastAt] as? Date
        sentAt = (d[Key.sentAt] as? Date) ?? Date()
    }

    /// Kept as a property list in the App Group, where the complication reads it.
    func encoded() -> Data? { try? PropertyListSerialization.data(fromPropertyList: dictionary(), format: .binary, options: 0) }
    static func decode(_ data: Data) -> WatchContext? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]).flatMap { WatchContext(dictionary: $0) }
    }
}

/// The watch's words and limits. Copy follows DESIGN.md §8.
enum WatchRules {
    /// The App Group the watch app and its complications share (the same group name the iPhone app uses).
    static let appGroup = "group.co.stumpandroot.verbatim.ios"
    /// In the App Group: the iPhone's last `WatchContext`, and the start times of thoughts still waiting to go.
    static let contextKey = "watch.context"
    static let unsentThoughtsKey = "watch.unsentThoughts"
    /// Links from the complications and the Smart Stack into the watch app.
    static let recordLink = URL(string: "verbatim://watch/record")!
    static let thoughtLink = URL(string: "verbatim://watch/thought")!

    /// What a link asks for: a voice note or a thought (nil for anything else).
    static func kind(for url: URL) -> WatchCaptureKind? {
        guard url.scheme == "verbatim", url.host == "watch" else { return nil }
        switch url.lastPathComponent {
        case "record": return .voiceNote
        case "thought": return .thought
        default: return nil
        }
    }

    // MARK: Marks

    /// Two marks closer than this are one moment, as on the iPhone and the Mac (`Marks.dedupeWindow`).
    static let dedupeWindow: Double = 3
    /// How long "Marked 4:12" shows.
    static let confirmSeconds: Double = 2

    /// Adds a mark at `at` unless one is within `dedupeWindow` (then that one stands). Returns the marks and the time
    /// to confirm.
    static func adding(_ at: Double, createdAt: Date = Date(), to marks: [WatchTransferMark]) -> (marks: [WatchTransferMark], confirmed: Double) {
        if let near = marks.last(where: { abs($0.at - at) < dedupeWindow }) { return (marks, near.at) }
        return (marks + [WatchTransferMark(at: at, createdAt: createdAt)], at)
    }

    /// "4:12" or "1:02:14", the same as the iPhone's and the Mac's (`Marks.clock`).
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "Marked 4:12".
    static func marked(_ at: Double) -> String { "Marked \(clock(at))" }

    // MARK: Words

    static func moments(_ n: Int) -> String { n == 1 ? "1 moment" : "\(n) moments" }
    static func thoughts(_ n: Int) -> String { n == 1 ? "1 thought" : "\(n) thoughts" }

    /// Under the home screen's buttons: "Today · 6 thoughts".
    static func todayLine(_ n: Int) -> String { n == 0 ? "No thoughts today" : "Today · \(thoughts(n))" }

    /// The rectangular complication: "6 thoughts today", then "Tap to add one".
    static func complicationTitle(_ n: Int) -> String { n == 0 ? "No thoughts today" : "\(thoughts(n)) today" }
    static let complicationDetail = "Tap to add one"

    /// The Sent screen's last line: "Voice note · 41:05 · 3 moments".
    static func sentLine(_ t: WatchTransfer) -> String {
        var parts = [t.kind.label, clock(t.duration)]
        if !t.marks.isEmpty { parts.append(moments(t.marks.count)) }
        return parts.joined(separator: " · ")
    }

    /// Under "Sent to iPhone": where it goes, and whether the iPhone is in reach now.
    static func sentDetail(_ kind: WatchCaptureKind, reachable: Bool) -> String {
        let goes = kind == .thought ? "adds it to today's Thoughts" : "adds it to the Library"
        return reachable ? "Your iPhone transcribes it and \(goes)." : "Your iPhone gets it when it's in reach, then transcribes it and \(goes)."
    }

    /// On the home screen while recordings wait for the iPhone.
    static func waitingLine(_ n: Int) -> String? {
        guard n > 0 else { return nil }
        return n == 1 ? "1 recording waiting for your iPhone" : "\(n) recordings waiting for your iPhone"
    }

    /// Today's count on the watch: the iPhone's count while its page lasts, plus thoughts recorded on the watch for
    /// that page that haven't reached the iPhone yet (so the iPhone hasn't counted them).
    static func thoughtsToday(context: WatchContext?, unsent: [Date], now: Date = Date()) -> Int {
        guard let c = context, now < c.pageEnds else {
            // No count from the iPhone for today: the watch's own unsent thoughts from today.
            return unsent.filter { Calendar.current.isDate($0, inSameDayAs: now) }.count
        }
        let pageStarts = c.pageEnds.addingTimeInterval(-86_400)
        return c.thoughtsToday + unsent.filter { $0 >= pageStarts && $0 < c.pageEnds }.count
    }

    /// The Smart Stack's second line: "Thought · 0:42 · 9:58 AM".
    static func lastLine(_ c: WatchContext, time: (Date) -> String) -> String? {
        guard let kind = c.lastKind else { return nil }
        var parts = [kind]
        if let d = c.lastDuration, d > 0 { parts.append(clock(d)) }
        if let at = c.lastAt { parts.append(time(at)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Storage

    /// Recording needs this much free space to start (an hour of the watch's AAC is about 21 MB).
    static let minimumFreeToStart: Int64 = 50_000_000
    /// Below this, a recording stops and is saved.
    static let stopBelowFree: Int64 = 15_000_000
    static func canStart(freeBytes: Int64?) -> Bool { (freeBytes ?? .max) >= minimumFreeToStart }
    static func mustStop(freeBytes: Int64?) -> Bool { (freeBytes ?? .max) < stopBelowFree }

    static let fullMessage = "Your Apple Watch is almost full. Free up space to record."
    static let stoppedFullMessage = "Your Apple Watch is almost full, so recording stopped. Your recording is saved."
    static let micMessage = "Verbose needs the microphone to record. Turn it on in Settings on your Apple Watch, in Privacy & Security › Microphone."
    static let interruptedMessage = "Another app took the microphone, so recording stopped. Your recording is saved."
    static let failedMessage = "Verbose couldn't start recording. Try again."
}
