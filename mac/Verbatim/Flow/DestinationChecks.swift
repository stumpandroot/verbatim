import Foundation

/// Self-tests for formatting by destination: email greetings, sign-offs, and paragraphs; Slack and Messages
/// layout; the rules that run after the model; and the app and website classifier. Foundation only. The Mac
/// self-test (`UITest`) runs them, and so does `mac/tools/test-formatter.sh` on any Swift toolchain.
enum DestinationChecks {
    struct Result {
        let name: String
        let ok: Bool
        let detail: String
    }

    private struct Case {
        let name: String
        let input: String
        let options: DictationFormatter.Options
        let expected: String
        /// Run the rules that follow the model (`CleanupPrepass.finalRules`, Polished) first, as `FlowCleanup` does.
        var finalRules = false
    }

    private static let email = DictationFormatter.EmailPrefs.options(ownLines: true, short: false)
    private static let emailTim = DictationFormatter.EmailPrefs.options(ownLines: true, short: false, signer: ["Tim Medina"])
    private static let emailShort = DictationFormatter.EmailPrefs.options(ownLines: true, short: true, signer: ["Tim Medina"])
    private static let emailInline = DictationFormatter.EmailPrefs.options(ownLines: false, short: false, signer: ["Tim Medina"])
    private static let emailInsert = DictationFormatter.EmailPrefs.options(ownLines: true, short: false, insertion: true, signer: ["Tim Medina"])
    private static let work = DictationFormatter.options(for: .work)!
    private static let personal = DictationFormatter.options(for: .personal)!

    private static let footage = "I went through the footage from Tuesday and most of it is usable. The interviews look great and the audio is clean. We lost about ten minutes to a bad card, but nothing we can't cover with b-roll."
    private static let ask = "Also, the client wants a cut by Friday. Can you let me know if that works for your schedule?"

    private static let cases: [Case] = [
        // Greetings
        Case(name: "email: greeting and Best sign-off", input: "Hi Sarah, thanks for sending the draft over. I'll review it tonight and send notes in the morning. Best, Tim",
             options: email, expected: "Hi Sarah,\n\nThanks for sending the draft over. I'll review it tonight and send notes in the morning.\n\nBest,\nTim"),
        Case(name: "email: run-on greeting gets its own line", input: "hi Sarah how are you", options: email, expected: "Hi Sarah,\n\nHow are you?"),
        Case(name: "email: Hi, Sarah. becomes Hi Sarah,", input: "Hi, Sarah. I wanted to follow up on the proposal.", options: email,
             expected: "Hi Sarah,\n\nI wanted to follow up on the proposal."),
        Case(name: "email: Hey team", input: "Hey team, quick update. The shoot moved to Friday.", options: email,
             expected: "Hey team,\n\nQuick update. The shoot moved to Friday."),
        Case(name: "email: two names", input: "Hi Sarah and Jake, the cut is ready for review.", options: email,
             expected: "Hi Sarah and Jake,\n\nThe cut is ready for review."),
        Case(name: "email: Hello everyone", input: "Hello everyone. Welcome to the project.", options: email, expected: "Hello everyone,\n\nWelcome to the project."),
        Case(name: "email: Dear Mr. Smith", input: "Dear Mr. Smith, thank you for your letter.", options: email, expected: "Dear Mr. Smith,\n\nThank you for your letter."),
        Case(name: "email: Good morning with a name", input: "Good morning Sarah, the files are uploaded.", options: email, expected: "Good morning Sarah,\n\nThe files are uploaded."),
        Case(name: "email: greeting stops at I", input: "Hey Sarah I wanted to check in about Friday.", options: email, expected: "Hey Sarah,\n\nI wanted to check in about Friday."),
        Case(name: "email: lowercase greeting", input: "hi Sarah, the invoice is attached.", options: email, expected: "Hi Sarah,\n\nThe invoice is attached."),
        Case(name: "email: Hey, can you… is not a greeting", input: "Hey, can you send me the invoice?", options: email, expected: "Hey, can you send me the invoice?"),
        Case(name: "email: Hello world is not a greeting", input: "Hello world is the first program most people write.", options: email,
             expected: "Hello world is the first program most people write."),
        Case(name: "email: Dear God is not a greeting", input: "Dear God, that was close.", options: email, expected: "Dear God, that was close."),
        Case(name: "email: bare Hey before a new sentence", input: "Hey. Can you call me when you get a chance?", options: email,
             expected: "Hey,\n\nCan you call me when you get a chance?"),
        // Sign-offs
        Case(name: "email: Thank you, Sarah thanks the reader", input: "I'll send the files tonight. Thank you, Sarah.", options: email,
             expected: "I'll send the files tonight. Thank you, Sarah."),
        Case(name: "email: Thanks, Tim with your name", input: "Can you send the invoice over? Thanks, Tim", options: emailTim,
             expected: "Can you send the invoice over?\n\nThanks,\nTim"),
        Case(name: "email: run-on thanks Tim", input: "Let me know if Friday works thanks Tim", options: emailTim,
             expected: "Let me know if Friday works.\n\nThanks,\nTim"),
        Case(name: "email: lowercase thanks tim", input: "Let me know if Friday works. thanks tim", options: emailTim,
             expected: "Let me know if Friday works.\n\nThanks,\nTim"),
        Case(name: "email: thanks for the update is a sentence", input: "Thanks for the update yesterday. I'll review the cut tonight.", options: emailTim,
             expected: "Thanks for the update yesterday. I'll review the cut tonight."),
        Case(name: "email: thanks for… at the end is a sentence", input: "I'll review the cut tonight. Thanks for the update yesterday.", options: emailTim,
             expected: "I'll review the cut tonight. Thanks for the update yesterday."),
        Case(name: "email: Thanks alone", input: "The files are in the shared folder. Thanks.", options: emailTim,
             expected: "The files are in the shared folder.\n\nThanks,"),
        Case(name: "email: run-on thanks after a question", input: "Can you send it over thanks", options: emailTim, expected: "Can you send it over?\n\nThanks,"),
        Case(name: "email: say thanks is a sentence", input: "I just wanted to say thanks", options: emailTim, expected: "I just wanted to say thanks"),
        Case(name: "email: full name sign-off", input: "See you Thursday. Best, Tim Medina", options: emailTim, expected: "See you Thursday.\n\nBest,\nTim Medina"),
        Case(name: "email: Best regards", input: "See you Thursday. Best regards, Tim", options: email, expected: "See you Thursday.\n\nBest regards,\nTim"),
        Case(name: "email: the best is not a sign-off", input: "That's the best.", options: emailTim, expected: "That's the best."),
        Case(name: "email: Cheers alone stays", input: "Cheers", options: emailTim, expected: "Cheers"),
        Case(name: "email: Appreciate it, Tim", input: "The deck looks great. Appreciate it, Tim", options: emailTim,
             expected: "The deck looks great.\n\nAppreciate it,\nTim"),
        Case(name: "email: thanks with another name after a greeting", input: "Hi Sarah, the deck is attached. Thanks so much, Tim", options: email,
             expected: "Hi Sarah,\n\nThe deck is attached.\n\nThanks so much,\nTim"),
        Case(name: "email: thanking the person greeted", input: "Hi Sarah, thanks for everything. Thank you, Sarah.", options: email,
             expected: "Hi Sarah,\n\nThanks for everything. Thank you, Sarah."),
        Case(name: "email: only a greeting and a sign-off", input: "Hi Sarah. Thanks. Tim", options: emailTim, expected: "Hi Sarah,\n\nThanks,\nTim"),
        // Body
        Case(name: "email: short email stays one paragraph", input: "Hi Sarah, see you at 3. Thanks, Tim", options: emailTim,
             expected: "Hi Sarah,\n\nSee you at 3.\n\nThanks,\nTim"),
        Case(name: "email: paragraphs at a topic shift", input: "Hi Sarah, \(footage) \(ask) Thanks, Tim", options: emailTim,
             expected: "Hi Sarah,\n\n\(footage)\n\n\(ask)\n\nThanks,\nTim"),
        Case(name: "email: short paragraphs", input: "Hi Sarah, \(footage) \(ask) Thanks, Tim", options: emailShort,
             expected: "Hi Sarah,\n\nI went through the footage from Tuesday and most of it is usable. The interviews look great and the audio is clean.\n\nWe lost about ten minutes to a bad card, but nothing we can't cover with b-roll.\n\n\(ask)\n\nThanks,\nTim"),
        Case(name: "email: a blank line before a list", input: "We need three things first the photos second the copy and third the price list", options: email,
             expected: "We need three things:\n\n1. The photos\n2. The copy\n3. The price list"),
        Case(name: "email: greeting lines off", input: "Hi Sarah, see you at 3. Thanks, Tim", options: emailInline, expected: "Hi Sarah, see you at 3. Thanks, Tim"),
        Case(name: "email: mid-email insertion keeps sentences", input: "Hi Sarah, see you at 3. Thanks, Tim", options: emailInsert, expected: "Hi Sarah, see you at 3. Thanks, Tim"),
        // Tim's Gmail dictation (Polished, Chrome), as the model returned it.
        Case(name: "email: Tim's Gmail dictation",
             input: "Hey Claude,\n\nThis is me just typing out or transcribing an email to you. So here's a few things I want to go over:\n1. Let's do the first task.\n2. Let's do a different kind of task.\n3. Let's do the another kind of thing we can kind of work on.\n\nSo, once you see this, let me know what you think and get back to me. Thank you so much. Tim",
             options: email,
             expected: "Hey Claude,\n\nThis is me just typing out or transcribing an email to you. Here are a few things I want to go over:\n\n1. Let's do the first task.\n2. Let's do a different kind of task.\n3. Let's do another kind of thing we can work on.\n\nOnce you see this, let me know what you think and get back to me.\n\nThank you so much,\nTim",
             finalRules: true),
        Case(name: "email: thank you so much for… is a sentence",
             input: "Hey Claude,\n\nSo, once you see this, let me know what you think and get back to me. Thank you so much for your help with the shoot.",
             options: email,
             expected: "Hey Claude,\n\nOnce you see this, let me know what you think and get back to me. Thank you so much for your help with the shoot.",
             finalRules: true),

        // Slack and Teams
        Case(name: "slack: no greeting line", input: "Hey team, quick update. The shoot moved to Friday.", options: work, expected: "Hey team, quick update. The shoot moved to Friday."),
        Case(name: "slack: mentions and channels stay", input: "@Sarah can you check the #design channel before lunch?", options: work,
             expected: "@Sarah can you check the #design channel before lunch?"),
        Case(name: "slack: short paragraphs, split before the ask",
             input: "The cut is uploaded to the shared drive. Sarah did the color pass this morning. The audio still needs a final mix. Can you take a look before lunch? Let me know if anything looks off.",
             options: work,
             expected: "The cut is uploaded to the shared drive. Sarah did the color pass this morning. The audio still needs a final mix.\n\nCan you take a look before lunch? Let me know if anything looks off."),
        Case(name: "slack: Markdown list", input: "We need three things first the photos second the copy and third the price list", options: work,
             expected: "We need three things:\n1. The photos\n2. The copy\n3. The price list"),
        Case(name: "slack: thanks Tim is not a sign-off", input: "Sounds good thanks Tim", options: work, expected: "Sounds good thanks Tim"),

        // Messages and WhatsApp
        Case(name: "messages: short message stays one paragraph", input: "Running late. Be there in ten. Also, do you want coffee?", options: personal,
             expected: "Running late. Be there in ten. Also, do you want coffee?"),
        Case(name: "messages: no sign-off", input: "Love you, see you soon. Thanks Mom", options: personal, expected: "Love you, see you soon. Thanks Mom"),
        Case(name: "messages: question mark stays", input: "are we still on for tonight?", options: personal, expected: "are we still on for tonight?"),
        Case(name: "messages: emoji words stay words", input: "That's hilarious laughing emoji", options: personal, expected: "That's hilarious laughing emoji"),
    ]

    /// The rules after the model, alone: (input, polished, expected).
    private static let ruleCases: [(String, Bool, String)] = [
        ("So, once you see this, let me know.", true, "Once you see this, let me know."),
        ("So here's a few things I want to go over:", true, "Here are a few things I want to go over:"),
        ("I love it so much.", true, "I love it so much."),
        ("We moved it, so we need a new date.", true, "We moved it, so we need a new date."),
        ("So I can't make it Friday.", true, "So I can't make it Friday."),
        ("Let's do the another kind of thing we can kind of work on.", true, "Let's do another kind of thing we can work on."),
        ("It's a different kind of task.", true, "It's a different kind of task."),
        ("What kind of camera is it?", true, "What kind of camera is it?"),
        ("It's kind of a mess.", true, "It's kind of a mess."),
        ("There's two options for the venue.", true, "There are two options for the venue."),
        ("Here's three quick things.", true, "Here are three quick things."),
        ("There's some news about the shoot.", true, "There's some news about the shoot."),
        ("There's a few people here. The another one left.", false, "There are a few people here. Another one left."),
        ("So, once you see this, we can kind of start.", false, "So, once you see this, we can kind of start."),
    ]

    /// Classifier cases: (bundle ID, window title, host, expected).
    private static let classifierCases: [(String?, String, String?, AppCategory)] = [
        ("com.google.Chrome", "Untitled", "mail.google.com", .email),
        ("com.apple.Safari", "Mail", "outlook.office.com", .email),
        ("com.apple.Safari", "", "outlook.live.com", .email),
        ("company.thebrowser.Browser", "", "mail.proton.me", .email),
        ("com.google.Chrome", "", "app.fastmail.com", .email),
        ("com.google.Chrome", "", "app.hey.com", .email),
        ("com.google.Chrome", "", "mail.superhuman.com", .email),
        ("com.google.Chrome", "", "mail.notion.so", .email),
        ("com.google.Chrome", "general", "app.slack.com", .work),
        ("com.brave.Browser", "", "acme.slack.com", .work),
        ("company.thebrowser.Browser", "Chat", "teams.microsoft.com", .work),
        ("com.google.Chrome", "", "discord.com", .work),
        ("com.google.Chrome", "", "www.notion.so", .work),
        ("com.google.Chrome", "", "web.whatsapp.com", .personal),
        ("com.apple.Safari", "", "www.messenger.com", .personal),
        ("com.google.Chrome", "", "messages.google.com", .personal),
        ("com.google.Chrome", "", "github.com", .code),
        ("com.google.Chrome", "Inbox (3) - tim@stumpandroot.co - Gmail", nil, .email),
        ("com.google.Chrome", "Slack | general", "example.com", .work),
        ("com.google.Chrome", "Q3 plan", "docs.google.com", .other),
        ("com.apple.Safari.WebApp.1A2B", "", "mail.google.com", .email),
        ("com.apple.notes", "Notes", "mail.google.com", .other),
        ("com.microsoft.teams2", "", nil, .work),
        ("com.tinyspeck.slackmacgap", "", nil, .work),
        ("com.hnc.Discord", "", nil, .work),
        ("com.apple.mail", "", nil, .email),
        ("net.whatsapp.WhatsApp", "", nil, .personal),
        ("com.apple.Terminal", "", nil, .code),
    ]

    static func run() -> [Result] {
        var out: [Result] = []
        for c in cases {
            let input = c.finalRules ? CleanupPrepass.finalRules(c.input, polished: true) : c.input
            let got = DictationFormatter.format(input, c.options)
            let again = DictationFormatter.format(got, c.options)
            var detail = ""
            if got != c.expected { detail = "expected:\n\(c.expected)\ngot:\n\(got)" }
            else if again != got { detail = "a second run changed it:\n\(again)" }
            out.append(Result(name: c.name, ok: detail.isEmpty, detail: detail))
        }
        for (input, polished, expected) in ruleCases {
            let got = CleanupPrepass.finalRules(input, polished: polished)
            out.append(Result(name: "final rules: \(input)", ok: got == expected, detail: got == expected ? "" : "expected: \(expected)\ngot: \(got)"))
        }
        for (bid, title, host, expected) in classifierCases {
            let got = AppCategory.classify(bundleID: bid, title: title, host: host)
            out.append(Result(name: "classify \(bid ?? "nil") \(host ?? "-") “\(title)”", ok: got == expected,
                              detail: got == expected ? "" : "expected \(expected.rawValue), got \(got.rawValue)"))
        }
        return out
    }
}
