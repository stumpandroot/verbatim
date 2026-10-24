import Foundation

// Speaker name suggestions (SpeakerNames): what people say, link details, past names, Apple Intelligence's answer
// checked against the transcript, and voice matches. Not part of any app target; run mac/tools/test-speaker-names.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

/// "Speaker 1: …" paragraphs as one segment per sentence, timed at 2.5 words a second. Unlabeled paragraphs have no
/// speaker.
func segments(_ export: String) -> [Segment] {
    var out: [Segment] = []
    var t = 0.0
    for para in export.components(separatedBy: "\n\n") {
        var text = para.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        var speaker: String? = nil
        if text.hasPrefix("Speaker "), let colon = text.firstIndex(of: ":") {
            speaker = "S" + text[text.index(text.startIndex, offsetBy: 8)..<colon]
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        for s in SpeakerNames.splitSentences(text) {
            let d = Double(s.split(separator: " ").count) / 2.5
            out.append(Segment(start: t, end: t + d, text: s, speaker: speaker))
            t += d
        }
    }
    return out
}

func lines(_ pairs: [(String?, String)]) -> [Segment] {
    var t = 0.0
    return pairs.map { sp, text in
        defer { t += 5 }
        return Segment(start: t, end: t + 5, text: text, speaker: sp)
    }
}

let two = [Speaker(id: "S1", name: "Speaker 1"), Speaker(id: "S2", name: "Speaker 2")]
func names(_ s: [SpeakerSuggestion]) -> [String: String] { Dictionary(uniqueKeysWithValues: s.map { ($0.speakerId, $0.name) }) }

// MARK: The YouTube fixture

guard let export = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else { print("FAIL  can't read the fixture"); exit(1) }
let yt = segments(export)
let title = "The Dark Side of the “Pro-Life” Movement & The Truth About Abortion Politics | Ginna Cross | Ep 1412"
let channel = "Allie Beth Stuckey"
let ytSuggestions = SpeakerNames.suggest(.init(segments: yt, speakers: two, title: title, channel: channel))
let s1 = ytSuggestions.first { $0.speakerId == "S1" }, s2 = ytSuggestions.first { $0.speakerId == "S2" }
check("the fixture parses", yt.count > 100 && Set(yt.compactMap(\.speaker)) == ["S1", "S2"])
check("Speaker 1 might be Ginna Cross, the title's spelling", s1?.name == "Ginna Cross", "\(ytSuggestions)")
check("…because Speaker 2 calls them Jenna, and the title names her", s1.map { $0.reasons.first?.hasPrefix("called “Jenna” at ") == true && $0.reasons.contains("named in the title") } == true,
      "\(s1?.reasons ?? [])")
check("…the address is counted more than once", s1?.reasons.first?.contains("more times") == true, "\(s1?.reasons ?? [])")
check("…the reason reads as one line", s1?.reasonText.hasPrefix("Called “Jenna” at ") == true && s1?.reasonText.contains(" · named in the title") == true,
      s1?.reasonText ?? "")
check("Speaker 2 might be Allie Beth Stuckey, the channel", s2?.name == "Allie Beth Stuckey", "\(ytSuggestions)")
check("…because it's the channel and they ask the questions", s2.map { $0.reasons.first == "the channel’s name" && $0.reasons.contains("asks the questions") } == true,
      "\(s2?.reasons ?? [])")
check("suggestions name their sources", s1?.sources == ["speech", "link"] && s2?.sources == ["link"], "\(s1?.sources ?? []) \(s2?.sources ?? [])")
check("suggestions start pending", ytSuggestions.allSatisfy { $0.state == .pending })

// Without the link details, the heard spelling, from what people say alone.
let heardOnly = SpeakerNames.suggest(.init(segments: yt, speakers: two))
check("without the link, Speaker 1 might be Jenna and Speaker 2 gets nothing", names(heardOnly) == ["S1": "Jenna"], "\(heardOnly)")
// A speaker you already named isn't suggested a name; the other one still is.
let namedHost = SpeakerNames.suggest(.init(segments: yt, speakers: [Speaker(id: "S1", name: "Speaker 1"), Speaker(id: "S2", name: "Allie")],
                                           title: title, channel: channel))
check("a named speaker gets no suggestion", names(namedHost) == ["S1": "Ginna Cross"], "\(namedHost)")

// MARK: What people say

let intro = lines([
    ("S1", "Hi everyone, and welcome back to the show."),
    ("S1", "My guest today is Priya Raman. She builds bridges for a living."),
    ("S2", "Thanks for having me. It's great to be here."),
    ("S1", "Priya, what got you into engineering?"),
    ("S2", "Honestly, my dad. He fixed everything in the house."),
    ("S1", "That's lovely. Thank you so much, Priya."),
])
let introS = SpeakerNames.suggest(.init(segments: intro, speakers: two))
check("a host introduction names the guest", names(introS) == ["S2": "Priya Raman"], "\(introS)")
check("…introduced and called by name", introS.first?.reasons.first?.hasPrefix("introduced as “Priya Raman”") == true
      && introS.first?.reasons.contains(where: { $0.hasPrefix("called “Priya”") }) == true, "\(introS.first?.reasons ?? [])")

let selfIntro = lines([
    ("S1", "Hello. My name is Tomás Ortega and I run the bakery on Main."),
    ("S2", "Nice to meet you."),
    ("S1", "We open at six."),
    ("S2", "Do you sell bread on Sundays?"),
])
check("a self-introduction names the speaker", names(SpeakerNames.suggest(.init(segments: selfIntro, speakers: two))) == ["S1": "Tomás Ortega"])

let imSam = lines([
    ("S1", "Hey, I'm Sam, and this is the weekly update."),
    ("S2", "And I'm Dana."),
    ("S1", "Let's get into it."),
])
check("“I'm X” near the start names each speaker", names(SpeakerNames.suggest(.init(segments: imSam, speakers: two))) == ["S1": "Sam", "S2": "Dana"],
      "\(SpeakerNames.suggest(.init(segments: imSam, speakers: two)))")

// MARK: Negative cases

let plain = lines([
    ("S1", "So I think we should move the launch to Thursday."),
    ("S2", "Well, that depends on the printer. Honestly, I'm not sure."),
    ("S1", "Absolutely, let's ask them. Christians, Republicans, everyone loves a good flyer."),
    ("S2", "Right, Florida, Texas, and Ohio are the first stores."),
    ("S1", "Okay. I'm going to call them now."),
])
check("no names, no suggestions", SpeakerNames.suggest(.init(segments: plain, speakers: two)).isEmpty, "\(SpeakerNames.suggest(.init(segments: plain, speakers: two)))")

let ambiguous = lines([
    ("S1", "Jenna, thanks for coming in."),
    ("S2", "Of course, happy to help."),
    ("S1", "Maria, what do you think about the plan?"),
    ("S2", "I like it a lot."),
])
check("two different names for one speaker, no suggestion", SpeakerNames.suggest(.init(segments: ambiguous, speakers: two)).isEmpty,
      "\(SpeakerNames.suggest(.init(segments: ambiguous, speakers: two)))")

let once = lines([
    ("S1", "We talked about the budget for a long time and then moved on to hiring for the spring."),
    ("S1", "But Kevin, the numbers didn't add up, so we waited a week before deciding anything at all."),
    ("S1", "In the end the team agreed on two hires and a contractor for the summer months."),
    ("S2", "That sounds right to me."),
])
check("one mention in the middle of a turn isn't enough", SpeakerNames.suggest(.init(segments: once, speakers: two)).isEmpty,
      "\(SpeakerNames.suggest(.init(segments: once, speakers: two)))")

let lowercaseToo = lines([
    ("S1", "Grace, thanks for coming."),
    ("S2", "It was all grace, really."),
])
check("a word also heard in lowercase isn't a name", SpeakerNames.suggest(.init(segments: lowercaseToo, speakers: two)).isEmpty)

let oneSpeaker = SpeakerNames.suggest(.init(segments: intro, speakers: [Speaker(id: "S1", name: "Speaker 1")]))
check("one speaker, no suggestions", oneSpeaker.isEmpty)

let notAPerson = SpeakerNames.suggest(.init(segments: yt, speakers: two, title: "Abortion Politics | Ep 1412", channel: "The Daily Wire"))
check("a channel that isn't a person names nobody", names(notAPerson) == ["S1": "Jenna"], "\(notAPerson)")

// MARK: Link details

check("names in a title", SpeakerNames.titleNames(title, channel: channel) == ["Ginna Cross"], "\(SpeakerNames.titleNames(title, channel: channel))")
check("names after with and ft.", SpeakerNames.titleNames("Building in public with Marcus Lee", channel: nil) == ["Marcus Lee"]
      && SpeakerNames.titleNames("Night Drive (ft. Sofia Carson)", channel: nil) == ["Sofia Carson"],
      "\(SpeakerNames.titleNames("Night Drive (ft. Sofia Carson)", channel: nil))")
check("the channel isn't a guest", SpeakerNames.titleNames("Allie Beth Stuckey | Ginna Cross", channel: channel) == ["Ginna Cross"])
check("a person's name, not a show", SpeakerNames.personName("Allie Beth Stuckey") == "Allie Beth Stuckey" && SpeakerNames.personName("The Daily Show") == nil
      && SpeakerNames.personName("Ep 1412") == nil && SpeakerNames.personName("Lex") == nil)
check("Jenna sounds like Ginna", SpeakerNames.sameName("Jenna", "Ginna Cross") && SpeakerNames.soundsAlike("Katherine", "Catherine")
      && SpeakerNames.soundsAlike("Allie", "Ally"))
check("different names don't sound alike", !SpeakerNames.sameName("Jenna", "Allie Beth Stuckey") && !SpeakerNames.soundsAlike("Mark", "Mike")
      && !SpeakerNames.sameName("Ginna Cross", "Ginna Smith"))

// A title guest nobody named out loud goes to the speaker who isn't the host.
let quiet = lines([
    ("S1", "Welcome to the program. Today we talk about soil."),
    ("S2", "Soil is alive, and most people never think about it."),
    ("S1", "Why does that matter for farmers?"),
    ("S2", "Because the yield depends on it."),
    ("S1", "Where can people learn more?"),
    ("S2", "My website has a guide."),
    ("S1", "Thanks for listening, see you next week."),
])
let quietS = SpeakerNames.suggest(.init(segments: quiet, speakers: two, title: "Living Soil | Dr. Elaine Ingham", channel: "Marcus Webb"))
check("the host from the channel, the guest from the title", names(quietS) == ["S1": "Marcus Webb", "S2": "Elaine Ingham"], "\(quietS)")

// MARK: Past names

let pastCall = lines([
    ("S1", "Mark, thanks for jumping on."),
    ("S2", "Anytime."),
    ("S1", "Mark, can you send the deck?"),
    ("S2", "Will do."),
])
let pastS = SpeakerNames.suggest(.init(segments: pastCall, speakers: two, pastNames: ["Mark Hughes", "Dana Fox"]))
check("a past full name fills in a first name", names(pastS) == ["S2": "Mark Hughes"] && pastS.first?.reasons.contains("a name you’ve used before") == true, "\(pastS)")
let pastAmbiguous = SpeakerNames.suggest(.init(segments: pastCall, speakers: two, pastNames: ["Mark Hughes", "Mark Ruiz"]))
check("two past Marks keep the heard name", names(pastAmbiguous) == ["S2": "Mark"], "\(pastAmbiguous)")
var other = Transcript(title: "x", source: .voiceMemo, sourceLabel: "", duration: 1, audioFileName: nil, model: "")
other.speakers = [Speaker(id: "S1", name: "Dana Fox"), Speaker(id: "S2", name: "Speaker 2"), Speaker(id: "S3", name: "You")]
var other2 = other; other2.id = UUID(); other2.speakers = [Speaker(id: "S1", name: "Dana Fox"), Speaker(id: "S2", name: "Mark Hughes")]
check("past names skip placeholders and You, most used first", SpeakerNames.pastNames([other, other2]) == ["Dana Fox", "Mark Hughes"])

// MARK: Apple Intelligence

let answer = """
    S1: Ginna Cross | Jenna, thanks so much for taking the time
    S2: Allie Beth Stuckey | Channel: Allie Beth Stuckey
    Speaker 1: John Smith | runs a clinic
    """
let model = SpeakerNames.modelEvidence(answer, speakers: two, segments: yt, title: title, channel: channel)
check("the model's names are kept when the transcript or details have them", model.map(\.name) == ["Ginna Cross", "Allie Beth Stuckey"], "\(model.map(\.name))")
check("a name in neither is dropped", !model.contains { $0.name == "John Smith" })
let excerpt = SpeakerNames.modelExcerpt(yt, speakers: two, maxWords: 600)
check("the excerpt is bounded and labeled", excerpt.split(whereSeparator: { $0.isWhitespace }).count <= 700 && excerpt.hasPrefix("S1: ") && excerpt.contains("[…]"))
let withModel = SpeakerNames.suggest(.init(segments: plain, speakers: two, extra: SpeakerNames.modelEvidence("S1: Sam | hi", speakers: two, segments: plain, title: "", channel: nil)))
check("an ungrounded model name alone suggests nothing", withModel.isEmpty)

// MARK: Voices

let named: [(name: String, embedding: [Float])] = [("Dana Fox", [1, 0, 0, 0]), ("Mark Hughes", [0, 1, 0, 0])]
let heard: [String: [Float]] = ["S1": [0.95, 0.1, 0.05, 0], "S2": [0.5, 0.5, 0.5, 0.5]]
let voice = SpeakerNames.voiceEvidence(voices: heard, named: named)
check("a close voice match is evidence, a vague one isn't", voice.map(\.speaker) == ["S1"] && voice.first?.name == "Dana Fox")
let byVoice = SpeakerNames.suggest(.init(segments: plain, speakers: two, extra: voice))
check("a voice match alone suggests the name", names(byVoice) == ["S1": "Dana Fox"] && byVoice.first?.sources == ["voice"], "\(byVoice)")
let mapped = SpeakerNames.voices(turns: [(speaker: "A", start: 0, end: 6), (speaker: "B", start: 6, end: 20)],
                                 embeddings: ["A": [1, 0], "B": [0, 1]], segments: lines([("S1", "one"), ("S2", "two"), ("S2", "three")]))
check("each speaker gets the voice that overlaps its lines most", mapped["S1"] == [1, 0] && mapped["S2"] == [0, 1])

// MARK: Saving and showing

var t = Transcript(title: "x", source: .link, sourceLabel: "", duration: 1, audioFileName: nil, model: "")
t.speakers = two
t.speakerSuggestions = SpeakerNames.merge(existing: nil, new: ytSuggestions)
check("both suggestions show", t.visibleSpeakerSuggestions.map(\.name) == ["Ginna Cross", "Allie Beth Stuckey"])
t.markSpeakerSuggestion(s2!.id, .dismissed)
check("a dismissed suggestion hides", t.visibleSpeakerSuggestions.map(\.name) == ["Ginna Cross"])
t.speakerSuggestions = SpeakerNames.merge(existing: t.speakerSuggestions, new: ytSuggestions)
check("…and stays dismissed when suggestions run again", t.visibleSpeakerSuggestions.map(\.name) == ["Ginna Cross"]
      && t.speakerSuggestions?.filter { $0.speakerId == "S2" }.map(\.state) == [.dismissed])
t.markSpeakerSuggestion(s1!.id, .accepted)
t.speakers[0].name = "Ginna Cross"
check("a used suggestion hides and keeps its reasons", t.visibleSpeakerSuggestions.isEmpty
      && t.speakerSuggestions?.first { $0.speakerId == "S1" }?.reasons == s1?.reasons)
var renamed = t; renamed.speakerSuggestions = SpeakerNames.merge(existing: nil, new: ytSuggestions); renamed.speakers[1].name = "Allie"
check("a speaker renamed by hand hides its suggestion", renamed.visibleSpeakerSuggestions.isEmpty)
check("merging nothing into nothing writes nothing", SpeakerNames.merge(existing: nil, new: []) == nil)
check("placeholders", Speaker(id: "S1", name: "Speaker 12").isPlaceholder && Speaker(id: "S1", name: "").isPlaceholder
      && !Speaker(id: "S1", name: "You").isPlaceholder && !Speaker(id: "S1", name: "Speaker Ann").isPlaceholder)

// Files: the field round-trips, older files don't have it, and an odd one doesn't break the transcript.
let enc = JSONEncoder(), dec = JSONDecoder()
enc.dateEncodingStrategy = .iso8601; dec.dateDecodingStrategy = .iso8601
let back = try? dec.decode(Transcript.self, from: enc.encode(t))
check("suggestions round-trip", back?.speakerSuggestions == t.speakerSuggestions)
var fresh = Transcript(title: "New", source: .voiceMemo, sourceLabel: "", duration: 1, audioFileName: nil, model: "")
fresh.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
let freshJSON = (try? JSONSerialization.jsonObject(with: enc.encode(fresh))) as? [String: Any] ?? [:]
check("a transcript without suggestions writes no key", freshJSON["speakerSuggestions"] == nil)
let odd = Data(#"{"title":"Odd","speakerSuggestions":[{"speakerId":"S1","name":"Ann","state":"snoozed","extra":1},{"name":"Bo"}]}"#.utf8)
let oddT = try? dec.decode(Transcript.self, from: odd)
check("an unknown state reads as dismissed", oddT?.speakerSuggestions?.first?.state == .dismissed && oddT?.speakerSuggestions?.count == 2)
let broken = Data(#"{"title":"Broken","speakerSuggestions":"nope"}"#.utf8)
check("a broken field is dropped, the transcript reads", (try? dec.decode(Transcript.self, from: broken)).map { $0.title == "Broken" && $0.speakerSuggestions == nil } == true)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
