import Foundation

/// The automatic kind without Apple Intelligence's judgment, and for links and imported media always. Pure
/// Foundation, so mac/tools/test-autolabel.sh checks it on Linux.
///
/// - Recordings (voice memos, app audio): two or more speakers for 10 minutes or more is a meeting; anything else
///   is a note. Apple Intelligence may suggest journal, idea, meeting, or note instead (AutoLabel).
/// - Links and imported audio or video files are never a meeting: two or more speakers is a podcast; one speaker is
///   a video when the source is a video file or a video site, else a talk at 10 minutes or more, else a note.
/// - Interview is only ever picked.
enum KindRule {
    enum Origin: Equatable {
        /// Recorded here: a voice memo, app audio, or a meeting.
        case recording
        /// A link or an imported file; `video` when it's a video file or from a video site.
        case media(video: Bool)
    }

    /// Ten minutes: the line between a short note and a meeting or talk.
    static let longRecording: Double = 600

    static func kind(origin: Origin, speakers: Int, duration: Double) -> RecordingKind {
        switch origin {
        case .recording:
            return speakers >= 2 && duration >= longRecording ? .meeting : .note
        case .media(let video):
            if speakers >= 2 { return .podcast }
            if video { return .video }
            return duration >= longRecording ? .talk : .note
        }
    }

    /// The kind from Apple Intelligence's answer: one of `RecordingKind.modelKinds` for a recording, else `fallback`.
    /// A link or imported media always takes `fallback` (this rule's kind), so the model never makes a podcast a meeting.
    static func fromModel(_ raw: String?, origin: Origin, fallback: RecordingKind) -> RecordingKind {
        guard origin == .recording else { return fallback }
        // The model names Thoughts "thought" (its stored value stays "idea", so synced files and older builds read it).
        return raw.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .map { $0 == "thought" || $0 == "thoughts" ? RecordingKind.idea.rawValue : $0 }
            .flatMap { RecordingKind(rawValue: $0) }
            .flatMap { RecordingKind.modelKinds.contains($0) ? $0 : nil } ?? fallback
    }

    /// Where a transcript came from, for `kind(origin:speakers:duration:)`.
    static func origin(of t: Transcript) -> Origin {
        if LibrarySource.isLink(t) {
            let onVideoSite = Platform.of(t).map { Platform.video.contains($0) } == true
            let media = (t.link?.url ?? t.sourceURL).flatMap { URL(string: $0) }
            let videoFile = media.map { MediaImport.videoExts.contains($0.pathExtension.lowercased()) } == true
            return .media(video: onVideoSite || videoFile || t.keptVideo != nil)
        }
        if t.source == .file { return .media(video: LibrarySource.isVideoFile(t)) }
        return .recording
    }
}
