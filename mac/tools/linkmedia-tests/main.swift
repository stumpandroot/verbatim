import Foundation

// On-device link media: an MP4's real length (Verbatim/Sources/MP4Timing.swift), the chunked download's byte ranges
// (VerbatimPhone/LinkChunks.swift), and YouTube's channel and upload date (VerbatimPhone/YouTubePageMeta.swift).
// Not part of any app target; run mac/tools/test-linkmedia.sh. No network.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name)"); let d = detail(); if !d.isEmpty { print("    " + d) } }
}

// MARK: MP4 boxes

func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }
func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }
func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { cat(be32(UInt32(payload.count + 8)), ascii(type), payload) }
func full(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ payload: [UInt8]) -> [UInt8] {
    let head: [UInt8] = [version, UInt8(flags >> 16 & 0xff), UInt8(flags >> 8 & 0xff), UInt8(flags & 0xff)]
    return box(type, cat(head, payload))
}
func mvhd(timescale: UInt32, duration: UInt32) -> [UInt8] { full("mvhd", cat(be32(0), be32(0), be32(timescale), be32(duration), zeros(80))) }
func trak(id: UInt32, timescale: UInt32, stts: [(UInt32, UInt32)]) -> [UInt8] {
    let tkhd = full("tkhd", cat(be32(0), be32(0), be32(id), be32(0), be32(0), zeros(60)))
    let mdhd = full("mdhd", cat(be32(0), be32(0), be32(timescale), be32(0), zeros(4)))
    let hdlr = full("hdlr", cat(be32(0), ascii("soun"), zeros(13)))
    let entries: [UInt8] = stts.flatMap { cat(be32($0.0), be32($0.1)) }
    let sttsBox = full("stts", cat(be32(UInt32(stts.count)), entries))
    return box("trak", cat(tkhd, box("mdia", cat(mdhd, hdlr, box("minf", box("stbl", sttsBox))))))
}
func moof(track: UInt32, samples: Int, perSampleDuration: UInt32?) -> [UInt8] {
    let tfhd = full("tfhd", be32(track))
    let trun: [UInt8]
    if let d = perSampleDuration {
        let each: [UInt8] = (0..<samples).flatMap { _ in cat(be32(d), be32(6)) }
        trun = full("trun", flags: 0x000301, cat(be32(UInt32(samples)), be32(0), each))
    } else {
        trun = full("trun", flags: 0x000001, cat(be32(UInt32(samples)), be32(0)))
    }
    return box("moof", cat(full("mfhd", be32(1)), box("traf", cat(tfhd, trun))))
}
/// A segment index with one reference covering `ticks` at `timescale`.
func sidx(timescale: UInt32, ticks: UInt32) -> [UInt8] {
    full("sidx", cat(be32(1), be32(timescale), be32(0), be32(0), [0, 0, 0, 1], be32(400), be32(ticks), be32(0x9000_0000)))
}

// A file shaped like YouTube's audio-only M4A (itag 140): the movie header names the whole length, the samples are
// all in fragments (some with their own durations, some with the trex default), and a segment index covers them.
let rate: UInt32 = 44100
let total = 160_164   // AAC frames of 1024 samples in 3719 s (1:01:59)
let trex = full("trex", cat(be32(1), be32(1), be32(1024), be32(0), be32(0)))
var dash = box("ftyp", cat(ascii("dash"), be32(0), ascii("iso6mp41")))
dash += box("moov", cat(mvhd(timescale: 1000, duration: 3_719_000), trak(id: 1, timescale: rate, stts: []), box("mvex", trex)))
dash += sidx(timescale: rate, ticks: UInt32(total * 1024))
let parts = [40_000, 40_000, 40_000, total - 120_000]
for (k, n) in parts.enumerated() {
    dash += moof(track: 1, samples: n, perSampleDuration: k % 2 == 0 ? 1024 : nil)
    dash += box("mdat", zeros(16))
}
let r = MP4Timing.read(data: Data(dash))
let real = Double(total * 1024) / Double(rate)
check("a YouTube-shaped M4A: fragmented, its samples add up to 1:01:59", r?.fragmented == true && abs((r?.sampleSeconds ?? 0) - real) < 0.001,
      "\(String(describing: r))")
check("its movie header says 1:01:59 too", r?.headerSeconds == 3719)
check("AVFoundation's 2:03:58 for it disagrees with the samples", MP4Timing.disagrees(reported: 7438, samples: real))
check("a rounding difference doesn't", !MP4Timing.disagrees(reported: 3719.2, samples: real) && !MP4Timing.disagrees(reported: 0, samples: real))

// The same file read from disk, with the mdat skipped rather than read.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("linkmedia-\(UUID().uuidString).m4a")
try? Data(dash).write(to: tmp)
check("read from a file the same as from memory", MP4Timing.read(tmp) == r)
try? FileManager.default.removeItem(at: tmp)

// Only the segment index: the fragments' boxes cut off.
let indexOnly = cat(box("ftyp", cat(ascii("dash"), be32(0))), box("moov", cat(mvhd(timescale: 1000, duration: 0), trak(id: 1, timescale: rate, stts: []))),
                    sidx(timescale: rate, ticks: UInt32(total * 1024)))
let ri = MP4Timing.read(data: Data(indexOnly))
check("the segment index gives the length when no fragment is there", abs((ri?.sampleSeconds ?? 0) - real) < 0.001 && ri?.headerSeconds == nil, "\(String(describing: ri))")

// A plain (unfragmented) M4A: samples in the sample table.
let plain = cat(box("ftyp", cat(ascii("M4A "), be32(0))),
                box("moov", cat(mvhd(timescale: 600, duration: 57_000), trak(id: 1, timescale: rate, stts: [(4092, 1024), (1, 512)]))),
                box("mdat", [1, 2, 3]))
let rp = MP4Timing.read(data: Data(plain))
check("a plain M4A: not fragmented, samples from its sample table", rp?.fragmented == false && abs((rp?.sampleSeconds ?? 0) - Double(4092 * 1024 + 512) / 44100) < 0.0001
      && rp?.headerSeconds == 95, "\(String(describing: rp))")
check("not an MP4: nil", MP4Timing.read(data: Data("ID3\u{3}garbage that is long enough".utf8)) == nil && MP4Timing.read(data: Data()) == nil)

// MARK: Chunked download ranges

check("the Range header is inclusive", LinkChunks.rangeHeader(offset: 0, chunk: 8_388_608) == "bytes=0-8388607"
      && LinkChunks.rangeHeader(offset: 8_388_608, chunk: 8_388_608) == "bytes=8388608-16777215")
check("Content-Range totals", LinkChunks.total(contentRange: "bytes 0-8388607/59514321") == 59_514_321
      && LinkChunks.total(contentRange: "bytes */59514321") == 59_514_321 && LinkChunks.total(contentRange: "bytes 0-1/*") == nil
      && LinkChunks.total(contentRange: nil) == nil)
// A server answering each Range as HTTP does (clamped to the file): the chunks cover it once, no gap, no overlap.
do {
    let size: Int64 = 59_514_321, chunk: Int64 = 8 * 1024 * 1024
    var offset: Int64 = 0, covered: [ClosedRange<Int64>] = []
    while offset < size {
        let h = LinkChunks.rangeHeader(offset: offset, chunk: chunk).dropFirst("bytes=".count).split(separator: "-").compactMap { Int64($0) }
        let range = h[0]...min(h[1], size - 1)
        covered.append(range)
        offset += range.count.toInt64
    }
    let contiguous = zip(covered, covered.dropFirst()).allSatisfy { $0.upperBound + 1 == $1.lowerBound }
    check("chunks cover a 59.5 MB file exactly once", covered.first?.lowerBound == 0 && covered.last?.upperBound == size - 1 && contiguous
          && covered.reduce(0) { $0 + Int64($1.count) } == size && covered.count == 8, "\(covered)")
}

// MARK: YouTube page metadata

let oembed = #"{"title":"The Dark Side of the “Pro-Life” Movement & The Truth About Abortion Politics | Ginna Cross | Ep 1412","author_name":"Allie Beth Stuckey","author_url":"https://www.youtube.com/@AllieBethStuckey","type":"video","provider_name":"YouTube"}"#
check("oEmbed author_name is the channel", YouTubePageMeta.author(oEmbed: Data(oembed.utf8)) == "Allie Beth Stuckey")
check("an oEmbed error page has no channel", YouTubePageMeta.author(oEmbed: Data("Not Found".utf8)) == nil)
let oURL = YouTubePageMeta.oEmbedURL(videoID: "1zUvmoQpVzw")
let oItems = oURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
check("the oEmbed URL", oURL?.host == "www.youtube.com" && oURL?.path == "/oembed"
      && oItems.first { $0.name == "url" }?.value == "https://www.youtube.com/watch?v=1zUvmoQpVzw" && oItems.first { $0.name == "format" }?.value == "json",
      "\(String(describing: oURL))")

let watch = """
<html><head><meta property="og:title" content="The Dark Side"><meta itemprop="datePublished" content="2026-10-23T05:00:12-07:00">
<meta itemprop="uploadDate" content="2026-10-23T05:00:12-07:00"></head><body>
<span itemprop="author" itemscope itemtype="http://schema.org/Person"><link itemprop="url" href="http://www.youtube.com/@AllieBethStuckey"><link itemprop="name" content="Allie Beth Stuckey"></span>
<script>var ytInitialPlayerResponse = {"videoDetails":{"videoId":"1zUvmoQpVzw","author":"Allie Beth Stuckey"},"microformat":{"playerMicroformatRenderer":{"ownerChannelName":"Allie Beth Stuckey","publishDate":"2026-10-23T05:00:12-07:00","uploadDate":"2026-10-23T05:00:12-07:00"}}};</script>
"""
let parsed = YouTubePageMeta.parse(html: watch)
check("the watch page's itemprop tags: channel and upload date (yyyyMMdd, like yt-dlp)", parsed.channel == "Allie Beth Stuckey" && parsed.uploadDate == "20261023", "\(parsed)")
let scriptOnly = #"<script>{"videoDetails":{"author":"Ben & Jerry's Kitchen"},"microformat":{"playerMicroformatRenderer":{"uploadDate":"2025-02-03"}}}</script>"#
let p2 = YouTubePageMeta.parse(html: scriptOnly)
check("the player data alone, with JSON escapes", p2.channel == "Ben & Jerry's Kitchen" && p2.uploadDate == "20250203", "\(p2)")
let p3 = YouTubePageMeta.parse(html: "<html><form action=\"https://consent.youtube.com/save\"></form></html>")
check("a consent page: nothing", p3.channel == nil && p3.uploadDate == nil)
check("dates", YouTubePageMeta.yyyyMMdd("2026-10-23") == "20261023" && YouTubePageMeta.yyyyMMdd("2026-13-01") == nil && YouTubePageMeta.yyyyMMdd("Oct 23") == nil)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

extension Int { var toInt64: Int64 { Int64(self) } }
