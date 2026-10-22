import AppKit
import Carbon

/// Settings › Dictation › After pasting: press nothing (the default), Return, or ⌘Return once a dictation lands, so a
/// message sends itself. Never into a password field, never after a dictation that didn't paste, and, unless you
/// choose every app, only in chat and work apps (Messages, Slack, Teams…), where Return means Send.
enum AutoSend {
    enum Key: String, CaseIterable, Identifiable {
        case none, returnKey = "return", commandReturn = "commandReturn"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Nothing"
            case .returnKey: return "Return"
            case .commandReturn: return "⌘Return"
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case chats, everywhere
        var id: String { rawValue }
        var title: String { self == .chats ? "Chat and work apps" : "Every app" }
    }

    static let keyKey = "flow.autoSend"
    static let scopeKey = "flow.autoSendScope"

    static var key: Key { Key(rawValue: UserDefaults.standard.string(forKey: keyKey) ?? "") ?? .none }
    static var scope: Scope { Scope(rawValue: UserDefaults.standard.string(forKey: scopeKey) ?? "") ?? .chats }

    /// Whether to press the key after a dictation pasted into an app of this kind.
    static func applies(to category: AppCategory?, key: Key = key, scope: Scope = scope) -> Bool {
        guard key != .none else { return false }
        if scope == .everywhere { return true }
        return category == .personal || category == .work
    }

    /// Presses the chosen key after a paste landed, unless a password field has focus now or had it when dictation
    /// started. Waits a moment so the app has inserted the text first.
    @MainActor
    static func afterPaste(target: NSRunningApplication?, category: AppCategory?, secureAtStart: Bool) async {
        let k = key
        guard applies(to: category, key: k) else { return }
        guard !secureAtStart else { Log.note("auto-send: skipped, password field"); return }
        try? await Task.sleep(nanoseconds: 120_000_000)
        if let pid = target?.processIdentifier, AppContext.focusedSecure(pid: pid) == true {
            Log.note("auto-send: skipped, password field"); return
        }
        // Only into the app the dictation went to, still in front.
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            Log.note("auto-send: skipped, the app isn't in front"); return
        }
        press(k)
        Log.note("auto-send: pressed \(k.rawValue)")
    }

    private static func press(_ k: Key) {
        let src = CGEventSource(stateID: .privateState)
        let ret = CGKeyCode(kVK_Return)
        let flags: CGEventFlags = k == .commandReturn ? .maskCommand : []
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: ret, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}
