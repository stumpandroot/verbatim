import Foundation

/// Self-tests for spoken corrections (`SpokenCorrections`), through the Clean rules (`CleanupPrepass.clean`) as
/// dictation runs them. Foundation only. The Mac self-test (`UITest`), the iPhone self-test (`PhoneUITest`), and
/// `mac/tools/test-formatter.sh` run them.
enum SpokenCorrectionsChecks {
    struct Result {
        let name: String
        let ok: Bool
        let detail: String
    }

    /// (input, expected after `CleanupPrepass.clean` with corrections on)
    static let cases: [(String, String)] = [
        // Rule 1: a value replaces the last value of its kind
        ("Let's meet at 2, actually 3.", "Let's meet at 3."),
        ("meet at 2 actually 3", "Meet at 3"),
        ("We're on for Tuesday, no wait, Wednesday.", "We're on for Wednesday."),
        ("The budget is $500, I mean $600.", "The budget is $600."),
        ("It costs 50, I mean, 60 dollars.", "It costs 60 dollars."),
        ("Let's meet Tuesday. I mean, Wednesday.", "Let's meet Wednesday."),
        ("The call is at nine. Actually, wait, eleven thirty. Please keep the same link.", "The call is at eleven thirty. Please keep the same link."),
        ("I think we should meet on Thursday actually make that Friday morning", "I think we should meet on Friday morning"),
        ("Call me at 2 pm, actually 3.", "Call me at 3 pm."),
        ("The call is at 2 with Sarah, actually 3, so bring the notes.", "The call is at 3 with Sarah, so bring the notes."),
        ("Raise it to 20%, sorry, 25%.", "Raise it to 25%."),
        ("I need 2 tickets, make that 3.", "I need 3 tickets."),
        ("The launch is in March, correction, April.", "The launch is in April."),
        ("The meeting is Monday at 3, actually Tuesday.", "The meeting is Tuesday at 3."),
        ("The total is five hundred, I mean six hundred dollars.", "The total is six hundred dollars."),
        ("Book it for May 4, actually May 5.", "Book it for May 5."),
        ("We have 3 actually 4 people.", "We have 4 people."),
        // Rule 2: an anchor word
        ("Meet me at the office at 10, no wait, at the cafe at 11.", "Meet me at the cafe at 11."),
        ("Send it to Sarah, no wait, send it to Jake.", "Send it to Jake."),
        ("It's in the blue folder, I mean the red folder.", "It's in the red folder."),
        // Rule 3: a name
        ("Tell Sarah, I mean Jake, about the shoot.", "Tell Jake, about the shoot."),
        ("Ask Sarah about it, sorry, Jake.", "Ask Jake about it."),
        // Rule 4: strong cues replace the clause
        ("We'll take the train, no wait, we're driving.", "We're driving."),
        ("I'll bring the chairs, or rather, the tables.", "I'll bring the tables."),
        ("We should fly, no wait, take the train.", "Take the train."),
        // Weak cues with nothing to match stay
        ("We could try the park, actually, it might rain.", "We could try the park, actually, it might rain."),
        // Delete cues
        ("We should go. Scratch that. Let's stay home.", "Let's stay home."),
        ("Send it to Sarah, call Jake, scratch that, and email the client.", "Send it to Sarah, and email the client."),
        ("Send it to Sarah, call Jake, scratch that.", "Send it to Sarah."),
        ("The report is done. Forget that.", ""),
        ("Pick up milk. Oh, never mind.", ""),
        ("Pick up milk. Nevermind. Pick up bread.", "Pick up bread."),
        ("Book the room. Delete that. Book the hall.", "Book the hall."),
        ("Meet at noon. Strike that.", ""),
        ("Bring the cake. Skip that. Bring the plates.", "Bring the plates."),
        ("Order the prints, cancel that, order the frames.", "Order the frames."),
        ("Buy stamps. Undo that.", ""),
        ("Email Dana. Remove that. Call Dana.", "Call Dana."),
        ("Thanks for the notes. We should talk Friday. Scratch that. Scratch that. See you soon.", "See you soon."),
        // Explicit commands
        ("The shoot moved. Bring snacks. Delete the last sentence.", "The shoot moved."),
        ("One. Two. Three. Delete the last two sentences.", "One."),
        ("We need the red blue, delete the last word.", "We need the red."),
        ("Ship it on Friday morning, delete the last 2 words.", "Ship it on."),
        ("First paragraph here.\n\nSecond paragraph here. Delete the last paragraph.", "First paragraph here."),
        ("Bring snacks erase that.", ""),
        // Start over
        ("This is wrong. Let me start over. The shoot moved to Friday.", "The shoot moved to Friday."),
        ("Okay, start over. Hi Sam, the cut is ready.", "Hi Sam, the cut is ready."),
        ("Something something. Let's start over.", ""),
        ("Draft one. Scratch all that. Draft two.", "Draft two."),
        ("Words here. Delete all that. New words.", "New words."),
        ("Words here. Delete everything. New words.", "New words."),
        ("Words here. Erase everything. New words.", "New words."),
        ("Words here. Clear that. New words.", "New words."),
        ("Words here. Start again. New words.", "New words."),
        // Keep-cases: these stay as spoken
        ("I actually like it.", "I actually like it."),
        ("Actually, I think we should go.", "Actually, I think we should go."),
        ("I mean it.", "I mean it."),
        ("What I mean is we need more time.", "What I mean is we need more time."),
        ("Make that call tomorrow.", "Make that call tomorrow."),
        ("We should make that call tomorrow.", "We should make that call tomorrow."),
        ("Never mind the weather.", "Never mind the weather."),
        ("Sorry I'm late.", "Sorry I'm late."),
        ("I'm sorry for the delay.", "I'm sorry for the delay."),
        ("Skip that step and go to the next one.", "Skip that step and go to the next one."),
        ("Forget that I said anything.", "Forget that I said anything."),
        ("We need to start over on the logo.", "We need to start over on the logo."),
        ("We need to start over.", "We need to start over."),
        ("Delete the last sentence of the contract.", "Delete the last sentence of the contract."),
        ("Please don't delete that.", "Please don't delete that."),
        ("I can't forget that.", "I can't forget that."),
        ("There was no wait at the restaurant.", "There was no wait at the restaurant."),
        ("Are you coming? No, sorry, I can't make it.", "Are you coming? No, sorry, I can't make it."),
        ("I said no, wait until Friday.", "I said no, wait until Friday."),
        ("I like it, I mean it.", "I like it, I mean it."),
        ("It's actually 5.", "It's actually 5."),
        ("I'll be there at 5. Actually, 6 people are coming.", "I'll be there at 5. Actually, 6 people are coming."),
        ("The correction is due Friday.", "The correction is due Friday."),
    ]

    static func run() -> [Result] {
        var out: [Result] = []
        for (input, want) in cases {
            let got = CleanupPrepass.clean(input, corrections: true)
            out.append(Result(name: "spoken correction: \(input)", ok: got == want, detail: "expected “\(want)”, got “\(got)”"))
        }
        // Off: the words stay as spoken.
        let off = CleanupPrepass.clean("Let's meet at 2, actually 3.", corrections: false)
        out.append(Result(name: "spoken corrections off keep both values", ok: off == "Let's meet at 2, actually 3.", detail: off))
        // Structured output and live spans.
        let r = SpokenCorrections.apply("Let's meet at 2, actually 3.")
        out.append(Result(name: "spoken corrections report a replacement",
                          ok: r.corrections.count == 1 && r.corrections[0].kind == .replace && r.corrections[0].removed == "2" && r.corrections[0].replacement == "3",
                          detail: "\(r.corrections)"))
        let struck = r.spans.filter { $0.style == .removed }.map(\.text).joined()
        out.append(Result(name: "live spans strike the old value and cue", ok: struck.contains("2") && struck.contains("actually") && !struck.contains("3"), detail: "\(r.spans)"))
        let wipe = SpokenCorrections.apply("One. Two. Let me start over. Three.")
        out.append(Result(name: "start over is a big correction", ok: SpokenCorrections.isBig(wipe.corrections) && wipe.text == "Three.", detail: "\(wipe)"))
        let chained = SpokenCorrections.apply("Call the venue. Book the crew. Scratch that. Scratch that. Send the deck.")
        out.append(Result(name: "two chained deletions are a big correction", ok: SpokenCorrections.isBig(chained.corrections) && chained.text == "Send the deck.", detail: "\(chained)"))
        let small = SpokenCorrections.apply("Meet at 2, actually 3.")
        out.append(Result(name: "a replacement is a small correction", ok: !SpokenCorrections.isBig(small.corrections), detail: "\(small.corrections)"))
        out.append(Result(name: "notice summary names the change", ok: SpokenCorrections.summary(small.corrections) == "Changed “2” to “3”",
                          detail: SpokenCorrections.summary(small.corrections)))
        // The model's corrected output passes the meaning guard for the new cues.
        let guarded = MeaningCheck.problem(raw: "Let's meet at 2, no sorry, at 3 on the patio near the fountain.", output: "Let's meet at 3 on the patio near the fountain.", limits: .clean)
        out.append(Result(name: "meaning check allows a value dropped after “no sorry”", ok: guarded == nil, detail: guarded ?? ""))
        let wiped = MeaningCheck.problem(raw: "Book the room for 20 people on Friday. Delete the last sentence. Book the hall.", output: "Book the hall.", limits: .clean)
        out.append(Result(name: "meaning check allows “delete the last sentence”", ok: wiped == nil, detail: wiped ?? ""))
        let none = SpokenCorrections.apply("I actually like it.")
        out.append(Result(name: "no correction leaves no spans struck", ok: !none.changed && none.text == "I actually like it.", detail: "\(none)"))
        out += liveTailChecks()
        return out
    }

    // MARK: Live words on a tail window

    /// Plain sentences for long dictations: no cue words.
    static let filler = [
        "The shoot starts early on the north lot.", "Bring the long lens and two spare batteries.",
        "Dr. Lee will meet us at 9 a.m. by the gate.", "We need the van back by six tonight!",
        "Is the client still happy with the cut?", "The grade looks warm in the second scene.",
        "Pack the sliders and the small light kit.", "Sam has the release forms for the talent.",
        "Lunch is at the diner across the road…", "The drone needs a fresh permit this week.",
        "Call the venue about the parking passes.", "The score lands on Thursday afternoon.",
    ]

    /// Sentences with spoken corrections, dropped into the filler at every position.
    static let cueSentences = [
        "Meet at 2, actually 3.", "Scratch that.", "Book the room, scratch that, book the hall.",
        "Let me start over.", "Delete the last two sentences.", "Delete the last 3 words.", "Actually, make that Friday.",
        "Tell Sarah, I mean Jake.", "No wait, the cafe at 11.", "Oh, never mind.", "Delete everything.",
        "Send it to Sarah, no wait, send it to Jake.",
    ]

    /// `liveSpans` runs the rules on the last few sentences only; its spans must match a run on the whole text for
    /// every visible character, including start overs and corrections that reach back past the window.
    static func liveTailChecks() -> [Result] {
        var out: [Result] = []
        func same(_ text: String, _ limit: Int) -> (Bool, String) {
            let tail = SpokenCorrections.liveSpans(text, limit: limit)
            let full = SpokenCorrections.lastCharacters(SpokenCorrections.apply(text).spans, limit: limit)
            return (tail == full, "limit \(limit), “\(text.suffix(200))”: window \(tail), whole text \(full)")
        }
        let long = filler.joined(separator: " ")
        let named: [(String, String)] = [
            ("a value fix at the end", long + " Meet at 2, actually 3."),
            ("a deletion at the end", long + " Book the room. Scratch that. Book the hall."),
            ("a start over at the end, earlier words struck", long + " Let me start over. New words."),
            ("a start over after a fix in the window", long + " Meet at 2, actually 3. Let me start over. New words."),
            ("a start over after a deletion in the window", long + " Book it. Scratch that. Delete everything. Fresh start here."),
            ("a start over long before the window", "Draft one. Start over. " + long + " Meet at 2, actually 3."),
            ("chained deletions past the window", long + String(repeating: " Scratch that.", count: 8) + " Done."),
            ("delete the last five sentences", long + " Delete the last five sentences."),
            ("a fix that starts a sentence", long + " Meet Tuesday. I mean, Wednesday."),
            ("paragraphs", long + "\n\nFirst paragraph here. " + long + "\n\nSecond one. Delete the last paragraph."),
            ("no punctuation", long.filter { $0 != "." } + " meet at 2 actually 3"),
            ("no correction", long + " " + long),
        ]
        for (name, text) in named {
            for limit in [60, 160] {
                let (ok, detail) = same(text, limit)
                out.append(Result(name: "live tail matches the whole text: \(name) (\(limit))", ok: ok, detail: detail))
            }
        }
        // Every cue sentence at every position, alone and followed by a start over.
        var failures: [String] = []
        var count = 0
        for cue in cueSentences {
            for k in 0...filler.count {
                var parts = filler
                parts.insert(cue, at: k)
                for text in [parts.joined(separator: " "), parts.joined(separator: " ") + " Let me start over. Hi."] {
                    for limit in [60, 160] {
                        count += 1
                        let (ok, detail) = same(text, limit)
                        if !ok { failures.append(detail) }
                    }
                }
            }
        }
        out.append(Result(name: "live tail matches the whole text for \(count) placements", ok: failures.isEmpty,
                          detail: "\(failures.count) differ; first: \(failures.first ?? "")"))
        // And it runs on a window, not the whole text.
        let longer = Array(repeating: long, count: 4).joined(separator: " ")
        let from = SpokenCorrections.liveTail(longer, limit: 160).from
        let ran = longer.distance(from: from, to: longer.endIndex)
        out.append(Result(name: "live tail runs the rules on the last few sentences", ok: ran > 160 && ran < 400,
                          detail: "\(ran) of \(longer.count) characters"))
        return out
    }
}
