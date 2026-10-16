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
        let role: String = attr(el, kAXRoleAttribute) ?? ""
        let subrole: String = attr(el, kAXSubroleAttribute) ?? ""
        let editable: Bool = attr(el, "AXEditable") ?? false
        c.secureField = subrole == (kAXSecureTextFieldSubrole as String)
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"]
        // Web views report AXWebArea or AXGroup for rich editors; treat anything editable as a field.
        c.hasFocusedField = textRoles.contains(role) || editable || role == "AXWebArea"
        if !c.hasFocusedField, role == "AXGroup" || role == (kAXScrollAreaRole as String) { c.hasFocusedField = true }
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
        if c.selection.count > 6000 { c.selection = String(c.selection.prefix(6000)) }
        return c
    }

    /// Re-reads the focused element's whole value (auto-learn compares it with what was pasted).
    static func value(of el: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(el, 0.1)
        return attr(el, kAXValueAttribute)
    }

    // MARK: App kinds

    private static let noFieldApps: Set<String> = ["com.apple.finder", "com.apple.dock"]

    static func category(bundleID: String?, title: String) -> AppCategory {
        let id = (bundleID ?? "").lowercased()
        let t = title.lowercased()
        let email = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.readdle.spark", "com.superhuman", "com.mimestream", "it.bloop.airmail", "com.freron.mailmate", "com.postbox", "com.canarymail", "com.hey"]
        let work = ["com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.linear", "com.atlassian", "com.basecamp", "us.zoom.xos", "com.figma"]
        let personal = ["com.apple.mobilesms", "com.apple.ichat", "net.whatsapp", "desktop.whatsapp", "ru.keepcoder.telegram", "org.telegram", "org.whispersystems.signal", "com.hnc.discord", "com.facebook.archon", "com.facebook.messenger"]
        let code = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.apple.dt.xcode", "com.jetbrains", "dev.zed", "com.sublimetext", "com.panic.nova", "com.barebones.bbedit"]
        if email.contains(where: { id.hasPrefix($0) }) { return .email }
        if code.contains(where: { id.hasPrefix($0) }) { return .code }
        if work.contains(where: { id.hasPrefix($0) }) { return .work }
        if personal.contains(where: { id.hasPrefix($0) }) { return .personal }
        // Browsers and web apps: decide from the tab's title.
        let browsers = ["com.apple.safari", "com.google.chrome", "company.thebrowser", "com.brave", "org.mozilla.firefox", "com.microsoft.edgemac", "com.operasoftware", "com.vivaldi", "com.kagi.kagimacos", "ai.perplexity.comet"]
        if browsers.contains(where: { id.hasPrefix($0) }) || id.isEmpty {
            if ["gmail", "outlook", "inbox", "mail -", "proton mail", "fastmail", "superhuman"].contains(where: { t.contains($0) }) { return .email }
            if ["slack", "teams", "linear", "discord", "jira", "asana", "notion"].contains(where: { t.contains($0) }) { return .work }
            if ["whatsapp", "messenger", "telegram", "instagram", "messages"].contains(where: { t.contains($0) }) { return .personal }
            if ["github", "gitlab", "codespaces", "replit", "colab"].contains(where: { t.contains($0) }) { return .code }
        }
        return .other
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
