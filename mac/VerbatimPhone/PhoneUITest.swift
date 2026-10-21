import SwiftUI
import AVFoundation
import UIKit

/// Screenshot tour for CI. With VERBATIM_UITEST=1 the app seeds sample transcripts, walks its screens, and
/// writes each screen's name to Documents/show.txt; the CI job captures the simulator when the name changes.
@MainActor
enum PhoneUITest {
    static let enabled = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1"
    static var onboardingStep = 0

    static func run(_ app: PhoneState) {
        seed(app)
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            for (prefix, mode) in [("p", "light"), ("d", "dark")] {
                app.appearance = mode
                app.tab = .home
                try? await Task.sleep(nanoseconds: 600_000_000)
                await show("\(prefix)01-home")
                app.showRecorder = true
                await show("\(prefix)02-record")
                app.showRecorder = false
                try? await Task.sleep(nanoseconds: 600_000_000)
                // Live captions with made-up lines (no microphone or speech in UI test mode).
                app.requestCaptions()
                await show("\(prefix)02b-live-captions")
                if prefix == "p" {
                    app.captions.flipped = true
                    await show("p02c-live-captions-flipped")
                }
                app.stopCaptions(save: false)
                try? await Task.sleep(nanoseconds: 600_000_000)
                app.showLinkSheet = true
                await show("\(prefix)03-link")
                app.showLinkSheet = false
                try? await Task.sleep(nanoseconds: 600_000_000)
                // The "link added" card with made-up data (nothing here touches the network).
                let card = LinkImport(id: UUID(), url: "https://www.youtube.com/watch?v=Q7r2mDn4x1k", site: "YouTube")
                card.title = "How we light interviews in small rooms"; card.duration = 3852
                card.phase = .downloading; card.progress = 0.42
                app.linkCardImport = card
                await show("\(prefix)03b-link-card")
                app.linkCardImport = nil
                try? await Task.sleep(nanoseconds: 400_000_000)
                // Transcribe what's playing: the sheet, with the system broadcast picker behind Start.
                app.showPlayingSheet = true
                await show("\(prefix)03c-whats-playing")
                app.showPlayingSheet = false
                try? await Task.sleep(nanoseconds: 700_000_000)
                if prefix == "p" {
                    // A file shared to Verbatim: a generated clip seeded into the App Group inbox, then imported the way
                    // a launch does. The "added" card lands on the Library tab, where the new row shows.
                    seedInbox()
                    app.importInbox()
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    app.tab = .library
                    await show("p03d-inbox-import")
                    app.tab = .home
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                app.tab = .library
                await show("\(prefix)04-library")
                app.libraryPath.append(DictationsRoute())
                await show("\(prefix)04d-dictations")
                app.libraryPath = NavigationPath()
                try? await Task.sleep(nanoseconds: 500_000_000)
                app.libraryFilterRequest = "journal"
                await show("\(prefix)04b-library-journal")
                app.libraryFilterRequest = "idea"
                await show("\(prefix)04c-library-ideas")
                if let walk = app.store.live.first(where: { $0.title == "Errands and a long walk" }) {
                    UserDefaults.standard.set(true, forKey: Transcript.mainSpeakerOnlyKey)
                    app.libraryPath.append(walk.id)
                    await show("\(prefix)05b-background-voices")
                    app.libraryPath = NavigationPath()
                    UserDefaults.standard.set(false, forKey: Transcript.mainSpeakerOnlyKey)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                app.libraryFilterRequest = "all"
                if let rich = app.store.live.first(where: { $0.title == "Lapp Wagons catalog call" }) {
                    app.libraryPath.append(rich.id)
                    await show("\(prefix)05-transcript")
                    // The export sheet with the options a meeting export would use.
                    let keep = ExportOptions.saved
                    var o = keep; o.header = true; o.timecodeMode = .everyParagraph; o.moments = .end; o.speakerMode = .onChange; o.save()
                    ExportOptions.savedFormat = .txt
                    app.exportRequest = PhoneExportRequest(ids: [rich.id])
                    await show("\(prefix)05c-export")
                    app.exportRequest = nil
                    keep.save()
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    app.libraryPath = NavigationPath()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    app.tab = .home
                    app.homePath.append(DocumentRoute(id: rich.id))
                    await show("\(prefix)06-document")
                    app.homePath = NavigationPath()
                }
                if let link = app.store.live.first(where: { $0.title == "Folding wagon walkthrough" }) {
                    app.tab = .library
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    app.libraryPath.append(link.id)
                    await show("\(prefix)07-link-transcript")
                    app.libraryPath = NavigationPath()
                }
                app.tab = .moments
                await show("\(prefix)08-moments")
                app.tab = .settings
                await show("\(prefix)09-settings")
                SettingsSearchModel.shared.query = "keyboard"
                await show("\(prefix)09b-settings-search")
                SettingsSearchModel.shared.query = ""
                // Settings › Your voice, step 2, with made-up progress (no microphone in the simulator).
                NotificationCenter.default.post(name: .verbatimShowVoiceProfile, object: true)
                await show("\(prefix)09c-voice-enroll")
                NotificationCenter.default.post(name: .verbatimShowVoiceProfile, object: false)
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            app.appearance = "light"
            for i in 0..<3 {
                onboardingStep = i
                app.showOnboarding = true
                await show("p1\(i)-onboarding")
                app.showOnboarding = false
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            onboardingStep = 0
            app.appearance = "system"
            write("done")
            Log.note("UITEST phone tour done")
        }
    }

    private static func show(_ name: String) async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // let presentations settle
        snapshot(name)
        write(name)
        Log.note("UITEST show \(name)")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    /// Renders the key window (sheets and covers included) into Documents/screens/<name>.png. The app takes
    /// its own screenshots so they match the screen exactly, with no timing race against the CI runner.
    private static func snapshot(_ name: String) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let w = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        let img = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in _ = w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("screens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? img.pngData()?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private static func write(_ name: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("show.txt")
        try? (name + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func seed(_ app: PhoneState) {
        let store = app.store
        guard !store.transcripts.contains(where: { $0.title == "Lapp Wagons catalog call" }) else { return }
        let project = store.projects.first { $0.name == "Lapp Wagons" } ?? store.addProject("Lapp Wagons")
        store.dictionary.append(DictionaryEntry(preferred: "Lititz", heardAs: ["Lit it's", "Lititz's"], learnedFrom: "Added by you"))

        var link = Transcript(title: "Folding wagon walkthrough", source: .link, sourceLabel: "youtube.com", duration: 412, audioFileName: nil, model: "Parakeet TDT v3")
        link.sourceURL = "https://www.youtube.com/watch?v=ab12cd34ef5"
        link.link = LinkInfo(url: "https://www.youtube.com/watch?v=ab12cd34ef5", site: "YouTube", channel: "Lapp Wagons", uploadDate: "20260912")
        link.segments = [Segment(start: 0, end: 6, text: "This is the folding wagon, and here's how it folds flat for the truck."),
                         Segment(start: 6, end: 13, text: "Two latches on the side, lift the bed, and the wheels tuck under.")]
        link.original = link.segments
        link.createdAt = Date().addingTimeInterval(-86_400 * 2)
        store.add(link)
        store.addNote(Note(text: "Latches on the side; good close-up for the catalog.", at: 7, segmentId: link.segments[1].id), to: link.id)

        // Link rows only; nothing here touches the network (PhoneState skips link fetches in UITest mode).
        // One handed to the Mac (a site the iPhone can't fetch), and one downloading on this iPhone.
        var queued = Transcript(title: "https://example.com/talks/417", source: .link, sourceLabel: "example.com", duration: 0, audioFileName: nil, model: "")
        queued.sourceURL = "https://example.com/talks/417"; queued.status = .processing; queued.pendingLink = true
        store.add(queued)

        var downloading = Transcript(title: "Wheelwright at work", source: .link, sourceLabel: "vimeo.com", duration: 0, audioFileName: nil, model: "")
        downloading.sourceURL = "https://vimeo.com/123456789"; downloading.status = .processing; downloading.stage = "Downloading 42%"
        downloading.link = LinkInfo(url: "https://vimeo.com/123456789", site: "Vimeo", channel: "Lancaster Crafts")
        downloading.processingDevice = Device.id; downloading.processingDeviceName = Device.name
        store.add(downloading)

        var onMac = Transcript(title: "Dealer call, Lititz", source: .file, sourceLabel: "M4A file", duration: 1260, audioFileName: "dealer.m4a", model: "")
        onMac.status = .processing; onMac.processingDevice = "mac-device"; onMac.processingDeviceName = "Tim's MacBook Pro"
        onMac.createdAt = Date().addingTimeInterval(-3600)
        store.add(onMac)

        let url = store.newAudioURL(ext: "wav")
        writeToneFile(url, seconds: 42)
        var t = Transcript(title: "Lapp Wagons catalog call", source: .voiceMemo, sourceLabel: "Voice memo", duration: 42, audioFileName: url.lastPathComponent, model: "Parakeet TDT v3")
        let lines: [(Double, Double, String, String)] = [
            (0, 6, "Okay, so the catalog needs to work for the folding wagon and the full wheel line.", "S1"),
            (6, 11, "Right. Jonathan wants the wheels first, then the wagons as a second section.", "S2"),
            (11, 18, "Then we shoot the wheels on white, and the wagons out in the field by the shop in Ephrata.", "S1"),
            (18, 18.6, "Um.", "S1"),
            (18.6, 24, "Chris mentioned the Lititz dealer wants a one-page sheet too. Same photos, trimmed copy.", "S2"),
            (24, 24.6, "Uh, hmm.", "S1"),
            (24, 31, "Fine. One hero per product, three details, and a spec table. Keep the copy plain.", "S1"),
            (31, 37, "And the folding wagon gets its own spread, because thats the one people ask about.", "S2"),
            (37, 42, "Agreed. I'll send the shot list Thursday.", "S1"),
        ]
        t.segments = lines.map { Segment(start: $0.0, end: $0.1, text: $0.2, speaker: $0.3) }
        t.original = t.segments
        t.speakers = [Speaker(id: "S1", name: "Tim"), Speaker(id: "S2", name: "Jonathan")]
        t.projectId = project.id
        t.waveform = Waveform.envelope(of: url)
        t.pinned = true
        // Capture and archive: a suggested kind and tags, and two filler lines the transcript hides.
        t.kind = .meeting; t.kindIsAuto = true; t.tags = ["lapp wagons", "catalog"]
        store.add(t)
        let shoot = t.segments.first { $0.text.hasPrefix("Then we shoot") }!, spread = t.segments.first { $0.text.hasPrefix("And the folding") }!
        store.addNote(Note(text: "Ask Jonathan for the wheel spec sheet before the shoot.", at: 11, segmentId: shoot.id), to: t.id)
        store.addNote(Note(text: "Folding wagon spread", at: 31, segmentId: spread.id, isBookmark: true), to: t.id)
        seedArchive(store)
    }

    /// Journal entries on three days (one with background voices), an idea, and a note.
    private static func seedArchive(_ store: Store) {
        func add(_ title: String, _ kind: RecordingKind, daysAgo: Double, hour: Int, duration: Double, tags: [String] = [], _ lines: [(String, String?)]) {
            var t = Transcript(title: title, source: .voiceMemo, sourceLabel: "Voice memo", duration: duration, audioFileName: nil, model: "Parakeet TDT v3")
            var start = 0.0
            t.segments = lines.map { line in
                let len = max(1, Double(line.0.split(separator: " ").count) * 0.4)
                defer { start += len }
                return Segment(start: start, end: start + len, text: line.0, speaker: line.1)
            }
            t.original = t.segments
            if lines.contains(where: { $0.1 == "S2" }) { t.speakers = [Speaker(id: "S1", name: "Speaker 1"), Speaker(id: "S2", name: "Speaker 2")] }
            let day = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86_400 * daysAgo))
            t.createdAt = Calendar.current.date(byAdding: .hour, value: hour, to: day) ?? day
            t.kind = kind; t.kindIsAuto = true; t.tags = tags
            store.add(t)
        }
        add("Slow start, good afternoon", .journal, daysAgo: 0, hour: 7, duration: 372, tags: ["family"], [
            ("Woke up before the kids. Coffee on the porch, thinking about how to split the week between the catalog and the film.", nil),
            ("The afternoon was better. Got the shot list done and the dealer sheet roughed out.", nil)])
        add("Errands and a long walk", .journal, daysAgo: 1, hour: 18, duration: 1531, tags: ["verbatim"], [
            ("Grocery run, then the long way home. Talked through the speech app the whole way; some of it was actually useful.", "S1"),
            ("Please place the item in the bagging area.", "S2"),
            ("The big idea is that the app should sort recordings by itself, so the journal just builds up.", "S1"),
            ("Do you have a bag for that?", "S2"),
            ("And the titles should come from what I said, not the first five words.", "S1")])
        add("Quiet day in the edit", .journal, daysAgo: 3, hour: 21, duration: 260, tags: ["film"], [
            ("Locked the second act. The score temp works better than expected. Need to send notes tomorrow.", nil)])
        add("Catalog shoot plan", .idea, daysAgo: 0, hour: 9, duration: 760, tags: ["lapp wagons"], [
            ("Start with the wheels on white, before anything else, then the wagons in the field late afternoon.", nil)])
        func dictate(_ text: String, minutesAgo: Double) {
            var t = Transcript(title: String(text.prefix(40)), source: .dictation, sourceLabel: "Dictation", duration: Double(text.split(separator: " ").count) * 0.4, audioFileName: nil, model: "Parakeet TDT v3")
            t.segments = [Segment(start: 0, end: t.duration, text: text)]
            t.original = t.segments
            t.kind = .dictation
            t.createdAt = Date().addingTimeInterval(-60 * minutesAgo)
            store.add(t)
        }
        dictate("Thanks Chris, Thursday works. I'll bring the wheel samples and the shot list.", minutesAgo: 25)
        dictate("Reminder to order more white seamless before the catalog shoot.", minutesAgo: 190)
        dictate("Can you send the dealer sheet as a PDF by Friday? Same photos, trimmed copy.", minutesAgo: 60 * 26)
        add("Wheel sizes to confirm", .note, daysAgo: 2, hour: 15, duration: 48, tags: ["lapp wagons"], [
            ("Confirm the twelve and sixteen inch wheel sizes with Jonathan before the captions.", nil)])
    }

    /// A six-second clip and its manifest in the inbox, as the share extension leaves them.
    private static func seedInbox() {
        guard let folder = VerbatimInbox.inbox else { Log.note("UITEST inbox unavailable"); return }
        let id = UUID()
        let name = id.uuidString + ".wav"
        writeToneFile(folder.appendingPathComponent(name), seconds: 6)
        let item = VerbatimInbox.Item(id: id, kind: .file, fileName: name, originalName: "Porch interview, Lititz.wav", date: Date())
        do { try VerbatimInbox.writeManifest(item, in: folder) } catch { Log.note("UITEST inbox manifest: \(error)") }
    }

    private static func writeToneFile(_ url: URL, seconds: Double) {
        let sr = 16_000.0
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: 1, interleaved: true),
              let file = try? AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatInt16, interleaved: true) else { return }
        let n = AVAudioFrameCount(sr * seconds)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        buf.frameLength = n
        var seed: UInt32 = 12345
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            seed = seed &* 1664525 &+ 1013904223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let syllable = max(0, sin(t * 2 * .pi * 4.2)) * (0.5 + 0.5 * sin(t * 0.7))
            let pause = (Int(t) % 9 == 8) ? 0.05 : 1.0
            let v = (sin(t * 2 * .pi * 180) * 0.6 + noise * 0.4) * syllable * pause * 0.5
            buf.int16ChannelData![0][i] = Int16(max(-1, min(1, v)) * 32000)
        }
        try? file.write(from: buf)
    }
}
