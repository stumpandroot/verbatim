import AppKit
import SwiftUI
import Carbon
import Carbon.HIToolbox

// Getting a dictation back when its paste failed or landed in the wrong place:
// - Recent dictations: ⌥⌘V (Settings › Dictation) opens a small paper panel with your last 10 dictations. A number
//   key, Return, or a click copies one; ⇧ with it (or the Paste button) pastes it where your cursor is.
// - The menu bar item lists the same dictations; a click copies one.
// - A dictation that didn't land (no text field, or the app never read the paste) stays in the Ribbon with Copy and
//   Paste again, and on the clipboard.
// - Settings › Dictation › Also copy each dictation to the clipboard leaves every pasted dictation on the clipboard.

// MARK: - Settings

/// The shortcut that opens Recent dictations. Registered with Carbon, so it works in every app (and with secure
/// input on) and the keystroke goes only to Verbatim.
enum RecallShortcut: String, CaseIterable, Identifiable {
    case optionCommandV, controlOptionV, off

    static let key = "dictation.recentShortcut"
    var id: String { rawValue }

    static var current: RecallShortcut {
        RecallShortcut(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .optionCommandV
    }

    var title: String {
        switch self {
        case .optionCommandV: return "⌥⌘V"
        case .controlOptionV: return "⌃⌥V"
        case .off: return "Off"
        }
    }

    /// Carbon key code and modifiers; nil when off.
    var binding: (key: Int, mods: Int)? {
        switch self {
        case .optionCommandV: return (kVK_ANSI_V, optionKey | cmdKey)
        case .controlOptionV: return (kVK_ANSI_V, controlKey | optionKey)
        case .off: return nil
        }
    }
}

/// Settings › Dictation › Also copy each dictation to the clipboard. Off by default.
enum AlwaysCopy {
    static let key = "dictation.alwaysCopy"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

// MARK: - The list

/// One dictation as Recent dictations shows it.
struct RecallItem: Identifiable, Equatable {
    let id: UUID
    let text: String
    let app: String
    let site: String?
    let date: Date

    /// "Chrome · github.com", "Mail", or empty.
    var source: String { [app, site ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// The pure logic behind Recent dictations, the menu bar list, and the didn't-paste notice (checked in UITest).
enum Recall {
    /// Rows shown at once (keys 1–9 and 0).
    static let cap = 10
    /// How far back search looks.
    static let pool = 200

    /// Dictations newest first: finished ones with words, at most `limit`.
    static func items(from transcripts: [Transcript], sites: [UUID: String], limit: Int = pool) -> [RecallItem] {
        let list: [RecallItem] = transcripts.compactMap { t in
            guard t.source == .dictation, t.status != .failed, t.deletedAt == nil else { return nil }
            let text = (t.flow?.pasted ?? t.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecallItem(id: t.id, text: text, app: t.flow?.app ?? "", site: sites[t.id], date: t.createdAt)
        }
        return Array(list.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// The first `cap` items, or the first `cap` that contain every word of `query` (in the text, app, or website).
    static func visible(_ items: [RecallItem], query: String, cap: Int = cap) -> [RecallItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }
        guard !words.isEmpty else { return Array(items.prefix(cap)) }
        return Array(items.filter { item in
            let hay = fold(item.text + " " + item.source)
            return words.allSatisfy { hay.contains($0) }
        }.prefix(cap))
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// The text on one line: line breaks and runs of spaces become single spaces.
    static func oneLine(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    /// One line of at most `n` characters, ending in "…" when cut.
    static func truncate(_ s: String, to n: Int = 60) -> String {
        let line = oneLine(s)
        guard n > 1, line.count > n else { return line }
        return String(line.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The first `lines` non-empty lines.
    static func preview(_ s: String, lines: Int = 2) -> String {
        s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .prefix(lines).joined(separator: "\n")
    }

    /// "9:41 AM" today, "Yesterday", or "Oct 12".
    static func when(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return Formats.style(date: .none, time: .short).string(from: d) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return Formats.pattern(cal.isDate(d, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy").string(from: d)
    }

    /// The key that picks row `index`: 1–9, then 0.
    static func keyLabel(_ index: Int) -> String? {
        switch index {
        case 0..<9: return "\(index + 1)"
        case 9: return "0"
        default: return nil
        }
    }

    /// The row a number key picks, from the row of number keys or the keypad (key codes, so any layout works).
    static func index(forKeyCode code: UInt16) -> Int? {
        let row: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]   // kVK_ANSI_1…9, 0
        let pad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]   // kVK_ANSI_Keypad1…9, 0
        return row.firstIndex(of: code) ?? pad.firstIndex(of: code)
    }

    enum KeyAction: Equatable { case close, move(Int), copySelected, pasteSelected, copy(Int), paste(Int) }

    /// What a key does in the panel. Numbers pick a row while the search field is empty (with ⌘, always); Shift
    /// pastes instead of copying. Anything else goes to the search field.
    static func keyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, queryEmpty: Bool) -> KeyAction? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        let shift = mods.contains(.shift)
        let rest = mods.subtracting(.shift)
        switch keyCode {
        case 53: return .close                                            // Esc
        case 126: return rest.isEmpty ? .move(-1) : nil                   // ↑
        case 125: return rest.isEmpty ? .move(1) : nil                    // ↓
        case 36, 76: return rest.isEmpty ? (shift ? .pasteSelected : .copySelected) : nil   // Return, Enter
        default: break
        }
        guard let i = index(forKeyCode: keyCode) else { return nil }
        if rest == [.command] || (rest.isEmpty && queryEmpty) { return shift ? .paste(i) : .copy(i) }
        return nil
    }

    /// Why a dictation didn't land, when the Ribbon should hold it with Copy and Paste again.
    enum Rescue: Equatable {
        /// No text field had focus (Finder, the desktop, a list), so it went to the clipboard.
        case noField
        /// ⌘V was pressed, but the app never read the clipboard.
        case notRead
    }

    /// Nil when the paste landed, for an edit by voice (its result has its own notice), and for failures with their
    /// own fix (Accessibility off, typing interrupted part way).
    static func rescue(for outcome: Paster.Outcome, command: Bool) -> Rescue? {
        guard !command else { return nil }
        switch outcome {
        case .copiedOnly: return .noField
        case .failed(.notRead): return .notRead
        default: return nil
        }
    }

    static func rescueTitle(_ r: Rescue, app: String, onClipboard: Bool) -> String {
        switch r {
        case .noField: return onClipboard ? "Copied, since there was no text field." : "There was no text field to paste into."
        case .notRead: return onClipboard ? "Copied, since \(app) didn't take the paste." : "\(app) didn't take the paste."
        }
    }
}

// MARK: - Shortcut

private let recallSignature: OSType = 0x5642_5243   // "VBRC"

/// Carbon calls this on the main thread. Other Verbatim hotkeys share the event target, so anything that isn't
/// ours passes through.
private func recallHotkeyHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard err == noErr, id.signature == recallSignature else { return OSStatus(eventNotHandledErr) }
    if GetEventKind(event) == UInt32(kEventHotKeyPressed) { MainActor.assumeIsolated { RecallHotkey.shared.fire() } }
    return noErr
}

/// Registers the Recent dictations shortcut. `unavailable` is true when macOS refused it (another app holds it).
@MainActor
final class RecallHotkey: ObservableObject {
    static let shared = RecallHotkey()
    @Published private(set) var unavailable = false
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers the shortcut from Settings, replacing the previous one.
    func apply() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        let choice = RecallShortcut.current
        guard let b = choice.binding else { unavailable = false; return }
        if handler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
            let status = InstallEventHandler(GetApplicationEventTarget(), recallHotkeyHandler, 1, &types, nil, &handler)
            guard status == noErr else {
                handler = nil
                unavailable = true
                Log.note("recent dictations: hotkey handler not installed (\(status))")
                return
            }
        }
        var r: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(b.key), UInt32(b.mods), EventHotKeyID(signature: recallSignature, id: 1),
                                         GetApplicationEventTarget(), 0, &r)
        if status == noErr, let r {
            ref = r
            unavailable = false
            Log.note("recent dictations: shortcut \(choice.title)")
        } else {
            unavailable = true
            Log.note("recent dictations: shortcut \(choice.title) not registered (\(status))")
        }
    }

    fileprivate func fire() { onPress?() }
}

// MARK: - Panel

@MainActor
final class RecallModel: ObservableObject {
    @Published var items: [RecallItem] = []
    @Published var query = ""
    @Published var selection = 0
    /// False until just after the panel is on screen, so it can fade (and settle) in.
    @Published var shown = false
    var visible: [RecallItem] { Recall.visible(items, query: query) }
}

/// Takes keys (for search, arrows, and numbers) without making Verbatim the active app, so the app you were in
/// keeps its text field and gets the paste.
final class RecallPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// Recent dictations: a paper panel near the top of the screen with the pointer.
@MainActor
final class RecallPanelController {
    static let shared = RecallPanelController()
    weak var dictation: DictationController?
    let model = RecallModel()
    private var panel: RecallPanel?
    private var monitors: [Any] = []
    var isOpen: Bool { panel != nil }

    static let size = CGSize(width: 480, height: 470)

    func toggle() { if isOpen { close() } else { open() } }

    func open() {
        guard panel == nil, let dictation else { return }
        model.items = dictation.recallItems()
        model.query = ""
        model.selection = 0
        model.shown = false
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        let size = Self.size
        let origin = CGPoint(x: f.midX - size.width / 2, y: max(f.minY, f.maxY - size.height - min(160, f.height * 0.14)))
        let p = RecallPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = false
        p.animationBehavior = .none
        p.setAccessibilityTitle("Recent dictations")
        let host = NSHostingView(rootView: RecallPanelView(model: model, controller: self).limitMotionRoot())
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []
        p.contentView = host
        panel = p
        p.makeKeyAndOrderFront(nil)
        p.onResign = { [weak self] in self?.close() }
        DispatchQueue.main.async { [weak self] in
            self?.model.shown = true
            p.invalidateShadow()
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, let p = self.panel, e.window === p else { return e }
            return self.handleKey(e) ? nil : e
        }) { monitors.append(l) }
        // A click in another app closes the panel.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(g) }
        Log.note("recent dictations: opened with \(model.items.count)")
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        guard let p = panel else { return }
        panel = nil
        p.onResign = nil
        p.orderOut(nil)
        // Released on the next turn: close() is often called from inside this panel's own SwiftUI action.
        DispatchQueue.main.async { p.close() }
    }

    /// Copies a dictation, closes, and says so where the panel was.
    func copy(_ item: RecallItem) {
        let at = panel.map { CGPoint(x: $0.frame.midX, y: $0.frame.maxY - 40) } ?? NSEvent.mouseLocation
        Paster.copy(item.text)
        close()
        RecallHUD.shared.show("Copied", near: at)
        Log.note("recent dictations: copied \(item.text.count) chars")
    }

    /// Closes, then pastes a dictation into the app you were in.
    func paste(_ item: RecallItem) {
        close()
        let text = item.text
        // A beat for the app you were in to get its keyboard focus back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.dictation?.pasteText(text) }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard let action = Recall.keyAction(keyCode: e.keyCode, modifiers: e.modifierFlags, queryEmpty: model.query.isEmpty) else { return false }
        let list = model.visible
        switch action {
        case .close:
            close()
        case .move(let d):
            guard !list.isEmpty else { return true }
            model.selection = min(max(0, model.selection + d), list.count - 1)
        case .copySelected:
            if list.indices.contains(model.selection) { copy(list[model.selection]) } else { NSSound.beep() }
        case .pasteSelected:
            if list.indices.contains(model.selection) { paste(list[model.selection]) } else { NSSound.beep() }
        case .copy(let i):
            if list.indices.contains(i) { copy(list[i]) } else { NSSound.beep() }
        case .paste(let i):
            if list.indices.contains(i) { paste(list[i]) } else { NSSound.beep() }
        }
        return true
    }
}

/// The panel: a search field, up to 10 rows (key, time, app or website, the first two lines), and the keys.
/// Opaque paper; nothing sits on glass. Arrives with a 0-bounce spring, or a fade with Limit animation.
struct RecallPanelView: View {
    @ObservedObject var model: RecallModel
    let controller: RecallPanelController
    @Environment(\.limitMotion) private var limitMotion
    @FocusState private var searchFocused: Bool

    var body: some View {
        let list = model.visible
        VStack(spacing: 0) {
            header
            Rectangle().fill(Ink.hairline).frame(height: 1)
            if list.isEmpty { empty } else { rows(list) }
            Rectangle().fill(Ink.hairline).frame(height: 1)
            footer
        }
        .frame(width: RecallPanelController.size.width, height: RecallPanelController.size.height)
        .background(Ink.paper)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.outlineStrong.opacity(0.6)))
        .opacity(model.shown ? 1 : 0)
        .offset(y: model.shown || limitMotion ? 0 : -8)
        .animation(limitMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.24, bounce: 0), value: model.shown)
        .onAppear { searchFocused = true }
        .onChange(of: model.query) { _, _ in model.selection = 0 }
        .uiTarget("recent-dictations")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.mute)
                .accessibilityHidden(true)
            TextField("Search your dictations", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Ink.ink)
                .focused($searchFocused)
                .accessibilityLabel("Search your dictations")
            Text("RECENT DICTATIONS").font(Ink.mono(10.5, weight: .medium)).tracking(1.1).foregroundStyle(Ink.mute)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 16).frame(height: 52)
    }

    private func rows(_ list: [RecallItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        RecallRow(item: item, index: i, selected: i == model.selection,
                                  onHover: { model.selection = i },
                                  onCopy: { controller.copy(item) },
                                  onPaste: { controller.paste(item) })
                            .id(item.id)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.selection) { _, s in
                if list.indices.contains(s) { proxy.scrollTo(list[s].id) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(model.items.isEmpty ? "No dictations yet" : "No dictations match")
                .font(Ink.serif(20)).foregroundStyle(Ink.ink)
            Text(model.items.isEmpty ? "Your dictations show up here, newest first." : "Search looks at your last \(Recall.pool) dictations, their apps, and websites.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.mute).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("1–0", model.query.isEmpty ? "copy" : "with ⌘ copy")
            hint("⇧", "pastes")
            hint("↩", "copies the selection")
            Spacer(minLength: 0)
            hint("esc", "closes")
        }
        .padding(.horizontal, 16).frame(height: 36)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(Ink.mono(10.5, weight: .medium)).foregroundStyle(Ink.dim)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Ink.card))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Ink.hairline))
            Text(label).font(.system(size: 11)).foregroundStyle(Ink.mute)
        }
        .lineLimit(1).fixedSize()
    }
}

/// One dictation: its key, time, app or website, and first two lines. A click copies it; Paste shows on the
/// selected row.
private struct RecallRow: View {
    let item: RecallItem
    let index: Int
    let selected: Bool
    let onHover: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Recall.keyLabel(index) ?? "")
                .font(Ink.mono(12, weight: .medium))
                .foregroundStyle(selected ? Ink.accentText : Ink.mute)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.card))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.hairline))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Recall.when(item.date)).font(Ink.mono(11)).foregroundStyle(Ink.mute)
                    if !item.source.isEmpty {
                        Text(item.source).font(.system(size: 11.5)).foregroundStyle(Ink.mute).lineLimit(1)
                    }
                }
                Text(Recall.preview(item.text))
                    .font(.system(size: 13.5)).foregroundStyle(Ink.ink)
                    .lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Paste", action: onPaste)
                .buttonStyle(RecallPasteButton())
                .opacity(selected ? 1 : 0)
                .allowsHitTesting(selected)
                .accessibilityHidden(!selected)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Ink.wash : Color.clear))
        .contentShape(Rectangle())
        .onHover { if $0 { onHover() } }
        .onTapGesture(perform: onCopy)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(Recall.when(item.date)), \(item.source). \(Recall.truncate(item.text, to: 200))")
        .accessibilityHint("Copies this dictation")
        .accessibilityAction(named: "Paste") { onPaste() }
    }
}

private struct RecallPasteButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Ink.onInteractive)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Ink.interactive, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - "Copied"

/// A short "Copied" capsule that ignores the pointer and fades away.
@MainActor
final class RecallHUD {
    static let shared = RecallHUD()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    private static let size = CGSize(width: 160, height: 44)

    func show(_ text: String, near point: CGPoint) {
        let p = panel ?? make()
        panel = p
        let host = NSHostingView(rootView: RecallHUDView(text: text))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.sizingOptions = []
        p.contentView = host
        var origin = CGPoint(x: point.x - Self.size.width / 2, y: point.y - Self.size.height / 2)
        if let f = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - Self.size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - Self.size.height - 4)
        }
        p.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hide?.cancel()
        let work = DispatchWorkItem { [weak p] in
            MainActor.assumeIsolated {
                guard let p else { return }
                NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 0 }
                // Out of the window list once faded, unless another "Copied" brought it back meanwhile.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if p.alphaValue < 0.05 { p.orderOut(nil) } }
            }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        return p
    }
}

private struct RecallHUDView: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Ink.readerFixed)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Ink.inkFixed))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Menu bar

/// The menu bar panel's Recent dictations: tap to show the last 10 (text, app, and time); click one to copy it.
struct RecallMenuSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var sites = SiteLog.shared
    @State private var expanded = false
    @State private var copied: UUID?

    var body: some View {
        let items = Recall.items(from: app.store.live, sites: sites.hosts, limit: Recall.cap)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        ArtIcon(art: .iconRecent, size: 16).foregroundStyle(Ink.iris).frame(width: 26)
                        Text("Recent dictations").font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        if RecallShortcut.current != .off {
                            Text(RecallShortcut.current.title).font(Ink.mono(11)).foregroundStyle(Ink.mute)
                        }
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.mute)
                    }
                    .padding(10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide recent dictations" : "Show recent dictations")
                if expanded {
                    Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 10)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            Button { copy(item) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Recall.truncate(item.text)).font(.system(size: 12.5)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(copied == item.id ? "Copied" : [item.source, Recall.when(item.date)].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 11)).foregroundStyle(copied == item.id ? Ink.sageText : Ink.mute).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Copies this dictation")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .background(Ink.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func copy(_ item: RecallItem) {
        Paster.copy(item.text)
        copied = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if copied == item.id { copied = nil } }
    }
}

// MARK: - Settings rows

/// Settings › Dictation: the Recent dictations shortcut.
struct RecallShortcutRow: View {
    @AppStorage(RecallShortcut.key) private var shortcut: String = RecallShortcut.optionCommandV.rawValue
    @ObservedObject private var hotkey = RecallHotkey.shared

    var body: some View {
        SettingsRow("dictate.recall",
                    detail: hotkey.unavailable && shortcut != RecallShortcut.off.rawValue ? "Another app already uses \(RecallShortcut.current.title). Pick another shortcut." : nil,
                    detailColor: hotkey.unavailable ? Ink.accentText : Ink.mute) {
            Picker("Recent dictations", selection: $shortcut) {
                ForEach(RecallShortcut.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .labelsHidden().fixedSize()
        }
        .onChange(of: shortcut) { _, _ in RecallHotkey.shared.apply() }
    }
}

/// Settings › Dictation: Also copy each dictation to the clipboard.
struct AlwaysCopyRow: View {
    @AppStorage(AlwaysCopy.key) private var on = false
    var body: some View { SettingsToggleRow("dictate.alwaysCopy", isOn: $on) }
}
