import Foundation

// The AI output checks (Verbatim/Model/Grounding.swift and Grounding+Results.swift): generated text against its source.
// Every name, place, and number here is invented. Not part of any app target; run mac/tools/test-grounding.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

func findings(_ output: String, _ source: String, known: [String] = [], duration: Double? = nil) -> [GroundingFinding] {
    Grounding.check(output, against: GroundingSource(text: source, known: known, duration: duration))
}
func texts(_ f: [GroundingFinding]) -> [String] { f.map(\.text) }
/// Clean: nothing found.
func clean(_ name: String, _ output: String, _ source: String, known: [String] = []) {
    let f = findings(output, source, known: known)
    check("clean: " + name, f.isEmpty, "found \(f.map { "\($0.kind.rawValue):\($0.text)" })")
}
/// Flags exactly these texts (in any order).
func flags(_ name: String, _ output: String, _ source: String, _ expected: [String], known: [String] = []) {
    let f = findings(output, source, known: known)
    check("flags: " + name, Set(texts(f)) == Set(expected) && f.count == expected.count, "found \(f.map { "\($0.kind.rawValue):\($0.text)" }), expected \(expected)")
}

// MARK: Numbers

let budgetCall = "Okay so Dana said the budget is twelve hundred dollars for the booth. We meet at three thirty on Friday at the Millbrook office. About thirty-two percent of the volunteers said yes. The order is five thousand flyers, and we need a dozen boxes. Her number is five five five oh one four two."
clean("$1,200 matches twelve hundred dollars", "Dana set the budget at $1,200.", budgetCall)
clean("1200 dollars matches $1,200", "The booth costs $1,200.", "The booth costs 1200 dollars, give or take.")
clean("1,200 written with a comma", "The booth costs 1,200 dollars.", "The booth costs $1200.")
clean("$1.2 million matches 1.2 million", "Revenue reached $1.2 million.", "We hit 1.2 million in revenue this year.")
clean("$1.2M matches 1,200,000", "Revenue reached $1.2M.", "We hit 1,200,000 in revenue this year.")
clean("32% matches thirty-two percent", "About 32% of volunteers agreed.", budgetCall)
clean("32 percent matches 32%", "Thirty-two percent of volunteers agreed.", "Turnout was 32% this time.")
clean("3:30 PM matches three thirty", "They meet at 3:30 PM on Friday.", budgetCall)
clean("3:30 matches half past three", "The call starts at 3:30.", "Let's do the call at half past three.")
clean("3 PM matches three in the afternoon", "Pickup is at 3 PM.", "Pickup is at three in the afternoon.")
clean("three thirty matches 3:30", "They meet at three thirty.", "The meeting is at 3:30.")
clean("twelve fifty matches $1,250", "The rent is twelve fifty.", "Rent is $1,250 a month.")
flags("a spelled time that isn't said", "They meet at four fifteen.", "The meeting is at 3:30.", ["four fifteen"])
clean("15:30 matches 3:30 pm", "The bus leaves at 15:30.", "The bus leaves at 3:30 pm sharp.")
clean("quarter to four", "Doors open at 3:45.", "Doors open at quarter to four.")
clean("5,000 matches five thousand", "They ordered 5,000 flyers.", budgetCall)
clean("$5k matches five thousand dollars", "Sponsorship is $5k.", "The sponsorship is five thousand dollars.")
clean("12 matches a dozen", "They need 12 boxes.", budgetCall)
clean("twelve matches 12", "There were twelve people there.", "We had 12 people show up.")
clean("a phone number spelled out digit by digit", "Call her at 555-0142.", budgetCall)
clean("small counts aren't checked", "They discussed three options and 2 venues, and one risk.", "We talked about the venue and a backup plan.")
clean("October 27 matches the twenty-seventh of October", "The launch is October 27.", "The launch is on the twenty-seventh of October.")
clean("27th matches twenty-seventh", "The launch is on the 27th.", "The launch is on the twenty-seventh.")
clean("2026 matches twenty twenty-six", "The plan runs through 2026.", "The plan runs through twenty twenty-six.")
clean("1990 matches nineteen ninety", "The house was built in 1990.", "The house was built in nineteen ninety.")
clean("$1,250 matches twelve fifty", "The rent is $1,250.", "Rent is twelve fifty a month.")
clean("two hundred and fifty", "The invoice is $250.", "The invoice is two hundred and fifty dollars.")
clean("an approximate number within 10%", "About 30% of people agreed.", "Roughly 29 percent of people agreed.")
clean("50% matches half", "Half of the budget is spent; that's 50%.", "Half of the budget is spent already.")
check("clean: 90 minutes from the recording's length", findings("The meeting ran 90 minutes.", "We should wrap up.", duration: 5_400).isEmpty)
clean("decimals", "The ratio is 2.5 to 1.", "The ratio is 2.5 to 1 right now.")
clean("versions and model numbers in a name aren't counts", "They use the X200 printer on Route 30.", "We use the X200 printer out on Route 30.")
flags("45% isn't in the source", "In the end 45% agreed.", budgetCall, ["45%"])
clean("about half is about 50%", "About 50% agreed.", "Almost half of them agreed.")
flags("30% without 'about' isn't 29%", "30% of people agreed.", "Roughly 29 percent of people agreed.", ["30%"])
flags("a time that isn't said", "They meet at 4:15 PM.", budgetCall, ["4:15 PM"])
flags("a spelled-out number that isn't said", "Fifteen volunteers signed up.", budgetCall, ["Fifteen"])
flags("money that isn't said", "The booth costs $1,800.", budgetCall, ["$1,800"])
flags("a percentage, however small", "Only 5% declined.", budgetCall, ["5%"])
flags("a date number after a month", "The launch is October 28.", "The launch is on the twenty-seventh of October.", ["28"])
flags("a year", "The plan runs through 2027.", "The plan runs through twenty twenty-six.", ["2027"])

// Contradictory evidence: both figures said are supported; a third one isn't.
let contradictory = "The budget is 1,200. No wait, actually it's 1,500, I was looking at last year's sheet. Sam thinks it's lower."
clean("contradictory notes: the first figure", "The budget is $1,200.", contradictory)
clean("contradictory notes: the correction", "The budget is $1,500.", contradictory)
flags("contradictory notes: a figure neither said", "The budget is $1,800.", contradictory, ["$1,800"])

// MARK: Names

let teamCall = "Dana: Thanks for joining. Priya's draft is in the shared folder. Marcus will take the Brookhaven site visit. Dr. Okafor wants the Johnson file by the end of the month. I talked to Kathrine about the print run."
clean("a possessive in the output", "Dana's team reviewed the draft.", teamCall)
clean("a possessive in the source", "Priya wrote the draft.", teamCall)
clean("plural family name", "The Johnsons' file is due.", teamCall)
clean("one letter off is the same name", "Katherine is handling the print run.", teamCall)
clean("names after Dr.", "Marcus and Dr. Okafor are visiting Brookhaven.", teamCall)
clean("sentence-initial words aren't names", "Schedule the site visit. Overall, the call went well. Follow up with Marcus. Review the draft.", teamCall)
clean("months and weekdays aren't names", "Marcus visits the site at the end of the month.", teamCall)
clean("the app's own words", "Apple Intelligence wrote this. Next steps: Marcus visits Brookhaven.", teamCall)
clean("headings and labels", "## Action Items\n**Next Steps:**\n- [ ] Marcus visits Brookhaven\nKey Decisions: Priya owns the draft.", teamCall)
clean("all-caps words aren't names", "Send it ASAP; NASA style.", "Send it as soon as possible, NASA style.")
clean("speaker names passed in", "Jordan agreed with Dana.", "Yeah I agree with that.", known: ["Jordan", "Dana"])
clean("a name in the title passed in", "The Fairview bid is due.", "The bid is due soon.", known: ["Fairview bid"])
clean("accents", "Zoë approved it.", "zoe approved it yesterday")
clean("a name the source writes in lowercase", "Ask Marcus about it.", "ask marcus about it")
flags("a place that isn't in the source", "Marcus will visit Harrisburg next.", teamCall, ["Harrisburg"])
flags("a surname that doesn't match", "Dana Whitman owns the draft.", "Dana Whitfield owns the draft, Dana said.", ["Dana Whitman"])
flags("a possessive name that isn't in the source", "Ramona's notes are attached.", teamCall, ["Ramona"])
flags("a name mid-sentence", "The draft goes to Bellweather for review.", teamCall, ["Bellweather"])

// Title Case, tables, and another language.
clean("Title Case common words aren't names", "The Marketing Team will share the Budget Review with the Host and Guest.", "marketing wants to share the budget numbers")
clean("a table's header and cells", "| Owner | Task | Due |\n| Marcus | Site Visit | Friday |", "Marcus does the site visit on Friday.")
clean("100% is a way of speaking", "She is 100% committed to the launch.", "I'm totally committed to the launch.")
let spanish = "Bueno, entonces la reunión es el viernes a las tres y media. El presupuesto es de mil doscientos dólares, y Marisol trae las sillas. Necesitamos doce mesas para la feria del barrio, y también un toldo grande por si llueve."
clean("numbers aren't checked against another language's words", "The meeting is Friday at 3:30. The budget is $1,200 and they need 12 tables.", spanish)
flags("names still are", "Marisol and Esteban bring the chairs.", spanish, ["Esteban"])

// MARK: Quotes

let quoteSource = "So um I think we should, uh, we should move the launch to spring because the printer is late. And honestly the booth looks great."
clean("a quote with the fillers taken out", "Dana said, \u{201C}we should move the launch to spring because the printer is late.\u{201D}", quoteSource)
clean("a quote that drops a word", "She said \"we should move the launch to spring, the printer is late\".", quoteSource)
clean("a one-word quote the source has", "She called the booth \"great\".", quoteSource)
flags("an invented quote", "She said \u{201C}we will cancel the launch entirely.\u{201D}", quoteSource, ["we will cancel the launch entirely"])
flags("a long invented quote is shortened", "She said \"the whole team agreed that the new logo should be bright orange and huge\".", quoteSource,
      ["the whole team agreed that the new\u{2026}"])
flags("a scare quote the source doesn't have", "The launch needs a \"pivot\".", quoteSource, ["pivot"])

// MARK: Dates

clean("a weekday the source says", "They meet Friday.", budgetCall)
clean("May the verb isn't a month", "May is when it ships? They may move it.", "they might move it")
flags("a weekday the source doesn't say", "They meet Tuesday.", budgetCall, ["Tuesday"])
flags("a month the source doesn't say", "The launch is in March.", quoteSource, ["March"])
flags("tomorrow when the source never says it", "Dana sends it tomorrow.", budgetCall, ["tomorrow"])

// MARK: Summaries and template results with the real types

func recording(_ title: String, _ lines: [(Double, String, String?)], speakers: [(String, String)] = [], duration: Double? = nil) -> Transcript {
    var t = Transcript(title: title, source: .voiceMemo, sourceLabel: "Voice memo", duration: duration ?? ((lines.last?.0 ?? 0) + 30), audioFileName: nil, model: "Test")
    t.segments = lines.map { Segment(start: $0.0, end: $0.0 + 10, text: $0.1, speaker: $0.2) }
    t.original = t.segments
    t.speakers = speakers.map { Speaker(id: $0.0, name: $0.1) }
    return t
}

var call = recording("Booth planning", [
    (0, "Thanks for joining. The budget is twelve hundred dollars for the booth.", "S1"),
    (12, "Great. I can do the Millbrook pickup at three thirty on Friday.", "S2"),
    (25, "About thirty-two percent of the volunteers said yes.", "S1"),
], speakers: [("S1", "Rowan"), ("S2", "Imani")])
call.summary = TranscriptSummary(overview: "Rowan and Imani planned the booth. The budget is $1,200, and Imani picks up in Millbrook at 3:30 on Friday.",
                                 keyPoints: ["About 32% of volunteers said yes."])
call.summaryByModel = true
check("summary: a correct summary has no note", GroundingChecks.summaryNote(call) == nil, "\(GroundingChecks.summary(call))")
var wrong = call
wrong.summary = TranscriptSummary(overview: "Rowan and Imani planned the booth in Harrisburg. The budget is $1,200.", keyPoints: ["About 45% of volunteers said yes."])
check("summary: a wrong summary names what to check", GroundingChecks.summaryNote(wrong) == "Check this: 45% and \u{201C}Harrisburg\u{201D} aren\u{2019}t in the transcript.",
      GroundingChecks.summaryNote(wrong) ?? "nil")
var edited = wrong
edited.summaryByModel = false
check("summary: a summary the person edited isn't checked", GroundingChecks.summary(edited).isEmpty)
check("summary: About me supports names", { var t = call; t.summary = TranscriptSummary(overview: "Rowan asked Tobias, who runs the booth, for $1,200."); return GroundingChecks.summary(t, aboutMe: "I'm Tobias and I run a print shop.").isEmpty }())

let meetingNotes = TemplateResult(templateId: UUID(), name: "Meeting notes",
                                  text: "## Decisions\n- The budget is $1,200.\n## Action items\n- [ ] Imani picks up in Millbrook on Friday [00:12]\n- [ ] Rowan emails the volunteers (high priority) [00:25]")
check("result: flags a priority the source doesn't give", Set(GroundingChecks.result(meetingNotes, in: call).map(\.text)) == ["priority"],
      "\(GroundingChecks.result(meetingNotes, in: call))")
var editedResult = meetingNotes
editedResult.edited = true
check("result: an edited result isn't checked", GroundingChecks.result(editedResult, in: call).isEmpty)
let pastEnd = TemplateResult(templateId: UUID(), name: "Meeting notes", text: "## Action items\n- [ ] Imani picks up on Friday [45:10]")
check("result: a time past the end of the recording", GroundingChecks.resultNote(pastEnd, in: call) == "Check this: 45:10 is past the end of the recording.",
      GroundingChecks.resultNote(pastEnd, in: call) ?? "nil")
let timecodes = TemplateResult(templateId: UUID(), name: "Highlights", text: "- Budget set [00:00]\n- Pickup planned [00:12]\n- Volunteers [0:25]")
check("result: timecodes inside the recording aren't numbers to check", GroundingChecks.result(timecodes, in: call).isEmpty, "\(GroundingChecks.result(timecodes, in: call))")

// MARK: Plan my day

var dump = recording("Brain dump", [
    (0, "Okay, tomorrow I need to call Rob about the props.", nil),
    (9, "I should also water the plants at some point.", nil),
    (20, "And by Thursday I have to send the invoice to Lena, it's three hundred forty dollars.", nil),
    (34, "Oh and the printer is out of ink again.", nil),
    (41, "Pick up the dry cleaning.", nil),
])
let goodPlan = TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: """
    ## Tomorrow
    - [ ] Call Rob about the props [00:00]
    ## This week
    - [ ] Send the $340 invoice to Lena (Thursday) [00:20]
    ## Someday
    - [ ] Water the plants [00:09]
    - [ ] Pick up the dry cleaning [00:41]
    """)
check("plan: a plan that keeps to what was said has no note", GroundingChecks.result(goodPlan, in: dump).isEmpty, "\(GroundingChecks.result(goodPlan, in: dump))")
let guessedDays = TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: """
    ## Top three
    - [ ] Call Rob about the props [00:00]
    - [ ] Send the invoice to Lena [00:20]
    - [ ] Water the plants [00:09]
    ## Tomorrow
    - [ ] Pick up the dry cleaning [00:41]
    - [ ] Urgent: water the plants again [00:09]
    """)
let guessed = GroundingChecks.result(guessedDays, in: dump)
check("plan: a task under Tomorrow with no day said", guessed.contains { $0.kind == .dayNotSaid && $0.text == "Pick up the dry cleaning" }, "\(guessed)")
check("plan: a Top three nobody named", guessed.contains { $0.kind == .topNotNamed }, "\(guessed)")
check("plan: a priority nobody gave", guessed.contains { $0.kind == .priority && $0.text == "urgent" }, "\(guessed)")
check("plan: the note says each", GroundingChecks.resultNote(guessedDays, in: dump)
      == "Check this: \u{201C}urgent\u{201D} isn\u{2019}t in the transcript. You didn\u{2019}t say a day for \u{201C}Pick up the dry cleaning\u{201D}. You didn\u{2019}t name a top three.",
      GroundingChecks.resultNote(guessedDays, in: dump) ?? "nil")
let inferredTop = TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: """
    ## Top three
    You didn't name three, so these are today's first three.
    - [ ] Call Rob about the props [00:00]
    """)
check("plan: a Top three the model says it chose isn't flagged", !GroundingChecks.result(inferredTop, in: dump).contains { $0.kind == .topNotNamed })
let namedTop = recording("Brain dump", [(0, "The most important thing is to call Rob. Then pick up the dry cleaning.", nil)])
let namedTopPlan = TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: "## Top three\n- [ ] Call Rob [00:00]\n## Someday\n- [ ] Pick up the dry cleaning [00:00]")
check("plan: a Top three the speaker named", GroundingChecks.result(namedTopPlan, in: namedTop).isEmpty, "\(GroundingChecks.result(namedTopPlan, in: namedTop))")
let copiedExample = TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: "## Someday\n- [ ] Email Dana about the $250 invoice [00:20]\n- [ ] Pick up the dry cleaning [00:41]")
check("plan: the instruction's example copied in is caught", Set(GroundingChecks.result(copiedExample, in: dump).map(\.text)) == ["$250", "Dana"],
      "\(GroundingChecks.result(copiedExample, in: dump))")
let wrongWeekday = TemplateResult(templateId: TemplateLibrary.planMyDayID, name: "Plan my day", text: "## This week\n- [ ] Send the invoice to Lena (Friday) [00:20]")
check("plan: a weekday the speaker didn't say", GroundingChecks.result(wrongWeekday, in: dump).map(\.text) == ["Friday"], "\(GroundingChecks.result(wrongWeekday, in: dump))")

// Over a day's thoughts and the Mac's note.
let thoughts = ["Need to book the vet for Biscuit.", "Tomorrow morning call the bank about the card.", "Idea: a podcast about old maps."]
let dayPlan = "## Tomorrow\n- [ ] Call the bank about the card [01:00]\n## Someday\n- [ ] Book the vet for Biscuit [00:00]\n## Ideas\n- A podcast about old maps [02:00]"
check("day plan: thoughts that support the plan", GroundingChecks.dayPlan(dayPlan, lines: thoughts).isEmpty, "\(GroundingChecks.dayPlan(dayPlan, lines: thoughts))")
let dayPlanWrong = "## Tomorrow\n- [ ] Book the vet for Biscuit at 9 AM [00:00]\n## Someday\n- [ ] Call the bank [01:00]"
check("day plan: the note says these thoughts", GroundingChecks.dayPlanNote(dayPlanWrong, lines: thoughts, fromNote: false)
      == "Check this: 9 AM isn\u{2019}t in these thoughts. You didn\u{2019}t say a day for \u{201C}Book the vet for Biscuit at 9 AM\u{201D}.",
      GroundingChecks.dayPlanNote(dayPlanWrong, lines: thoughts, fromNote: false) ?? "nil")
check("day plan: from the note", GroundingChecks.dayPlanNote("## Someday\n- [ ] Call Theo", lines: ["Call the bank."], fromNote: true)
      == "Check this: \u{201C}Theo\u{201D} isn\u{2019}t in your note.")

// MARK: Ask answers

let callId = UUID(), reviewId = UUID()
let created = Date(timeIntervalSince1970: 1_791_913_600) // Tuesday, October 13, 2026
func source(_ n: Int, _ id: UUID, _ start: Double, _ title: String, _ text: String) -> AskSource {
    AskSource(number: n, transcriptId: id, segmentId: UUID(), start: start, title: title, createdAt: created, text: text)
}
let passages = [
    source(1, callId, 40, "Client call", "Sam: The new deadline is the fourteenth, and the deposit is eight hundred dollars."),
    source(2, reviewId, 300, "Design review", "Alex: The logo needs more contrast. Use the darker teal for the header."),
]
let goodAnswer = AskAnswer(blocks: [.paragraph([AskSentence(text: "Sam moved the deadline to the 14th and asked for an $800 deposit.", cites: [1]),
                                                 AskSentence(text: "Alex wants more contrast in the logo, with darker teal in the header.", cites: [2])])],
                           citations: passages)
let durations: [UUID: Double] = [callId: 1_800, reviewId: 2_400]
check("ask: a grounded answer has no note", GroundingChecks.answerNote(goodAnswer, question: "What changed?", duration: { durations[$0] }) == nil,
      "\(GroundingChecks.answer(goodAnswer, question: "What changed?", duration: { durations[$0] }))")
let swapped = AskAnswer(blocks: [.paragraph([AskSentence(text: "Alex wants more contrast in the logo, with darker teal in the header.", cites: [1])])], citations: passages)
check("ask: a sentence citing a passage that doesn't say it", GroundingChecks.answerNote(swapped, question: "What about the logo?", duration: { durations[$0] })
      == "Check this: [1] doesn\u{2019}t mention what its sentence says.", GroundingChecks.answerNote(swapped, question: "What about the logo?", duration: { durations[$0] }) ?? "nil")
let invented = AskAnswer(blocks: [.paragraph([AskSentence(text: "Sam asked for a $900 deposit by Thursday.", cites: [1])])], citations: passages)
check("ask: numbers and days the passages don't state", Set(GroundingChecks.answer(invented, question: "Deposit?").map(\.text)) == ["$900", "Thursday"],
      "\(GroundingChecks.answer(invented, question: "Deposit?"))")
let fromQuestion = AskAnswer(blocks: [.paragraph([AskSentence(text: "For Jordan's question: the deposit is $800.", cites: [1])])], citations: passages)
check("ask: a name from the question is fine", GroundingChecks.answer(fromQuestion, question: "What did Jordan need to know about the deposit?").isEmpty,
      "\(GroundingChecks.answer(fromQuestion, question: "What did Jordan need to know about the deposit?"))")
let dayFromHeader = AskAnswer(blocks: [.paragraph([AskSentence(text: "On Tuesday's client call, Sam set the deadline for the 14th.", cites: [1])])], citations: passages)
check("ask: the passage's date supports the weekday", GroundingChecks.answer(dayFromHeader, question: "When is it due?").isEmpty,
      "\(GroundingChecks.answer(dayFromHeader, question: "When is it due?"))")
var late = passages
late[1].start = 3_000
let lateAnswer = AskAnswer(blocks: [.paragraph([AskSentence(text: "Alex wants more contrast in the logo.", cites: [2])])], citations: late)
check("ask: a citation past the end of its recording", GroundingChecks.answerNote(lateAnswer, question: "Logo?", duration: { durations[$0] })
      == "Check this: [2] points past the end of its recording.", GroundingChecks.answerNote(lateAnswer, question: "Logo?", duration: { durations[$0] }) ?? "nil")
check("ask: an unknown length isn't a finding", GroundingChecks.answer(lateAnswer, question: "Logo?").isEmpty)
check("ask: short sentences aren't judged on key words", Grounding.claimSupported("Yes, that's right.", by: ["Nothing alike here at all."]))
check("ask: a paraphrase that shares a word passes", Grounding.claimSupported("The deposit changed to eight hundred.", by: [passages[0].text]))

// MARK: Long transcripts

let everyday = [
    "So I was thinking about how we set up the room before people arrive.", "We could move the tables closer to the windows.",
    "The light in the afternoon is really nice in there.", "Somebody should check whether the projector still works.",
    "I keep forgetting to bring the extension cord.", "Let's keep the agenda short this time so nobody gets restless.",
    "The coffee from the place downstairs is better than what we had last time.", "We should ask people what they want to see next.",
    "I'd rather not change the schedule again unless we have to.", "Honestly the signage could be bigger and easier to read.",
    "Maybe we put the sign-up sheet by the door.", "It would help to have someone greeting folks as they come in.",
]
var longLines: [(Double, String, String?)] = []
var at = 0.0
for i in 0..<330 {
    var line = everyday[i % everyday.count]
    if i == 40 { line = "Okay, the room fee is four hundred fifty dollars for the whole evening." }
    if i == 155 { line = "Talia from the Ridgeview library said they can lend us sixty chairs." }
    if i == 290 { line = "Let's lock the date: November twelfth, doors at six thirty." }
    longLines.append((at, line, i % 2 == 0 ? "S1" : "S2"))
    at += 8
}
let longTalk = recording("Community night planning", longLines, speakers: [("S1", "Rowan"), ("S2", "Imani")])
let words = longTalk.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
check("long: the transcript has thousands of words", words > 3_000, "\(words)")
var longSummary = longTalk
longSummary.summaryByModel = true
longSummary.summary = TranscriptSummary(overview: "Rowan and Imani planned community night at the Ridgeview library. The room fee is $450, Talia is lending 60 chairs, and doors open at 6:30 on November 12.",
                                        keyPoints: ["Move the tables closer to the windows.", "Make the signage bigger.", "Put the sign-up sheet by the door."])
let t0 = Date()
let longFound = GroundingChecks.summary(longSummary)
let elapsed = Date().timeIntervalSince(t0)
check("long: a correct summary of a long transcript has no note", longFound.isEmpty, "\(longFound)")
check("long: checking takes well under a second", elapsed < 1.0, "\(elapsed)s")
var longWrong = longSummary
longWrong.summary = TranscriptSummary(overview: "Rowan and Imani planned community night at the Oakdale library. The room fee is $540, Talia is lending 60 chairs, and doors open at 7:30 on November 12.")
check("long: a wrong summary of a long transcript names each error", Set(GroundingChecks.summary(longWrong).map(\.text)) == ["$540", "7:30", "Oakdale"],
      "\(GroundingChecks.summary(longWrong))")
check("long: missing evidence (a fact from nowhere)", GroundingChecks.summary({ var t = longSummary; t.summary = TranscriptSummary(overview: "Imani said the city grant of $2,000 covers it."); return t }()).map(\.text) == ["$2,000"])
let t1 = Date()
_ = GroundingChecks.summary(longSummary)
check("long: a second look is cached", Date().timeIntervalSince(t1) < 0.01)

// A long, real-sounding summary full of ordinary capitalized starts and counts stays quiet.
var quiet = longSummary
quiet.summary = TranscriptSummary(overview: "The two hosts talked through setup for community night. They want a shorter agenda, better coffee, and bigger signs. Overall the plan is in good shape.",
                                  keyPoints: ["Check that the projector works.", "Bring an extension cord.", "Ask people what they want next.", "Keep the schedule as it is."])
check("long: false-positive guard on an ordinary summary", GroundingChecks.summary(quiet).isEmpty, "\(GroundingChecks.summary(quiet))")

// MARK: The note

let sample = [GroundingFinding(kind: .number, text: "32%"), GroundingFinding(kind: .name, text: "Harrisburg")]
check("note: the example", GroundingNote.text(sample) == "Check this: 32% and \u{201C}Harrisburg\u{201D} aren\u{2019}t in the transcript.")
check("note: one term", GroundingNote.text([GroundingFinding(kind: .number, text: "$900")]) == "Check this: $900 isn\u{2019}t in the transcript.")
check("note: more than three terms", GroundingNote.text((1...5).map { GroundingFinding(kind: .number, text: "\($0)0%") })
      == "Check this: 10%, 20%, 30%, and 2 more aren\u{2019}t in the transcript.")
check("note: nothing found, no note", GroundingNote.text([]) == nil)
check("note: a plan sentence first starts lowercase", GroundingNote.text([GroundingFinding(kind: .topNotNamed, text: "Top three")]) == "Check this: you didn\u{2019}t name a top three.")
check("note: two citations", GroundingNote.text([GroundingFinding(kind: .citation, text: "a", number: 4), GroundingFinding(kind: .citation, text: "b", number: 2)])
      == "Check this: [2] and [4] don\u{2019}t mention what their sentences say.")
let allNotes = [GroundingNote.text(sample), GroundingNote.text(guessed), GroundingNote.text([GroundingFinding(kind: .timeRange, text: "[3]", number: 3)]),
                GroundingChecks.resultNote(pastEnd, in: call)].compactMap { $0 }
check("note: no em dashes or exclamation points", allNotes.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("!") }, "\(allNotes)")

// MARK: Wiring (reads the sources from the mac/ folder given as the first argument)

if CommandLine.arguments.count > 1 {
    let root = CommandLine.arguments[1]
    func read(_ p: String) -> String { (try? String(contentsOfFile: root + "/" + p, encoding: .utf8)) ?? "" }
    check("wiring: the Summary tab shows the summary's note", read("Verbatim/Views/SummaryBlock.swift").contains("GroundingChecks.summaryNote("))
    check("wiring: the Mac's template results show the note", read("Verbatim/Views/TemplateResultsSection.swift").contains("GroundingChecks.resultNote("))
    check("wiring: the iPhone's template results show the note", read("VerbatimPhone/TemplatesScreens.swift").contains("GroundingChecks.resultNote("))
    check("wiring: the Mac's Ask answers show the note", read("Verbatim/Views/AskViews.swift").contains("GroundingChecks.answerNote("))
    check("wiring: the iPhone's Ask answers show the note", read("VerbatimPhone/AskScreens.swift").contains("GroundingChecks.answerNote("))
    check("wiring: the Mac's day plan shows the note", read("Verbatim/Views/DayNote.swift").contains("GroundingChecks.dayPlanNote("))
    check("wiring: the iPhone's day plan shows the note", read("VerbatimPhone/PhonePlanViews.swift").contains("GroundingChecks.dayPlanNote("))
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
