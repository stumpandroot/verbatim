import SwiftUI
import AppKit
import AVFoundation

/// In-app UI self-test. With VERBATIM_UITEST=1 in the environment, the app seeds a transcript, synthesizes
/// real mouse events at the recorded positions of key controls, and logs PASS/FAIL per step to native.log.
/// CI runs it on a macOS 26 runner, so hit-testing regressions are caught before a build ships.
@MainActor
enum UITest {
    static let enabled = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1"
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
            await step("mode switch to Dictate", window, target: "mode-dictate", check: { app.captureMode == "dictate" })
            await step("mode switch back to Voice note", window, target: "mode-voice", check: { app.captureMode == "voice" })
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
        seedRich(app)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let memo = app.store.transcripts.first { $0.title == "Lapp Wagons catalog call" }
        app.go(.home); app.captureMode = "voice"
        await show("01-home")
        app.captureMode = "dictate"
        await show("02-home-dictate")
        app.captureMode = "voice"
        app.requestRecord()                       // no mic on the runner: the permission sheet
        await show("03-mic-sheet")
        app.showMicSheet = false
        app.showAppPicker = true
        await show("04-app-picker")
        app.showAppPicker = false
        app.projectFilter = nil; app.go(.library)
        await show("05-library")
        if let m = memo { app.go(.transcript(m.id)) }
        await show("06-transcript")
        NotificationCenter.default.post(name: .verbatimShowMode, object: "Document")
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // Harper lints off the main thread
        await show("06b-document")
        NotificationCenter.default.post(name: .verbatimShowMode, object: "Transcript")
        app.go(.dictionary)
        await show("07-dictionary")
        app.dictation.previewPill(seconds: 4)
        await show("08-dictate-pill")
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        await show("09-settings")
        NSApp.windows.filter { $0 != window && $0.isVisible }.forEach { $0.close() }
        app.go(.home)
        await show("10-home-again")
        write(show: "done")
    }

    private static func show(_ name: String) async {
        try? await Task.sleep(nanoseconds: 1_200_000_000)   // let transitions settle
        write(show: name)
        Log.note("UITEST show \(name)")
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // CI captures in this window
    }

    private static func write(show name: String) {
        let url = Log.file.deletingLastPathComponent().appendingPathComponent("show.txt")
        try? (name + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// A transcript with real audio (so the player dock shows), notes, a bookmark, a project, and dictionary words.
    private static func seedRich(_ app: AppState) {
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
