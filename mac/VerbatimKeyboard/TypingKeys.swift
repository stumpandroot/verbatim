import SwiftUI
import UIKit

// The typing layout: QWERTY with shift and caps lock, 123 and #+= layers, space, return, delete with repeat, and
// the globe key. It works without Allow Full Access (App Store guideline 4.4.1): it only uses the text proxy.
// The layout and the rules are pure (TypingLayout.swift); this file applies them to the field and draws the keys.

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

    /// Haptics need Allow Full Access; input clicks don't.
    var hasFullAccess = false {
        didSet { impact = hasFullAccess ? UIImpactFeedbackGenerator(style: .light) : nil }
    }

    weak var controller: UIInputViewController?
    /// Called after each key that changes the text, so the dictation view drops an Undo that no longer applies.
    var onEdit: (() -> Void)?

    var rows: [[RowItem]] { TypingLayout.rows(layer: layer, field: field, showsGlobe: showsGlobe) }

    private struct Touch {
        var key: KeyID
        var kind: KeyKind
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
        updateReturnEnabled()
        if reset || changedField {
            let l = TypingRules.initialLayer(for: field)
            if l != layer { layer = l }
            lastKeyWasSpace = false
            if reset { shift = .off }
        }
        // Auto-capitalize for where the cursor is now, unless you pressed a key a moment ago (that key already did).
        if reset || changedField || Date().timeIntervalSince(lastLocalKey) > 0.4 {
            setShift(TypingRules.shiftAfterInput(shift, capitalizeNext: capitalizeNext))
        }
    }

    private var capitalizeNext: Bool { TypingRules.shouldCapitalize(autoCap, before: proxy?.documentContextBeforeInput) }

    private func updateReturnEnabled() {
        guard let p = proxy else { return }
        let enabled = !(p.enablesReturnKeyAutomatically ?? false) || p.hasText
        if enabled != returnEnabled { returnEnabled = enabled }
    }

    private func setShift(_ s: ShiftState) { if s != shift { shift = s } }

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

    static func mapAutoCap(_ t: UITextAutocapitalizationType?) -> AutoCapMode {
        switch t ?? .sentences {
        case .none: return .none
        case .words: return .words
        case .allCharacters: return .allCharacters
        default: return .sentences
        }
    }

    // MARK: Touches

    func touchBegan(_ id: ObjectIdentifier, on key: PlacedKey) {
        lastLocalKey = Date()
        // Rollover: a new character commits the ones still held (fast two-thumb typing).
        if key.kind.isCharacter || key.kind == .space {
            for (other, t) in touches where !t.committed && (t.kind.isCharacter || t.kind == .space) {
                commit(t.kind)
                touches[other]?.committed = true
            }
        }
        touches[id] = Touch(key: key.id, kind: key.kind)
        feedback()
        switch key.kind {
        case .shift: tapShift()
        case .delete: deleteOnce(); startRepeat()
        default: break
        }
        publishPressed()
    }

    /// Sliding to another character key moves the press there, as on the system keyboard; it types on release.
    func touchMoved(_ id: ObjectIdentifier, to key: PlacedKey?) {
        guard var t = touches[id], !t.committed, t.kind.isCharacter,
              let key, key.kind.isCharacter, key.id != t.key else { return }
        t.key = key.id
        t.kind = key.kind
        touches[id] = t
        publishPressed()
    }

    func touchEnded(_ id: ObjectIdentifier) {
        guard let t = touches.removeValue(forKey: id) else { return }
        switch t.kind {
        case .delete: stopRepeat()
        case .shift, .globe: break
        default: if !t.committed { commit(t.kind) }
        }
        publishPressed()
    }

    func touchCancelled(_ id: ObjectIdentifier) {
        guard let t = touches.removeValue(forKey: id) else { return }
        if t.kind == .delete { stopRepeat() }
        publishPressed()
    }

    /// Drops every touch (the keyboard went away mid-press).
    func reset() {
        touches.removeAll()
        stopRepeat()
        publishPressed()
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
            proxy.insertText(TypingRules.text(for: c, layer: layer, shift: shift))
            lastKeyWasSpace = false
        case .space:
            if TypingRules.periodShortcut(before: proxy.documentContextBeforeInput, lastKeyWasSpace: lastKeyWasSpace, field: field) {
                proxy.deleteBackward()
                proxy.insertText(". ")
                lastKeyWasSpace = false
            } else {
                proxy.insertText(" ")
                lastKeyWasSpace = true
            }
        case .returnKey:
            guard returnEnabled else { return }
            proxy.insertText("\n")
            lastKeyWasSpace = false
        case .layer(let l):
            if l != layer { layer = l }
            return
        case .shift, .delete, .globe:
            return
        }
        let next = TypingRules.layer(after: kind, in: layer, field: field)
        if next != layer { layer = next }
        afterEdit()
    }

    private func afterEdit() {
        setShift(TypingRules.shiftAfterInput(shift, capitalizeNext: capitalizeNext))
        updateReturnEnabled()
        onEdit?()
    }

    private func tapShift() {
        let now = Date()
        setShift(TypingRules.tapShift(shift, sinceLastTap: lastShiftTap.map { now.timeIntervalSince($0) }))
        // After caps lock turns on, the next tap starts a fresh pair.
        lastShiftTap = shift == .locked ? nil : now
    }

    private func deleteOnce() {
        proxy?.deleteBackward()
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
    /// light tap you can feel with Full Access.
    private func feedback() {
        UIDevice.current.playInputClick()
        impact?.impactOccurred(intensity: 0.6)
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
            let keys = TypingLayout.place(rows, in: geo.size, metrics: KeyMetrics.forSize(geo.size, rows: rows.count))
            ZStack(alignment: .topLeading) {
                ForEach(keys) { k in
                    KeyCap(kind: k.kind, typing: typing, pressed: typing.pressed[k.id] != nil)
                        .frame(width: k.frame.width, height: k.frame.height)
                        .position(x: k.frame.midX, y: k.frame.midY)
                }
                if showsPopups {
                    ForEach(keys.filter { typing.pressed[$0.id] != nil && $0.kind.isCharacter }) { k in
                        KeyPopup(kind: k.kind, typing: typing, keyFrame: k.frame, areaWidth: geo.size.width)
                    }
                }
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
                                                          returnKind: typing.returnKind, returnEnabled: typing.returnEnabled))
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
            model?.touchBegan(ObjectIdentifier(t), on: key)
        }
        if globe { forwardGlobe(event) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var globe = false
        for t in touches {
            let id = ObjectIdentifier(t)
            if globeTouches.contains(id) { globe = true; continue }
            let key = TypingLayout.hit(t.location(in: self), in: keys)
            model?.touchMoved(id, to: key)
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
        elements = keys.map { key in
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
