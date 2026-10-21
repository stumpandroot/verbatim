import AppKit
import ApplicationServices

/// What Verbatim knows about where you're dictating: the app, its kind, and the text around your cursor.
/// Read through Accessibility (already allowed for Dictate), with a 100 ms limit so a busy app can't stall
/// dictation. Password fields are never read, and nothing here leaves the Mac.
struct AppContext {
    var appName: String
    var bundleID: String?
    var windowTitle: String = ""
    var category: AppCategory = .other
    /// A text field or text area has focus (so ⌘V will land somewhere).
    var hasFocusedField = false
    var secureField = false
    var before = ""
    var selection = ""
    /// True when the selection was longer than Verbatim reads (6,000 characters) and `selection` holds only its start.
    var selectionClipped = false
    var after = ""
    /// The focused element and where the cursor was, for auto-learn's look at your edits.
    var element: AXUIElement?
    var cursor: Int?

    /// Reads the frontmost app. With `readText` off, only the app and its kind are known.
    static func capture(readText: Bool) -> AppContext {
        let front = NSWorkspace.shared.frontmostApplication
        var c = AppContext(appName: front?.localizedName ?? "the front app", bundleID: front?.bundleIdentifier)
        guard let pid = front?.processIdentifier, AXIsProcessTrusted() else {
            c.category = category(bundleID: c.bundleID, title: "")
            c.hasFocusedField = true   // Unknown: try the paste anyway.
            return c
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        if let win: AXUIElement = attr(app, kAXFocusedWindowAttribute), let title: String = attr(win, kAXTitleAttribute) { c.windowTitle = title }
        c.category = category(bundleID: c.bundleID, title: c.windowTitle)

        var focused: AXUIElement? = attr(app, kAXFocusedUIElementAttribute)
        if focused == nil {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.1)
            focused = attr(system, kAXFocusedUIElementAttribute)
        }
        guard let el = focused else {
            // Some apps (Electron, games) don't expose a focused element even with a field focused.
            c.hasFocusedField = !noFieldApps.contains(c.bundleID ?? "")
            return c
        }
        AXUIElementSetMessagingTimeout(el, 0.1)
        let subrole: String = attr(el, kAXSubroleAttribute) ?? ""
        c.secureField = subrole == (kAXSecureTextFieldSubrole as String)
        c.hasFocusedField = isTextInput(el, strict: noFieldApps.contains(c.bundleID ?? ""))
        c.element = el
        guard readText, !c.secureField else { return c }
        let value: String = attr(el, kAXValueAttribute) ?? ""
        let ns = value as NSString
        if let rangeValue: AXValue = attr(el, kAXSelectedTextRangeAttribute) {
            var r = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &r), r.location >= 0, r.location + r.length <= ns.length {
                c.cursor = r.location
                c.before = String(ns.substring(to: r.location).suffix(400))
                c.selection = ns.substring(with: NSRange(location: r.location, length: r.length))
                c.after = String(ns.substring(from: r.location + r.length).prefix(200))
            }
        }
        if c.selection.isEmpty, let sel: String = attr(el, kAXSelectedTextAttribute) { c.selection = sel }
        // Very long documents: the window around the cursor is what matters, and anything long is clipped.
        if c.selection.count > 6000 { c.selection = String(c.selection.prefix(6000)); c.selectionClipped = true }
        return c
    }

    /// Whether the app with `pid` has a text field focused right now, checked just before ⌘V (you may have
    /// clicked elsewhere since the dictation started). Nil when it can't be told: Accessibility is off, the app
    /// isn't in front, or it exposes no focused element (Electron, games), so the caller keeps its earlier answer.
    static func focusedEditable(pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let el: AXUIElement = attr(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        return isTextInput(el, strict: noFieldApps.contains(id))
    }

    /// Text fields, text areas, and anything editable. Web views report AXWebArea or AXGroup for rich editors,
    /// and some editors sit in a scroll area, so those count too. `strict` (Finder and the Dock, whose file lists
    /// and desktop report groups and scroll areas) counts only real text fields, such as a file name being renamed.
    private static func isTextInput(_ el: AXUIElement, strict: Bool = false) -> Bool {
        let role: String = attr(el, kAXRoleAttribute) ?? ""
        let editable: Bool = attr(el, "AXEditable") ?? false
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"]
        if textRoles.contains(role) || editable { return true }
        if strict { return false }
        if role == "AXWebArea" { return true }
        return role == "AXGroup" || role == (kAXScrollAreaRole as String)
    }

    /// Re-reads the focused element's whole value (auto-learn compares it with what was pasted).
    static func value(of el: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(el, 0.1)
        return attr(el, kAXValueAttribute)
    }

    // MARK: App kinds

    private static let noFieldApps: Set<String> = ["com.apple.finder", "com.apple.dock"]

    /// The app's kind from its bundle ID and window title (`AppCategory.classify`). Dictation refines it with the
    /// front tab's host once `SiteCapture` has it.
    static func category(bundleID: String?, title: String, host: String? = nil) -> AppCategory {
        AppCategory.classify(bundleID: bundleID, title: title, host: host)
    }

    /// True when the field already has writing before the cursor, so a dictation goes into the middle of a message.
    var insertsMidText: Bool {
        before.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: AX helpers

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self { return (v as! AXUIElement) as? T }
        if T.self == AXValue.self { return (v as! AXValue) as? T }
        return v as? T
    }
}
