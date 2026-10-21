import Foundation

/// One mic of a multi-track recording: its working copy (16 kHz mono WAV in `Paths.tracks(id)`, on this device
/// only), the file it came from, and the speaker it belongs to.
struct AudioTrack: Codable, Equatable, Identifiable {
    var id = UUID()
    /// The working copy's name inside `Paths.tracks(transcriptID)`.
    var fileName: String
    /// The original file's name ("Tim_MV7.wav"), for display. Never a path.
    var sourceName: String
    var speaker: String
    /// Seconds this track starts after track 1 (negative: before). 0 for track 1.
    var offset: Double = 0
    var duration: Double = 0
}

/// A transcript made from several mics recorded at once, one speaker per file (Import › Multi-track recording).
/// The working copies are deleted once the transcript is ready; the track list stays as a record.
struct MultitrackInfo: Codable, Equatable {
    var tracks: [AudioTrack]
    /// Drop words one mic picked up from another speaker.
    var ignoreBleed = true
    /// Line tracks up by sound (true) or treat them as starting together.
    var alignAutomatically = true

    /// Where each track starts on the transcript's timeline (and in the mixed audio): the earliest track at 0.
    var timeline: [Double] { MultitrackMath.timeline(tracks.map(\.offset)) }
}

extension Paths {
    /// Working copies of one multi-track transcript's tracks. Local (never synced), removed when it's done.
    static func tracks(_ id: UUID) -> URL {
        local.appendingPathComponent("tracks", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
