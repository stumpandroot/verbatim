import Foundation

/// How long an MP4 or M4A file's audio really is, read from its boxes without decoding: the sum of the audio
/// track's sample durations, whether they're listed in the movie header (`stts`) or in fragments (`moof`/`trun`,
/// or the segment index `sidx` that covers them).
///
/// YouTube's audio-only M4A streams are fragmented DASH files. AVFoundation can report twice their real length
/// for one (a 1:01:59 video read as 2:03:58), while the samples, and the decoded audio, are the real length.
/// MediaImport compares the two and decodes such a file with FFmpeg instead, so the saved audio, its duration, and
/// the player's total time all match. Pure Foundation, so mac/tools/test-linkmedia.sh runs it on Linux.
enum MP4Timing {
    struct Report: Equatable {
        /// What the movie header says (`mehd` for a fragmented file, else `mvhd`), in seconds. Nil when it says 0.
        var headerSeconds: Double?
        /// The audio track's samples added up, in seconds. Nil when there are none to count.
        var sampleSeconds: Double?
        /// Whether the samples live in movie fragments (`moof`).
        var fragmented: Bool
    }

    /// Reads `url`'s boxes. Nil when it isn't an MP4-family file or can't be read.
    static func read(_ url: URL) -> Report? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return read(size: size) { offset, count in
            do {
                try h.seek(toOffset: UInt64(offset))
                return try h.read(upToCount: count) ?? Data()
            } catch { return Data() }
        }
    }

    /// The same for bytes in memory (the tests).
    static func read(data: Data) -> Report? {
        let bytes = [UInt8](data)
        return read(size: Int64(bytes.count)) { offset, count in
            guard offset >= 0, offset < Int64(bytes.count) else { return Data() }
            let end = min(Int64(bytes.count), offset + Int64(count))
            return Data(bytes[Int(offset)..<Int(end)])
        }
    }

    /// True when a player's duration and the file's own samples disagree by more than 2% (and over a second):
    /// the reported length can't be trusted.
    static func disagrees(reported: Double, samples: Double) -> Bool {
        guard reported > 0, samples > 0 else { return false }
        return abs(reported - samples) > max(1, samples * 0.02)
    }

    // MARK: Parsing

    /// The biggest box read into memory whole (a `moov` with a long sample table, or a `moof`). `mdat` is skipped.
    private static let maxBoxBytes = 64 * 1024 * 1024
    /// Containers whose children are boxes.
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "mvex", "moof", "traf", "edts"]

    private struct Track {
        var id: UInt32 = 0
        var timescale: UInt32 = 0
        var isAudio = false
        var sttsTicks: UInt64 = 0
        var defaultDuration: UInt32 = 0   // trex
    }

    private final class State {
        var movieTimescale: UInt32 = 0
        var mvhdDuration: UInt64 = 0
        var mehdDuration: UInt64 = 0
        var tracks: [Track] = []
        var current: Track?
        var fragmentTicks: [UInt32: UInt64] = [:]   // track id → ticks from trun
        var sidxSeconds: Double = 0
        var sidxTrack: UInt32?
        var fragmented = false
        var sawFtypOrMoov = false
        // Inside a traf.
        var trafTrack: UInt32 = 0
        var trafDefault: UInt32?
    }

    private static func read(size: Int64, _ at: (Int64, Int) -> Data) -> Report? {
        let s = State()
        var offset: Int64 = 0
        var boxes = 0
        while offset + 8 <= size, boxes < 200_000 {
            boxes += 1
            let head = [UInt8](at(offset, 16))
            guard head.count >= 8 else { break }
            var length = Int64(u32(head, 0))
            let type = fourCC(head, 4)
            var headerLength: Int64 = 8
            if length == 1 {
                guard head.count >= 16 else { break }
                length = Int64(bitPattern: u64(head, 8)); headerLength = 16
            } else if length == 0 {
                length = size - offset
            }
            // Compared by subtraction: a corrupt or hostile size near Int64.max would overflow `offset + length`.
            guard length >= headerLength else { break }
            let fits = length <= size - offset
            guard fits || type == "mdat" else { break }
            if offset == 0, type != "ftyp", type != "moov", type != "styp" { return nil }
            switch type {
            case "ftyp", "styp": s.sawFtypOrMoov = true
            case "moov", "moof", "sidx":
                let body = length - headerLength
                guard body <= Int64(maxBoxBytes) else { return nil }
                let data = [UInt8](at(offset + headerLength, Int(body)))
                guard Int64(data.count) == body else { break }
                if type == "sidx" { sidx(data, s) } else { s.sawFtypOrMoov = true; walk(type, data, s) }
            default: break   // mdat, free, …: skipped
            }
            guard fits else { break }   // an mdat that runs past the end is the last box
            offset += length
        }
        guard s.sawFtypOrMoov else { return nil }
        let audio = s.tracks.first { $0.isAudio } ?? s.tracks.first
        var samples: Double?
        if let t = audio, t.timescale > 0 {
            let ticks = t.sttsTicks + (s.fragmentTicks[t.id] ?? 0)
            if ticks > 0 { samples = Double(ticks) / Double(t.timescale) }
        }
        // A file whose fragments weren't all walked still has its segment index.
        if samples == nil, s.sidxSeconds > 0 { samples = s.sidxSeconds }
        let headerTicks = s.mehdDuration > 0 ? s.mehdDuration : s.mvhdDuration
        let header = s.movieTimescale > 0 && headerTicks > 0 ? Double(headerTicks) / Double(s.movieTimescale) : nil
        return Report(headerSeconds: header, sampleSeconds: samples, fragmented: s.fragmented)
    }

    /// Walks a container's children.
    private static func walk(_ type: String, _ d: [UInt8], _ s: State) {
        if type == "moof" { s.fragmented = true }
        if type == "trak" { s.current = Track() }
        if type == "traf" { s.trafTrack = 0; s.trafDefault = nil }
        var p = 0
        while p + 8 <= d.count {
            var length = Int(u32(d, p))
            let child = fourCC(d, p + 4)
            var hl = 8
            if length == 1 {
                guard p + 16 <= d.count else { return }
                length = Int(clamping: u64(d, p + 8)); hl = 16
            } else if length == 0 { length = d.count - p }
            guard length >= hl, length <= d.count - p else { return }   // not `p + length`: it can overflow
            let body = Array(d[(p + hl)..<(p + length)])
            if containers.contains(child) {
                walk(child, body, s)
            } else {
                leaf(child, body, s)
            }
            p += length
        }
        if type == "trak", var t = s.current {
            if let i = s.tracks.firstIndex(where: { $0.id == t.id && t.id != 0 }) {
                t.defaultDuration = s.tracks[i].defaultDuration   // a trex read first
                s.tracks[i] = t
            } else {
                s.tracks.append(t)
            }
            s.current = nil
        }
    }

    private static func leaf(_ type: String, _ b: [UInt8], _ s: State) {
        guard b.count >= 4 else { return }
        let version = b[0]
        switch type {
        case "mvhd":
            if version == 1, b.count >= 32 { s.movieTimescale = u32(b, 20); s.mvhdDuration = u64(b, 24) }
            else if b.count >= 20 { s.movieTimescale = u32(b, 12); s.mvhdDuration = UInt64(u32(b, 16)) }
        case "mehd":
            if version == 1, b.count >= 12 { s.mehdDuration = u64(b, 4) } else if b.count >= 8 { s.mehdDuration = UInt64(u32(b, 4)) }
        case "tkhd":
            if version == 1, b.count >= 24 { s.current?.id = u32(b, 20) } else if b.count >= 16 { s.current?.id = u32(b, 12) }
        case "mdhd":
            if version == 1, b.count >= 24 { s.current?.timescale = u32(b, 20) } else if b.count >= 16 { s.current?.timescale = u32(b, 12) }
        case "hdlr":
            if b.count >= 12 { s.current?.isAudio = fourCC(b, 8) == "soun" }
        case "stts":
            guard b.count >= 8 else { return }
            let n = Int(u32(b, 4))
            var ticks: UInt64 = 0
            for i in 0..<n {
                let p = 8 + i * 8
                guard p + 8 <= b.count else { break }
                ticks &+= UInt64(u32(b, p)) * UInt64(u32(b, p + 4))
            }
            s.current?.sttsTicks = ticks
        case "trex":
            guard b.count >= 16 else { return }
            let id = u32(b, 4), duration = u32(b, 12)
            if let i = s.tracks.firstIndex(where: { $0.id == id }) { s.tracks[i].defaultDuration = duration }
            else { var t = Track(); t.id = id; t.defaultDuration = duration; s.tracks.append(t) }
        case "tfhd":
            guard b.count >= 8 else { return }
            let flags = UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
            s.trafTrack = u32(b, 4)
            var p = 8
            if flags & 0x01 != 0 { p += 8 }   // base data offset
            if flags & 0x02 != 0 { p += 4 }   // sample description index
            if flags & 0x08 != 0, p + 4 <= b.count { s.trafDefault = u32(b, p) }
        case "trun":
            guard b.count >= 8 else { return }
            let flags = UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
            let count = Int(u32(b, 4))
            var p = 8
            if flags & 0x01 != 0 { p += 4 }   // data offset
            if flags & 0x04 != 0 { p += 4 }   // first sample flags
            var per = 0
            let hasDuration = flags & 0x100 != 0
            if hasDuration { per += 4 }
            if flags & 0x200 != 0 { per += 4 }
            if flags & 0x400 != 0 { per += 4 }
            if flags & 0x800 != 0 { per += 4 }
            var ticks: UInt64 = 0
            if hasDuration {
                for i in 0..<count {
                    let q = p + i * per
                    guard q + 4 <= b.count else { break }
                    ticks &+= UInt64(u32(b, q))
                }
            } else {
                let fallback = s.trafDefault ?? s.tracks.first(where: { $0.id == s.trafTrack })?.defaultDuration ?? 0
                ticks = UInt64(count) * UInt64(fallback)
            }
            s.fragmentTicks[s.trafTrack, default: 0] &+= ticks
        default: break
        }
    }

    /// A segment index: its subsegments' durations at its own timescale (the first `sidx` only, for one track).
    private static func sidx(_ b: [UInt8], _ s: State) {
        guard b.count >= 12 else { return }
        let version = b[0]
        let track = u32(b, 4), timescale = u32(b, 8)
        guard timescale > 0, s.sidxTrack == nil || s.sidxTrack == track else { return }
        s.sidxTrack = track
        var p = version == 0 ? 20 : 28
        guard p + 4 <= b.count else { return }
        let count = Int(UInt16(b[p + 2]) << 8 | UInt16(b[p + 3]))
        p += 4
        var ticks: UInt64 = 0
        for i in 0..<count {
            let q = p + i * 12
            guard q + 8 <= b.count else { break }
            ticks &+= UInt64(u32(b, q + 4))
        }
        s.sidxSeconds += Double(ticks) / Double(timescale)
    }

    // MARK: Bytes

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(u32(b, i)) << 32 | UInt64(u32(b, i + 4))
    }

    private static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        guard i + 4 <= b.count else { return "" }
        return String(decoding: b[i..<(i + 4)], as: UTF8.self)
    }
}
