import AppKit
import ApplicationServices

/// Reads a call app's windows through Accessibility while a call records (MeetingSession), for CallWindowNames: who
/// the other side is and the meeting's own name. Accessibility is already allowed for pasting dictations; without it
/// this reads nothing and nothing changes.
///
/// Each window's title, and for FaceTime and Zoom (`CallWindowNames.readsWindowText`) the strings in the window:
/// static text, and each element's title and description. Text fields and web areas are skipped (what someone typed,
/// a shared page), as are browsers, Teams, Webex, and Slack, whose titles are enough and whose web views would turn on
/// their accessibility trees. At most `maxWindows` windows, `maxElements` elements, `maxDepth` levels, and `budget`
/// seconds, with a 0.1 s messaging limit per element, so a busy app can't stall it. Runs off the main thread. Only the
/// name and the title CallWindowNames picks out are kept; the rest is dropped, and nothing leaves the Mac.
enum CallWindowReader {
    static let maxWindows = 6
    static let maxDepth = 12
    static let maxElements = 400
    static let maxTexts = 200
    static let budget: TimeInterval = 0.4

    /// What the windows of the running app with `bundleID` show, with a name resolved through Contacts when access is
    /// already allowed (CallWindowNames.preferContact; a phone number or email to its one contact). Nil without
    /// Accessibility or when the app isn't running.
    static func read(bundleID: String, selfNames: [String]) -> CallWindowNames.Reading? {
        guard let windows = windows(bundleID: bundleID) else { return nil }
        var r = CallWindowNames.read(bundleID: bundleID, windows: windows, selfNames: selfNames)
        if ContactNames.isAllowed {
            r.names = r.names.map { CallWindowNames.preferContact($0, matches: ContactNames.fullNames(matching: $0)) }
            if r.names.isEmpty, let h = r.handles.first, let n = ContactNames.name(forHandle: h), !MeetingNames.isSelf(n, selfNames: selfNames) {
                r.names = [n]
            }
        }
        // A number or an email is only ever looked up, never kept.
        r.handles = []
        return r
    }

    /// The app's windows: each title, and the strings inside when the app's text is read.
    static func windows(bundleID: String) -> [CallWindowNames.Window]? {
        guard AXIsProcessTrusted(),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }) else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let list: [AXUIElement] = attr(app, kAXWindowsAttribute as String) ?? []
        let walk = CallWindowNames.readsWindowText(bundleID)
        let deadline = Date().addingTimeInterval(budget)
        var visited = 0
        var out: [CallWindowNames.Window] = []
        for w in list.prefix(maxWindows) {
            AXUIElementSetMessagingTimeout(w, 0.1)
            let title: String = attr(w, kAXTitleAttribute as String) ?? ""
            var texts: [String] = []
            if walk { collect(w, into: &texts, visited: &visited, deadline: deadline) }
            out.append(CallWindowNames.Window(title: title, texts: texts))
        }
        return out
    }

    /// The strings under `root`, breadth first, within the limits.
    private static func collect(_ root: AXUIElement, into texts: inout [String], visited: inout Int, deadline: Date) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        let skipped: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, "AXWebArea", "AXSearchField"]
        func add(_ s: String?) {
            guard let s, texts.count < maxTexts else { return }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t.count <= 200, !texts.contains(t) { texts.append(t) }
        }
        while head < queue.count, visited < maxElements, texts.count < maxTexts, Date() < deadline {
            let (el, depth) = queue[head]
            head += 1
            visited += 1
            AXUIElementSetMessagingTimeout(el, 0.1)
            let role: String = attr(el, kAXRoleAttribute as String) ?? ""
            if skipped.contains(role) { continue }
            if role == kAXStaticTextRole as String { add(attr(el, kAXValueAttribute as String)) }
            if depth > 0 { add(attr(el, kAXTitleAttribute as String)) }
            add(attr(el, kAXDescriptionAttribute as String))
            guard depth < maxDepth else { continue }
            let children: [AXUIElement] = attr(el, kAXChildrenAttribute as String) ?? []
            for c in children.prefix(60) { queue.append((c, depth + 1)) }
        }
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self { return (v as! AXUIElement) as? T }
        return v as? T
    }
}
