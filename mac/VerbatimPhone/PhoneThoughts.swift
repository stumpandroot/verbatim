import SwiftUI
import AVFoundation
import UIKit

// Thoughts on the iPhone (approved mockup "Thoughts", sections 05–08; DESIGN.md §14). A thought is a recording of the
// Thoughts kind (raw value `idea`), exactly as on the Mac, and a day's page is every one that started that day
// (Model/DayPages.swift, Model/ThoughtPages.swift). The thought records with the voice note's recorder, so its Live
// Activity, interruptions, and the full-screen recorder are the voice note's; only where it lands differs.
//
// Never lose a thought: the audio is written as it records, with a `.thought` marker beside it so launch recovery
// brings a thought the app was closed in the middle of back as a thought (Store.swift); Stop adds it to its day, with
// its time, before transcription starts ("Saved as audio. Transcribing…"); a failed transcription keeps the audio and
// offers Transcribe again.
//
// Settings › Features › Thoughts › New page each day at is per device: settings don't sync between the Mac and the
// iPhone (only the library does), so each keeps its own boundary under the same key.

/// A day's page in the Library stack: Thoughts or Journal on `day` (the start of that calendar day).
struct DayPageRoute: Hashable { var kind: RecordingKind = .idea; var day: Date }
/// Library › By day, on Thoughts or Journal.
struct ByDayRoute: Hashable { var kind: RecordingKind }

extension PhoneState {
    /// Where a thought recorded on this iPhone came from, in its meta line ("iPhone").
    static let thoughtSource = "Thought · iPhone"

    /// The hour a new page starts (Settings › Features › Thoughts › New page each day at).
    var newPageHour: Int { DayPages.storedHour() }
    /// Today's page (the start of its calendar day).
    var todayPage: Date { DayPages.today(hour: newPageHour) }

    /// "Thoughts · Mon, Oct 26": a day's page title, as the page and the Live Activity show it.
    static func thoughtPageTitle(_ day: Date) -> String { DayPages.title("Thoughts", day: day) }

    // MARK: Recording

    /// New thought in the app (today's page, Library, a widget that opened Verbose): the recorder opens on a
    /// thought. A recording already running comes back instead.
    func requestThought() {
        guard !recordingActive else { requestRecord(); return }
        pendingThought = true
        requestRecord()
    }

    /// Called by `startRecording` once the recorder runs: marks a thought that was asked for.
    func beginThoughtIfAsked(_ url: URL) {
        guard pendingThought else { recordingThought = false; thoughtStartedAt = nil; return }
        pendingThought = false
        recordingThought = true
        thoughtStartedAt = Date()
        Store.markThought(url)
        Log.note("thought: recording")
    }

    /// What New thought from outside the app does now (`ThoughtRules.start`).
    func thoughtStartDecision() -> ThoughtRules.Start {
        var systemAllows = false
        if #available(iOS 18.0, *) { systemAllows = true }
        return ThoughtRules.start(recordingThought: recordingThought && recorder.isRecording,
                                  inPlaceSetting: ThoughtRules.inPlace(), systemAllows: systemAllows,
                                  noticeSeen: UserDefaults.standard.bool(forKey: Self.consentNoticeKey),
                                  micAllowed: AVAudioApplication.shared.recordPermission == .granted,
                                  micBusy: recordingActive || showCaptions)
    }

    /// New thought from a widget, control, the Action button, Back Tap, or Siri with Verbose in the background
    /// (iOS 18 and later, `AudioRecordingIntent`): starts the thought and its Live Activity in place. True when both
    /// started. False otherwise; the intent then opens Verbose, where the recorder shows the thought if it began.
    func startThoughtInPlace() -> Bool {
        guard case .inPlace = thoughtStartDecision() else { return false }
        pendingThought = true
        startRecording()
        guard recorder.isRecording, recordingThought else { pendingThought = false; return false }
        guard RecordingPresence.shared.startActivityNow() else {
            Log.note("new thought: recording, but its Live Activity didn't start; opening Verbose")
            return false
        }
        return true
    }

    /// New thought a second time, or Stop: the thought joins today's page.
    func stopThought() {
        guard recordingThought, recorder.isRecording else { return }
        stopRecording()
    }

    /// Adds a recorded thought to its day at once and queues it to transcribe. Returns its ID. The self-test files a
    /// simulated recording through here too.
    @discardableResult
    func fileThought(url: URL, duration: Double, envelope: [Float], startedAt: Date, skipped: [ClosedRange<Double>] = [],
                     moments: [RecordingMoment] = []) -> UUID? {
        guard let name = store.adoptRecording(url) else {
            say("Couldn't save the thought. Its audio is kept in Verbose's recordings folder.")
            return nil
        }
        var t = Transcript(title: "Thought", source: .voiceMemo, sourceLabel: Self.thoughtSource, duration: duration, audioFileName: name, model: "")
        t.createdAt = startedAt
        t.kind = .idea
        t.kindIsAuto = false
        t.waveform = envelope
        t.notes = Store.skippedNotes(skipped) + RecordingMoment.notes(moments)
        coordinator.enqueue(t)
        lastThought = t.id
        Log.note("thought: added \(String(format: "%.1f", duration)) s; transcribing")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if UIApplication.shared.applicationState == .active { say(ThoughtRules.savedTitle) }
        return t.id
    }

    // MARK: The page

    /// A thought you typed over: its words go in the edited layer, so what was heard stays.
    func editThought(_ id: UUID, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(id) { t in
            t.document = trimmed
            t.documentEdited = true
            if t.audioFileName == nil { t.segments = [Segment(start: 0, end: 0, text: trimmed)]; t.original = t.segments }
        }
    }

    /// Opens a day's Thoughts page in Library (today's from a widget or the Live Activity).
    func openThoughtPage(_ day: Date? = nil) {
        tab = .library
        var path = NavigationPath()
        path.append(DayPageRoute(kind: .idea, day: day ?? todayPage))
        libraryPath = path
    }
}

/// The thought added last, outlined on its page until the page opens again. Kept outside PhoneState's published
/// values so filing a thought doesn't re-render every screen.
extension PhoneState {
    private static var lastThoughtID: UUID?
    var lastThought: UUID? {
        get { Self.lastThoughtID }
        set { Self.lastThoughtID = newValue }
    }
}

/// Hands New thought from `NewThoughtIntent` to the app. The intent can run before the app has set up (a cold launch),
/// so a request that arrives first waits until `PhoneState` attaches.
@MainActor
enum ThoughtSignal {
    private static weak var app: PhoneState?
    private static var pending = false

    static func attach(_ a: PhoneState) {
        app = a
        guard pending else { return }
        pending = false
        DispatchQueue.main.async { a.requestThought() }
    }

    static func decide() -> ThoughtRules.Start { app?.thoughtStartDecision() ?? .openVerbose("Verbose is still starting") }
    static func startInPlace() -> Bool { app?.startThoughtInPlace() ?? false }
    static func stop() { app?.stopThought() }

    /// With Verbose in front: the recorder opens on a thought.
    static func fire() {
        if let app { app.requestThought() } else { pending = true }
    }
}
