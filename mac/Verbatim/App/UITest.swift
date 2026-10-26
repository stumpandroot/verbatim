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
            // The library loads off the main thread at launch (Store.isLoaded); the self-test starts once it has.
            while !app.store.isLoaded { try? await Task.sleep(nanoseconds: 50_000_000) }
            // Launch timing for CI (never a pass or fail), with the big library (BigLibrarySeed) in it.
            LaunchClock.logTimings(app.store)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // The main window, never a floating panel (the dictation bar or today's page can come first in the list).
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { Log.note("UITEST FAIL no window"); return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Every click step runs in Verbose style (the look new installs start in); the tour adds Native screens.
            if AppLook.current != .verbose {
                AppLook.current = .verbose
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            // The Thoughts bubble stays off the screenshots except its own (thoughtsSteps and thoughtShots turn it on).
            Thoughts.showBubble = false
            // Screen changes with 1,000 transcripts while a file transcribes; then the big library goes again.
            await bigLibrarySteps(app: app)

            if app.store.transcripts.isEmpty {
                var t = Transcript(title: "Self-test memo", source: .voiceMemo, sourceLabel: "Voice memo", duration: 12, audioFileName: nil, model: "Test")
                t.segments = [Segment(start: 0, end: 4, text: "This is a seeded transcript.", speaker: "S1"), Segment(start: 4, end: 9, text: "It exists so the self-test can click a row.", speaker: "S2")]
                t.original = t.segments
                t.speakers = [Speaker(id: "S1", name: "Speaker 1"), Speaker(id: "S2", name: "Speaker 2")]
                app.store.add(t)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            await step("click row opens transcript", window, target: "row-0", check: { if case .transcript = app.screen { return true } else { return false } })
            oneScreen("opening a transcript", app: app)
            await step("sidebar Home goes home", window, target: "side-home", check: { app.screen == .home })
            oneScreen("sidebar Home", app: app)
            await step("sidebar Library opens library", window, target: "side-library", check: { app.screen == .library })
            oneScreen("sidebar Library", app: app)
            await step("sidebar Dictionary opens dictionary", window, target: "side-dict", check: { app.screen == .dictionary })
            oneScreen("sidebar Dictionary", app: app)
            await step("sidebar home again (one click)", window, target: "side-home", check: { app.screen == .home })
            oneScreen("sidebar Home again", app: app)
            try? await Task.sleep(nanoseconds: 900_000_000)   // let Home settle before clicking inside it
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
            // This week is one button: a click anywhere on it opens You.
            await step("This week opens You", window, target: "home-week", check: { app.screen == .activity })
            oneScreen("This week opens You", app: app)
            await step("sidebar Home goes home from You", window, target: "side-home", check: { app.screen == .home })
            oneScreen("sidebar Home from You", app: app)
            // A Recent dictations row copies its words wherever it's clicked.
            seedDictations(app)
            try? await Task.sleep(nanoseconds: 900_000_000)
            let newest = app.store.live.filter { $0.source == .dictation }.max { $0.createdAt < $1.createdAt }
            let expected = newest.map { HomeDictationText.pasted($0) } ?? ""
            NSPasteboard.general.clearContents()
            await step("clicking a recent dictation copies its text", window, target: "home-dictation-0",
                       check: { !expected.isEmpty && NSPasteboard.general.string(forType: .string) == expected })
            try? await Task.sleep(nanoseconds: 300_000_000)
            await step("row opens transcript again", window, target: "row-0", check: { if case .transcript = app.screen { return true } else { return false } })
            timingSummary("clicks")
            // Back: the Library comes back where you left it, ⌘[ and the View menu, and Back to Home (App/NavTrail.swift).
            await backSteps(app: app, window: window, native: false)

            await settingsSteps(main: window)
            await ribbonSteps(app: app)
            await surfaceSteps(app: app)
            window.makeKeyAndOrderFront(nil)
            await meetingSteps(main: window)
            // Thoughts: today's page, the bubble, the menu bar's group, By day, the rename, and the pad's move.
            await thoughtsSteps(app: app, window: window)
            window.makeKeyAndOrderFront(nil)
            logicChecks()
            // Dictation polish: timing, pause hints, paste decisions, and cleanup's time limit.
            await DictationPolishChecks.run { name, ok in
                if ok { pass += 1 } else { fail += 1 }
                Log.note("UITEST \(ok ? "PASS" : "FAIL") dictation: \(name)")
            }
            // No lost recordings: write failures, joins around a corrupt part, discard, and recovery.
            RecordingSafetyChecks.run(store: app.store) { name, ok in
                if ok { pass += 1 } else { fail += 1 }
                Log.note("UITEST \(ok ? "PASS" : "FAIL") recording safety: \(name)")
            }
            // Imports through the bundled FFmpeg (MKV) and files with several audio tracks, mixed and kept apart.
            await MediaImportSelfTest.run { name, ok in
                if ok { pass += 1 } else { fail += 1 }
                Log.note("UITEST \(ok ? "PASS" : "FAIL") import: \(name)")
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

    /// Opens each pane and checks that every SettingsIndex entry on it is laid out (SettingsAnchor counts it), so a
    /// search result always lands on a row. Rows that show only with another setting on are left out.
    private static func settingsEntriesResolve() async {
        let conditional: Set<String> = [
            "models.engine",                                                        // Quality is Advanced
            "dictate.cloudProvider", "dictate.cloudKey", "dictate.cloudModel",      // Cloud cleanup is on
            "dictate.noNotch", "dictate.notchWords", "dictate.notchClick",          // Show dictation in: Notch
            "ribbon.show", "ribbon.liveWords", "ribbon.style", "ribbon.mark",       // Show dictation in: Ribbon
            "watched.enabled", "watched.subfolders", "watched.location", "watched.formats", "watched.exportOptions",
            "watched.saveTo", "watched.fileName", "watched.notify",                 // a watched folder is chosen
        ]
        var missing: [String] = []
        for t in SettingsTab.allCases {
            UserDefaults.standard.set(t.rawValue, forKey: "settingsTab")
            try? await Task.sleep(nanoseconds: 900_000_000)
            for e in SettingsIndex.all where e.section == t && !conditional.contains(e.id) && !SettingsModel.shared.isLaidOut(e.id) {
                missing.append(e.id)
            }
        }
        let ok = missing.isEmpty
        if ok { pass += 1 } else { fail += 1 }
        Log.note("UITEST \(ok ? "PASS" : "FAIL") settings: every search entry resolves to a visible row (\(SettingsIndex.all.count) entries, \(SettingsTab.allCases.count) panes)\(ok ? "" : "; missing " + missing.joined(separator: ", "))")
    }

    /// Clicks in the Settings window: a sidebar pane, then a search result opening its pane; then every search entry
    /// resolves to a row laid out on its pane.
    private static func settingsSteps(main: NSWindow) async {
        UserDefaults.standard.set(SettingsTab.personalization.rawValue, forKey: "settingsTab")
        SettingsModel.shared.query = ""
        openSettingsWindow()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let w = SettingsModel.shared.window, w.isVisible else { fail += 1; Log.note("UITEST FAIL settings window did not open"); return }
        w.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await step("settings sidebar opens Watched folders", w, target: "settings-watched", check: { settingsTab == SettingsTab.watched.rawValue })
        await step("settings sidebar opens Account and plan", w, target: "settings-account", check: { settingsTab == SettingsTab.account.rawValue })
        await step("settings sidebar's version opens What's new", w, target: "settings-version", check: { settingsTab == SettingsTab.whatsNew.rawValue })
        SettingsModel.shared.query = "timecode"
        try? await Task.sleep(nanoseconds: 700_000_000)
        let first = SettingsIndex.search("timecode").first
        await step("settings search result opens its pane", w, target: "settings-result-0", check: {
            first != nil && settingsTab == first?.section.rawValue && !SettingsModel.shared.isSearching
        })
        SettingsModel.shared.query = ""
        await settingsEntriesResolve()
        UserDefaults.standard.set(SettingsTab.personalization.rawValue, forKey: "settingsTab")
        w.close()
        main.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: Ribbon

    /// What the Ribbon's prompt handlers saw, for the checks below.
    private static var ribbonAnswer = ""

    /// Clicks inside the Ribbon's panel: a prompt's main answer, its other answer, its X, and a notice's action.
    /// Each step first checks the routing the window server uses (with the pointer over the control, the panel
    /// must stop ignoring mouse events), then clicks the control through the panel's own event path.
    private static func lititz(_ seconds: Double = 20) -> FlowBarModel.Prompt {
        .init(title: "Remember “Lititz”?", body: "You changed ", quote: "lit it's → Lititz", after: ". Next time it's spelled your way.",
              primary: "Remember", secondary: "Not now", seconds: seconds,
              onPrimary: { ribbonAnswer = "primary" }, onSecondary: { ribbonAnswer = "secondary" }, onTimeout: { ribbonAnswer = "timeout" })
    }

    private static func ribbonSteps(app: AppState) async {
        guard let bar = app.dictation.bar else { fail += 1; Log.note("UITEST FAIL ribbon: no Ribbon controller"); return }
        let settle: UInt64 = 1_200_000_000   // the card slides in and its frames are recorded

        ribbonAnswer = ""; bar.ask(lititz())
        try? await Task.sleep(nanoseconds: settle)
        await ribbonStep("ribbon prompt Remember runs its answer", bar, target: "ribbon-prompt-primary",
                         check: { ribbonAnswer == "primary" && bar.model.phase == .idle })

        try? await Task.sleep(nanoseconds: 500_000_000)
        ribbonAnswer = ""; bar.ask(lititz())
        try? await Task.sleep(nanoseconds: settle)
        await ribbonStep("ribbon prompt Not now runs its answer", bar, target: "ribbon-prompt-secondary",
                         check: { ribbonAnswer == "secondary" && bar.model.phase == .idle })

        try? await Task.sleep(nanoseconds: 500_000_000)
        ribbonAnswer = ""; bar.ask(lititz())
        try? await Task.sleep(nanoseconds: settle)
        await ribbonStep("ribbon prompt X dismisses it", bar, target: "ribbon-prompt-close",
                         check: { ribbonAnswer == "timeout" && bar.model.phase == .idle && bar.model.prompt == nil })

        // The countdown holds while the pointer is over the card and restarts when it leaves.
        try? await Task.sleep(nanoseconds: 500_000_000)
        ribbonAnswer = ""; bar.ask(lititz(3))
        try? await Task.sleep(nanoseconds: settle)
        if let panel = bar.panelWindow, let f = frames["ribbon-prompt-primary"], let content = panel.contentView {
            let over = panel.convertPoint(toScreen: CGPoint(x: f.midX, y: content.bounds.height - f.midY))
            bar.updatePointer(at: over)
            let held = !bar.model.promptCountdown.running
            try? await Task.sleep(nanoseconds: 2_500_000_000)    // past the 3 s it had (1.2 s already gone)
            bar.updatePointer(at: over)                          // the poll may have read the real pointer meanwhile
            let stillUp = bar.model.phase == .prompt && ribbonAnswer.isEmpty
            bar.updatePointer(at: CGPoint(x: panel.frame.midX, y: panel.frame.maxY + 400))
            let resumed = bar.model.promptCountdown.running && bar.model.promptCountdown.seconds >= FlowBarController.resumeSeconds
            let ok = held && stillUp && resumed
            if ok { pass += 1 } else { fail += 1 }
            Log.note("UITEST \(ok ? "PASS" : "FAIL") ribbon prompt holds under the pointer (held=\(held) stillUp=\(stillUp) resumed=\(resumed))")
        } else { fail += 1; Log.note("UITEST FAIL ribbon prompt holds under the pointer: no panel or target") }
        bar.setPhase(.idle)

        try? await Task.sleep(nanoseconds: 500_000_000)
        var ran = false
        bar.flash("Learned “Lititz”", action: "Undo") { ran = true }
        try? await Task.sleep(nanoseconds: settle)
        await ribbonStep("ribbon notice action runs", bar, target: "ribbon-notice-action", check: { ran && bar.model.phase == .idle })
        bar.setPhase(.idle)
    }

    /// The notch style (shown as the pill on the runner, whose display has no notch) and the floating button: the
    /// same prompt and notice clicks as the Ribbon, through their own panels, and a click on the floating button.
    private static func surfaceSteps(app: AppState) async {
        guard let bar = app.dictation.bar else { fail += 1; Log.note("UITEST FAIL surfaces: no controller"); return }
        let d = UserDefaults.standard
        let saved = d.string(forKey: DictationSurface.key)
        let settle: UInt64 = 1_200_000_000

        for (surface, prefix) in [(DictationSurface.notch, "notch"), (DictationSurface.button, "button")] {
            d.set(surface.rawValue, forKey: DictationSurface.key)
            bar.refresh()
            try? await Task.sleep(nanoseconds: 600_000_000)
            Log.note("UITEST \(surface.rawValue) style shows as \(bar.shown)")

            ribbonAnswer = ""; bar.ask(lititz())
            try? await Task.sleep(nanoseconds: settle)
            await ribbonStep("\(prefix) prompt Remember runs its answer", bar, target: "\(prefix)-prompt-primary",
                             check: { ribbonAnswer == "primary" && bar.model.phase == .idle })
            try? await Task.sleep(nanoseconds: 500_000_000)
            ribbonAnswer = ""; bar.ask(lititz())
            try? await Task.sleep(nanoseconds: settle)
            await ribbonStep("\(prefix) prompt Not now runs its answer", bar, target: "\(prefix)-prompt-secondary",
                             check: { ribbonAnswer == "secondary" && bar.model.phase == .idle })
            try? await Task.sleep(nanoseconds: 500_000_000)
            ribbonAnswer = ""; bar.ask(lititz())
            try? await Task.sleep(nanoseconds: settle)
            await ribbonStep("\(prefix) prompt X dismisses it", bar, target: "\(prefix)-prompt-close",
                             check: { ribbonAnswer == "timeout" && bar.model.phase == .idle && bar.model.prompt == nil })
            try? await Task.sleep(nanoseconds: 500_000_000)
            var ran = false
            bar.flash("Learned “Lititz”", action: "Undo") { ran = true }
            try? await Task.sleep(nanoseconds: settle)
            await ribbonStep("\(prefix) notice action runs", bar, target: "\(prefix)-notice-action", check: { ran && bar.model.phase == .idle })
            bar.setPhase(.idle)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // A click on the floating button reaches dictation: it starts, or asks for Accessibility (or the mic).
        await ribbonStep("floating button click reaches dictation", bar, target: "floating-button", check: { bar.model.phase != .idle })
        if app.dictation.isListening { app.dictation.cancel(quiet: true) }
        bar.setPhase(.idle)

        if let saved { d.set(saved, forKey: DictationSurface.key) } else { d.removeObject(forKey: DictationSurface.key) }
        bar.refresh()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// The notch style's and the floating button's states for CI's screenshots (the notch shows as the pill on a
    /// display without one), then the Ribbon again.
    private static func surfaceShots(app: AppState) async {
        guard let bar = app.dictation.bar else { return }
        let d = UserDefaults.standard
        let saved = d.string(forKey: DictationSurface.key)
        bar.model.targetName = "Notes"
        bar.model.targetBundleID = "com.apple.Notes"
        for (surface, prefix) in [(DictationSurface.notch, "08f-notch"), (DictationSurface.button, "08g-floating")] {
            d.set(surface.rawValue, forKey: DictationSurface.key)
            bar.refresh()
            bar.holdHover = true
            await show("\(prefix)-idle-hover")
            bar.holdHover = false
            bar.model.handsFree = true
            bar.setPhase(.listening)
            await show("\(prefix)-listening")
            if surface == .notch { notchOverMenuBar(bar) }
            bar.holdHover = true
            await show("\(prefix)-listening-hover")
            bar.holdHover = nil
            bar.setPhase(.working)
            await show("\(prefix)-cleaning-up")
            // Held under a pretend pointer, so the 1.6 s confirmation stays for the capture.
            bar.holdHover = true
            bar.confirmPaste(app: "Notes", words: 38)
            await show("\(prefix)-pasted")
            bar.holdHover = nil
            bar.flash("Couldn't paste into Notes. Your words are saved. Press ⌃⌘V to paste.", action: "Copy", tone: .error)
            await show("\(prefix)-error")
            bar.ask(lititz(30))
            await show("\(prefix)-prompt")
            bar.setPhase(.idle)
        }
        if let saved { d.set(saved, forKey: DictationSurface.key) } else { d.removeObject(forKey: DictationSurface.key) }
        bar.refresh()
    }

    /// The notch (or the pill) hangs from the very top of the display, over the menu bar: its panel's top edge is the
    /// screen's top edge, and no menu bar or status item window draws over its first row. Build 200 had the pill at
    /// `.statusBar`, under the macOS 26 menu bar, so only its bottom 8 pt showed.
    private static func notchOverMenuBar(_ bar: FlowBarController) {
        guard let panel = bar.panelWindow, panel.isVisible else {
            fail += 1; Log.note("UITEST FAIL notch panel on screen"); return
        }
        let f = panel.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.minX <= f.midX && f.midX <= $0.frame.maxX }) else {
            fail += 1; Log.note("UITEST FAIL notch panel has no display (frame=\(f))"); return
        }
        let flush = abs(f.maxY - screen.frame.maxY) < 0.5
        if flush { pass += 1 } else { fail += 1 }
        Log.note("UITEST \(flush ? "PASS" : "FAIL") notch panel top is the screen's top (panel=\(f) screen=\(screen.frame) visible=\(screen.visibleFrame))")

        // Windows the window server draws over the panel, in global display coordinates (top-left origin).
        let top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY)
        let row = CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: max(1, screen.frame.maxY - screen.visibleFrame.maxY))
        let above = (CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], CGWindowID(panel.windowNumber)) as? [[String: Any]]) ?? []
        var covering: [String] = []
        for w in above {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard let b = w[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.intersects(row) else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let name = w[kCGWindowName as String] as? String ?? ""
            Log.note("UITEST notch: above it, \(owner) \"\(name)\" layer=\(layer) bounds=\(r)")
            // Menus (popUpMenu and up) and the cursor may draw over it; the menu bar and its items may not.
            if layer < NSWindow.Level.popUpMenu.rawValue { covering.append("\(owner) layer \(layer)") }
        }
        let clear = covering.isEmpty
        if clear { pass += 1 } else { fail += 1 }
        Log.note("UITEST \(clear ? "PASS" : "FAIL") notch draws over the menu bar (level=\(panel.level.rawValue) mainMenu=\(CGWindowLevelForKey(.mainMenuWindow)) statusBar=\(CGWindowLevelForKey(.statusWindow)) covering=\(covering))")
    }

    private static func ribbonStep(_ name: String, _ bar: FlowBarController, target: String, check: () -> Bool) async {
        guard let panel = bar.panelWindow, panel.isVisible, let content = panel.contentView else {
            fail += 1; Log.note("UITEST FAIL \(name): the Ribbon isn't on screen"); return
        }
        guard let f = frames[target] else { fail += 1; Log.note("UITEST FAIL \(name): missing target \(target)"); return }
        // The window server sends a click to the panel only while it isn't ignoring mouse events, which the
        // controller decides from the pointer's position against the drawn content's frame.
        let screen = panel.convertPoint(toScreen: CGPoint(x: f.midX, y: content.bounds.height - f.midY))
        bar.updatePointer(at: screen)
        let routed = !panel.ignoresMouseEvents
        if !routed { fail += 1 }
        Log.note("UITEST \(routed ? "routed" : "FAIL") \(name): pointer \(Int(screen.x)),\(Int(screen.y)) hit rect \(bar.hitRect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil")")
        click(target, in: panel)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let ok = routed && check()
        if ok { pass += 1 } else if routed { fail += 1 }
        Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name) (phase=\(bar.model.phase) answer=\(ribbonAnswer))")
    }

    /// Meeting capture's floating surfaces, clicked through their own panels: a pretend call prompt (nothing is
    /// watched in the self-test) and the consent sheet. Nothing records: the last click is Cancel.
    private static func meetingSteps(main: NSWindow) async {
        let coordinator = MeetingCoordinator.shared
        coordinator.showTestPrompt(name: "Zoom")
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let banner = coordinator.banner.window, banner.isVisible else { fail += 1; Log.note("UITEST FAIL meeting prompt did not show"); return }
        await step("meeting prompt Not now hides it", banner, target: "meeting-prompt-notnow", check: { coordinator.banner.kind == nil || !coordinator.banner.isShowing })
        coordinator.showTestPrompt(name: "Zoom")
        try? await Task.sleep(nanoseconds: 700_000_000)
        await step("meeting prompt Record opens the consent sheet", banner, target: "meeting-prompt-record", check: { coordinator.consent.isShowing })
        if let sheet = coordinator.consent.window, sheet.isVisible {
            await step("meeting consent Cancel closes it without recording", sheet, target: "meeting-consent-cancel",
                       check: { !coordinator.consent.isShowing && !MeetingSession.shared.isActive })
        } else {
            fail += 1; Log.note("UITEST FAIL meeting consent sheet has no window")
        }
        coordinator.banner.hide()
        main.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
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
        timings = []   // the tour's summaries leave out the Settings, Ribbon, and meeting steps' navigations
        ScreenPlaces.shared.reset()   // every screen opens where it always did in the screenshots
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
        // The This week strip under the tiles.
        await reveal("home-week", in: window)
        await show("02c-home-week")
        await editHomeSteps(app: app, window: window, look: .verbose, suffix: "")
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
        await show("05i-library-thoughts")
        app.libraryKind = nil
        // Library › By day: Thoughts and Journal, with the calendar's dots and the day's page.
        seedThoughts(app, withTranscribing: true)
        app.go(.byDay(.idea))
        await show("05n-by-day-thoughts")
        app.go(.byDay(.journal))
        await show("05o-by-day-journal")
        app.go(.library)
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
        await thoughtShots(suffix: "")
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
        await surfaceShots(app: app)
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        await show("09-settings")
        UserDefaults.standard.set(SettingsTab.recording.rawValue, forKey: "settingsTab")
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
        UserDefaults.standard.set(SettingsTab.floatingButton.rawValue, forKey: "settingsTab")
        await show("09h-settings-floating-button")
        UserDefaults.standard.set(SettingsTab.actions.rawValue, forKey: "settingsTab")
        await show("09b-settings-actions")
        seedWatchedFolders()
        UserDefaults.standard.set(SettingsTab.watched.rawValue, forKey: "settingsTab")
        await show("09e-settings-watched")
        SettingsModel.shared.query = "timecode"
        await show("09f-settings-search")
        SettingsModel.shared.query = ""
        // Export sits under the watched folders on their pane.
        UserDefaults.standard.set(SettingsTab.watched.rawValue, forKey: "settingsTab")
        SettingsModel.shared.focusID = "export.source"
        await show("09g-settings-export")
        UserDefaults.standard.set(SettingsTab.meetings.rawValue, forKey: "settingsTab")
        await show("09j-settings-meetings-captions")
        UserDefaults.standard.set(SettingsTab.support.rawValue, forKey: "settingsTab")
        await show("09k-settings-support")
        UserDefaults.standard.set(SettingsTab.features.rawValue, forKey: "settingsTab")
        await show("09l-settings-features")
        UserDefaults.standard.set(SettingsTab.whatsNew.rawValue, forKey: "settingsTab")
        await show("09i-settings-whats-new")
        UserDefaults.standard.set(SettingsTab.personalization.rawValue, forKey: "settingsTab")
        NSApp.windows.filter { $0 != window && $0.isVisible }.forEach { $0.close() }
        app.go(.home)
        await show("10-home-again")
        await whatsNewLine(app: app, window: window, name: "10f-home-whats-new")
        for (i, name) in ["10a-onboarding-welcome", "10a2-onboarding-look", "10b-onboarding-permissions", "10c-onboarding-try", "10d-onboarding-placement", "10e-onboarding-quality"].enumerated() {
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
        UserDefaults.standard.set(SettingsTab.personalization.rawValue, forKey: "settingsTab")
        NSApp.windows.filter { $0 != window && $0.isVisible }.forEach { $0.close() }
        app.go(.home)
        NSApplication.shared.appearance = nil
        timingSummary("tour-verbose")
        await nativeTour(app: app, window: window, memo: memo?.id)
        timingSummary("tour-native")
        write(show: "done")
    }

    /// The Native look (Settings › General › Look) on the key screens, light then dark, with `-native` names: Home,
    /// the Library, a transcript, Settings › General with the look picker, and the welcome tour's Pick a look step.
    /// Ends back in Verbose style.
    private static func nativeTour(app: AppState, window: NSWindow, memo: UUID?) async {
        // The switch as a pick makes it (LookSwitch.swift): the card, the rebuild behind it, and its time.
        await lookSwitch(to: .native, on: "home")
        try? await Task.sleep(nanoseconds: 400_000_000)
        nativeChecks()
        await nativeClicks(app: app, window: window)
        await backSteps(app: app, window: window, native: true)
        app.go(.home); app.captureMode = "voice"
        await show("01-home-native")
        await editHomeSteps(app: app, window: window, look: .native, suffix: "-native")
        app.projectFilter = nil; app.libraryKind = nil; app.libraryFilter = .all
        app.go(.library)
        await show("05-library-native")
        NativeNav.shared.libraryTable = true
        await show("05b-library-table-native")
        NativeNav.shared.libraryTable = false
        if let m = memo { app.go(.transcript(m)) }
        await show("06-transcript-native")
        app.go(.byDay(.idea))
        await show("05n-by-day-thoughts-native")
        app.go(.byDay(.journal))
        await show("05o-by-day-journal-native")
        await thoughtShots(suffix: "-native")
        UserDefaults.standard.set(SettingsTab.personalization.rawValue, forKey: "settingsTab")
        openSettingsWindow()
        await show("09-settings-general-native")
        check("native look: Settings, closed during the switch, opens in Native", SettingsView.lastBuilt == .native)
        UserDefaults.standard.set(SettingsTab.recording.rawValue, forKey: "settingsTab")
        await show("09c-settings-transcription-native")
        UserDefaults.standard.set(SettingsTab.dictate.rawValue, forKey: "settingsTab")
        await show("09d-settings-dictate-native")
        UserDefaults.standard.set(SettingsTab.whatsNew.rawValue, forKey: "settingsTab")
        await show("09i-settings-whats-new-native")
        UserDefaults.standard.set(SettingsTab.personalization.rawValue, forKey: "settingsTab")
        NSApp.windows.filter { $0 != window && $0.isVisible }.forEach { $0.close() }
        window.makeKeyAndOrderFront(nil)
        app.go(.home)
        await whatsNewLine(app: app, window: window, name: "10f-home-whats-new-native")
        onboardingStep = OnboardingStep.look.rawValue
        app.showOnboarding = true
        await show("10a2-onboarding-look-native")
        app.showOnboarding = false
        onboardingStep = 0
        try? await Task.sleep(nanoseconds: 700_000_000)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        await show("11-dark-home-native")
        app.go(.library)
        await show("15-dark-library-native")
        if let m = memo { app.go(.transcript(m)) }
        await show("12-dark-transcript-native")
        NSApplication.shared.appearance = nil
        try? await Task.sleep(nanoseconds: 400_000_000)
        // Back to Verbose style on the open transcript: the switch rebuilds the screen, and its audio stays open (it
        // used to stop when the old screen left after the new one appeared), with the same sponsor reads skipped.
        let opened = app.player.canPlay
        let loaded = app.player.loadedURL
        await lookSwitch(to: .verbose, on: memo == nil ? "home" : "transcript")
        try? await Task.sleep(nanoseconds: 400_000_000)
        if memo != nil {
            if opened {
                check("look switch on an open transcript keeps its audio", app.player.canPlay && app.player.loadedURL == loaded)
            } else {
                Log.note("UITEST note: the transcript's audio hadn't opened before the look switch; its check is skipped")
            }
        }
        app.go(.home)
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    /// Edit Home (EditHome.swift, HomeLayout.swift), clicked: Edit Home at the end of Home opens the inspector; then
    /// hide a section (This week), reorder two, change a size (the tiles) and a tile (Search in the last slot), check
    /// Home draws exactly that, click Done, and reset. The layout store starts from the defaults in the self-test and
    /// never writes the Mac's layout.
    private static func editHomeSteps(app: AppState, window: NSWindow, look: AppLook, suffix: String) async {
        let store = HomeLayoutStore.shared
        let session = HomeEditSession.shared
        let hl = look.homeLook
        let other: HomeLook = hl == .native ? .verbose : .native
        store.reset(hl)
        session.editing = false
        app.go(.home); app.captureMode = "voice"
        try? await Task.sleep(nanoseconds: 900_000_000)
        await step("edit home\(suffix): Edit Home at the end of Home opens the inspector", window, target: "home-edit",
                   check: { session.editing && EditHomeView.visible })
        await show("02e-edit-home\(suffix)")
        let before = store.layout(hl)
        store.update(hl) { $0.setVisible(.week, false) }
        let order = store.layout(hl).shown.map(\.section)
        store.update(hl) { $0.moveShown(fromOffsets: IndexSet(integer: 0), toOffset: 2) }
        let tileSize: HomeCardSize = before.size(.tiles) == .large ? .compact : .large
        store.update(hl) { $0.setSize(.tiles, tileSize) }
        session.pickingTiles = true
        await show("02f-edit-home-tiles\(suffix)")
        check("edit home\(suffix): Choose… opens the tile picker", HomeTilePickerMac.visible)
        session.pickingTiles = false
        try? await Task.sleep(nanoseconds: 500_000_000)
        let dropped = before.tiles[HomeLayout.tileCount - 1]
        store.update(hl) { l in l.tiles = HomeLayout.toggle(.search, in: HomeLayout.toggle(dropped, in: l.tiles)) }
        try? await Task.sleep(nanoseconds: 700_000_000)
        await show("02g-edit-home-edited\(suffix)")
        await step("edit home\(suffix): Done closes the inspector", window, target: "home-edit-done", check: { !session.editing })
        let after = store.layout(hl)
        let onScreen = HomeProbe.sections
        let drawn = after.shown.filter { $0.section != .queue || app.store.transcripts.contains { $0.deletedAt == nil && $0.status == .processing } }
        check("edit home\(suffix): a hidden section leaves Home (This week)", !after.isVisible(.week) && onScreen[.week] == nil)
        check("edit home\(suffix): two sections swap places", order.count >= 2 && after.shown.prefix(2).map(\.section) == [order[1], order[0]])
        check("edit home\(suffix): Home draws only the shown sections (\(onScreen.keys.map(\.rawValue).sorted().joined(separator: ", ")))",
              Set(onScreen.keys) == Set(drawn.map(\.section)))
        check("edit home\(suffix): a size change reaches Home (tiles \(tileSize.rawValue))", onScreen[.tiles] == tileSize)
        check("edit home\(suffix): a new tile reaches Home (Search for \(dropped.title))", HomeProbe.tiles.contains(.search) && !HomeProbe.tiles.contains(dropped))
        check("edit home\(suffix): the other look keeps its own layout", store.layout(other) == HomeLayout.defaults(.mac, other))
        store.reset(hl)
        try? await Task.sleep(nanoseconds: 900_000_000)
        check("edit home\(suffix): Reset puts Home back", store.layout(hl) == HomeLayout.defaults(.mac, hl)
              && Set(HomeProbe.sections.keys) == Set(store.layout(hl).shown.map(\.section)))
        if look == .native {
            check("edit home\(suffix): Record starts hidden in Native, where the floating record button stands in", !store.layout(hl).isVisible(.record) && HomeProbe.sections[.record] == nil)
        }
    }

    /// Checks that only hold while Native is on: tokens turn into Native's colors, resolved for the appearance asked
    /// for (not whichever is drawing) and cached, and the serif role turns into SF Pro.
    private static func check(_ name: String, _ ok: Bool) {
        if ok { pass += 1 } else { fail += 1 }
        Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name)")
    }

    private static func nativeChecks() {
        check("native look: tokens turn into system colors while it's on", NativeSwap.on && NativeSwap.color(light: Ink.paperHex) != nil)
        check("native look: the serif role is SF Pro", Ink.serif(30) == NativeSwap.serif(30, weight: .regular) && Ink.serif(30) != SurfaceFont.serif(30))
        let light = NativeSwap.color(light: Ink.paperHex, dark: false, increased: false)
        let dark = NativeSwap.color(light: Ink.paperHex, dark: true, increased: false)
        check("native look: the window is the warm off-white in light and near black in dark",
              light.map { abs($0.redComponent - 0xF6 / 255.0) < 0.01 && abs($0.blueComponent - 0xF1 / 255.0) < 0.01 } == true
              && dark.map { $0.redComponent < 0.1 } == true)
        let before = NativeSwap.cachedColorCount
        _ = NativeSwap.color(light: Ink.inkHex, dark: true, increased: false)
        let afterFirst = NativeSwap.cachedColorCount
        _ = NativeSwap.color(light: Ink.inkHex, dark: true, increased: false)
        check("native look: a token resolves once per appearance, then comes from the cache", afterFirst <= before + 1 && NativeSwap.cachedColorCount == afterFirst)
        check("native look: brand fills keep their color", NativeSwap.color(light: Ink.persimmonHex, dark: false, increased: false) == nil)
    }

    /// The Native window's own controls, clicked: the sidebar (a List selection), a Library item (click selects,
    /// double-click opens), and the toolbar's Back.
    private static func nativeClicks(app: AppState, window: NSWindow) async {
        let nav = NativeNav.shared
        nav.libraryTable = false
        app.projectFilter = nil; app.libraryKind = nil; app.libraryFilter = .all
        app.go(.queue)
        try? await Task.sleep(nanoseconds: 700_000_000)
        await step("native: sidebar Home goes home", window, target: "side-home", check: { app.screen == .home })
        await step("native: sidebar Library opens the Library", window, target: "side-library", check: { app.screen == .library })
        let first = Store.group(NativeLibraryScope.list(app), sort: LibrarySort(rawValue: UserDefaults.standard.string(forKey: LibrarySort.key) ?? "") ?? .newest).first?.items.first?.id
        if windowFrames["lib-item-1"]?() != nil {
            await step("native: clicking a Library item selects it", window, target: "lib-item-1",
                       check: { app.screen == .library && nav.librarySelection != nil && nav.librarySelection != first })
        }
        await step("native: double-clicking a Library item opens its transcript", window, target: "lib-item-0", clicks: 2,
                   check: { app.screen.transcriptID != nil && app.screen.transcriptID == first })
        await step("native: the toolbar's Back returns to the Library", window, target: "tb-back", check: { app.screen == .library })
        await step("native: Open Transcript in the preview opens it", window, target: "lib-open", check: { app.screen.transcriptID != nil })
        app.go(.home)
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Switches the look as the picker does, checks the card shows in the new look and goes, and logs the time from the
    /// pick to the rebuilt window's first frame: `UITEST TIMING look-switch <ms> to=<look> screen=<screen>`.
    private static func lookSwitch(to look: AppLook, on screen: String) async {
        let before = LookSwitch.shared.cardsShown
        let ms = await LookSwitch.shared.switchTo(look)
        // Counted when the card is set, so a busy main thread on the CI machine can't make the check miss it.
        let shown = LookSwitch.shared.cardsShown > before
        try? await Task.sleep(nanoseconds: 300_000_000)   // the card's fade out
        let ok = shown && AppLook.current == look && LookSwitch.shared.card == nil
        if ok { pass += 1 } else { fail += 1 }
        Log.note("UITEST \(ok ? "PASS" : "FAIL") look switch to \(look.rawValue) shows the card, then the look (card \(shown ? "shown" : "missing"))")
        Log.note("UITEST TIMING look-switch \(Int(ms.rounded())) to=\(look.rawValue) screen=\(screen) rebuild=\(Int(LookSwitch.shared.lastRebuildMs.rounded()))")
        Log.note("UITEST look-switch marks to=\(look.rawValue) \(LookSwitch.shared.lastMarks)")
    }

    /// Home's note for the newest build in the notes, then Verbose › What's New… (the same action as clicking the
    /// note), which opens Settings › What's new. Puts the last build seen back and closes Settings.
    private static func whatsNewLine(app: AppState, window: NSWindow, name: String) async {
        let d = UserDefaults.standard
        let keepSeen = d.object(forKey: ReleaseNotes.lastSeenKey)
        guard let n = ReleaseNotes.bundled.first(where: { $0.number != nil })?.number else {
            Log.note("UITEST FAIL what's new: no numbered build in the bundled notes"); return
        }
        WhatsNewHomeLine.previewBuild = n
        d.set(n - 1, forKey: ReleaseNotes.lastSeenKey)
        await show(name)
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title == "What's New…" }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            Log.note("UITEST \(settingsTab == SettingsTab.whatsNew.rawValue ? "PASS" : "FAIL") what's new: Verbose › What's New… opens Settings › What's new (\(name))")
        } else {
            Log.note("UITEST FAIL what's new: no What's New… item in the app menu")
        }
        WhatsNewHomeLine.previewBuild = nil
        if let keepSeen { d.set(keepSeen, forKey: ReleaseNotes.lastSeenKey) } else { d.removeObject(forKey: ReleaseNotes.lastSeenKey) }
        UserDefaults.standard.set(SettingsTab.personalization.rawValue, forKey: "settingsTab")
        NSApp.windows.filter { $0 != window && $0.isVisible }.forEach { $0.close() }
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 600_000_000)
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
        check("settings search needs every word", SettingsIndex.search("sync iphone").map(\.id) == ["storage.icloud"] && SettingsIndex.search("sync icloud").map(\.id).contains("storage.icloud") && SettingsIndex.search("   ").isEmpty)
        check("every settings pane is searchable", SettingsTab.allCases.allSatisfy { t in SettingsIndex.all.contains { $0.section == t } })
        check("settings ids are unique", Set(SettingsIndex.all.map(\.id)).count == SettingsIndex.all.count)
        // The Native look (LookRules.swift, NativeLook.swift).
        check("native look: paper becomes the window background", NativeRoles.role(light: Ink.paperHex) == .window)
        check("native look: brand persimmon keeps its color", NativeRoles.role(light: Ink.persimmonHex) == nil)
        check("native look: buttons use title case", NativeText.titleCase("Don't ask for this app") == "Don't Ask for This App")
        check("native look: Pick a look comes after the welcome", OnboardingStep.at(1) == .look && OnboardingStep.count == 6)
        check("native look: Settings › General › Look is searchable", SettingsIndex.search("native").map(\.id).contains("general.look"))
        // The run starts in Verbose style (above), so this checks Verbose keeps its tokens; nativeChecks() checks Native.
        check("native look: Verbose style keeps its own tokens", !NativeSwap.on && NativeSwap.color(light: Ink.paperHex) == nil)
        // What's new: the bundled notes, their rules, when Home's note shows, and where it's found (ReleaseNotes.swift).
        ReleaseNotes.selfTest { check($0, $1) }
        check("release notes: Settings search finds What's new", SettingsIndex.search("release notes").map(\.section).contains(.whatsNew))

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
        appAudioChecks(check)
        cleanupChecks(check)
        VocabularySelfTest.run(check)
        OriginalCleanedSelfTest.run(check)
        check("settings search finds built-in vocabulary", SettingsIndex.search("chatgpt spelling").map(\.id).contains("models.builtInVocabulary"))
        HomeSelfTest.run(check)
        AudioDuckerSelfTest.run(check)
        check("settings search finds This week", SettingsIndex.search("this week").map(\.id).contains("general.homeWeek"))
        check("settings search finds Customize Home", SettingsIndex.search("edit home").map(\.id).contains("general.customizeHome"))
        // Show words while you record (RecordingWords.swift): on by default, findable, and never started by the
        // self-test (no speech on the runner).
        check("settings search finds show words while you record", SettingsIndex.search("words while you record").map(\.id).contains("models.recordLiveWords"))
        check("show words while you record is on by default", {
            let k = RecordingWords.enabledKey, stored = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
            defer { UserDefaults.standard.set(stored, forKey: k) }
            return RecordingWords.enabled
        }())
        let preview = RecordingWords()
        preview.begin(Recorder())
        check("recorder live words stay off in the self-test", !preview.isActive && preview.shown.isEmpty)
        preview.end()
        // Speech recognition permission is asked for only from an explicit action, and never in the self-test, so no
        // dialog covers the tour's screenshots (builds 199 and 200 asked whenever the Ribbon went idle).
        check("speech permission is never asked in the self-test", !DictationController.mayAskSpeechPermission)
    }

    /// App audio capture: synthetic sample buffers go through the live capture's path (owned copy, then the
    /// segmented writer). Each buffer's memory is overwritten right after it's consumed, as ScreenCaptureKit
    /// releases it, so a write that still pointed into it would read garbage.
    private static func appAudioChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("verbatim-app-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.wav")
        let chunk = 1_024, count = 12
        // A ramp that never repeats within the file, so a dropped, doubled, or garbled buffer shows.
        func sample(_ i: Int) -> Float { Float((i * 37) % 2_001 - 1_000) / 1_250 }
        var asbd = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        var buffers: [CMSampleBuffer] = []
        for b in 0..<count {
            let values = (0..<chunk).map { sample(b * chunk + $0) }
            var block: CMBlockBuffer?
            guard let desc, CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: chunk * 4,
                                                               blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                               dataLength: chunk * 4, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                               blockBufferOut: &block) == noErr, let block else { break }
            _ = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: chunk * 4) }
            var sb: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: desc,
                                                                      sampleCount: chunk, presentationTimeStamp: CMTime(value: CMTimeValue(b * chunk), timescale: 16_000),
                                                                      packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let sb else { break }
            buffers.append(sb)
        }
        check("app audio: synthetic sample buffers made", buffers.count == count)
        let junk = [Float](repeating: 0.9, count: chunk)
        let written = AppAudioCapture.selfTestWrite(buffers, to: url) { sb in
            // What ScreenCaptureKit does once the callback returns: the block's memory is no longer ours.
            guard let block = sb.dataBuffer else { return }
            _ = junk.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: chunk * 4) }
        }
        var got: [Int16] = []
        if let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true),
           let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)), (try? f.read(into: b)) != nil,
           let ch = b.int16ChannelData?[0] {
            got = Array(UnsafeBufferPointer(start: ch, count: Int(b.frameLength)))
        }
        let total = chunk * count
        var worst = 0
        for i in 0..<min(total, got.count) { worst = max(worst, abs(Int(got[i]) - Int((sample(i) * 32_767).rounded()))) }
        Log.note("UITEST app audio frames written=\(written ?? -1) read=\(got.count) worst diff=\(worst)")
        check("app audio: every frame is written", written == Int64(total) && got.count == total)
        check("app audio: written samples match the input", got.count == total && worst <= 2)
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

        // Cloud share links and private-video sign-in (CloudShareLinkChecks and LinkSignInChecks, also run by
        // mac/tools/test-cloudlinks.sh; the iPhone self-test runs the cloud links too).
        for r in CloudShareLinkChecks.run() + LinkSignInChecks.run() {
            check(r.name, r.ok)
            if !r.ok { Log.note("UITEST detail: " + r.detail) }
        }
        check("settings search finds sign-in for private videos", SettingsIndex.search("cookies").map(\.id).contains("links.signIn"))
        check("cloud links don't need the yt-dlp helper", LinkFetcher.canFetch("https://www.dropbox.com/s/abc123/talk.mp4?dl=0"))
        check("spoken corrections stay off the prompt when off",
              !FlowCleanup.instructions(level: .clean, corrections: false).contains("scratch that") && FlowCleanup.instructions(level: .clean, corrections: true).contains("scratch that"))
    }

    /// Screen-change timing for CI, never a pass or fail: from the navigation (the click that called `go`) to the new
    /// screen's root `onAppear`, and to the next turn of the main loop after it (the first frame committed). One line
    /// per change: `UITEST TIMING <screen> <ms> settled=<ms>`. Launch's first screen isn't a change and isn't logged, and
    /// neither is the same screen appearing again for the same navigation: a look switch rebuilds the window, and its
    /// screen used to be timed from the last click seconds before (build 213's 5,103 ms transcript and 1,391 ms Home in
    /// `tour-native` were the switches, which `look-switch` already times), and Native's split view can make a screen
    /// appear twice (two identical lines).
    private static var lastTimedNav = 0
    static func screenAppeared(_ key: String, nav: Int, since start: Date, window: NSWindow?) {
        guard enabled, nav > 0, nav != lastTimedNav else { return }
        lastTimedNav = nav
        let screen = key.hasPrefix("t-") ? "transcript" : key
        let appeared = Date().timeIntervalSince(start) * 1000
        DispatchQueue.main.async { [weak window] in
            let settled = Date().timeIntervalSince(start) * 1000
            let marks = LookSwitch.endNavigationMarks()
            Log.note("UITEST TIMING \(screen) \(Int(appeared.rounded())) settled=\(Int(settled.rounded()))")
            if !marks.isEmpty { Log.note("UITEST nav marks \(screen) \(marks) settled+\(Int(settled.rounded()))") }
            timings.append((appeared, settled))
            // The screens in the window on the turn of the main loop after the change (after the timing, so the walk
            // isn't timed): exactly one, or an outgoing screen is still drawn over or under the new one.
            let roots = screenRoots(in: window)
            lastRoots = (nav, roots)
            if roots.count != 1 { Log.note("UITEST note: \(roots.count) screens in the window after the change to \(screen): \(roots.joined(separator: ", "))") }
        }
    }

    /// The screens in the window just after the last timed navigation (its number and their keys).
    private static var lastRoots: (nav: Int, keys: [String]) = (0, [])

    /// Each screen root's marker (`screenRootMarker`, ContentView.swift) in the window's views, by screen key.
    static func screenRoots(in window: NSWindow?) -> [String] {
        guard let top = window?.contentView?.superview ?? window?.contentView else { return [] }
        var keys: [String] = []
        func walk(_ v: NSView) {
            if let m = v as? ScreenRootMarkerView { keys.append(m.key) }
            for s in v.subviews { walk(s) }
        }
        walk(top)
        return keys
    }

    /// Passes when the last navigation left exactly one screen in the window, the one it went to.
    private static func oneScreen(_ name: String, app: AppState) {
        let (nav, keys) = lastRoots
        let ok = nav == app.navCount && keys.count == 1
        if !ok { Log.note("UITEST detail: one screen after \(name): nav \(nav) of \(app.navCount), screens \(keys)") }
        check("one screen in the window after \(name)", ok)
    }

    /// Screen changes with the big library (BigLibrarySeed) while a file transcribes: a placeholder job's progress
    /// ticks at the queue's rate (4 a second, as `ProgressGate` lets a running job's through) and the self-test moves
    /// through the main screens and a transcript. Logs each change and `UITEST TIMING summary big-library-transcribing`.
    /// Then the placeholder and the 1,000 seeded transcripts are deleted, so every later step sees the library it
    /// always did. (A real job would need a speech model, which CI doesn't download.)
    private static func bigLibrarySteps(app: AppState) async {
        let seeded = app.store.transcripts.filter { BigLibrarySeed.isSeeded($0.id) }
        guard !seeded.isEmpty else { Log.note("UITEST note: no big library; its timings are skipped"); return }
        timings = []
        var job = Transcript(title: "Transcribing (perf)", source: .file, sourceLabel: "MP3 file", duration: 3600, audioFileName: nil, model: "Parakeet TDT v3")
        job.status = .processing
        job.stage = "Transcribing 0%"
        app.store.add(job)
        let id = job.id
        let ticker = Task { @MainActor in
            var p = 0
            while !Task.isCancelled {
                p = (p + 1) % 100
                app.store.setStage(id, "Transcribing \(p)%")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        var screens: [Screen] = [.library, .home, .links, .moments, .queue, .dictations, .activity, .trash]
        if let big = seeded.first?.id { screens += [.transcript(big), .library] }
        screens.append(.home)
        for screen in screens {
            app.go(screen)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        ticker.cancel()
        timingSummary("big-library-transcribing")
        if let t = app.store.transcript(id) { app.store.delete(t) }
        BigLibrarySeed.remove(from: app.store)
        app.go(.home)
        try? await Task.sleep(nanoseconds: 800_000_000)
        timings = []
    }

    /// Screen changes timed since the last summary: (appeared, settled) in ms.
    private static var timings: [(appeared: Double, settled: Double)] = []

    /// One line per stretch of the run for build-to-build comparison, never a pass or fail:
    /// `UITEST TIMING summary <label> n=<changes> appeared-median=<ms> settled-median=<ms> settled-p90=<ms>
    /// settled-max=<ms> settled-total=<ms>`. Starts the next stretch.
    private static func timingSummary(_ label: String) {
        defer { timings = [] }
        let closed = SettingsModel.shared.closedRenders
        SettingsModel.shared.closedRenders = (0, 0)
        Log.note("UITEST settings closed-window renders \(label) root=\(closed.root) pane=\(closed.pane)")
        guard !timings.isEmpty else { Log.note("UITEST TIMING summary \(label) n=0"); return }
        func pick(_ v: [Double], _ q: Double) -> Int { Int(v.sorted()[min(v.count - 1, Int((Double(v.count - 1) * q).rounded()))].rounded()) }
        let appeared = timings.map(\.appeared), settled = timings.map(\.settled)
        Log.note("UITEST TIMING summary \(label) n=\(timings.count) appeared-median=\(pick(appeared, 0.5)) settled-median=\(pick(settled, 0.5)) settled-p90=\(pick(settled, 0.9)) settled-max=\(pick(settled, 1)) settled-total=\(Int(settled.reduce(0, +).rounded()))")
    }

    private static func step(_ name: String, _ window: NSWindow, target: String, clicks: Int = 1, check: () -> Bool) async {
        await reveal(target, in: window)
        click(target, in: window)
        if clicks > 1 { click(target, in: window) }   // a double-click: the second click lands at once
        try? await Task.sleep(nanoseconds: 900_000_000)
        let ok = check()
        if ok { pass += 1 } else { fail += 1 }
        Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name)")
    }

    /// Moves the pointer onto the target, then clicks it, through the window's own event path.
    private static func click(_ id: String, in main: NSWindow) {
        let window = id.hasPrefix("sheet-") ? (main.attachedSheet ?? main) : main
        guard let f = windowFrames[id]?() ?? frames[id], let content = window.contentView else { Log.note("UITEST missing target \(id); known=\(frames.keys.sorted())"); return }
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
        // An AppKit control (an NSTableView like Native's sidebar, or an NSButton like the Native toolbar's Back) tracks
        // the press in a loop of its own that waits for the mouse-up in the event queue. Sent straight after the down,
        // the up never reached that loop, so the click blocked the main thread for good (build 209 stopped at the Native
        // sidebar click; builds 210 to 212 at the toolbar's Back, so `tour-native` was never logged). Where a control is
        // found under the point the up is queued first; everywhere else both still go straight to the window. A hit test
        // doesn't always find what the window routes the down to (the toolbar's Back in build 212), so a timer in the
        // common modes, which the tracking loop runs, queues the up if the down is still tracking half a second later.
        var tracked = false
        var hv = (content.superview ?? content).hitTest(content.convert(p, to: nil))
        while let x = hv { if x is NSControl { tracked = true; break }; hv = x.superview }
        if tracked, let x = hv { Log.note("UITEST click \(id) queues the mouse-up first (\(type(of: x)) tracks the press)") }
        if let m = ev(.mouseMoved) { window.sendEvent(m) }
        if tracked, let u = ev(.leftMouseUp) { NSApp.postEvent(u, atStart: true) }
        var rescued = false
        if let d = ev(.leftMouseDown) {
            let watch = ClickWatch(up: tracked ? nil : ev(.leftMouseUp))
            let timer = Timer(timeInterval: 0.5, repeats: false) { _ in MainActor.assumeIsolated { watch.rescue() } }
            RunLoop.main.add(timer, forMode: .common)
            window.sendEvent(d)
            timer.invalidate()
            rescued = watch.rescued
            if rescued { Log.note("UITEST click \(id): the down was still in a tracking loop after 0.5 s; the up was queued for it") }
        }
        if !tracked, !rescued, let u = ev(.leftMouseUp) { window.sendEvent(u) }
    }
}

/// The self-test click's watchdog (`UITest.click`): queues the mouse-up for a down that's still in a tracking loop.
@MainActor
private final class ClickWatch {
    private var up: NSEvent?
    private(set) var rescued = false
    init(up: NSEvent?) { self.up = up }
    func rescue() {
        guard let u = up else { return }
        up = nil
        rescued = true
        NSApp.postEvent(u, atStart: true)
    }
}

extension UITest {
    /// Controls outside the window content's coordinate space (toolbar items live in hosting views of their own):
    /// their frames, worked out when clicked, in the same top-left coordinates as `frames`.
    static var windowFrames: [String: () -> CGRect?] = [:]
}

/// Records a control's frame in window coordinates for the self-test (toolbar items; see `UITest.windowFrames`).
private struct UIWindowTarget: NSViewRepresentable {
    var id: String
    func makeNSView(context: Context) -> NSView {
        let v = Probe()
        UITest.windowFrames[id] = { [weak v] in v?.frameInWindow }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Probe: NSView {
        var frameInWindow: CGRect? {
            guard let w = window, let content = w.contentView, !isHiddenOrHasHiddenAncestor else { return nil }
            let r = convert(bounds, to: nil)
            return CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// `uiTarget` for a control in the toolbar.
    @ViewBuilder func uiWindowTarget(_ id: String) -> some View {
        if UITest.enabled { background(UIWindowTarget(id: id)) } else { self }
    }
}

/// Records a control's frame for the self-test. Outside the self-test it adds nothing (it used to add a
/// GeometryReader that tracked the global frame of every target on every scroll and layout pass).
struct UITarget: ViewModifier {
    var id: String
    func body(content: Content) -> some View {
        if UITest.enabled {
            content.background(GeometryReader { g in
                Color.clear
                    .onAppear { UITest.frames[id] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in UITest.frames[id] = f }
            })
        } else {
            content
        }
    }
}
extension View { func uiTarget(_ id: String) -> some View { modifier(UITarget(id: id)) } }

// MARK: - Thoughts

extension UITest {
    /// Thoughts seeded for the self-test and the tour: five on today's page (one from the iPhone), and a few on earlier
    /// days so the calendar has dots. With `withTranscribing`, one more that's still transcribing. Returns today's, in
    /// the order they started. Text only, so nothing is transcribed.
    @discardableResult
    static func seedThoughts(_ app: AppState, withTranscribing: Bool = false) -> [UUID] {
        let hour = Thoughts.newPageHour
        let base = DayPages.today(hour: hour)   // the page's day, at midnight
        let cal = Calendar.current
        func at(_ day: Date, _ h: Int, _ m: Int) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: day) ?? day }
        let lines: [(Int, Int, String, String)] = [
            (9, 14, "Move the export button into the toolbar so it sits next to Share.", Thoughts.macSource),
            (9, 40, "Pick up printer paper and AA batteries on the way home.", "Thought · iPhone"),
            (10, 5, "Try the calendar dots in ink, not persimmon. Persimmon only means recording.", Thoughts.macSource),
            (10, 21, "Ask whether the onboarding video can drop to sixty seconds.", "Thought · iPhone"),
            (10, 42, "Day headers could use the mono date, like the website.", Thoughts.macSource),
        ]
        var ids: [UUID] = []
        if let existing = app.store.transcripts.first(where: { $0.title == "Self-test thought 1" }), existing.deletedAt == nil {
            ids = app.store.page(.idea, day: base, hour: hour).filter { $0.title.hasPrefix("Self-test thought ") }.map(\.id)
        } else {
            for (i, l) in lines.enumerated() {
                let t = ThoughtPadMigration.textThought(l.2, at: at(base, l.0, l.1), source: l.3, title: "Self-test thought \(i + 1)")
                app.store.add(t)
                ids.append(t.id)
            }
            for (ago, text) in [(1, "Rename the share sheet action to Send a copy."), (2, "Order a second stand for the review monitor."), (4, "Empty states need one sentence, not two.")] {
                app.store.add(ThoughtPadMigration.textThought(text, at: at(DayPages.day(base, moved: -ago), 15, 0), source: Thoughts.macSource))
            }
        }
        if withTranscribing, !app.store.live.contains(where: { $0.title == "Self-test thought, transcribing" }) {
            var t = Transcript(title: "Self-test thought, transcribing", source: .voiceMemo, sourceLabel: Thoughts.macSource, duration: 9, audioFileName: nil, model: "")
            t.createdAt = at(base, 11, 3)
            t.kind = .idea; t.kindIsAuto = false; t.status = .processing; t.stage = "Transcribing"
            app.store.add(t)
        }
        return ids
    }

    /// Today's page and the bubble's recording and saved states, for CI's screenshots.
    static func thoughtShots(suffix: String) async {
        guard let app = appRef else { return }
        seedThoughts(app, withTranscribing: true)
        ThoughtPadController.shared.open()
        await show("08b-thoughts-page\(suffix)")
        ThoughtPadController.shared.close()
        guard suffix.isEmpty else { return }
        let capture = ThoughtCapture.shared
        capture.simulate = true
        Thoughts.showBubble = true
        capture.start()
        await show("08f-thought-bubble-recording")
        capture.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        write(show: "08g-thought-bubble-saved")
        Log.note("UITEST show 08g-thought-bubble-saved")
        try? await Task.sleep(nanoseconds: 1_600_000_000)   // "Added to Thoughts" shows for two seconds
        capture.simulate = false
        Thoughts.showBubble = false
    }

    /// Thoughts, clicked: today's page in time order with times, its day arrows, the mic and the bubble starting and
    /// stopping a thought into today's page (simulated audio), the menu bar's group, By day with the calendar's dots
    /// for Thoughts and Journal, the rename in the Library's filters, and the Thought pad's one-time move. The page and
    /// the bubble never become key, and neither can activate Verbose.
    static func thoughtsSteps(app: AppState, window: NSWindow) async {
        let capture = ThoughtCapture.shared
        let hour = Thoughts.newPageHour
        let today = DayPages.today(hour: hour)
        seedArchive(app)
        let seeded = seedThoughts(app)
        try? await Task.sleep(nanoseconds: 600_000_000)

        check("thoughts: Idea is called Thoughts in pickers and filters", RecordingKind.idea.label == "Thoughts" && RecordingKind.idea.plural == "Thoughts"
              && RecordingKind.idea.rawValue == "idea" && RecordingKind.pickable.contains(.idea))
        let page = app.store.page(.idea, day: today, hour: hour).filter { seeded.contains($0.id) }
        check("thoughts: today's page lists the seeded thoughts in the order they started", page.map(\.id) == seeded && page.count == 5)
        check("thoughts: each thought has its time", page.allSatisfy { !Thoughts.time($0.createdAt, native: false).isEmpty }
              && Thoughts.time(page.first?.createdAt ?? Date(), native: false).contains("14"))
        check("thoughts: Copy joins the day with blank lines", Thoughts.joined(page).components(separatedBy: "\n\n").count == 5)

        // Today's page: open, not key, and its arrows.
        let pad = ThoughtPadController.shared
        pad.open()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let panel = pad.panelWindow else { check("thoughts: today's page opens", false); return }
        check("thoughts: today's page opens on today without becoming key or activating Verbose",
              panel.isVisible && !panel.isKeyWindow && NSApp.keyWindow !== panel && panel.styleMask.contains(.nonactivatingPanel)
              && pad.state.day == today && frames["page-title"] != nil)
        await panelStep("thoughts: the arrow goes to the day before", panel, target: "page-prev", check: { pad.state.day == DayPages.day(today, moved: -1) })
        await panelStep("thoughts: the arrow comes back to today", panel, target: "page-next", check: { pad.state.day == today })
        await panelStep("thoughts: Next is off on today", panel, target: "page-next", check: { pad.state.day == today })

        // The mic on the page starts and stops a thought (simulated audio) that lands on today's page.
        capture.simulate = true
        var before = app.store.page(.idea, day: today, hour: hour).count
        await panelStep("thoughts: the page's mic starts a thought", panel, target: "page-mic", check: { capture.isRecording })
        await panelStep("thoughts: the page's mic stops it, and it lands on today's page", panel, target: "page-mic",
                        check: { !capture.isRecording && app.store.page(.idea, day: today, hour: hour).count == before + 1 })
        let added = app.store.page(.idea, day: today, hour: hour).last
        check("thoughts: a new thought is saved as audio before it's transcribed",
              added.map { $0.audioFileName != nil && ($0.status == .processing || $0.status == .ready || $0.status == .failed) && $0.kind == .idea } == true)
        check("thoughts: the page never became key", !panel.isKeyWindow)
        pad.close()

        // The bubble: a click starts a thought, another adds it to today's page; it never becomes key.
        Thoughts.showBubble = true
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let bubble = ThoughtBubble.shared.panelWindow, bubble.isVisible {
            before = app.store.page(.idea, day: today, hour: hour).count
            await bubbleStep("thoughts: a click on the bubble starts a thought", bubble, check: { capture.isRecording })
            await bubbleStep("thoughts: another click adds it to today's page", bubble,
                             check: { !capture.isRecording && app.store.page(.idea, day: today, hour: hour).count == before + 1 })
            check("thoughts: the bubble says it was added", { if case .saved = capture.phase { return true }; return false }())
            check("thoughts: the bubble never becomes key or activates Verbose",
                  !bubble.isKeyWindow && !bubble.canBecomeKey && bubble.styleMask.contains(.nonactivatingPanel) && bubble.level == .statusBar)
        } else {
            check("thoughts: the bubble is on screen", false)
        }

        // The menu bar's Thoughts group, in a window of its own.
        let menu = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 320, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        menu.contentView = FirstClickHostingView(rootView: ThoughtsMenuSection().environmentObject(app).frame(width: 320).background(Ink.paper))
        menu.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 800_000_000)
        check("thoughts: the menu bar has New thought, Today's count, Open today's page, and Show the bubble",
              ["menu-new-thought", "menu-today-count", "menu-open-page", "menu-show-bubble"].allSatisfy { frames[$0] != nil })
        // Show the bubble before Open today's page: that row's dismiss() runs against this stand-in panel, which a
        // real menu bar panel never outlives, so nothing is clicked in it afterwards.
        Log.note("UITEST thoughts: before Show the bubble, showBubble=\(Thoughts.showBubble) showing=\(ThoughtBubble.shared.isShowing)")
        await panelStep("thoughts: the menu's Show the bubble hides it", menu, target: "menu-show-bubble", check: {
            Log.note("UITEST thoughts: after the first click, showBubble=\(Thoughts.showBubble) showing=\(ThoughtBubble.shared.isShowing)")
            return !Thoughts.showBubble && !ThoughtBubble.shared.isShowing
        })
        await panelStep("thoughts: and shows it again", menu, target: "menu-show-bubble", check: {
            Log.note("UITEST thoughts: after the second click, showBubble=\(Thoughts.showBubble) showing=\(ThoughtBubble.shared.isShowing)")
            return Thoughts.showBubble && ThoughtBubble.shared.isShowing
        })
        await panelStep("thoughts: the menu's Open today's page opens it", menu, target: "menu-open-page", check: { pad.isOpen })
        pad.close()
        // The stand-in goes for good: a panel that's only ordered out keeps its views, which would go on observing.
        menu.orderOut(nil)
        menu.contentView = nil
        menu.close()
        capture.simulate = false
        Thoughts.showBubble = false

        // Library › By day.
        window.makeKeyAndOrderFront(nil)
        frames = frames.filter { !$0.key.hasPrefix("byday") }
        await step("thoughts: the sidebar's Thoughts opens By day", window, target: "side-thoughts", check: { app.screen == .byDay(.idea) })
        try? await Task.sleep(nanoseconds: 600_000_000)
        let day = Calendar.current.component(.day, from: today)
        check("thoughts: By day shows the calendar with a dot on today, and the day's page",
              frames["byday-calendar"] != nil && frames["byday-dot-\(day)"] != nil && frames["byday-page"] != nil && frames["byday-thoughts"] != nil)
        frames = frames.filter { !$0.key.hasPrefix("byday") }
        await step("thoughts: the sidebar's Journal opens its By day", window, target: "side-journal", check: { app.screen == .byDay(.journal) })
        try? await Task.sleep(nanoseconds: 600_000_000)
        check("thoughts: Journal's calendar has a dot on today's entry", frames["byday-journal"] != nil && frames["byday-dot-\(day)"] != nil)
        app.projectFilter = nil; app.libraryFilter = .all; app.libraryKind = .idea
        app.go(.library)
        try? await Task.sleep(nanoseconds: 800_000_000)
        check("thoughts: the Library's kind filter says Thoughts", frames["kind-idea"] != nil && RecordingKind.idea.plural == "Thoughts")
        app.libraryKind = nil
        app.go(.home)

        // The Thought pad's pieces move into Thoughts once, on the day each was written.
        let defaults = UserDefaults(suiteName: "uitest.thoughts.migration")!
        defaults.removePersistentDomain(forName: "uitest.thoughts.migration")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("thoughtpad-selftest.json")
        let p1 = UUID(), p2 = UUID()
        let yesterday = Date().addingTimeInterval(-86_400)
        let json = "{\"title\":\"Catalog shoot email\",\"pieces\":[{\"id\":\"\(p1.uuidString)\",\"text\":\"Shoot the wheels on white first.\",\"seconds\":14,\"missed\":false,\"createdAt\":\(yesterday.timeIntervalSinceReferenceDate)},{\"id\":\"\(p2.uuidString)\",\"text\":\"Ask Jonathan for the spec sheet.\",\"seconds\":6,\"missed\":true,\"createdAt\":\(Date().timeIntervalSinceReferenceDate)}]}"
        try? Data(json.utf8).write(to: file)
        let moved = ThoughtPadMigration.run(app.store, from: file, defaults: defaults)
        let m1 = app.store.transcript(p1), m2 = app.store.transcript(p2)
        check("thoughts: the pad's pieces become text-only Thoughts on the day each was written", moved == 2 && m1?.kind == .idea && m1?.audioFileName == nil
              && m1.map { abs($0.createdAt.timeIntervalSince(yesterday)) < 1 } == true && m2?.title == "Catalog shoot email" && Thoughts.words(m2!) == "Ask Jonathan for the spec sheet.")
        try? Data(json.utf8).write(to: file)
        check("thoughts: the pad moves once only", ThoughtPadMigration.run(app.store, from: file, defaults: defaults) == 0)
        defaults.set(false, forKey: ThoughtPadMigration.doneKey)
        check("thoughts: even run again, a piece is never added twice", ThoughtPadMigration.run(app.store, from: file, defaults: defaults) == 0)
        for id in [p1, p2] { if let t = app.store.transcript(id) { app.store.delete(t) } }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().appendingPathComponent(PadMigration.doneName(file.lastPathComponent)))
        defaults.removePersistentDomain(forName: "uitest.thoughts.migration")
    }

    /// A click on a control in a floating panel (today's page, the menu's group), through the panel's own event path.
    private static func panelStep(_ name: String, _ panel: NSWindow, target: String, check: () -> Bool) async {
        click(target, in: panel)
        try? await Task.sleep(nanoseconds: 900_000_000)
        let ok = check()
        if ok { pass += 1 } else { fail += 1 }
        Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name)")
    }

    /// A click on the bubble: the pointer first, so the panel takes the click (it passes clicks through elsewhere).
    private static func bubbleStep(_ name: String, _ panel: NSWindow, check: () -> Bool) async {
        guard let f = frames["thought-bubble"], let content = panel.contentView else { fail += 1; Log.note("UITEST FAIL \(name): no bubble"); return }
        ThoughtBubble.shared.updatePointer(at: panel.convertPoint(toScreen: CGPoint(x: f.midX, y: content.bounds.height - f.midY)))
        let routed = !panel.ignoresMouseEvents
        click("thought-bubble", in: panel)
        try? await Task.sleep(nanoseconds: 900_000_000)
        let ok = routed && check()
        if ok { pass += 1 } else { fail += 1 }
        Log.note("UITEST \(ok ? "PASS" : "FAIL") \(name)\(routed ? "" : " (the panel ignored the pointer)")")
    }
}

// MARK: - Back

extension UITest {
    /// Library rows carry self-test targets (`lib-row-<id>`) only while the Back steps run, so the other steps and
    /// the big library's timings don't pay for a frame reader on every row.
    static var rowTargets = false

    /// Back and the places screens come back to (App/NavTrail.swift), in one look: scroll the Library down, open a row,
    /// and Back returns to the Library with the same row selected and in view, the same scroll offset (within a few
    /// points), and the same search and filter; ⌘[ and ⌘] with View › Back and Forward enabled as they should be; and
    /// Back from a transcript opened from Home returns to Home where it was. Forty seeded transcripts make the Library
    /// long enough to scroll; they and every remembered place are gone afterwards, so the tour's screens are unchanged.
    static func backSteps(app: AppState, window: NSWindow, native: Bool) async {
        let tag = native ? "back (native)" : "back"
        let look: AppLook = native ? .native : .verbose
        var ids: [UUID] = []
        for i in 0..<40 {
            var t = Transcript(title: String(format: "Backtrail %02d", i), source: .voiceMemo, sourceLabel: "Voice memo",
                               duration: 60 + Double(i), audioFileName: nil, model: "Test")
            t.kind = .meeting
            t.kindIsAuto = false
            t.createdAt = Date().addingTimeInterval(-3 * 86_400 - Double(i) * 4 * 3600)
            t.segments = [Segment(start: 0, end: 4, text: "A seeded line for the Back steps.", speaker: "S1")]
            t.original = t.segments
            app.store.add(t)
            ids.append(t.id)
        }
        rowTargets = true
        defer {
            rowTargets = false
            for id in ids { if let t = app.store.transcript(id) { app.store.delete(t) } }
            app.search = ""
            app.libraryKind = nil
            ScreenPlaces.shared.reset()
        }
        if native { NativeNav.shared.libraryTable = false }
        app.projectFilter = nil; app.libraryFilter = .all; app.libraryKind = .meeting
        app.go(.library)
        app.search = "Backtrail"
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        // 1. Scroll the Library down, select a row near the middle, and open it.
        let key = ScreenPlaces.scrollKey(ScreenPlaces.libraryKey(nil), look: look)
        ScreenPlaces.shared.scrollLive(key, by: 600)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let h = window.contentView?.bounds.height ?? 0
        func rowFrame(_ id: UUID) -> CGRect? { native ? windowFrames["lib-row-\(id.uuidString)"]?() : frames["lib-row-\(id.uuidString)"] }
        // The row nearest the window's lower middle, well inside the list.
        var picked: (id: UUID, distance: CGFloat)?
        for id in ids {
            guard let f = rowFrame(id), f.minY > 120, f.maxY < h - 60 else { continue }
            let d = abs(f.midY - h * 0.6)
            if picked == nil || d < picked!.distance { picked = (id, d) }
        }
        guard let row = picked?.id, let scrolled = ScreenPlaces.shared.liveOffset(key), scrolled > 100 else {
            Log.note("UITEST detail: \(tag): offset \(ScreenPlaces.shared.liveOffset(key).map { "\(Int($0))" } ?? "none"), rows on screen \(ids.filter { rowFrame($0) != nil }.count)")
            check("\(tag): the Library scrolls down to a row to open", false)
            return
        }
        let target = "lib-row-\(row.uuidString)"
        if native {
            await step("\(tag): clicking an item in the scrolled Library selects it", window, target: target, check: { NativeNav.shared.librarySelection == row })
        }
        let before = ScreenPlaces.shared.liveOffset(key) ?? scrolled
        await step("\(tag): \(native ? "double-clicking" : "clicking") a row in the scrolled Library opens it", window, target: target,
                   clicks: native ? 2 : 1, check: { app.screen == .transcript(row) })
        oneScreen("opening a transcript from the scrolled Library\(native ? " (native)" : "")", app: app)

        // 2. Back: the same row, offset, search, and filter.
        await step("\(tag): \(native ? "the toolbar's Back" : "the transcript's back pill") returns to the Library", window,
                   target: native ? "tb-back" : "transcript-back", check: { app.screen == .library })
        oneScreen("Back to the Library\(native ? " (native)" : "")", app: app)
        let after = ScreenPlaces.shared.liveOffset(key)
        check("\(tag): the Library comes back at the same scroll offset (\(Int(before)), now \(after.map { "\(Int($0))" } ?? "none"))",
              after.map { abs($0 - before) <= 4 } ?? false)
        let selected = ScreenPlaces.shared.selectedRow(nil) == row && (!native || NativeNav.shared.librarySelection == row)
        let inView = rowFrame(row).map { $0.minY >= 0 && $0.maxY <= h } ?? false
        check("\(tag): the same row is selected and in view", selected && inView)
        check("\(tag): the same search and filter", app.search == "Backtrail" && app.libraryKind == .meeting && app.libraryFilter == .all && app.projectFilter == nil)
        if let r = ScreenPlaces.shared.lastRestore { Log.note("UITEST note: \(tag) restore key=\(r.key) offset=\(Int(r.offset)) before the first frame=\(r.early)") }

        // 3. ⌘[ and ⌘], and View › Back and Forward.
        app.go(.transcript(row))
        try? await Task.sleep(nanoseconds: 800_000_000)
        check("\(tag): on a transcript, View › Back is on and Forward is off", viewMenuItem("Back")?.isEnabled == true && viewMenuItem("Forward")?.isEnabled == false)
        commandKey("[", in: window)
        try? await Task.sleep(nanoseconds: 900_000_000)
        check("\(tag): ⌘[ goes back to the Library", app.screen == .library)
        check("\(tag): after going back, View › Forward is on", viewMenuItem("Forward")?.isEnabled == true)
        commandKey("]", in: window)
        try? await Task.sleep(nanoseconds: 900_000_000)
        check("\(tag): ⌘] goes forward to the transcript", app.screen == .transcript(row))

        // 4. Back from a transcript opened from Home returns to Home, where it was.
        app.search = ""
        app.libraryKind = nil
        app.go(.home)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let homeKey = ScreenPlaces.scrollKey("home", look: look)
        ScreenPlaces.shared.scrollLive(homeKey, by: 80)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await reveal("row-0", in: window)
        let homeBefore = ScreenPlaces.shared.liveOffset(homeKey)
        if native {
            // A Home item's click lands on its play pill or menu as often as its title; open it as its title does.
            if let t = app.archive.first { app.go(.transcript(t.id)) }
            try? await Task.sleep(nanoseconds: 900_000_000)
        } else {
            await step("\(tag): a row on Home opens its transcript", window, target: "row-0", check: { app.screen.transcriptID != nil })
        }
        await step("\(tag): Back from a transcript opened from Home returns to Home", window,
                   target: native ? "tb-back" : "transcript-back", check: { app.screen == .home })
        oneScreen("Back to Home\(native ? " (native)" : "")", app: app)
        let homeAfter = ScreenPlaces.shared.liveOffset(homeKey)
        check("\(tag): Home comes back at the same scroll offset (\(homeBefore.map { "\(Int($0))" } ?? "none"), now \(homeAfter.map { "\(Int($0))" } ?? "none"))",
              homeBefore != nil && homeAfter.map { abs($0 - homeBefore!) <= 4 } == true)
    }

    /// View › `title`, validated as the menu bar would before it opens.
    private static func viewMenuItem(_ title: String) -> NSMenuItem? {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return nil }
        menu.update()
        return menu.items.first { $0.title == title }
    }

    /// ⌘ and a key, through the main menu's key equivalents (as a key press reaches them).
    private static func commandKey(_ key: String, in window: NSWindow) {
        let code: UInt16 = key == "[" ? 33 : 30
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                                       isARepeat: false, keyCode: code) else { return }
        if NSApp.mainMenu?.performKeyEquivalent(with: e) != true { Log.note("UITEST note: no menu item took ⌘\(key)") }
    }
}
