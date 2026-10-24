import Foundation

// Stand-ins for the app-side types Transcript.swift touches, so the real Transcript compiles on its own.

enum Paths {
    static let local = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-tests", isDirectory: true)
}

enum Device {
    static let id = "test-device"
}

enum LocalMedia {
    enum Kind: String, Codable { case video, audio, original }
    static func paths(_ id: UUID) -> [Kind: String] { [:] }
    static func set(_ id: UUID, _ kind: Kind, _ path: String?) {}
    static func noteLegacy(_ id: UUID) {}
}

enum DocumentText {
    static func build(from t: Transcript) -> String { t.segments.map(\.text).joined(separator: "\n\n") }
    static func shown(_ document: String, in t: Transcript) -> String { document }
}

enum MediaImport {
    static let videoExts: Set<String> = ["mov", "mp4", "m4v"]
}
