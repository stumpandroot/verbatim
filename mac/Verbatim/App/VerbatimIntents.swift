import AppKit
import AppIntents
import UniformTypeIdentifiers

// Shortcuts actions for the Mac app: transcribe a file, get the last dictation, start a recording, get a transcript's
// text by search, and Copy for AI. They run in Verbatim's process and talk to the running app (SystemHooks). The
// iPhone's own shortcuts (VerbatimPhone/KeyboardSessionShortcuts.swift) stay separate: different targets, different
// providers.

enum VerbatimIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case noMatch(String)
    case nothingYet
    case failed(String)
    case unreadableFile

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: return "Verbose didn't finish opening. Try again."
        case .noMatch(let q): return "No transcript matches “\(q)”."
        case .nothingYet: return "There's nothing in Verbose yet."
        case .failed(let why): return "Transcription didn't finish: \(why)"
        case .unreadableFile: return "Verbose couldn't read that file."
        }
    }
}

@MainActor
enum IntentLookup {
    static func app() async throws -> AppState {
        guard let app = await SystemHooks.waitForApp() else { throw VerbatimIntentError.notRunning }
        return app
    }

    /// The best match for a search: a title match first, then the words, newest first. Finished transcripts only.
    static func find(_ query: String, in app: AppState) -> Transcript? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ready = app.store.live.filter { $0.status == .ready }.sorted { $0.createdAt > $1.createdAt }
        guard !q.isEmpty else { return ready.first { !$0.isDictation } ?? ready.first }
        return ready.first { $0.title.lowercased().contains(q) } ?? ready.first { app.store.searchText($0).contains(q) }
    }

    /// The text a transcript action returns: the Cleaned tab's when it has its own, else the Original.
    static func text(_ t: Transcript) -> String { Exporter.copyText(t, t.hasCleanedText ? .cleaned : .original) }
}

/// Transcribes an audio or video file on this Mac and returns the text when it's done.
struct TranscribeFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe a file"
    static let description = IntentDescription("Transcribes an audio or video file on this Mac and returns the text. The file is added to your Library.")

    // supportedTypeIdentifiers: supportedContentTypes needs macOS 15.
    @Parameter(title: "File", supportedTypeIdentifiers: ["public.audio", "public.movie"])
    var file: IntentFile

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = try await IntentLookup.app()
        let url: URL
        if let u = file.fileURL, FileManager.default.fileExists(atPath: u.path) {
            url = u
        } else {
            // Shortcuts handed over data without a file on disk: write it next to the downloads, under its name.
            let dir = Paths.downloads.appendingPathComponent("Shortcuts-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent(file.filename.isEmpty ? "Recording.m4a" : file.filename)
            do { try file.data.write(to: url) } catch { throw VerbatimIntentError.unreadableFile }
        }
        guard let id = app.importFiles([url], useLibraryProject: false, announce: false).first?.0 else { throw VerbatimIntentError.unreadableFile }
        Log.note("intent: transcribe a file")
        // Waits for the queue (one transcription runs at a time), for up to 12 hours.
        for _ in 0..<(12 * 3600) {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let t = app.store.transcript(id), t.deletedAt == nil else { throw VerbatimIntentError.failed("it was deleted.") }
            if t.status == .failed { throw VerbatimIntentError.failed(t.error ?? "unknown error.") }
            if t.status == .ready, t.pendingAppend == nil { return .result(value: IntentLookup.text(t)) }
        }
        throw VerbatimIntentError.failed("it's still in the queue. It appears in your Library when it's done.")
    }
}

/// The text of your most recent dictation, as it was pasted.
struct GetLastDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Get the last dictation"
    static let description = IntentDescription("Returns the text of your most recent dictation, as it was pasted.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = try await IntentLookup.app()
        let last = app.store.live.filter { $0.isDictation && $0.status == .ready }.max { $0.createdAt < $1.createdAt }
        guard let last else { throw VerbatimIntentError.nothingYet }
        let text = last.flow?.pasted.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .result(value: text.isEmpty ? last.text : text)
    }
}

/// Starts a voice memo recording.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start recording"
    static let description = IntentDescription("Opens Verbose and starts recording a voice memo.")
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await IntentLookup.app()
        app.requestRecord()
        return .result()
    }
}

/// A transcript's text, found by searching titles and words.
struct GetTranscriptTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get a transcript's text"
    static let description = IntentDescription("Finds a transcript by its title or words and returns its text. Leave the search empty for the newest transcript.")

    @Parameter(title: "Search", default: "")
    var query: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = try await IntentLookup.app()
        guard let t = IntentLookup.find(query, in: app) else {
            throw query.isEmpty ? VerbatimIntentError.nothingYet : VerbatimIntentError.noMatch(query)
        }
        return .result(value: IntentLookup.text(t))
    }
}

/// Copy for AI: copies a transcript with its header (title, date, duration, speakers, source, language).
struct CopyForAIIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy a transcript for AI"
    static let description = IntentDescription("Copies a transcript with a short header (title, date, duration, speakers, source, and language) for pasting into an AI assistant, and returns it. Leave the search empty for the newest transcript.")

    @Parameter(title: "Search", default: "")
    var query: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = try await IntentLookup.app()
        guard let t = IntentLookup.find(query, in: app) else {
            throw query.isEmpty ? VerbatimIntentError.nothingYet : VerbatimIntentError.noMatch(query)
        }
        let text = t.copyForAI
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return .result(value: text)
    }
}

/// Siri, Spotlight, and the Shortcuts app on the Mac.
struct VerbatimMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TranscribeFileIntent(),
                    phrases: ["Transcribe a file with \(.applicationName)", "Transcribe with \(.applicationName)"],
                    shortTitle: "Transcribe a file",
                    systemImageName: "doc.text")   // brand: system surface
        AppShortcut(intent: GetLastDictationIntent(),
                    phrases: ["Get my last \(.applicationName) dictation", "What did I last dictate in \(.applicationName)"],
                    shortTitle: "Last dictation",
                    systemImageName: "text.cursor")   // brand: system surface
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording in \(.applicationName)", "Record a voice memo with \(.applicationName)"],
                    shortTitle: "Start recording",
                    systemImageName: "mic")   // brand: system surface
        AppShortcut(intent: GetTranscriptTextIntent(),
                    phrases: ["Get a transcript from \(.applicationName)"],
                    shortTitle: "Get transcript text",
                    systemImageName: "text.magnifyingglass")   // brand: system surface
        AppShortcut(intent: CopyForAIIntent(),
                    phrases: ["Copy a \(.applicationName) transcript for AI"],
                    shortTitle: "Copy for AI",
                    systemImageName: "doc.on.clipboard")   // brand: system surface
    }
}
