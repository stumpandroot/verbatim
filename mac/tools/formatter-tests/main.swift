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
                             "bullet", "next", "new", "dash", "and", "then", "or", "of", "all", "off", "also", "plus"]

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
            if !cueWords.contains(a[i]) { return "dropped “\(a[i])” before “\(w)”" }
            i += 1
        }
        if i == a.count { return "added or reordered “\(w)”" }
        i += 1
    }
    for w in a[i...] where !cueWords.contains(w) { return "dropped “\(w)” at the end" }
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
