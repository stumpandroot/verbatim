import SwiftUI
import UIKit

// Record as (approved mockup "Record as", October 26, 2026; DESIGN.md §17.6): touching and holding Record opens
// Verbose's own tray instead of the system's context menu, after the trays in Family. It rises from the bottom and
// covers the tab bar; slide your finger to a kind and lift to start it, or lift without sliding and tap one. It opens
// from Home's Record card (both sizes), drawn with the refined kit (DESIGN.md §13): an opaque
// paper tray, the serif title, and each kind on its colored icon square. The tray over everything is `RecordTrayLayer`,
// put once at the root above the tab view.
//
// The kinds, their order, their names, and the line under each come from `RecordChoice` (Model/Templates.swift); the
// gesture's decisions from `RecordTrayRules`, which the Linux tests check (mac/tools/test-templates.sh).
//
// Motion: the tray opens on a critically damped spring (280 ms, no bounce), and each kind's card follows 90 ms in, 28 ms
// after the one above it, rising 10 pt and fading in over 240 ms (approved mockup "Record As Cards", October 31, 2026);
// nothing waits for it, so a finger can slide to a row while the last ones land. The highlight jumps to the row under
// your finger with no animation (a high-frequency action), and the tray leaves in 200 ms, ease-out. Limit animation
// crossfades the tray and its cards together, with no stagger or movement. Haptics: a light impact on open, a selection tick on each new row, and the recorder's own
// Record haptic when a row starts; like every haptic in Verbose they go through `Haptics` (Haptics.swift), so
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
    /// This press reached the hold (the tray opened, or a running recording came back), so its lift is not a tap.
    private(set) var heldThisPress = false

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

    /// On touch down: a new press, with the haptics ready by the time the hold completes.
    func pressBegan() {
        heldThisPress = false
        prepare()
    }

    /// The haptics are ready by the time the hold completes.
    func prepare() {
        Haptics.prepare(impact)
        Haptics.prepare(selection)
    }

    /// The hold completed: open the tray, with the finger still down. While a recording runs, Record brings it back
    /// instead (as a tap does), so there's never a tray of kinds that can't start.
    func open(_ source: Source, from frame: CGRect = .zero) {
        heldThisPress = true
        if let app, app.recordingActive || app.savingRecording {
            if !reopened { reopened = true; app.requestRecord() }
            return
        }
        self.source = source
        if case .floating(let tab) = source { buttonFrame = floatingFrames[tab] ?? frame } else { buttonFrame = frame }
        // Only the rows on screen this time count (a row hidden since stays out of the slide).
        rowFrames = [:]
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

    /// The finger lifted from Record without moving. It's a tap (run `action`) unless this press reached the hold or
    /// the tray is up; a lift after the hold leaves the tray open for a tap on a row.
    func tapLifted(_ action: () -> Void) {
        let held = heldThisPress
        heldThisPress = false
        guard RecordTrayRules.isTap(held: held, trayOpen: isOpen || fingerDown) else { return }
        action()
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

// MARK: - The press on Record

extension View {
    /// Touch and hold opens the Record as tray; a tap (lifted sooner) runs `tap`. `onPhase` reports the press so the
    /// card can press in and listen to the mic. Moving more than 10 pt before the hold lets the scroll view have it.
    func recordTrayPress(_ source: RecordTray.Source, onPhase: @escaping (RecordPressPhase) -> Void = { _ in },
                         tap: @escaping () -> Void) -> some View {
        modifier(RecordTrayPress(source: source, onPhase: onPhase, tap: tap))
    }

    /// VoiceOver's named actions on Record, one for each way to record that Record as shows (`RecordAsStore`), so a
    /// kind can be picked from the actions rotor without opening the tray.
    func recordChoiceActions(_ app: PhoneState) -> some View {
        modifier(RecordChoiceActions(app: app))
    }

    /// Record as one button for VoiceOver: activating it is the plain Record, the actions rotor has each way to
    /// record, and a double-tap and hold opens the tray as a modal.
    func recordCardAccessibility(_ app: PhoneState, value: String = "", id: String,
                                 hint: String = "Starts a voice note. Touch and hold to choose another way to record.",
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
            // A plain tap gesture, beside the hold rather than behind it: an exclusive tap only ran when the hold
            // failed, and on iPhone a quick tap often never got there, so Record did nothing.
            .onTapGesture { RecordTray.shared.tapLifted(tap) }
            .simultaneousGesture(press)
            .onChange(of: phase) { old, new in
                onPhase(new)
                let tray = RecordTray.shared
                switch new {
                case .pressing: tray.pressBegan()
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
    }
}

// MARK: - The tray

/// VoiceOver's actions on Record, following the rows Record as shows.
private struct RecordChoiceActions: ViewModifier {
    let app: PhoneState
    @ObservedObject private var rows = RecordAsStore.shared
    func body(content: Content) -> some View {
        content.accessibilityActions {
            ForEach(rows.visible) { c in
                Button(c.actionName) { app.startRecordChoice(c) }
            }
        }
    }
}

struct RecordTrayLayer: View {
    @EnvironmentObject var app: PhoneState
    /// The rows you show (consolidation, October 28, 2026: five by default; Edit Record as turns the others on).
    @ObservedObject private var recordAs = RecordAsStore.shared
    @ObservedObject private var tray = RecordTray.shared
    @ObservedObject private var auto = TemplateSettingsModel.shared
    @Environment(\.limitMotion) private var limitMotion
    /// How far a swipe down has pulled the tray.
    @State private var pull: CGFloat = 0
    @State private var trayHeight: CGFloat = 0
    /// The cards have come in (false for the first frame of each opening, so they can rise one after another).
    @State private var cardsIn = false

    private var openAnimation: Animation { limitMotion ? Motion.fade : .spring(duration: 0.28, bounce: 0) }
    private var closeAnimation: Animation { .easeOut(duration: 0.2) }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                if tray.isOpen {
                    scrim
                        .transition(.opacity)
                    panel(maxHeight: g.size.height * CGFloat(RecordTrayRules.maxHeightShare))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trayHeight = $0 }
                        .offset(y: max(0, pull))
                        .padding(.bottom, 8)
                        .transition(limitMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
        .animation(tray.isOpen ? openAnimation : closeAnimation, value: tray.isOpen)
        .allowsHitTesting(tray.isOpen)
        .onAppear { tray.app = app }
        .onChange(of: tray.isOpen) { _, open in
            if !open {
                pull = 0
                // After the tray has left, so the cards don't fade on their own while it goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if !tray.isOpen { cardsIn = false } }
                return
            }
            // The cards start hidden and rise in on the next turn, after the tray is in place.
            cardsIn = limitMotion
            if !limitMotion { DispatchQueue.main.async { cardsIn = true } }
        }
    }

    /// The dimmed screen behind the tray: the fixed ink at 32%, the same in light and dark.
    private var scrim: some View {
        Refined.onFill.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { if !tray.fingerDown { tray.close() } }
            .accessibilityHidden(true)
    }

    // MARK: The panel

    private func panel(maxHeight: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: RefinedPlatform.radius(.record), style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            grabber
            header
                .contentShape(Rectangle())
                .gesture(dismissDrag)
            rows(maxHeight: maxHeight)
            editRow
        }
        .padding(.top, 8).padding(.horizontal, 10).padding(.bottom, 8)
        .refinedSurface(Refined.paper, radius: RefinedPlatform.radius(.record))
        .contentShape(shape)
        .padding(.horizontal, 8)
        .modalTray()
    }

    private var grabber: some View {
        Capsule().fill(Refined.faint)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .gesture(dismissDrag)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Record as").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Verbose files it under this kind and runs its template.")
                    .refinedFont(.meta).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { tray.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Refined.ink)
                    .frame(width: 30, height: 30)
                    .background(Refined.neutral, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -6).padding(.trailing, -6)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.bottom, 12)
    }

    /// Each kind on its own card, 6 pt apart (approved mockup "Record As Cards"). The tray is only as tall as its
    /// cards; when they're taller than the room (80% of the screen, less the header), they scroll and the header stays.
    /// `CappedHeight` keeps a short list from being stretched to the room, which left empty bands above and below it.
    @ViewBuilder private func rows(maxHeight: CGFloat) -> some View {
        let shown = recordAs.visible
        let list = VStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.element) { i, c in
                TrayRow(choice: c, highlighted: tray.highlighted == c,
                        hint: c.hint(settings: auto.settings, templates: app.store.allTemplates)) { tray.choose(c) }
                    .cardEntrance(index: i, shown: cardsIn, limitMotion: limitMotion)
            }
        }
        let room = max(160, maxHeight - 120)
        CappedHeight(max: room) {
            ViewThatFits(in: .vertical) {
                list.gesture(dismissDrag, including: .all)
                ScrollView { list.gesture(dismissDrag, including: .subviews) }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tray.listFrame = $0 }
    }

    /// The tray's foot: Edit Record as, where the rows you hid (Interview, Journal entry, and Talk start hidden) come back.
    private var editRow: some View {
        Button {
            tray.close()
            app.showRecordAsEditor = true
        } label: {
            Text("Edit Record as")
                .refinedFont(.body, weight: .semibold)
                .foregroundStyle(Refined.accentText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose which ways to record show here.")
        .accessibilityIdentifier("tray.editRecordAs")
        .cardEntrance(index: recordAs.visible.count, shown: cardsIn, limitMotion: limitMotion)
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
}

private extension View {
    /// The tray is a modal for VoiceOver: focus stays in it, and the escape gesture closes it.
    func modalTray() -> some View {
        accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel("Record as")
            .accessibilityAction(.escape) { RecordTray.shared.close() }
    }
}

/// One way to record (the refined kit): the kind's glyph on its colored square, its name, and what happens. Under the
/// finger, the persimmon tint with the record disc; persimmon only ever appears as that tint and the disc's red dot.
/// One kind on its own card: the card's off-white, or the persimmon tint with the record disc while your finger is on it.
private struct TrayRow: View {
    var choice: RecordChoice
    var highlighted: Bool
    var hint: String
    var action: () -> Void
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 60

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconSquare(art: choice.art, hue: choice.refinedHue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.name).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(hint).refinedFont(.meta).foregroundStyle(Refined.mute)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AccessoryRecordDisc(size: 32)
                    .opacity(highlighted ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: rowHeight)
            .refinedSurface(highlighted ? Refined.persimmonTint : Refined.card, radius: RefinedPlatform.radius(.card))
            .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { RecordTray.shared.rowFrames[choice] = $0 }
        .accessibilityLabel(choice.name)
        .accessibilityHint(hint)
        .accessibilityIdentifier("recordtray.\(choice.id)")
    }
}

/// Edit Record as (consolidation, October 28, 2026): every way to record with a switch, in Record as's order, so a row
/// you hid comes back. Interview, Journal entry, and Talk start hidden; Voice note always shows. A standard sheet with
/// the system's switches, on paper with the rows in a card (the refined kit).
struct PhoneRecordAsEditor: View {
    @ObservedObject private var rows = RecordAsStore.shared
    @Environment(\.dismiss) private var dismiss
    /// On screen, for the self-test.
    static var visible = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(RecordChoice.all) { c in
                        Toggle(isOn: Binding(get: { rows.rows.isShown(c) }, set: { rows.set(c, shown: $0) })) {
                            HStack(spacing: 12) {
                                IconSquare(art: c.art, hue: c.refinedHue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).refinedFont(.body).foregroundStyle(Refined.ink)
                                    Text(c.fallbackHint).refinedFont(.meta).foregroundStyle(Refined.mute)
                                }
                            }
                        }
                        .refinedSwitchTint()
                        .disabled(!RecordAsRows.canHide(c))
                        .listRowBackground(Refined.card)
                        .listRowSeparatorTint(Refined.separator)
                        .accessibilityIdentifier("recordAs.\(c.id)")
                    }
                } footer: {
                    Text("The ways you turn off stay kinds you can pick with Change kind.").refinedFont(.meta).foregroundStyle(Refined.mute)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Refined.paper.ignoresSafeArea())
            .navigationTitle("Edit Record as")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Refined.accentText)
        .presentationDragIndicator(.visible)
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }
}

// MARK: - Layout and entrance

/// Proposes at most `max` to its content and takes the content's own height, so a short list stays short (a
/// `.frame(maxHeight:)` grows to the max when there's room, which centered the list in empty space).
private struct CappedHeight: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let height = Swift.min(proposal.height ?? max, max)
        return child.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension View {
    /// Record as's cards coming in: 90 ms after the tray starts, 28 ms apart, rising 10 pt and fading in over 240 ms on
    /// a spring with no bounce. With motion limited they're simply there, fading with the tray.
    func cardEntrance(index: Int, shown: Bool, limitMotion: Bool) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(y: shown || limitMotion ? 0 : 10)
            .animation(limitMotion ? nil : .spring(duration: 0.24, bounce: 0).delay(0.09 + 0.028 * Double(index)), value: shown)
    }
}
