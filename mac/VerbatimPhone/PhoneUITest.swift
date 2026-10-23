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
        keyboardChecks()
        KeyboardSessionChecks.run()   // Build E2: format chip, host map, App Store seams, session timeouts.
        ribbonChecks(app)             // The recording ribbon: routing, takes, timeouts, and the session's take API.
        libraryChecks()
        homeChecks()
        homeActionChecks(app)
        recorderChecks(app)
        // No lost recordings: write failures, joins around a corrupt part, discard, and recovery (shared with the Mac).
        RecordingSafetyChecks.run(store: app.store) { name, ok in Log.note("UITEST \(ok ? "PASS" : "FAIL") recording safety: \(name)") }
        // Imports through the bundled FFmpeg (MKV) and files with several audio tracks (shared with the Mac).
        Task { @MainActor in
            await MediaImportSelfTest.run { name, ok in Log.note("UITEST \(ok ? "PASS" : "FAIL") import: \(name)") }
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            for (prefix, mode) in [("p", "light"), ("d", "dark")] {
                app.appearance = mode
                app.tab = .home
                try? await Task.sleep(nanoseconds: 600_000_000)
                await show("\(prefix)01-home")
                // The rest of Home: This week, Recent recordings, Recent dictations, and the keyboard row.
                NotificationCenter.default.post(name: .verbatimHomeScroll, object: "home-recent")
                await show("\(prefix)01b-home-recent")
                NotificationCenter.default.post(name: .verbatimHomeScroll, object: "home-top")
                try? await Task.sleep(nanoseconds: 500_000_000)
                app.showRecorder = true
                await show("\(prefix)02-record")
                app.showRecorder = false
                try? await Task.sleep(nanoseconds: 600_000_000)
                // A recording with live text, then minimized to the bar over Library. A stand-in recording with
                // made-up words (no microphone or speech in the simulator).
                app.previewRecording = true
                app.recorder.live.setElapsed(252)
                app.recordingWords.seedForScreenshots()
                app.openRecorder()
                await show("\(prefix)02d-record-live-text")
                app.minimizeRecorder()
                try? await Task.sleep(nanoseconds: 600_000_000)
                app.tab = .library
                await show("\(prefix)02e-mini-recorder-library")
                app.tab = .home
                app.previewRecording = false
                app.recordingWords.clearScreenshots()
                app.recorder.live.reset()
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
                // Add from Library on the seeded project (made-up transcripts; nothing is added).
                if let project = app.store.projects.first(where: { $0.name == "Lapp Wagons" }) {
                    app.addFromLibrary = project.id
                    await show("\(prefix)04e-add-from-library")
                    app.addFromLibrary = nil
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
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
                // The recording ribbon: the Session ended screen after a call (made-up last take), then Settings ›
                // Action button (last, because it stays pushed on the Settings tab).
                app.session.endedNotice = KeyboardSession.EndedNotice(reason: Ribbon.endedReason(call: true),
                                                                      lastTake: "Thursday works. Noon at the usual place?",
                                                                      lastTakeAt: Date().addingTimeInterval(-120))
                await show("\(prefix)09d-session-ended")
                app.session.endedNotice = nil
                try? await Task.sleep(nanoseconds: 500_000_000)
                if prefix == "d" {
                    SettingsPage.open("actionButton")
                    await show("d09e-action-button")
                }
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

    /// The recording ribbon (RibbonRules.swift, KeyboardSession's take API): the owner's routing rule, the take
    /// state machine, the idle timeout, the Action button choice, the keyboard hand-off keys, and the session's
    /// actions called directly. No microphone in the simulator, so the take API is checked with no session: it must
    /// ask for the foreground and leave the audio session alone.
    static func ribbonChecks(_ app: PhoneState) {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") ribbon: \(name)")
        }
        let now = Date().timeIntervalSince1970
        check("keyboard up and showing the take: insert", Ribbon.route(keyboardVisibleAt: now - 1, keyboardShowsTake: true, now: now) == .keyboard)
        check("no keyboard: clipboard", Ribbon.route(keyboardVisibleAt: 0, keyboardShowsTake: false, now: now) == .clipboard)
        check("the keyboard route leaves the clipboard alone", !Ribbon.copies(.keyboard, alwaysCopy: false))
        check("a failed copy is reported", Ribbon.resultPhase(.clipboard, copied: false) == .failed)
        check("presses alternate", Ribbon.decide(.idle, .toggle, sessionOn: true) == .begin
              && { let i = UUID(); return Ribbon.decide(.listening(i), .toggle, sessionOn: true) == .finish(i) }())
        check("default idle timeout is 30 minutes", Ribbon.normalizedTimeout(nil) == 1800)
        check("the Action button dictates by default", Ribbon.actionChoice(nil) == .dictate)

        // The keyboard hand-off: a visible keyboard adopts a ribbon take; a take that went to the clipboard isn't inserted later.
        let t = UUID()
        check("a visible keyboard picks up the ribbon take",
              KeyboardBridge.ribbonTakeToAdopt(ribbonID: t, running: (id: t, phase: KeyboardBridge.Phase.listening))?.id == t)
        check("a keyboard doesn't adopt someone else's dictation",
              KeyboardBridge.ribbonTakeToAdopt(ribbonID: UUID(), running: (id: t, phase: KeyboardBridge.Phase.listening)) == nil)
        check("a take that went to the clipboard isn't inserted later",
              KeyboardBridge.runningDictation(id: t, phase: .done, insertedID: nil, cancelID: nil, routedAway: t.uuidString) == nil)
        check("a take routed to the keyboard still is",
              KeyboardBridge.runningDictation(id: t, phase: .done, insertedID: nil, cancelID: nil, routedAway: UUID().uuidString)?.id == t)

        // The session's take API with no session (the simulator has no microphone).
        let session = app.session
        let category = AVAudioSession.sharedInstance().category
        if !session.isOn {
            check("toggleTake with no session needs the foreground", session.toggleTake(source: .test) == .needsForeground)
            check("startTake with no session needs the foreground", session.startTake(source: .test) == .needsForeground)
            check("stopTake with no take does nothing", session.stopTake() == .ignored)
            check("cancelTake with no take does nothing", session.cancelTake() == .ignored)
            check("the take API leaves the session off", !session.isOn && !session.dictating)
            check("the take API doesn't touch the audio session", AVAudioSession.sharedInstance().category == category)
            check("the Dictate intent's command asks for the foreground", RibbonSignal.send(.toggle) == .needsForeground)
            check("Done from the Dynamic Island with no take is ignored", RibbonSignal.send(.finish) == .ignored)
            check("the Control Center switch on with no session asks for the foreground", RibbonSignal.send(.startSession) == .needsForeground)
        }
        check("settings search finds the Action button",
              SettingsSearchIndex.search("action button").flatMap(\.entries).contains { $0.id == "actionButton" })
        check("settings search finds the idle timeout", SettingsSearchIndex.search("idle").flatMap(\.entries).contains { $0.id == "actionButtonTimeout" })
        Log.note("UITEST ribbon checks: \(pass) passed, \(fail) failed")
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

    /// Home's greeting, This week, and counts (shared with the Mac's self-test).
    static func homeChecks() {
        var pass = 0, fail = 0
        HomeSelfTest.run { name, ok in
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name)")
        }
        Log.note("UITEST home checks: \(pass) passed, \(fail) failed")
    }

    /// What Home's cards do when tapped (the Mac's self-test clicks them; here the same actions run directly):
    /// This week opens your profile, and a Recent dictations row puts its words on the clipboard.
    static func homeActionChecks(_ app: PhoneState) {
        func check(_ name: String, _ ok: Bool) { Log.note("UITEST \(ok ? "PASS" : "FAIL") home: \(name)") }
        let tab = app.tab
        HomeScreen.openProfile(app)
        check("This week opens About me in Settings", app.tab == .settings)
        _ = SettingsPage.take()
        app.tab = tab
        let newest = app.store.live.filter { $0.isDictation }.max { $0.createdAt < $1.createdAt }
        let text = newest.map { HomeDictationText.pasted($0) } ?? "Running ten minutes late, save me a seat."
        UIPasteboard.general.string = ""
        HomeScreen.copyDictation(text)
        check("a dictation row copies its words", UIPasteboard.general.string == text)
    }

    /// The minimized recorder (MiniRecorder.swift): minimizing never stops the recording, reopening keeps its
    /// elapsed time, Record reopens instead of starting a second recording, and live captions ask you to finish
    /// first. The pure rules, then PhoneState itself with the stand-in recording (no microphone in the simulator).
    static func recorderChecks(_ app: PhoneState) {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") recorder: \(name)")
        }
        typealias P = RecorderPresentation
        let running = P.State(recording: true, paused: false, fullScreen: true, elapsed: 252)
        let small = P.minimize(running)
        check("minimize hides the full screen", !small.fullScreen)
        check("minimize doesn't stop or pause the recording", small.recording && small.paused == running.paused)
        check("minimize keeps a paused recording paused", P.minimize(P.State(recording: true, paused: true, fullScreen: true, elapsed: 9)).paused)
        let back = P.reopen(small)
        check("reopen shows the full screen with the same elapsed time", back.fullScreen && back.elapsed == 252 && back.recording)
        check("reopen without a recording shows nothing", !P.reopen(P.State(recording: false, paused: false, fullScreen: false, elapsed: 0)).fullScreen)
        check("Record reopens while recording", P.recordTap(recording: true, saving: false) == .reopen)
        check("Record reopens while saving", P.recordTap(recording: false, saving: true) == .reopen)
        check("Record starts a new recording when nothing is recording", P.recordTap(recording: false, saving: false) == .start)
        check("the bar shows while recording or saving", P.showsBar(recording: true, saving: false) && P.showsBar(recording: false, saving: true))
        check("no bar without a recording", !P.showsBar(recording: false, saving: false))
        check("bar clock", P.clock(252) == "4:12" && P.clock(5) == "0:05" && P.clock(3725) == "1:02:05")
        check("bar VoiceOver label", P.accessibilityLabel(paused: false, saving: false, elapsed: 252) == "Recording, 4 minutes 12 seconds")
        check("bar VoiceOver label when paused", P.accessibilityLabel(paused: true, saving: false, elapsed: 61) == "Paused, 1 minute 1 second")
        let stored = UserDefaults.standard.object(forKey: RecordingLiveText.enabledKey)
        UserDefaults.standard.removeObject(forKey: RecordingLiveText.enabledKey)
        check("show words while you record is on by default", RecordingLiveText.enabled)
        UserDefaults.standard.set(stored, forKey: RecordingLiveText.enabledKey)
        check("settings search finds show words while you record",
              SettingsSearchIndex.search("live text").flatMap(\.entries).contains { $0.id == "recordLiveWords" })

        // PhoneState, with the stand-in recording.
        app.previewRecording = true
        app.recorder.live.setElapsed(252)
        app.showRecorder = true
        app.minimizeRecorder()
        check("PhoneState: minimize hides the full screen and keeps the recording",
              !app.showRecorder && app.recordingActive && app.recorder.live.elapsed == 252)
        app.requestRecord()
        check("PhoneState: Record reopens the recording instead of starting a new one",
              app.showRecorder && !app.recorder.isRecording && app.recorder.live.elapsed == 252 && !app.showConsentNotice)
        app.minimizeRecorder()
        app.requestCaptions()
        check("PhoneState: live captions ask you to finish the recording first", app.finishRecordingFirst == "live captions" && !app.showCaptions)
        app.finishRecordingFirst = nil
        app.showRecorder = false
        app.previewRecording = false
        app.recorder.live.reset()
        app.openRecorder()
        check("PhoneState: nothing to reopen without a recording", !app.showRecorder)
        Log.note("UITEST recorder checks: \(pass) passed, \(fail) failed")
    }

    /// The Library's type and platform filters and Add from Library (shared with the Mac's self-test).
    static func libraryChecks() {
        var pass = 0, fail = 0
        LibraryFilterChecks.run { name, ok in
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") library: \(name)")
        }
        // Transcript actions, Library sort and search, synced playback (shared with the Mac's self-test).
        ActionsHistoryChecks.run { name, ok in
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name)")
        }
        Log.note("UITEST library checks: \(pass) passed, \(fail) failed")
    }

    /// The keyboard's first-tap logic, which a simulator can't exercise end to end (it can't run keyboards):
    /// the session link round trip, what a reappearing keyboard picks up, the one-minute stop for a dictation
    /// nobody came back to, the setting's default, and the search entry. Results go to the log as UITEST lines.
    static func keyboardChecks() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") keyboard: \(name)")
        }
        let r = UUID(), d = UUID()
        let link = KeyboardBridge.sessionLink(in: KeyboardBridge.sessionURL(request: r, host: "com.apple.MobileSMS", dictation: d))
        check("session link carries the first-tap dictation", link == KeyboardBridge.SessionLink(request: r, host: "com.apple.MobileSMS", dictation: d))
        let plain = KeyboardBridge.sessionLink(in: KeyboardBridge.sessionURL(request: r, host: nil))
        check("session link without host or dictation", plain == KeyboardBridge.SessionLink(request: r, host: nil, dictation: nil))

        check("a listening dictation is picked up", KeyboardBridge.runningDictation(id: d, phase: .listening, insertedID: nil, cancelID: nil)?.phase == .listening)
        check("a done dictation is picked up to insert", KeyboardBridge.runningDictation(id: d, phase: .done, insertedID: nil, cancelID: nil)?.id == d)
        check("an inserted dictation isn't picked up again", KeyboardBridge.runningDictation(id: d, phase: .done, insertedID: d.uuidString, cancelID: nil) == nil)
        check("a cancelled dictation isn't picked up", KeyboardBridge.runningDictation(id: d, phase: .listening, insertedID: nil, cancelID: d) == nil)
        check("a failed dictation isn't picked up", KeyboardBridge.runningDictation(id: d, phase: .failed, insertedID: nil, cancelID: nil) == nil)

        let t0 = Date()
        check("an unseen first-tap dictation keeps listening under a minute",
              !KeyboardBridge.shouldStopUnseenTake(startedAt: t0, seen: false, now: t0.addingTimeInterval(59)))
        check("an unseen first-tap dictation stops after a minute",
              KeyboardBridge.shouldStopUnseenTake(startedAt: t0, seen: false, now: t0.addingTimeInterval(60)))
        check("a dictation the keyboard showed never stops for that",
              !KeyboardBridge.shouldStopUnseenTake(startedAt: t0, seen: true, now: t0.addingTimeInterval(600)))

        let stored = KeyboardBridge.defaults?.object(forKey: KeyboardBridge.Key.autoStart)
        KeyboardBridge.defaults?.removeObject(forKey: KeyboardBridge.Key.autoStart)
        check("start dictating when you come back is on by default", KeyboardBridge.autoStart)
        KeyboardBridge.defaults?.set(stored, forKey: KeyboardBridge.Key.autoStart)

        let pa = KeyboardBridge.defaults?.object(forKey: KeyboardBridge.Key.polishAfter)
        KeyboardBridge.defaults?.removeObject(forKey: KeyboardBridge.Key.polishAfter)
        check("polish after inserting is on by default", KeyboardBridge.polishAfter)
        KeyboardBridge.defaults?.set(pa, forKey: KeyboardBridge.Key.polishAfter)
        let lw = KeyboardBridge.defaults?.object(forKey: KeyboardBridge.Key.liveWords)
        KeyboardBridge.defaults?.removeObject(forKey: KeyboardBridge.Key.liveWords)
        check("keyboard live words are on by default", KeyboardBridge.liveWords)
        KeyboardBridge.defaults?.set(lw, forKey: KeyboardBridge.Key.liveWords)

        // Polish after inserting: the background budget, and when the keyboard may swap the text.
        check("polish budget starts at 2 s", KeyboardBridge.polishBudget(words: 0) == 2)
        check("polish budget grows 0.05 s a word", abs(KeyboardBridge.polishBudget(words: 100) - 7) < 0.001)
        check("polish budget stops at 10 s", KeyboardBridge.polishBudget(words: 1_000) == 10)
        let ins = " Um, so I think we should, uh, meet Tuesday."
        let pol = " I think we should meet Tuesday."
        func swap(_ before: String?, same: Bool = true, age: TimeInterval = 3, polished: String = pol) -> KeyboardBridge.SwapDecision {
            KeyboardBridge.polishSwap(inserted: ins, polished: polished, before: before, sameField: same, age: age)
        }
        check("swap when the field ends with the inserted text", swap("Hi Sam." + ins) == .replace)
        check("swap when the inserted text is the whole field", swap(ins) == .replace)
        check("keep when you typed after the inserted text", swap("Hi Sam." + ins + " See you") != .replace)
        check("keep when you deleted part of the inserted text", swap("Hi Sam." + String(ins.dropLast(5))) != .replace)
        check("keep in a different text field", swap("Hi Sam." + ins, same: false) == .keep("a different text field"))
        check("keep when the field shows nothing before the cursor", swap(nil) != .replace && swap("") != .replace)
        check("keep when the polished text arrives too late", swap(ins, age: KeyboardBridge.polishWindow + 1) != .replace)
        check("keep when the polished text is empty", swap(ins, polished: "  ") != .replace)
        check("keep when nothing changed", swap(ins, polished: ins) == .keep("nothing changed"))
        check("swap when iOS cuts the context but 16+ characters match", swap("should, uh, meet Tuesday.") == .replace)
        check("keep when too little of a cut context matches", swap("Tuesday.") != .replace)
        let para = " First point.\n\nSecond."
        check("swap when the context starts after a line break in the inserted text",
              KeyboardBridge.polishSwap(inserted: para, polished: " First.\n\nSecond.", before: "Second.", sameField: true, age: 2) == .replace)

        // The keyboard's Recent row: newest first, one entry per dictation, at most 10 of about 2 KB each.
        let t = Date()
        var recent: [KeyboardBridge.Recent] = []
        let ids = (0..<12).map { _ in UUID() }
        for (i, id) in ids.enumerated() { recent = KeyboardBridge.addingRecent(recent, .init(id: id, text: "Dictation \(i)", date: t.addingTimeInterval(Double(i)))) }
        check("recent: newest first, capped at 10", recent.count == 10 && recent.first?.text == "Dictation 11" && recent.last?.text == "Dictation 2")
        recent = KeyboardBridge.addingRecent(recent, .init(id: ids[5], text: "Dictation 5 again", date: t.addingTimeInterval(20)))
        check("recent: the same dictation moves to the front once", recent.count == 10 && recent.first?.text == "Dictation 5 again"
              && recent.filter { $0.id == ids[5] }.count == 1)
        check("recent: empty text is skipped", KeyboardBridge.addingRecent(recent, .init(id: UUID(), text: "  \n", date: t)) == recent)
        let polishedList = KeyboardBridge.replacingRecent(recent, id: ids[11], text: "Polished eleven.")
        check("recent: the polished text replaces it in place", polishedList.map(\.id) == recent.map(\.id)
              && polishedList.first { $0.id == ids[11] }?.text == "Polished eleven.")
        let big = String(repeating: "é", count: 3_000)
        let clipped = KeyboardBridge.clip(big)
        check("recent: long text is cut to 2 KB", clipped.utf8.count <= KeyboardBridge.recentMaxBytes && clipped.hasSuffix("…")
              && KeyboardBridge.clip("short") == "short")
        let storedRecent = KeyboardBridge.defaults?.data(forKey: KeyboardBridge.recentKey)
        KeyboardBridge.defaults?.removeObject(forKey: KeyboardBridge.recentKey)
        let a = UUID()
        KeyboardBridge.addRecent(id: a, text: "From the App Group")
        KeyboardBridge.updateRecent(id: a, text: "From the App Group, polished")
        check("recent: round trip through the App Group", KeyboardBridge.readRecent().first.map { $0.id == a && $0.text == "From the App Group, polished" } ?? false)
        KeyboardBridge.defaults?.set(storedRecent, forKey: KeyboardBridge.recentKey)
        let ac = KeyboardBridge.defaults?.object(forKey: KeyboardBridge.alwaysCopyKey)
        KeyboardBridge.defaults?.removeObject(forKey: KeyboardBridge.alwaysCopyKey)
        check("also copy each dictation is off by default", !KeyboardBridge.alwaysCopy)
        KeyboardBridge.defaults?.set(ac, forKey: KeyboardBridge.alwaysCopyKey)
        check("settings search finds also copy each dictation",
              SettingsSearchIndex.search("clipboard").flatMap(\.entries).contains { $0.id == "keyboardAlwaysCopy" })

        check("settings search finds lower other audio",
              SettingsSearchIndex.search("music").flatMap(\.entries).contains { $0.id == "keyboardLowerAudio" })
        check("settings search finds polish after inserting",
              SettingsSearchIndex.search("polish").flatMap(\.entries).contains { $0.id == "keyboardPolishAfter" })
        check("settings search finds keyboard live words",
              SettingsSearchIndex.search("live words").flatMap(\.entries).contains { $0.id == "keyboardLiveWords" })
        check("settings search finds the first-tap setting",
              SettingsSearchIndex.search("second tap").flatMap(\.entries).contains { $0.id == "keyboardAutoStart" })
        check("settings search finds cloud cleanup",
              SettingsSearchIndex.search("api key").flatMap(\.entries).contains { $0.id == "cloudCleanup" })
        check("cloud cleanup is off by default", UserDefaults.standard.object(forKey: CloudCleanup.enabledKey) != nil || !CloudCleanup.enabled)
        check("cleanup removes fillers on the iPhone", CleanupPrepass.clean("Um, I think, you know, it works.") == "I think it works.")
        // Spoken corrections, the same cases as the Mac (SpokenCorrectionsChecks), plus the keyboard's live words.
        for r in SpokenCorrectionsChecks.run() { check("iPhone " + r.name, r.ok) }
        check("keyboard live words strike a correction",
              SpokenCorrections.liveSpans("meet at 2, actually 3", limit: 90).contains { $0.style == .removed && $0.text.contains("2") })
        check("keyboard live words keep plain speech plain",
              SpokenCorrections.liveSpans("I actually like it", limit: 90).allSatisfy { $0.style == .kept })
        check("settings search finds spoken corrections",
              SettingsSearchIndex.search("scratch that").flatMap(\.entries).contains { $0.id == "spokenCorrections" })
        check("grammar pass fixes a/an and capitals on the iPhone", GrammarPass.fix("i sent a email.") == "I sent an email.")
        check("switching back to the host app is off in UI tests", KeyboardSession.returnToHostApp(linkHost: "com.apple.MobileSMS") == .failed("UI test", retry: false))
        VocabularySelfTest.run(check)
        OriginalCleanedSelfTest.run(check)
        check("settings search finds built-in vocabulary",
              SettingsSearchIndex.search("modern words").flatMap(\.entries).contains { $0.id == "builtInVocabulary" })
        // Cloud share links, the same cases as the Mac (CloudShareLinkChecks); no network.
        for r in CloudShareLinkChecks.run() { check("iPhone " + r.name, r.ok) }
        check("cloud links aren't podcast shows", !PhoneLinkFetcher.isShowLink(URL(string: "https://www.dropbox.com/s/abc/feed.mp3?dl=0")!))
        recordingChecks(check)
        Log.note("UITEST keyboard checks: \(pass) passed, \(fail) failed")
    }

    /// After a call: when a recording resumes and on which input; and the recording Live Activity's content.
    static func recordingChecks(_ check: (String, Bool) -> Void) {
        check("recording: an interruption resumes only with shouldResume",
              InterruptionPolicy.shouldResume(pausedForInterruption: true, isRecording: true, isPaused: true, systemSaysResume: true)
              && !InterruptionPolicy.shouldResume(pausedForInterruption: true, isRecording: true, isPaused: true, systemSaysResume: false)
              && !InterruptionPolicy.shouldResume(pausedForInterruption: false, isRecording: true, isPaused: true, systemSaysResume: true))
        check("recording: resuming keeps AirPods while they're connected",
              InterruptionPolicy.input(pinned: "airpods", available: ["mic", "airpods"], builtIn: "mic") == "airpods"
              && InterruptionPolicy.input(pinned: "airpods", available: ["mic"], builtIn: "mic") == "mic")
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let running = VerbatimRecordingAttributes.ContentState.make(elapsed: 65, isPaused: false, pausedReason: "Paused for a call", now: now)
        check("recording activity: running counts from the start, with no reason",
              running.startDate == now.addingTimeInterval(-65) && running.pauseTime == nil && running.pausedReason == nil && running.status == "Recording")
        let paused = VerbatimRecordingAttributes.ContentState.make(elapsed: 65, isPaused: true, pausedReason: "Paused for a call", now: now)
        check("recording activity: paused holds the timer and shows the reason",
              paused.pauseTime == now && paused.elapsed == 65 && paused.status == "Paused for a call")
        let saved = VerbatimRecordingAttributes.ContentState.make(elapsed: 65, isPaused: false, pausedReason: "x", saved: true, now: now)
        check("recording activity: saved stops the timer and drops the reason",
              saved.isPaused && saved.pausedReason == nil && saved.status.hasPrefix("Saved"))
        check("recording activity: odd elapsed values never go negative",
              VerbatimRecordingAttributes.ContentState.make(elapsed: -3, isPaused: true, pausedReason: nil, now: now).elapsed == 0
              && VerbatimRecordingAttributes.ContentState.make(elapsed: .nan, isPaused: true, pausedReason: nil, now: now).elapsed == 0)
        check("recording activity: short reasons",
              VerbatimRecordingAttributes.shortReason(Recorder.callPausedNotice) == "Paused for a call. Open Verbose."
              && VerbatimRecordingAttributes.shortReason(Recorder.audioRestartedNotice) == "Audio restarted. Tap Resume."
              && VerbatimRecordingAttributes.shortReason(Recorder.interruptionBeganNotice) == "Paused for a call"
              && VerbatimRecordingAttributes.shortReason(nil) == nil)
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
