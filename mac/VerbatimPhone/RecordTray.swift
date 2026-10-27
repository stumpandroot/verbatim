import SwiftUI
import UIKit

// Record as (approved mockup "Record as", October 26, 2026; DESIGN.md §17.6): touching and holding Record opens
// Verbose's own tray instead of the system's context menu, after the trays in Family. It rises from the bottom and
// covers the tab bar; slide your finger to a kind and lift to start it, or lift without sliding and tap one. The same
// tray opens from Home's Record card (both Verbose sizes and Premium Native's card) and from Premium Native's floating
// record button, which adds Dictate, Live captions, and Import under the kinds.
//
// The kinds, their order, their names, and the line under each come from `RecordChoice` (Model/Templates.swift); the
// gesture's decisions from `RecordTrayRules`, which the Linux tests check (mac/tools/test-templates.sh).
//
// Motion: the tray opens on a critically damped spring (280 ms, no bounce), the highlight jumps to the row under your
// finger with no animation (a high-frequency action), and the tray leaves in 200 ms, ease-out. Limit animation
// crossfades it instead. Haptics: a light impact on open, a selection tick on each new row, and the recorder's own
// Record haptic when a row starts; like every haptic in Verbose they go through `Haptics` (PhoneMotion.swift), so
// Settings › Personalization and preferences › Haptics turns them off, and they follow the iPhone's System Haptics.

// MARK: - The tray's state

/// What the press is doing: just touched (the card presses in), held past 0.4 s (the tray is open), or nothing.
enum RecordPressPhase: Equatable { case idle, pressing, held }

@MainActor
final class RecordTray: ObservableObject {
    static let shared = RecordTray()

    /// Where the tray was opened from: Home's Record card, or the floating record button on a tab (which adds Dictate,
    /// Live captions, and Import, and sits the tray above the button).
    enum Source: Equatable {
        case card
        case floating(PhoneState.Tab)
        var isFloating: Bool { if case .floating = self { return true } else { return false } }
    }

    @Published private(set) var isOpen = false
    @Published private(set) var source: Source = .card
    /// The row under the finger, drawn as the selected row with the record disc.
    @Published private(set) var highlighted: RecordChoice? = nil
    /// The floating button's frame when the tray opened from it, so the layer draws it lit above the scrim.
    @Published private(set) var buttonFrame: CGRect = .zero

    /// The finger that opened the tray is still down.
    private(set) var fingerDown = false
    /// The finger has moved more than 10 pt since the tray opened (`RecordTrayRules.slid`).
    private(set) var slid = false
    private var origin: CGPoint? = nil
    /// This press brought a running recording back instead of opening the tray (once per press).
    private var reopened = false

    /// Each row's frame and the list's visible band, in global coordinates (reported by the layer, never published).
    var rowFrames: [RecordChoice: CGRect] = [:]
    var listFrame: CGRect = .zero
    /// The floating buttons' frames by tab, kept current by their press modifier (never published).
    var floatingFrames: [PhoneState.Tab: CGRect] = [:]

    weak var app: PhoneState?
    /// The self-test records what a choice would start instead of starting it.
    var override: ((RecordChoice) -> Void)? = nil

    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()

    /// On touch down: the haptics are ready by the time the hold completes.
    func prepare() {
        Haptics.prepare(impact)
        Haptics.prepare(selection)
    }

    /// The hold completed: open the tray, with the finger still down. While a recording runs, Record brings it back
    /// instead (as a tap does), so there's never a tray of kinds that can't start.
    func open(_ source: Source, from frame: CGRect = .zero) {
        if let app, app.recordingActive || app.savingRecording {
            if !reopened { reopened = true; app.requestRecord() }
            return
        }
        self.source = source
        if case .floating(let tab) = source { buttonFrame = floatingFrames[tab] ?? frame } else { buttonFrame = frame }
        highlighted = nil
        fingerDown = true
        slid = false
        origin = nil
        isOpen = true
        Haptics.impact(impact)
        // VoiceOver: the tray is a modal; move focus into it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    }

    /// The finger moved (global coordinates). Once it has slid, the row under it lights up, with no animation.
    func move(to p: CGPoint) {
        guard isOpen, fingerDown else { return }
        guard let o = origin else { origin = p; return }
        if !slid { slid = RecordTrayRules.slid(dx: Double(p.x - o.x), dy: Double(p.y - o.y)) }
        guard slid else { return }
        let row = self.row(at: p)
        guard row != highlighted else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { highlighted = row }
        if row != nil { Haptics.selection(selection); Haptics.prepare(selection) }
    }

    /// The finger lifted where the drag ended: start the row under it, or keep the tray open for a tap.
    func lift(at p: CGPoint?) {
        reopened = false
        guard fingerDown else { return }
        fingerDown = false
        let over = p.map { row(at: $0) } ?? highlighted
        switch RecordTrayRules.lift(opened: isOpen, slid: slid, over: over) {
        case .start(let c): choose(c)
        case .keepOpen, .plainRecord:
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { highlighted = nil }
        }
    }

    /// The press ended without a drag ending (no movement after the hold, or the system took the touch): the tray stays
    /// open for a tap, nothing highlighted.
    func fingerLifted() {
        reopened = false
        guard fingerDown else { return }
        fingerDown = false
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { highlighted = nil }
    }

    /// A tap on Record (lifted before the hold): the plain Record.
    func tap() {
        if case .plainRecord = RecordTrayRules.lift(opened: false, slid: false, over: nil) { perform(.voiceNote) }
    }

    /// A row was chosen (lifted on, or tapped): the tray leaves and the choice starts.
    func choose(_ c: RecordChoice) {
        close()
        perform(c)
    }

    /// Tap outside, the close button, a swipe down, or VoiceOver's escape. Never while the opening finger is down.
    func close() {
        guard isOpen else { return }
        fingerDown = false
        isOpen = false
        highlighted = nil
    }

    func perform(_ c: RecordChoice) {
        if let override { override(c); return }
        app?.startRecordChoice(c)
    }

    private func row(at p: CGPoint) -> RecordChoice? {
        let rows = rowFrames.map { ($0.key, minX: Double($0.value.minX), minY: Double($0.value.minY), maxX: Double($0.value.maxX), maxY: Double($0.value.maxY)) }
        let band = listFrame == .zero ? (-Double.infinity, Double.infinity) : (Double(listFrame.minY), Double(listFrame.maxY))
        return RecordTrayRules.row(atY: Double(p.y), x: Double(p.x), rows: rows, visibleMinY: band.0, visibleMaxY: band.1)
    }

    // MARK: Self-test

    /// The self-test's stand-in for a finger: the hold completes on `source`.
    func tourHold(_ source: Source) { open(source) }
    /// The self-test slides the finger from the first row to `choice`'s row and returns where it ended.
    @discardableResult
    func tourSlide(to choice: RecordChoice) -> CGPoint? {
        guard let start = rowFrames[.voiceNote], let end = rowFrames[choice] else { return nil }
        move(to: CGPoint(x: start.midX, y: start.minY - 40))
        let p = CGPoint(x: end.midX, y: end.midY)
        move(to: p)
        return p
    }
}

extension PhoneState {
    /// One of Record as's six choices, from the tray or VoiceOver's actions on Record: Voice note is the plain Record,
    /// a kind records as yours (AutoLabel leaves it; Run automatically uses it), and Thought starts New thought (Stop &
    /// add, today's page). The recorder then slides in 12 pt over 150 ms, opaque from its first frame.
    func startRecordChoice(_ choice: RecordChoice) {
        if !recordingActive { recorderSlideIn = true }
        switch choice {
        case .voiceNote: requestRecord()
        case .kind(let k): requestRecord(kind: k)
        case .thought: requestThought()
        }
    }

    /// What the recording running was started as, for the recorder's chip and the line under its timer.
    var recordingChoice: RecordChoice {
        if recordingThought { return .thought }
        if let k = recordKind { return .kind(k) }
        return .voiceNote
    }
}

extension RecordChoice {
    /// Verbose style's fine-line glyph (the Mac menus' custom symbols are made from the same ones).
    var art: BrandArt {
        switch self {
        case .voiceNote: return .iconMic
        case .kind(.meeting): return .iconSpeakers
        case .kind(.interview): return .iconQuote
        case .kind(.journal): return .iconNotes
        case .kind(.talk): return .iconVoice
        case .kind: return .iconMic
        case .thought: return .iconThought
        }
    }
}

// MARK: - The press on Record

extension View {
    /// Touch and hold opens the Record as tray; a tap (lifted sooner) runs `tap`. `onPhase` reports the press so the
    /// card can press in and listen to the mic. Moving more than 10 pt before the hold lets the scroll view have it.
    func recordTrayPress(_ source: RecordTray.Source, onPhase: @escaping (RecordPressPhase) -> Void = { _ in },
                         tap: @escaping () -> Void) -> some View {
        modifier(RecordTrayPress(source: source, onPhase: onPhase, tap: tap))
    }

    /// VoiceOver's named actions on Record, one for each way to record, so a kind can be picked from the actions rotor
    /// without opening the tray.
    func recordChoiceActions(_ app: PhoneState) -> some View {
        accessibilityActions {
            ForEach(RecordChoice.all) { c in
                Button(c.actionName) { app.startRecordChoice(c) }
            }
        }
    }

    /// Record as one button for VoiceOver: activating it is the plain Record, the actions rotor has each way to
    /// record, and a double-tap and hold opens the tray as a modal.
    func recordCardAccessibility(_ app: PhoneState, value: String = "", id: String,
                                 hint: String = "Starts a voice note. Touch and hold to record a meeting, an interview, a journal entry, a talk, or a thought.",
                                 before: @escaping () -> Void = {}) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Record")
            .accessibilityValue(value)
            .accessibilityHint(hint)
            .accessibilityAction { before(); RecordTray.shared.tap() }
            .recordChoiceActions(app)
            .accessibilityIdentifier(id)
    }
}

/// Holds a frame without publishing it, so a card scrolling doesn't redraw itself each frame.
private final class FrameBox { var frame: CGRect = .zero }

private struct RecordTrayPress: ViewModifier {
    var source: RecordTray.Source
    var onPhase: (RecordPressPhase) -> Void
    var tap: () -> Void
    @GestureState private var phase: RecordPressPhase = .idle
    @State private var box = FrameBox()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { remember($0) }
            .gesture(press)
            .onChange(of: phase) { old, new in
                onPhase(new)
                let tray = RecordTray.shared
                switch new {
                case .pressing: tray.prepare()
                case .held: if !tray.fingerDown { tray.open(source, from: box.frame) }
                case .idle:
                    // After the drag's own end (same event), so a lift on a row isn't taken for a lift in place.
                    if old == .held { DispatchQueue.main.async { tray.fingerLifted() } }
                }
            }
    }

    private func remember(_ f: CGRect) {
        box.frame = f
        if case .floating(let tab) = source { RecordTray.shared.floatingFrames[tab] = f }
    }

    private var press: some Gesture {
        LongPressGesture(minimumDuration: RecordTrayRules.hold, maximumDistance: CGFloat(RecordTrayRules.cancelDistance))
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($phase) { value, state, _ in
                switch value {
                case .first(true): state = .pressing
                case .second(true, _): state = .held
                default: state = .idle
                }
            }
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                let tray = RecordTray.shared
                if !tray.fingerDown && !tray.isOpen { tray.open(source, from: box.frame) }
                tray.move(to: drag.location)
            }
            .onEnded { value in
                guard case .second(true, let drag) = value else { return }
                RecordTray.shared.lift(at: drag?.location)
            }
            .exclusively(before: TapGesture().onEnded { tap() })
    }
}

// MARK: - The tray

/// The tray over everything, the tab bar included: the scrim, the tray in the look, and (from the floating button)
/// the button kept lit above the scrim. Put once at the root, above the tab view.
struct RecordTrayLayer: View {
    @EnvironmentObject var app: PhoneState
    @ObservedObject private var tray = RecordTray.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @Environment(\.look) private var look
    @Environment(\.limitMotion) private var limitMotion
    /// How far a swipe down has pulled the tray.
    @State private var pull: CGFloat = 0
    @State private var trayHeight: CGFloat = 0

    private var openAnimation: Animation { limitMotion ? Motion.fade : .spring(duration: 0.28, bounce: 0) }
    private var closeAnimation: Animation { .easeOut(duration: 0.2) }

    var body: some View {
        GeometryReader { g in
            let global = g.frame(in: .global)
            ZStack(alignment: .bottom) {
                if tray.isOpen {
                    scrim
                        .transition(.opacity)
                    if tray.source.isFloating && tray.buttonFrame != .zero {
                        litButton(in: global)
                    }
                    panel(maxHeight: g.size.height * CGFloat(RecordTrayRules.maxHeightShare))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trayHeight = $0 }
                        .offset(y: max(0, pull))
                        .padding(.bottom, bottomGap(in: global))
                        .transition(limitMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
        .animation(tray.isOpen ? openAnimation : closeAnimation, value: tray.isOpen)
        .allowsHitTesting(tray.isOpen)
        .onAppear { tray.app = app }
        .onChange(of: tray.isOpen) { _, open in if !open { pull = 0 } }
    }

    /// The gap under the tray: just above the home indicator from the card, so it covers the tab bar; above the
    /// floating button from it, so your thumb slides up from the button through the rows.
    private func bottomGap(in global: CGRect) -> CGFloat {
        guard tray.source.isFloating, tray.buttonFrame != .zero else { return look.isNative ? 6 : 12 }
        return max(12, global.maxY - tray.buttonFrame.minY + 14)
    }

    @ViewBuilder private var scrim: some View {
        Group {
            if look.isNative {
                Color.black.opacity(0.38)   // brand: native
            } else {
                Ink.inkFixed.opacity(0.32)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { if !tray.fingerDown { tray.close() } }
        .accessibilityHidden(true)
    }

    /// The floating button, lit above the dimmed screen while the tray it opened is up.
    private func litButton(in global: CGRect) -> some View {
        let f = tray.buttonFrame
        return NativeRecordDisc(size: 64)   // brand: native
            .position(x: f.midX - global.minX, y: f.midY - global.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: The panel

    @ViewBuilder private func panel(maxHeight: CGFloat) -> some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            if look.isNative { grabber }
            header
                .contentShape(Rectangle())
                .gesture(dismissDrag)
            rows(maxHeight: maxHeight)
            if look.isNative, case .floating(let tab) = tray.source { footer(tab) }
        }
        if look.isNative {
            NativeTrayFace(content: content)
        } else {
            VerboseTrayFace(content: content)
        }
    }

    private var grabber: some View {
        Capsule().fill(NativeInk.tertiary)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .gesture(dismissDrag)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: look.isNative ? 2 : 4) {
                Group {
                    if look.isNative {
                        Text("Record as").font(.title3.bold()).foregroundStyle(NativeInk.label)
                    } else {
                        (Text("Record ") + Text("as").italic()).font(Ink.serif(serifTitle)).foregroundStyle(Ink.ink)
                    }
                }
                .accessibilityAddTraits(.isHeader)
                Text("Verbose files it under this kind and runs its template.")
                    .font(.system(size: look.isNative ? subNative : subVerbose))
                    .foregroundStyle(look.isNative ? NativeInk.secondary : Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { tray.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: look.isNative ? 12 : 13, weight: .bold))
                    .foregroundStyle(look.isNative ? NativeInk.secondary : Ink.ink)
                    .frame(width: look.isNative ? 30 : 34, height: look.isNative ? 30 : 34)
                    .background { closeBackground }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -6).padding(.trailing, -6)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 8).padding(.trailing, 6)
        .padding(.top, look.isNative ? 4 : 0).padding(.bottom, 12)
    }

    @ViewBuilder private var closeBackground: some View {
        if look.isNative {
            Circle().fill(NativeInk.fill)
        } else {
            Circle().strokeBorder(Ink.ink, lineWidth: 1.5)
        }
    }

    @ScaledMetric(relativeTo: .title) private var serifTitle: CGFloat = 27
    @ScaledMetric(relativeTo: .subheadline) private var subVerbose: CGFloat = 13.5
    @ScaledMetric(relativeTo: .subheadline) private var subNative: CGFloat = 14

    /// The rows; when they're taller than the room (80% of the screen, less the header), they scroll and the header stays.
    @ViewBuilder private func rows(maxHeight: CGFloat) -> some View {
        let list = VStack(spacing: 0) {
            ForEach(Array(RecordChoice.all.enumerated()), id: \.element) { i, c in
                TrayRow(choice: c, first: i == 0, highlighted: tray.highlighted == c,
                        neighborHighlighted: i > 0 && tray.highlighted == RecordChoice.all[i - 1],
                        hint: c.hint(settings: auto.settings, templates: app.store.allTemplates)) { tray.choose(c) }
            }
        }
        let room = max(160, maxHeight - 120)
        ViewThatFits(in: .vertical) {
            listBox(list, scrolls: false)
            ScrollView { listBox(list, scrolls: true) }.frame(maxHeight: room)
        }
        .frame(maxHeight: room)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tray.listFrame = $0 }
    }

    @ViewBuilder private func listBox<L: View>(_ list: L, scrolls: Bool) -> some View {
        if look.isNative {
            list
                .background(NativeInk.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .gesture(dismissDrag, including: scrolls ? .subviews : .all)
        } else {
            list.gesture(dismissDrag, including: scrolls ? .subviews : .all)
        }
    }

    /// Swipe down to close: past a third of the tray's height, or a fast flick. A shorter drag springs back.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard !tray.fingerDown else { return }
                pull = max(0, v.translation.height)
            }
            .onEnded { v in
                guard !tray.fingerDown else { return }
                if RecordTrayRules.dismisses(translation: Double(v.translation.height), predicted: Double(v.predictedEndTranslation.height),
                                             height: Double(max(trayHeight, 1))) {
                    tray.close()
                } else {
                    withAnimation(limitMotion ? Motion.fade : .spring(duration: 0.28, bounce: 0)) { pull = 0 }
                }
            }
    }

    // MARK: The floating button's extras

    // brand: native begin
    /// Dictate, Live captions, and Import, which the floating button's menu held, as a row of three under the kinds.
    /// They open their own screens; they don't record.
    private func footer(_ tab: PhoneState.Tab) -> some View {
        HStack(spacing: 8) {
            footerButton("Dictate", symbol: "text.bubble") {
                tray.close()
                if tab == .library { app.libraryPath.append(DictationsRoute()) } else { app.homePath.append(DictationsRoute()) }
            }
            footerButton("Live captions", symbol: "captions.bubble") { tray.close(); app.requestCaptions() }
            Menu {
                Button { tray.close(); app.showPhotoPicker = true } label: { Label("Choose from Photos", systemImage: "photo") }
                Button { tray.close(); app.showImporter = true } label: { Label("Choose files…", systemImage: "folder") }
                Button { tray.close(); app.showLinkSheet = true } label: { Label("Paste a link", systemImage: "link") }
            } label: { footerFace("Import", symbol: "square.and.arrow.down") }
            .accessibilityLabel("Import")
        }
        .padding(.top, 8)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { footerFace(title, symbol: symbol) }
            .buttonStyle(PhoneCardPress())
            .accessibilityLabel(title)
    }

    private func footerFace(_ title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(NativeInk.label)
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(NativeInk.label).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(NativeInk.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    // brand: native end
}

/// Verbose style: an opaque paper tray with the ink outline, the (6, 7) hard shadow, and the panel radius. No grain:
/// grain never goes on paper (DESIGN.md §5.5).
private struct VerboseTrayFace<Content: View>: View {
    var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        content
            .padding(.top, 14).padding(.horizontal, 10).padding(.bottom, 10)
            .background(Ink.paper, in: shape)
            .overlay(shape.strokeBorder(Ink.ink, lineWidth: 1.5))
            .background(shape.fill(PhoneInk.hard).offset(x: 6, y: 7))
            .padding(.leading, 10).padding(.trailing, 16)
            .modalTray()
    }
}

// brand: native begin
/// Premium Native: a system material sheet with a grabber; the rows sit on an opaque card, so only the title is on
/// glass (DESIGN.md §13.5). Reduce Transparency makes the sheet opaque.
private struct NativeTrayFace<Content: View>: View {
    var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        content
            .padding(.top, 8).padding(.horizontal, 10).padding(.bottom, 10)
            .background {
                if reduceTransparency { shape.fill(NativeInk.paper) } else { shape.fill(.regularMaterial) }
            }
            .padding(.horizontal, 8)
            .modalTray()
    }
}
// brand: native end

private extension View {
    /// The tray is a modal for VoiceOver: focus stays in it, and the escape gesture closes it.
    func modalTray() -> some View {
        accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel("Record as")
            .accessibilityAction(.escape) { RecordTray.shared.close() }
    }
}

/// One way to record: the kind's icon, its name, and what happens. Verbose style: the serif name with an italic last
/// word; under the finger, the selected-row card (§11) with the record disc. Native: SF Symbols in the label color
/// on a gray chip and the system highlight, with Premium's persimmon disc. Persimmon only ever appears as that disc.
private struct TrayRow: View {
    var choice: RecordChoice
    var first: Bool
    var highlighted: Bool
    var neighborHighlighted: Bool
    var hint: String
    var action: () -> Void
    @Environment(\.look) private var look
    @ScaledMetric(relativeTo: .title3) private var nameSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var nativeName: CGFloat = 17
    @ScaledMetric(relativeTo: .footnote) private var hintSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var chip: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 60

    var body: some View {
        Button(action: action) {
            if look.isNative { native } else { verbose }
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { RecordTray.shared.rowFrames[choice] = $0 }
        .accessibilityLabel(choice.name)
        .accessibilityHint(hint)
        .accessibilityIdentifier("recordtray.\(choice.id)")
    }

    private var verbose: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        let (lead, italic) = choice.serifParts
        return HStack(spacing: 12) {
            IconGlyph(art: choice.art, size: chip * 0.53, color: Ink.ink)
                .frame(width: chip, height: chip)
                .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                (Text(lead) + (italic.map { Text($0).italic() } ?? Text("")))
                    .font(Ink.serif(nameSize)).foregroundStyle(Ink.ink)
                Text(hint).font(.system(size: hintSize)).foregroundStyle(Ink.mute)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Circle().fill(Ink.inkFixed)
                Circle().fill(PhoneInk.record).frame(width: 12, height: 12)
            }
            .frame(width: 34, height: 34)
            .opacity(highlighted ? 1 : 0)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(minHeight: rowHeight)
        .background {
            if highlighted {
                shape.fill(Ink.card)
                    .overlay(shape.strokeBorder(Ink.ink, lineWidth: 1.5))
                    .background(shape.fill(PhoneInk.hard).offset(x: 4, y: 5))
            }
        }
        .overlay(alignment: .top) {
            if !first && !highlighted && !neighborHighlighted {
                Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, chip + 20).padding(.trailing, 8)
            }
        }
        .zIndex(highlighted ? 1 : 0)
        .contentShape(shape)
    }

    // brand: native begin
    private var native: some View {
        HStack(spacing: 12) {
            Image(systemName: choice.nativeSymbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(NativeInk.label)
                .frame(width: 32, height: 32)
                .background(NativeInk.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(choice.name).font(.system(size: nativeName)).foregroundStyle(NativeInk.label)
                Text(hint).font(.system(size: hintSize)).foregroundStyle(NativeInk.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 8)
        .frame(minHeight: rowHeight)
        .background(highlighted ? NativeInk.fillStrong : Color.clear)
        .overlay(alignment: .top) {
            if !first && !highlighted && !neighborHighlighted {
                Rectangle().fill(NativeInk.separator).frame(height: 0.5).padding(.leading, 58)
            }
        }
        .contentShape(Rectangle())
    }
    // brand: native end
}

// MARK: - The recorder's kind

/// The recorder's header in Verbose style: a neutral chip with the kind's glyph and name, in place of "Voice note"
/// (ink at 6%, like every kind, §1; the persimmon panel and Stop stay the screen's one record color).
struct RecordKindChip: View {
    var choice: RecordChoice
    var body: some View {
        HStack(spacing: 6) {
            IconGlyph(art: choice.art, size: 17, color: Ink.ink).accessibilityHidden(true)
            Text(choice.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
        }
        .padding(.leading, 7).padding(.trailing, 11)
        .frame(minHeight: 30)
        .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(Ink.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording as \(choice.name)")
    }
}

// brand: native begin
/// Premium Native's recorder: a gray capsule with the kind's symbol under the clock.
struct NativeRecordKindChip: View {
    var choice: RecordChoice
    var body: some View {
        HStack(spacing: 7) {
            if choice != .voiceNote { Image(systemName: choice.nativeSymbol).font(.system(size: 15, weight: .medium)) }
            Text(choice.name).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(NativeInk.label)
        .padding(.leading, choice == .voiceNote ? 15 : 11).padding(.trailing, 15)
        .frame(minHeight: 34)
        .background(NativeInk.fill, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording as \(choice.name)")
    }
}
// brand: native end
