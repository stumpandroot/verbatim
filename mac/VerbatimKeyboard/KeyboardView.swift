import SwiftUI
import UIKit

/// The keyboard's palette: paper in light (the approved mockup), ink in dark. Each color follows the keyboard's
/// appearance, which `KeyboardViewController` sets from the host app (`keyboardAppearance`, else its light or dark
/// mode). Dark: ink background (#1C2A24), paper text, persimmon marks, cards #22322B.
enum KB {
    static let uiPaper = dynamic(0xF5F0E6, 0x1C2A24)
    static let uiInk = dynamic(0x26352E, 0xF5F0E6)

    static let paper = Color(uiColor: uiPaper)
    static let ink = Color(uiColor: uiInk)
    static let persimmon = Color(hex: 0xFA6B47)
    static let card = Color(uiColor: dynamic(0xFFFDF9, 0x22322B))
    /// Notices (a failure, Full Access): deep persimmon on paper, a lighter one on ink.
    static let deep = Color(uiColor: dynamic(0xB23F24, 0xFF9473))
    static let muted = Color(uiColor: dynamic(0x5F6A62, 0xAEB6AD))
    static let hairline = Color(uiColor: dynamic(0x26352E, 0xF5F0E6, alpha: 0.14))
    /// Ink in both appearances: the glyph on the persimmon record button.
    static let inkFixed = Color(hex: 0x26352E)

    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor { t in (t.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)).withAlphaComponent(alpha) }
    }

    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

/// Voice-first: no letter keys. A top strip for status, one big card for the action, and a bottom row with
/// globe, space, delete, and return.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    private var busy: Bool { model.stage == .listening || model.stage == .writing || model.stage == .starting }

    var body: some View {
        VStack(spacing: 8) {
            topStrip.frame(height: 30)
            card.frame(maxHeight: .infinity)
            if let c = model.correction {
                correctionStrip(c)
            } else if let n = model.notice {
                Text(n).font(.system(size: 12)).foregroundStyle(KB.deep)
                    .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.updatesFrequently)
            } else if let i = model.info {
                Text(i).font(.system(size: 12, weight: .medium)).foregroundStyle(KB.muted)
                    .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            bottomRow.frame(height: 44)
                .opacity(busy ? 0.4 : 1)
                .disabled(busy)
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
        .background(KB.paper)
    }

    /// After a spoken correction changed the inserted words: what changed, Use as spoken, and Turn off.
    private func correctionStrip(_ summary: String) -> some View {
        HStack(spacing: 6) {
            Text(summary).font(.system(size: 12)).foregroundStyle(KB.ink)
                .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Chip(title: "Use as spoken") { model.useAsSpoken() }
                .accessibilityHint("Replaces the corrected words with the words as you said them")
            Chip(title: "Turn off") { model.turnOffSpokenCorrections() }
                .accessibilityHint("Stops Verbatim from acting on spoken corrections")
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
    }

    // MARK: Top strip

    @ViewBuilder private var topStrip: some View {
        HStack(spacing: 8) {
            switch model.stage {
            case .listening, .starting, .writing:
                RingsMark(color: KB.persimmon).frame(width: 15, height: 15)
                Text(stripLabel).font(KB.mono(11)).tracking(1.3).foregroundStyle(KB.ink).lineLimit(1)
                    .accessibilityLabel(stripAccessibility)
                Spacer(minLength: 6)
                if model.stage == .starting {
                    Chip(title: "Cancel") { model.cancel() }
                        .accessibilityHint("Stops waiting for Verbatim")
                }
            case .inserted:
                if model.polishing {
                    // Polish after inserting: a soft pulse while the cleaned-up version is on its way.
                    PolishingMark()
                    Text("POLISHING…")
                        .font(KB.mono(11)).tracking(1.3).foregroundStyle(KB.muted).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityLabel("Inserted. Polishing your words")
                } else {
                    SessionDot(on: model.sessionLive)
                    Text("INSERTED · \(model.insertion?.words ?? 0) \((model.insertion?.words ?? 0) == 1 ? "WORD" : "WORDS")")
                        .font(KB.mono(11)).tracking(1.3).foregroundStyle(KB.ink).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
                Chip(title: "Undo") { model.undo() }
                    .accessibilityHint("Removes the inserted words")
                if let ins = model.insertion, ins.raw != ins.text, !ins.raw.isEmpty {
                    Chip(title: "Use as spoken") { model.useAsSpoken() }
                        .accessibilityHint("Replaces the cleaned-up words with the words as you said them")
                }
                if !model.snippets.isEmpty {
                    IconChip(systemName: "text.quote") { model.toggleSnippets() }
                        .accessibilityLabel("Snippets")
                        .accessibilityHint("Shows your snippets to insert")
                }
                recentButton
            case .idle:
                if model.showingSnippets {
                    snippetRow
                } else if model.showingRecent {
                    recentRow
                } else {
                    idleStrip
                }
            }
        }
        .padding(.horizontal, 6)
    }

    /// Idle: the session, the cleanup level, and the Snippets chip when you have snippets.
    @ViewBuilder private var idleStrip: some View {
        BarsMark(color: KB.persimmon).frame(width: 14, height: 14)
        Text(sessionLabel).font(KB.mono(11)).tracking(1.3).foregroundStyle(KB.ink).lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityLabel(sessionAccessibility)
        Spacer(minLength: 6)
        Text(model.levelLabel.uppercased()).font(KB.mono(10)).tracking(1.2).foregroundStyle(KB.muted).lineLimit(1)
            .accessibilityLabel("Cleanup: \(model.levelLabel)")
        if !model.snippets.isEmpty {
            Chip(title: "Snippets") { model.toggleSnippets() }
                .accessibilityHint("Shows your snippets to insert")
        }
        recentButton
    }

    /// The clock button: shows your last few dictations in the top strip.
    @ViewBuilder private var recentButton: some View {
        if !model.recent.isEmpty {
            IconChip(systemName: "clock.arrow.circlepath") { model.toggleRecent() }
                .accessibilityLabel("Recent dictations")
                .accessibilityHint("Shows your last dictations to insert again")
        }
    }

    /// Recent dictations in a row that scrolls sideways: tap one to insert it, touch and hold to copy it.
    private var recentRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.recent) { r in
                        RecentChip(text: r.text, insert: { model.insertRecent(r) }, copy: { model.copyRecent(r) })
                    }
                }
            }
            IconChip(systemName: "xmark") { model.toggleRecent() }
                .accessibilityLabel("Close recent dictations")
        }
    }

    /// Snippet triggers in a row that scrolls sideways; tapping one inserts its text. The X closes the row.
    private var snippetRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.snippets) { s in
                        Chip(title: s.trigger) { model.insertSnippet(s) }
                            .accessibilityHint("Inserts your saved text")
                    }
                }
            }
            IconChip(systemName: "xmark") { model.toggleSnippets() }
                .accessibilityLabel("Close snippets")
        }
    }

    /// "SESSION ON · 4:12 LEFT", "SESSION ON", or "TAP TO START A SESSION".
    private var sessionLabel: String {
        guard model.sessionLive else { return "TAP TO START A SESSION" }
        guard let ends = model.sessionEndsAt else { return "SESSION ON" }
        return "SESSION ON · \(Self.clock(ends.timeIntervalSince(model.now))) LEFT"
    }

    private var sessionAccessibility: String {
        guard model.sessionLive else { return "No session. Tap the record button to start one." }
        guard let ends = model.sessionEndsAt else { return "Session on" }
        let m = max(0, Int(ends.timeIntervalSince(model.now)) / 60)
        return m >= 1 ? "Session on, \(m) minutes left" : "Session on, less than a minute left"
    }

    private var stripLabel: String {
        switch model.stage {
        case .starting: return "STARTING A SESSION"
        case .writing: return "WRITING IT DOWN"
        default: return "LISTENING · \(Self.clock(model.elapsed))"
        }
    }

    private var stripAccessibility: String {
        switch model.stage {
        case .starting: return "Starting a session"
        case .writing: return "Writing it down"
        default: return "Listening, \(Int(model.elapsed)) seconds"
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    // MARK: Card

    @ViewBuilder private var card: some View {
        switch model.stage {
        case .idle, .inserted:
            Button { model.record() } label: {
                HStack(spacing: 16) {
                    KeyboardRecordButton(size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recordTitle)
                            .font(.system(size: 24, design: .serif)).foregroundStyle(KB.ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if !model.sessionLive {
                            Text("Verbatim opens for a second, then comes back")
                                .font(.system(size: 12)).foregroundStyle(KB.muted)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KB.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KB.hairline))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressFade())
            .accessibilityLabel(model.sessionLive ? (model.stage == .inserted ? "Keep dictating" : "Dictate") : "Start a session")
            .accessibilityHint(model.sessionLive ? "Starts listening right away" : "Opens Verbatim for a second to turn on the microphone, then comes back here")
        case .starting:
            HStack(spacing: 16) {
                VoiceBars(level: 0, color: KB.persimmon, barWidth: 10, maxHeight: 44).frame(width: 50)
                Text("Opening Verbatim…")
                    .font(.system(size: 24, design: .serif)).foregroundStyle(KB.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KB.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KB.persimmon.opacity(0.55)))
        case .listening, .writing:
            HStack(spacing: 12) {
                RoundKey(systemName: "xmark", filled: false) { model.cancel() }
                    .accessibilityLabel("Cancel")
                    .accessibilityHint("Stops listening and inserts nothing")
                VStack(spacing: 6) {
                    if model.stage == .writing {
                        ProgressView().tint(KB.ink).frame(height: 40).accessibilityLabel("Writing it down")
                    } else {
                        ListeningDots(level: model.level, color: KB.persimmon).frame(height: hasLiveWords ? 28 : 40)
                    }
                    if model.stage == .listening, hasLiveWords {
                        LiveWordsLine(settled: model.liveSettled, volatile: model.liveVolatile, corrections: model.liveCorrections)
                    } else {
                        Text(model.stage == .writing ? "Writing it down…" : "Listening · \(model.micName)")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(KB.muted)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                RoundKey(systemName: "checkmark", filled: true) { model.done() }
                    .disabled(model.stage == .writing)
                    .opacity(model.stage == .writing ? 0.4 : 1)
                    .accessibilityLabel("Done")
                    .accessibilityHint("Stops listening and inserts your words")
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KB.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KB.persimmon.opacity(0.55)))
            .accessibilityElement(children: .contain)
        }
    }

    private var hasLiveWords: Bool { !model.liveSettled.isEmpty || !model.liveVolatile.isEmpty }

    private var recordTitle: String {
        guard model.sessionLive else { return "Tap to start" }
        return model.stage == .inserted ? "Tap to keep going" : "Tap to dictate"
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobe {
                GlobeKey(controller: model.controllerForGlobe)
                    .frame(width: 48)
                    .background(KB.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(KB.hairline))
                    .accessibilityLabel("Next keyboard")
            }
            Key(label: { Text("space").font(.system(size: 15)).foregroundStyle(KB.muted) }, action: model.space)
                .accessibilityLabel("Space")
            RepeatKey(action: model.deleteOne) {
                Image(systemName: "delete.left").font(.system(size: 18, weight: .regular)).foregroundStyle(KB.ink)
            }
            .frame(width: 56)
            .accessibilityLabel("Delete")
            Key(label: { Image(systemName: "return").font(.system(size: 18, weight: .regular)).foregroundStyle(KB.ink) }, action: model.newline)
                .frame(width: 72)
                .accessibilityLabel("Return")
        }
    }
}

// MARK: - Pieces

/// The app's record button: a persimmon circle with the Capture glyph in ink (same as the Mac's RecordButton).
struct KeyboardRecordButton: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(KB.persimmon)
            BrandGlyph(art: .capture, color: KB.inkFixed, minLineWidth: 1.2).padding(size * 0.2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Your words while you talk, as Verbatim's live words hear them: settled words in ink, the newest words (which
/// may still change) lighter. Two lines, the start cut off as it grows. The text swaps in place, with no
/// per-character animation, so words land one by one without shimmer.
private struct LiveWordsLine: View {
    var settled: String
    var volatile: String
    /// Strike out what a spoken correction removes ("scratch that", "at 2, actually 3").
    var corrections = false

    var body: some View {
        let joiner = settled.isEmpty || volatile.isEmpty ? "" : " "
        line(joiner)
            .font(.system(size: 15, design: .serif))
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.center)
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(settled + joiner + volatile)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// Settled words in ink and the newest lighter; with a correction, removed words faded and struck through and
    /// the replacement in ink. Style only, no animation (the line already swaps in place).
    private func line(_ joiner: String) -> Text {
        if corrections {
            let spans = SpokenCorrections.liveSpans(settled + joiner + volatile, limit: 160)
            if spans.contains(where: { $0.style != .kept }) {
                return spans.reduce(Text("")) { t, s in
                    s.style == .removed
                        ? t + Text(s.text).foregroundColor(KB.muted.opacity(0.75)).strikethrough(true, color: KB.muted)
                        : t + Text(s.text).foregroundColor(KB.ink)
                }
            }
        }
        return Text(settled).foregroundColor(KB.ink) + Text(joiner + volatile).foregroundColor(KB.muted)
    }
}

/// The session dot, pulsing softly while Verbatim polishes the inserted text. Still under Reduce Motion.
private struct PolishingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle().fill(KB.persimmon).frame(width: 8, height: 8)
            .opacity(reduceMotion ? 0.7 : (dim ? 0.3 : 1))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// A small persimmon dot in the top strip: filled while a session is on.
private struct SessionDot: View {
    var on: Bool
    var body: some View {
        Circle().fill(on ? KB.persimmon : KB.hairline).frame(width: 8, height: 8)
            .accessibilityLabel(on ? "Session on" : "No session")
    }
}

/// Cancel (X, outlined) and Done (check, ink) on the listening card.
private struct RoundKey: View {
    var systemName: String
    var filled: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(filled ? KB.card : KB.ink)
                .frame(width: 52, height: 52)
                .background(filled ? KB.ink : KB.card, in: Circle())
                .overlay(Circle().strokeBorder(filled ? Color.clear : KB.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(PressFade())
    }
}

/// A row of persimmon dots that rise with the voice level, with a slow travelling wave so the row looks alive
/// even in a quiet room. Under Reduce Motion the dots follow the level only.
private struct ListeningDots: View {
    var level: Double
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let count = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<Self.count, id: \.self) { i in
                    Capsule().fill(color).frame(width: 6, height: height(i, t))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let l = pow(min(1, max(0, level)), 0.6)
        let center = Double(Self.count - 1) / 2
        let shape = 1 - abs(Double(i) - center) / (center + 1)      // taller in the middle
        let wave = reduceMotion ? 0.5 : (sin(t * 5 + Double(i) * 0.8) + 1) / 2
        let idle = 0.12 + 0.08 * wave
        return 6 + CGFloat(max(idle, l * shape * (0.7 + 0.3 * wave))) * 34
    }
}

private struct Chip: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 28)
                .background(KB.card, in: Capsule())
                .overlay(Capsule().strokeBorder(KB.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(title)
    }
}

/// A recent dictation's chip: the start of its text. Tap inserts it; touch and hold copies it.
private struct RecentChip: View {
    var text: String
    var insert: () -> Void
    var copy: () -> Void
    var body: some View {
        Text(Self.label(text)).font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink).lineLimit(1)
            .padding(.horizontal, 12).frame(height: 28)
            .frame(maxWidth: 200)
            .background(KB.card, in: Capsule())
            .overlay(Capsule().strokeBorder(KB.hairline))
            .contentShape(Capsule())
            .onTapGesture(perform: insert)
            .onLongPressGesture(minimumDuration: 0.45, perform: copy)
            .accessibilityElement()
            .accessibilityLabel(String(text.prefix(200)))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Inserts this dictation")
            .accessibilityAction(named: "Copy", copy)
    }

    /// One line of at most 32 characters.
    static func label(_ s: String) -> String {
        let line = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return line.count > 32 ? String(line.prefix(31)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

/// A round chip with a symbol (Snippets, Close).
private struct IconChip: View {
    var systemName: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 12, weight: .semibold)).foregroundStyle(KB.ink)
                .frame(width: 28, height: 28)
                .background(KB.card, in: Circle())
                .overlay(Circle().strokeBorder(KB.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(PressFade())
    }
}

private struct Key<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KB.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(KB.hairline))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressFade())
    }
}

/// Delete: once on touch down, then repeats while held.
private struct RepeatKey<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var pressed = false
    @State private var timer: Timer?

    var body: some View {
        label()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pressed ? KB.hairline : KB.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(KB.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { begin() } }
                .onEnded { _ in end() })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .onDisappear { end() }
    }

    private func begin() {
        pressed = true
        action()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
            Task { @MainActor in
                guard pressed else { return }
                timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in Task { @MainActor in action() } }
            }
        }
    }

    private func end() {
        pressed = false
        timer?.invalidate()
        timer = nil
    }
}

private struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The globe key. A UIKit button so it can hand the touch to `handleInputModeList(from:with:)`, which shows the
/// keyboard list on a long press and moves to the next keyboard on a tap (required for every keyboard).
struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let b = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        b.setImage(UIImage(systemName: "globe", withConfiguration: config), for: .normal)
        b.tintColor = KB.uiInk
        b.accessibilityLabel = "Next keyboard"
        if let controller {
            b.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return b
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
