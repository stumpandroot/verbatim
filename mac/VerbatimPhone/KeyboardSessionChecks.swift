import UIKit

/// Self-tests for Build E2 (the keyboard's format chip and the App Store switch), run with the screenshot tour
/// (`PhoneUITest.run`). Pure functions only: a simulator can't run keyboards, and nothing here calls a private
/// interface. Results go to the log as UITEST lines.
@MainActor
enum KeyboardSessionChecks {
    static func run() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") keyboard E2: \(name)")
        }
        typealias F = KeyboardFormat
        typealias T = KeyboardFormat.FieldTraits

        // Format inference from public traits and the text before the cursor.
        check("a greeting line reads as email", F.infer(T(before: "Hi Sarah,\n")) == .email)
        check("a greeting with a comma as the whole text reads as email", F.infer(T(before: "Dear Mr. Lee,")) == .email)
        check("a sign-off reads as email", F.infer(T(before: "Thanks for the update.\n\nBest,\nTim")) == .email)
        check("a quoted reply header reads as email", F.infer(T(before: "Sounds good.\n\nOn Monday, Sam Park wrote:\n> Lunch?")) == .email)
        check("a Send return key reads as a message", F.infer(T(returnKeyType: .send, before: "")) == .message)
        check("a greeting beats the Send key", F.infer(T(returnKeyType: .send, before: "Hello team,\n")) == .email)
        check("short chat text reads as a message", F.infer(T(before: "hey are we still on for 6")) == .message)
        check("a casual 'hi there' isn't email", F.infer(T(before: "hi there how's it going")) == .message)
        check("an empty field reads as a message", F.infer(T()) == .message)
        let prose = String(repeating: "This paragraph explains the plan in some detail. ", count: 8)
        check("long prose reads as a note", F.infer(T(before: prose)) == .note)
        check("paragraph breaks read as a note", F.infer(T(before: "First idea.\n\nSecond idea.")) == .note)
        check("an email address field isn't body text", F.infer(T(keyboardType: .emailAddress, before: "Hi Sarah,\n")) == .note)
        check("a URL content type isn't body text", F.infer(T(textContentType: .URL)) == .note)
        check("a username field isn't body text", F.infer(T(textContentType: .username)) == .note)

        // Chosen formats and categories.
        check("Email maps to the email category", F.email.category(hostKind: nil) == "email")
        check("Message maps to personal without a host", F.message.category(hostKind: nil) == "personal")
        check("Message in a work chat app maps to work", F.message.category(hostKind: .work) == "work")
        check("Note maps to everything else", F.note.category(hostKind: .email) == "other")
        check("the chip cycles Auto, Email, Message, Note", F.auto.next == .email && F.email.next == .message && F.message.next == .note && F.note.next == .auto)

        // Host classification (full builds; App Store builds never know the host).
        check("Mail is email", F.classify(host: "com.apple.mobilemail")?.kind == .email)
        check("Outlook and Gmail are email", F.classify(host: "com.microsoft.Office.Outlook")?.kind == .email && F.classify(host: "com.google.Gmail")?.kind == .email)
        check("Messages, WhatsApp, Telegram, and Signal are personal",
              ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ph.telegra.Telegraph", "org.whispersystems.signal"].allSatisfy { F.classify(host: $0)?.kind == .personal })
        check("Slack, Teams, and Discord are work",
              ["com.tinyspeck.chatlyio", "com.microsoft.skype.teams", "com.hammerandchisel.discord"].allSatisfy { F.classify(host: $0)?.kind == .work })
        check("an unknown host isn't classified", F.classify(host: "com.example.unknown") == nil && F.classify(host: nil) == nil)
        let mail = F.resolve(.auto, host: "com.apple.mobilemail", traits: T(returnKeyType: .send))
        check("Auto with a known host says its name", mail.label == "Auto · Mail" && mail.category == "email")
        let slack = F.resolve(.auto, host: "com.tinyspeck.chatlyio", traits: T())
        check("Auto in Slack is work", slack.label == "Auto · Slack" && slack.category == "work")
        let inferred = F.resolve(.auto, host: nil, traits: T(before: "Hi Sarah,\n"))
        check("Auto without a host says what it inferred", inferred.label == "Auto · Email" && inferred.category == "email")
        let chosen = F.resolve(.message, host: "com.tinyspeck.chatlyio", traits: T(before: "Hi Sarah,\n"))
        check("a chosen format beats inference", chosen.label == "Message" && chosen.category == "work")

        // The app's side: the chip's category wins, then the host, then work messages.
        check("the app uses the chip's category", PhoneDictation.category(host: nil, chosen: "email", own: "own") == .email)
        check("the app classifies a known host", PhoneDictation.category(host: "net.whatsapp.WhatsApp", chosen: nil, own: "own") == .personal)
        check("the app falls back to work messages", PhoneDictation.category(host: nil, chosen: nil, own: "own") == .work)
        check("dictation inside Verbatim is everything else", PhoneDictation.category(host: "own", chosen: "email", own: "own") == .other)
        let d = UUID()
        check("the stored category belongs to its dictation",
              KeyboardBridge.parseCategory(d.uuidString + " email", for: d) == "email" && KeyboardBridge.parseCategory(UUID().uuidString + " email", for: d) == nil)

        // The App Store switch: every private-API seam reports unavailable.
        let store = Distribution.abilities(appStore: true)
        check("App Store builds read no host app", !store.readsHostApp)
        check("App Store builds' keyboard doesn't open Verbose", !store.keyboardOpensVerbatim)
        check("App Store builds don't switch back to your app", !store.returnsToHostApp)
        check("App Store builds don't fetch YouTube on the device", !store.youTubeOnDevice)
        check("the return seam is unavailable in App Store builds",
              KeyboardSession.returnToHostApp(linkHost: "com.apple.MobileSMS", appStore: true) == KeyboardSession.unavailableInAppStore)
        let full = Distribution.abilities(appStore: false)
        check("full builds keep the host, opening, and returning", full.readsHostApp && full.keyboardOpensVerbatim && full.returnsToHostApp)
        check("this build's flag matches its abilities", Distribution.current == Distribution.abilities(appStore: Distribution.isAppStore))

        // Session links from outside the keyboard, and the longer timeouts.
        let control = KeyboardBridge.sessionLink(in: KeyboardBridge.sessionURL(from: .control))
        check("a Control Center link starts a session with no request", control == KeyboardBridge.SessionLink(request: nil, host: nil, dictation: nil, source: .control))
        let widget = KeyboardBridge.sessionLink(in: URL(string: "verbatim://session?start=1&from=widget")!)
        check("the Lock Screen widget's link names its source", widget?.source == .widget && widget?.request == nil)
        let seconds = KeyboardSession.timeoutChoices.map { $0.seconds }
        check("session timeouts keep 1, 5, 15 minutes and until you end it", [60, 300, 900, 0].allSatisfy { seconds.contains($0) })
        check("session timeouts add 30 and 60 minutes", seconds.contains(1800) && seconds.contains(3600))
        check("timeout labels", KeyboardSession.label(1800) == "30 minutes" && KeyboardSession.label(3600) == "60 minutes")

        Log.note("UITEST keyboard E2 checks: \(pass) passed, \(fail) failed")
    }
}
