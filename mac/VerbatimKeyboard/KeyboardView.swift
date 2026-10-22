import SwiftUI
import UIKit

/// The keyboard's palette: Verbatim's tokens (Tokens.swift is in this target), so it matches the app in light,
/// dark, and Increase Contrast. Each color follows the keyboard's appearance, which `KeyboardViewController` sets
/// from the host app. Dictation is butter (DESIGN.md §1: butter means Dictate); errors are `Ink.danger`.
enum KB {
    static let uiPaper = Ink.paperUI
    static let uiInk = Ink.inkUI

    static let paper = Ink.paper
    static let ink = Ink.ink
    /// The keyboard's one action, dictation: butter fills, marks, and the listening edge.
    static let dictate = Ink.butter
    static let card = Ink.card
    /// Notices (a failure, Full Access).
    static let deep = Ink.danger
    static let muted = Ink.mute
    static let hairline = Ink.hairline
    /// Ink in both appearances: the glyph on the butter dictate button.
    static let inkFixed = Ink.inkFixed
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
        .background(KB.paper)
    }

    // MARK: Typing

    private var typingSurface: some View {
        VStack(spacing: 0) {
            typingStrip
                .frame(height: 40)
                .padding(.horizontal, 8).padding(.top, 4)
            TypingKeysView(typing: model.typing)
        }
    }

    /// The Dictate key on the left (always there, so you can find dictation); with Full Access, Recent on the
    /// right to insert your last transcript. Without Full Access, Recent is hidden rather than broken.
    private var typingStrip: some View {
        HStack(spacing: 8) {
            if model.hasFullAccess && model.showingRecent {
                recentRow
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
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
    }

    // MARK: Top strip

    @ViewBuilder private var topStrip: some View {
        HStack(spacing: 8) {
            switch model.stage {
            case .listening, .starting, .writing:
                IconGlyph(art: .iconDictations, size: 16, color: KB.ink)
                Text(stripLabel).font(.system(size: 12.5, weight: .medium)).monospacedDigit().foregroundStyle(KB.ink).lineLimit(1)
                    .accessibilityLabel(stripAccessibility)
                Spacer(minLength: 6)
                if model.stage == .starting {
                    Chip(title: "Cancel") { model.cancel() }
                        .accessibilityHint("Stops waiting for Verbose")
                }
            case .inserted:
                if model.polishing {
                    // Polish after inserting: a soft pulse while the cleaned-up version is on its way.
                    PolishingMark()
                    Text("Polishing…")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.muted).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityLabel("Inserted. Polishing your words")
                } else {
                    SessionDot(on: model.sessionLive)
                    Text("Inserted · \(model.insertion?.words ?? 0) \((model.insertion?.words ?? 0) == 1 ? "word" : "words")")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.ink).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
                Chip(title: "Undo") { model.undo() }
                    .accessibilityHint("Removes the inserted words")
                if let ins = model.insertion, ins.raw != ins.text, !ins.raw.isEmpty {
                    Chip(title: "Use as spoken") { model.useAsSpoken() }
                        .accessibilityHint("Replaces the cleaned-up words with the words as you said them")
                }
                if !model.snippets.isEmpty {
                    IconChip(art: .iconQuote) { model.toggleSnippets() }
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
        if !model.hasFullAccess {
            // No session or cleanup level to show without Full Access.
            BarsMark(color: Ink.persimmon).frame(width: 14, height: 14)
            Ink.wordmark(16).accessibilityHidden(true)
            Spacer(minLength: 6)
        } else {
            sessionStrip
        }
    }

    @ViewBuilder private var sessionStrip: some View {
        BarsMark(color: Ink.persimmon).frame(width: 14, height: 14)
        Text(sessionLabel).font(.system(size: 12.5, weight: .medium)).monospacedDigit().foregroundStyle(KB.ink).lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityLabel(sessionAccessibility)
        Spacer(minLength: 6)
        Text(model.levelLabel).font(.system(size: 12)).foregroundStyle(KB.muted).lineLimit(1)
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
            IconChip(art: .iconRecent) { model.toggleRecent() }
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
            IconChip(symbol: "xmark") { model.toggleRecent() }
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
            IconChip(symbol: "xmark") { model.toggleSnippets() }
                .accessibilityLabel("Close snippets")
        }
    }

    /// "Session on · 4:12 left", "Session on", or "Tap to start a session".
    private var sessionLabel: String {
        guard model.sessionLive else { return model.needsSessionCard ? "No session" : "Tap to start a session" }
        guard let ends = model.sessionEndsAt else { return "Session on" }
        return "Session on · \(Self.clock(ends.timeIntervalSince(model.now))) left"
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
                recordCard
                    .overlay(alignment: .topTrailing) {
                        FormatChip(label: model.formatLabel, format: model.format) { model.cycleFormat() }
                            .padding(10)
                    }
            }
        case .starting:
            startingCard
        case .listening, .writing:
            listeningCard
        }
    }

    /// The record button: dictates at once with a session, or opens Verbatim for a second to start one.
    private var recordCard: some View {
        Button { model.record() } label: {
            HStack(spacing: 16) {
                KeyboardRecordButton(size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recordTitle)
                        .font(Ink.serif(24)).foregroundStyle(KB.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if !model.sessionLive {
                        Text("Verbose opens for a second, then comes back")
                            .font(.system(size: 12)).foregroundStyle(KB.muted)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KB.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(KB.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(model.sessionLive ? (model.stage == .inserted ? "Keep dictating" : "Dictate") : "Start a session")
        .accessibilityHint(model.sessionLive ? "Starts listening right away" : "Opens Verbose for a second to turn on the microphone, then comes back here")
    }

    private var startingCard: some View {
        HStack(spacing: 16) {
            VoiceBars(level: 0, color: KB.dictate, barWidth: 10, maxHeight: 44).frame(width: 50)
            Text("Opening Verbose…")
                .font(Ink.serif(24)).foregroundStyle(KB.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KB.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(KB.dictate.opacity(0.55)))
    }

    private var listeningCard: some View {
        HStack(spacing: 12) {
            RoundKey(systemName: "xmark", filled: false) { model.cancel() }
                .accessibilityLabel("Cancel")
                .accessibilityHint("Stops listening and inserts nothing")
            VStack(spacing: 6) {
                if model.stage == .writing {
                    ProgressView().tint(KB.ink).frame(height: 40).accessibilityLabel("Writing it down")
                } else {
                    ListeningDots(level: model.level, color: KB.dictate).frame(height: hasLiveWords ? 28 : 40)
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
        .background(KB.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(KB.dictate.opacity(0.55)))
        .accessibilityElement(children: .contain)
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
                    .background(KB.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(KB.hairline))
                    .accessibilityLabel("Next keyboard")
            }
            Key(label: { Image(systemName: "keyboard").font(.system(size: 17, weight: .regular)).foregroundStyle(KB.ink) },
                action: model.toggleSurface)
                .frame(width: 48)
                .accessibilityLabel("Letter keys")
                .accessibilityHint("Shows the typing keyboard")
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

/// The format chip on the record card: "Auto · Mail", "Auto · Message", "Email", "Message", or "Note". Tap it to
/// move to the next format; VoiceOver can also swipe up or down on it.
private struct FormatChip: View {
    var label: String
    var format: KeyboardFormat
    var next: () -> Void

    var body: some View {
        Button(action: next) {
            HStack(spacing: 5) {
                Circle().fill(format == .auto ? KB.hairline : KB.dictate).frame(width: 6, height: 6)
                Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(KB.ink).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(KB.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(format == .auto ? KB.hairline : KB.dictate.opacity(0.6)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel("Format: \(label)")
        .accessibilityHint("Changes how Verbose cleans up this dictation: Auto, Email, Message, or Note")
        .accessibilityAdjustableAction { direction in
            if direction == .increment || direction == .decrement { next() }
        }
    }
}

/// Dictation without Allow Full Access: why it needs it, and where to turn it on. Inline in the keyboard, not a
/// modal. A keyboard can't open Settings without private API, so the path shows as text.
private struct FullAccessCard: View {
    @State private var showsPath = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Ink.butterTint)
                BrandGlyph(art: .iconDictations, color: Ink.butterText, minLineWidth: 1.2).padding(11)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Dictation needs Full Access, so the Verbose app can pass your words to this keyboard. Typing works without it.")
                    .font(.system(size: 14)).foregroundStyle(KB.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.8)
                if showsPath {
                    Text("Settings › Verbose › Keyboards › Allow Full Access")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
                        .lineLimit(2).minimumScaleFactor(0.75)
                        .accessibilityLabel("Open Settings, then Verbose, then Keyboards, and turn on Allow Full Access")
                } else {
                    Chip(title: "Show me where") { showsPath = true }
                        .accessibilityHint("Shows where to turn on Full Access in Settings")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KB.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(KB.hairline))
        .accessibilityElement(children: .contain)
    }
}

/// The Dictate key in the typing view's strip. With Full Access it shows the dictation view; without it, the
/// dictation view explains Full Access.
private struct DictateKey: View {
    var fullAccess: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                IconGlyph(art: .iconDictations, size: 15, color: KB.ink)
                Text("Dictate").font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(KB.card, in: Capsule())
            .overlay(Capsule().strokeBorder(KB.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel("Dictate")
        .accessibilityHint(fullAccess ? "Shows the dictation view" : "Explains how to turn on dictation")
    }
}

/// App Store builds with no session: the keyboard can't open Verbatim by itself, so this card says how to start
/// a session instead of offering a record button.
private struct StartSessionCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Ink.butterTint)
                BrandGlyph(art: .iconDictations, color: Ink.butterText, minLineWidth: 1.2).padding(11)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Start a session to dictate")
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
        .background(KB.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(KB.hairline))
        .accessibilityElement(children: .combine)
    }

    private func way(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(KB.ink).frame(width: 16)
            Text(text).font(.system(size: 13)).foregroundStyle(KB.muted).lineLimit(1).minimumScaleFactor(0.75)
        }
    }
}

/// The dictate button: a butter circle with the Dictations glyph in ink (butter means Dictate).
struct KeyboardRecordButton: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(KB.dictate)
            BrandGlyph(art: .iconDictations, color: KB.inkFixed, minLineWidth: 1.2).padding(size * 0.22)
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
            .font(.system(size: 15))
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

/// The session dot, half-lit while Verbatim polishes the inserted text (still: nothing loops, DESIGN.md §7).
private struct PolishingMark: View {
    var body: some View {
        Circle().fill(KB.dictate).frame(width: 8, height: 8).opacity(0.6)
            .overlay(Circle().strokeBorder(KB.dictate, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// A small persimmon dot in the top strip: filled while a session is on.
private struct SessionDot: View {
    var on: Bool
    var body: some View {
        Circle().fill(on ? KB.dictate : KB.hairline).frame(width: 8, height: 8)
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

/// A row of butter dots that rise with the voice level, taller in the middle. They follow the level only: still
/// in a quiet room (DESIGN.md §7).
private struct ListeningDots: View {
    var level: Double
    var color: Color
    private static let count = 9

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<Self.count, id: \.self) { i in
                Capsule().fill(color).frame(width: 6, height: height(i))
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private func height(_ i: Int) -> CGFloat {
        let l = pow(min(1, max(0, level)), 0.6)
        let center = Double(Self.count - 1) / 2
        let shape = 1 - abs(Double(i) - center) / (center + 1)      // taller in the middle
        return 6 + CGFloat(max(0.12, l * shape)) * 34
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
/// A round chip in the top strip: a brand glyph, or a standard control symbol (xmark).
private struct IconChip: View {
    var art: BrandArt? = nil
    var symbol: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let art { ArtIcon(art: art, size: 15) }
                else if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
            }
            .foregroundStyle(KB.ink)
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
                .background(KB.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(KB.hairline))
                .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
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
            .background(pressed ? KB.hairline : KB.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(KB.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
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
