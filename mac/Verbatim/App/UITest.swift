import SwiftUI
import AppKit
import AVFoundation

/// In-app UI self-test. With VERBATIM_UITEST=1 in the environment, the app seeds a transcript, synthesizes
/// real mouse events at the recorded positions of key controls, and logs PASS/FAIL per step to native.log.
/// CI runs it on a macOS 26 runner, so hit-testing regressions are caught before a build ships.
@MainActor
enum UITest {
    /// Off in bench mode (`-bench`), so CI can set VERBATIM_UITEST=1 for a clean, offline profile without the tour.
    static let enabled = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1" && !Bench.isRequested
    /// The welcome tour step the next screenshot opens on.
    static var onboardingStep = 0
    static var frames: [String: CGRect] = [:]     // SwiftUI .global (window content, top-left origin)
    private static var pass = 0, fail = 0
    /// Scrolls the enclosing scroll view so the target is on screen (a narrow window stacks Home's cards).
    private static func reveal(_ id: String, in window: NSWindow) async {
        guard let f = frames[id], let content = window.contentView else { return }
        let h = content.bounds.height
        let top = f.minY, bottom = f.maxY
        guard top < 52 || bottom > h - 8 else { return }
        let probe = CGPoint(x: f.midX, y: h / 2)
        var v = content.hitTest(probe)
        while let x = v, !(x is NSScrollView) { v = x.superview }
        guard let sv = v as? NSScrollView else { Log.note("UITEST no scroll view to reveal \(id)"); return }
        let clip = sv.contentView
        var o = clip.bounds.origin
        o.y += (f.midY - h / 2)
        o.y = max(0, min(o.y, (sv.documentView?.frame.height ?? 0) - clip.bounds.height))
        clip.scroll(to: o); sv.reflectScrolledClipView(clip)
        try? await Task.sleep(nanoseconds: 500_000_000)
        Log.note("UITEST revealed \(id) scroll=\(Int(o.y)) frame now=\(frames[id].map { "\(Int($0.minY))" } ?? "?")")
    }

    static func run(app: AppState) {
        guard enabled else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // The main window, never a floating panel (the dictation bar or thought pad can come first in the list).
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { Log.note("UITEST FAIL no window"); return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            if app.store.transcripts.isEmpty {
                var t = Transcript(title: "Self-test memo", source: .voiceMemo, sourceLabel: "Voice memo", duration: 12, audioFileName: nil, model: "Test")
                t.segments = [Segment(start: 0, end: 4, text: "This is a seeded transcript.", speaker: "S1"), Segment(start: 4, end: 9, text: "It exists so the self-test can click a row.", speaker: "S2")]
                t.original = t.segments
                t.speakers = [Speaker(id: "S1", name: "Speaker 1"), Speaker(id: "S2", name: "Speaker 2")]
                app.store.add(t)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            await step("click row opens transcript", window, target: "row-0", check: { if case .transcript = app.screen { return true } else { return false } })
            await step("sidebar Home goes home", window, target: "side-home", check: { app.screen == .home })
            await step("sidebar Library opens library", window, target: "side-library", check: { app.screen == .library })
            await step("sidebar Dictionary opens dictionary", window, target: "side-dict", check: { app.screen == .dictionary })
            await step("sidebar home again (one click)", window, target: "side-home", check: { app.screen == .home })
            try? await Task.sleep(nanoseconds: 900_000_000)   // let the Home slide-in finish before clicking inside it
            await step("Dictate opens its panel", window, target: "mode-dictate", check: { app.captureMode == "dictate" })
            app.captureMode = "voice"                                   // close the panel before the next click
            Log.note("UITEST after dictate step captureMode=\(app.captureMode)")
            try? await Task.sleep(nanoseconds: 600_000_000)
            await step("record tile asks for the mic or records", window, target: "tile-record", check: { app.showMicSheet || app.recorder.isRecording })
            if app.showMicSheet {
                await step("mic sheet Not now closes it", window, target: "sheet-notnow", check: { !app.showMicSheet })
            } else if app.recorder.isRecording {
                _ = app.recorder.stop()
            }
            await step("app tile opens the picker", window, target: "tile-app", check: { app.showAppPicker })
            app.showAppPicker = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            await step("captions tile opens the live captions panel", window, target: "tile-captions", check: { LiveCaptions.shared.isOpen })
            LiveCaptions.shared.close(force: true)
            try? await Task.sleep(nanoseconds: 400_000_000)
            app.verbiePose = .working; try? await Task.sleep(nanoseconds: 300_000_000); app.verbiePose = .ready
            await step("row opens transcript again", window, target: "row-0", check: { if case .transcript = app.screen { return true } else { return false } })

            await settingsSteps(main: window)
            logicChecks()
            // No lost recordings: write failures, joins around a corrupt part, discard, and recovery.
            RecordingSafetyChecks.run(store: app.store) { name, ok in
                if ok { pass += 1 } else { fail += 1 }
                Log.note("UITEST \(ok ? "PASS" : "FAIL") recording safety: \(name)")
            }

            Log.note("UITEST DONE pass=\(pass) fail=\(fail)")
            await tour(app: app, window: window)
        }
    }

    // MARK: Settings window

    private static func openSettingsWindow() {
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private static var settingsTab: String { UserDefaults.standard.string(forKey: "settingsTab") ?? "" }

    /// Clicks in the Settings window: a sidebar pane, then a search result opening its pane.
    private static func settingsSteps(main: NSWindow) async {
        UserDefaults.standard.set(SettingsTab.general.rawValue, forKey: "settingsTab")
        SettingsModel.shared.query = ""
        openSettingsWindow()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let w = SettingsModel.shared.window, w.isVisible else { fail += 1; Log.note("UITEST FAIL settings window did not open"); return }
        w.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await step("settings sidebar opens Watched folders", w, target: "settings-watched", check: { settingsTab == SettingsTab.watched.rawValue })
        await step("settings sidebar opens Export", w, target: "settings-export", check: { settingsTab == SettingsTab.export.rawValue })
        SettingsModel.shared.query = "timecode"
        try? await Task.sleep(nanoseconds: 700_000_000)
        let first = SettingsIndex.search("timecode").first
        await step("settings search result opens its pane", w, target: "settings-result-0", check: {
            first != nil && settingsTab == first?.section.rawValue && !SettingsModel.shared.isSearching
        })
        SettingsModel.shared.query = ""
        UserDefaults.standard.set(SettingsTab.general.rawValue, forKey: "settingsTab")
        w.close()
        main.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Two watched folders for the screenshots, like the approved mockup: one watching with SRT and Plain text
    /// going to a Subtitles folder, one paused with no export.
    private static func seedWatchedFolders() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Verbatim watch demo", isDirectory: true)
        let dailies = root.appendingPathComponent("Shoot dailies", isDirectory: true)
        let memos = root.appendingPathComponent("Voice memos", isDirectory: true)
        let subs = root.appendingPathComponent("Subtitles", isDirectory: true)
        for d in [dailies, memos, subs] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let w = FolderWatcher.shared
        guard w.folders.isEmpty else { return }
        if let a = w.add(dailies, formats: [.srt, .txt]) {
            w.update(a.id) { $0.includeSubfolders = true; $0.destination = FolderWatcher.bookmark(subs); $0.destinationPath = subs.path }
            UserDefaults.standard.set(a.id.uuidString, forKey: "watch.selected")
        }
        if let b = w.add(memos, formats: []) { w.update(b.id) { $0.enabled = false } }
    }

    // MARK: Screenshot tour

    /// Walks every screen with richer seeded data. CI watches `show.txt` and captures each name.
    private static func tour(app: AppState, window: NSWindow) async {
        appRef = app
        seedRich(app)
        seedArchive(app)
        seedDictations(app)
        seedActivity()
        YouTourSeed.run()
        try? await Task.sleep(nanoseconds: 800_000_000)
        let memo = app.store.transcripts.first { $0.title == "Lapp Wagons catalog call" }
        app.go(.home); app.captureMode = "voice"
        await show("01-home")
        app.captureMode = "dictate"
        await show("02-home-dictate")
        app.captureMode = "voice"
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Home's Dictations section (seeded above), scrolled into view.
        await reveal("home-dictations", in: window)
        await show("02b-home-dictations")
        // The Method cards between the tiles and Recent.
        await reveal("home-method", in: window)
        await show("02c-home-method")
        app.requestRecord()                       // no mic on the runner: the permission sheet
        await show("03-mic-sheet")
        app.showMicSheet = false
        app.showAppPicker = true
        await show("04-app-picker")
        app.showAppPicker = false
        // The multi-track sheet with made-up tracks (no files, nothing transcribed).
        app.multitrackDraft = MultitrackDraft.sample()
        await show("04b-multitrack")
        app.multitrackDraft = nil
        // Live captions with made-up lines (no speech or audio in UI test mode).
        app.toggleLiveCaptions()
        await show("04c-live-captions")
        LiveCaptions.shared.close(force: true)
        app.projectFilter = nil; app.go(.library)
        await show("05-library")
        app.libraryKind = .journal
        await show("05h-library-journal")
        app.libraryKind = .idea
        await show("05i-library-ideas")
        app.libraryKind = nil
        // Type and platform chips: Links, broken down by site.
        app.libraryFilter = LibraryFilter(source: .links)
        await show("05k-library-links-filter")
        app.libraryFilter = .all
        // A project's Library with Add from Library open (the seeded transcripts; nothing is added).
        if let project = app.store.projects.first(where: { $0.name == "Lapp Wagons" }) {
            app.projectFilter = project.id; app.go(.library)
            await show("05l-project-library")
            app.addFromLibrary = project.id
            await show("05m-add-from-library")
            app.addFromLibrary = nil
            try? await Task.sleep(nanoseconds: 600_000_000)
            app.projectFilter = nil
        }
        app.go(.queue)
        await show("05b-queue")
        // The "link added" card with made-up data (the tour never touches the network).
        app.go(.home)
        let card = LinkImport(id: UUID(), url: "https://www.youtube.com/watch?v=Q7r2mDn4x1k", site: "YouTube")
        card.title = "How we light interviews in small rooms"; card.duration = 3852
        card.phase = .downloading; card.progress = 0.42
        app.linkImports[card.id] = card; app.linkBadgeHeld.insert(card.id); app.linkCardID = card.id
        await show("05j-link-card")
        app.linkCardID = nil; app.linkBadgeHeld.remove(card.id); app.linkImports[card.id] = nil
        app.go(.links)
        await show("05c-links")
        app.go(.moments)
        await show("05f-moments")
        if let link = app.store.live.first(where: { $0.title == "Folding wagon walkthrough" }) {
            app.go(.transcript(link.id))
            await show("05g-link-kept")
        }
        app.search = "folding"
        await show("05d-search")
        app.search = ""
        if let trashMe = app.store.live.first(where: { $0.title == "Self-test memo" }) { app.store.moveToTrash(trashMe.id) }
        app.go(.trash)
        await show("05e-recently-deleted")
        if let m = memo { app.go(.transcript(m.id)) }
        await show("06-transcript")
        NotificationCenter.default.post(name: .verbatimShowMode, object: "Document")
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // Harper lints off the main thread
        await show("06b-document")
        NotificationCenter.default.post(name: .verbatimShowMode, object: "Transcript")
        // The export sheet (one transcript, then a Library selection of three).
        if let m = memo {
            let keep = ExportOptions.saved
            var o = keep; o.header = true; o.timecodeMode = .everyParagraph; o.moments = .end; o.speakerMode = .onChange; o.save()
            ExportOptions.savedFormat = .txt
            app.exportRequest = ExportRequest(ids: [m.id])
            await show("06f-export-sheet")
            app.exportRequest = nil
            try? await Task.sleep(nanoseconds: 700_000_000)
            ExportOptions.savedFormat = .srt
            let three = [m.id] + app.archive.filter { $0.id != m.id && $0.status == .ready }.prefix(2).map(\.id)
            app.exportRequest = ExportRequest(ids: three)
            await show("06g-export-batch-srt")
            app.exportRequest = nil
            ExportOptions.savedFormat = .txt
            keep.save()
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        if let walk = app.store.live.first(where: { $0.title == "Errands and a long walk" }) {
            UserDefaults.standard.set(true, forKey: Transcript.mainSpeakerOnlyKey)
            app.go(.transcript(walk.id))
            await show("06e-background-voices")
            UserDefaults.standard.set(false, forKey: Transcript.mainSpeakerOnlyKey)
        }
        // Performance probe: open a long transcript from Home and log how long the screen takes.
        let long = seedLong(app)
        app.go(.home)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        app.go(.transcript(long))
        await show("06c-long-transcript")
        // Scrolled down: the mode bar and tools pin under the top edge.
        app.go(.home)
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let seg = app.store.transcript(long)?.segments[120].id { app.focusSegment = seg }
        app.go(.transcript(long))
        await show("06d-pinned-tools")
        app.go(.home)
        try? await Task.sleep(nanoseconds: 800_000_000)
        app.go(.transcript(long))
        try? await Task.sleep(nanoseconds: 800_000_000)
        app.go(.dictionary)
        await show("07-dictionary")
        app.go(.dictations)
        await show("07b-dictations")
        app.go(.activity)
        await show("07c-you")
        app.dictation.previewPill(seconds: 4)
        await show("08-dictate-pill")
        let pad = ThoughtPad.shared
        pad.clear(); pad.title = "Catalog shoot email"
        pad.add("Shoot the wheels on white first, then the wagons out in the field by the shop.", seconds: 14)
        pad.add("Ask Jonathan for the wheel spec sheet before Friday.", seconds: 6)
        pad.add("The Lititz dealer wants a one-page sheet too. Same photos, trimmed copy.", seconds: 9, missed: true)
        ThoughtPadController.shared.open()
        await show("08b-thought-pad")
        ThoughtPadController.shared.close()
        app.dictation.bar?.ask(.init(title: "Remember “Lititz”?", body: "You changed ", quote: "lit it's → Lititz", after: ". Next time it's spelled your way.",
                                     primary: "Remember in Lapp Wagons", secondary: "Not now", seconds: 8))
        await show("08c-remember")
        app.dictation.bar?.setPhase(.idle)
        // Recent dictations (⌥⌘V) with the seeded dictations, then the Ribbon holding one that didn't paste.
        RecallPanelController.shared.open()
        await show("08d-recent-dictations")
        RecallPanelController.shared.close()
        app.dictation.previewRescue()
        await show("08e-didnt-paste")
        app.dictation.bar?.setPhase(.idle)
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        await show("09-settings")
        UserDefaults.standard.set(SettingsTab.models.rawValue, forKey: "settingsTab")
        await show("09c-settings-transcription")
        // Voice profile enrollment, step 2, with made-up progress (no microphone on the runner).
        if let settings = NSApp.keyWindow ?? NSApp.windows.first(where: { $0 != window && $0.isVisible && !($0 is NSPanel) }) {
            VoiceEnrollmentSheet.present(preview: true, from: settings)
            await show("09e-voice-enroll")
            VoiceEnrollmentSheet.dismiss()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        UserDefaults.standard.set(SettingsTab.dictate.rawValue, forKey: "settingsTab")
        await show("09d-settings-dictate")
        UserDefaults.standard.set(SettingsTab.actions.rawValue, forKey: "settingsTab")
        await show("09b-settings-actions")
        seedWatchedFolders()
        UserDefaults.standard.set(SettingsTab.watched.rawValue, forKey: "settingsTab")
        await show("09e-settings-watched")
        SettingsModel.shared.query = "timecode"
        await show("09f-settings-search")
        SettingsModel.shared.query = ""
        UserDefaults.standard.set(SettingsTab.export.rawValue, forKey: "settingsTab")
        await show("09g-settings-export")
        UserDefaults.standard.set(SettingsTab.general.rawValue, forKey: "settingsTab")
        NSApp.windows.filter { $0 != window && $0.isVisible }.forEach { $0.close() }
        app.go(.home)
        await show("10-home-again")
        for (i, name) in ["10a-onboarding-welcome", "10b-onboarding-permissions", "10c-onboarding-try", "10d-onboarding-placement", "10e-onboarding-quality"].enumerated() {
            onboardingStep = i
            app.showOnboarding = true
            await show(name)
            app.showOnboarding = false
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        onboardingStep = 0
        // Dark appearance pass
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        await show("11-dark-home")
        await reveal("home-dictations", in: window)
        await show("11c-dark-home-recent")
        app.toggleLiveCaptions()
        await show("11b-dark-live-captions")
        LiveCaptions.shared.close(force: true)
        if let m = memo { app.go(.transcript(m.id)) }
        await show("12-dark-transcript")
        NotificationCenter.default.post(name: .verbatimShowMode, object: "Document")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await show("13-dark-document")
        app.go(.links)
        await show("14-dark-links")
        app.libraryKind = .journal
        app.go(.library)
        await show("15-dark-library")
        app.libraryKind = nil
        app.go(.dictations)
        await show("16-dark-dictations")
        app.go(.activity)
        await show("17-dark-you")
        app.go(.dictionary)
        await show("18-dark-dictionary")
        app.go(.moments)
        await show("19-dark-moments")
        app.go(.trash)
        await show("20-dark-trash")
        UserDefaults.standard.set(SettingsTab.dictate.rawValue, forKey: "settingsTab")
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
        await show("21-dark-settings-dictate")
        UserDefaults.standard.set(SettingsTab.actions.rawValue, forKey: "settingsTab")
        await show("22-dark-settings-actions")
        UserDefaults.standard.set(SettingsTab.watched.rawValue, forKey: "settingsTab")
        await show("23-dark-settings-watched")
        UserDefaults.standard.set(SettingsTab.general.rawValue, forKey: "settingsTab")
        NSApp.windows.filter { $0 != window && $0.isVisible }.forEach { $0.close() }
        app.go(.home)
        NSApplication.shared.appearance = nil
        write(show: "done")
    }

    static weak var appRef: AppState?
    private static func show(_ name: String) async {
        try? await Task.sleep(nanoseconds: 1_200_000_000)   // let transitions settle
        write(show: name)
        Log.note("UITEST show \(name) captureMode=\(appRef?.captureMode ?? "?") screen=\(String(describing: appRef?.screen))")
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // CI captures in this window
    }

    private static func write(show name: String) {
        let url = Log.file.deletingLastPathComponent().appendingPathComponent("show.txt")
        try? (name + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// A transcript with real audio (so the player dock shows), notes, a bookmark, a project, and dictionary words.
    private static func seedRich(_ app: AppState) {
        seedLink(app)
        let project = app.store.projects.first { $0.name == "Lapp Wagons" } ?? app.store.addProject("Lapp Wagons")
        if !app.store.dictionary.contains(where: { $0.preferred == "Lititz" }) {
            app.store.dictionary.append(DictionaryEntry(preferred: "Lititz", heardAs: ["Lit it's", "Lititz's"], learnedFrom: "Added by you"))
            app.store.dictionary.append(DictionaryEntry(preferred: "Lapp Wagons", heardAs: ["Lap wagons", "lab wagons"], learnedFrom: "Lapp Wagons catalog call", projectId: project.id))
        }
        guard !app.store.transcripts.contains(where: { $0.title == "Lapp Wagons catalog call" }) else { return }
        let url = app.store.newAudioURL(ext: "wav")
        writeToneFile(url, seconds: 42)
        var t = Transcript(title: "Lapp Wagons catalog call", source: .voiceMemo, sourceLabel: "Voice memo", duration: 42, audioFileName: url.lastPathComponent, model: "Parakeet TDT v3")
        t.engine = "fluid"
        let lines: [(Double, Double, String, String)] = [
            (0, 6, "Okay, so the catalog needs to work for the folding wagon and the full wheel line.", "S1"),
            (6, 11, "Right. Jonathan wants the wheels first, then the wagons as a second section.", "S2"),
            (11, 18, "Then we shoot the wheels on white, and the wagons out in the field by the shop in Ephrata.", "S1"),
            (18, 18.6, "Um.", "S1"),
            (18.6, 24, "Chris mentioned the Lititz dealer wants a one-page sheet too. Same photos, trimmed copy.", "S2"),
            (24, 31, "Fine. One hero per product, three details, and a spec table. Keep the copy plain.", "S1"),
            (31, 31.8, "Uh, hmm.", "S2"),
            (31.8, 37, "And the folding wagon gets its own spread, because thats the one people ask about.", "S2"),
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
        app.store.add(t)
        let shoot = t.segments.first { $0.text.hasPrefix("Then we shoot") }!, spread = t.segments.first { $0.text.hasPrefix("And the folding") }!
        app.store.addNote(Note(text: "Ask Jonathan for the wheel spec sheet before the shoot.", at: 11, segmentId: shoot.id, isBookmark: false), to: t.id)
        app.store.addNote(Note(text: "Folding wagon spread", at: 31.8, segmentId: spread.id, isBookmark: true), to: t.id)
        app.store.addNote(Note(text: "Quote for the one-page sheet: separate line item.", at: nil, segmentId: nil, isBookmark: false), to: t.id)
    }

    /// Capture and archive: Journal entries on three days (one with background voices), an idea, and a note.
    private static func seedArchive(_ app: AppState) {
        guard !app.store.transcripts.contains(where: { $0.title == "Errands and a long walk" }) else { return }
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
            app.store.add(t)
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
        add("Wheel sizes to confirm", .note, daysAgo: 2, hour: 15, duration: 48, tags: ["lapp wagons"], [
            ("Confirm the twelve and sixteen inch wheel sizes with Jonathan before the captions.", nil)])
    }

    /// Three dictations into other apps, for the Dictations screen.
    private static func seedDictations(_ app: AppState) {
        guard !app.store.transcripts.contains(where: { $0.source == .dictation }) else { return }
        let items: [(String, String?, AppCategory, FlowStyle, String, String, Double, Bool)] = [
            ("Mail", "com.apple.mail", .email, .formal, "um hi Jonathan so I think we should uh meet on Thursday actually make that Friday morning to go over the catalog thanks Tim",
             "Hi Jonathan,\n\nI think we should meet on Friday morning to go over the catalog.\n\nThanks,\nTim", -600, true),
            ("Slack", "com.tinyspeck.slackmacgap", .work, .casual, "the shot list is in the drive we need three things first the photos second the copy and third the price list",
             "The shot list is in the drive. We need three things:\n1. The photos\n2. The copy\n3. The price list", -3_600, true),
            ("Messages", "com.apple.MobileSMS", .personal, .casual, "running like ten minutes late sorry", "Running like 10 minutes late, sorry", -90_000, false),
        ]
        for (appName, bundle, cat, style, raw, pasted, ago, ok) in items {
            var t = Transcript(title: Transcript.titleFrom([Segment(start: 0, end: 4, text: pasted)]) ?? "Dictation", source: .dictation, sourceLabel: "Dictation · \(appName)", duration: 6, audioFileName: nil, model: "Parakeet TDT v3")
            t.segments = [Segment(start: 0, end: 6, text: raw)]; t.original = t.segments
            t.createdAt = Date().addingTimeInterval(ago)
            t.document = pasted
            t.flow = FlowInfo(app: appName, bundleID: bundle, category: cat, style: style, level: "light", raw: raw, pasted: pasted, pastedOK: ok)
            app.store.add(t)
        }
    }

    /// Six months of dictation numbers, for the Activity screen. Deterministic, so screenshots compare run to run.
    private static func seedActivity() {
        guard ActivityLog.shared.events.count < 20 else { return }
        let apps: [(String, AppCategory)] = [("Claude", .other), ("Mail", .email), ("Slack", .work), ("Messages", .personal), ("Notes", .other), ("Xcode", .code)]
        let cal = Calendar.current
        var list: [ActivityEvent] = []
        for day in 0..<180 {
            // Quiet days happen; nothing marks them as missed.
            if day % 7 == 3 || (day * 13) % 11 == 0 { continue }
            let date = cal.date(byAdding: .day, value: -day, to: cal.date(bySettingHour: 9 + (day % 6), minute: 15, second: 0, of: Date()) ?? Date()) ?? Date()
            for k in 0..<(1 + day % 4) {
                let (name, cat) = apps[(day + k * 3) % apps.count]
                let words = 30 + (day * 37 + k * 53) % 220
                list.append(ActivityEvent(id: UUID(), date: date.addingTimeInterval(Double(k) * 900), words: words, seconds: Double(words) / 2.3,
                                                     transcribeSeconds: 0.6 + Double((day + k) % 5) * 0.15, cleanupSeconds: 0.4 + Double(k % 3) * 0.2,
                                                     app: name, category: cat, fillers: (day + k) % 4, changed: 2 + (day * k) % 9, vocabularyFixes: (day + k) % 6 == 0 ? 1 : 0))
            }
        }
        ActivityLog.shared.addAll(list)
    }

    /// A transcript that came from a link, for the Links screen and timestamped-link actions.
    private static func seedLink(_ app: AppState) {
        guard !app.store.transcripts.contains(where: { $0.title == "Folding wagon walkthrough" }) else { return }
        var t = Transcript(title: "Folding wagon walkthrough", source: .link, sourceLabel: "youtube.com", duration: 412, audioFileName: nil, model: "Parakeet TDT v3")
        t.sourceURL = "https://www.youtube.com/watch?v=ab12cd34ef5"
        t.link = LinkInfo(url: "https://www.youtube.com/watch?v=ab12cd34ef5", site: "YouTube", channel: "Lapp Wagons", uploadDate: "20260912")
        t.segments = [Segment(start: 0, end: 6, text: "This is the folding wagon, and here's how it folds flat for the truck."),
                      Segment(start: 6, end: 13, text: "Two latches on the side, lift the bed, and the wheels tuck under.")]
        t.original = t.segments
        app.store.add(t)
        // Keep: a short generated MP4 stands in for a kept video, so frame grabs run for real.
        let video = Paths.downloads.appendingPathComponent("uitest-kept.mp4")
        let id = t.id
        Task {
            try? FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
            guard await writeTestVideo(video, seconds: 14) else { Log.note("UITEST keep video FAIL write"); return }
            app.store.update(id) { $0.keptVideo = video.path }
            app.store.addNote(Note(text: "Latches on the side; good close-up for the catalog.", at: 7, segmentId: app.store.transcript(id)?.segments.last?.id), to: id)
            app.store.addNote(Note(text: "", at: 2, segmentId: app.store.transcript(id)?.segments.first?.id, isBookmark: true), to: id)
            app.grabFrames(id, video: video)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let frames = app.store.transcript(id)?.notes.filter { $0.frameFile != nil }.count ?? 0
            Log.note("UITEST keep frames \(frames == 2 ? "PASS" : "FAIL") (\(frames)/2)")
        }
    }

    /// An H.264 MP4 of slowly shifting color bands, for frame-grab tests.
    nonisolated private static func writeTestVideo(_ url: URL, seconds: Int) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        let w = 640, h = 360
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let fps = 2
        for f in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { return false }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<h {
                for x in 0..<w {
                    let band = (x / 80 + f) % 3
                    let o = y * row + x * 4
                    // BGRA: paper, iris, coral bands
                    let c: (UInt8, UInt8, UInt8) = band == 0 ? (0xEE, 0xF4, 0xF7) : band == 1 ? (0xFF, 0x5B, 0x6B) : (0x5A, 0x7A, 0xFF)
                    base[o] = c.0; base[o + 1] = c.1; base[o + 2] = c.2; base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    /// A one-hour-style transcript: 600 segments, two speakers, no audio.
    private static func seedLong(_ app: AppState) -> UUID {
        if let t = app.store.transcripts.first(where: { $0.title == "Long interview (perf)" }) { return t.id }
        var t = Transcript(title: "Long interview (perf)", source: .file, sourceLabel: "MP3 file", duration: 3600, audioFileName: nil, model: "Parakeet TDT v3")
        let lines = ["So the first thing we talked about was the catalog and how the wheels should lead it.",
                     "Right, and the folding wagon needs its own spread because that's what people ask about.",
                     "We can shoot the wheels on white and the wagons out in the field by the shop.",
                     "The dealer in Lititz wants a one-page sheet with the same photos and trimmed copy."]
        t.segments = (0..<600).map { i in Segment(start: Double(i) * 6, end: Double(i) * 6 + 5.5, text: lines[i % 4], speaker: i % 3 == 0 ? "S2" : "S1") }
        t.original = t.segments
        t.speakers = [Speaker(id: "S1", name: "Tim"), Speaker(id: "S2", name: "Guest")]
        t.createdAt = Date().addingTimeInterval(-86_400 * 3)
        app.store.add(t)
        return t.id
    }

    /// Writes a 16 kHz mono WAV with a speech-like amplitude envelope.
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

    /// Checks that need no clicks: filler lines, recording kinds, and joining a long recording's segments
    /// (including one whose header was never finalized, as after a crash).
    private static func logicChecks() {
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name)")
        }
        check("filler-only lines", Segment(start: 0, end: 1, text: "Um.").isFillerOnly && Segment(start: 0, end: 1, text: "uh, hmm…").isFillerOnly
              && !Segment(start: 0, end: 1, text: "Um, I think so.").isFillerOnly && !Segment(start: 0, end: 1, text: "").isFillerOnly)
        let feed = CaptionFeed()
        feed.addSource("a", speaker: nil)
        feed.update("a", words: LiveWords(settled: "Hello there. How are", volatile: "you"))
        check("captions: a finished sentence becomes a line", feed.history.map(\.text) == ["Hello there."] && feed.current.first?.text == "How are you")
        feed.update("a", words: LiveWords(settled: "Hello there. How are you?", volatile: ""))
        check("captions: the current line finishes", feed.history.map(\.text) == ["Hello there.", "How are you?"] && feed.current.isEmpty)
        // Library type and platform filters, and Add from Library (shared with the iPhone's self-test).
        LibraryFilterChecks.run { check("library: " + $0, $1) }
        // Transcript actions, Library sort and search, synced playback (shared with the iPhone's self-test).
        ActionsHistoryChecks.run { check($0, $1) }
        let restored = FlowAction.builtIn
        check("actions: the five sit alongside the eight in Settings › Actions", restored.count == 13
              && TranscriptActions.builtIn.allSatisfy { spec in restored.contains { $0.id == spec.id && $0.name == spec.name && $0.instruction.contains(TranscriptActions.noAddRule) } })
        let dict = Transcript(title: "d", source: .dictation, sourceLabel: "", duration: 1, audioFileName: nil, model: "")
        check("dictations are kind dictation", dict.kind == .dictation && dict.titleIsAuto && dict.kindIsAuto)

        // Export: the options shape the text, and subtitles honor the caption limits.
        var ex = Transcript(title: "Export check", source: .voiceMemo, sourceLabel: "Voice memo", duration: 40, audioFileName: nil, model: "Test")
        ex.segments = [Segment(start: 0, end: 6, text: "This wall gets the best light in the morning, so the chair goes here.", speaker: "S1"),
                       Segment(start: 6.2, end: 7, text: "Um.", speaker: "S1"),
                       Segment(start: 7.5, end: 14, text: "Agreed. Can we bring the second key in from the left so the background stays darker?", speaker: "S2")]
        ex.speakers = [Speaker(id: "S1", name: "Ana"), Speaker(id: "S2", name: "Tim")]
        ex.notes = [Note(text: "Second key", at: 7.5, isBookmark: true)]
        var eo = ExportOptions(); eo.timecodeMode = .everyParagraph; eo.moments = .end
        let etext = Exporter.render(ex, as: .txt, options: eo)
        check("export text has header, stamps, speakers, moments",
              etext.hasPrefix("Export check\n") && etext.contains("[00:00:07] Tim: Agreed.") && etext.contains("Moments\n[00:00:07] Second key"))
        check("export leaves hidden filler out", !etext.contains("Um.") && Exporter.render(ex, as: .txt, options: { var o = eo; o.includeHidden = true; return o }()).contains("Um."))
        let caps = Exporter.captions(ex, eo)
        check("export captions within limits", !caps.isEmpty && caps.allSatisfy { $0.lines.count <= 2 && $0.lines.allSatisfy { $0.count <= 42 } && $0.end - $0.start <= 7.0001 })
        check("export JSON has the export section", Exporter.render(ex, as: .json, options: eo).contains("\"verbatim-export\""))

        // Summaries and titles: plain-text fallback parsing, refusals, sentence case, sampled excerpts
        let plain = Summarizer.parsePlain("OVERVIEW: Tim plans errands. He weighs a film title.\nPOINTS:\n- Take the dogs out\n- **Range** closes at 5 p.m.")
        check("summary plain text parses", plain.overview == "Tim plans errands. He weighs a film title." && plain.keyPoints == ["Take the dogs out", "Range closes at 5 p.m."])
        check("summary refusal detected", OnDeviceTextRefusal.isRefusal("I’m sorry, but I can’t help with that.") && !OnDeviceTextRefusal.isRefusal("Tim plans errands."))
        check("title sentence case", AutoLabel.cleanTitle("range plans and film title.") == "Range plans and film title" && AutoLabel.cleanTitle("I can't help with that") == nil)
        let longSegs = (0..<60).map { i in Segment(start: Double(i), end: Double(i + 1), text: Array(repeating: "w\(i)", count: 40).joined(separator: " "), speaker: nil) }
        let excerpt = AutoLabel.excerpt(longSegs)
        check("title excerpt samples start, middle, and end", excerpt.contains("w0") && excerpt.contains("w30") && excerpt.contains("w59") && excerpt.split(whereSeparator: { $0.isWhitespace }).count <= 1_510)

        // A recording's mic going away: the built-in mic it moves to, and when it pauses instead
        let shure = AudioDevices.Device(id: 41, name: "Shure MV7", transport: "USB")
        let pods = AudioDevices.Device(id: 42, name: "AirPods Pro", transport: "Bluetooth")
        let jack = AudioDevices.Device(id: 43, name: "External Microphone", transport: "Built-in")
        let mbp = AudioDevices.Device(id: 44, name: "MacBook Pro Microphone", transport: "Built-in")
        let imic: UInt32 = 0x696D6963, emic: UInt32 = 0x656D6963
        let mics: [(device: AudioDevices.Device, source: UInt32?)] = [(shure, nil), (pods, nil), (jack, emic), (mbp, imic)]
        check("mic fallback picks the internal built-in mic", AudioDevices.pickBuiltIn(mics) == mbp
              && AudioDevices.pickBuiltIn(mics, excluding: mbp.id) == nil
              && AudioDevices.pickBuiltIn([(shure, nil), (pods, nil)]) == nil)
        check("mic fallback without a data source goes by name", AudioDevices.pickBuiltIn([(jack, nil), (mbp, nil)]) == mbp
              && AudioDevices.pickBuiltIn([(jack, nil)]) == nil)
        check("a mic going away moves to the built-in mic, never pauses for time",
              MicRecovery.plan(lostGone: true, onBuiltIn: false, recentlyReopened: false, builtIn: mbp) == .builtIn(mbp)
              && MicRecovery.plan(lostGone: true, onBuiltIn: false, recentlyReopened: true, builtIn: mbp) == .builtIn(mbp))
        check("a mic going away pauses only without a built-in mic",
              MicRecovery.plan(lostGone: true, onBuiltIn: false, recentlyReopened: false, builtIn: nil) == .pause(micLost: true))
        check("a mic that's still there follows the change, then pauses if it changes again",
              MicRecovery.plan(lostGone: false, onBuiltIn: false, recentlyReopened: false, builtIn: mbp) == .current
              && MicRecovery.plan(lostGone: false, onBuiltIn: false, recentlyReopened: true, builtIn: mbp) == .pause(micLost: false)
              && MicRecovery.plan(lostGone: false, onBuiltIn: true, recentlyReopened: false, builtIn: mbp) == .builtIn(mbp))

        // After a call (iPhone): resume only when iOS says so, on the input the recording was using.
        check("an interruption resumes only with shouldResume",
              InterruptionPolicy.shouldResume(pausedForInterruption: true, isRecording: true, isPaused: true, systemSaysResume: true)
              && !InterruptionPolicy.shouldResume(pausedForInterruption: true, isRecording: true, isPaused: true, systemSaysResume: false))
        check("an interruption never resumes a pause you made, a stopped recording, or one already running",
              !InterruptionPolicy.shouldResume(pausedForInterruption: false, isRecording: true, isPaused: true, systemSaysResume: true)
              && !InterruptionPolicy.shouldResume(pausedForInterruption: true, isRecording: false, isPaused: true, systemSaysResume: true)
              && !InterruptionPolicy.shouldResume(pausedForInterruption: true, isRecording: true, isPaused: false, systemSaysResume: true))
        check("resuming keeps the recording's input while it's there",
              InterruptionPolicy.input(pinned: "airpods", available: ["mic", "airpods"], builtIn: "mic") == "airpods")
        check("resuming falls back to the built-in mic only when the input is gone",
              InterruptionPolicy.input(pinned: "airpods", available: ["mic"], builtIn: "mic") == "mic"
              && InterruptionPolicy.input(pinned: nil, available: ["mic"], builtIn: "mic") == "mic"
              && InterruptionPolicy.input(pinned: "airpods", available: [], builtIn: nil) == nil)
        check("a resume counts only audio that arrives after it",
              InterruptionPolicy.delivering(resumedAt: 10, latestBuffer: 10.5)
              && !InterruptionPolicy.delivering(resumedAt: 10, latestBuffer: 9.9)
              && !InterruptionPolicy.delivering(resumedAt: 10, latestBuffer: nil))

        // Voice enrollment without a microphone: following along, passage rotation, and the audio guard before the
        // speaker models run.
        check("voice: passage words normalize", VoicePassages.normalized("Grandfather's wheel, by hand.") == ["grandfathers", "wheel", "by", "hand"]
              && VoicePassages.normalized("  — ").isEmpty)
        check("voice: heard words follow in order, past a missed word", VoicePassages.matched(["a", "b", "c", "d"], heard: ["a", "c", "d"]) == 4
              && VoicePassages.matched(["a", "b"], heard: ["x", "y"]) == 0 && VoicePassages.matched([], heard: ["a"]) == 0
              && VoicePassages.matched(["a"], heard: []) == 0)
        check("voice: extra passages wrap for any stored index", VoicePassages.extraIndex(-1, count: 4) == 3 && VoicePassages.extraIndex(9, count: 4) == 1
              && VoicePassages.extraIndex(Int.min, count: 4) == 0 && VoicePassages.extraIndex(Int.max, count: 4) == 3 && VoicePassages.extraIndex(5, count: 0) == 0)
        let clockStep = VoiceEnrollment.follow(words: 26, matched: 0, followsWords: false, inPassage: 2, elapsed: 2, wordsRead: 0, doneAt: nil)
        check("voice: without live words the clock moves the reading", clockStep.wordsRead == 5 && clockStep.doneAt == nil && !clockStep.advance)
        let heardStep = VoiceEnrollment.follow(words: 10, matched: 9, followsWords: true, inPassage: 4, elapsed: 4, wordsRead: 3, doneAt: nil)
        let nextStep = VoiceEnrollment.follow(words: 10, matched: 10, followsWords: true, inPassage: 4.9, elapsed: 4.9, wordsRead: heardStep.wordsRead, doneAt: heardStep.doneAt)
        check("voice: a passage is done with all but its last word, then moves on", heardStep.wordsRead == 10 && heardStep.doneAt == 4 && !heardStep.advance && nextStep.advance)
        let slowStep = VoiceEnrollment.follow(words: 10, matched: 2, followsWords: true, inPassage: 9.5, elapsed: 9.5, wordsRead: 2, doneAt: nil)
        check("voice: a missed word never stalls the reading", slowStep.wordsRead == 10 && slowStep.doneAt == 9.5)
        check("voice: progress never goes backwards", VoiceEnrollment.follow(words: 10, matched: 3, followsWords: true, inPassage: 1, elapsed: 1, wordsRead: 7, doneAt: nil).wordsRead == 7)
        let oddStep = VoiceEnrollment.follow(words: 10, matched: 0, followsWords: false, inPassage: .nan, elapsed: .nan, wordsRead: 0, doneAt: nil)
        _ = VoiceEnrollment.follow(words: 0, matched: 0, followsWords: true, inPassage: .infinity, elapsed: .infinity, wordsRead: 0, doneAt: nil)
        check("voice: odd clock values never trap", oddStep.wordsRead == 0 && !oddStep.advance && VoiceEnrollment.wholeSeconds(-5) == 0
              && VoiceEnrollment.wholeSeconds(61.9) == 61 && VoiceEnrollment.wholeSeconds(.infinity) == 0 && VoiceEnrollment.wholeSeconds(1e30) == 359_999
              && VoiceEnrollment.clock(75) == "1:15" && VoiceEnrollment.clock(.nan) == "0:00")
        let split = VoicePassageCard.split(["The", "morning", "—", "light"], wordsRead: 2)
        check("voice: the passage card darkens read words with their punctuation", split.read == "The morning —" && split.rest == "light")
        var guardOK = false
        if case .failure(.noSpeech) = VoiceProfile.prepareSamples([]), case .failure(.silent) = VoiceProfile.prepareSamples([Float](repeating: 0, count: 32_000)),
           case .success(let short) = VoiceProfile.prepareSamples([Float.nan, 0.1, -0.2]), case .success(let long) = VoiceProfile.prepareSamples([Float](repeating: 0.1, count: 32_000)) {
            guardOK = short.count == 16_000 && short[0] == 0 && short[2] == -0.2 && long.count == 32_000
        }
        check("voice: no audio or only silence never reaches the speaker models; short clips are padded", guardOK)
        let previewModel = VoiceEnrollment(preview: true)
        previewModel.start(); previewModel.readMore(); previewModel.togglePause()
        check("voice: the preview never records", previewModel.step == .reading && previewModel.wordsRead == 15 && !previewModel.isStarting && !previewModel.isPaused)

        // Settings search
        let tc = SettingsIndex.search("timecode").map(\.id)
        check("settings search finds timecode rows", tc.contains("export.timecodes") && tc.contains("watched.exportOptions") && tc.contains("captions.soon"))
        check("settings search needs every word", SettingsIndex.search("sync icloud").map(\.id) == ["storage.icloud"] && SettingsIndex.search("   ").isEmpty)
        check("every settings pane is searchable", SettingsTab.allCases.allSatisfy { t in SettingsIndex.all.contains { $0.section == t } })
        check("settings ids are unique", Set(SettingsIndex.all.map(\.id)).count == SettingsIndex.all.count)

        // Recent dictations: newest first, capped, one-line menu titles, number keys, and when the Ribbon keeps a missed paste
        do {
            let now = Date()
            var pool: [Transcript] = (0..<14).map { i in
                var t = Transcript(title: "d\(i)", source: .dictation, sourceLabel: "Dictation", duration: 2, audioFileName: nil, model: "")
                t.createdAt = now.addingTimeInterval(-Double(i) * 60)
                t.flow = FlowInfo(app: i % 2 == 0 ? "Mail" : "Slack", bundleID: nil, category: .other, style: .casual, level: "light",
                                  raw: "r\(i)", pasted: "Dictation number \(i)", pastedOK: true)
                return t
            }
            var memo = Transcript(title: "m", source: .voiceMemo, sourceLabel: "Voice memo", duration: 2, audioFileName: nil, model: "")
            memo.createdAt = now.addingTimeInterval(5)
            var failed = Transcript(title: "f", source: .dictation, sourceLabel: "Dictation", duration: 2, audioFileName: nil, model: "")
            failed.createdAt = now.addingTimeInterval(5); failed.status = .failed
            var blank = Transcript(title: "b", source: .dictation, sourceLabel: "Dictation", duration: 2, audioFileName: nil, model: "")
            blank.createdAt = now.addingTimeInterval(5)
            blank.flow = FlowInfo(app: "Mail", bundleID: nil, category: .other, style: .casual, level: "light", raw: "", pasted: "  ", pastedOK: false)
            pool += [memo, failed, blank]
            let items = Recall.items(from: Array(pool.reversed()), sites: [pool[1].id: "github.com"])
            let shown = Recall.visible(items, query: "")
            check("recent dictations: newest first, only dictations with words", items.count == 14 && items.first?.text == "Dictation number 0"
                  && zip(items, items.dropFirst()).allSatisfy { $0.0.date >= $0.1.date })
            check("recent dictations: at most 10 rows", shown.count == 10 && shown.last?.text == "Dictation number 9")
            check("recent dictations: app and website", items[1].source == "Slack · github.com" && items[0].source == "Mail")
            check("recent dictations: search needs every word", Recall.visible(items, query: "slack NUMBER 13").map(\.text) == ["Dictation number 13"]
                  && Recall.visible(items, query: "github").map(\.text) == ["Dictation number 1"] && Recall.visible(items, query: "zzz").isEmpty)
            let long = String(repeating: "word ", count: 30)
            check("recent dictations: menu titles are one line of 60", Recall.truncate(long).count == 60 && Recall.truncate(long).hasSuffix("…")
                  && Recall.truncate("Hi\n\nthere  you") == "Hi there you" && Recall.truncate("Short") == "Short")
            check("recent dictations: two-line preview", Recall.preview("One\n\n  Two\nThree") == "One\nTwo")
            check("recent dictations: number keys 1–9 then 0", Recall.index(forKeyCode: 18) == 0 && Recall.index(forKeyCode: 25) == 8
                  && Recall.index(forKeyCode: 29) == 9 && Recall.index(forKeyCode: 82) == 9 && Recall.index(forKeyCode: 0) == nil
                  && Recall.keyLabel(0) == "1" && Recall.keyLabel(9) == "0" && Recall.keyLabel(10) == nil)
            check("recent dictations: a number copies, ⇧ pastes", Recall.keyAction(keyCode: 18, modifiers: [], queryEmpty: true) == .copy(0)
                  && Recall.keyAction(keyCode: 29, modifiers: [.shift], queryEmpty: true) == .paste(9))
            check("recent dictations: numbers type into search unless ⌘ is held", Recall.keyAction(keyCode: 18, modifiers: [], queryEmpty: false) == nil
                  && Recall.keyAction(keyCode: 18, modifiers: [.command], queryEmpty: false) == .copy(0)
                  && Recall.keyAction(keyCode: 18, modifiers: [.command, .shift], queryEmpty: false) == .paste(0)
                  && Recall.keyAction(keyCode: 18, modifiers: [.option], queryEmpty: true) == nil)
            check("recent dictations: arrows, Return, and Esc", Recall.keyAction(keyCode: 125, modifiers: [], queryEmpty: false) == .move(1)
                  && Recall.keyAction(keyCode: 126, modifiers: [], queryEmpty: true) == .move(-1)
                  && Recall.keyAction(keyCode: 36, modifiers: [], queryEmpty: false) == .copySelected
                  && Recall.keyAction(keyCode: 36, modifiers: [.shift], queryEmpty: false) == .pasteSelected
                  && Recall.keyAction(keyCode: 53, modifiers: [], queryEmpty: false) == .close
                  && Recall.keyAction(keyCode: 0, modifiers: [], queryEmpty: true) == nil)
            check("didn't paste: the Ribbon keeps it with no text field or no read", Recall.rescue(for: .copiedOnly, command: false) == .noField
                  && Recall.rescue(for: .failed(.notRead), command: false) == .notRead)
            check("didn't paste: not after a paste that landed, an edit by voice, or a failure with its own fix",
                  Recall.rescue(for: .pasted, command: false) == nil && Recall.rescue(for: .copiedOnly, command: true) == nil
                  && Recall.rescue(for: .failed(.notTrusted), command: false) == nil && Recall.rescue(for: .failed(.typingInterrupted), command: false) == nil)
            check("didn't paste: says when it's on the clipboard", Recall.rescueTitle(.noField, app: "Finder", onClipboard: true) == "Copied, since there was no text field."
                  && Recall.rescueTitle(.notRead, app: "Notes", onClipboard: false) == "Notes didn't take the paste.")
            check("settings search finds the clipboard and recent dictations rows", SettingsIndex.search("clipboard").map(\.id).contains("dictate.alwaysCopy")
                  && SettingsIndex.search("recent").map(\.id).contains("dictate.recall"))
            check("also copy each dictation is off by default", UserDefaults.standard.object(forKey: AlwaysCopy.key) != nil || !AlwaysCopy.isOn)
            check("recent dictations shortcut defaults to ⌥⌘V", UserDefaults.standard.object(forKey: RecallShortcut.key) != nil || RecallShortcut.current == .optionCommandV)
        }

        // Watched folders: names, the seen-before key, and an auto-export written with Exporter
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        check("watch file name pattern", FolderWatcher.fileName(pattern: "{original name}", original: URL(fileURLWithPath: "/x/Day 1.mov"), title: "T", date: day) == "Day 1"
              && FolderWatcher.fileName(pattern: "{title}/{original name}", original: URL(fileURLWithPath: "/x/a.wav"), title: "Call", date: day) == "Call-a"
              && FolderWatcher.fileName(pattern: "  ", original: URL(fileURLWithPath: "/x/b.m4a"), title: "", date: day) == "b")
        check("watch seen-before key", FolderWatcher.processedKey(path: "/a/b.wav", size: 10, mtime: 5.7) == "/a/b.wav|10|5"
              && FolderWatcher.processedKey(path: "/a/b.wav", size: 11, mtime: 5.7) != FolderWatcher.processedKey(path: "/a/b.wav", size: 10, mtime: 5.7))
        do {
            let fm = FileManager.default
            let wdir = fm.temporaryDirectory.appendingPathComponent("verbatim-watch-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: wdir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: wdir) }
            var t = Transcript(title: "Clip", source: .file, sourceLabel: "MOV file", duration: 4, audioFileName: nil, model: "Test")
            t.segments = [Segment(start: 0, end: 2, text: "Rolling.", speaker: "S1"), Segment(start: 2, end: 4, text: "Action.", speaker: "S1")]
            t.speakers = [Speaker(id: "S1", name: "Speaker 1")]
            let folder = WatchedFolder(name: "w", bookmark: Data(), path: wdir.path, formats: [ExportFormat.srt.rawValue, ExportFormat.txt.rawValue])
            let src = wdir.appendingPathComponent("clip.mov")
            let r1 = FolderWatcher.export(t, folder: folder, source: src, options: ExportOptions())
            let r2 = FolderWatcher.export(t, folder: folder, source: src, options: ExportOptions())
            let srt = (try? String(contentsOf: wdir.appendingPathComponent("clip.srt"), encoding: .utf8)) ?? ""
            check("watch auto-export writes each format", r1.error == nil && r1.written.map(\.lastPathComponent) == ["clip.txt", "clip.srt"]
                  && srt.contains("00:00:00,000 --> ") && srt.contains("Rolling.") && r2.written.map(\.lastPathComponent) == ["clip 2.txt", "clip 2.srt"])
        }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("verbatim-seg-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let base = dir.appendingPathComponent("2026-01-01 at 10.00.00.wav")
        func write(_ url: URL, seconds: Double) {
            guard let f = try? AVAudioFile(forWriting: url, settings: recordingFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true),
                  let b = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: AVAudioFrameCount(16_000 * seconds)) else { return }
            b.frameLength = b.frameCapacity
            if let ch = b.int16ChannelData?[0] { for i in 0..<Int(b.frameLength) { ch[i] = Int16(truncatingIfNeeded: (i % 64) * 200) } }
            try? f.write(from: b)
            if #available(macOS 15, *) { f.close() }
        }
        write(base, seconds: 1)
        write(RecordingSegments.url(for: base, index: 2), seconds: 1)
        let third = RecordingSegments.url(for: base, index: 3)
        write(third, seconds: 1)
        // Zero the third file's sizes, like a recording the app never closed.
        if let h = try? FileHandle(forUpdating: third) {
            try? h.seek(toOffset: 4); h.write(Data([0, 0, 0, 0]))
            try? h.seek(toOffset: 0)
            if let head = try? h.read(upToCount: 4096), let r = head.range(of: Data("data".utf8)) {
                try? h.seek(toOffset: UInt64(r.upperBound)); h.write(Data([0, 0, 0, 0]))
            }
            try? h.close()
        }
        RecordingSegments.joinLeftovers(in: dir)
        let frames = (try? AVAudioFile(forReading: base))?.length ?? 0
        let left = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != base.lastPathComponent }
        Log.note("UITEST segments joined frames=\(frames) leftover=\(left)")
        check("segments join into one recording", abs(Int(frames) - 48_000) <= 400 && left.isEmpty)

        // A join the app died in the middle of. Bytes per second of 16 kHz 16-bit mono: 32,000.
        func frameCount(_ u: URL) -> Int { Int((try? AVAudioFile(forReading: u))?.length ?? -1) }
        func clean() { for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) } }
        // Roll forward: every byte already appended, the segment not yet deleted.
        clean()
        write(base, seconds: 2)
        let seg2 = RecordingSegments.url(for: base, index: 2)
        write(seg2, seconds: 1)
        try? RecordingSegments.writeMarker(.init(base: base.lastPathComponent, originalLength: 32_000, expectedLength: 64_000,
                                                 segments: [seg2.lastPathComponent], renamedFrom: nil), in: dir)
        RecordingSegments.joinLeftovers(in: dir)
        var rest = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != base.lastPathComponent }
        Log.note("UITEST join roll-forward frames=\(frameCount(base)) leftover=\(rest)")
        check("interrupted join rolls forward", abs(frameCount(base) - 32_000) <= 200 && rest.isEmpty)
        // Roll back: half of the segment appended when the app died. Cut back, then joined again: 2 s, nothing left.
        clean()
        write(base, seconds: 1.5)
        write(seg2, seconds: 1)
        try? RecordingSegments.writeMarker(.init(base: base.lastPathComponent, originalLength: 32_000, expectedLength: 64_000,
                                                 segments: [seg2.lastPathComponent], renamedFrom: nil), in: dir)
        RecordingSegments.joinLeftovers(in: dir)
        rest = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != base.lastPathComponent }
        Log.note("UITEST join roll-back frames=\(frameCount(base)) leftover=\(rest)")
        check("interrupted join rolls back and rejoins", abs(frameCount(base) - 32_000) <= 200 && rest.isEmpty)
        // An unreadable middle segment no longer strands the parts after it: both readable parts are joined (the
        // 14-byte file stands for no time at all) and the bad one is set aside, not deleted.
        clean()
        write(base, seconds: 1)
        try? Data("not a wav file".utf8).write(to: seg2)
        let seg3 = RecordingSegments.url(for: base, index: 3)
        write(seg3, seconds: 1)
        RecordingSegments.joinLeftovers(in: dir)
        rest = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != base.lastPathComponent }
        Log.note("UITEST join around unreadable frames=\(frameCount(base)) leftover=\(rest)")
        check("join with an unreadable segment keeps every readable part", abs(frameCount(base) - 32_000) <= 200
              && rest.count == 1 && rest[0].hasPrefix("Unreadable "))
        check("segment numbers past 999 parse", RecordingSegments.parse(RecordingSegments.url(for: base, index: 1000))?.index == 1000)

        // Filler rules: answers and questions stay.
        check("filler keeps answers and questions",
              !Segment(start: 0, end: 1, text: "Uh-huh.").isFillerOnly && !Segment(start: 0, end: 1, text: "Hmm?").isFillerOnly
              && !Segment(start: 0, end: 1, text: "Mm-hmm.").isFillerOnly && Segment(start: 0, end: 1, text: "Um.").isFillerOnly)
        var turns = Transcript(title: "Turns", source: .voiceMemo, sourceLabel: "Voice memo", duration: 3, audioFileName: nil, model: "")
        turns.segments = [Segment(start: 0, end: 1, text: "Did you sign it?", speaker: "S1"), Segment(start: 1, end: 2, text: "Um.", speaker: "S2"),
                          Segment(start: 2, end: 3, text: "Okay, take your time.", speaker: "S1"), Segment(start: 3, end: 4, text: "Uh.", speaker: "S1")]
        let shown = turns.visibleSegments(hideFiller: true).map(\.text)
        check("filler hides only within a speaker's turn", shown == ["Did you sign it?", "Um.", "Okay, take your time."])

        // You page: websites by domain only.
        check("site host from a web address", SiteHost.host(from: "https://mail.google.com/mail/u/0/#inbox") == "mail.google.com"
              && SiteHost.host(from: "  HTTPS://www.Notion.so/page?x=1 ") == "notion.so" && SiteHost.host(from: "https://example.com.") == "example.com")
        check("site host drops ports and sign-ins", SiteHost.host(from: "http://localhost:3000/app") == "localhost"
              && SiteHost.host(from: "https://user:pw@Example.COM:8443/a") == "example.com" && SiteHost.host(from: "https://[2001:db8::1]:8080/") == "[2001:db8::1]")
        check("site host keeps international names", SiteHost.host(from: "https://Bücher.de/katalog") == "bücher.de" && SiteHost.host(from: "https://xn--bcher-kva.de/") == "xn--bcher-kva.de")
        check("site host is nil for other schemes", [("file:///Users/a/b.html"), "about:blank", "chrome://newtab/", "javascript:alert(1)", "", "https://", "https://www.", "mailto:a@b.co", "ftp://x.org"]
              .allSatisfy { SiteHost.host(from: $0) == nil })
        check("browsers that can be asked", BrowserTabs.isSupported("com.google.Chrome") && BrowserTabs.isSupported("company.thebrowser.Browser")
              && BrowserTabs.isSupported("com.apple.Safari") && !BrowserTabs.isSupported("org.mozilla.firefox") && !BrowserTabs.isSupported(nil))
        // You page: weeks start on the region's first weekday.
        var gc = Calendar(identifier: .gregorian); gc.timeZone = TimeZone(identifier: "UTC")!
        let wed = gc.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!
        gc.firstWeekday = 1
        let sunWeek = YouRange.interval(.week, containing: wed, calendar: gc)
        gc.firstWeekday = 2
        let monWeek = YouRange.interval(.week, containing: wed, calendar: gc)
        check("week starts on Sunday or Monday by region", gc.component(.day, from: sunWeek.start) == 18 && gc.component(.day, from: monWeek.start) == 19
              && YouRange.days(in: monWeek, calendar: gc).count == 7 && gc.component(.weekday, from: monWeek.start) == 2)
        gc.firstWeekday = 1
        let newYear = YouRange.interval(.week, containing: gc.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 9))!, calendar: gc)
        let back = YouRange.interval(.week, containing: YouRange.shifted(wed, .week, by: -3, calendar: gc), calendar: gc)
        check("week math crosses months and years", gc.component(.day, from: newYear.start) == 27 && gc.component(.month, from: newYear.start) == 12
              && gc.component(.day, from: back.start) == 27 && gc.component(.month, from: back.start) == 9)
        let oct = YouRange.interval(.month, containing: wed, calendar: gc)
        check("month has its days", YouRange.days(in: oct, calendar: gc).count == 31
              && YouRange.days(in: YouRange.interval(.month, containing: gc.date(from: DateComponents(year: 2027, month: 2, day: 10))!, calendar: gc), calendar: gc).count == 28
              && YouRange.isCurrent(oct, now: wed) && !YouRange.isCurrent(monWeek, now: oct.end))
        // Sidebar: saved order and hidden items.
        let known = ["home", "library", "links", "you"]
        check("sidebar order keeps yours, drops unknown, adds new at the end",
              SidebarRules.merge(saved: ["you", "gone", "home", "you"], known: known) == ["you", "home", "library", "links"]
              && SidebarRules.merge(saved: [], known: known) == known)
        check("sidebar never hides Settings or everything",
              SidebarRules.sanitizeHidden(["settings", "links", "gone"], known: known) == ["links"]
              && SidebarRules.sanitizeHidden(known, known: known).isEmpty
              && !SidebarRules.canHide("settings", hidden: [], known: known)
              && !SidebarRules.canHide("you", hidden: ["home", "library", "links"], known: known)
              && SidebarRules.canHide("you", hidden: ["home"], known: known)
              && !SidebarRules.canHide("gone", hidden: [], known: known))
        check("sidebar move", SidebarRules.move("you", to: "library", in: known) == ["home", "you", "library", "links"]
              && SidebarRules.move("home", to: "links", in: known) == ["library", "links", "home", "you"])
        cleanupChecks(check)
        VocabularySelfTest.run(check)
        OriginalCleanedSelfTest.run(check)
        check("settings search finds built-in vocabulary", SettingsIndex.search("chatgpt spelling").map(\.id).contains("models.builtInVocabulary"))
        HomeSelfTest.run(check)
        AudioDuckerSelfTest.run(check)
        check("settings search finds the Method cards", SettingsIndex.search("method cards").map(\.id).contains("general.welcomeCard"))
    }

    /// Dictation cleanup rules (CleanupPrepass), Harper's grammar pass, and the guards. No model, no network.
    private static func cleanupChecks(_ check: (String, Bool) -> Void) {
        func clean(_ input: String, _ want: String) {
            let got = CleanupPrepass.clean(input)
            if got != want { Log.note("UITEST cleanup got “\(got)” for “\(input)”") }
            check("cleanup: \(input)", got == want)
        }
        // Filler sounds
        clean("Um, I think we should go.", "I think we should go.")
        clean("um so I think we should uh meet on Thursday", "So I think we should meet on Thursday")
        clean("So, um, I think it works.", "So, I think it works.")
        clean("And, uh, then we left.", "And then we left.")
        clean("We should, um.", "We should.")
        clean("Um. Let's start.", "Let's start.")
        clean("Uh... so the plan is set.", "So the plan is set.")
        clean("Hmm, let me check. Er, the file is there.", "Let me check. The file is there.")
        clean("I need, uh, three copies.", "I need three copies.")
        clean("If you're free tomorrow, um, let's meet.", "If you're free tomorrow, let's meet.")
        clean("Erm, okay, let's go.", "Okay, let's go.")
        clean("Um, um, um.", "")
        // Filler sounds that stay
        clean("The cut is 5 mm wide.", "The cut is 5 mm wide.")
        clean("Take him to the ER now.", "Take him to the ER now.")
        clean("Huh? What did you say?", "Huh? What did you say?")
        clean("Uh-huh, that's right.", "Uh-huh, that's right.")
        clean("Uh huh, that's right.", "Uh huh, that's right.")
        clean("Mm hmm.", "Mm hmm.")
        clean("Grab the umbrella and the hummus.", "Grab the umbrella and the hummus.")
        // "You know"
        clean("You know, I think we should wait.", "I think we should wait.")
        clean("It was hard, you know.", "It was hard.")
        clean("It's tough, you know?", "It's tough, you know?")
        clean("Do you know the answer?", "Do you know the answer?")
        clean("You know the answer?", "You know the answer?")
        clean("As you know, the budget is tight.", "As you know, the budget is tight.")
        clean("I told him, you know the drill.", "I told him, you know the drill.")
        // "I mean"
        clean("I mean, it's fine.", "It's fine.")
        clean("I mean it.", "I mean it.")
        clean("I mean what I say.", "I mean what I say.")
        // A correction after "I mean" keeps the final value (SpokenCorrections).
        clean("Let's meet Tuesday. I mean, Wednesday.", "Let's meet Wednesday.")
        clean("It costs 50, I mean, 60 dollars.", "It costs 60 dollars.")
        // "Like"
        clean("I like it.", "I like it.")
        clean("It was, like, really good.", "It was really good.")
        clean("Like, I don't know.", "I don't know.")
        clean("There were, like, 50 people.", "There were, like, 50 people.")
        clean("We need a few things, like, the photos.", "We need a few things, like, the photos.")
        clean("Like I said, it works.", "Like I said, it works.")
        clean("I'd like, um, two coffees.", "I'd like two coffees.")
        // Stutters, repeats, and false starts
        clean("I-I-I think so.", "I think so.")
        clean("It was so-so, bye-bye.", "It was so-so, bye-bye.")
        clean("th- the dog ran", "The dog ran")
        clean("We need pre- and post-production.", "We need pre- and post-production.")
        clean("I had had enough.", "I had had enough.")
        clean("No no, that's wrong.", "No no, that's wrong.")
        clean("I think I think we should go.", "I think we should go.")
        clean("We went to Bora Bora.", "We went to Bora Bora.")
        clean("We should — we need to finish today.", "We need to finish today.")
        clean("I was going to -- I'll call you later.", "I'll call you later.")
        clean("We have three options — red, blue, and green.", "We have three options — red, blue, and green.")
        clean("The plan - the new one - is ready.", "The plan - the new one - is ready.")
        // Together
        clean("um hi Sarah comma uh I wanted to follow up on the proposal period", "Hi Sarah, I wanted to follow up on the proposal.")
        clean("Hi team, um, quick update. The, uh, the shoot moved to Friday. Uh, let me know if, you know, that works.",
              "Hi team, quick update. The shoot moved to Friday. Let me know if that works.")
        check("cleanup: Literal keeps fillers", CleanupPrepass.literal("um I like it") == "Um I like it")

        // Harper's grammar pass and its guard
        check("grammar fixes a/an, capitals, and i", GrammarPass.fix("i think we should send a email. it's a easy fix.") == "I think we should send an email. It's an easy fix.")
        check("grammar keeps had had and iPhone", GrammarPass.fix("I had had enough. iPhone sales are up.") == "I had had enough. iPhone sales are up.")
        check("grammar keeps line breaks", GrammarPass.fix("Three things:\n1. The photos\n2. the copy") == "Three things:\n1. The photos\n2. The copy")
        check("grammar guard rejects a changed number", !GrammarPass.accepts(original: "I sent 500 units.", fixed: "I sent 50 units."))
        check("grammar guard rejects a dropped not", !GrammarPass.accepts(original: "I do not agree.", fixed: "I do agree."))
        check("grammar guard rejects IPhone", !GrammarPass.accepts(original: "iPhone sales", fixed: "IPhone sales"))
        check("grammar guard rejects changed punctuation", !GrammarPass.accepts(original: "Yes, we can.", fixed: "Yes we can."))

        // Guards: Polished may tighten rambling to 40%; Clean keeps 50%.
        let ramble = "So basically what I was kind of thinking is that we should probably sort of move the shoot to Friday."
        check("polished may tighten rambling", MeaningCheck.problem(raw: ramble, output: "I think we should move the shoot to Friday.", limits: .polished) == nil)
        check("clean keeps the 50% floor", MeaningCheck.problem(raw: ramble, output: "I think we should move the shoot to Friday.", limits: .clean) != nil)
        check("polished still catches a changed day", MeaningCheck.problem(raw: ramble, output: "I think we should move the shoot to Monday.", limits: .polished) != nil)

        // Cloud cleanup: off by default, never configured without a key.
        check("cloud cleanup is off by default", UserDefaults.standard.object(forKey: CloudCleanup.enabledKey) != nil || CloudCleanup.current == nil)
        check("cloud cleanup privacy line", CloudCleanup.privacyNote(.openai) == "Your words are sent to OpenAI for cleanup. Your audio stays on this device.")
        check("cloud cleanup default models", CloudCleanup.Provider.anthropic.defaultModel == "claude-haiku-5-5" && CloudCleanup.Provider.openai.defaultModel == "gpt-5.4-mini")
        check("settings search finds cloud cleanup", SettingsIndex.search("api key").map(\.id).contains("dictate.cloudKey"))

        // Formatting by destination: email greetings, sign-offs, and paragraphs; Slack and Messages; the rules after
        // the model; and the app and website classifier (DestinationChecks, also run by mac/tools/test-formatter.sh).
        for r in DestinationChecks.run() {
            check("destination: \(r.name)", r.ok)
            if !r.ok { Log.note("UITEST detail: " + r.detail.replacingOccurrences(of: "\n", with: "⏎")) }
        }
        check("settings search finds the email layout", SettingsIndex.search("greeting sign-off").map(\.id).contains("dictate.emailLines"))

        // Spoken corrections: every rule, chaining, start over, commands, and the keep-cases
        // (SpokenCorrectionsChecks, also run by mac/tools/test-formatter.sh and the iPhone self-test).
        for r in SpokenCorrectionsChecks.run() {
            check(r.name, r.ok)
            if !r.ok { Log.note("UITEST detail: " + r.detail.replacingOccurrences(of: "\n", with: "⏎")) }
        }
        check("settings search finds spoken corrections", SettingsIndex.search("scratch that").map(\.id).contains("dictate.spokenCorrections"))
        check("spoken corrections stay off the prompt when off",
              !FlowCleanup.instructions(level: .clean, corrections: false).contains("scratch that") && FlowCleanup.instructions(level: .clean, corrections: true).contains("scratch that"))
    }

    private static func step(_ name: String, _ window: NSWindow, target: String, check: () -> Bool) async {
        await reveal(target, in: window)
        click(target, in: window)
        try? await Task.sleep(nanoseconds: 900_000_000)
        let ok = check()
        if ok { pass += 1 } else { fail += 1 }
        Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name)")
    }

    /// Moves the pointer onto the target, then clicks it, through the window's own event path.
    private static func click(_ id: String, in main: NSWindow) {
        let window = id.hasPrefix("sheet-") ? (main.attachedSheet ?? main) : main
        guard let f = frames[id], let content = window.contentView else { Log.note("UITEST missing target \(id); known=\(frames.keys.sorted())"); return }
        let p = CGPoint(x: f.midX, y: content.bounds.height - f.midY)   // SwiftUI global (top-left) -> NSWindow (bottom-left)
        var chain: [String] = []
        var v = content.hitTest(p)
        while let x = v, chain.count < 7 { chain.append("\(type(of: x))[\(Int(x.frame.minX)),\(Int(x.frame.minY)) \(Int(x.frame.width))x\(Int(x.frame.height))]"); v = x.superview }
        var under = chain.joined(separator: " < ")
        if content.hitTest(p) is NSClipView {
            var all: [String] = []
            func walk(_ v: NSView, _ depth: Int) {
                if let sv = v as? NSScrollView {
                    let d = sv.documentView
                    all.append("\(type(of: sv))@\(depth)[\(Int(sv.frame.minX)),\(Int(sv.frame.minY)) \(Int(sv.frame.width))x\(Int(sv.frame.height))] doc=\(Int(d?.frame.height ?? -1)) hidden=\(sv.isHiddenOrHasHiddenAncestor) alpha=\(sv.alphaValue) subviews=\(d?.subviews.count ?? -1)")
                }
                v.subviews.forEach { walk($0, depth + 1) }
            }
            walk(content, 0)
            Log.note("UITEST scrollviews: " + all.joined(separator: " || "))
        }
        if let clip = content.hitTest(p) as? NSClipView {
            under += " | clip.bounds=\(Int(clip.bounds.minX)),\(Int(clip.bounds.minY)) doc=\(clip.documentView.map { "\(type(of: $0))[\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))] flipped=\($0.isFlipped)" } ?? "nil")"
        }
        Log.note("UITEST click \(id) frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) point=\(Int(p.x)),\(Int(p.y)) content=\(Int(content.bounds.width))x\(Int(content.bounds.height)) under=\(under)")
        let t = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber, context: nil, eventNumber: Int(t * 1000) % 100000, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        if let m = ev(.mouseMoved) { window.sendEvent(m) }
        if let d = ev(.leftMouseDown) { window.sendEvent(d) }
        if let u = ev(.leftMouseUp) { window.sendEvent(u) }
    }
}

/// Records a control's frame for the self-test. Free in release use: a GeometryReader in the background.
struct UITarget: ViewModifier {
    var id: String
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { UITest.frames[id] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in UITest.frames[id] = f }
        })
    }
}
extension View { func uiTarget(_ id: String) -> some View { modifier(UITarget(id: id)) } }
