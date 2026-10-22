import Foundation
import Combine

// The app's side of Settings › Privacy (NetworkActivity.swift has the rules): the shared log's file, an observable
// copy of it for the Network activity list, and the size of a downloaded model.

extension NetworkActivityLog {
    /// network-activity.json beside the other device-only files (never in iCloud: it describes this device).
    static let shared: NetworkActivityLog = {
        let log = NetworkActivityLog(file: Paths.local.appendingPathComponent("network-activity.json"))
        // onChange runs on the main queue.
        log.onChange = { MainActor.assumeIsolated { NetworkActivityModel.shared.reload() } }
        return log
    }()

    /// Points the gate at the shared log. Called once at launch, before anything can use the network.
    static func install() {
        if NetworkGate.log == nil { NetworkGate.log = shared }
    }
}

/// The Network activity list's data, refreshed whenever the log changes.
@MainActor
final class NetworkActivityModel: ObservableObject {
    static let shared = NetworkActivityModel()
    @Published private(set) var events: [NetworkEvent] = []
    /// Mirrors LocalOnly.isOn for SwiftUI.
    @Published var localOnly: Bool = LocalOnly.isOn {
        didSet { if LocalOnly.isOn != localOnly { LocalOnly.isOn = localOnly; Log.note("privacy: Local Only \(localOnly ? "on" : "off")") } }
    }

    private init() { events = NetworkActivityLog.shared.events }

    func reload() { events = NetworkActivityLog.shared.events }

    func clear() { NetworkActivityLog.shared.clear() }

    /// What a row says: "Today at 2:03 PM", or the date and time.
    static func when(_ d: Date) -> String { Formats.style(date: .medium, time: .short, relative: true).string(from: d) }
}

enum ModelFiles {
    /// The size of a model folder on disk, for the activity log's byte count.
    static func bytes(in dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.fileSize ?? v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func bytes(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

/// Settings › Privacy's plain statement, the same on the Mac and the iPhone.
enum PrivacyStatement {
    static let text = "Verbatim has no account and no analytics. Audio and text stay on your devices unless you turn on cloud cleanup or fetch a link."
    static let localOnlyDetail = "Every network request except iCloud sync is refused before it starts: cloud cleanup, model downloads, links, and update checks. Models already on this device keep working."
    static let iCloudNote = "iCloud sync is Apple's and isn't listed here. Turn it on or off in Storage and iCloud."
}
