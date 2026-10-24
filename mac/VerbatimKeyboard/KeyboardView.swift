import SwiftUI
import UIKit

/// The keyboard's palette: Verbatim's tokens (Tokens.swift is in this target), so it matches the app in light,
/// dark, and Increase Contrast. Each color follows the keyboard's appearance, which `KeyboardViewController` sets
/// from the host app. Dictation is butter (DESIGN.md §1: butter means Dictate); errors are `Ink.danger`.
///
/// There's no panel color: the keyboard's backdrop is Apple's (system chrome stays Apple's). iOS draws the keyboard
/// container, its rounded top, and the globe and dictation strip below in a neutral gray (about #1F1F1F in dark,
/// a light gray in light), and our keys, pills, and cards sit on it. Text that sits straight on the backdrop (Home's
/// numbers, Listening, the bar's notices) uses `ink`, `dim`, `muted`, and `deep`, which hold 4.5:1 on that gray
/// in both appearances.
enum KB {
    static let uiInk = Ink.inkUI

    static let paper = Ink.paper
    static let ink = Ink.ink
    /// Cards and outlined circles: the menu, the lists, the Full Access notice, ABC, Recent, and Settings.
    static let card = Ink.card
    /// Secondary text: the line under Home's number, the live words while you talk.
    static let dim = Ink.dim
    /// Notices (a failure). `Ink.danger`, a step deeper in light so it holds 4.5:1 on the system's light gray.
    static let deep = Ink.dynC(0x9E361E, 0xFF8A6B, 0x8A2E18, 0xFFA48A)
    /// Metadata. `Ink.mute`, a step deeper in light so it holds 4.5:1 on the system's light gray and on `wash`.
    static let muted = Ink.dynC(0x48514A, 0xA1A29A, 0x3E4A43, 0xD4CDC0)
    static let hairline = Ink.hairline
    /// Ink in both appearances: text and glyphs on butter, which stays butter in dark. Never the adaptive `ink`
    /// on butter: that turns light in dark.
    static let inkFixed = Ink.inkFixed

    // Keyboard-only colors (not in Tokens.swift; defined here, not shared). The keys and soft surfaces are tuned
    // for Apple's keyboard backdrop rather than a panel of ours.
    /// The keyboard's one action, dictation: Tap to talk, Start, and Listening's done button. Dark is #DDB563, a
    /// little lighter than `Ink.butter`'s dark value, so it holds up on the dark backdrop.
    static let dictate = Ink.dyn(Ink.butterHex, 0xDDB563)
    /// The butter's 1.5 pt outline: fixed ink in light, as the mockup; none in dark, where a dark ring would
    /// melt into the dark backdrop and shrink the butter. The butter itself holds 8:1 against the dark gray.
    static let dictateRim = Ink.make { dark, _ in dark ? PColor.clear : PColor(hex: Ink.inkHex) }
    /// Letter keys and the key popup: reader white in light; a raised gray-green in dark, lighter than the
    /// system's dark gray (1.7:1), with ink labels at 8.7:1 (7:1 with Increase Contrast, on a lighter key).
    static let key = Ink.dynC(Ink.readerHex, 0x3A4641, Ink.readerHex, 0x47544E)
    /// The space bar's name on a key: `muted`, lighter in dark so it holds 5:1 on `key`.
    static let keyMuted = Ink.dynC(0x606962, 0xB9BAB2, 0x3E4A43, 0xD4CDC0)
    /// Chips, soft circles, and function keys: a warm step darker than the system's light gray in light (like
    /// Apple's function keys), and a quiet step above the backdrop in dark (1.3:1), under the letter keys.
    static let wash = Ink.dynC(0xCCC3B1, 0x2B3530, 0xC0B6A2, 0x36423C)
    /// The butter pills' and the menu card's hard offset shadow.
    static let hard = Ink.dyn(Ink.inkHex, 0x0C1310)
    /// A key's 1 pt bottom edge: ink at 25% in light (50% with Increase Contrast); a dark shadow in dark, as the
    /// system keys have (a light edge under a dark key reads as a rim), with a paper edge under Increase Contrast.
    static let keyShadow = Ink.make { dark, hc in
        if dark { return hc ? PColor(hex: Ink.paperHex).withAlphaComponent(0.35) : PColor.black.withAlphaComponent(0.5) }
        return PColor(hex: Ink.inkHex).withAlphaComponent(hc ? 0.5 : 0.25)
    }

    /// Keys use a 7 pt radius, like the system keyboard's keys; cards use the Record panel's radius.
    static let keyRadius: CGFloat = 7
    static let cardRadius = Radius.record
    /// The top bar: 46 pt circles and pills, 10 pt from the edges.
    static let barHeight: CGFloat = 46
    static let barInset: CGFloat = 10
}

/// Three modes, like Wispr Flow's keyboard, in Verbose's look (the approved mockup, kb2):
/// - Home: close and ABC (to Typing), Recent, and Settings over your numbers in the serif, with one butter Tap to talk.
/// - Typing: the menu and a butter Start over the full keyboard. Words that go in come back here with
///   "✓ Inserted · 14 words" and Undo for a few seconds.
/// - Listening: cancel, the cleanup chip, and a butter done button over your words, the voice bars, "Listening", and
///   the microphone and time. Starting, writing, and polishing use the same screen.
/// Typing works without Allow Full Access; Home explains why dictation needs it.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch model.mode {
                case .home: home
                case .typing: typingMode
                case .listening: listening
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if model.showingMenu && model.mode == .typing { menuLayer }
        }
        // No background: Apple's keyboard backdrop shows through (see `KB`).
    }

    // MARK: Bars

    /// The top bar's frame, shared by all three modes.
    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .frame(height: KB.barHeight)
            .padding(.horizontal, KB.barInset).padding(.top, 8)
    }

    /// The bar above an open list (recent dictations, snippets): its name and a soft close circle.
    @ViewBuilder private var listBar: some View {
        if model.showingSnippets {
            listHeader("Snippets", closeLabel: "Close snippets") { model.toggleSnippets() }
        } else {
            listHeader("Recent dictations", closeLabel: "Close recent dictations") { model.toggleRecent() }
        }
    }

    private func listHeader(_ title: String, closeLabel: String, close: @escaping () -> Void) -> some View {
        bar {
            Text(title).font(Ink.serif(21)).foregroundStyle(KB.ink).lineLimit(1)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            CircleButton(look: .soft, action: close) { Image(systemName: "xmark").font(.system(size: 16, weight: .medium)) }
                .accessibilityLabel(closeLabel)
        }
    }

    private var listOpen: Bool { model.hasFullAccess && (model.showingRecent || model.showingSnippets) }

    // MARK: Home

    private var home: some View {
        VStack(spacing: 0) {
            if listOpen {
                listBar
                list.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 8)
            } else {
                homeBar
                homeBody
            }
        }
    }

    /// Close (to Typing) on the left; ABC, Recent, and Settings on the right. The session's time left sits between,
    /// when the app set an idle timeout.
    private var homeBar: some View {
        bar {
            CircleButton(look: .soft, action: model.showTyping) { Image(systemName: "xmark").font(.system(size: 16, weight: .medium)) }
                .accessibilityLabel("Close")
                .accessibilityHint("Shows the typing keyboard")
            Spacer(minLength: 6)
            if model.hasFullAccess, model.sessionLive, model.sessionEndsAt != nil {
                Text(sessionLabel).font(Ink.mono(12)).foregroundStyle(KB.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel(sessionAccessibility)
                Spacer(minLength: 6)
            }
            CircleButton(look: .outline, action: model.showTyping) {
                Text("ABC").font(.system(size: 15, weight: .bold))
            }
            .accessibilityLabel("Letter keys")
            .accessibilityHint("Shows the typing keyboard")
            if model.hasFullAccess {
                CircleButton(look: .outline, action: model.toggleRecent) { KBGlyph(art: .iconRecent, size: 20, color: KB.ink, minLineWidth: 1.3) }
                    .accessibilityLabel("Recent dictations")
                    .accessibilityHint("Shows your last dictations to insert again")
            }
            CircleButton(look: .outline, action: model.openVerbose) { KBGlyph(art: .iconSettings, size: 20, color: KB.ink, minLineWidth: 1.3) }
                .accessibilityLabel("Settings")
                .accessibilityHint(model.hasFullAccess ? "Opens Verbose" : "Shows how to turn on dictation")
        }
    }

    @ViewBuilder private var homeBody: some View {
        if !model.hasFullAccess {
            FullAccessCard()
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 10)
        } else if model.needsSessionCard {
            StartSessionCard()
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 10)
        } else {
            VStack(spacing: 0) {
                StatsPager(pages: model.statsPages, page: model.statsPage,
                           next: model.nextStatsPage, previous: model.previousStatsPage)
                    .frame(maxHeight: .infinity)
                statusLine.padding(.horizontal, 18).padding(.bottom, 6)
                ZStack {
                    TalkPill(label: "Tap to talk", action: model.record)
                        .accessibilityHint(model.sessionLive ? "Starts listening right away"
                                           : "Opens Verbose for a second to turn on the microphone, then comes back here")
                    if model.showsGlobe {
                        HStack {
                            globe
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, KB.barInset).padding(.bottom, 10)
            }
        }
    }

    /// A failure, or a short confirmation ("Copied."), above Tap to talk.
    @ViewBuilder private var statusLine: some View {
        if let n = model.notice {
            Text(n).font(.system(size: 12.5)).foregroundStyle(KB.deep)
                .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
        } else if let i = model.info {
            Text(i).font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.muted)
                .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var globe: some View {
        GlobeKey(controller: model.controllerForGlobe)
            .frame(width: 34, height: 34)
            .accessibilityLabel("Next keyboard")
    }

    /// Time left in the session: "4:12 left".
    private var sessionLabel: String {
        guard let ends = model.sessionEndsAt else { return "" }
        return "\(Self.clock(ends.timeIntervalSince(model.now))) left"
    }

    private var sessionAccessibility: String {
        guard let ends = model.sessionEndsAt else { return "Session on" }
        let m = max(0, Int(ends.timeIntervalSince(model.now)) / 60)
        return m >= 1 ? "Session on, \(m) minutes left" : "Session on, less than a minute left"
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    // MARK: Typing

    private var typingMode: some View {
        VStack(spacing: 0) {
            if listOpen {
                listBar
                list.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 8)
            } else {
                typingBar.padding(.bottom, 2)
                TypingKeysView(typing: model.typing)
            }
        }
    }

    /// The menu and Start; "✓ Inserted · 14 words" and Undo just after words went in; a spoken correction's notice
    /// when one changed them.
    @ViewBuilder private var typingBar: some View {
        if model.stage == .inserted, let c = model.correction {
            bar { correctionStrip(c) }
        } else if model.stage == .inserted {
            bar {
                CheckDisc()
                Text("Inserted · \(model.insertion?.words ?? 0) \((model.insertion?.words ?? 0) == 1 ? "word" : "words")")
                    .font(.system(size: 13.5, weight: .semibold)).monospacedDigit().foregroundStyle(KB.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .layoutPriority(-1)
                Spacer(minLength: 6)
                Chip(title: "Undo") { model.undo() }
                    .accessibilityHint("Removes the inserted words")
                StartPill(action: model.start)
                    .accessibilityHint(startHint)
            }
        } else {
            bar {
                CircleButton(look: model.showingMenu ? .active : .soft, action: model.toggleMenu) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .medium))
                }
                .accessibilityLabel("Menu")
                .accessibilityValue(model.showingMenu ? "Open" : "")
                .accessibilityHint("Cleanup, snippets, recent dictations, and Open Verbose")
                if let n = model.notice {
                    Text(n).font(.system(size: 12)).foregroundStyle(KB.deep)
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.updatesFrequently)
                } else if let i = model.info {
                    Text(i).font(.system(size: 12, weight: .medium)).foregroundStyle(KB.muted)
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                Spacer(minLength: 6)
                StartPill(action: model.start)
                    .accessibilityHint(startHint)
            }
        }
    }

    private var startHint: String {
        guard model.hasFullAccess else { return "Explains how to turn on dictation" }
        if model.needsSessionCard && !model.sessionLive { return "Shows how to start a session" }
        return model.sessionLive ? "Starts listening right away" : "Opens Verbose for a second to turn on the microphone, then comes back here"
    }

    /// After a spoken correction changed the inserted words: what changed, Use as spoken, and Turn off.
    private func correctionStrip(_ summary: String) -> some View {
        HStack(spacing: 6) {
            Text(summary).font(.system(size: 12.5)).foregroundStyle(KB.ink)
                .lineLimit(2).truncationMode(.middle).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Chip(title: "Use as spoken") { model.useAsSpoken() }
                .accessibilityHint("Replaces the corrected words with the words as you said them")
            Chip(title: "Turn off") { model.turnOffSpokenCorrections() }
                .accessibilityHint("Stops Verbose from acting on spoken corrections")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Menu

    /// The menu card under the menu circle, over the keys. A tap anywhere else closes it.
    private var menuLayer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.closeMenu() }
                .accessibilityHidden(true)
            MenuCard(model: model)
                .padding(.leading, KB.barInset).padding(.top, 8 + KB.barHeight + 6)
        }
    }

    // MARK: Listening

    private var listening: some View {
        VStack(spacing: 0) {
            listeningBar
            VStack(spacing: 12) {
                listeningWords
                VoiceWave(level: model.level, active: model.stage == .listening, color: KB.ink, count: 13, barWidth: 6)
                    .frame(width: 170, height: 36)
                VStack(spacing: 3) {
                    Text(listeningTitle)
                        .font(Ink.serif(22)).foregroundStyle(KB.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(listeningDetail)
                        .font(detailIsData ? Ink.mono(12) : .system(size: 12.5))
                        .foregroundStyle(KB.muted)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(listeningAccessibility)
                .accessibilityAddTraits(.updatesFrequently)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if model.showsGlobe { globe.padding(.leading, KB.barInset).padding(.bottom, 8) }
            }
        }
    }

    /// Cancel on the left (hidden while polishing: the words are already in); the cleanup chip and done on the right.
    private var listeningBar: some View {
        bar {
            if model.polishing {
                Color.clear.frame(width: KB.barHeight, height: KB.barHeight).accessibilityHidden(true)
            } else {
                CircleButton(look: .soft, action: model.cancel) { Image(systemName: "xmark").font(.system(size: 16, weight: .medium)) }
                    .accessibilityLabel("Cancel")
                    .accessibilityHint(model.stage == .starting ? "Stops waiting for Verbose" : "Stops listening and inserts nothing")
            }
            Spacer(minLength: 6)
            if model.hasFullAccess {
                CleanupChip(level: model.levelLabel, format: model.formatLabel, enabled: model.stage == .listening || model.stage == .starting) {
                    model.cycleFormat()
                }
            }
            CircleButton(look: .go, action: { model.polishing ? model.skipPolish() : model.done() }) {
                Image(systemName: "checkmark").font(.system(size: 19, weight: .bold))
            }
            .disabled(!doneEnabled)
            .opacity(doneEnabled ? 1 : 0.4)
            .accessibilityLabel("Done")
            .accessibilityHint(model.polishing ? "Stops waiting for the polished version and keeps your words"
                               : "Stops listening and inserts your words")
        }
    }

    private var doneEnabled: Bool { model.stage == .listening || model.polishing }

    /// Your words while you talk, centered in the serif; the newest two lighter.
    @ViewBuilder private var listeningWords: some View {
        if model.stage == .listening, hasLiveWords {
            LiveWordsLine(settled: model.liveSettled, volatile: model.liveVolatile,
                          corrections: model.liveCorrections, size: 19, base: KB.dim, alignment: .center)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
    }

    private var hasLiveWords: Bool { !model.liveSettled.isEmpty || !model.liveVolatile.isEmpty }

    private var listeningTitle: String {
        if model.polishing { return "Polishing…" }
        switch model.stage {
        case .starting: return "Opening Verbose…"
        case .writing: return "Writing it down"
        default: return "Listening"
        }
    }

    /// The microphone and the time while listening or writing (mono: it's data); a plain line otherwise.
    private var listeningDetail: String {
        if model.polishing {
            let n = model.insertion?.words ?? 0
            return "Inserted · \(n) \(n == 1 ? "word" : "words")"
        }
        if model.stage == .starting { return "Verbose opens for a second, then comes back" }
        return "\(model.micName) · \(Self.clock(model.elapsed))"
    }

    private var detailIsData: Bool { !model.polishing && model.stage != .starting }

    private var listeningAccessibility: String {
        if model.polishing { return "Inserted. Polishing your words" }
        switch model.stage {
        case .starting: return "Starting a session"
        case .writing: return "Writing it down"
        default: return "Listening, \(Int(model.elapsed)) seconds"
        }
    }

    // MARK: Lists

    @ViewBuilder private var list: some View {
        if model.showingSnippets { snippetCard } else { recentCard }
    }

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
}

// MARK: - Home pieces

/// Home's numbers: "3,620 *words*" in the big serif, the line under it, and paging dots. Tap or swipe left for the
/// next page, swipe right for the one before; the page swaps in place, with no slide (the voice bars are the
/// keyboard's only motion). VoiceOver swipes up or down to page.
private struct StatsPager: View {
    var pages: [KeyboardStatPage]
    var page: Int
    var next: () -> Void
    var previous: () -> Void

    private var current: KeyboardStatPage? { pages.indices.contains(page) ? pages[page] : nil }

    var body: some View {
        VStack(spacing: 6) {
            if let p = current {
                Text("\(Text(p.number)) \(Text(p.unit).italic())")
                    .font(Ink.serif(50)).tracking(-1).foregroundStyle(KB.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(p.line)
                    .font(.system(size: 15)).foregroundStyle(KB.dim)
                    .multilineTextAlignment(.center).lineSpacing(2)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: 300)
            } else {
                // Before the first dictation.
                Text("\(Text("Talk, "))\(Text("don't type.").italic())")
                    .font(Ink.serif(40)).tracking(-0.8).foregroundStyle(KB.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("Your numbers show up here after your first dictation.")
                    .font(.system(size: 15)).foregroundStyle(KB.dim)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: 300)
            }
            if pages.count > 1 {
                HStack(spacing: 7) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle().fill(i == page ? KB.ink : KB.hairline).frame(width: 7, height: 7)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: next)
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in
            if v.translation.width < -30 { next() } else if v.translation.width > 30 { previous() }
        })
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current?.spoken ?? "Talk, don't type. Your numbers show up here after your first dictation.")
        .accessibilityValue(pages.count > 1 ? "Page \(page + 1) of \(pages.count)" : "")
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: next()
            case .decrement: previous()
            @unknown default: break
            }
        }
    }
}

/// Home's one big action: butter, ink outline, hard shadow, grain, and the microphone.
private struct TalkPill: View {
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                KBGlyph(art: .capture, size: 20, color: KB.inkFixed, minLineWidth: 1.5)
                Text(label).font(.system(size: 16, weight: .bold)).foregroundStyle(KB.inkFixed).lineLimit(1)
            }
            .padding(.horizontal, 26).frame(height: 50)
            .butterPill(shadow: CGSize(width: 3, height: 4))
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(label)
    }
}

/// Typing's Start: butter, with five still voice bars (a glyph, not a meter).
private struct StartPill: View {
    var action: () -> Void
    private static let bars: [CGFloat] = [9, 16, 20, 12, 17]
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("Start").font(.system(size: 17, weight: .bold)).foregroundStyle(KB.inkFixed).lineLimit(1)
                HStack(spacing: 2.5) {
                    ForEach(Self.bars.indices, id: \.self) { i in
                        Capsule().fill(KB.inkFixed).frame(width: 3, height: Self.bars[i])
                    }
                }
                .frame(height: 20)
                .accessibilityHidden(true)
            }
            .padding(.leading, 20).padding(.trailing, 16).frame(height: KB.barHeight)
            .butterPill(shadow: CGSize(width: 2, height: 3))
        }
        .buttonStyle(PressFade())
        .accessibilityLabel("Start dictation")
    }
}

private extension View {
    /// Butter capsule with a 1.5 pt fixed-ink outline (none in dark, `KB.dictateRim`), the grain, and a hard ink
    /// shadow offset by `shadow`.
    func butterPill(shadow: CGSize) -> some View {
        background {
            ZStack {
                Capsule().fill(KB.dictate)
                GrainOverlay().clipShape(Capsule())
            }
        }
        .overlay(Capsule().strokeBorder(KB.dictateRim, lineWidth: 1.5))
        .background(Capsule().fill(KB.hard).offset(x: shadow.width, y: shadow.height))
        .contentShape(Capsule())
    }
}

/// A 46 pt circle in the top bar: soft (wash), outline (card with an ink ring), active (ink, for the open menu),
/// or go (butter with the hard shadow, for done).
private struct CircleButton<Label: View>: View {
    enum Look { case soft, outline, active, go }
    var look: Look
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(foreground)
                .frame(width: KB.barHeight, height: KB.barHeight)
                .background(Circle().fill(fill))
                .overlay { ring }
                .background { if look == .go { Circle().fill(KB.hard).offset(x: 2, y: 3) } }
                .contentShape(Circle())
        }
        .buttonStyle(PressFade())
    }

    private var fill: Color {
        switch look {
        case .soft: return KB.wash
        case .outline: return KB.card
        case .active: return KB.ink
        case .go: return KB.dictate
        }
    }

    private var foreground: Color {
        switch look {
        case .active: return KB.paper
        case .go: return KB.inkFixed
        default: return KB.ink
        }
    }

    @ViewBuilder private var ring: some View {
        switch look {
        case .outline: Circle().strokeBorder(KB.ink, lineWidth: 1.5)
        case .go: Circle().strokeBorder(KB.dictateRim, lineWidth: 1.5)
        default: EmptyView()
        }
    }
}

/// The Typing menu: Cleanup (the level and format; tap for the next format), Snippets, Recent dictations, Use as
/// spoken (after cleaned-up words went in), and Open Verbose. Card fill, ink outline, hard shadow.
private struct MenuCard: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            if model.hasFullAccess {
                row(.iconAI, "Cleanup", value: "\(model.levelLabel) · \(model.formatLabel)",
                    spoken: ("Format: \(model.formatLabel)", "Cleanup: \(model.levelLabel)"),
                    hint: "Changes how Verbose cleans up your dictations: Auto, Email, Message, or Note",
                    adjustable: true, action: model.cycleFormat)
                if !model.snippets.isEmpty {
                    row(.iconQuote, "Snippets", value: "\(model.snippets.count)", hint: "Shows your snippets to insert",
                        action: model.toggleSnippets)
                }
                if !model.recent.isEmpty {
                    row(.iconRecent, "Recent dictations", hint: "Shows your last dictations to insert again", action: model.toggleRecent)
                }
                if model.stage == .inserted, let ins = model.insertion, ins.raw != ins.text, !ins.raw.isEmpty {
                    row(.iconSwap, "Use as spoken", hint: "Replaces the cleaned-up words with the words as you said them") {
                        model.closeMenu()
                        model.useAsSpoken()
                    }
                }
            }
            row(.iconSettings, "Open Verbose", hint: model.hasFullAccess ? "Opens the Verbose app" : "Shows how to turn on dictation",
                action: model.openVerbose)
        }
        .padding(6)
        .frame(width: 228)
        .background(KB.card, in: RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous).strokeBorder(KB.ink, lineWidth: 1.5))
        .background(RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous).fill(KB.hard).offset(x: 4, y: 5))
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { model.closeMenu() }
    }

    /// One row: a brand icon, the name, and a mono value on the right. `spoken` overrides VoiceOver's label and
    /// value; `adjustable` lets VoiceOver swipe up or down to run the action again.
    private func row(_ art: BrandArt, _ title: String, value: String? = nil, spoken: (String, String)? = nil,
                     hint: String, adjustable: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                KBGlyph(art: art, size: 18, color: KB.ink)
                Text(title).font(.system(size: 14.5)).foregroundStyle(KB.ink).lineLimit(1)
                Spacer(minLength: 6)
                if let value {
                    Text(value).font(Ink.mono(12)).foregroundStyle(KB.muted).lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            .padding(.horizontal, 10).frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken?.0 ?? title)
        .accessibilityValue(spoken?.1 ?? value ?? "")
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
        .modifier(AdjustableRow(enabled: adjustable, action: action))
    }
}

/// VoiceOver's swipe up or down runs the row's action, on the one row that cycles (Cleanup); other rows stay plain
/// buttons.
private struct AdjustableRow: ViewModifier {
    var enabled: Bool
    var action: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAdjustableAction { d in
                if d == .increment || d == .decrement { action() }
            }
        } else {
            content
        }
    }
}

/// A menu row presses to the wash.
private struct MenuRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(configuration.isPressed ? KB.wash : Color.clear))
    }
}

// MARK: - Surfaces

/// A brand line icon drawn as SwiftUI shapes, so its color resolves like any fill (`Circle().fill`) in the
/// keyboard's light or dark appearance. Build 186's Canvas-drawn microphone vanished on the ink circle in dark
/// mode; shapes take the same path as the circles and keys, which did draw. Fills and strokes only (the icons the
/// keyboard uses have no dashes or clipped hatching). Decorative: the label beside it carries the meaning.
struct KBGlyph: View {
    var art: BrandArt
    var size: CGFloat
    var color: Color
    var minLineWidth: CGFloat = 1.2

    var body: some View {
        let s = min(size / art.box.width, size / art.box.height)
        let width = max(minLineWidth, art.strokeWidth * s)
        ZStack {
            if !art.fills.isEmpty { ArtShape(art: art, fills: true).fill(color) }
            if !art.strokes.isEmpty {
                ArtShape(art: art, fills: false)
                    .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One BrandArt's fills or strokes as a shape, scaled to fit its frame (as `BrandGlyph` scales it).
private struct ArtShape: Shape {
    var art: BrandArt
    var fills: Bool
    func path(in rect: CGRect) -> Path {
        Path(BrandArt.cgPath(fills ? art.fills : art.strokes))
            .applying(ArtSpace(box: art.box, size: rect.size).transform)
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

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

/// Paper grain for the butter pills and notice cards: one 128 px tile of ink noise, made once and tiled (64 KB), never redrawn per
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

/// A notice card on Home (Full Access, how to start a session): card color, ink outline, and the grain.
private struct CardShell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous)
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    shape.fill(KB.card)
                    GrainOverlay().clipShape(shape)
                }
            }
            .overlay { shape.strokeBorder(KB.ink, lineWidth: 1.5) }
    }
}

// MARK: - Cards

/// Home without Allow Full Access: why dictation needs it, and where to turn it on. Inline in the keyboard, not a
/// modal. A keyboard can't open Settings without private API, so the path shows as text.
private struct FullAccessCard: View {
    @State private var showsPath = false

    var body: some View {
        CardShell {
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
                    KBGlyph(art: .iconPrivacy, size: 22, color: KB.ink)
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
        CardShell {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Ink.butterTint)
                    KBGlyph(art: .iconDictations, size: 22, color: Ink.butterText)
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

/// Listening's cleanup chip, a soft rounded chip ("✦ Polished · Auto ▾"). Tap it to move to the next format, which
/// applies to the dictation you're speaking (the app reads it when you finish); VoiceOver can also swipe up or down
/// on it. While Verbose writes your words down it only shows the level.
private struct CleanupChip: View {
    var level: String
    var format: String
    var enabled = true
    var next: () -> Void

    var body: some View {
        Button(action: next) {
            HStack(spacing: 5) {
                KBGlyph(art: .iconAI, size: 14, color: KB.ink)
                Text(level).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(KB.ink).lineLimit(1)
                Text("· \(format)").font(.system(size: 13.5, weight: .medium)).foregroundStyle(KB.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if enabled {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(KB.ink)
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(KB.wash, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
        .buttonStyle(PressFade())
        .disabled(!enabled)
        .accessibilityLabel("Format: \(format)")
        .accessibilityValue("Cleanup: \(level)")
        .accessibilityHint(enabled ? "Changes how Verbose cleans up this dictation: Auto, Email, Message, or Note" : "")
        .accessibilityAdjustableAction { direction in
            if enabled, direction == .increment || direction == .decrement { next() }
        }
    }
}

/// The ink check disc beside "Inserted" (paper on ink; ink on paper in dark, so it doesn't vanish).
private struct CheckDisc: View {
    var body: some View {
        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(KB.paper)
            .frame(width: 18, height: 18)
            .background(KB.ink, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The voice bars: ink bars that move with your voice, flat in a quiet room. The keyboard's only motion; still under
/// Reduce Motion and whenever nothing is listening (starting, writing, polishing). Redrawn at most 30 times a
/// second, in one Canvas.
private struct VoiceWave: View {
    var level: Double
    var active: Bool
    var color: Color
    var count = 13
    /// The widest a bar gets; narrower when the bars are close together.
    var barWidth: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment

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
        // Resolved here, so the Canvas gets a plain color for this appearance rather than an adaptive one.
        let color = Color(self.color.resolve(in: environment))
        let n = max(1, count), maxBar = barWidth
        return Canvas { ctx, size in
            let gap = size.width / CGFloat(n)
            let bw = min(maxBar, gap * 0.5)
            for i in 0..<n {
                let v: Double
                if still {
                    v = 0.25
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

/// Your words while you talk, as Verbatim's live words hear them: in the serif, the newest two words at 45% (they
/// may still change). Up to three lines, the start cut off as it grows. The text swaps in place, with no
/// per-character animation, so words land one by one without shimmer.
private struct LiveWordsLine: View {
    var settled: String
    var volatile: String
    /// Strike out what a spoken correction removes ("scratch that", "at 2, actually 3").
    var corrections = false
    var size: CGFloat = 19
    var base: Color = KB.ink
    var alignment: TextAlignment = .center

    var body: some View {
        let joiner = settled.isEmpty || volatile.isEmpty ? "" : " "
        line(joiner)
            .font(Ink.serif(size))
            .lineSpacing(3)
            .lineLimit(3)
            .truncationMode(.head)
            .multilineTextAlignment(alignment)
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .accessibilityLabel(settled + joiner + volatile)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// The base color, with the newest two words at 45%; with a correction, removed words faded and struck through and the
    /// replacement in ink. Style only, no animation (the line already swaps in place).
    private func line(_ joiner: String) -> Text {
        let full = settled + joiner + volatile
        if corrections {
            let spans = SpokenCorrections.liveSpans(full, limit: 160)
            if spans.contains(where: { $0.style != .kept }) {
                return spans.reduce(Text("")) { t, s in
                    s.style == .removed
                        ? t + Text(s.text).foregroundColor(KB.muted.opacity(0.75)).strikethrough(true, color: KB.muted)
                        : t + Text(s.text).foregroundColor(base)
                }
            }
        }
        let (head, tail) = Self.splitNewest(full, count: 2)
        return Text(head).foregroundColor(base) + Text(tail).foregroundColor(base.opacity(0.45))
    }

    /// The text before the newest `count` words (with its trailing space), and those words.
    static func splitNewest(_ s: String, count: Int) -> (String, String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > count else { return ("", trimmed) }
        return (words.dropLast(count).joined(separator: " ") + " ", words.suffix(count).joined(separator: " "))
    }
}

/// A soft rounded chip in the top bar (Undo, Use as spoken, Turn off).
private struct Chip: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(KB.ink).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 34)
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

private struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The globe key on Home and Listening, when the system doesn't draw one (Typing has its own). A UIKit button so it can hand the touch to `handleInputModeList(from:with:)`, which shows the
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
