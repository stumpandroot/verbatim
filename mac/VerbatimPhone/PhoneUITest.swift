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
        lookChecks()
        // What's new: the bundled notes, their rules, and when Home's note shows (ReleaseNotes.swift).
        ReleaseNotes.selfTest { name, ok in Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name)") }
        homeChecks()
        homeActionChecks(app)
        recorderChecks(app)
        premiumChecks(app)
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
                if prefix == "p" { homeLayoutCheck(.verbose) }
                // The rest of Home: This week, Recent recordings, Recent dictations, and the keyboard row.
                NotificationCenter.default.post(name: .verbatimHomeScroll, object: "home-recent")
                await show("\(prefix)01b-home-recent")
                NotificationCenter.default.post(name: .verbatimHomeScroll, object: "home-top")
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Home's note after an update, then What's new, which it opens (WhatsNewScreen.swift).
                await whatsNewTour(app, prefix: prefix, suffix: "")
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
                // A long transcript held mid-drag on the scrubber: the handle, and the bubble with the time and the
                // speaker you'd land on (TranscriptScrubber.swift).
                if let long = app.store.live.first(where: { $0.title == Self.longTitle }) {
                    app.tab = .library
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    app.libraryPath.append(long.id)
                    try? await Task.sleep(nanoseconds: 1_600_000_000)   // pushed, laid out, and measured
                    TranscriptScrubber.lastLanding = nil
                    NotificationCenter.default.post(name: .verbatimScrubPreview, object: 0.62)
                    await show("\(prefix)05d-transcript-scrubber")
                    if prefix == "p" {
                        let landed = TranscriptScrubber.lastLanding ?? ""
                        Log.note("UITEST \(landed.contains(" · ") ? "PASS" : "FAIL") scrubber: a drag lands on a line and names its time and speaker (\(landed))")
                        // One scale: a drag to a fraction of the track lands on the line at that fraction of the
                        // recording (the last line at the bottom), and once let go, the handle measured from the
                        // line at the top of the screen sits where the finger was.
                        var off: [String] = []
                        for f in [0.25, 0.75, 1.0, 0.5] {
                            NotificationCenter.default.post(name: .verbatimScrubPreview, object: f)
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            let at = TranscriptScrubber.lastLandingFraction ?? -1
                            let ok = f == 1 ? TranscriptScrubber.lastLandingIsLast : abs(at - f) <= 0.03
                            if !ok { off.append("\(f) landed at \(String(format: "%.3f", at))") }
                        }
                        Log.note("UITEST \(off.isEmpty ? "PASS" : "FAIL") scrubber: drags to 0.25, 0.5, 0.75, and 1.0 land within 3% of that time and on the last line\(off.isEmpty ? "" : " (\(off.joined(separator: ", ")))")")
                        NotificationCenter.default.post(name: .verbatimScrubPreview, object: nil)
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        let measured = TranscriptScrubModel.onScreen?.progress ?? -1
                        Log.note("UITEST \(abs(measured - 0.5) <= 0.03 ? "PASS" : "FAIL") scrubber: scrolled to the middle line, the handle sits at about 0.5 (\(String(format: "%.3f", measured)))")
                    }
                    NotificationCenter.default.post(name: .verbatimScrubPreview, object: nil)
                    app.libraryPath = NavigationPath()
                    try? await Task.sleep(nanoseconds: 500_000_000)
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
                // The seven groups run long: the middle (Dictation and keyboard) and the end (Features and the version).
                await settingsScrollShots(prefix: prefix, suffix: "")
                if prefix == "p" { await settingsSearchResolves(app, native: false) }
                SettingsSearchModel.shared.query = "keyboard"
                await show("\(prefix)09b-settings-search")
                SettingsSearchModel.shared.query = ""
                // Settings › Appearance: the look picker, light or dark, and Limit animation.
                SettingsPage.open("appearance")
                await show("\(prefix)09m-appearance")
                if prefix == "p" { lookCheck("Settings opens Appearance", AppearanceScreen.visible) }
                SettingsPage.open("root")
                try? await Task.sleep(nanoseconds: 800_000_000)
                // Settings › Your voice, step 2, with made-up progress (no microphone in the simulator).
                NotificationCenter.default.post(name: .verbatimShowVoiceProfile, object: true)
                await show("\(prefix)09c-voice-enroll")
                NotificationCenter.default.post(name: .verbatimShowVoiceProfile, object: false)
                try? await Task.sleep(nanoseconds: 700_000_000)
                // The You page from Home's This week card, then About me from the You page.
                app.tab = .home
                try? await Task.sleep(nanoseconds: 500_000_000)
                HomeScreen.openProfile(app)
                await show("\(prefix)09f-you")
                if prefix == "p" { youCheck("This week opens the You page", app.tab == .settings && YouScreen.visible) }
                NotificationCenter.default.post(name: .verbatimYouPage, object: true)
                await show("\(prefix)09g-you-about-me")
                if prefix == "p" { youCheck("the You page opens About me", AboutMeScreen.visible) }
                NotificationCenter.default.post(name: .verbatimYouPage, object: false)
                try? await Task.sleep(nanoseconds: 900_000_000)
                if prefix == "p" { youCheck("the You page closes", !YouScreen.visible && !AboutMeScreen.visible) }
                // The recording ribbon: the Session ended screen after a call (made-up last take), then Settings ›
                // Action button (last, because it stays pushed on the Settings tab).
                app.session.endedNotice = KeyboardSession.EndedNotice(reason: Ribbon.endedReason(call: true),
                                                                      lastTake: "Thursday works. Noon at the usual place?",
                                                                      lastTakeAt: Date().addingTimeInterval(-120))
                await show("\(prefix)09d-session-ended")
                app.session.endedNotice = nil
                try? await Task.sleep(nanoseconds: 500_000_000)
                // The start screen once a session is on (App Store builds can't switch back): the way-back coach for
                // the first five session starts, naming the app (Messages), then the one-line reminder. Made up: no
                // microphone in the simulator.
                app.session.previewStartScreen(coach: .full, host: "com.apple.MobileSMS")
                await show("\(prefix)09k-session-way-back")
                app.session.previewStartScreen(coach: .reminder, host: nil)
                await show("\(prefix)09l-session-way-back-reminder")
                app.session.previewStartScreen(coach: nil, host: nil)
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Settings › Keyboard's Dictate button group with its live preview: the default, then two made-up
                // choices (the keyboard extension itself isn't in the app, so the preview stands in for it). The
                // stored choice is put back after.
                app.tab = .settings
                let keepButton = DictateButton.read(KeyboardBridge.defaults)
                DictateButton.standard.write(KeyboardBridge.defaults)
                SettingsPage.open("keyboard")
                await show("\(prefix)09h-keyboard-dictate-button")
                DictateButton(size: .large, position: .left, style: .outline).write(KeyboardBridge.defaults)
                await show("\(prefix)09i-keyboard-dictate-large-left-outline")
                DictateButton(size: .large, position: .center, style: .filled).write(KeyboardBridge.defaults)
                await show("\(prefix)09j-keyboard-dictate-large-center")
                keepButton.write(KeyboardBridge.defaults)
                SettingsPage.open("root")
                try? await Task.sleep(nanoseconds: 800_000_000)
                // Settings › Action button: the five choices, which ones open Verbose, and the setup steps.
                SettingsPage.open("actionButton")
                await show("\(prefix)09e-action-button")
                SettingsPage.open("root")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            // Edit Home in the first look (Verbose style on a fresh simulator), from Home's button.
            await editHomeTour(app, look: AppLook.current, suffix: "")
            // The Native look (DESIGN.md §13): the key screens again, named p…-native and d…-native. The look is
            // stored per device in the App Group; the one this simulator had is put back after.
            // It switches as people do, from Settings › Appearance (LookSwitch.swift): the card in the new look, the
            // rebuild behind it, and its time.
            let keepLook = AppLook.current
            app.tab = .settings
            SettingsPage.open("appearance")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await lookSwitch(to: .native, on: "appearance", card: "d09o-look-switching-native")
            SettingsPage.open("root")
            try? await Task.sleep(nanoseconds: 800_000_000)
            for (prefix, mode) in [("p", "light"), ("d", "dark")] {
                app.appearance = mode
                app.tab = .home
                await show("\(prefix)01-home-native")
                if prefix == "p" {
                    homeLayoutCheck(.native)
                    lookCheck("Home in Native shows the floating record button", PremiumRecordButton.onScreen.contains(.home))
                }
                // Premium's recent recordings, as Voicenotes-style items (light only, to keep the tour short).
                if prefix == "p" {
                    NotificationCenter.default.post(name: .verbatimHomeScroll, object: "home-recent")
                    await show("p01b-home-recent-native")
                    NotificationCenter.default.post(name: .verbatimHomeScroll, object: "home-top")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                await whatsNewTour(app, prefix: prefix, suffix: "-native")
                // The record flow: the full-screen recorder with two marked moments (a stand-in recording; no
                // microphone in the simulator), then the Saved sheet for a seeded recording (nothing is changed).
                app.previewRecording = true
                app.recorder.live.setElapsed(134)
                app.recordingMoments = [RecordingMoment(at: 42), RecordingMoment(at: 118)]
                app.openRecorder()
                await show("\(prefix)02-record-native")
                if prefix == "p" { lookCheck("the record flow opens Premium's full-screen recorder", PremiumRecorder.visible) }
                app.minimizeRecorder()
                app.previewRecording = false
                app.recordingMoments = []
                app.recorder.live.reset()
                try? await Task.sleep(nanoseconds: 700_000_000)
                if let voice = app.store.live.first(where: { !$0.isDictation && $0.source == .voiceMemo }) ?? app.store.live.first(where: { !$0.isDictation }) {
                    app.savedRecording = SavedRecording(id: voice.id, length: 134, moments: 2, savedAt: Date())
                    await show("\(prefix)02s-saved-native")
                    if prefix == "p" { lookCheck("Stop opens the Saved sheet", PremiumSavedSheet.visible) }
                    app.savedRecording = nil
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                app.tab = .library
                await show("\(prefix)04-library-native")
                app.libraryPath.append(DictationsRoute())
                await show("\(prefix)04d-dictations-native")
                app.libraryPath = NavigationPath()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let rich = app.store.live.first(where: { $0.title == "Lapp Wagons catalog call" }) {
                    app.libraryPath.append(rich.id)
                    await show("\(prefix)05-transcript-native")
                    app.libraryPath = NavigationPath()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                // You, from Home's This week card: the week, the year, the stat cards, and the calendar.
                app.tab = .home
                try? await Task.sleep(nanoseconds: 500_000_000)
                HomeScreen.openProfile(app)
                await show("\(prefix)09f-you-native")
                if prefix == "p" { youCheck("You in Native shows the week, year, and calendar cards", YouScreen.visible && PremiumYouStats.visible) }
                NotificationCenter.default.post(name: .verbatimYouPage, object: false)
                try? await Task.sleep(nanoseconds: 900_000_000)
                app.tab = .moments
                await show("\(prefix)08-moments-native")
                app.tab = .settings
                await show("\(prefix)09-settings-native")
                await settingsScrollShots(prefix: prefix, suffix: "-native")
                if prefix == "p" { await settingsSearchResolves(app, native: true) }
                SettingsPage.open("appearance")
                await show("\(prefix)09m-appearance-native")
                SettingsPage.open("root")
                try? await Task.sleep(nanoseconds: 800_000_000)
                // The keyboard preview follows the look, as the keyboard does.
                let keepButton = DictateButton.read(KeyboardBridge.defaults)
                DictateButton.standard.write(KeyboardBridge.defaults)
                SettingsPage.open("keyboard")
                await show("\(prefix)09h-keyboard-dictate-button-native")
                DictateButton(size: .large, position: .center, style: .filled).write(KeyboardBridge.defaults)
                await show("\(prefix)09j-keyboard-dictate-large-center-native")
                keepButton.write(KeyboardBridge.defaults)
                SettingsPage.open("root")
                try? await Task.sleep(nanoseconds: 800_000_000)
                onboardingStep = PhoneOnboarding.lookStep
                app.showOnboarding = true
                await show("\(prefix)10b-onboarding-look-native")
                app.showOnboarding = false
                onboardingStep = 0
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            await editHomeTour(app, look: .native, suffix: "-native")
            // Back to the look the simulator had, from Home this time: the tab on screen rebuilds behind the card.
            app.tab = .home
            try? await Task.sleep(nanoseconds: 800_000_000)
            await lookSwitch(to: keepLook, on: "home", card: nil)
            try? await Task.sleep(nanoseconds: 600_000_000)
            app.appearance = "light"
            // The tour in Verbose style: the welcome, Pick a look, the microphone, and the last step.
            for (i, name) in [(0, "p10-onboarding"), (PhoneOnboarding.lookStep, "p10b-onboarding-look"), (2, "p11-onboarding"), (3, "p12-onboarding")] {
                onboardingStep = i
                app.showOnboarding = true
                await show(name)
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
        check("default idle timeout is 2 hours", Ribbon.normalizedTimeout(nil) == 7200)
        // The start screen's way-back coach: counted in UserDefaults, full five times, then the reminder.
        let keepCoach = UserDefaults.standard.object(forKey: Ribbon.coachCountKey)
        UserDefaults.standard.removeObject(forKey: Ribbon.coachCountKey)
        var coachRuns: [Ribbon.Coach] = []
        for _ in 0..<6 {
            let d = UserDefaults.standard
            coachRuns.append(Ribbon.coach(shown: d.integer(forKey: Ribbon.coachCountKey)))
            d.set(Ribbon.coachCount(after: d.integer(forKey: Ribbon.coachCountKey)), forKey: Ribbon.coachCountKey)
        }
        check("the way-back coach shows in full five times, then as a line", coachRuns == [.full, .full, .full, .full, .full, .reminder])
        UserDefaults.standard.set(keepCoach, forKey: Ribbon.coachCountKey)
        check("a call pauses and resumes the session", Ribbon.audio(.running, .interruptionBegan, dictating: false).1 == .pause(saveTake: false)
              && Ribbon.audio(.paused, .interruptionEnded(shouldResume: false), dictating: false).1 == .reactivate)
        check("the Action button dictates by default", Ribbon.actionChoice(nil) == .dictate)
        check("the Action button offers five choices", Ribbon.ActionChoice.allCases.count == 5)
        check("Quick capture can't be chosen on iPhone", !Ribbon.ActionChoice.quickCapture.available && Ribbon.actionChoice("quickCapture") == .dictate)
        check("only Dictate works in place", Ribbon.ActionChoice.allCases.filter { !$0.needsForeground } == [.dictate])

        // The keyboard session's Live Activity: the content state stays far under ActivityKit's 4 KB with the
        // longest words line, a message, and the target; the Lock Screen line never carries words.
        let longest = VerbatimSessionAttributes.ContentState(
            listening: true, endsAt: Date(), phase: .listening, sessionStartedAt: Date(), takeStartedAt: Date(), level: 1, words: 9999,
            takes: 999, message: Ribbon.copyFailedMessage, target: "Proton Mail",
            liveWords: Ribbon.islandWords(String(repeating: "\u{1F600}\u{1F600} wörds ", count: 200)))
        let bytes = (try? JSONEncoder().encode(longest).count) ?? Int.max
        check("the content state fits ActivityKit's 4 KB (\(bytes) bytes)", bytes < Ribbon.contentStateLimit / 2)
        check("an older content state without the new fields still decodes",
              (try? JSONDecoder().decode(VerbatimSessionAttributes.ContentState.self, from: Data(#"{"listening":false,"level":0,"words":0,"takes":1}"#.utf8)))?.liveWords == nil)
        check("the Lock Screen line names the app and the take, never words",
              Ribbon.lockLine(target: longest.target, take: 3) == "Into Proton Mail · take 3 of this session")
        check("App Store builds name the keyboard", Ribbon.target(hostName: "Messages", appStore: true) == Ribbon.keyboardTarget)
        check("Show words in the Dynamic Island is off unless turned on",
              KeyboardBridge.defaults?.object(forKey: Ribbon.islandWordsKey) != nil || !KeyboardSession.islandWordsOn)

        // Settings › Keyboard › Dictate button reaches the keyboard through the App Group.
        let keep = DictateButton.read(KeyboardBridge.defaults)
        let large = DictateButton(size: .large, position: .left, style: .outline)
        large.write(KeyboardBridge.defaults)
        check("the dictate button's choices reach the App Group", DictateButton.read(KeyboardBridge.defaults) == large)
        keep.write(KeyboardBridge.defaults)
        check("settings search finds the dictate button",
              SettingsSearchIndex.search("dictate button").flatMap(\.entries).contains { $0.id == "keyboardDictateButton" })
        check("settings search finds words in the Dynamic Island",
              SettingsSearchIndex.search("dynamic island").flatMap(\.entries).contains { $0.id == "keyboardIslandWords" })

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

    /// The look (Look.swift, DESIGN.md §13): new installs start in Verbose style, the keyboard reads the app's choice
    /// from the App Group, search finds the setting, and the Native accent's values meet 4.5:1 for small text.
    static func lookChecks() {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") look: \(name)")
        }
        let store = AppLook.store
        let keep = store.string(forKey: AppLook.key)
        store.removeObject(forKey: AppLook.key)
        check("a new install starts in Verbose style", AppLook.current == .verbose)
        check("the keyboard reads Verbose style with nothing stored", !KeyboardLook.isNative(KeyboardBridge.defaults))
        AppLook.current = .native
        check("the keyboard reads the app's Native choice from the App Group", KeyboardLook.isNative(KeyboardBridge.defaults))
        check("the keyboard's key is the app's", KeyboardLook.key == AppLook.key)
        AppLook.current = .verbose
        check("and Verbose style again", !KeyboardLook.isNative(KeyboardBridge.defaults))
        check("without Full Access (no App Group) the keyboard keeps Verbose style", !KeyboardLook.isNative(nil))
        if let keep { store.set(keep, forKey: AppLook.key) } else { store.removeObject(forKey: AppLook.key) }
        check("settings search finds the look", SettingsSearchIndex.search("native").flatMap(\.entries).contains { $0.id == "look" })
        check("Limit animation is a switch on the Settings root", SettingsSearchIndex.all.first { $0.id == "limitMotion" }?.target == .row)
        check("white on the light accent reaches 4.5:1", KeyboardLook.contrast(Ink.nativeAccentLightHex, 0xFFFFFF) >= 4.5)
        check("the dark accent reaches 4.5:1 on dark gray", KeyboardLook.contrast(Ink.nativeAccentDarkHex, 0x1C1C1E) >= 4.5)
        Log.note("UITEST look checks: \(pass) passed, \(fail) failed")
    }

    /// Settings scrolled to Dictation and keyboard, then to its foot (the version and What's new), then back to the top.
    /// Screens <prefix>09p-settings-dictation<suffix> and <prefix>09q-settings-end<suffix>.
    private static func settingsScrollShots(prefix: String, suffix: String) async {
        NotificationCenter.default.post(name: .verbatimSettingsScroll, object: "group-3")
        await show("\(prefix)09p-settings-dictation\(suffix)")
        NotificationCenter.default.post(name: .verbatimSettingsScroll, object: "settings-footer")
        await show("\(prefix)09q-settings-end\(suffix)")
        NotificationCenter.default.post(name: .verbatimSettingsScroll, object: "settings-top")
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    /// Every Settings search entry resolves to something on screen: a root row is laid out on the Settings root, and
    /// an entry on a page opens that page (SettingsPage, the same push a result makes). On the pages the regroup
    /// added, and on Appearance, the entry's row has to be laid out there too. One UITEST line per look.
    private static func settingsSearchResolves(_ app: PhoneState, native: Bool) async {
        let name = native ? "settings (native)" : "settings"
        SettingsSearchModel.shared.query = ""
        app.tab = .settings
        SettingsPage.open("root")
        try? await Task.sleep(nanoseconds: 900_000_000)
        var missing: [String] = []
        for e in SettingsSearchIndex.all where e.target == .row && !SettingsRowRegistry.isOnScreen(e.id) { missing.append(e.id) }
        // Rows that show only in one look or with a setting on.
        var conditional: Set<String> = native ? [] : ["homeRecordCard"]
        if !CloudCleanup.enabled { conditional.insert("cloudProvider") }
        let rowsChecked: Set<SettingsSubpage> = [.appearance, .speakers, .moreTranscription, .cloudCleanup, .tour, .widgets, .shortcuts]
        var pages: [SettingsSubpage] = []
        for e in SettingsSearchIndex.all { if case .page(let p) = e.target, !pages.contains(p) { pages.append(p) } }
        for p in pages {
            SettingsPage.open(p.rawValue)
            let opened = await waitFor(3) { SettingsRowRegistry.page == p }
            if !opened.ok { missing.append("page \(p.rawValue)") }
            if opened.ok, rowsChecked.contains(p) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                for e in SettingsSearchIndex.all where e.target == .page(p) && !conditional.contains(e.id) && !SettingsRowRegistry.isOnScreen(e.id) {
                    missing.append(e.id)
                }
            }
            SettingsPage.open("root")
            _ = await waitFor(3) { SettingsRowRegistry.page == nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let ok = missing.isEmpty
        Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name): every search entry resolves to a visible row (\(SettingsSearchIndex.all.count) entries, \(pages.count) pages)\(ok ? "" : "; missing " + missing.joined(separator: ", "))")
    }

    /// Home's note for the newest build in the notes (the simulator's own build has no entry), then What's new, which
    /// the note opens; back on Home with the note gone and the last build seen put back. Screens
    /// <prefix>01c-home-whats-new<suffix> and <prefix>09n-whats-new<suffix>.
    private static func whatsNewTour(_ app: PhoneState, prefix: String, suffix: String) async {
        let d = UserDefaults.standard
        let keepSeen = d.object(forKey: ReleaseNotes.lastSeenKey)
        guard let n = ReleaseNotes.bundled.first(where: { $0.number != nil })?.number else {
            Log.note("UITEST FAIL what's new: no numbered build in the bundled notes"); return
        }
        WhatsNewBanner.previewBuild = n
        d.set(n - 1, forKey: ReleaseNotes.lastSeenKey)
        app.tab = .home
        await show("\(prefix)01c-home-whats-new\(suffix)")
        HomeScreen.openWhatsNew(app)
        await show("\(prefix)09n-whats-new\(suffix)")
        if prefix == "p" {
            Log.note("UITEST \(app.tab == .settings && WhatsNewScreen.visible ? "PASS" : "FAIL") what's new: Home's note opens What's new\(suffix)")
        }
        // Back to Settings. The pop can take longer than its animation on a slow runner (build 206's runner: Settings
        // was created by this very step), so the check waits for it, up to 3 s, instead of a fixed 0.8 s.
        SettingsPage.open("root")
        let closed = await waitFor(3) { !WhatsNewScreen.visible }
        if prefix == "p" {
            // UIKit's stack is the truth when the screen's onDisappear is late: one view controller is Settings itself.
            let depth = visibleStackDepth()
            let ok = closed.ok || depth == 1
            Log.note("UITEST \(ok ? "PASS" : "FAIL") what's new: it closes\(suffix)")
            Log.note("UITEST TIMING whats-new-close \(closed.ms) stack=\(depth.map(String.init) ?? "?")")
        }
        if closed.ms < 800 { try? await Task.sleep(nanoseconds: UInt64(800 - closed.ms) * 1_000_000) }
        WhatsNewBanner.previewBuild = nil
        if let keepSeen { d.set(keepSeen, forKey: ReleaseNotes.lastSeenKey) } else { d.removeObject(forKey: ReleaseNotes.lastSeenKey) }
        app.tab = .home
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Switches the look as the picker does, checks the card shows in the new look and goes, and logs the time from the
    /// pick to the rebuild's first frame: `UITEST TIMING look-switch <ms> to=<look> screen=<screen>`. With a `card`
    /// name, the card is captured mid-switch into Documents/screens.
    private static func lookSwitch(to look: AppLook, on screen: String, card: String?) async {
        guard look != AppLook.current else { return }
        let before = LookSwitch.shared.cardsShown
        let switching = Task { await LookSwitch.shared.switchTo(look) }
        if let card {
            try? await Task.sleep(nanoseconds: 250_000_000)   // past the card's fade in
            if LookSwitch.shared.card != nil { snapshot(card) }
        }
        let ms = await switching.value
        // Counted when the card is set, so a busy main thread on the CI machine can't make the check miss it (sampling
        // `card == look` 60 ms in could land after the card had already gone).
        let shown = LookSwitch.shared.cardsShown > before
        try? await Task.sleep(nanoseconds: 300_000_000)   // the card's fade out
        lookCheck("switching to \(look.label) shows the card, then the look (card \(shown ? "shown" : "missing"))",
                  shown && AppLook.current == look && LookSwitch.shared.card == nil)
        Log.note("UITEST TIMING look-switch \(Int(ms.rounded())) to=\(look.rawValue) screen=\(screen) rebuild=\(Int(LookSwitch.shared.lastRebuildMs.rounded()))")
    }

    /// Waits up to `seconds` for `done`, checking every 50 ms: whether it came true, and after how long (ms).
    private static func waitFor(_ seconds: Double, _ done: () -> Bool) async -> (ok: Bool, ms: Int) {
        let start = Date()
        while !done() {
            if Date().timeIntervalSince(start) >= seconds { return (false, Int(seconds * 1000)) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return (true, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }

    /// How many view controllers the navigation stack on screen holds (UIKit's view of the selected tab), or nil.
    private static func visibleStackDepth() -> Int? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let root = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return nil }
        func find(_ vc: UIViewController) -> UINavigationController? {
            if let n = vc as? UINavigationController, n.viewIfLoaded?.window != nil { return n }
            for c in vc.children { if let n = find(c) { return n } }
            return nil
        }
        func tabBar(_ vc: UIViewController) -> UITabBarController? {
            if let t = vc as? UITabBarController { return t }
            for c in vc.children { if let t = tabBar(c) { return t } }
            return nil
        }
        let start = tabBar(root)?.selectedViewController ?? root
        return find(start)?.viewControllers.count
    }

    /// Home shows the layout for the look and only that one, by which Record card is on screen (build 204's Native
    /// Home kept Verbose style's Record panel, rings, and tiles under a half-made navigation bar).
    private static func homeLayoutCheck(_ look: AppLook) {
        let shown = HomeScreen.recordCardsOnScreen
        let name = look == .native ? "Home in Native shows the Premium layout (This week card), not Verbose style's Record panel"
                                   : "Home in Verbose style shows the Record panel, not Native's Record card"
        lookCheck("\(name) (on screen: \(shown.map(\.rawValue).sorted().joined(separator: ", ")))", shown == [look])
    }

    /// Edit Home (EditHome.swift, HomeLayout.swift) from Home's button: open it, hide a section (This week), reorder
    /// two, change a size (the tiles) and a tile (Search in the last slot), check Home draws exactly that, then reset.
    /// The layout store starts from the defaults in UI test mode and never writes the simulator's layout.
    private static func editHomeTour(_ app: PhoneState, look: AppLook, suffix: String) async {
        func check(_ name: String, _ ok: Bool) { Log.note("UITEST \(ok ? "PASS" : "FAIL") edit home\(suffix): \(name)") }
        let store = HomeLayoutStore.shared
        let hl = look.homeLook
        let other: HomeLook = hl == .native ? .verbose : .native
        let working = { HomeScreen.working(app.store) }
        app.appearance = "light"
        app.homePath = NavigationPath()
        app.tab = .home
        store.reset(hl)
        try? await Task.sleep(nanoseconds: 700_000_000)
        NotificationCenter.default.post(name: .verbatimHomeScroll, object: "home-top")
        NotificationCenter.default.post(name: .verbatimEditHome, object: true)
        await show("p13a-edit-home\(suffix)")
        check("Edit Home opens from Home", EditHomeView.visible)
        let before = store.layout(hl)
        store.update(hl) { $0.setVisible(.week, false) }
        let order = store.layout(hl).shown.map(\.section)
        store.update(hl) { $0.moveShown(fromOffsets: IndexSet(integer: 0), toOffset: 2) }
        let tileSize: HomeCardSize = before.size(.tiles) == .large ? .compact : .large
        store.update(hl) { $0.setSize(.tiles, tileSize) }
        await show("p13b-edit-home-edited\(suffix)")
        NotificationCenter.default.post(name: .verbatimHomeTilePicker, object: true)
        await show("p13c-edit-home-tiles\(suffix)")
        check("Choose tiles opens the tile picker", HomeTilePicker.visible)
        NotificationCenter.default.post(name: .verbatimHomeTilePicker, object: false)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let dropped = before.tiles[HomeLayout.tileCount - 1]
        store.update(hl) { l in l.tiles = HomeLayout.toggle(.search, in: HomeLayout.toggle(dropped, in: l.tiles)) }
        NotificationCenter.default.post(name: .verbatimEditHome, object: false)
        try? await Task.sleep(nanoseconds: 900_000_000)
        await show("p13d-home-edited\(suffix)")
        let after = store.layout(hl)
        let onScreen = HomeProbe.sections
        check("Edit Home closes with Done", !EditHomeView.visible)
        check("a hidden section leaves Home (This week)", !after.isVisible(.week) && onScreen[.week] == nil)
        check("two sections swap places", order.count >= 2 && after.shown.prefix(2).map(\.section) == [order[1], order[0]])
        check("Home draws only the shown sections (\(onScreen.keys.map(\.rawValue).sorted().joined(separator: ", ")))",
              Set(onScreen.keys) == Set(HomeSpacing.drawn(after, working: working()).map(\.section)))
        check("a size change reaches Home (tiles \(tileSize.rawValue))", onScreen[.tiles] == tileSize)
        check("a new tile reaches Home (Search for \(dropped.title))", HomeProbe.tiles.contains(.search) && !HomeProbe.tiles.contains(dropped))
        check("the other look keeps its own layout", store.layout(other) == HomeLayout.defaults(.phone, other))
        store.reset(hl)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        check("Reset puts Home back", store.layout(hl) == HomeLayout.defaults(.phone, hl)
              && Set(HomeProbe.sections.keys) == Set(HomeSpacing.drawn(store.layout(hl), working: working()).map(\.section)))
        // The same screen from Settings › Personalization › Customize Home (SettingsPages.swift).
        app.tab = .settings
        SettingsPage.open("customizeHome")
        await show("p13e-settings-customize-home\(suffix)")
        check("Settings › Customize Home opens Edit Home", EditHomeView.visible)
        SettingsPage.open("root")
        try? await Task.sleep(nanoseconds: 800_000_000)
        app.tab = .home
        try? await Task.sleep(nanoseconds: 600_000_000)
        if look.isNative {
            check("the floating record button stays while the Record section is hidden",
                  PremiumRecordButton.onScreen.contains(.home) && HomeProbe.sections[.record] == nil)
        }
    }

    private static func lookCheck(_ name: String, _ ok: Bool) {
        Log.note("UITEST \(ok ? "PASS" : "FAIL") look: \(name)")
    }

    /// The You page (YouScreen.swift), checked on screen during the tour.
    private static func youCheck(_ name: String, _ ok: Bool) {
        Log.note("UITEST \(ok ? "PASS" : "FAIL") you: \(name)")
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
        // The page itself opening is checked in the tour ("you: This week opens the You page").
        check("This week asks Settings for the You page", app.tab == .settings && SettingsPage.lastRequested == "you")
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

    /// Premium Native's record flow and Home (PremiumRecord.swift, PremiumHome.swift): Mark moment saves a moment at
    /// the elapsed time, moments become bookmarks (named or "Moment", offset when added to a transcript), the Record
    /// card is off by default, and the gradients meet contrast (the full set runs on Linux, test-premium-phone.sh).
    static func premiumChecks(_ app: PhoneState) {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") premium: \(name)")
        }
        app.previewRecording = true
        app.recorder.live.setElapsed(42)
        app.recordingMoments = []
        app.markMoment()
        check("Mark moment saves a moment at the elapsed time", app.recordingMoments.count == 1 && app.recordingMoments.first?.at == 42)
        app.previewRecording = false
        app.recorder.live.reset()
        app.markMoment()
        check("Mark moment does nothing without a recording", app.recordingMoments.count == 1)
        app.recordingMoments = []
        let notes = RecordingMoment.notes([RecordingMoment(at: 42), RecordingMoment(at: 118, name: "  The price  ")], offset: 600)
        check("moments become bookmarks, unnamed ones called Moment", notes.map(\.text) == ["Moment", "The price"] && notes.allSatisfy(\.isBookmark))
        check("moments added to a transcript start after it", notes.map { $0.at ?? -1 } == [642, 718])
        check("the Record card is off by default in Native", !HomeLayout.defaults(.phone, .native).isVisible(.record))
        check("settings search finds the Record card", SettingsSearchIndex.search("record card").flatMap(\.entries).contains { $0.id == "homeRecordCard" })
        let low = PremiumRules.minWhiteContrast(PremiumInk.persimmonLight, from: 1.0 / 3)
        check("white text keeps 4.5:1 on the lower two thirds of the persimmon card (\(String(format: "%.2f", low)):1)", low >= 4.5)
        check("black on the dark accent keeps 7:1", PremiumRules.contrast(Ink.nativeAccentDarkHex, PremiumInk.onAccentDarkHex) >= 7)
        check("recorder clock", PremiumRules.recorderClock(134) == "02:14")
        Log.note("UITEST premium checks: \(pass) passed, \(fail) failed")
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
        seedLong(store)
    }

    static let longTitle = "Barn raising, with Ginna Cross"

    /// A 46-minute interview, about 280 lines between two speakers, long enough for the transcript scrubber (more
    /// than three screens). Made-up words; nine days old, so it stays out of This week and the top of Recent.
    private static func seedLong(_ store: Store) {
        let ginna = [
            "We started before sunrise, because the frame has to be up before the wind comes over the ridge.",
            "My grandfather raised this barn in nineteen fifty one, and most of the pegs are still the ones he cut.",
            "You learn to listen to the wood. Oak tells you when it's going to split if you pay attention.",
            "The bents go up one at a time, and everybody on a pike pole has to push together on the count.",
            "Lunch is the part people remember. Forty pies on the wagon bed, and somehow none come home.",
            "The hardest joint is the scarf in the plate, where two timbers meet over the middle post.",
        ]
        let tim = [
            "How many people does it take to lift a bent?",
            "What changes when you do this with a crane instead of by hand?",
            "Did anything go wrong today?",
            "Who taught you to cut the joints?",
        ]
        var t = Transcript(title: longTitle, source: .voiceMemo, sourceLabel: "Voice memo", duration: 2772, audioFileName: nil, model: "Parakeet TDT v3")
        var lines: [Segment] = []
        var start = 0.0
        for i in 0..<280 {
            let asks = i % 5 == 0
            let text = asks ? tim[(i / 5) % tim.count] : ginna[i % ginna.count]
            let len = asks ? 4.0 : 11.0 + Double(i % 3)
            lines.append(Segment(start: start, end: start + len, text: text, speaker: asks ? "S2" : "S1"))
            start += len - 0.5 + (asks ? 0 : 1.6)
        }
        t.segments = lines
        t.original = lines
        t.duration = max(t.duration, start)
        t.speakers = [Speaker(id: "S1", name: "Ginna Cross"), Speaker(id: "S2", name: "Tim")]
        t.createdAt = Calendar.current.date(byAdding: .day, value: -9, to: Date()) ?? Date()
        t.kind = .interview; t.kindIsAuto = true; t.tags = ["film"]
        store.add(t)
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
