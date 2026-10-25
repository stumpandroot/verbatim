import SwiftUI
import AppKit

// brand: web style
//
// Settings for how dictation shows and starts: Floating button and Ribbon › Where dictation shows (the Ribbon, the
// notch, or the floating button, with each one's own rows) and the floating button's look, and Dictation and
// keyboard › Hotkey (a list that shows its keys, a shortcut you record, or a mouse side button) and How it starts. Website style (DESIGN.md §11): cards with
// an ink outline when chosen, keycaps for keys, line mini pills for actions; switches, menus, and segmented
// controls stay native.

// MARK: - Floating button and Ribbon › Where dictation shows

struct DictationSurfaceRows: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var flow = FlowSettings.shared
    @AppStorage(DictationSurface.key) private var surfaceRaw = DictationSurface.ribbon.rawValue
    @AppStorage(NotchFallback.key) private var fallbackRaw = NotchFallback.pill.rawValue
    @AppStorage(NotchClick.key) private var notchClick = true
    @AppStorage(LiveWordsSetting.key) private var liveWords = true
    @AppStorage(RibbonStyle.key) private var ribbonStyle: String = RibbonStyle.paper.rawValue
    @AppStorage(RibbonMark.key) private var ribbonMark: String = RibbonMark.bars.rawValue

    private var surface: DictationSurface { DictationSurface(rawValue: surfaceRaw) ?? .ribbon }

    var body: some View {
        SettingsRow("dictate.surface", stacked: true) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(DictationSurface.allCases) { s in
                    SurfaceCard(surface: s, selected: surface == s) { surfaceRaw = s.rawValue }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
        .onChange(of: surfaceRaw) { _, _ in app.dictation.bar?.refresh() }
        .onChange(of: fallbackRaw) { _, _ in app.dictation.bar?.refresh() }
        .onChange(of: notchClick) { _, _ in app.dictation.bar?.refresh() }
        .onChange(of: liveWords) { _, on in if on { app.dictation.prepareLiveWords(askPermission: true) } }
        switch surface {
        case .notch:
            SettingsRow("dictate.noNotch") {
                Picker("On displays without a notch", selection: $fallbackRaw) {
                    ForEach(NotchFallback.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
            }
            SettingsToggleRow("dictate.notchWords", isOn: $liveWords)
            SettingsToggleRow("dictate.notchClick", isOn: $notchClick)
            // Where the notch style falls back to the Ribbon, the Ribbon's look still applies there.
            if fallbackRaw == NotchFallback.ribbon.rawValue { ribbonLook }
        case .ribbon:
            SettingsToggleRow("ribbon.show", isOn: $flow.showBar)
            ribbonLook
            SettingsToggleRow("ribbon.liveWords", isOn: $liveWords)
        case .button:
            // The floating button's own rows follow on this pane (FloatingButtonGroups).
            EmptyView()
        }
    }

    @ViewBuilder private var ribbonLook: some View {
        SettingsRow("ribbon.style") {
            Picker("Style", selection: $ribbonStyle) {
                Text("Paper").tag(RibbonStyle.paper.rawValue)
                Text("Ink").tag(RibbonStyle.ink.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        SettingsRow("ribbon.mark") {
            Picker("Voice mark", selection: $ribbonMark) {
                Text("Three bars").tag(RibbonMark.bars.rawValue)
                Text("Rings").tag(RibbonMark.rings.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}

/// One choice in Show dictation in: a small picture of the style on a neutral desktop, its name, and a line.
private struct SurfaceCard: View {
    var surface: DictationSurface
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SurfaceThumb(surface: surface)
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(alignment: .topTrailing) { ChoiceDot(on: selected).padding(6) }
            Text(surface.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
                .padding(.top, 9).padding(.horizontal, 4)
            Text(surface.detail).font(.system(size: 12)).foregroundStyle(Ink.mute).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2).padding(.horizontal, 4)
        }
        .padding(8).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(selected ? Ink.card : (hover ? Ink.cardHover : Ink.paper), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay { if !selected { RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1) } }
        .inkEdge(outline: selected, shadow: selected ? CGSize(width: 3, height: 4) : .zero, radius: Radius.tile)
        .onHover { hover = $0 }
        .tapArea(action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
        .uiTarget("settings-surface-\(surface.rawValue)")
    }
}

/// The radio dot on a choice card.
private struct ChoiceDot: View {
    var on: Bool
    var size: CGFloat = 16
    var body: some View {
        ZStack {
            Circle().fill(Ink.card)
            Circle().strokeBorder(on ? Ink.ink : Ink.mute, lineWidth: on ? size * 0.31 : 1.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A neutral desktop (menu bar, hills) with the style drawn small on it.
private struct SurfaceThumb: View {
    var surface: DictationSurface
    var body: some View {
        ZStack {
            Ink.stripeA
            DesktopHills().fill(Ink.stripeB).padding(.top, 30)
            VStack(spacing: 0) { Ink.raised.frame(height: 9); Spacer(minLength: 0) }
            switch surface {
            case .ribbon:
                VStack {
                    Spacer()
                    HStack(spacing: 2) { VoiceBars(levels: [0.6, 0.4, 0.9], height: 10, barWidth: 3, gap: 2) }
                        .padding(.horizontal, 9).frame(height: 18)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 7, style: .continuous).fill(Ink.paperFixed))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 7, style: .continuous).strokeBorder(Ink.inkFixed.opacity(0.18), lineWidth: 0.75))
                }
            case .notch:
                VStack {
                    HStack {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Ink.butterFixed).frame(width: 8, height: 8)
                        Spacer()
                        VoiceBars(levels: VoiceBars.still(5), height: 8, barWidth: 1.5, gap: 1.5)
                    }
                    .padding(.horizontal, 7)
                    .frame(width: 92, height: 14)
                    .background(NotchShape(radius: 6, flare: 3).fill(Ink.notchBlack))
                    Spacer()
                }
            case .button:
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        BarsMark(color: Ink.paperFixed).frame(width: 10, height: 11)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Ink.inkFixed))
                            .background(Circle().fill(Ink.inkFixed).offset(x: 2, y: 2))
                    }
                    .padding(.trailing, 16).padding(.bottom, 14)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Three soft hills for the thumbnails' desktop.
private struct DesktopHills: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.35))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.2),
                   control1: CGPoint(x: r.minX + r.width * 0.3, y: r.minY), control2: CGPoint(x: r.minX + r.width * 0.6, y: r.minY + r.height * 0.45))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Dictation › Hotkey

/// A key as a raised keycap (mono 12.5 in an ink outline with a 2 pt ink floor), as on the hotkey picker.
struct KeyChip: View {
    var text: String
    var ghost = false
    var big = false
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(Ink.mono(big ? 15 : 12.5))
            if text == "fn" { Image(systemName: "globe").font(.system(size: big ? 14 : 12)) }
        }
        .foregroundStyle(ghost ? Ink.mute : Ink.ink)
        .padding(.horizontal, 8)
        .frame(minWidth: big ? 38 : 30, minHeight: big ? 34 : 28)
        .background {
            if ghost {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.ink).offset(y: 2)
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(Ink.card)
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1)
                }
            }
        }
        .fixedSize()
        .accessibilityLabel(Keycap.spoken(text))
    }
}

/// Settings › Dictation › Hotkey: a short list that shows each choice's keys. Fn or Globe says when macOS needs a
/// change first; a shortcut you choose is recorded here (and checked against shortcuts Verbose knows are taken); a
/// mouse button is picked by pressing it.
struct HotkeyPickerRow: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject private var flow = FlowSettings.shared
    @State private var recording = false
    @State private var held: KeyMods = []
    @State private var needsModifier = false
    @State private var candidate: KeyCombo?
    @State private var choosingMouse = false
    @State private var monitors: [Any] = []

    var body: some View {
        SettingsRow("dictate.hotkey", stacked: true) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    option(.fnGlobe, title: "Fn or Globe key",
                           note: fnNeedsChange ? "Set System Settings › Keyboard › Press 🌐 key to: Do nothing first." : nil, warn: true) {
                        KeyChip(text: "fn")
                    }
                    option(.rightCommand, title: "Right Command") { KeyChip(text: "right ⌘") }
                    option(.rightOption, title: "Right Option", note: "The default. Left ⌥ still types special characters.") { KeyChip(text: "right ⌥") }
                    option(.custom, title: "A shortcut you choose", note: customNote, warn: needsModifier) { customControl }
                    option(.mouse, title: "A mouse button", note: "A side button on a mouse with more than three.", last: true) { mouseControl }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1))
                .frame(maxWidth: 620)
                if recording {
                    HStack(spacing: 5) {
                        Text("Press")
                        KeyChip(text: "esc")
                        Text("to stop recording without changing anything.")
                    }
                    .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                }
                if let c = candidate { RecordedCard(combo: c, check: ShortcutCheck.check(c, also: recallTaken), mode: flow.mode,
                                                    again: startRecording, use: { commit(c) }, cancel: { candidate = nil }) }
                if choosingMouse { MouseWaitCard(cancel: stopMouse) }
            }
        }
        .onDisappear { stopRecording(); stopMouse() }
    }

    // MARK: Rows

    private func option<Trailing: View>(_ choice: DictationController.Hotkey, title: String, note: String? = nil, warn: Bool = false,
                                        last: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        let on = dictation.hotkey == choice
        return HStack(spacing: 12) {
            // The text side picks the choice; the controls on the right take their own clicks.
            HStack(spacing: 12) {
                ChoiceDot(on: on, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
                    if let note {
                        Text(note).font(.system(size: 12)).foregroundStyle(warn ? Ink.accentText : Ink.mute)
                            .lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .tapArea { select(choice) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(choice) }
            .uiTarget("hotkey-\(choice.rawValue)")
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 52)
        .background(on ? Ink.butterTint : Color.clear)
        .overlay(alignment: .bottom) { if !last { RowRule() } }
    }

    @ViewBuilder private var customControl: some View {
        if recording {
            HStack(spacing: 6) {
                Circle().fill(Ink.recordFill).frame(width: 8, height: 8)
                ForEach(held.symbols, id: \.self) { KeyChip(text: $0) }
                Rectangle().fill(Ink.ink).frame(width: 1.5, height: 18)
                Text("Type a key").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 168, minHeight: 38, alignment: .leading)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5))
            .background(RoundedRectangle(cornerRadius: Radius.button + 3, style: .continuous).fill(Ink.butter.opacity(0.7)).padding(-4))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording a shortcut. Press the keys you want, or Esc to stop.")
        } else if let c = HotkeyStore.custom() {
            HStack(spacing: 6) {
                ForEach(c.keycaps, id: \.self) { KeyChip(text: $0) }
                Button("Change") { startRecording() }.buttonStyle(.settingsPill)
            }
        } else {
            Button("Record") { startRecording() }.buttonStyle(.settingsPill)
        }
    }

    @ViewBuilder private var mouseControl: some View {
        HStack(spacing: 8) {
            if let n = HotkeyStore.mouseButton() { KeyChip(text: MouseButtons.title(n)) } else { KeyChip(text: "Not set", ghost: true) }
            Button(HotkeyStore.mouseButton() == nil ? "Choose" : "Change") { startMouse() }.buttonStyle(.settingsPill)
        }
    }

    private var customNote: String {
        if needsModifier { return "Add ⌃, ⌥, or ⌘, or use a function key on its own." }
        if let c = HotkeyStore.custom(), dictation.hotkey == .custom { return "Press the keys you want, such as ⌃⌥D. Now \(c.title)." }
        return "Press the keys you want, such as ⌃⌥D."
    }

    /// macOS uses the Globe key for emoji, input sources, or its own dictation unless it's set to do nothing
    /// (`AppleFnUsageType` 0). Unknown counts as needing the change.
    private var fnNeedsChange: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) != 0
    }

    /// Recent dictations' shortcut, which is a setting, so it's checked as it's set now.
    private var recallTaken: [ShortcutCheck.Known] {
        let mods: KeyMods
        switch RecallShortcut.current {
        case .optionCommandV: mods = [.option, .command]
        case .controlOptionV: mods = [.control, .option]
        case .off: return []
        }
        return [ShortcutCheck.Known(combo: KeyCombo(keyCode: 9, mods: mods), owner: "Verbose", does: "opens Recent dictations")]
    }

    // MARK: Choosing

    private func select(_ choice: DictationController.Hotkey) {
        switch choice {
        case .custom:
            if HotkeyStore.custom() != nil && !recording { stopMouse(); dictation.hotkey = .custom } else if !recording { startRecording() }
        case .mouse:
            if HotkeyStore.mouseButton() != nil { stopRecording(); dictation.hotkey = .mouse } else { startMouse() }
        default:
            stopRecording(); stopMouse(); candidate = nil
            dictation.hotkey = choice
        }
    }

    /// Records the next key pressed with its modifiers. Esc alone stops without changing anything; a key without
    /// ⌃, ⌥, or ⌘ (other than a function key) asks for one. The hotkey and Verbose's shortcuts are off meanwhile.
    private func startRecording() {
        stopMouse()
        stopMonitors()
        candidate = nil
        held = []
        needsModifier = false
        recording = true
        dictation.hotkeySuspended = true
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { e in
            let mods = DictationController.keyMods(e.modifierFlags)
            if e.type == .flagsChanged { held = mods; return e }
            if e.keyCode == KeyNames.escape && mods.isEmpty { stopRecording(); return nil }
            if e.isARepeat { return nil }
            let combo = KeyCombo(keyCode: e.keyCode, mods: mods)
            if !combo.mods.hasCommandKey && KeyNames.functionKeys[combo.keyCode] == nil { needsModifier = true; return nil }
            needsModifier = false
            stopRecording()
            candidate = combo
            return nil
        }) { monitors.append(m) }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        held = []
        stopMonitors()
        dictation.hotkeySuspended = false
    }

    private func commit(_ c: KeyCombo) {
        UserDefaults.standard.set(c.stored, forKey: HotkeyStore.customKey)
        candidate = nil
        if dictation.hotkey == .custom { dictation.hotkeyChanged() } else { dictation.hotkey = .custom }
    }

    /// Waits for button 4, 5, or higher, in this window or anywhere (the global monitor needs Accessibility).
    private func startMouse() {
        stopRecording()
        stopMonitors()
        candidate = nil
        choosingMouse = true
        dictation.hotkeySuspended = true
        let picked: (Int) -> Void = { n in
            guard MouseButtons.isSideButton(n), choosingMouse else { return }
            UserDefaults.standard.set(n, forKey: HotkeyStore.mouseKey)
            stopMouse()
            if dictation.hotkey == .mouse { dictation.hotkeyChanged() } else { dictation.hotkey = .mouse }
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown], handler: { e in
            guard MouseButtons.isSideButton(e.buttonNumber) else { return e }
            picked(e.buttonNumber)
            return nil
        }) { monitors.append(m) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown], handler: { e in
            DispatchQueue.main.async { picked(e.buttonNumber) }
        }) { monitors.append(g) }
    }

    private func stopMouse() {
        guard choosingMouse else { return }
        choosingMouse = false
        stopMonitors()
        dictation.hotkeySuspended = false
    }

    private func stopMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }
}

/// After recording: the shortcut as big keycaps, with Use, or why it can't be used.
private struct RecordedCard: View {
    var combo: KeyCombo
    var check: ShortcutCheck.Result
    var mode: FlowMode
    var again: () -> Void
    var use: () -> Void
    var cancel: () -> Void

    private var taken: (owner: String, sentence: String)? {
        if case .taken(let o, let s) = check { return (o, s) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: taken == nil ? "Recorded" : "Already taken")
            Group {
                if let t = taken { WebText.serif("That one belongs", italic: "to \(t.owner)", size: 22) }
                else { WebText.serif("Your shortcut is", italic: combo.title, size: 22) }
            }
            .foregroundStyle(Ink.ink).padding(.top, 4)
            HStack(spacing: 6) { ForEach(combo.keycaps, id: \.self) { KeyChip(text: $0, big: true) } }
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(taken == nil ? Ink.ink : Ink.danger, lineWidth: 1.5))
                .padding(.top, 14)
            if let t = taken {
                HStack(alignment: .top, spacing: 6) {
                    BrandGlyph(art: .webAttention, color: Ink.danger, minLineWidth: 1.3).frame(width: 16, height: 16)
                    Text("\(t.sentence) Choose another shortcut.").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.danger)
                }
                .padding(.top, 10)
            } else {
                Text("\(mode == .toggle ? "Press it to start; press it again to paste." : "Hold it to talk; let go to paste.") It works in every app except while a password field is focused. If nothing happens, another app may have it; choose another.")
                    .font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                Spacer()
                if taken != nil {
                    Button("Cancel", action: cancel).buttonStyle(.settingsPill)
                    Button("Use \(combo.title)", action: use).buttonStyle(.settingsPrimaryPill).disabled(true)
                } else {
                    Button("Record again", action: again).buttonStyle(.settingsPill)
                    Button("Use \(combo.title)", action: use).buttonStyle(.settingsPrimaryPill)
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Ink.paper, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1))
    }
}

/// Waiting for a mouse side button: a drawn mouse with its side button in butter.
private struct MouseWaitCard: View {
    var cancel: () -> Void

    private static let box = CGRect(x: 0, y: 0, width: 74, height: 110)
    private static let outline = "M37 4 C 58 4 68 20 68 44 V 72 C 68 94 56 106 37 106 C 18 106 6 94 6 72 V 44 C 6 20 16 4 37 4 Z"
    private static let shell = BrandArt(box: box, fills: [.path(outline)])
    private static let side = BrandArt(box: box, fills: [.rect(2, 50, 8, 14, 3)])
    private static let lines = BrandArt(box: box, strokes: [.path(outline), .path("M37 4 V 40 M6 40 H68"), .rect(33, 14, 8, 14, 4), .rect(2, 50, 8, 14, 3), .rect(2, 68, 8, 12, 3)], strokeWidth: 1.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Mouse button")
            WebText.serif("Press the button", italic: "you want", size: 22).foregroundStyle(Ink.ink).padding(.top, 4)
            ZStack {
                BrandGlyph(art: Self.shell, color: Ink.card)
                BrandGlyph(art: Self.side, color: Ink.butter)
                BrandGlyph(art: Self.lines, color: Ink.ink)
            }
            .frame(width: 74, height: 110)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            Text("Waiting for a click on button 4 or 5. Left, right, and middle clicks don't count.")
                .font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.top, 10)
            HStack { Spacer(); Button("Cancel", action: cancel).buttonStyle(.settingsPill) }.padding(.top, 14)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Ink.paper, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1))
    }
}

/// Settings › Dictation › How it starts: hold to talk, press to start and stop, or either.
struct HowItStartsRow: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject private var flow = FlowSettings.shared

    var body: some View {
        SettingsRow("dictate.mode", detail: flow.mode.note(thing: dictation.hotkey == .mouse ? "button" : "key")
                    + " Press Esc to cancel. Hold Shift as you start to edit selected text by voice.", stacked: true) {
            Picker("How it starts", selection: $flow.mode) {
                ForEach(FlowMode.pickerOrder) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}

// MARK: - Floating button

struct FloatingButtonSettingsPane: View {
    @EnvironmentObject var app: AppState
    @AppStorage(LiveWordsSetting.key) private var liveWords = true
    @AppStorage(FloatingLook.key) private var lookRaw = FloatingLook.disc.rawValue
    @AppStorage(FloatingSize.key) private var sizeRaw = FloatingSize.medium.rawValue
    @AppStorage(FloatingButtonKeys.mark) private var mark = RibbonMark.bars.rawValue
    @AppStorage(FloatingButtonKeys.snap) private var snap = false
    @AppStorage(DictationSurface.key) private var surfaceRaw = DictationSurface.ribbon.rawValue

    var body: some View {
        SettingsPane(tab: .floatingButton) {
            SettingsGroup(title: "Where dictation shows") {
                DictationSurfaceRows()
            }
            SettingsGroup(title: "Floating button", footer: surfaceRaw == DictationSurface.button.rawValue ? nil
                          : "It shows once Show dictation in, above, is set to Floating button.") {
                SettingsRow("float.look", detail: "", stacked: true) {
                    HStack(spacing: 10) {
                        ForEach(FloatingLook.allCases) { l in
                            LookCard(look: l, selected: lookRaw == l.rawValue, keycap: app.dictation.hotkey.keycap) { lookRaw = l.rawValue }
                        }
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                }
                SettingsRow("float.size") {
                    Picker("Size", selection: $sizeRaw) {
                        ForEach(FloatingSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingsRow("float.mark") {
                    Picker("Voice mark", selection: $mark) {
                        Text("Three bars").tag(RibbonMark.bars.rawValue)
                        Text("Rings").tag(RibbonMark.rings.rawValue)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingsToggleRow("float.snap", isOn: $snap)
                SettingsToggleRow("float.liveWords", isOn: $liveWords)
            }
        }
        .onChange(of: lookRaw) { _, _ in app.dictation.bar?.refresh() }
        .onChange(of: sizeRaw) { _, _ in app.dictation.bar?.refresh() }
        .onChange(of: liveWords) { _, on in if on { app.dictation.prepareLiveWords(askPermission: true) } }
    }
}

/// One look in Settings › Floating button and Ribbon › Floating button, drawn at rest on a neutral desktop.
private struct LookCard: View {
    var look: FloatingLook
    var selected: Bool
    var keycap: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Ink.stripeA
                DesktopHills().fill(Ink.stripeB).padding(.top, 22)
                FloatingButtonFace(look: look, size: look == .dot ? .medium : .small, phase: .rest,
                                   levels: VoiceBars.still(5), elapsed: 0, keycap: String(keycap.split(separator: " ").last ?? "⌥"))
                    .scaleEffect(look == .label ? 0.82 : 1)
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            Text(look.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                .padding(.top, 8).padding(.horizontal, 4)
        }
        .padding(6).padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(selected ? Ink.card : (hover ? Ink.cardHover : Ink.paper), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay { if !selected { RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1) } }
        .inkEdge(outline: selected, shadow: selected ? CGSize(width: 3, height: 4) : .zero, radius: Radius.tile)
        .onHover { hover = $0 }
        .tapArea(action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
        .uiTarget("settings-look-\(look.rawValue)")
    }
}
