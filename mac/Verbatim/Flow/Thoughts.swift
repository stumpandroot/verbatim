import SwiftUI
import AppKit
import AVFoundation
import Combine

// Thoughts (approved mockup "Thoughts", October 26, 2026; DESIGN.md §14). A thought is a recording of the Thoughts kind
// (raw value `idea`, so synced files and older builds still read it), and a day's page is every Thoughts recording that
// started that day, in time order (Model/DayPages.swift). So audio, Transcribe again, sync, and delete are the ones
// every recording has. Copy and Send act on the whole day.
//
// Never lose a thought: the audio is written to disk as it records; Stop adds the thought to its day, with its time,
// before transcription starts ("Saved as audio. Transcribing…"); the words fill in when they're ready; and a failed
// transcription keeps the audio with Transcribe again. A marker beside the recording (RecordingSafety.swift) makes a
// thought the app quit in the middle of come back as a thought.

/// Settings › Features › Thoughts, and the words a thought shows.
enum Thoughts {
    /// Settings › Features › Thoughts › Show the bubble (also in the menu bar's Thoughts group). Off on a new install
    /// (consolidation, October 28, 2026); an install from before keeps what it had (ConsolidationMac).
    static let bubbleKey = "thoughts.showBubble"
    static let bubbleDefault = false
    static var showBubble: Bool {
        get { UserDefaults.standard.object(forKey: bubbleKey) as? Bool ?? bubbleDefault }
        set { UserDefaults.standard.set(newValue, forKey: bubbleKey); refreshBubble() }
    }
    /// The setter is nonisolated; the bubble is main-actor. On the main thread (every caller today) it refreshes at once.
    private static func refreshBubble() {
        if Thread.isMainThread { MainActor.assumeIsolated { ThoughtBubble.shared.refresh() } }
        else { Task { @MainActor in ThoughtBubble.shared.refresh() } }
    }
    /// The hotkey, for menus, hints, and Settings. Fixed: ⌃⌥P starts and stops a thought from any app.
    static let hotkey = "⌃⌥P"
    /// Where a thought recorded on this Mac came from, in its meta line ("Mac").
    static let macSource = "Thought · Mac"
    static let padSource = "Thought pad"

    /// The hour a new page starts (Settings › Features › Thoughts › New page each day at).
    static var newPageHour: Int { DayPages.storedHour() }

    /// A thought's words: what you edited or the cleaned text when there is one, else what was heard.
    static func words(_ t: Transcript) -> String { ThoughtText.words(t) }

    /// "Mac", "iPhone", or "Apple Watch": where it was recorded, in the sans meta line under a thought.
    static func origin(_ t: Transcript) -> String { ThoughtText.origin(t) }

    /// "9:40" (`native: false`, like a transcript's timecode) or "9:40 AM" (`native: true`, the system's short time).
    static func time(_ date: Date, native: Bool) -> String { ThoughtText.time(date, native: native) }

    /// The page's words for Copy and Send, a blank line between thoughts.
    static func joined(_ page: [Transcript]) -> String { ThoughtText.joined(page) }

    /// "Thoughts" or "Journal" for a by-day kind.
    static func pageName(_ kind: RecordingKind) -> String { kind == .journal ? "Journal" : "Thoughts" }
}

// The library's pages (`Store.dayPages`, `page`, `todaysThoughts`) are in Model/ThoughtPages.swift, shared with the iPhone.

/// Recording a thought: from the bubble, ⌃⌥P, the menu bar, today's page, the Library, or a desktop widget. Its own
/// recorder (a normal recording's, released on Stop), so a dictation or a voice memo is never touched. Nothing here
/// activates Verbose or takes focus from the app you're in.
@MainActor
final class ThoughtCapture: ObservableObject {
    static let shared = ThoughtCapture()
    enum Phase: Equatable { case idle, recording, saved(Date) }
    @Published private(set) var phase: Phase = .idle
    /// A one-line notice for the bubble (a mic problem); cleared after a few seconds.
    @Published private(set) var notice: String?
    /// When the thought being recorded started (it belongs to that day).
    @Published private(set) var startedAt: Date?
    /// The thought added last, outlined on today's page until the page opens again.
    @Published var lastAdded: UUID?

    let recorder = Recorder()
    /// Your words on the bubble's card while you speak (a preview; the saved words come from the full engine).
    let words = RecordingWords()
    private(set) weak var app: AppState?
    private var url: URL?
    private var savedTimer: DispatchWorkItem?
    private var noticeTimer: DispatchWorkItem?
    /// Stop was clicked and the recording is being saved; another click waits for it.
    private var stopping = false
    /// The self-test records simulated audio instead of opening the mic.
    var simulate = false

    var isRecording: Bool { phase == .recording }

    /// The desktop widget's New thought (VerbatimWidgets/HomeWidgets.swift) asks the running app by name, so the
    /// app you're in stays in front. Any app could post it, as any app can open verbatim://record; the bubble shows
    /// the recording either way.
    static let widgetRequest = Notification.Name("co.stumpandroot.verbatim.newThought")
    private var widgetObserver: NSObjectProtocol?

    func attach(_ app: AppState) {
        self.app = app
        widgetObserver = DistributedNotificationCenter.default().addObserver(forName: Self.widgetRequest, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThoughtCapture.shared.toggle() }
        }
        // Pad pieces become Thoughts once the library has loaded (once only), and the bubble comes up.
        app.store.whenLoaded { [weak self] in
            guard let self, let app = self.app else { return }
            ThoughtPadMigration.run(app.store)
            ThoughtBubble.shared.attach(self)
        }
    }

    /// Starts a thought, or stops the one recording.
    func toggle() { if isRecording { stop() } else { start() } }

    func start() {
        guard let app, !isRecording else { return }
        if simulate { begin(at: Date()); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in if ok { self.start() } else { self.say("Verbose can't hear you: microphone access is off") } }
            }
            return
        default:
            say("Verbose can't hear you: microphone access is off")
            return
        }
        let url = app.store.newRecordingURL()
        Store.markThought(url)
        self.url = url
        let started = Date()
        begin(at: started)
        words.begin(recorder)
        recorder.begin(to: url) { [weak self] error in
            guard let self else { return }
            if let error {
                Store.clearThoughtMark(url)
                self.url = nil
                self.phase = .idle
                self.startedAt = nil
                self.say(error.localizedDescription)
                return
            }
            Sounds.start()
        }
        Log.note("thought: recording")
    }

    private func begin(at date: Date) {
        savedTimer?.cancel()
        startedAt = date
        phase = .recording
    }

    func stop() {
        guard isRecording, !stopping else { return }
        let started = startedAt ?? Date()
        if simulate {
            phase = .idle
            simulatedStop(started: started)
            return
        }
        stopping = true
        Task {
            await finish(started: started)
            stopping = false
        }
    }

    /// Stop: the recording is saved, then the thought joins its day at once, and transcription follows.
    private func finish(started: Date) async {
        // Moments marked while it recorded (⌃⌥B, the bubble's Mark): bookmarks on the thought.
        let marks = MarkCenter.shared.take(.thought)
        let stopped = await recorder.stopAndSave()
        words.end()
        let marked = url
        url = nil
        guard let r = stopped else {
            // Stopped while the mic was still starting: nothing was recorded.
            if let marked { Store.clearThoughtMark(marked) }
            phase = .idle; startedAt = nil
            return
        }
        if r.joinFailed {
            // Every part stays in the recordings folder, with the marker: launch recovery adds it as a thought.
            phase = .idle; startedAt = nil
            say(Store.joinFailedNotice)
            return
        }
        if let marked { Store.clearThoughtMark(marked); Marks.clear(marked) }
        Store.clearThoughtMark(r.startedAs ?? r.url)
        Marks.clear(r.startedAs ?? r.url)
        guard r.framesWritten > 0 else {
            try? FileManager.default.removeItem(at: r.url)
            phase = .idle; startedAt = nil
            say(Store.nothingRecordedNotice)
            return
        }
        file(url: r.url, duration: r.duration, envelope: r.envelope, startedAt: started, skipped: r.skipped, marks: marks)
    }

    /// Adds a recorded thought to its day and queues it to transcribe. Returns its ID.
    @discardableResult
    func file(url: URL, duration: Double, envelope: [Float], startedAt: Date, skipped: [ClosedRange<Double>] = [], marks: [RecordingMark] = []) -> UUID? {
        guard let app, let name = app.store.adoptRecording(url) else {
            if !isRecording || stopping { phase = .idle; self.startedAt = nil }
            say("Couldn't save the thought. Its audio is in the recordings folder.")
            return nil
        }
        var t = Transcript(title: "Thought", source: .voiceMemo, sourceLabel: Thoughts.macSource, duration: duration, audioFileName: name, model: "")
        t.createdAt = startedAt
        t.kind = .idea
        t.kindIsAuto = false
        t.waveform = envelope
        t.notes = Store.skippedNotes(skipped) + RecordingMark.notes(marks)
        app.enqueue(t)
        lastAdded = t.id
        Log.note("thought: added \(String(format: "%.1f", duration)) s; transcribing")
        // A dictation handed over while a thought records (today's page open) leaves that recording alone.
        if !isRecording || stopping || simulate { showSaved(startedAt) }
        return t.id
    }

    private func showSaved(_ date: Date) {
        phase = .saved(date)
        self.startedAt = nil
        let w = DispatchWorkItem { [weak self] in if case .saved = self?.phase { self?.phase = .idle } }
        savedTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    /// The self-test's stand-in for the mic: a short tone, saved and filed as a recording would be.
    private func simulatedStop(started: Date) {
        guard let app else { return }
        let url = app.store.newRecordingURL()
        let seconds = 1.5
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        if let file = try? AVAudioFile(forWriting: url, settings: format.settings),
           let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds)) {
            buf.frameLength = buf.frameCapacity
            for i in 0..<Int(buf.frameLength) { buf.floatChannelData?[0][i] = 0.2 * sin(Float(i) * 2 * .pi * 220 / 16_000) }
            try? file.write(from: buf)
        }
        file(url: url, duration: seconds, envelope: Array(repeating: 0.4, count: 120), startedAt: started)
    }

    /// A short notice on the bubble, or on the dictation surface when the bubble is hidden.
    func say(_ text: String) {
        noticeTimer?.cancel()
        notice = text
        if !ThoughtBubble.shared.isShowing { app?.dictation.bar?.flash(text, seconds: 5, tone: .error) }
        let w = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    // MARK: The page

    /// A thought you typed or edited: its words go in the edited layer, so what was heard stays.
    func edit(_ id: UUID, to text: String) {
        app?.store.updateDeferred(id) { t in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            t.document = trimmed
            t.documentEdited = true
            if t.audioFileName == nil { t.segments = [Segment(start: 0, end: 0, text: trimmed)]; t.original = t.segments }
        }
    }

    /// Moves a thought to Recently Deleted (restore it from there).
    func delete(_ id: UUID) { app?.store.moveToTrash(id) }
}

/// The Thought pad's saved pieces (thoughtpad.json) become text-only Thoughts recordings, dated by each piece's
/// `createdAt`, once: each takes its piece's ID (a second run can't add one twice), and the file is renamed after.
@MainActor
enum ThoughtPadMigration {
    static let doneKey = "thoughts.padMigrated"
    nonisolated static var file: URL {
        Paths.local.appendingPathComponent(ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1" ? "thoughtpad-uitest.json" : "thoughtpad.json")
    }

    /// A text-only Thoughts recording: no audio, one line of words, ready.
    static func textThought(_ text: String, at date: Date, source: String, id: UUID = UUID(), title: String? = nil) -> Transcript {
        var t = Transcript(title: title ?? Transcript.titleFrom([Segment(start: 0, end: 0, text: text)]) ?? "Thought",
                           source: .voiceMemo, sourceLabel: source, duration: 0, audioFileName: nil, model: "")
        t.id = id
        t.createdAt = date
        t.kind = .idea
        t.kindIsAuto = false
        t.titleIsAuto = title == nil
        t.segments = [Segment(start: 0, end: 0, text: text)]
        t.original = t.segments
        t.status = .ready
        return t
    }

    /// Moves the pad's pieces into Thoughts. Returns how many it added.
    @discardableResult
    static func run(_ store: Store, from url: URL = file, defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        guard let data = try? Data(contentsOf: url) else { defaults.set(true, forKey: doneKey); return 0 }
        guard let pad = PadMigration.read(data) else {
            Log.note("thoughts: the Thought pad's file couldn't be read; left as it is")
            defaults.set(true, forKey: doneKey)
            return 0
        }
        let existing = Set(store.transcripts.map(\.id))
        let todo = PadMigration.pending(pad.pieces, existing: existing)
        for p in todo {
            store.add(textThought(p.text, at: p.createdAt, source: Thoughts.padSource, id: p.id, title: pad.title.isEmpty ? nil : pad.title))
        }
        store.waitForWrites()
        let done = url.deletingLastPathComponent().appendingPathComponent(PadMigration.doneName(url.lastPathComponent))
        try? FileManager.default.removeItem(at: done)
        try? FileManager.default.moveItem(at: url, to: done)
        defaults.set(true, forKey: doneKey)
        Log.note("thoughts: moved \(todo.count) Thought pad piece\(todo.count == 1 ? "" : "s") into Thoughts")
        return todo.count
    }
}
