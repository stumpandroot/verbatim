import Foundation

// Thoughts on the iPhone (approved mockup "Thoughts", sections 05–08; DESIGN.md §14): the settings, when a thought
// from outside the app records in place or opens Verbose, day-to-day navigation, and the words the system surfaces
// show. Compiled into the app and the VerbatimWidgets extension. Pure Foundation, so the Linux tests compile it
// (mac/tools/test-thoughts.sh).

enum ThoughtRules {
    // MARK: Settings › Features › Thoughts

    /// Record without opening Verbose: on unless you turn it off. Off, every way in opens Verbose to the recorder.
    static let inPlaceKey = "thoughts.inPlace"
    /// Show words in the Dynamic Island: on unless you turn it off. Never on the Lock Screen either way.
    static let islandWordsKey = "thoughts.islandWords"

    static func inPlace(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: inPlaceKey) as? Bool ?? true }
    static func islandWords(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: islandWordsKey) as? Bool ?? true }

    // MARK: Starting a thought from outside the app

    /// What a widget, control, the Action button, Back Tap, or Siri does with New thought.
    enum Start: Equatable {
        /// Record in place, behind the Live Activity, without opening Verbose.
        case inPlace
        /// Stop the thought that's recording (New thought a second time).
        case stop
        /// Open Verbose straight to the recorder, for the reason given (logged).
        case openVerbose(String)
    }

    /// In place needs iOS 18 (`AudioRecordingIntent`), the setting on, the recording notice already seen, the
    /// microphone allowed, and nothing else holding the microphone. Anything missing opens Verbose instead, where
    /// the question can be asked or the other recording shown.
    static func start(recordingThought: Bool, inPlaceSetting: Bool, systemAllows: Bool, noticeSeen: Bool,
                      micAllowed: Bool, micBusy: Bool) -> Start {
        if recordingThought { return .stop }
        if !inPlaceSetting { return .openVerbose("Record without opening Verbose is off") }
        if !systemAllows { return .openVerbose("this iOS can't record from outside the app") }
        if !noticeSeen { return .openVerbose("the recording notice hasn't been seen") }
        if !micAllowed { return .openVerbose("the microphone isn't allowed yet") }
        if micBusy { return .openVerbose("another recording holds the microphone") }
        return .inPlace
    }

    // MARK: A day's page

    /// The days the arrows go to: the nearest earlier page with something on it, and the nearest later one (or
    /// today, which is always reachable). Next is off on today.
    static func neighbors(pages: [Date], current: Date, today: Date, calendar: Calendar = .current) -> (previous: Date?, next: Date?) {
        let cur = calendar.startOfDay(for: current), now = calendar.startOfDay(for: today)
        let days = Set(pages.map { calendar.startOfDay(for: $0) })
        let previous = days.filter { $0 < cur }.max()
        guard cur < now else { return (previous, nil) }
        let next = days.filter { $0 > cur && $0 <= now }.min() ?? now
        return (previous, next)
    }

    /// A thought that's still transcribing.
    static let transcribing = "Saved as audio. Transcribing…"
    /// A thought whose transcription failed: the audio is kept, with Transcribe again.
    static let failed = "Didn't transcribe. The audio is saved."
    static let transcribeAgain = "Transcribe again"
    /// A page with nothing on it.
    static let emptyPage = "Nothing on this page yet."
    static let emptyToday = "Nothing on today's page yet. Tap New thought and start talking."

    /// "Today · 6 thoughts", "Mon Oct 24 · 1 thought": the eyebrow over a page.
    static func eyebrow(dayLabel: String, isToday: Bool, count: Int) -> String {
        "\(isToday ? "Today" : dayLabel) · \(count == 1 ? "1 thought" : "\(count) thoughts")"
    }

    // MARK: System surfaces

    /// The Live Activity's title in the Dynamic Island.
    static let activityTitle = "New thought"
    /// The Lock Screen activity's headline (it never shows your words).
    static let lockTitle = "Recording a thought"
    /// The alert when a thought is saved.
    static let savedTitle = "Added to Thoughts"
    /// How long "Added to Thoughts" shows before the activity ends.
    static let savedSeconds: TimeInterval = 2

    /// "Into Thoughts · Mon, Oct 26": where the thought goes.
    static func intoLine(_ pageTitle: String) -> String { "Into \(pageTitle)" }

    /// The rectangular Lock Screen widget: today's count, never the words. "6 today", "None yet today".
    static func lockCount(_ n: Int) -> String { n <= 0 ? "None yet today" : "\(n) today" }

    // MARK: Settings › Features › Thoughts statuses

    /// Widgets: how many of Verbose's thought widgets are on the Home Screen and Lock Screen.
    static func widgetStatus(_ n: Int) -> String { n <= 0 ? "Not added" : "\(n) added" }
    /// Control Center: added or not; nil when iOS can't say (before iOS 18, which has no controls).
    static func controlStatus(_ added: Bool?) -> String {
        guard let added else { return "Needs iOS 18" }
        return added ? "Added" : "Not added"
    }
    /// The Action button and Back Tap: iOS doesn't tell apps what they do, so the row offers setup instead.
    static let undetectable = "Set up"
    /// The thought widgets' kinds (HomeWidgets.swift): New thought (the Quick capture widget's kind), Today's thoughts,
    /// and the Lock Screen's. mac/tools/test-thoughts.sh checks they match the widgets.
    static let widgetKinds: Set<String> = ["co.stumpandroot.verbatim.widget.capture", "co.stumpandroot.verbatim.widget.thoughts",
                                           "co.stumpandroot.verbatim.ios.widget.thoughtsLock"]
    /// The New thought control's kind (StartSessionWidgets.swift).
    static let controlKind = "co.stumpandroot.verbatim.ios.control.thought"
    /// Siri: an App Shortcut, ready as soon as Verbose is installed.
    static let siriStatus = "Ready"
    /// What you say to Siri.
    static let siriPhrase = "New thought in Verbose"
}

/// Starting a recording in place from an `AudioRecordingIntent`: New thought, Record from a widget, and the Action
/// button's voice note (`PhoneState.startThoughtInPlace`, `startVoiceNoteInPlace`). On iOS 27, AppIntents stops the
/// app with an assertion ("performed with an active audio session but without a Live Activity") when the audio
/// session turns on during such an intent before its Live Activity shows. So the Live Activity always starts first. Without one, the microphone is never touched and
/// Verbose opens to the recorder instead; a recording that then fails to start takes its Live Activity with it.
/// Pure, so the Linux tests check the order (mac/tools/test-thoughts.sh).
enum InPlaceRecording {
    enum Outcome: Equatable {
        /// Recording, behind its Live Activity.
        case recording
        /// Nothing is recording and no Live Activity is left: open Verbose to the recorder, for the reason given (logged).
        case openVerbose(String)
    }

    static func start(startActivity: () -> Bool, startRecording: () -> Bool, endActivity: () -> Void) -> Outcome {
        guard startActivity() else { return .openVerbose("its Live Activity didn't start") }
        guard startRecording() else {
            endActivity()
            return .openVerbose("the recording didn't start")
        }
        return .recording
    }
}
