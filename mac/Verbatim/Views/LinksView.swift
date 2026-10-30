import SwiftUI
import AppKit
import os

// Link pieces other screens use: the stage progress bar, video stills, and link thumbnails. The Links screen and its
// rows became the Library's Links filter in the consolidation (October 28, 2026).

/// A thin progress bar (6 pt, persimmon on the track) for a transcription in progress.
struct StageProgressBar: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Refined.track)
                Capsule().fill(Refined.persimmon).frame(width: max(6, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
        .animation(Motion.settle, value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Reads the percentage out of the engine's stage label ("Transcribing 42%").
enum StageFraction {
    static func fraction(_ stage: String?) -> Double? {
        guard let s = stage, let r = s.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        return Double(s[r].dropLast()).map { $0 / 100 }
    }
}

/// A video still saved in Paths.thumbs.
struct FrameImage: View {
    var file: String
    var body: some View {
        // The rectangle sets the size; the still fills it and is clipped, so it never pushes the layout.
        Rectangle().fill(Refined.track)
            .overlay { ThumbImage(file: file, maxPixel: 900) { Rectangle().fill(Refined.track) } }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct Thumbnail: View {
    var info: LinkInfo
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Refined.track)
            .overlay {
                if let f = info.thumbnailFile {
                    ThumbImage(file: f, maxPixel: 200) { IconGlyph(art: .iconPlay, size: 22, color: Refined.mute) }
                } else {
                    IconGlyph(art: .iconPlay, size: 22, color: Refined.mute)
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Refined.separator))
    }
}

/// A link's upload day for a row: "Sep 12" this year, "Sep 12, 2025" before. `yyyyMMdd` in, as yt-dlp writes it.
enum LinkUploadDate {
    static func short(_ raw: String?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let raw, raw.count == 8, let date = Formats.pattern("yyyyMMdd").date(from: raw) else { return nil }
        return (calendar.isDate(date, equalTo: now, toGranularity: .year) ? sameYear : otherYear).string(from: date)
    }
    /// Made once (a formatter per row per render is slow).
    private static let sameYear = template("MMM d")
    private static let otherYear = template("MMM d yyyy")
    private static func template(_ t: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate(t)
        return f
    }
}
