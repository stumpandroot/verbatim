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
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { Log.note("UITEST FAIL no window"); return }
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
            app.verbiePose = .working; try? await Task.sleep(nanoseconds: 300_000_000); app.verbiePose = .ready
            await step("row opens transcript again", window, target: "row-0", check: { if case .transcript = app.screen { return true } else { return false } })

            Log.note("UITEST DONE pass=\(pass) fail=\(fail)")
            await tour(app: app, window: window)
        }
    }

    // MARK: Screenshot tour

    /// Walks every screen with richer seeded data. CI watches `show.txt` and captures each name.
    private static func tour(app: AppState, window: NSWindow) async {
        appRef = app
        seedRich(app)
        seedDictations(app)
        seedActivity()
        try? await Task.sleep(nanoseconds: 800_000_000)
        let memo = app.store.transcripts.first { $0.title == "Lapp Wagons catalog call" }
        app.go(.home); app.captureMode = "voice"
        await show("01-home")
        app.captureMode = "dictate"
        await show("02-home-dictate")
        app.captureMode = "voice"
        try? await Task.sleep(nanoseconds: 500_000_000)
        app.requestRecord()                       // no mic on the runner: the permission sheet
        await show("03-mic-sheet")
        app.showMicSheet = false
        app.showAppPicker = true
        await show("04-app-picker")
        app.showAppPicker = false
        app.projectFilter = nil; app.go(.library)
        await show("05-library")
        app.go(.queue)
        await show("05b-queue")
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
        await show("07c-activity")
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
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        await show("09-settings")
        UserDefaults.standard.set(SettingsTab.actions.rawValue, forKey: "settingsTab")
        await show("09b-settings-actions")
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
        if let m = memo { app.go(.transcript(m.id)) }
        await show("12-dark-transcript")
        NotificationCenter.default.post(name: .verbatimShowMode, object: "Document")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await show("13-dark-document")
        app.go(.links)
        await show("14-dark-links")
        app.go(.library)
        await show("15-dark-library")
        app.go(.dictations)
        await show("16-dark-dictations")
        app.go(.activity)
        await show("17-dark-activity")
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
            (18, 24, "Chris mentioned the Lititz dealer wants a one-page sheet too. Same photos, trimmed copy.", "S2"),
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
        app.store.add(t)
        app.store.addNote(Note(text: "Ask Jonathan for the wheel spec sheet before the shoot.", at: 11, segmentId: t.segments[2].id, isBookmark: false), to: t.id)
        app.store.addNote(Note(text: "Folding wagon spread", at: 31, segmentId: t.segments[5].id, isBookmark: true), to: t.id)
        app.store.addNote(Note(text: "Quote for the one-page sheet: separate line item.", at: nil, segmentId: nil, isBookmark: false), to: t.id)
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
