import Foundation

// The automatic kind (KindRule): recordings keep the meeting-or-note rule; links and imported media are never a
// meeting. Not part of any app target; run mac/tools/test-autolabel.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let audio = KindRule.Origin.media(video: false), video = KindRule.Origin.media(video: true)
func k(_ o: KindRule.Origin, _ speakers: Int, _ minutes: Double) -> RecordingKind { KindRule.kind(origin: o, speakers: speakers, duration: minutes * 60) }

// Recordings: unchanged.
check("a long recording with two speakers is a meeting", k(.recording, 2, 10) == .meeting)
check("a short recording with two speakers is a note", k(.recording, 2, 9.9) == .note)
check("a long recording with one speaker is a note", k(.recording, 1, 60) == .note)

// Links and imported media.
check("two speakers is a podcast, however long (the 1:01:59 YouTube report)", k(video, 2, 62) == .podcast && k(audio, 3, 5) == .podcast && k(video, 2, 1) == .podcast)
check("links and media are never a meeting", [audio, video].allSatisfy { o in (0...4).allSatisfy { s in [1.0, 9, 10, 90].allSatisfy { k(o, s, $0) != .meeting } } })
check("one speaker on video is a video", k(video, 1, 3) == .video && k(video, 1, 45) == .video && k(video, 0, 20) == .video)
check("one speaker, audio, 10 minutes or more is a talk", k(audio, 1, 10) == .talk && k(audio, 0, 40) == .talk)
check("one speaker, audio, under 10 minutes is a note", k(audio, 1, 9.9) == .note)
check("interview is never automatic", [KindRule.Origin.recording, audio, video].allSatisfy { o in (0...4).allSatisfy { s in [1.0, 10, 90].allSatisfy { k(o, s, $0) != .interview } } })

// The model's answer: recordings take one of the four model kinds; links and media always take the rule's.
check("a recording takes the model's kind", KindRule.fromModel(" Journal ", origin: .recording, fallback: .note) == .journal)
check("a recording ignores a kind the model may not give", KindRule.fromModel("podcast", origin: .recording, fallback: .note) == .note
      && KindRule.fromModel("dictation", origin: .recording, fallback: .meeting) == .meeting && KindRule.fromModel(nil, origin: .recording, fallback: .note) == .note)
check("a link ignores the model's meeting", KindRule.fromModel("meeting", origin: video, fallback: .podcast) == .podcast)

// Where a transcript came from.
func t(_ source: SourceKind, label: String = "", url: String? = nil, link: LinkInfo? = nil) -> Transcript {
    var x = Transcript(title: "t", source: source, sourceLabel: label, duration: 60, audioFileName: nil, model: "")
    x.sourceURL = url; x.link = link
    return x
}
check("a voice memo is a recording", KindRule.origin(of: t(.voiceMemo)) == .recording)
check("app audio is a recording", KindRule.origin(of: t(.app)) == .recording)
check("a YouTube link is video", KindRule.origin(of: t(.link, url: "https://youtu.be/1zUvmoQpVzw", link: LinkInfo(url: "https://www.youtube.com/watch?v=1zUvmoQpVzw", site: "YouTube"))) == video)
check("a link synced from the iPhone (no link details yet) is video by its URL", KindRule.origin(of: t(.link, url: "https://www.youtube.com/watch?v=x")) == video)
check("an Apple Podcasts link is audio", KindRule.origin(of: t(.link, url: "https://podcasts.apple.com/us/podcast/x/id1?i=2")) == audio)
check("a direct MP4 link is video", KindRule.origin(of: t(.link, url: "https://example.com/files/talk.mp4")) == video)
check("a direct MP3 link is audio", KindRule.origin(of: t(.link, url: "https://example.com/files/ep.mp3")) == audio)
check("an imported MP4 is video", KindRule.origin(of: t(.file, label: "MP4 file")) == video)
check("an imported M4A is audio", KindRule.origin(of: t(.file, label: "M4A file")) == audio)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
