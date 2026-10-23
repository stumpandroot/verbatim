import SwiftUI
import UIKit

/// The keyboard's palette: Verbatim's tokens (Tokens.swift is in this target), so it matches the app in light,
/// dark, and Increase Contrast. Each color follows the keyboard's appearance, which `KeyboardViewController` sets
/// from the host app. Dictation is butter (DESIGN.md §1: butter means Dictate); errors are `Ink.danger`.
enum KB {
    /// The panel behind the keyboard, for the controller's own view (it shows before SwiftUI draws).
    static let uiPanel = UIColor { tc in UIColor(Ink.side).resolvedColor(with: tc) }
    static let uiInk = Ink.inkUI

    /// The panel behind the strip, the card, and the keys.
    static let panel = Ink.side
    static let paper = Ink.paper
    static let ink = Ink.ink
    static let card = Ink.card
    /// Notices (a failure).
    static let deep = Ink.danger
    static let muted = Ink.mute
    static let hairline = Ink.hairline
    /// Ink in both appearances: text and outlines on the butter card, which stays butter in dark.
    static let inkFixed = Ink.inkFixed

    // Keyboard-only colors from the keyboard mockup (not in Tokens.swift; defined here, not shared).
    /// The keyboard's one action, dictation: the butter card, the Dictate key, the Done pill, and the listening
    /// ring. Dark is #DDB563, a little lighter than `Ink.butter`'s dark value, so it holds up on the dark panel.
    static let dictate = Ink.dyn(Ink.butterHex, 0xDDB563)
    /// Chips and function keys: one step darker than the panel (`Ink.wash` matches the panel in light).
    static let wash = Ink.dynC(0xE6DFD1, 0x22312A, 0xDCD3C2, 0x2C3C34)
    /// The butter card's hard offset shadow.
    static let hard = Ink.dyn(Ink.inkHex, 0x0C1310)
    /// The listening dot in the strip.
    static let record = Ink.dyn(0xFB7350, 0xE2694B)
    /// A key's 1 pt bottom edge: ink at 25% (50% with Increase Contrast).
    static let keyShadow = Ink.make { dark, hc in
        PColor(hex: dark ? Ink.paperHex : Ink.inkHex).withAlphaComponent(hc ? 0.5 : 0.25)
    }

    /// Keys use a 7 pt radius, like the system keyboard's keys; the big card uses the Record panel's radius.
    static let keyRadius: CGFloat = 7
    static let cardRadius = Radius.record
}

/// Two views behind a compact toggle. Dictation: a top strip for status, one big card for the action, and a
/// bottom row with globe, letter keys, space, delete, and return. Typing: a strip with the Dictate key (and Recent
/// with Full Access) over QWERTY keys. Typing works without Allow Full Access; dictation explains why it needs it.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    private var busy: Bool { model.stage == .listening || model.stage == .writing || model.stage == .starting }

    /// A dictation in progress always shows the dictation view.
    private var showsTyping: Bool { model.surface == .typing && !busy }

    var body: some View {
        Group {
            if showsTyping { typingSurface } else { dictationSurface }
        }
        .background(KB.panel)
    }

    // MARK: Typing

    private var typingSurface: some View {
        VStack(spacing: 0) {
            typingStrip
                .frame(height: 34)
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
            if model.hasFullAccess && model.showingRecent {
                recentCard
                    .padding(.leading, 8).padding(.trailing, 8).padding(.top, 6).padding(.bottom, 8)
                    .frame(maxHeight: .infinity)
            } else {
                TypingKeysView(typing: model.typing)
            }
        }
    }

    /// The butter Dictate key on the left (always there, so you can find dictation); with Full Access, Recent on
    /// the right to insert your last transcript. Without Full Access, Recent is hidden rather than broken.
    private var typingStrip: some View {
        HStack(spacing: 8) {
            if model.hasFullAccess && model.showingRecent {
                listHeader("Recent dictations", closeLabel: "Close recent dictations") { model.toggleRecent() }
            } else {
                DictateKey(fullAccess: model.hasFullAccess) { model.toggleSurface() }
                if let i = model.info {
                    Text(i).font(.system(size: 12, weight: .medium)).foregroundStyle(KB.muted)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                Spacer(minLength: 6)
                if model.hasFullAccess { recentButton }
            }
        }
    }

    // MARK: Dictation

    private var dictationSurface: some View {
        VStack(spacing: 8) {
            topStrip.frame(height: 34)
            mainArea
                .padding(.leading, 2).padding(.trailing, 4).padding(.top, 2).padding(.bottom, 4)
                .frame(maxHeight: .infinity)
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
        .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 4)
    }

    /// The card area: your snippets or recent dictations when you open them, otherwise the big card.
    @ViewBuilder private var mainArea: some View {
        if model.stage == .idle && model.showingSnippets {
            snippetCard
        } else if model.stage == .idle && model.showingRecent {
            recentCard
        } else {
            card
        }
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
                .accessibilityHint("Stops Verbose from acting on spoken corrections")
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: Top strip

    @ViewBuilder private var topStrip: some View {
        HStack(spacing: 8) {
            switch model.stage {
            case .listening, .starting, .writing:
                if model.stage == .listening { RecordDot() }
                Text(stripLabel).font(.system(size: 13.5, weight: .semibold)).monospacedDigit().foregroundStyle(KB.ink).lineLimit(1)
                    .accessibilityLabel(stripAccessibility)
                Spacer(minLength: 6)
                if model.stage == .starting {
                    Chip(title: "Cancel") { model.cancel() }
                        .accessibilityHint("Stops waiting for Verbose")
                } else if model.hasFullAccess {
                    LevelTag(level: model.levelLabel)
                }
            case .inserted:
                if model.polishing {
                    // Polish after inserting: a still, half-lit dot while the cleaned-up version is on its way.
                    PolishingMark()
                    Text("Polishing…")
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(KB.muted).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityLabel("Inserted. Polishing your words")
                } else {
                    CheckDisc()
                    Text("Inserted · \(model.insertion?.words ?? 0) \((model.insertion?.words ?? 0) == 1 ? "word" : "words")")
                        .font(.system(size: 13.5, weight: .semibold)).monospacedDigit().foregroundStyle(KB.ink)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 6)
                Chip(title: "Undo") { model.undo() }
                    .accessibilityHint("Removes the inserted words")
                if let ins = model.insertion, ins.raw != ins.text, !ins.raw.isEmpty {
                    Chip(title: "Use as spoken") { model.useAsSpoken() }
                        .accessibilityHint("Replaces the cleaned-up words with the words as you said them")
                }
                snippetsButton
                recentButton
            case .idle:
                if model.showingSnippets {
                    listHeader("Snippets", closeLabel: "Close snippets") { model.toggleSnippets() }
                } else if model.showingRecent {
                    listHeader("Recent dictations", closeLabel: "Close recent dictations") { model.toggleRecent() }
                } else {
                    idleStrip
                }
            }
        }
        .padding(.horizontal, 4)
    }

    /// Idle: the cleanup level (tap to change the format), the session's time left, Recent, and Snippets.
    @ViewBuilder private var idleStrip: some View {
        if !model.hasFullAccess {
            // No session or cleanup level to show without Full Access.
            BarsMark(color: Ink.persimmon).frame(width: 14, height: 14)
            Ink.wordmark(16).accessibilityHidden(true)
            Spacer(minLength: 6)
        } else {
            CleanupChip(level: model.levelLabel, format: model.formatLabel) { model.cycleFormat() }
            if model.sessionLive, model.sessionEndsAt != nil {
                Text(sessionLabel).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(KB.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityLabel(sessionAccessibility)
            }
            Spacer(minLength: 6)
            recentButton
            snippetsButton
        }
    }

    /// The clock button: shows your last few dictations.
    @ViewBuilder private var recentButton: some View {
        if !model.recent.isEmpty {
            IconButton(art: .iconRecent) { model.toggleRecent() }
                .accessibilityLabel("Recent dictations")
                .accessibilityHint("Shows your last dictations to insert again")
        }
    }

    /// The quote button: shows your snippets.
    @ViewBuilder private var snippetsButton: some View {
        if !model.snippets.isEmpty {
            IconButton(art: .iconQuote) { model.toggleSnippets() }
                .accessibilityLabel("Snippets")
                .accessibilityHint("Shows your snippets to insert")
        }
    }

    /// The strip above an open list: its name and a close button.
    @ViewBuilder private func listHeader(_ title: String, closeLabel: String, close: @escaping () -> Void) -> some View {
        Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(KB.ink).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 6)
        IconButton(symbol: "xmark", action: close)
            .accessibilityLabel(closeLabel)
    }

    /// Time left in the session: "4:12 left".
    private var sessionLabel: String {
        guard let ends = model.sessionEndsAt else { return "" }
        return "\(Self.clock(ends.timeIntervalSince(model.now))) left"
    }

    private var sessionAccessibility: String {
        guard model.sessionLive else {
            return model.needsSessionCard ? "No session" : "No session. Tap the record button to start one."
        }
        guard let ends = model.sessionEndsAt else { return "Session on" }
        let m = max(0, Int(ends.timeIntervalSince(model.now)) / 60)
        return m >= 1 ? "Session on, \(m) minutes left" : "Session on, less than a minute left"
    }

    private var stripLabel: String {
        switch model.stage {
        case .starting: return "Starting a session"
        case .writing: return "Writing it down"
        default: return "Listening · \(Self.clock(model.elapsed))"
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
            if !model.hasFullAccess {
                FullAccessCard()
            } else if model.needsSessionCard {
                StartSessionCard()
            } else {
                dictateCard
            }
        case .starting:
            startingCard
        case .listening, .writing:
            listeningCard
        }
    }

    /// The butter card: dictates at once with a session, or opens Verbose for a second to start one.
    private var dictateCard: some View {
        Button { model.record() } label: {
            CardShell(look: .butter) {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 8) {
                        MicDisc(size: 58)
                        cardTitle
                        cardSubtitle
                    }
                    // A short card (a notice under it): the mic beside the words.
                    HStack(spacing: 14) {
                        MicDisc(size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            cardTitle
                            cardSubtitle
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .contentShape(RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous))
        }
        .buttonStyle(CardPress())
        .accessibilityLabel(model.sessionLive ? (model.stage == .inserted ? "Keep dictating" : "Dictate") : "Start a session")
        .accessibilityHint(model.sessionLive ? "Starts listening right away" : "Opens Verbose for a second to turn on the microphone, then comes back here")
    }

    private var cardTitle: some View {
        let words: (String, String) = !model.sessionLive ? ("Tap to ", "start.")
            : model.stage == .inserted ? ("Keep ", "going?") : ("Tap and ", "talk.")
        return Text("\(Text(words.0))\(Text(words.1).italic())")
            .font(Ink.serif(22)).foregroundStyle(KB.inkFixed)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private var cardSubtitle: some View {
        let line: String
        if !model.sessionLive {
            line = "Verbose opens for a second, then comes back"
        } else if model.stage == .inserted, let note = cleanupNote {
            line = note
        } else {
            line = "Tap again when you're done"
        }
        return Text(line)
            .font(.system(size: 12.5)).foregroundStyle(KB.inkFixed.opacity(0.8))
            .lineLimit(1).minimumScaleFactor(0.8)
    }

    /// What cleanup did to the words just inserted: "3 filler words removed", or the level when it changed
    /// other words. Nil when the words went in as spoken.
    private var cleanupNote: String? {
        guard let ins = model.insertion, !ins.raw.isEmpty, ins.raw != ins.text else { return nil }
        let n = Self.fillerCount(ins.raw) - Self.fillerCount(ins.text)
        if n > 0 { return n == 1 ? "1 filler word removed" : "\(n) filler words removed" }
        return "Cleaned up · \(model.levelLabel)"
    }

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm"]

    static func fillerCount(_ s: String) -> Int {
        s.lowercased().split(whereSeparator: { !$0.isLetter }).filter { fillers.contains(String($0)) }.count
    }

    private var startingCard: some View {
        CardShell(look: .listening) {
            VStack(spacing: 6) {
                Text("Opening Verbose…")
                    .font(Ink.serif(22)).foregroundStyle(KB.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("Verbose opens for a second, then comes back")
                    .font(.system(size: 12.5)).foregroundStyle(KB.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16)
        }
        .accessibilityElement(children: .combine)
    }

    /// Listening: your words in the serif, then Cancel, the voice bars, and Done. Writing keeps the words and
    /// stills the bars while Verbose writes them down.
    private var listeningCard: some View {
        CardShell(look: .listening) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if hasLiveWords {
                        LiveWordsLine(settled: model.liveSettled, volatile: model.liveVolatile,
                                      corrections: model.stage == .listening && model.liveCorrections)
                    } else if model.stage == .writing {
                        Text("Writing it down")
                            .font(Ink.serif(21)).foregroundStyle(KB.muted)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    } else {
                        Text("Listening · \(model.micName)")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(KB.muted)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(spacing: 10) {
                    Button { model.cancel() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(KB.ink)
                            .frame(width: 44, height: 44)
                            .overlay(Circle().strokeBorder(KB.ink, lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressFade())
                    .accessibilityLabel("Cancel")
                    .accessibilityHint("Stops listening and inserts nothing")
                    VoiceWave(level: model.level, active: model.stage == .listening, color: KB.ink)
                        .frame(maxWidth: .infinity).frame(height: 30)
                    Button { model.done() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                            Text("Done").font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(KB.inkFixed)
                        .padding(.horizontal, 18).frame(height: 44)
                        .background(KB.dictate, in: Capsule())
                        .overlay(Capsule().strokeBorder(KB.inkFixed, lineWidth: 1.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressFade())
                    .disabled(model.stage == .writing)
                    .opacity(model.stage == .writing ? 0.4 : 1)
                    .accessibilityLabel("Done")
                    .accessibilityHint("Stops listening and inserts your words")
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        }
        .accessibilityElement(children: .contain)
    }

    private var hasLiveWords: Bool { !model.liveSettled.isEmpty || !model.liveVolatile.isEmpty }

    // MARK: Lists

    /// Your last few dictations: tap one to insert it, touch and hold to copy it.
    private var recentCard: some View {
        ListCard {
            ForEach(Array(model.recent.enumerated()), id: \.element.id) { i, r in
                ListRow(meta: Self.when(r.date), text: r.text, hint: "Inserts this dictation",
                        insert: { model.insertRecent(r) }, copy: { model.copyRecent(r) })
                    .overlay(alignment: .bottom) { if i < model.recent.count - 1 { Rule() } }
            }
        }
    }

    /// Your snippets: tap one to insert its text.
    private var snippetCard: some View {
        ListCard {
            ForEach(Array(model.snippets.enumerated()), id: \.element.id) { i, s in
                ListRow(meta: s.trigger, text: s.expansion, hint: "Inserts your saved text",
                        insert: { model.insertSnippet(s) }, copy: nil)
                    .overlay(alignment: .bottom) { if i < model.snippets.count - 1 { Rule() } }
            }
        }
    }

    /// "10:16 AM" today, "Yesterday · 9:12 AM", or "Oct 20 · 9:12 AM".
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return time }
        if cal.isDateInYesterday(d) { return "Yesterday · \(time)" }
        return "\(d.formatted(.dateTime.month(.abbreviated).day())) · \(time)"
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobe {
                GlobeKey(controller: model.controllerForGlobe)
                    .frame(width: 44)
                    .background(KBKeyFace(fill: KB.wash))
                    .accessibilityLabel("Next keyboard")
            }
            Key(fill: KB.wash, action: model.toggleSurface) {
                Text("ABC").font(.system(size: 15)).foregroundStyle(KB.ink)
            }
            .frame(width: 52)
            .accessibilityLabel("Letter keys")
            .accessibilityHint("Shows the typing keyboard")
            Key(fill: KB.card, action: model.space) {
                Text("space").font(.system(size: 15)).foregroundStyle(KB.muted)
            }
            .accessibilityLabel("Space")
            RepeatKey(fill: KB.wash, action: model.deleteOne) {
                Image(systemName: "delete.left").font(.system(size: 18, weight: .regular)).foregroundStyle(KB.ink)
            }
            .frame(width: 52)
            .accessibilityLabel("Delete")
            Key(fill: KB.ink, action: model.newline) {
                Text("return").font(.system(size: 15, weight: .semibold)).foregroundStyle(KB.paper)
            }
            .frame(width: 76)
            .accessibilityLabel("Return")
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Surfaces

/// A key's face: its fill in a 7 pt rounded rectangle over a 1 pt ink-tinted bottom edge. Shared with the
/// typing keys.
struct KBKeyFace: View {
    var fill: Color
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KB.keyRadius, style: .continuous)
        ZStack {
            shape.fill(KB.keyShadow).offset(y: 1)
            shape.fill(fill)
        }
    }
}

/// Paper grain for the cards: one 128 px tile of ink noise, made once and tiled (64 KB), never redrawn per
/// frame. Off under Increase Contrast and Reduce Transparency.
private enum KBGrain {
    static let tile: CGImage? = {
        let n = 128
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt32 = 0x9E37_79B9
        func next() -> Double {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return Double(seed & 0xFFFF) / 65535
        }
        // Ink (0.15, 0.2, 0.18) at up to 0.55 × 0.32 alpha, as the website's grain; premultiplied.
        for i in 0..<(n * n) {
            let a = (next() + next()) / 2 * 0.55 * 0.32
            bytes[i * 4] = UInt8(0.15 * a * 255)
            bytes[i * 4 + 1] = UInt8(0.20 * a * 255)
            bytes[i * 4 + 2] = UInt8(0.18 * a * 255)
            bytes[i * 4 + 3] = UInt8(a * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

private struct GrainOverlay: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if contrast == .standard, !reduceTransparency, let tile = KBGrain.tile {
            Image(decorative: tile, scale: 2)
                .resizable(resizingMode: .tile)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The big card's three looks: butter at rest (ink outline, hard offset shadow), card color with a butter ring
/// while listening, and card color with an ink outline for notices. All three carry the grain.
private enum CardLook { case butter, listening, notice }

private struct CardShell<Content: View>: View {
    var look: CardLook
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous)
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    shape.fill(look == .butter ? KB.dictate : KB.card)
                    GrainOverlay().clipShape(shape)
                }
            }
            .overlay { border(shape) }
            .background { backing(shape) }
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle) -> some View {
        switch look {
        case .butter: shape.strokeBorder(KB.inkFixed, lineWidth: 1.5)
        case .listening: shape.strokeBorder(KB.dictate, lineWidth: 2)
        case .notice: shape.strokeBorder(KB.ink, lineWidth: 1.5)
        }
    }

    @ViewBuilder private func backing(_ shape: RoundedRectangle) -> some View {
        switch look {
        case .butter:
            shape.fill(KB.hard).offset(x: 3, y: 4)
        case .listening:
            RoundedRectangle(cornerRadius: KB.cardRadius + 2, style: .continuous)
                .fill(KB.dictate.opacity(0.35)).padding(-2)
        case .notice:
            EmptyView()
        }
    }
}

/// The card presses in a little; under Reduce Motion it dims instead.
private struct CardPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.85 : 1)
            .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
    }
}

/// The ink circle on the butter card, with the microphone in butter.
private struct MicDisc: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(KB.inkFixed)
            BrandGlyph(art: .capture, color: KB.dictate, minLineWidth: 1.6)
                .frame(width: size * 0.45, height: size * 0.45)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Cards

/// Dictation without Allow Full Access: why it needs it, and where to turn it on. Inline in the keyboard, not a
/// modal. A keyboard can't open Settings without private API, so the path shows as text.
private struct FullAccessCard: View {
    @State private var showsPath = false

    var body: some View {
        CardShell(look: .notice) {
            ViewThatFits(in: .vertical) {
                content(disc: true)
                content(disc: false)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .accessibilityElement(children: .contain)
    }

    private func content(disc: Bool) -> some View {
        VStack(spacing: 6) {
            if disc {
                ZStack {
                    Circle().fill(KB.wash)
                    IconGlyph(art: .iconPrivacy, size: 22, color: KB.ink)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            }
            Text("\(Text("Dictation needs "))\(Text("Full Access.").italic())")
                .font(Ink.serif(21)).foregroundStyle(KB.ink)
                .multilineTextAlignment(.center)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text("So the Verbose app can pass your words to this keyboard. Typing works without it.")
                .font(.system(size: 12.5)).foregroundStyle(KB.muted)
                .multilineTextAlignment(.center).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            if showsPath {
                Text("Settings › Verbose › Keyboards › Allow Full Access")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.75)
                    .accessibilityLabel("Open Settings, then Verbose, then Keyboards, and turn on Allow Full Access")
            } else {
                DarkPill(title: "Show me where") { showsPath = true }
                    .padding(.top, 2)
                    .accessibilityHint("Shows where to turn on Full Access in Settings")
            }
        }
    }
}

/// App Store builds with no session: the keyboard can't open Verbatim by itself, so this card says how to start
/// a session instead of offering a record button.
private struct StartSessionCard: View {
    var body: some View {
        CardShell(look: .notice) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Ink.butterTint)
                    BrandGlyph(art: .iconDictations, color: Ink.butterText, minLineWidth: 1.2).padding(11)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(Text("Start a session to "))\(Text("dictate.").italic())")
                        .font(Ink.serif(20)).foregroundStyle(KB.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    way("square.grid.2x2", "Open Control Center and tap Verbose")
                    way("button.horizontal.top.press", "Press the Action button, if you set it to Verbose")
                    way("arrow.up.forward.app", "Or open Verbose and tap Start keyboard session")
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }

    private func way(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(KB.ink).frame(width: 16)
            Text(text).font(.system(size: 13)).foregroundStyle(KB.muted).lineLimit(1).minimumScaleFactor(0.75)
        }
    }
}

/// A list in the card's place (recent dictations, snippets): card fill, hairline edge, scrolling rows.
private struct ListCard<Rows: View>: View {
    @ViewBuilder var rows: () -> Rows
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) { rows() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KB.card, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(KB.hairline))
    }
}

/// One row: mono "when" or trigger, one line of text, and an outlined Insert pill. Tap anywhere inserts; with a
/// copy action, touch and hold copies.
private struct ListRow: View {
    var meta: String
    var text: String
    var hint: String
    var insert: () -> Void
    var copy: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta).font(Ink.mono(11.5)).foregroundStyle(KB.muted).lineLimit(1)
                Text(Self.oneLine(text)).font(.system(size: 14.5)).foregroundStyle(KB.ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Insert").font(.system(size: 13, weight: .bold)).foregroundStyle(KB.ink)
                .padding(.horizontal, 11).frame(height: 28)
                .overlay(Capsule().strokeBorder(KB.ink, lineWidth: 1.3))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: insert)
        .onLongPressGesture(minimumDuration: 0.45, perform: { copy?() })
        .accessibilityElement()
        .accessibilityLabel(String(text.prefix(200)))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(hint)
        .accessibilityActions {
            if let copy { Button("Copy", action: copy) }
        }
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

private struct Rule: View {
    var body: some View { Rectangle().fill(KB.hairline).frame(height: 1).accessibilityHidden(true) }
}

// MARK: - Pieces

/// The butter Dictate key in the typing view's strip. With Full Access it shows the dictation view; without it,
/// the dictation view explains Full Access.
private struct DictateKey: View {
    var fullAccess: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                BrandGlyph(art: .capture, color: KB.inkFixed, minLineWidth: 1.3).frame(width: 16, height: 16)
                Text("Dictate").font(.system(size: 13, weight: .bold)).foregroundStyle(KB.inkFixed).lineLimit(1)
            }
            .padding(.leading, 8).padding(.trailing, 12).frame(height: 30)
            .background(KB.dictate, in: Capsule())
            .overlay(Capsule().strokeBorder(KB.inkFixed, lineWidth: 1.3))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel("Dictate")
        .accessibilityHint(fullAccess ? "Shows the dictation view" : "Explains how to turn on dictation")
    }
}

/// The cleanup level as a soft chip ("✦ Polished · Auto ▾"). Tap it to move to the next format; VoiceOver can
/// also swipe up or down on it.
private struct CleanupChip: View {
    var level: String
    var format: String
    var next: () -> Void

    var body: some View {
        Button(action: next) {
            HStack(spacing: 5) {
                IconGlyph(art: .iconAI, size: 14, color: KB.ink)
                Text(level).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink).lineLimit(1)
                Text("· \(format)").font(.system(size: 13, weight: .medium)).foregroundStyle(KB.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(KB.ink)
            }
            .padding(.horizontal, 11).frame(height: 30)
            .background(KB.wash, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
        .buttonStyle(PressFade())
        .accessibilityLabel("Format: \(format)")
        .accessibilityValue("Cleanup: \(level)")
        .accessibilityHint("Changes how Verbose cleans up this dictation: Auto, Email, Message, or Note")
        .accessibilityAdjustableAction { direction in
            if direction == .increment || direction == .decrement { next() }
        }
    }
}

/// The cleanup level while listening: a wash chip, not a control.
private struct LevelTag: View {
    var level: String
    var body: some View {
        Text(level).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink).lineLimit(1)
            .padding(.horizontal, 11).frame(height: 30)
            .background(KB.wash, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .accessibilityLabel("Cleanup: \(level)")
    }
}

/// The listening dot: record color, pulsing slowly; still under Reduce Motion.
private struct RecordDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion {
                dot(1)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 15)) { tl in
                    dot(0.65 + 0.35 * cos(2 * .pi * tl.date.timeIntervalSinceReferenceDate / 1.4))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func dot(_ opacity: Double) -> some View {
        Circle().fill(KB.record).frame(width: 8, height: 8).opacity(opacity)
    }
}

/// The ink check disc beside "Inserted".
private struct CheckDisc: View {
    var body: some View {
        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(KB.paper)
            .frame(width: 18, height: 18)
            .background(KB.ink, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The session dot, half-lit while Verbatim polishes the inserted text (still: nothing loops, DESIGN.md §7).
private struct PolishingMark: View {
    var body: some View {
        Circle().fill(KB.dictate).frame(width: 8, height: 8).opacity(0.6)
            .overlay(Circle().strokeBorder(KB.dictate, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// The voice bars: 26 thin ink bars that move with your voice, flat in a quiet room. The keyboard's only motion;
/// still under Reduce Motion and while Verbose writes your words down. Redrawn at most 30 times a second.
private struct VoiceWave: View {
    var level: Double
    var active: Bool
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let count = 26

    var body: some View {
        Group {
            if active && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                    bars(t: tl.date.timeIntervalSinceReferenceDate, still: false)
                }
            } else {
                bars(t: 0, still: true)
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(t: Double, still: Bool) -> some View {
        let lifted = pow(min(1, max(0, level)), 0.6)
        let color = self.color
        return Canvas { ctx, size in
            let n = Self.count
            let gap = size.width / CGFloat(n)
            let bw = min(4, gap * 0.5)
            for i in 0..<n {
                let v: Double
                if still {
                    v = 0.4
                } else {
                    let x = Double(i)
                    let wave = abs(sin(t * 3.1 + x * 0.55) * cos(t * 1.7 + x * 0.21))
                    v = 0.14 + 0.82 * wave * lifted
                }
                let h = max(bw, CGFloat(v) * size.height)
                let rect = CGRect(x: CGFloat(i) * gap + (gap - bw) / 2, y: (size.height - h) / 2, width: bw, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: .color(color))
            }
        }
    }
}

/// Your words while you talk, as Verbatim's live words hear them: in the serif, the newest two words lighter
/// (they may still change). Up to three lines, the start cut off as it grows. The text swaps in place, with no
/// per-character animation, so words land one by one without shimmer.
private struct LiveWordsLine: View {
    var settled: String
    var volatile: String
    /// Strike out what a spoken correction removes ("scratch that", "at 2, actually 3").
    var corrections = false

    var body: some View {
        let joiner = settled.isEmpty || volatile.isEmpty ? "" : " "
        line(joiner)
            .font(Ink.serif(21))
            .lineSpacing(5)
            .lineLimit(3)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .accessibilityLabel(settled + joiner + volatile)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// Ink, with the newest two words at 45%; with a correction, removed words faded and struck through and the
    /// replacement in ink. Style only, no animation (the line already swaps in place).
    private func line(_ joiner: String) -> Text {
        let full = settled + joiner + volatile
        if corrections {
            let spans = SpokenCorrections.liveSpans(full, limit: 160)
            if spans.contains(where: { $0.style != .kept }) {
                return spans.reduce(Text("")) { t, s in
                    s.style == .removed
                        ? t + Text(s.text).foregroundColor(KB.muted.opacity(0.75)).strikethrough(true, color: KB.muted)
                        : t + Text(s.text).foregroundColor(KB.ink)
                }
            }
        }
        let (head, tail) = Self.splitNewest(full, count: 2)
        return Text(head).foregroundColor(KB.ink) + Text(tail).foregroundColor(KB.ink.opacity(0.45))
    }

    /// The text before the newest `count` words (with its trailing space), and those words.
    static func splitNewest(_ s: String, count: Int) -> (String, String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > count else { return ("", trimmed) }
        return (words.dropLast(count).joined(separator: " ") + " ", words.suffix(count).joined(separator: " "))
    }
}

/// A wash chip in the strip (Undo, Use as spoken, Cancel, Turn off).
private struct Chip: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink).lineLimit(1)
                .padding(.horizontal, 11).frame(height: 30)
                .background(KB.wash, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(title)
    }
}

/// The dark pill: ink with paper text (paper with ink text in dark, so it shows on the dark card).
private struct DarkPill: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.paper).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 30)
                .background(KB.ink, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(title)
    }
}

/// A bare round button in the strip: a brand glyph (Recent, Snippets), or a standard control symbol (xmark).
private struct IconButton: View {
    var art: BrandArt? = nil
    var symbol: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let art { ArtIcon(art: art, size: 19) }
                else if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
            }
            .foregroundStyle(KB.ink)
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(PressFade())
    }
}

/// A key in the dictation view's bottom row: its fill, pressed to the next shade.
private struct Key<Label: View>: View {
    var fill: Color
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    var body: some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(KeyPress(fill: fill))
    }
}

private struct KeyPress: ButtonStyle {
    var fill: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(KBKeyFace(fill: fill))
            .overlay {
                RoundedRectangle(cornerRadius: KB.keyRadius, style: .continuous)
                    .fill(KB.ink.opacity(configuration.isPressed ? 0.1 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: KB.keyRadius, style: .continuous))
    }
}

/// Delete: once on touch down, then repeats while held.
private struct RepeatKey<Label: View>: View {
    var fill: Color
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var pressed = false
    @State private var timer: Timer?

    var body: some View {
        label()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KBKeyFace(fill: pressed ? KB.card : fill))
            .contentShape(RoundedRectangle(cornerRadius: KB.keyRadius, style: .continuous))
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
