import SwiftUI
import UIKit

// The typing layout: each language's letters (QWERTY, QWERTY with ñ, AZERTY, QWERTZ, ЙЦУКЕН, Greek with its accent key,
// and Arabic and Hebrew, whose rows read right to left and have no shift) with shift and caps lock, 123 and #+= layers,
// space, return, delete with repeat, and the globe key; long-press letters, and the space bar's cursor drag. It works without Allow Full Access (App Store guideline 4.4.1): it only uses the text proxy. The layout and the
// rules are pure (TypingLayout.swift, TypingHelp.swift, TypingCorrection.swift); this file applies them to the field and
// draws the keys. Corrections and the suggestion strip are `TypingAssist`.

/// Typing state: the layer, shift, the field's traits, and the keys under a finger. Touches arrive from
/// `KeyTouchView` (multi-touch, so fast two-thumb typing keeps every key).
@MainActor
final class TypingModel: ObservableObject {
    @Published private(set) var layer: TypingLayer = .letters
    @Published private(set) var shift: ShiftState = .off
    @Published private(set) var field: FieldKind = .standard
    @Published private(set) var returnKind: ReturnKind = .standard
    /// False while the field is empty and asks for an automatic return key (`enablesReturnKeyAutomatically`).
    @Published private(set) var returnEnabled = true
    @Published var showsGlobe = true
    /// The keys a finger is on, for the pressed look and the key popup.
    @Published private(set) var pressed: [KeyID: KeyKind] = [:]
    /// The language's letter layout (`TypingLanguages.layout`).
    @Published private(set) var letters: KeyLayout = .qwerty
    /// The long-press row over a held letter, when it's open.
    @Published private(set) var accent: AccentPopup?
    /// True while the space bar drags the cursor: the key labels clear.
    @Published private(set) var cursorDragging = false
    /// Greek's accent mark waiting for the next letter (`DeadKeys`): the accent key shows as held.
    @Published private(set) var pendingMark: String?

    /// A held letter's alternates and where they sit.
    struct AccentPopup: Equatable {
        var key: KeyID
        var keyFrame: CGRect
        /// In the case they'd type (capitals with shift or caps lock on).
        var options: [String]
        var row: AccentRow
        var selected = 0
    }

    /// Autocorrect, text replacements, and the suggestion strip.
    let assist = TypingAssist()
    /// The haptic when a cursor drag starts (a selection tick), nil without Full Access or with Haptics off.
    var dragHaptic: Haptic?

    /// Haptics need Allow Full Access; input clicks don't.
    var hasFullAccess = false {
        didSet { updateImpact() }
    }
    /// A key's tap: nil unless Settings › Keyboard › Typing haptics is on (off by default) and Haptics is on
    /// (`HapticPolicy`, read when the keyboard appears).
    var typingHaptic: Haptic? {
        didSet { updateImpact() }
    }

    private func updateImpact() {
        if hasFullAccess, case .impact(let weight, _)? = typingHaptic {
            if impact == nil || impactWeight != weight { impact = UIImpactFeedbackGenerator(style: weight.style); impactWeight = weight }
        } else {
            impact = nil; impactWeight = nil
        }
    }

    weak var controller: UIInputViewController? {
        didSet { assist.controller = controller }
    }
    /// Called after each key that changes the text, so the dictation view drops an Undo that no longer applies.
    var onEdit: (() -> Void)?

    var rows: [[RowItem]] { TypingLayout.rows(layer: layer, field: field, showsGlobe: showsGlobe, letters: letters) }
    /// Letter keys across the widest row, for the key width (11 for QWERTZ's letters).
    var columns: Int { layer == .letters && field != .numberPad && field != .decimalPad ? letters.columns : 10 }

    private struct Touch {
        var key: KeyID
        var kind: KeyKind
        /// The key's frame in the key area, for the long-press row.
        var frame: CGRect
        /// Already typed, because a newer key was pressed while this finger was still down (rollover).
        var committed = false
    }

    private var autoCap: AutoCapMode = .sentences
    private var lastShiftTap: Date?
    private var lastKeyWasSpace = false
    /// The last key press here, so a late `textDidChange` from our own typing doesn't undo a shift you just set.
    private var lastLocalKey = Date.distantPast
    private var document: UUID?
    private var touches: [ObjectIdentifier: Touch] = [:]
    private var repeatTimer: Timer?
    private var impact: UIImpactFeedbackGenerator?
    private var impactWeight: HapticWeight?
    /// The touch and hold that opens the long-press row (0.4 s) or starts the cursor drag (0.3 s).
    private enum Hold { case accent, cursor }
    private var holdTimer: Timer?
    private var accentTouch: ObjectIdentifier?
    private var accentOpenX: CGFloat = 0
    private var accentMoved = false
    private var drag: CursorDrag?
    private var dragTouch: ObjectIdentifier?
    /// Where each finger is, across the key area, and how wide the area is (for the long-press row).
    private var touchX: [ObjectIdentifier: CGFloat] = [:]
    private var areaWidth: CGFloat = 0

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    // MARK: Field traits

    /// Reads the field's traits. `reset` (a new appearance) also starts over in the field's first layer.
    func refreshTraits(reset: Bool) {
        guard let p = proxy else { return }
        let newField = Self.mapField(p.keyboardType)
        let newDocument = p.safeDocumentIdentifier
        let changedField = newField != field || newDocument != document
        if newField != field { field = newField }
        document = newDocument
        let r = Self.mapReturn(p.returnKeyType)
        if r != returnKind { returnKind = r }
        autoCap = Self.mapAutoCap(p.autocapitalizationType)
        assist.setPolicy(TypingFieldPolicy(kind: newField, autocorrection: Self.mapTrait(p.autocorrectionType),
                                           spellChecking: Self.mapTrait(p.spellCheckingType), contentType: p.safeTextContentType))
        updateReturnEnabled()
        if reset || changedField {
            let l = TypingRules.initialLayer(for: field)
            if l != layer { layer = l }
            lastKeyWasSpace = false
            clearMark()
            if reset { shift = .off }
        }
        // Auto-capitalize for where the cursor is now, unless you pressed a key a moment ago (that key already did).
        if reset || changedField || Date().timeIntervalSince(lastLocalKey) > 0.4 {
            setShift(TypingRules.shiftAfterInput(shift, capitalizeNext: capitalizeNext))
            // The cursor moved or the host changed the text: a correction can't be put back from here.
            assist.forget()
        } else {
            assist.setNeedsRefresh()
        }
    }

    /// The language to type in: its letter layout and the spell checker's language. Arabic and Hebrew have no capitals, so
    /// shift goes off.
    func setLanguage(_ language: String) {
        assist.setLanguage(language)
        let l = TypingLanguages.layout(for: language)
        if l != letters {
            letters = l
            clearMark()
            setShift(TypingRules.shiftAfterInput(shift, capitalizeNext: capitalizeNext))
        }
    }

    /// The accent key shows as held while its mark waits.
    func showsHeld(_ kind: KeyKind) -> Bool {
        guard pendingMark != nil, case .character(let c) = kind else { return false }
        return DeadKeys.isDead(c)
    }

    private func clearMark() { if pendingMark != nil { pendingMark = nil } }

    private var capitalizeNext: Bool { TypingRules.shouldCapitalize(autoCap, before: proxy?.documentContextBeforeInput) }

    private func updateReturnEnabled() {
        guard let p = proxy else { return }
        let enabled = !(p.enablesReturnKeyAutomatically ?? false) || p.hasText
        if enabled != returnEnabled { returnEnabled = enabled }
    }

    /// Shift stays off on layouts without capitals (Arabic, Hebrew).
    private func setShift(_ s: ShiftState) {
        let s = letters.hasCase ? s : .off
        if s != shift { shift = s }
    }

    static func mapField(_ t: UIKeyboardType?) -> FieldKind {
        switch t ?? .default {
        case .numberPad, .asciiCapableNumberPad: return .numberPad
        case .decimalPad: return .decimalPad
        case .numbersAndPunctuation, .phonePad: return .numbersAndPunctuation
        case .emailAddress: return .email
        case .URL: return .url
        default: return .standard
        }
    }

    static func mapReturn(_ t: UIReturnKeyType?) -> ReturnKind {
        switch t ?? .default {
        case .go: return .go
        case .google, .yahoo, .search: return .search
        case .join: return .join
        case .next: return .next
        case .route: return .route
        case .send: return .send
        case .done: return .done
        case .emergencyCall: return .emergencyCall
        case .continue: return .continue
        default: return .standard
        }
    }

    static func mapTrait(_ t: UITextAutocorrectionType?) -> FieldTrait {
        switch t ?? .default {
        case .no: return .no
        case .yes: return .yes
        default: return .default
        }
    }

    static func mapTrait(_ t: UITextSpellCheckingType?) -> FieldTrait {
        switch t ?? .default {
        case .no: return .no
        case .yes: return .yes
        default: return .default
        }
    }

    static func mapAutoCap(_ t: UITextAutocapitalizationType?) -> AutoCapMode {
        switch t ?? .sentences {
        case .none: return .none
        case .words: return .words
        case .allCharacters: return .allCharacters
        default: return .sentences
        }
    }

    // MARK: Touches

    func touchBegan(_ id: ObjectIdentifier, on key: PlacedKey, at point: CGPoint, areaWidth width: CGFloat) {
        lastLocalKey = Date()
        areaWidth = width
        touchX[id] = point.x
        // A second finger closes an open long-press row (typing its letter) or ends a cursor drag.
        if accentTouch != nil { finishAccent(insert: true) }
        if dragTouch != nil { endDrag() }
        cancelHold()
        // Rollover: a new character commits the ones still held (fast two-thumb typing).
        if key.kind.isCharacter || key.kind == .space {
            for (other, t) in touches where !t.committed && (t.kind.isCharacter || t.kind == .space) {
                commit(t.kind)
                touches[other]?.committed = true
            }
        }
        touches[id] = Touch(key: key.id, kind: key.kind, frame: key.frame)
        feedback()
        switch key.kind {
        case .shift: tapShift()
        case .delete: deleteOnce(); startRepeat()
        case .space: startHold(.cursor, id, key: key.id)
        case .character(let c):
            if layer == .letters, showsAccents, !AccentSets.alternates(for: c, language: assist.language).isEmpty {
                startHold(.accent, id, key: key.id)
            }
        default: break
        }
        publishPressed()
    }

    /// Long-press rows show on letter layouts, not number pads, and not with VoiceOver (as the key popup).
    private var showsAccents: Bool {
        field != .numberPad && field != .decimalPad && !UIAccessibility.isVoiceOverRunning
    }

    /// Sliding to another character key moves the press there, as on the system keyboard; it types on release. With the
    /// long-press row open, sliding picks a letter in it; while the space bar drags, sliding moves the cursor.
    func touchMoved(_ id: ObjectIdentifier, to key: PlacedKey?, at point: CGPoint) {
        touchX[id] = point.x
        if id == dragTouch, var d = drag {
            let delta = d.move(to: point.x)
            drag = d
            if delta != 0 { proxy?.adjustTextPosition(byCharacterOffset: delta) }
            return
        }
        if id == accentTouch, var a = accent {
            if !accentMoved, abs(point.x - accentOpenX) >= AccentRow.pickSlop { accentMoved = true }
            if accentMoved {
                a.selected = a.row.index(at: point.x)
                if a != accent { accent = a }
            }
            return
        }
        guard var t = touches[id], !t.committed, t.kind.isCharacter,
              let key, key.kind.isCharacter, key.id != t.key else { return }
        t.key = key.id
        t.kind = key.kind
        t.frame = key.frame
        touches[id] = t
        publishPressed()
    }

    func touchEnded(_ id: ObjectIdentifier) {
        touchX[id] = nil
        if id == dragTouch { touches[id] = nil; endDrag(); publishPressed(); return }
        if id == accentTouch { finishAccent(insert: true); touches[id] = nil; publishPressed(); return }
        guard let t = touches.removeValue(forKey: id) else { return }
        if touches.isEmpty { cancelHold() }
        switch t.kind {
        case .delete: stopRepeat()
        case .shift, .globe: break
        default: if !t.committed { commit(t.kind) }
        }
        publishPressed()
    }

    func touchCancelled(_ id: ObjectIdentifier) {
        touchX[id] = nil
        if id == dragTouch { endDrag() }
        if id == accentTouch { finishAccent(insert: false) }
        guard let t = touches.removeValue(forKey: id) else { return }
        if t.kind == .delete { stopRepeat() }
        publishPressed()
    }

    /// Drops every touch (the keyboard went away mid-press).
    func reset() {
        clearMark()
        touches.removeAll()
        touchX.removeAll()
        stopRepeat()
        cancelHold()
        if accentTouch != nil { finishAccent(insert: false) }
        if dragTouch != nil { endDrag() }
        publishPressed()
    }

    // MARK: Touch and hold

    private func startHold(_ hold: Hold, _ id: ObjectIdentifier, key: KeyID) {
        cancelHold()
        let delay = hold == .accent ? AccentRow.holdDelay : CursorDrag.holdDelay
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.holdFired(hold, id, key: key) }
        }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    /// The hold lasted: the finger is still on the same key and it hasn't typed (no rollover).
    private func holdFired(_ hold: Hold, _ id: ObjectIdentifier, key: KeyID) {
        holdTimer = nil
        guard let t = touches[id], !t.committed, t.key == key else { return }
        switch hold {
        case .cursor: beginDrag(id)
        case .accent: openAccent(id, kind: t.kind, key: key, frame: t.frame)
        }
    }

    private func openAccent(_ id: ObjectIdentifier, kind: KeyKind, key: KeyID, frame: CGRect) {
        guard case .character(let c) = kind else { return }
        var options = AccentSets.alternates(for: c, language: assist.language)
        if shift != .off { options = AccentSets.capitals(options) }
        guard !options.isEmpty else { return }
        let row = AccentRow.layout(keyMinX: frame.minX, keyWidth: frame.width, count: options.count, areaWidth: areaWidth,
                                   rightToLeft: letters.isRightToLeft)
        accentTouch = id
        accentOpenX = touchX[id] ?? frame.midX
        accentMoved = false
        accent = AccentPopup(key: key, keyFrame: frame, options: options, row: row)
    }

    /// Release with the row open types the chosen letter instead of the key's own.
    private func finishAccent(insert: Bool) {
        let chosen = accent.flatMap { $0.options.indices.contains($0.selected) ? $0.options[$0.selected] : nil }
        if let id = accentTouch { touches[id]?.committed = true }
        accentTouch = nil
        accent = nil
        if insert, let chosen { typeCharacter(chosen); finishKey(after: .character(chosen)) }
    }

    /// The drag moves in visual order: in a right-to-left paragraph (Hebrew, Arabic), dragging left moves forward.
    private func beginDrag(_ id: ObjectIdentifier) {
        dragTouch = id
        clearMark()
        let rtl = TypingScripts.paragraphIsRightToLeft(before: proxy?.documentContextBeforeInput, after: proxy?.documentContextAfterInput,
                                                        fallback: letters.isRightToLeft)
        drag = CursorDrag(startX: touchX[id] ?? 0, rightToLeft: rtl)
        cursorDragging = true
        assist.forget()
        if hasFullAccess, let h = dragHaptic { HapticPlayer.play(h) }
    }

    /// The finger lifted after a drag: no space goes in; shift and the strip follow the cursor's new place.
    private func endDrag() {
        if let id = dragTouch { touches[id]?.committed = true }
        dragTouch = nil
        drag = nil
        if cursorDragging { cursorDragging = false }
        setShift(TypingRules.shiftAfterInput(shift, capitalizeNext: capitalizeNext))
        lastKeyWasSpace = false
        assist.forget()
    }

    /// VoiceOver's double tap on a key.
    func activate(_ kind: KeyKind) {
        lastLocalKey = Date()
        switch kind {
        case .shift: tapShift()
        case .delete: deleteOnce()
        case .globe: controller?.advanceToNextInputMode()
        default: commit(kind)
        }
    }

    private func publishPressed() {
        var p: [KeyID: KeyKind] = [:]
        for t in touches.values { p[t.key] = t.kind }
        if p != pressed { pressed = p }
    }

    // MARK: Keys

    private func commit(_ kind: KeyKind) {
        guard let proxy else { return }
        switch kind {
        case .character(let c):
            typeCharacter(TypingRules.text(for: c, layer: layer, shift: shift))
        case .space:
            if pendingMark != nil {
                // Space after the accent key types the mark alone.
                typeCharacter(" ")
            } else if TypingRules.periodShortcut(before: proxy.documentContextBeforeInput, lastKeyWasSpace: lastKeyWasSpace, field: field) {
                assist.keyTyped()
                proxy.deleteBackward()
                proxy.insertText(". ")
                lastKeyWasSpace = false
            } else {
                // Space corrects the word before it (or expands a text replacement) first.
                assist.boundary(trailing: " ")
                proxy.insertText(" ")
                lastKeyWasSpace = true
            }
        case .returnKey:
            guard returnEnabled else { return }
            clearMark()
            assist.boundary(trailing: "\n")
            proxy.insertText("\n")
            lastKeyWasSpace = false
        case .layer(let l):
            clearMark()
            if l != layer { layer = l }
            return
        case .shift, .delete, .globe:
            return
        }
        finishKey(after: kind)
    }

    /// A character key's text or a long-press letter, through Greek's accent key: a mark waits for the next letter, and
    /// a waiting mark goes on a vowel (`DeadKeys.press`).
    private func typeCharacter(_ text: String) {
        guard pendingMark != nil || DeadKeys.isDead(text) else { typeText(text); return }
        let r = DeadKeys.press(pending: pendingMark, input: text)
        if r.pending != pendingMark { pendingMark = r.pending }
        if !r.insert.isEmpty { typeText(r.insert) }
    }

    /// Inserts text: punctuation corrects the word before it first.
    private func typeText(_ text: String) {
        guard let proxy else { return }
        if TypingCorrection.isBoundary(text) { assist.boundary(trailing: text) } else { assist.keyTyped() }
        proxy.insertText(text)
        lastKeyWasSpace = false
    }

    private func finishKey(after kind: KeyKind) {
        let next = TypingRules.layer(after: kind, in: layer, field: field)
        if next != layer { layer = next }
        afterEdit()
    }

    private func afterEdit() {
        setShift(TypingRules.shiftAfterInput(shift, capitalizeNext: capitalizeNext))
        updateReturnEnabled()
        assist.setNeedsRefresh()
        onEdit?()
    }

    /// A tap on the suggestion strip: keep the word, use a suggestion, or put a correction back.
    func tapSuggestion(_ action: SuggestionStrip.Action) {
        lastLocalKey = Date()
        feedback()
        clearMark()
        let spaced = assist.tap(action)
        lastKeyWasSpace = spaced
        afterEdit()
    }

    private func tapShift() {
        let now = Date()
        setShift(TypingRules.tapShift(shift, sinceLastTap: lastShiftTap.map { now.timeIntervalSince($0) }))
        // After caps lock turns on, the next tap starts a fresh pair.
        lastShiftTap = shift == .locked ? nil : now
    }

    /// Delete: first drops a waiting accent mark, then puts back a correction space just made, otherwise deletes one
    /// character.
    private func deleteOnce() {
        if pendingMark != nil {
            pendingMark = nil
            return
        }
        if !assist.handleDelete() { proxy?.deleteBackward() }
        lastKeyWasSpace = false
        afterEdit()
    }

    private func startRepeat() {
        stopRepeat()
        let t = Timer(timeInterval: TypingRules.repeatDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.touches.values.contains(where: { $0.kind == .delete }) else { return }
                let r = Timer(timeInterval: TypingRules.repeatInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.deleteOnce() }
                }
                RunLoop.main.add(r, forMode: .common)
                self.repeatTimer = r
            }
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    /// The system's input click (follows Settings › Sounds › Keyboard Clicks; works without Full Access), plus a
    /// light tap you can feel with Full Access and Typing haptics on.
    private func feedback() {
        UIDevice.current.playInputClick()
        if let impact, case .impact(_, let intensity)? = typingHaptic { impact.impactOccurred(intensity: CGFloat(intensity)) }
    }
}

// MARK: - Drawing

/// The key area: keys drawn in SwiftUI from `TypingLayout.place`, with a UIKit layer on top for touches and
/// VoiceOver. Nothing animates (DESIGN.md §7: never animate high-frequency input).
struct TypingKeysView: View {
    @ObservedObject var typing: TypingModel

    var body: some View {
        GeometryReader { geo in
            let rows = typing.rows
            let keys = TypingLayout.place(rows, in: geo.size, metrics: KeyMetrics.forSize(geo.size, rows: rows.count), columns: typing.columns)
            ZStack(alignment: .topLeading) {
                ForEach(keys) { k in
                    KeyCap(kind: k.kind, typing: typing, pressed: typing.pressed[k.id] != nil || typing.showsHeld(k.kind))
                        .frame(width: k.frame.width, height: k.frame.height)
                        .position(x: k.frame.midX, y: k.frame.midY)
                }
                if showsPopups && !typing.cursorDragging {
                    ForEach(keys.filter { typing.pressed[$0.id] != nil && $0.kind.isCharacter && typing.accent?.key != $0.id }) { k in
                        KeyPopup(kind: k.kind, typing: typing, keyFrame: k.frame, areaWidth: geo.size.width)
                    }
                }
                if let a = typing.accent { AccentPopupView(popup: a) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
            .overlay(KeyTouchLayer(typing: typing, keys: keys))
        }
    }

    /// Popups show on letter layouts, not number pads, and not with VoiceOver (as on the system keyboard).
    private var showsPopups: Bool {
        typing.field != .numberPad && typing.field != .decimalPad && !UIAccessibility.isVoiceOverRunning
    }
}

/// One key. Letters, numbers, and space are paper keys (`card`); shift, delete, the layer keys, and the globe are
/// on the wash, like the system's darker function keys. Return is ink with paper text. Each key sits on a 1 pt
/// ink-tinted bottom edge (`KBKeyFace`).
private struct KeyCap: View {
    var kind: KeyKind
    @ObservedObject var typing: TypingModel
    var pressed: Bool

    private var isFunction: Bool { !kind.isCharacter && kind != .space && kind != .returnKey && !shiftActive }
    private var shiftActive: Bool { kind == .shift && typing.shift != .off }

    var body: some View {
        ZStack {
            KBKeyFace(fill: fill)
            label
        }
    }

    private var fill: Color {
        if kind == .returnKey { return pressed ? KB.ink.opacity(0.8) : KB.ink }
        if isFunction { return pressed ? KB.key : KB.wash }
        return pressed ? KB.wash : KB.key
    }

    @ViewBuilder private var label: some View {
        // While the space bar drags the cursor, every label clears (the mockup's blank keys); the keys stay.
        if typing.cursorDragging {
            EmptyView()
        } else {
            keyLabel
        }
    }

    @ViewBuilder private var keyLabel: some View {
        switch kind {
        case .character(let c):
            Text(TypingRules.text(for: c, layer: typing.layer, shift: typing.shift))
                .font(.system(size: typing.layer == .letters ? 22 : 21))
                .foregroundStyle(KB.ink)
        case .shift:
            Group {
                switch typing.shift {
                case .off: Image(systemName: "shift")
                case .on: Image(systemName: "shift.fill")
                case .locked: Image(systemName: "capslock.fill")
                }
            }
            .font(.system(size: 17, weight: .medium)).foregroundStyle(KB.ink)
        case .delete:
            Image(systemName: "delete.left").font(.system(size: 18)).foregroundStyle(KB.ink)
        case .globe:
            Image(systemName: "globe").font(.system(size: 18)).foregroundStyle(KB.ink)
        case .space:
            // The space bar carries the name, as on Wispr Flow's keyboard; VoiceOver still says "Space".
            Text("Verbose").font(.system(size: 15)).foregroundStyle(KB.keyMuted)
        case .returnKey:
            Text(typing.returnKind.label ?? "return")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 4)
                .foregroundStyle(KB.paper)
                .opacity(typing.returnEnabled ? 1 : 0.4)
        case .layer:
            Text(kind.layerTitle ?? "").font(.system(size: 15)).foregroundStyle(KB.ink)
        }
    }
}

/// The long-press row over a held letter: the language's letters first, in the key popup's style (the card with a
/// hairline), the chosen one in ink with paper text, like the return key. Each slot is a key wide; on a right-to-left
/// layout the first letter is the rightmost. It appears and goes at once (DESIGN.md §7: nothing in the keyboard animates
/// for keyboard actions).
private struct AccentPopupView: View {
    var popup: TypingModel.AccentPopup

    var body: some View {
        let h = popup.keyFrame.height + 4
        let y = popup.keyFrame.minY + 2 - h / 2
        let shape = RoundedRectangle(cornerRadius: KB.keyRadius, style: .continuous)
        HStack(spacing: 0) {
            ForEach(0..<popup.options.count, id: \.self) { slot in
                let i = popup.row.option(atSlot: slot)
                let on = i == popup.selected
                Text(popup.options[i])
                    .font(.system(size: 24))
                    .foregroundStyle(on ? KB.paper : KB.ink)
                    .frame(width: popup.row.slot, height: h - 6)
                    .background(on ? KB.ink : Color.clear, in: RoundedRectangle(cornerRadius: KB.keyRadius - 2, style: .continuous))
            }
        }
        .frame(width: popup.row.width, height: h)
        .background(KBKeyFace(fill: KB.key))
        .overlay(shape.strokeBorder(KB.hairline))
        .position(x: popup.row.originX + popup.row.width / 2, y: y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The key popup: the character, larger, above your finger. Clamped to the keyboard's edges.
private struct KeyPopup: View {
    var kind: KeyKind
    @ObservedObject var typing: TypingModel
    var keyFrame: CGRect
    var areaWidth: CGFloat

    var body: some View {
        let w = keyFrame.width + 16
        let h = keyFrame.height + 4
        let x = min(max(keyFrame.midX, w / 2), max(w / 2, areaWidth - w / 2))
        let y = keyFrame.minY + 2 - h / 2
        let shape = RoundedRectangle(cornerRadius: KB.keyRadius, style: .continuous)
        Text(text)
            .font(.system(size: 32))
            .foregroundStyle(KB.ink)
            .frame(width: w, height: h)
            .background(KBKeyFace(fill: KB.key))
            .overlay(shape.strokeBorder(KB.hairline))
            .position(x: x, y: y)
            .allowsHitTesting(false)
    }

    private var text: String {
        if case .character(let c) = kind { return TypingRules.text(for: c, layer: typing.layer, shift: typing.shift) }
        return ""
    }
}

// MARK: - Touches and VoiceOver

/// A transparent UIKit layer over the keys: multi-touch hit testing (a touch in a gap lands on the nearest key),
/// the globe key's hand-off to `handleInputModeList(from:with:)`, and one VoiceOver element per key.
private struct KeyTouchLayer: UIViewRepresentable {
    @ObservedObject var typing: TypingModel
    var keys: [PlacedKey]

    func makeUIView(context: Context) -> KeyTouchView {
        let v = KeyTouchView()
        v.model = typing
        return v
    }

    func updateUIView(_ v: KeyTouchView, context: Context) {
        v.model = typing
        v.update(keys: keys, labels: KeyTouchView.Labels(shift: typing.shift, layer: typing.layer,
                                                          returnKind: typing.returnKind, returnEnabled: typing.returnEnabled,
                                                          rightToLeft: typing.layer == .letters && typing.letters.isRightToLeft,
                                                          markPending: typing.pendingMark != nil))
    }

    static func dismantleUIView(_ v: KeyTouchView, coordinator: ()) {
        v.model?.reset()
    }
}

final class KeyTouchView: UIView {
    struct Labels: Equatable {
        var shift: ShiftState
        var layer: TypingLayer
        var returnKind: ReturnKind
        var returnEnabled: Bool
        /// Arabic's and Hebrew's letter rows: VoiceOver reads them right to left.
        var rightToLeft = false
        /// Greek's accent key is held, waiting for a letter.
        var markPending = false
    }

    weak var model: TypingModel?
    private var keys: [PlacedKey] = []
    private var labels: Labels?
    private var globeTouches = Set<ObjectIdentifier>()
    private var elements: [KeyElement] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(keys: [PlacedKey], labels: Labels) {
        guard keys != self.keys || labels != self.labels else { return }
        self.keys = keys
        self.labels = labels
        rebuildElements()
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        var globe = false
        for t in touches {
            guard let key = TypingLayout.hit(t.location(in: self), in: keys) else { continue }
            if key.kind == .globe { globeTouches.insert(ObjectIdentifier(t)); globe = true }
            model?.touchBegan(ObjectIdentifier(t), on: key, at: t.location(in: self), areaWidth: bounds.width)
        }
        if globe { forwardGlobe(event) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var globe = false
        for t in touches {
            let id = ObjectIdentifier(t)
            if globeTouches.contains(id) { globe = true; continue }
            let key = TypingLayout.hit(t.location(in: self), in: keys)
            model?.touchMoved(id, to: key, at: t.location(in: self))
        }
        if globe { forwardGlobe(event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        var globe = false
        for t in touches {
            let id = ObjectIdentifier(t)
            if globeTouches.remove(id) != nil { globe = true }
            if cancelled { model?.touchCancelled(id) } else { model?.touchEnded(id) }
        }
        if globe { forwardGlobe(event) }
    }

    /// The globe key: a tap moves to the next keyboard; a touch and hold shows the keyboard list.
    private func forwardGlobe(_ event: UIEvent?) {
        guard let event else { return }
        model?.controller?.handleInputModeList(from: self, with: event)
    }

    // MARK: VoiceOver

    private final class KeyElement: UIAccessibilityElement {
        var onActivate: (@MainActor () -> Void)?
        override func accessibilityActivate() -> Bool {
            MainActor.assumeIsolated { onActivate?() }
            return true
        }
    }

    private func rebuildElements() {
        guard let labels else { elements = []; return }
        let ordered = TypingLayout.readingOrder(keys, rightToLeftRows: labels.rightToLeft ? [0, 1, 2] : [])
        elements = ordered.map { key in
            let e = KeyElement(accessibilityContainer: self)
            e.accessibilityLabel = key.kind.spokenLabel(shift: labels.shift, layer: labels.layer, returnKind: labels.returnKind)
            e.accessibilityFrameInContainerSpace = key.frame
            var traits: UIAccessibilityTraits = .keyboardKey
            switch key.kind {
            case .shift:
                if labels.shift != .off { traits.insert(.selected) }
                e.accessibilityValue = labels.shift == .locked ? "Caps lock" : nil
            case .returnKey:
                if !labels.returnEnabled { traits.insert(.notEnabled) }
            case .globe:
                traits = .button
                e.accessibilityHint = "Switches to your next keyboard"
            case .character(let c) where DeadKeys.isDead(c):
                if labels.markPending { traits.insert(.selected) }
                e.accessibilityHint = "Puts the accent on the next letter"
            default:
                break
            }
            e.accessibilityTraits = traits
            let kind = key.kind
            e.onActivate = { [weak self] in self?.model?.activate(kind) }
            return e
        }
    }

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var accessibilityElements: [Any]? {
        get { elements }
        set {}
    }
}

extension UITextDocumentProxy {
    /// The field's `documentIdentifier`, read without Swift's bridge. Swift declares it as a non-optional `UUID`, but on
    /// iOS 27 it is nil while the keyboard loads (before the field connects), and bridging nil to `UUID` traps:
    /// build 185 crashed in `viewDidLoad` every time the keyboard opened. Nil here means "no field yet".
    var safeDocumentIdentifier: UUID? {
        let getter = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard let object = self as? NSObject, object.responds(to: getter),
              let value = object.perform(getter)?.takeUnretainedValue() as? NSUUID else { return nil }
        return value as UUID
    }

    /// The field's `textContentType` as a string, read without Swift's bridge for the same reason: Swift imports it as
    /// an implicitly unwrapped `UITextContentType`, and a field that isn't connected yet can hand back nil or a
    /// non-string. Nil means "no content type".
    var safeTextContentType: String? {
        let getter = NSSelectorFromString("textContentType")
        guard let object = self as? NSObject, object.responds(to: getter),
              let value = object.perform(getter)?.takeUnretainedValue() as? NSString else { return nil }
        let s = value as String
        return s.isEmpty ? nil : s
    }
}
