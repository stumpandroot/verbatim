import Foundation

// Record a call from the iPhone (approved mockup "Verbose License and Calls", section 3): iOS doesn't let apps hear
// phone calls, so the iPhone asks your Mac to wait for the call instead. Two small files in the synced folder carry
// it, one writer each so they never conflict: the Mac writes `calls-mac.json` (its name, when it was last seen, its
// next calendar call, and the wait it holds), and the iPhone writes `calls-request.json` (wait for this call, or
// cancel). The Mac acts on a request once, and only while it's fresh, so an old request never starts a recording
// hours later. Pure, so mac/tools/test-call-relay.sh checks it on Linux.

/// The Mac's side: what the iPhone shows under "On your Mac".
struct CallRelayMac: Codable, Equatable {
    var device: String
    /// `Device.name` ("your Mac"): generic on purpose, since a computer's own name often includes its owner's.
    var name: String
    var seen: Date
    var next: CallRelayEvent? = nil
    var wait: CallRelayWait? = nil
}

struct CallRelayEvent: Codable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    /// "Zoom", "Google Meet".
    var service: String
}

struct CallRelayWait: Codable, Equatable {
    /// "Zoom", "a call app".
    var appName: String
    var title: String? = nil
    var expires: Date
    /// The request it came from, when the iPhone set it up.
    var requestID: String? = nil
    /// Recording now (the wait fired).
    var recording: Bool = false
}

/// The iPhone's side: wait for a call on the Mac, or cancel the wait it asked for.
struct CallRelayRequest: Codable, Equatable {
    enum Action: String, Codable { case wait, cancel }
    var id: String
    var action: Action
    /// The Mac's calendar event (from `CallRelayMac.next`), or nil for any call app.
    var eventID: String? = nil
    var copyNotice: Bool = true
    var created: Date
    var device: String
    var deviceName: String
}

enum CallRelay {
    static let macFileName = "calls-mac.json"
    static let requestFileName = "calls-request.json"
    /// The Mac acts on a request this new or newer; an older one is left alone.
    static let requestLifetime: TimeInterval = 10 * 60
    /// The Mac rewrites its file this often while it runs, so the iPhone knows it's there.
    static let heartbeat: TimeInterval = 10 * 60

    enum MacState: Equatable {
        /// No Mac has written the file (no Mac, or iCloud sync off).
        case none
        /// Seen within the last day.
        case ready(name: String)
        /// Not seen for `days` days: open Verbose on the Mac, or record on speaker.
        case stale(name: String, days: Int)
    }

    static func macState(_ m: CallRelayMac?, now: Date) -> MacState {
        guard let m else { return .none }
        let age = now.timeIntervalSince(m.seen)
        if age < 86_400 { return .ready(name: m.name) }
        return .stale(name: m.name, days: max(1, Int(age / 86_400)))
    }

    /// Whether the Mac should act on `r`: new to it, and fresh.
    static func shouldHandle(_ r: CallRelayRequest, lastHandled: String?, now: Date) -> Bool {
        r.id != lastHandled && now.timeIntervalSince(r.created) <= requestLifetime && now >= r.created.addingTimeInterval(-300)
    }

    /// The Mac's next call, while it hasn't ended.
    static func nextCall(_ m: CallRelayMac?, now: Date) -> CallRelayEvent? {
        guard let n = m?.next, n.end > now else { return nil }
        return n
    }

    /// The wait the iPhone shows on Home: the Mac's, while it hasn't expired.
    static func activeWait(_ m: CallRelayMac?, now: Date) -> CallRelayWait? {
        guard let w = m?.wait, w.recording || w.expires > now else { return nil }
        return w
    }

    // MARK: Files

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    static func decodeMac(_ data: Data) -> CallRelayMac? { try? decoder().decode(CallRelayMac.self, from: data) }
    static func decodeRequest(_ data: Data) -> CallRelayRequest? { try? decoder().decode(CallRelayRequest.self, from: data) }

    // MARK: Copy

    static let sheetTitle = "Record a call"
    static let onMac = "On your Mac"
    static func onMacDetail(next: CallRelayEvent?, macName: String, time: (Date) -> String) -> String {
        let records = "\(cap(macName)) records your mic and the call as two tracks."
        guard let n = next else { return "Your Mac waits for any call app. " + records }
        return "\(n.title) · \(time(n.start)) · \(n.service). " + records
    }
    static let onSpeaker = "On speaker, with this iPhone"
    static let onSpeakerDetail = "For a call on another device. Records the room, like a meeting."
    static let phoneCall = "A phone call"
    static let phoneCallDetail = "iPhone's Phone app has its own record button and saves the recording in Notes. Share it to Verbose to transcribe it."
    static let waitButton = "Wait for this call on your Mac"
    static let noMac = "Turn on iCloud sync on this iPhone and your Mac, and open Verbose on your Mac, to have it record calls."
    static func staleMac(_ name: String, days: Int) -> String {
        "Verbose on \(name) hasn't synced in \(days == 1 ? "1 day" : "\(days) days"). Open it on your Mac, or record on speaker with this iPhone."
    }
    static let consent = "Recording a call can require everyone's consent where they are. Verbose copies a short notice on your Mac to paste in the call's chat."
    static let copyNotice = "Copy the chat notice when recording starts"
    static let waitingTitle = "Waiting for your call"
    static func waitingBody(_ w: CallRelayWait, macName: String) -> String {
        if w.recording { return "\(cap(macName)) is recording \(w.title ?? "your call")." }
        if let t = w.title { return "\(cap(macName)) records \(t) when \(w.appName) joins the call." }
        return "\(cap(macName)) records when \(w.appName) joins the call."
    }
    /// "your Mac" (the generic name synced files carry, `Device.name`) at the start of a sentence.
    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    static let asleepNote = "If your Mac is asleep when the call starts, nothing is recorded."
    static let sent = "Sent to your Mac"

    static var allLines: [String] {
        let e = CallRelayEvent(id: "e", title: "Catalog review", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600), service: "Zoom")
        let w = CallRelayWait(appName: "Zoom", title: "Catalog review", expires: Date(timeIntervalSince1970: 3600))
        return [sheetTitle, onMac, onMacDetail(next: e, macName: "Mac", time: { _ in "10:30" }), onMacDetail(next: nil, macName: "Mac", time: { _ in "" }),
                onSpeaker, onSpeakerDetail, phoneCall, phoneCallDetail, waitButton, noMac, staleMac("Mac", days: 3), consent, copyNotice,
                waitingTitle, waitingBody(w, macName: "Mac"), asleepNote, sent]
    }
}
