import Foundation

// The keyboard's modes and the Home screen's numbers, as pure rules: which mode the keyboard opens in, which mode
// shows while a dictation runs, and the stats pages' words. Foundation only (no UIKit), so
// mac/tools/test-keyboard.sh compiles and checks it on Linux. `KeyboardModel` applies them.

// MARK: - Modes

/// The two resting views: Home (your numbers and Tap to talk) and Typing (the full keyboard with Start).
enum KeyboardSurface: String, Equatable {
    case home, typing

    /// The extension's own defaults key for when a dictation was last inserted. Not the App Group, so it works the
    /// same with or without Full Access.
    static let lastInsertedKey = "kb.lastInsertedAt"

    /// How long after inserting a dictation the keyboard still counts as the same writing session, and so reopens
    /// in Typing instead of Home.
    static let sessionWindow: TimeInterval = 15 * 60

    /// The view the keyboard opens in. Typing for fields that want typing (numbers, email addresses, links,
    /// passwords) and when dictation can't work (no Full Access). Otherwise Home the first time in a session, and
    /// Typing once a dictation has gone in (within `sessionWindow`).
    static func opening(field: FieldKind, secure: Bool, dictationAvailable: Bool,
                        lastInsertedAt: Date?, now: Date) -> KeyboardSurface {
        if secure { return .typing }
        switch field {
        case .numberPad, .decimalPad, .numbersAndPunctuation, .email, .url: return .typing
        case .standard: break
        }
        guard dictationAvailable else { return .typing }
        if let t = lastInsertedAt, now >= t, now.timeIntervalSince(t) < sessionWindow { return .typing }
        return .home
    }
}

/// What the keyboard shows: Home, Typing, or Listening (which also covers starting, writing, and polishing).
enum KeyboardMode: Equatable {
    case home, typing, listening

    /// A dictation in progress (or its polish) always shows Listening; otherwise the resting view.
    static func current(surface: KeyboardSurface, dictating: Bool) -> KeyboardMode {
        if dictating { return .listening }
        return surface == .home ? .home : .typing
    }
}

/// How long the Typing bar shows "✓ Inserted" before it goes back to the plain bar (longer with a spoken-correction
/// notice, which has more to read).
enum InsertedBar {
    static let seconds: TimeInterval = 5
    static let correctionSeconds: TimeInterval = 12

    static func expired(shownFor t: TimeInterval, hasCorrection: Bool) -> Bool {
        t >= (hasCorrection ? correctionSeconds : seconds)
    }
}

// MARK: - The session, as the keyboard sees it

/// Whether the app's session can take a dictation, is paused for a call, or isn't there.
enum KeyboardPresence: Equatable {
    /// The app's heartbeat is fresh and it isn't paused: dictation starts right here.
    case live
    /// A phone or FaceTime call (or Siri) has the audio; the app picks the session up when it ends. iOS may suspend
    /// the app during the call, so the heartbeat can go stale; the pause still counts for `pauseLimit`.
    case paused
    /// No session: Home shows Start a session.
    case off

    /// A pause older than this is treated as no session (the app was closed during the call, say).
    static let pauseLimit: TimeInterval = 3 * 3600

    /// From the App Group: `active` (the app says a session is on), the heartbeat's age, and when the app paused
    /// (seconds since 1970; 0 when it isn't paused). `stale` is `KeyboardBridge.heartbeatStale`.
    static func from(active: Bool, heartbeatAge: TimeInterval, pausedAt: Double, now: Double, stale: TimeInterval = 6) -> KeyboardPresence {
        guard active else { return .off }
        if pausedAt > 0 {
            let age = now - pausedAt
            return age >= -2 && age < pauseLimit ? .paused : .off
        }
        return heartbeatAge >= 0 && heartbeatAge < stale ? .live : .off
    }
}

/// What Home shows with Full Access and no session: Start a session (it opens Verbose straight into the session),
/// or, when opening Verbose didn't work, the three other ways to start one.
enum StartCard: Equatable {
    case start
    case instructions

    /// `openFailed`: the last Start a session couldn't open Verbose. A session coming on clears it.
    static func shown(openFailed: Bool) -> StartCard { openFailed ? .instructions : .start }

    static let title = "Start a session"
    static let secondary = "Or use Control Center or the Action button"
    /// The three ways when the keyboard couldn't open Verbose.
    static let ways = ["Open Control Center and tap Verbose",
                       "Press the Action button, if you set it to Verbose",
                       "Or open Verbose and tap Start keyboard session"]

    /// The line under the headline: what Start a session does. App Store builds can't switch back by themselves,
    /// so you come back with the ◀ at the top left.
    static func detail(returnsByItself: Bool) -> String {
        returnsByItself ? "Verbose opens for a second to turn on the microphone, then comes back here."
                        : "Verbose opens to turn on the microphone. Then tap ◀ at the top left to come back."
    }
}

/// The Listening view's words while the speech model loads for the first dictation (the app says when it's ready).
enum ListeningCopy {
    /// Title and line for Listening and Writing it down. `engineReady` comes from the App Group; missing reads as ready.
    static func lines(stage: String, engineReady: Bool) -> (title: String, detail: String)? {
        guard !engineReady, stage == "listening" || stage == "writing" else { return nil }
        return ("Getting ready", "The first one takes a few seconds")
    }
}

// MARK: - Stats pages

/// One Home page: the big number and its italic unit in the serif, and the line under it.
struct KeyboardStatPage: Equatable {
    var number: String
    var unit: String
    var line: String
    /// What VoiceOver says for the whole page.
    var spoken: String { "\(number) \(unit) \(line)" }
}

/// The numbers the app writes for the keyboard (`KeyboardBridge.Stats`), as plain values so the copy is testable.
struct KeyboardStatNumbers: Equatable {
    var weekWords: Int
    var weekSecondsSaved: Double
    /// False once the calendar week the app counted has ended (the app hasn't run since).
    var weekCurrent: Bool
    var totalWords: Int
    /// Words and speaking time from dictations whose length is known, for the pace.
    var paceWords: Int
    var paceSeconds: Double
    var typingWPM: Int
}

enum KeyboardStatsCopy {
    /// Words in a novel, for "That's about half a novel."
    static let novelWords = 90_000
    /// Words on a printed page.
    static let pageWords = 250
    /// Less speaking time than this gives a pace too noisy to show.
    static let minPaceSeconds: Double = 60

    /// Home's pages, in order: this week, since you started, and your speaking pace (left out until there's a minute
    /// of speech to measure). Empty when nothing has been dictated yet (Home then shows its welcome line).
    static func pages(_ n: KeyboardStatNumbers, grouping: String = groupingSeparator) -> [KeyboardStatPage] {
        guard n.totalWords > 0 else { return [] }
        let week = n.weekCurrent ? max(0, n.weekWords) : 0
        let saved = n.weekCurrent ? max(0, n.weekSecondsSaved) : 0
        var weekLine = "dictated this week."
        if saved >= 60 { weekLine += " That's \(duration(saved)) you didn't have to type." }
        var out = [KeyboardStatPage(number: number(week, grouping: grouping), unit: week == 1 ? "word" : "words", line: weekLine)]
        var totalLine = "since you started."
        if let c = comparison(n.totalWords) { totalLine += " That's \(c)." }
        out.append(KeyboardStatPage(number: number(n.totalWords, grouping: grouping), unit: n.totalWords == 1 ? "word" : "words", line: totalLine))
        if let wpm = pace(words: n.paceWords, seconds: n.paceSeconds) {
            var line = "your speaking pace"
            if let f = faster(pace: wpm, typing: n.typingWPM) { line += ", \(f)" }
            out.append(KeyboardStatPage(number: number(wpm, grouping: grouping), unit: "wpm", line: line + "."))
        }
        return out
    }

    /// Words a minute while talking, rounded; nil with less than `minPaceSeconds` of speech.
    static func pace(words: Int, seconds: Double) -> Int? {
        guard words > 0, seconds >= minPaceSeconds else { return nil }
        return Int((Double(words) / (seconds / 60)).rounded())
    }

    /// "about three times faster than typing", "about twice as fast as typing"; nil when talking isn't clearly
    /// faster (under 1.5 times your typing speed).
    static func faster(pace: Int, typing: Int) -> String? {
        let r = Double(pace) / Double(max(1, typing))
        guard r >= 1.5 else { return nil }
        let n = Int(r.rounded())
        let words = [3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten"]
        if n <= 2 { return "about twice as fast as typing" }
        return "about \(words[n] ?? String(n)) times faster than typing"
    }

    /// The total in pages or novels: "about 12 pages", "about half a novel", "about 3 novels". Nil under a page.
    static func comparison(_ words: Int) -> String? {
        guard words >= pageWords else { return nil }
        let r = Double(words) / Double(novelWords)
        if r < 0.2 {
            let pages = Int((Double(words) / Double(pageWords)).rounded())
            return pages == 1 ? "about a page" : "about \(pages) pages"
        }
        if r < 0.35 { return "about a quarter of a novel" }
        if r < 0.75 { return "about half a novel" }
        if r < 1.5 { return "about a whole novel" }
        return "about \(Int(r.rounded())) novels"
    }

    /// "42s", "18m", "1h", "2h 14m" (the iPhone's This week card writes time saved the same way).
    static func duration(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded()))s" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    static var groupingSeparator: String { Locale.current.groupingSeparator ?? "," }

    /// "3,620" with the locale's grouping separator.
    static func number(_ n: Int, grouping: String) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out += grouping }
            out.append(c)
        }
        return n < 0 ? "-" + out : out
    }
}
