import SwiftUI
import AppKit

/// In-app UI self-test. With VERBATIM_UITEST=1 in the environment, the app seeds a transcript, synthesizes
/// real mouse events at the recorded positions of key controls, and logs PASS/FAIL per step to native.log.
/// CI runs it on a macOS 26 runner, so hit-testing regressions are caught before a build ships.
@MainActor
enum UITest {
    static let enabled = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1"
    static var frames: [String: CGRect] = [:]     // SwiftUI .global (window content, top-left origin)
    private static var pass = 0, fail = 0

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

            await step("click row opens transcript", window) { click("row-0", in: window) } check: { if case .transcript = app.screen { return true } else { return false } }
            await step("sidebar Home goes home", window) { click("side-home", in: window) } check: { app.screen == .home }
            await step("sidebar Library opens library", window) { click("side-library", in: window) } check: { app.screen == .library }
            await step("sidebar Dictionary opens dictionary", window) { click("side-dict", in: window) } check: { app.screen == .dictionary }
            await step("sidebar home again (one click)", window) { click("side-home", in: window) } check: { app.screen == .home }
            try? await Task.sleep(nanoseconds: 900_000_000)   // let the Home slide-in finish before clicking inside it
            await step("mode switch to Dictate", window) { click("mode-dictate", in: window) } check: { app.captureMode == "dictate" }
            await step("mode switch back to Voice note", window) { click("mode-voice", in: window) } check: { app.captureMode == "voice" }
            await step("record tile asks for the mic or records", window) { click("tile-record", in: window) } check: { app.showMicSheet || app.recorder.isRecording }
            if app.showMicSheet {
                await step("mic sheet Not now closes it", window) { click("sheet-notnow", in: window) } check: { !app.showMicSheet }
            } else if app.recorder.isRecording {
                _ = app.recorder.stop()
            }
            await step("app tile opens the picker", window) { click("tile-app", in: window) } check: { app.showAppPicker }
            app.showAppPicker = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            app.verbiePose = .working; try? await Task.sleep(nanoseconds: 300_000_000); app.verbiePose = .ready
            await step("row opens transcript again", window) { click("row-0", in: window) } check: { if case .transcript = app.screen { return true } else { return false } }

            Log.note("UITEST DONE pass=\(pass) fail=\(fail)")
            // CI screenshots the transcript now, then Home a few seconds later.
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            app.go(.home)
        }
    }

    private static func step(_ name: String, _ window: NSWindow, act: () -> Void, check: () -> Bool) async {
        act()
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
