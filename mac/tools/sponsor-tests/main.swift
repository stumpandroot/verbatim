import Foundation

// Sponsor detection (SponsorDetect.swift) against a real episode, and the transcript-side rules (Sponsors.swift):
// folding, skipping, marking, and leaving sponsor reads out of summaries and exports.
//   bash mac/tools/test-sponsors.sh

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
}

// MARK: The fixture

/// The episode as exported from the iPhone ("Speaker 2: …" paragraphs), split into one line per sentence with
/// times at 2.5 words a second, the way the engine's segments arrive: a read starts and ends at a sentence, often
/// in the middle of the host's turn.
func fixtureLines(_ path: String, speakers: Bool = true, wordsPerSecond: Double = 2.5, sentencesPerLine: Int = 1) -> [SponsorDetect.Line] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("FAIL  can't read \(path)"); exit(1) }
    var lines: [SponsorDetect.Line] = []
    var t = 0.0
    var speaker: String? = nil
    for para in text.components(separatedBy: "\n") where !para.trimmingCharacters(in: .whitespaces).isEmpty {
        var body = para
        if let r = para.range(of: #"^Speaker (\d+): "#, options: .regularExpression) {
            speaker = "S" + para[r].filter(\.isNumber)
            body = String(para[r.upperBound...])
        }
        let sentences = body.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\n", options: .regularExpression)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let grouped = stride(from: 0, to: sentences.count, by: sentencesPerLine).map { sentences[$0..<min(sentences.count, $0 + sentencesPerLine)].joined(separator: " ") }
        for s in grouped {
            let words = Double(s.split(separator: " ").count)
            let d = max(0.6, words / wordsPerSecond)
            lines.append(.init(start: t, end: t + d, text: s, speaker: speakers ? speaker : nil))
            t += d + 0.15
        }
    }
    return lines
}

let fixture = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "podcast-export.txt"
let lines = fixtureLines(fixture)
let found = SponsorDetect.detect(lines)
func squash(_ s: String?) -> String { (s ?? "").lowercased().filter { $0.isLetter } }
func show(_ f: SponsorDetect.Found) -> String {
    "\(f.name ?? "?") \(Int(f.start))–\(Int(f.end)) s, lines \(f.first)–\(f.last): “\(lines[f.first].text.prefix(50))” … “\(lines[f.last].text.prefix(50))”"
}
for f in found { print("      found \(show(f))") }

/// Each read in the episode: how its first and last lines begin, and how the sponsor is named.
struct Expected { var name: String; var first: String; var last: String }
let expected: [Expected] = [
    .init(name: "Good Ranchers", first: "Y'all know we have been using Good Ranchers", last: "Get $50 off anything on their site"),
    .init(name: "Alliance Defending Freedom", first: "You know, a few years ago, it felt like we had defeated Marxism", last: "Go to joinadf.com slash alley"),
    .init(name: "CrowdHealth", first: "Next sponsor is Crowd Health.", last: "Joincrowdhealth.com code Alley."),
    .init(name: "Patriot Mobile", first: "So many companies today are happy to take your money", last: "Patriotmobile.com slash Ali code Alley."),
    .init(name: "Preborn", first: "We've got some really good news from preborn.", last: "That's preborn.com slash Allie."),
]
check("five sponsor reads, no more", found.count == expected.count, "found \(found.count)")
for e in expected {
    guard let f = found.first(where: { squash($0.name) == squash(e.name) }) else { check("\(e.name) is found", false); continue }
    check("\(e.name) is found and named", true)
    check("\(e.name) starts at its first line", lines[f.first].text.hasPrefix(e.first), "starts “\(lines[f.first].text.prefix(70))”")
    check("\(e.name) ends at its last line", lines[f.last].text.hasPrefix(e.last), "ends “\(lines[f.last].text.prefix(70))”")
    check("\(e.name) is one speaker's read", Set(lines[f.first...f.last].map(\.speaker)).count == 1)
    let length = f.end - f.start
    check("\(e.name) runs a sensible length (30 s to 3 min)", length >= 30 && length <= 180, "\(Int(length)) s")
}

// The interview isn't flagged: no guest line, and every flagged line sits in one of the five reads.
let flagged = Set(found.flatMap { Array($0.first...$0.last) })
check("no guest line is flagged", flagged.allSatisfy { lines[$0].speaker == "S2" })
let topicLines = [
    "Why do you think so many of those who are on the front lines against abortion",
    "It's interesting because at a lot of these pregnancy centers where I travel",
    "And with respect to that pregnancy center I was referring to earlier",
    "I know that you have some like bookmarks in your Bible",
    "You can find us at our website is alliancefamily services.org.",
    "Jenna, thanks so much for taking the time to join us.",
]
for t in topicLines {
    let i = lines.firstIndex { $0.text.hasPrefix(t) }
    check("topic line isn't flagged: “\(t.prefix(40))…”", i.map { !flagged.contains($0) } ?? false, i == nil ? "line not in the fixture" : "")
}
let flaggedWords = flagged.reduce(0) { $0 + lines[$1].text.split(separator: " ").count }
let allWords = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
check("reads are a small share of the episode (under 15% of the words)", Double(flaggedWords) / Double(allWords) < 0.15, "\(flaggedWords) of \(allWords)")

// Without speaker labels the reads are still found, held tighter.
let flat = fixtureLines(fixture, speakers: false)
let flatFound = SponsorDetect.detect(flat)
for f in flatFound { print("      unlabeled: \(f.name ?? "?") \(Int(f.start))–\(Int(f.end)) s") }
check("without speakers, all five are found", found.allSatisfy { f in flatFound.contains { $0.start < f.end && f.start < $0.end } }
      && flatFound.count == found.count, "\(flatFound.map { $0.name ?? "?" })")
check("without speakers, no read runs past 3 minutes", flatFound.allSatisfy { $0.end - $0.start <= 180 })
check("without speakers, no guest line is flagged", flatFound.allSatisfy { f in (f.first...f.last).allSatisfy { lines[$0].speaker == "S2" } })

// Faster speech and longer segments (two sentences each, so reads start and end inside a segment): the same five.
let coarse = fixtureLines(fixture, wordsPerSecond: 3.2, sentencesPerLine: 2)
let coarseFound = SponsorDetect.detect(coarse)
for f in coarseFound { print("      coarse: \(f.name ?? "?") \(Int(f.start))–\(Int(f.end)) s") }
check("with longer segments, the same five reads", Set(coarseFound.map { squash($0.name) }) == Set(expected.map { squash($0.name) }) && coarseFound.count == 5,
      "\(coarseFound.map { $0.name ?? "?" })")
check("with longer segments, no guest line is flagged", coarseFound.allSatisfy { f in (f.first...f.last).allSatisfy { coarse[$0].speaker == "S2" } })

// MARK: Rules on short lines

func one(_ texts: [String], speaker: String? = "S1") -> [SponsorDetect.Found] {
    var t = 0.0
    return SponsorDetect.detect(texts.map { s in defer { t += 6 }; return .init(start: t, end: t + 5, text: s, speaker: speaker) })
}
check("a cue names the sponsor", one(["This episode is brought to you by Squarespace.", "Build your website today."]).first?.name == "Squarespace")
check("a bare website from a guest isn't a read", one(["You can find us at alliancefamilyservices.org."]).isEmpty)
check("“code for” in conversation isn't a read", one(["That's code for all nine months for any reason."]).isEmpty)
check("“pre-born” in conversation isn't a read", one(["Pre-born children need legal protection.", "The pre-born are people."]).isEmpty)
check("“dot com slash” is a vanity link", one(["Head to athletic greens dot com slash tim."]).count == 1)
check("a domain names the sponsor when nothing else does", SponsorDetect.name(fromDomain: "joinadf") == "ADF" && SponsorDetect.name(fromDomain: "drinkag1") == "AG1")
check("domain keys drop vanity words", SponsorDetect.keys(fromDomain: "joincrowdhealth") == ["joincrowdhealth", "crowdhealth"])


// MARK: Apple Intelligence's answer

check("a yes with a name", SponsorDetect.verdict(from: "SPONSOR: yes\nNAME: CrowdHealth") == .sponsor(name: "CrowdHealth"))
check("a no", SponsorDetect.verdict(from: "Sponsor: No.\nName: none") == .notSponsor)
check("a yes without a name", SponsorDetect.verdict(from: "**SPONSOR:** yes\nNAME: none") == .sponsor(name: nil))
check("anything else is unknown", SponsorDetect.verdict(from: "This passage discusses abortion policy.") == .unknown)
check("the model's spelling of the same brand wins", SponsorDetect.pickName(rule: "Preborn", model: "PreBorn") == "PreBorn"
      && SponsorDetect.pickName(rule: "Crowd Health", model: "CrowdHealth") == "CrowdHealth")
check("a different brand from the model doesn't replace the read's", SponsorDetect.pickName(rule: "Good Ranchers", model: "Butcher Box") == "Good Ranchers")
check("the model names a read the rules couldn't", SponsorDetect.pickName(rule: nil, model: "Squarespace") == "Squarespace")

// MARK: On a transcript

func episode() -> Transcript {
    var t = Transcript(title: "Episode", source: .link, sourceLabel: "YouTube", duration: lines.last?.end ?? 0, audioFileName: nil, model: "test")
    t.segments = lines.map { Segment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker) }
    t.speakers = [Speaker(id: "S1", name: "Jenna"), Speaker(id: "S2", name: "Allie")]
    t.kind = .podcast
    return t
}
var t = episode()
check("a new transcript hasn't been checked", t.sponsors == nil && t.sponsorSpans.isEmpty)
t.applySponsors(found)
check("detection stores five spans", t.sponsorSpans.count == 5)
let kept = t.segmentsWithoutSponsors.map(\.text).joined(separator: " ").lowercased()
check("summaries and labels never see a read", !kept.contains("goodranchers") && !kept.contains("joinadf") && !kept.contains("crowdhealth")
      && !kept.contains("patriot mobile") && !kept.contains("preborn.com"))
check("summaries and labels keep the interview", kept.contains("toxic empathy") && kept.contains("romans 13"))
check("export leaves the read's lines out", t.withoutSponsors(t.segments).count == t.segments.count - flagged.count)

// Folding: one row per read, at its first line.
let places = SponsorFold.places(t.segments, in: t)
check("each read folds into one row", places.compactMap { $0 }.filter(\.first).count == 5)
check("folded lines are exactly the read's lines", Set(places.indices.filter { places[$0] != nil }) == flagged)
if let gr = t.sponsorSpans.first {
    check("the row says “Sponsor: Good Ranchers · m:ss”", SponsorFold.title(gr).hasPrefix("Sponsor: Good Ranchers · ") && SponsorFold.title(gr).contains(":"),
          SponsorFold.title(gr))
}
check("a row without a name", SponsorFold.title(SponsorSpan(start: 0, end: 72)) == "Sponsor · 1:12")
check("lengths past an hour", SponsorFold.length(3734) == "1:02:14")
// A filler line hidden inside a read doesn't split the fold.
let shown = t.segments.enumerated().filter { $0.offset != 80 }.map(\.element)
check("hidden lines don't split a fold", SponsorFold.places(shown, in: t).compactMap { $0 }.filter(\.first).count == 5)

// Skipping: only crossing into a read jumps; seeking into one plays it.
let spans = t.sponsorSpans.map { (start: $0.start, end: $0.end) }
let gr = spans[0]
check("playback crossing into a read jumps to its end", SponsorSkip.target(from: gr.start - 0.03, to: gr.start + 0.02, spans: spans) == gr.end)
check("playing from inside a read doesn't jump", SponsorSkip.target(from: gr.start + 10, to: gr.start + 10.05, spans: spans) == nil)
check("starting at a read's first line doesn't jump", SponsorSkip.target(from: gr.start, to: gr.start + 0.05, spans: spans) == nil)
check("a seek across a read doesn't jump", SponsorSkip.target(from: gr.start - 30, to: gr.start + 5, spans: spans) == nil)
check("back-to-back reads go in one jump", SponsorSkip.target(from: 9.9, to: 10.05, spans: [(10, 40), (40.2, 70)]) == 70)

// Corrections.
var c = t
let crowd = c.sponsorSpans[2]
c.dismissSponsor(crowd.id)
check("“Not a sponsor” stops the fold", c.sponsorSpans.count == 4 && !c.sponsorSpans.contains { $0.id == crowd.id })
c.applySponsors(found)
check("detecting again doesn't bring a dismissed read back", c.sponsorSpans.count == 4)
let topic = c.segments.firstIndex { $0.text.hasPrefix("It's interesting because at a lot of these pregnancy centers") }!
c.markSponsor(segment: c.segments[topic].id)
check("“Mark as sponsor” adds a span someone marked", c.sponsorSpans.contains { $0.source == .person })
c.markSponsor(segment: c.segments[topic + 1].id)
check("marking the next line grows the same span", c.sponsorSpans.filter { $0.source == .person }.count == 1
      && c.sponsorSegmentIDs.contains(c.segments[topic + 1].id))
c.applySponsors(found)
check("detecting again keeps what someone marked", c.sponsorSpans.contains { $0.source == .person })
let marked = c.sponsorSpans.first { $0.source == .person }!
c.dismissSponsor(marked.id)
check("“Not a sponsor” on a marked span removes it", !(c.sponsors ?? []).contains { $0.id == marked.id })
let inCrowd = c.segments.first { $0.start >= crowd.start && $0.end <= crowd.end }!
c.markSponsor(segment: inCrowd.id)
check("marking a line in a dismissed read brings it back", c.sponsorSpans.contains { $0.id == crowd.id })

// Which recordings are checked.
check("podcasts from links are checked", Transcript.detectsSponsors(isMedia: true, kind: .podcast))
check("videos, talks, and interviews are checked", [.video, .talk, .interview].allSatisfy { Transcript.detectsSponsors(isMedia: true, kind: $0) })
check("meetings and notes aren't", !Transcript.detectsSponsors(isMedia: true, kind: .meeting) && !Transcript.detectsSponsors(isMedia: true, kind: .note))
check("voice memos aren't", !Transcript.detectsSponsors(isMedia: false, kind: .podcast))

// Files: the field round-trips, older files read without it, and an older build's file writes no sponsors key.
let enc = JSONEncoder(), dec = JSONDecoder()
c.dismissSponsor(c.sponsorSpans[0].id)
if let data = try? enc.encode(c), let back = try? dec.decode(Transcript.self, from: data) {
    check("spans round-trip through the file", back.sponsors == c.sponsors)
    check("dismissed and marked spans round-trip", (back.sponsors ?? []).contains { $0.dismissed } && (back.sponsors ?? []).contains { $0.source == .person })
} else { check("spans round-trip through the file", false, "encode or decode failed") }
let plain = episode()
if let data = try? enc.encode(plain), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    check("an unchecked transcript writes no sponsors key", obj["sponsors"] == nil)
    check("a file without the key reads as unchecked", (try? dec.decode(Transcript.self, from: data))?.sponsors == nil)
}
let future = #"{"title":"x","source":"link","segments":[],"sponsors":[{"start":1,"end":5,"source":"crowd","later":true}]}"#
let read = try? dec.decode(Transcript.self, from: Data(future.utf8))
check("a newer build's span reads, with an unknown source as the rules'", read?.sponsors?.first?.source == .rules && read?.sponsors?.first?.end == 5)
let broken = #"{"title":"x","source":"link","segments":[],"sponsors":"not a list"}"#
check("spans in a shape this build can't read don't fail the file", (try? dec.decode(Transcript.self, from: Data(broken.utf8)))?.sponsors == nil
      && (try? dec.decode(Transcript.self, from: Data(broken.utf8))) != nil)

if failures > 0 { print("\(failures) sponsor check(s) failed"); exit(1) }
print("All sponsor checks passed.")
