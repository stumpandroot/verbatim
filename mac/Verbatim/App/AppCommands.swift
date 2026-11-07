import SwiftUI
import AppKit

// The menu bar's commands beyond File's (macOS HIG, The menu bar; the interactions audit, MAC-03, MAC-21, MAC-22):
// every main action has a menu item with its shortcut, so Help's search finds it and it works on every screen.
//
// - Recording: Stop and Transcribe (⌥⇧.), Pause or Resume, and Mark Moment, enabled while a voice note, a thought, or
//   another app's audio records, whatever screen is showing (`RecordingMenuState`).
// - Dictation: Dictate, New Thought (⌃⌥P), and Recent Dictations (⌥⌘V, or the shortcut Settings › Dictation picks).
// - View: Bigger Text (⌘=), Smaller Text (⌘−), and Mark This Moment (B) on an open transcript.
// - Edit: Copy Text (⇧⌘C) and Copy for AI (⌥⇧⌘C) on an open transcript; Find… (⌘F) finds in the open transcript, and
//   elsewhere opens Search or ask; Find Next (⌘G) and Find Previous (⇧⌘G); Search or Ask… (⌘K) everywhere.
//
// The SwiftUI items observe their own objects (as `MeetingCaptureCommands` and `CheckForUpdatesButton` do). The
// transcript's items depend on the screen, which no observable object the menu bar could follow publishes, so they're
// AppKit items that AppKit validates when the menu opens and when a key equivalent is looked up, as Back and Forward
// are (NavMenuItems, App/NavTrail.swift). Nothing here is a hidden zero-size button.

/// What the menus call, so a key and a click do the same thing.
@MainActor
enum AppCommands {
    /// Stop and Transcribe: the voice note (a key shows no "Saved" on Home's Record card, DESIGN.md §7), or the app capture.
    static func stopRecording(_ app: AppState) {
        if app.recorder.isRecording {
            app.stopRecording(from: AppState.handlingKeyPress ? .keyboard : .elsewhere)
        } else if app.capture.isCapturing {
            app.stopCapture()
        }
    }

    /// Dictation › Dictate: Home's Dictate, with your dictation key and your last dictation (as Record's menu does).
    static func dictate(_ app: AppState) {
        app.mainWindow?.makeKeyAndOrderFront(nil)
        app.fromKeyboard(AppState.handlingKeyPress) { app.goHome() }
        app.captureMode = "dictate"
    }

    /// Find…: on a transcript, the find bar over its Original lines; anywhere else, the Search or ask panel on Search.
    static func find(_ app: AppState) {
        app.mainWindow?.makeKeyAndOrderFront(nil)
        if let id = app.screen.transcriptID, let t = app.store.transcript(id), t.status == .ready, !t.showsAudioDetail,
           WindowNav.shared.stillViewer == nil {
            if WindowNav.shared.mode != .original { WindowNav.shared.mode = .original }
            TranscriptFind.shared.show()
        } else {
            AskNav.shared.open(mode: .search)
        }
    }

    /// The Recent dictations shortcut as a menu key equivalent, or nil when it's off.
    static func recallShortcut(_ raw: String) -> KeyboardShortcut? {
        switch RecallShortcut(rawValue: raw) ?? .optionCommandV {
        case .optionCommandV: return KeyboardShortcut("v", modifiers: [.option, .command])
        case .controlOptionV: return KeyboardShortcut("v", modifiers: [.control, .option])
        case .off: return nil
        }
    }
}

// MARK: - Recording

/// The Recording menu's items. Watches the recorder, the app capture, and the thought, so it's enabled whenever one
/// runs (MAC-03): ⌥⇧. stops from the Library, a transcript, or Settings, not only from Home.
struct RecordingMenuItems: View {
    let app: AppState
    @ObservedObject var recorder: Recorder
    @ObservedObject var capture: AppAudioCapture
    @ObservedObject var thoughts: ThoughtCapture

    var body: some View {
        let s = RecordingMenuState(recording: recorder.isRecording, starting: recorder.isStarting, paused: recorder.isPaused,
                                   capturing: capture.isCapturing, thought: thoughts.isRecording)
        Button(s.stopTitle) { AppCommands.stopRecording(app) }
            .keyboardShortcut(".", modifiers: [.option, .shift])
            .disabled(!s.canStop)
        Button(s.pauseTitle) { app.togglePause() }
            .disabled(!s.canPause)
        // ⌃⌥B also marks from any app while something records (MarkCenter's hotkey, set in Settings).
        Button("Mark Moment") { MarkCenter.shared.mark(.macApp) }
            .disabled(!s.canMark)
    }
}

// MARK: - Dictation

/// The Dictation menu's items: Dictate, New Thought (Stop Thought while one records), and Recent Dictations.
struct DictationMenuItems: View {
    let app: AppState
    @ObservedObject var thoughts: ThoughtCapture
    @AppStorage(RecallShortcut.key) private var recall: String = RecallShortcut.optionCommandV.rawValue

    var body: some View {
        Button("Dictate") { AppCommands.dictate(app) }
        Button(thoughts.isRecording ? "Stop Thought" : "New Thought") {
            ThoughtCapture.shared.toggle(source: AppState.handlingKeyPress ? .keyboard : .elsewhere)
        }
        .keyboardShortcut("p", modifiers: [.control, .option])
        if let k = AppCommands.recallShortcut(recall) {
            Button("Recent Dictations") { app.dictation.toggleRecall() }.keyboardShortcut(k)
        } else {
            Button("Recent Dictations") { app.dictation.toggleRecall() }
        }
    }
}

// MARK: - Find

/// Find… and Search or Ask…, and Find Next and Find Previous while the find bar is open with matches.
struct FindMenuItems: View {
    let app: AppState
    @ObservedObject private var find = TranscriptFind.shared

    var body: some View {
        Button("Find…") { AppCommands.find(app) }
            .keyboardShortcut("f", modifiers: .command)
        Button("Find Next") { find.next() }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!find.canStep)
        Button("Find Previous") { find.previous() }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!find.canStep)
        // Search or ask: the panel over the main window (Views/AskViews.swift), on every screen.
        Button("Search or Ask…") {
            app.mainWindow?.makeKeyAndOrderFront(nil)
            if AskNav.shared.panelOpen { AskNav.shared.close() } else { AskNav.shared.open() }
        }
        .keyboardShortcut("k", modifiers: .command)
    }
}

// MARK: - The open transcript's items

/// View › Bigger Text, Smaller Text, and Mark This Moment, and Edit › Copy Text and Copy for AI, for the transcript in
/// the main window. AppKit items, validated against the screen when the menu opens or a key is looked up. B has no
/// modifier, so it's off while you type in a field (the key goes to the field) and while the stills viewer is open.
@MainActor
final class TranscriptMenuItems: NSObject, NSMenuItemValidation {
    static let shared = TranscriptMenuItems()
    private weak var app: AppState?
    private let viewSeparator = NSMenuItem.separator()
    private lazy var bigger = item("Bigger Text", "=", .command, #selector(biggerText(_:)))
    private lazy var smaller = item("Smaller Text", "-", .command, #selector(smallerText(_:)))
    private lazy var mark = item("Mark This Moment", "b", [], #selector(markMoment(_:)))
    private lazy var copyText = item("Copy Text", "c", [.command, .shift], #selector(copyTabText(_:)))
    private lazy var copyForAI = item("Copy for AI", "c", [.command, .option, .shift], #selector(copyForAI(_:)))
    private var observers: [NSObjectProtocol] = []
    private var placing = false

    /// The titles, in menu order (the self-test reads them).
    static let viewTitles = ["Bigger Text", "Smaller Text", "Mark This Moment"]
    static let editTitles = ["Copy Text", "Copy for AI"]

    func install(_ app: AppState) {
        self.app = app
        place()
        guard observers.isEmpty else { return }
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeSoon() }
            })
        }
        placeSoon()
    }

    /// The transcript in the main window, when it's in front and ready.
    private var transcript: Transcript? {
        guard let app, let id = app.screen.transcriptID, let t = app.store.transcript(id), t.status == .ready,
              NSApp.keyWindow == nil || NSApp.keyWindow === app.mainWindow else { return nil }
        return t
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let t = transcript else { return false }
        let nav = WindowNav.shared
        if menuItem === bigger { return nav.stillViewer == nil && nav.textSize < WindowNav.textSizes.max }
        if menuItem === smaller { return nav.stillViewer == nil && nav.textSize > WindowNav.textSizes.min }
        if menuItem === mark { return nav.stillViewer == nil && !TranscriptView.typing && t.audioFileName != nil }
        // ⇧⌘C in a text field is the field's own (Show Colors); the item steps aside while you type.
        if menuItem === copyText { return !TranscriptView.typing }
        return true
    }

    @objc private func biggerText(_ sender: Any?) { WindowNav.shared.textSize = WindowNav.textSizes.clamp(WindowNav.shared.textSize + 1) }
    @objc private func smallerText(_ sender: Any?) { WindowNav.shared.textSize = WindowNav.textSizes.clamp(WindowNav.shared.textSize - 1) }
    @objc private func markMoment(_ sender: Any?) { if let app, let t = transcript { WindowNav.shared.bookmark(t, app: app) } }
    @objc private func copyTabText(_ sender: Any?) { if let app, let t = transcript { ExportMenu.copy(t, WindowNav.shared.copyVersion, app: app) } }
    @objc private func copyForAI(_ sender: Any?) { if let app, let t = transcript { CopyForAI.copy(t, app: app) } }

    private func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    /// Menus change rarely (SwiftUI building the menu bar); the check runs once on the next turn after a burst.
    private func placeSoon() {
        guard !placing else { return }
        placing = true
        DispatchQueue.main.async { [weak self] in
            self?.placing = false
            self?.place()
        }
    }

    private func menu(_ title: String) -> NSMenu? { NSApp.mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu }

    private func place() {
        if let view = menu("View") {
            let items = [viewSeparator, bigger, smaller, mark]
            if !items.allSatisfy({ $0.menu === view }) {
                for i in items { i.menu?.removeItem(i) }
                // After Back and Forward (or Edit Home, before they're in).
                var at = (view.items.firstIndex { $0.title == "Forward" } ?? view.items.firstIndex { $0.title == "Edit Home" }).map { $0 + 1 } ?? view.items.count
                for i in items { view.insertItem(i, at: at); at += 1 }
            }
        }
        if let edit = menu("Edit") {
            let items = [copyText, copyForAI]
            if !items.allSatisfy({ $0.menu === edit }) {
                for i in items { i.menu?.removeItem(i) }
                var at = edit.items.firstIndex { $0.title == "Copy" }.map { $0 + 1 } ?? edit.items.count
                for i in items { edit.insertItem(i, at: at); at += 1 }
            }
        }
    }
}
