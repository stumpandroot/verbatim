import Foundation

// Test cases for DictationFormatter. Not part of any app target; run mac/tools/test-formatter.sh.
// Every case also checks that a second run changes nothing, and that the output's words are the input's words in
// order, minus list cue words only.

enum AppCategory { case email, work, personal, code, other }

struct Case {
    let name: String
    let input: String
    let category: AppCategory
    let expected: String
}

let lorem1 = "I went through the footage from Tuesday and most of it is usable. The interviews look great and the audio is clean. We lost about ten minutes to a bad card but nothing we can't cover with b-roll."
let lorem2 = "Also, the client wants a cut by Friday. I told them we can do a rough cut by then, and the color pass the week after."

let cases: [Case] = [
    // Numbered lists from spoken enumeration
    Case(name: "ordinal list with announcing lead-in",
         input: "We need three things. First, the photos. Second, the copy. And third, the price list.",
         category: .other,
         expected: "We need three things:\n1. The photos\n2. The copy\n3. The price list"),
    Case(name: "unpunctuated ordinal list",
         input: "We need three things first the photos second the copy and third the price list",
         category: .other,
         expected: "We need three things:\n1. The photos\n2. The copy\n3. The price list"),
    Case(name: "step one step two, steps keep their periods",
         input: "To reset the router, step one, unplug it from the wall. Step two, wait thirty seconds before you touch it. Step three, plug it back in and wait for the light.",
         category: .work,
         expected: "To reset the router:\n1. Unplug it from the wall.\n2. Wait thirty seconds before you touch it.\n3. Plug it back in and wait for the light."),
    Case(name: "cardinal one, two, three",
         input: "Here's the plan. One, finish the edit. Two, send it to Sam. Three, book the color session.",
         category: .other,
         expected: "Here's the plan:\n1. Finish the edit\n2. Send it to Sam\n3. Book the color session"),
    Case(name: "firstly, secondly, finally",
         input: "There are a few reasons. Firstly, it's cheaper. Secondly, it's faster. Finally, the team already knows it.",
         category: .other,
         expected: "There are a few reasons:\n1. It's cheaper\n2. It's faster\n3. The team already knows it"),
    Case(name: "number one, number two",
         input: "Two priorities this week. Number one, the Equipter cut. Number two, the pretzel shoot.",
         category: .work,
         expected: "Two priorities this week:\n1. The Equipter cut\n2. The pretzel shoot"),
    Case(name: "list then a trailing sentence becomes its own paragraph",
         input: "For Monday, first, call the printer. Second, confirm the venue. Let me know if anything changes.",
         category: .other,
         expected: "For Monday:\n1. Call the printer\n2. Confirm the venue\n\nLet me know if anything changes."),
    Case(name: "non-announcing lead-in stays a paragraph",
         input: "Thanks for the call today. First, I'll send the contract tonight. Second, Sam will follow up with the schedule.",
         category: .other,
         expected: "Thanks for the call today.\n\n1. I'll send the contract tonight.\n2. Sam will follow up with the schedule."),
    Case(name: "email uses plain bullets and numbers",
         input: "We need a few things for the shoot, the tripod, the softboxes, and extra batteries.",
         category: .email,
         expected: "We need a few things for the shoot:\n• The tripod\n• The softboxes\n• Extra batteries"),

    Case(name: "a lead-in of only discourse words joins the first item",
         input: "Okay so first of all I want to say thanks. Second, the schedule. Third, the budget.",
         category: .other,
         expected: "1. Okay so I want to say thanks.\n2. The schedule.\n3. The budget."),
    Case(name: "options with a count announcement",
         input: "There are two options. Option one, we wait. Option two, we ship now and patch later.",
         category: .work,
         expected: "There are two options:\n1. We wait\n2. We ship now and patch later"),

    // Mixed cue families and two-item lists (Tim's report: "first of all… number two…" didn't format)
    Case(name: "first of all then number two, unpunctuated (Tim's phrasing)",
         input: "first of all we need to confirm the location number two we need to book the crew",
         category: .other,
         expected: "1. We need to confirm the location\n2. We need to book the crew"),
    Case(name: "first of all then second, two items",
         input: "First of all, the budget is approved. Second, we start filming in May.",
         category: .work,
         expected: "1. The budget is approved\n2. We start filming in May"),
    Case(name: "number one number two, lowercase, no punctuation",
         input: "number one call the venue number two send the invoice",
         category: .other,
         expected: "1. Call the venue\n2. Send the invoice"),
    Case(name: "first then second: then before a cue is a connector",
         input: "First, call the printer, then second, confirm the venue.",
         category: .other,
         expected: "1. Call the printer\n2. Confirm the venue"),
    Case(name: "one, two as two items",
         input: "One, finish the edit. Two, send it to Sam.",
         category: .work,
         expected: "1. Finish the edit\n2. Send it to Sam"),
    Case(name: "the first thing is, the second thing is",
         input: "The first thing is we need a new mic, the second thing is the lights need gels.",
         category: .other,
         expected: "1. We need a new mic\n2. The lights need gels"),
    Case(name: "firstly secondly, unpunctuated",
         input: "firstly the audio is clean secondly the color is done",
         category: .other,
         expected: "1. The audio is clean\n2. The color is done"),
    Case(name: "first off, Number 2 as a digit, and finally",
         input: "First off, book the flights. Number 2, reserve the hotel. And finally, rent a car.",
         category: .work,
         expected: "1. Book the flights\n2. Reserve the hotel\n3. Rent a car"),
    Case(name: "to start, next, third",
         input: "To start, we need the script. Next, we cast the leads. Third, we schedule the shoot.",
         category: .other,
         expected: "1. We need the script\n2. We cast the leads\n3. We schedule the shoot"),
    Case(name: "hash numbers with an announcing lead-in",
         input: "We have two updates. #1 the app shipped. #2 the site is live.",
         category: .work,
         expected: "We have two updates:\n1. The app shipped\n2. The site is live"),
    Case(name: "1st and 2nd as digits",
         input: "Here's the plan. 1st we film the interviews, 2nd we cut the trailer.",
         category: .other,
         expected: "Here's the plan:\n1. We film the interviews\n2. We cut the trailer"),
    Case(name: "No. 1, No. 2",
         input: "No. 1, the logo. No. 2, the fonts.",
         category: .work,
         expected: "1. The logo\n2. The fonts"),
    Case(name: "bare first and second before a clause, unpunctuated",
         input: "first we need to confirm the location second we need to book the crew",
         category: .other,
         expected: "1. We need to confirm the location\n2. We need to book the crew"),
    Case(name: "non-announcing lead-in before a mixed list",
         input: "Thanks for jumping on the call. First of all, I'll send the deck tonight. Number two, Sam will book the studio.",
         category: .other,
         expected: "Thanks for jumping on the call.\n\n1. I'll send the deck tonight\n2. Sam will book the studio"),
    Case(name: "long items get consistent periods",
         input: "First of all, we need to confirm the location with the client. Second, we need to book the whole crew for Saturday",
         category: .other,
         expected: "1. We need to confirm the location with the client.\n2. We need to book the whole crew for Saturday."),
    Case(name: "and lastly ends the list",
         input: "first the mics, second the lights, and lastly the stands",
         category: .other,
         expected: "1. The mics\n2. The lights\n3. The stands"),
    Case(name: "then after the last item stays in it",
         input: "First, call the printer. Second, confirm the venue, and then let me know what they say.",
         category: .other,
         expected: "1. Call the printer.\n2. Confirm the venue, and then let me know what they say."),

    // Bulleted lists
    Case(name: "spoken bullet cues",
         input: "Groceries bullet milk bullet eggs bullet sourdough bread",
         category: .other,
         expected: "Groceries:\n- Milk\n- Eggs\n- Sourdough bread"),
    Case(name: "next bullet with punctuation from the recognizer",
         input: "Notes from the call. Bullet, budget is approved. Next bullet, launch moves to May. Next bullet, Chris owns fulfillment.",
         category: .work,
         expected: "Notes from the call.\n\n- Budget is approved\n- Launch moves to May\n- Chris owns fulfillment"),
    Case(name: "bullet cues at line starts after new line",
         input: "Packing list\nbullet charger\nbullet passport\nbullet sunscreen",
         category: .personal,
         expected: "Packing list\n• Charger\n• Passport\n• Sunscreen"),
    Case(name: "announced comma series",
         input: "Here's what we need for Friday, the photos, the copy, and the price list.",
         category: .other,
         expected: "Here's what we need for Friday:\n- The photos\n- The copy\n- The price list"),
    Case(name: "colon announces a series",
         input: "Agenda: budget, timeline, and hiring.",
         category: .work,
         expected: "Agenda:\n- Budget\n- Timeline\n- Hiring"),
    Case(name: "count announcement with the first item in the same clause",
         input: "I need three things the logo files, the brand fonts, and the color codes.",
         category: .other,
         expected: "I need three things:\n- The logo files\n- The brand fonts\n- The color codes"),
    Case(name: "model's list syntax is normalized to the destination",
         input: "We need:\n* The photos\n* The copy\n1) Call Sam\n2) Book the room",
         category: .email,
         expected: "We need:\n• The photos\n• The copy\n1. Call Sam\n2. Book the room"),
    Case(name: "model's bullets become Markdown in chat",
         input: "Updates:\n• Shipped the build\n• Fixed the crash",
         category: .work,
         expected: "Updates:\n- Shipped the build\n- Fixed the crash"),

    // Not lists
    Case(name: "ordinary comma series stays a sentence",
         input: "I picked up apples, pears, and plums on the way home.",
         category: .other,
         expected: "I picked up apples, pears, and plums on the way home."),
    Case(name: "first of all alone is not a list",
         input: "First of all, thanks for coming tonight. It means a lot to all of us.",
         category: .other,
         expected: "First of all, thanks for coming tonight. It means a lot to all of us."),
    Case(name: "at first and the second time are not markers",
         input: "At first I didn't like it, but the second time I watched it, it clicked.",
         category: .other,
         expected: "At first I didn't like it, but the second time I watched it, it clicked."),
    Case(name: "a second is not a marker",
         input: "Give me a second, I'm almost done with the first draft.",
         category: .personal,
         expected: "Give me a second, I'm almost done with the first draft."),
    Case(name: "unpunctuated first and second needs three items",
         input: "I came in first and second place went to Jo",
         category: .other,
         expected: "I came in first and second place went to Jo"),
    Case(name: "bullet as a noun",
         input: "The bullet train was late, so I wrote in my bullet journal.",
         category: .other,
         expected: "The bullet train was late, so I wrote in my bullet journal."),
    Case(name: "one, maybe two is not a list",
         input: "We need one, maybe two, more editors for the spring.",
         category: .work,
         expected: "We need one, maybe two, more editors for the spring."),
    Case(name: "a few things followed by one item is not a list",
         input: "We talked about a few things, mostly the budget.",
         category: .other,
         expected: "We talked about a few things, mostly the budget."),
    Case(name: "times and numbers are not lists",
         input: "Meet at 1, then 2. Then 3 pm works too.",
         category: .other,
         expected: "Meet at 1, then 2. Then 3 pm works too."),

    Case(name: "first of all with no second item stays a sentence, unpunctuated",
         input: "first of all I want to thank everyone for coming out tonight",
         category: .other,
         expected: "first of all I want to thank everyone for coming out tonight"),
    Case(name: "number one priority and two of are not cues",
         input: "That was our number one priority last year, and two of the editors agreed.",
         category: .work,
         expected: "That was our number one priority last year, and two of the editors agreed."),
    Case(name: "number one priority, number two priority is a ranking",
         input: "Number one priority is the edit, number two priority is the mix.",
         category: .work,
         expected: "Number one priority is the edit, number two priority is the mix."),
    Case(name: "at first and a second pass are not cues",
         input: "At first it was slow, but a second pass fixed it.",
         category: .other,
         expected: "At first it was slow, but a second pass fixed it."),
    Case(name: "second-guess is not a cue",
         input: "Don't second-guess the first cut, it works.",
         category: .personal,
         expected: "Don't second-guess the first cut, it works."),
    Case(name: "one of and two or three are not cues",
         input: "One of the drives failed, so we need two or three new ones.",
         category: .other,
         expected: "One of the drives failed, so we need two or three new ones."),
    Case(name: "first thing tomorrow with no second item",
         input: "First thing tomorrow I'll call the client, then we can decide.",
         category: .other,
         expected: "First thing tomorrow I'll call the client, then we can decide."),
    Case(name: "first then without a second ordinal is a sentence",
         input: "First we load the truck, then we drive to the venue.",
         category: .other,
         expected: "First we load the truck, then we drive to the venue."),
    Case(name: "next week is not a cue",
         input: "First, I'll send the draft. Next week we can review it together.",
         category: .other,
         expected: "First, I'll send the draft. Next week we can review it together."),

    Case(name: "a question with a comma series stays a question",
         input: "Can you grab the following, milk, eggs, and bread?",
         category: .other,
         expected: "Can you grab the following, milk, eggs, and bread?"),
    Case(name: "my first thought, my second thought",
         input: "My first thought was no. My second thought was maybe.",
         category: .other,
         expected: "My first thought was no. My second thought was maybe."),

    // Paragraphs
    Case(name: "short message stays one paragraph",
         input: "Sounds good. Also, can you bring the hard drive?",
         category: .personal,
         expected: "Sounds good. Also, can you bring the hard drive?"),
    Case(name: "topic shift starts a paragraph in a long message",
         input: lorem1 + " " + lorem2,
         category: .other,
         expected: lorem1 + "\n\n" + lorem2),
    Case(name: "long paragraph splits at a natural boundary",
         input: "The shoot went well overall and the client was happy with the setups. We got every shot on the list before lunch. The second half of the day was mostly b-roll around the shop floor. So the edit should be simple, and I expect a first cut by Thursday. I'll send the selects tonight so you can start logging. If anything looks off in the selects, flag it early and we can reshoot on Monday.",
         category: .other,
         expected: "The shoot went well overall and the client was happy with the setups. We got every shot on the list before lunch. The second half of the day was mostly b-roll around the shop floor.\n\nSo the edit should be simple, and I expect a first cut by Thursday. I'll send the selects tonight so you can start logging. If anything looks off in the selects, flag it early and we can reshoot on Monday."),
    Case(name: "explicit paragraphs are kept",
         input: "First paragraph here.\n\nSecond paragraph here.",
         category: .other,
         expected: "First paragraph here.\n\nSecond paragraph here."),

    // Email
    Case(name: "email greeting and sign-off on their own lines",
         input: "Hi Sarah, thanks for sending the draft over. I'll review it tonight and send notes in the morning. Best, Tim",
         category: .email,
         expected: "Hi Sarah,\n\nThanks for sending the draft over. I'll review it tonight and send notes in the morning.\n\nBest,\nTim"),
    Case(name: "thanks with a name is not treated as a sign-off",
         input: "I'll send the files tonight. Thank you, Sarah.",
         category: .email,
         expected: "I'll send the files tonight. Thank you, Sarah."),

    // Code apps
    Case(name: "code apps are untouched",
         input: "first install the package second run the tests and third push",
         category: .code,
         expected: "first install the package second run the tests and third push"),
]

// MARK: Checks

let cueWords: Set<String> = ["first", "firstly", "second", "secondly", "third", "thirdly", "fourth", "fifth", "finally", "lastly", "last",
                             "one", "two", "three", "four", "five", "number", "step", "point", "item", "option", "reason",
                             "bullet", "next", "new", "dash", "and", "then", "or", "of", "all", "off", "also", "plus", "firstly", "thirdly",
                             "the", "thing", "is", "was", "to", "start", "begin", "with", "for", "starters", "no", "final"]

/// "2", "2nd", "1st": numbers spoken as cues may be dropped too.
func isCue(_ w: String) -> Bool {
    cueWords.contains(w) || w.range(of: #"^\d{1,2}(?:st|nd|rd|th)?$"#, options: .regularExpression) != nil
}

func words(_ s: String) -> [String] {
    // Drop list markers ("1.", "-", "•") before comparing words.
    let body = s.components(separatedBy: "\n").map { line -> String in
        line.replacingOccurrences(of: #"^(?:[-•*–+]|\d{1,2}[.)])\s+"#, with: "", options: .regularExpression)
    }.joined(separator: " ")
    return body.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted).filter { !$0.isEmpty }
}

/// Output words must be the input's words in order; only cue words may be missing.
func wordProblem(input: String, output: String) -> String? {
    let a = words(input), b = words(output)
    var i = 0
    for w in b {
        while i < a.count && a[i] != w {
            if !isCue(a[i]) { return "dropped “\(a[i])” before “\(w)”" }
            i += 1
        }
        if i == a.count { return "added or reordered “\(w)”" }
        i += 1
    }
    for w in a[i...] where !isCue(w) { return "dropped “\(w)” at the end" }
    return nil
}

func show(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "⏎\n      ") }

var passed = 0, failed = 0
for c in cases {
    let out = DictationFormatter.format(c.input, for: c.category)
    let again = DictationFormatter.format(out, for: c.category)
    var problems: [String] = []
    if out != c.expected { problems.append("expected:\n      \(show(c.expected))\n    got:\n      \(show(out))") }
    if again != out { problems.append("not idempotent; second run:\n      \(show(again))") }
    if let p = wordProblem(input: c.input, output: out) { problems.append("words: \(p)") }
    if problems.isEmpty {
        passed += 1
        print("PASS  \(c.name)")
    } else {
        failed += 1
        print("FAIL  \(c.name)")
        for p in problems { print("    " + p) }
    }
}
print("\n\(passed) passed, \(failed) failed, \(cases.count) cases")
exit(failed == 0 ? 0 : 1)
