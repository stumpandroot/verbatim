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
    /// The look chosen on this iPhone (Settings › Appearance; `KeyboardLook`), read once per appearance from the App
    /// Group like the dictate button's settings. Set by `KeyboardModel.resume` before it publishes the change; the
    /// keyboard view takes a new identity then, so every color and font below is read again. Verbose style without
    /// Full Access (no App Group).
    static var native = false

    static var uiInk: UIColor { native ? UIColor.label : Ink.inkUI }

    static var paper: Color { native ? N.paper : Ink.paper }
    static var ink: Color { native ? N.ink : Ink.ink }
    /// Cards and outlined circles: the menu, the lists, the Full Access notice, ABC, Recent, and Settings.
    static var card: Color { native ? N.card : Ink.card }
    /// Secondary text: the line under Home's number, the live words while you talk.
    static var dim: Color { native ? N.dim : Ink.dim }
    /// Notices (a failure). `Ink.danger`, a step deeper in light so it holds 4.5:1 on the system's light gray.
    static let deep = Ink.dynC(0x9E361E, 0xFF8A6B, 0x8A2E18, 0xFFA48A)
    /// Metadata. `Ink.mute`, a step deeper in light so it holds 4.5:1 on the system's light gray and on `wash`.
    static var muted: Color { native ? N.muted : V.muted }
    static var hairline: Color { native ? N.hairline : Ink.hairline }
    /// Text and glyphs on the filled dictate button: fixed ink on butter (butter stays butter in dark); on the Native
    /// accent, white in light and black in dark (`PremiumInk.onAccent`; white on the dark accent measures 2.8:1).
    static var inkFixed: Color { native ? PremiumInk.onAccent : Ink.inkFixed }

    // Keyboard-only colors (not in Tokens.swift; defined here, not shared). The keys and soft surfaces are tuned
    // for Apple's keyboard backdrop rather than a panel of ours.
    /// The keyboard's one action, dictation: Tap to talk, Start, and Listening's done button. Butter in Verbose style
    /// (dark is #DDB563, a little lighter than `Ink.butter`'s dark value, so it holds up on the dark backdrop); the
    /// Native accent in Native.
    static var dictate: Color { native ? Ink.nativeAccent : V.dictate }
    /// The butter's 1.5 pt outline: fixed ink in light, as the mockup; none in dark, where a dark ring would
    /// melt into the dark backdrop and shrink the butter. The butter itself holds 8:1 against the dark gray. None in
    /// Native.
    static var dictateRim: Color { native ? Color.clear : V.dictateRim }
    /// Letter keys and the key popup: reader white in light; a raised gray-green in dark, lighter than the
    /// system's dark gray (1.7:1), with ink labels at 8.7:1 (7:1 with Increase Contrast, on a lighter key). Native:
    /// Apple's white and gray keys.
    static var key: Color { native ? N.key : V.key }
    /// The space bar's name on a key: `muted`, lighter in dark so it holds 5:1 on `key`.
    static var keyMuted: Color { native ? N.keyMuted : V.keyMuted }
    /// Chips, soft circles, and function keys: a warm step darker than the system's light gray in light (like
    /// Apple's function keys), and a quiet step above the backdrop in dark (1.3:1), under the letter keys. Native:
    /// Apple's gray function keys.
    static var wash: Color { native ? N.wash : V.wash }
    /// The butter pills' and the menu card's hard offset shadow. None in Native.
    static var hard: Color { native ? Color.clear : V.hard }
    /// A key's 1 pt bottom edge: ink at 25% in light (50% with Increase Contrast); a dark shadow in dark, as the
    /// system keys have (a light edge under a dark key reads as a rim), with a paper edge under Increase Contrast.
    static var keyShadow: Color { native ? N.keyShadow : V.keyShadow }
    /// The voice bars while you talk: ink in Verbose style, the accent in Native (the one place color moves).
    static var voice: Color { native ? Ink.nativeAccent : Ink.ink }

    /// Keys use a 7 pt radius, like the system keyboard's keys; cards use the Record panel's radius (12 pt in Native).
    static let keyRadius: CGFloat = 7
    static var cardRadius: CGFloat { native ? 12 : Radius.record }
    /// The top bar: 46 pt circles and pills, 10 pt from the edges.
    static let barHeight: CGFloat = 46
    static let barInset: CGFloat = 10

    /// The display serif in Verbose style; SF Pro in Native (bold where the serif was regular, as Apple's numbers are).
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        native ? .system(size: size, weight: weight == .regular ? .bold : weight) : Ink.serif(size, weight: weight)
    }
    /// Mono data in Verbose style; SF Pro with monospaced digits in Native.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        native ? .system(size: size, weight: weight).monospacedDigit() : Ink.mono(size, weight: weight)
    }

    /// Verbose style's keyboard colors.
    private enum V {
        static let muted = Ink.dynC(0x48514A, 0xA1A29A, 0x3E4A43, 0xD4CDC0)
        static let dictate = Ink.dyn(Ink.butterHex, 0xDDB563)
        static let dictateRim = Ink.make { dark, _ in dark ? PColor.clear : PColor(hex: Ink.inkHex) }
        static let key = Ink.dynC(Ink.readerHex, 0x3A4641, Ink.readerHex, 0x47544E)
        static let keyMuted = Ink.dynC(0x606962, 0xB9BAB2, 0x3E4A43, 0xD4CDC0)
        static let wash = Ink.dynC(0xCCC3B1, 0x2B3530, 0xC0B6A2, 0x36423C)
        static let hard = Ink.dyn(Ink.inkHex, 0x0C1310)
        static let keyShadow = Ink.make { dark, hc in
            if dark { return hc ? PColor(hex: Ink.paperHex).withAlphaComponent(0.35) : PColor.black.withAlphaComponent(0.5) }
            return PColor(hex: Ink.inkHex).withAlphaComponent(hc ? 0.5 : 0.25)
        }
    }

    /// Native's keyboard colors: Apple's gray keyboard approximated with flat colors (an extension can't use the
    /// system keyboard's glass or key art), over Apple's own backdrop. Secondary text holds 4.5:1 on the backdrop
    /// and on the function keys in both appearances.
    private enum N {
        static let paper = Ink.dyn(0xFFFFFF, 0x000000)
        static let ink = Ink.dyn(0x000000, 0xFFFFFF)
        static let card = Ink.dyn(0xFFFFFF, 0x3A3A3C)
        static let dim = Ink.dynC(0x48484D, 0xAEAEB2, 0x3C3C43, 0xC7C7CC)
        static let muted = Ink.dynC(0x3C3C43, 0xC7C7CC, 0x2C2C2E, 0xE5E5EA)
        static let key = Ink.dynC(0xFFFFFF, 0x6B6B6B, 0xFFFFFF, 0x7C7C80)
        static let keyMuted = Ink.dynC(0x6C6C70, 0xD1D1D6, 0x48484D, 0xE5E5EA)
        static let wash = Ink.dynC(0xACB1B9, 0x474747, 0x9EA3AB, 0x545456)
        static let keyShadow = Ink.make { dark, _ in dark ? PColor.black.withAlphaComponent(0.45) : PColor(white: 0.54, alpha: 1) }
        static let hairline = Ink.make { dark, _ in dark ? PColor.white.withAlphaComponent(0.16) : PColor.black.withAlphaComponent(0.14) }
    }
}

/// Three modes, like Wispr Flow's keyboard, in Verbose's look (the approved mockup, kb2). The dictate button's size,
/// position, and style follow Settings › Keyboard › Dictate button (`DictateButton`, the notch mockup's section 05):
/// Typing's Start, Home's Tap to talk, and Listening's done button move and change with it.
/// - Home: close and ABC (to Typing), Recent, and Settings over your numbers in the serif, with one butter Tap to talk.
///   With no session, the same layout offers Start a session instead (it opens Verbose straight into one), with
///   "Or use Control Center or the Action button" under it; when Verbose couldn't be opened, the other ways.
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
        // A new identity when the look changes (once per appearance, at most), so every KB color and font is read
        // again; the state worth keeping lives in the model.
        .id(model.native)
        .environment(\.look, model.native ? .native : .verbose)
        // No background: Apple's keyboard backdrop shows through (see `KB`).
    }

    // MARK: Bars

    /// The dictate button's settings, read each time the keyboard appears.
    private var look: DictateButton { model.dictateButton }

    /// The top bar's frame, shared by all three modes: 46 pt, or 62 pt in Typing and Listening with the large disc.
    private func bar<Content: View>(height: CGFloat = KB.barHeight, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .frame(height: height)
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
            Text(title).font(KB.serif(21)).foregroundStyle(KB.ink).lineLimit(1)
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
            if model.hasFullAccess, model.sessionLive, let ends = model.sessionEndsAt {
                SessionCountdown(clock: model.clock, endsAt: ends)
                Spacer(minLength: 6)
            }
            CircleButton(look: .outline, action: model.showTyping) {
                Text("ABC").font(.system(size: 15, weight: .bold))
            }
            .accessibilityLabel("Letter keys")
            .accessibilityHint("Shows the typing keyboard")
            if model.hasFullAccess {
                CircleButton(look: .outline, action: model.toggleRecent) { KBIcon(art: .iconRecent, symbol: "clock", size: 20, color: KB.ink, minLineWidth: 1.3) }
                    .accessibilityLabel("Recent dictations")
                    .accessibilityHint("Shows your last dictations to insert again")
            }
            CircleButton(look: .outline, action: model.openVerbose) { KBIcon(art: .iconSettings, symbol: "gearshape", size: 20, color: KB.ink, minLineWidth: 1.3) }
                .accessibilityLabel("Settings")
                .accessibilityHint(model.hasFullAccess ? "Opens Verbose" : "Shows how to turn on dictation")
        }
    }

    @ViewBuilder private var homeBody: some View {
        if !model.hasFullAccess {
            FullAccessCard()
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 10)
        } else if model.needsSessionCard {
            VStack(spacing: 0) {
                switch model.startCard {
                case .start:
                    StartSessionHeadline(returnsByItself: Distribution.current.returnsToHostApp)
                        .frame(maxHeight: .infinity)
                case .instructions:
                    StartSessionWays()
                        .padding(.horizontal, 10).padding(.top, 10)
                        .frame(maxHeight: .infinity)
                }
                Group {
                    if model.notice != nil || model.info != nil { statusLine }
                    else {
                        Text(StartCard.secondary)
                            .font(.system(size: 12.5)).foregroundStyle(KB.muted)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 6)
                talkRow(label: StartCard.title, hint: Distribution.current.returnsToHostApp
                        ? "Opens Verbose for a second to turn on the microphone, then comes back here"
                        : "Opens Verbose to turn on the microphone. Then tap the back link at the top left to come back")
            }
        } else {
            VStack(spacing: 0) {
                StatsPager(pages: model.statsPages, page: model.statsPage,
                           next: model.nextStatsPage, previous: model.previousStatsPage)
                    .frame(maxHeight: .infinity)
                statusLine.padding(.horizontal, 18).padding(.bottom, 6)
                talkRow(label: "Tap to talk", hint: model.sessionPaused ? "Paused for a call" : "Starts listening right away")
            }
        }
    }

    /// Home's one big action where the dictate button sits (left, center, or right), clear of the globe.
    private func talkRow(label: String, hint: String) -> some View {
        ZStack {
            HStack(spacing: 0) {
                if look.position != .left { Spacer(minLength: 0) }
                TalkPill(label: label, style: look.style, action: model.record)
                    .accessibilityHint(hint)
                if look.position != .right { Spacer(minLength: 0) }
            }
            .padding(.leading, look.position == .left && model.showsGlobe ? 42 : 0)
            if model.showsGlobe {
                HStack {
                    globe
                    Spacer()
                }
            }
        }
        .padding(.horizontal, KB.barInset).padding(.bottom, 10)
    }

    /// A failure, a short confirmation ("Copied."), or Paused for a call, above Tap to talk.
    @ViewBuilder private var statusLine: some View {
        if let n = model.notice {
            Text(n).font(.system(size: 12.5)).foregroundStyle(KB.deep)
                .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
        } else if let i = model.info {
            Text(i).font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.muted)
                .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
        } else if model.sessionPaused {
            Text("Paused for a call · picks up when it ends").font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var globe: some View {
        GlobeKey(controller: model.controllerForGlobe)
            .frame(width: 34, height: 34)
            .accessibilityLabel("Next keyboard")
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
            bar(height: barHeight) { correctionStrip(c) }
        } else if model.stage == .inserted {
            bar(height: barHeight) {
                if look.position == .left {
                    startButton
                }
                CheckDisc()
                Text("Inserted · \(model.insertion?.words ?? 0) \((model.insertion?.words ?? 0) == 1 ? "word" : "words")")
                    .font(.system(size: 13.5, weight: .semibold)).monospacedDigit().foregroundStyle(KB.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .layoutPriority(-1)
                Spacer(minLength: 6)
                Chip(title: "Undo") { model.undo() }
                    .accessibilityHint("Removes the inserted words")
                if look.position != .left {
                    startButton
                }
            }
        } else {
            // The menu and the dictate button, in the order the position gives (`DictateButton.typingBar`).
            bar(height: barHeight) {
                ForEach(Array(look.typingBar.enumerated()), id: \.offset) { i, slot in
                    switch slot {
                    case .menu:
                        if i == 0 {
                            menuButton
                            typingNotice
                        } else {
                            typingNotice
                            menuButton
                        }
                    case .spacer: Spacer(minLength: 6)
                    case .button: startButton
                    case .balance: Color.clear.frame(width: KB.barHeight, height: KB.barHeight).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// Typing's and Listening's bar height: 62 pt with the large disc, otherwise 46 pt.
    private var barHeight: CGFloat { CGFloat(look.barHeight) }

    private var menuButton: some View {
        CircleButton(look: model.showingMenu ? .active : .soft, action: model.toggleMenu) {
            Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .medium))
        }
        .accessibilityLabel("Menu")
        .accessibilityValue(model.showingMenu ? "Open" : "")
        .accessibilityHint("Cleanup, snippets, recent dictations, and Open Verbose")
    }

    @ViewBuilder private var typingNotice: some View {
        if let n = model.notice {
            Text(n).font(.system(size: 12)).foregroundStyle(KB.deep)
                .lineLimit(2).minimumScaleFactor(0.8)
                .accessibilityAddTraits(.updatesFrequently)
        } else if let i = model.info {
            Text(i).font(.system(size: 12, weight: .medium)).foregroundStyle(KB.muted)
                .lineLimit(2).minimumScaleFactor(0.8)
                .accessibilityAddTraits(.updatesFrequently)
        } else if model.sessionPaused {
            Text("Paused for a call").font(.system(size: 12, weight: .medium)).foregroundStyle(KB.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// Start: the 46 pt pill or the 62 pt disc, filled or outlined.
    private var startButton: some View {
        DictateStart(look: look, action: model.start)
            .accessibilityHint(startHint)
    }

    private var startHint: String {
        guard model.hasFullAccess else { return "Explains how to turn on dictation" }
        if model.sessionPaused { return "Paused for a call" }
        if model.sessionLive { return "Starts listening right away" }
        return Distribution.current.returnsToHostApp ? "Opens Verbose for a second to turn on the microphone, then comes back here"
            : "Opens Verbose to turn on the microphone. Then tap the back link at the top left to come back"
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
        // The menu button sits on the right when the dictate button is on the left.
        let trailing = look.position == .left
        return ZStack(alignment: trailing ? .topTrailing : .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.closeMenu() }
                .accessibilityHidden(true)
            MenuCard(model: model)
                .padding(trailing ? .trailing : .leading, KB.barInset).padding(.top, 8 + barHeight + 6)
        }
    }

    // MARK: Listening

    private var listening: some View {
        VStack(spacing: 0) {
            listeningBar
            VStack(spacing: 12) {
                listeningWords
                VoiceWave(clock: model.clock, active: model.stage == .listening, color: KB.voice, count: 13, barWidth: 6)
                    .frame(width: 170, height: 36)
                ListeningStatus(clock: model.clock, stage: model.stage, polishing: model.polishing,
                                words: model.insertion?.words ?? 0, micName: model.micName, engineReady: model.engineReady)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if model.showsGlobe { globe.padding(.leading, KB.barInset).padding(.bottom, 8) }
            }
        }
    }

    /// Cancel (hidden while polishing: the words are already in), the cleanup chip, and done. Done trails, or leads
    /// when the dictate button is on the left, so the thumb that started the take ends it.
    private var listeningBar: some View {
        bar(height: barHeight) {
            if look.doneLeads {
                doneButton
                Spacer(minLength: 6)
                cleanupChip
                cancelButton
            } else {
                cancelButton
                Spacer(minLength: 6)
                cleanupChip
                doneButton
            }
        }
    }

    @ViewBuilder private var cancelButton: some View {
        if model.polishing {
            Color.clear.frame(width: KB.barHeight, height: KB.barHeight).accessibilityHidden(true)
        } else {
            CircleButton(look: .soft, action: model.cancel) { Image(systemName: "xmark").font(.system(size: 16, weight: .medium)) }
                .accessibilityLabel("Cancel")
                .accessibilityHint(model.stage == .starting ? "Stops waiting for Verbose" : "Stops listening and inserts nothing")
        }
    }

    @ViewBuilder private var cleanupChip: some View {
        if model.hasFullAccess {
            CleanupChip(level: model.levelLabel, format: model.formatLabel, enabled: model.stage == .listening || model.stage == .starting) {
                model.cycleFormat()
            }
        }
    }

    /// Done: the 46 pt circle or the 62 pt disc, in the dictate button's style.
    private var doneButton: some View {
        DictateDone(look: look, action: { model.polishing ? model.skipPolish() : model.done() })
            .disabled(!doneEnabled)
            .opacity(doneEnabled ? 1 : 0.4)
            .accessibilityLabel("Done")
            .accessibilityHint(model.polishing ? "Stops waiting for the polished version and keeps your words"
                               : "Stops listening and inserts your words")
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

// MARK: - Clocked pieces

/// Time left in the session in Home's bar: "4:12 left". Watches the clock, so the countdown redraws only this.
private struct SessionCountdown: View {
    @ObservedObject var clock: KeyboardClock
    var endsAt: Date

    var body: some View {
        Text("\(KeyboardView.clock(endsAt.timeIntervalSince(clock.now))) left")
            .font(KB.mono(12)).foregroundStyle(KB.muted)
            .lineLimit(1).minimumScaleFactor(0.8)
            .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        let m = max(0, Int(endsAt.timeIntervalSince(clock.now)) / 60)
        return m >= 1 ? "Session on, \(m) minutes left" : "Session on, less than a minute left"
    }
}

/// Listening's title and the line under it. Watches the clock for the time, so it redraws only this.
private struct ListeningStatus: View {
    @ObservedObject var clock: KeyboardClock
    var stage: KeyboardModel.Stage
    var polishing: Bool
    /// The inserted words, shown while polishing.
    var words: Int
    var micName: String
    /// False while the app's speech model loads (the first dictation): "Getting ready".
    var engineReady = true

    private var warming: (title: String, detail: String)? {
        guard !polishing else { return nil }
        return ListeningCopy.lines(stage: stage == .listening ? "listening" : stage == .writing ? "writing" : "other", engineReady: engineReady)
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(KB.serif(22)).foregroundStyle(KB.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail)
                .font(detailIsData ? KB.mono(12) : .system(size: 12.5))
                .foregroundStyle(KB.muted)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var title: String {
        if polishing { return "Polishing…" }
        if let w = warming { return w.title }
        switch stage {
        case .starting: return "Opening Verbose…"
        case .writing: return "Writing it down"
        default: return "Listening"
        }
    }

    /// The microphone and the time while listening or writing (mono: it's data); a plain line otherwise.
    private var detail: String {
        if polishing { return "Inserted · \(words) \(words == 1 ? "word" : "words")" }
        if let w = warming { return w.detail }
        if stage == .starting {
            return Distribution.current.returnsToHostApp ? "Verbose opens for a second, then comes back" : "Verbose opens; tap ◀ at the top left to come back"
        }
        return "\(micName) · \(KeyboardView.clock(clock.elapsed))"
    }

    private var detailIsData: Bool { !polishing && stage != .starting && warming == nil }

    private var accessibility: String {
        if polishing { return "Inserted. Polishing your words" }
        if warming != nil {
            return stage == .listening ? "Getting ready. The first one takes a few seconds. Verbose is already listening."
                : "Getting ready. The first one takes a few seconds."
        }
        switch stage {
        case .starting: return "Starting a session"
        case .writing: return "Writing it down"
        default: return "Listening, \(Int(clock.elapsed)) seconds"
        }
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
                Text("\(Text(p.number)) \(Text(p.unit).italic(!KB.native))")
                    .font(KB.native ? .system(size: 36, weight: .bold) : KB.serif(50)).tracking(KB.native ? 0 : -1).foregroundStyle(KB.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(p.line)
                    .font(.system(size: 15)).foregroundStyle(KB.dim)
                    .multilineTextAlignment(.center).lineSpacing(2)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: 300)
            } else {
                // Before the first dictation.
                Text("\(Text("Talk, "))\(Text("don't type.").italic(!KB.native))")
                    .font(KB.native ? .system(size: 30, weight: .bold) : KB.serif(40)).tracking(KB.native ? 0 : -0.8).foregroundStyle(KB.ink)
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

/// Home's one big action: Tap to talk with five still voice bars, butter with grain (Filled) or card white with an
/// ink ring (Outline), with the hard shadow either way.
private struct TalkPill: View {
    var label: String
    var style: DictateButton.Style
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if KB.native {
                    Image(systemName: "mic.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(dictateForeground(style))   // brand: native
                } else {
                    StillBars(height: 18, barWidth: 3, color: dictateForeground(style))
                }
                Text(label).font(.system(size: 16, weight: .bold)).foregroundStyle(dictateForeground(style)).lineLimit(1)
            }
            .padding(.horizontal, 24).frame(height: 50)
            .dictateSurface(style, shape: Capsule(), shadow: CGSize(width: 3, height: 4))
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(label)
    }
}

/// Typing's Start (Settings › Keyboard › Dictate button): Standard is the 46 pt pill with the word Start and five
/// still voice bars (a glyph, not a meter); Large is a 62 pt disc with the bars only. Filled or Outline.
private struct DictateStart: View {
    var look: DictateButton
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            if look.size == .large {
                StillBars(height: 24, barWidth: 3.5, color: dictateForeground(look.style))
                    .frame(width: CGFloat(DictateButton.disc), height: CGFloat(DictateButton.disc))
                    .dictateSurface(look.style, shape: Circle(), shadow: CGSize(width: 3, height: 4))
            } else {
                HStack(spacing: 10) {
                    Text("Start").font(.system(size: 17, weight: .bold)).foregroundStyle(dictateForeground(look.style)).lineLimit(1)
                    StillBars(height: 20, barWidth: 3, color: dictateForeground(look.style))
                }
                .padding(.leading, 20).padding(.trailing, 16).frame(height: KB.barHeight)
                .dictateSurface(look.style, shape: Capsule(), shadow: CGSize(width: 2, height: 3))
            }
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(DictateButton.accessibilityLabel)
    }
}

/// Listening's done, in the dictate button's place and look: the 46 pt circle (no grain, as before) or the 62 pt
/// disc (with grain), filled or outlined.
private struct DictateDone: View {
    var look: DictateButton
    var action: () -> Void
    var body: some View {
        let large = look.size == .large
        let d = large ? CGFloat(DictateButton.disc) : KB.barHeight
        Button(action: action) {
            Image(systemName: "checkmark").font(.system(size: large ? 23 : 19, weight: .bold))
                .foregroundStyle(dictateForeground(look.style))
                .frame(width: d, height: d)
                .dictateSurface(look.style, shape: Circle(), shadow: large ? CGSize(width: 3, height: 4) : CGSize(width: 2, height: 3), grain: large)
        }
        .buttonStyle(PressFade())
        // Icon only, so VoiceOver would read "Checkmark".
        .accessibilityLabel("Done")
        .accessibilityHint("Stops listening and puts your words in")
    }
}

/// Five still voice bars (a glyph, not a meter), scaled to `height`.
private struct StillBars: View {
    var height: CGFloat
    var barWidth: CGFloat
    var color: Color
    private static let bars: [CGFloat] = [9, 16, 20, 12, 17]
    var body: some View {
        HStack(spacing: barWidth * 0.85) {
            ForEach(Self.bars.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: barWidth, height: Self.bars[i] * height / 20)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Text and glyphs on the dictate button: fixed ink on butter (butter stays butter in dark), adaptive ink on card.
private func dictateForeground(_ style: DictateButton.Style) -> Color {
    // Native: `PremiumInk.onAccent` on the accent (white in light, black in dark, DESIGN.md §13.3.4), or the accent
    // on a white key.
    if KB.native { return style == .filled ? PremiumInk.onAccent : Ink.nativeAccent }
    return style == .filled ? KB.inkFixed : KB.ink
}

private extension View {
    /// The dictate button's surface. Filled: butter with a 1.5 pt fixed-ink outline (none in dark, `KB.dictateRim`)
    /// and the grain. Outline: card white with a 1.5 pt ink ring. Both with a hard shadow offset by `shadow`.
    func dictateSurface<S: InsettableShape>(_ style: DictateButton.Style, shape: S, shadow: CGSize, grain: Bool = true) -> some View {
        background {
            ZStack {
                shape.fill(style == .filled ? KB.dictate : KB.card)
                if style == .filled && grain && !KB.native { GrainOverlay().clipShape(shape) }
            }
        }
        // Native: a flat .borderedProminent capsule (filled) or a white key (outline), no ring and no hard shadow.
        .overlay(shape.strokeBorder(style == .filled ? KB.dictateRim : (KB.native ? Color.clear : KB.ink), lineWidth: 1.5))
        .background(shape.fill(KB.hard).offset(x: shadow.width, y: shadow.height))
        .contentShape(shape)
    }
}

/// A 46 pt circle in the top bar: soft (wash), outline (card with an ink ring), or active (ink, for the open menu).
/// Listening's done is `DictateDone`.
private struct CircleButton<Label: View>: View {
    enum Look { case soft, outline, active }
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
                .contentShape(Circle())
        }
        .buttonStyle(PressFade())
    }

    private var fill: Color {
        switch look {
        case .soft: return KB.wash
        case .outline: return KB.card
        case .active: return KB.ink
        }
    }

    private var foreground: Color {
        switch look {
        case .active: return KB.paper
        default: return KB.ink
        }
    }

    @ViewBuilder private var ring: some View {
        switch look {
        // Native: a plain white key, no ink ring.
        case .outline: if !KB.native { Circle().strokeBorder(KB.ink, lineWidth: 1.5) }
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
                row(.iconAI, "wand.and.stars", "Cleanup", value: "\(model.levelLabel) · \(model.formatLabel)",
                    spoken: ("Format: \(model.formatLabel)", "Cleanup: \(model.levelLabel)"),
                    hint: "Changes how Verbose cleans up your dictations: Auto, Email, Message, or Note",
                    adjustable: true, action: model.cycleFormat)
                if !model.snippets.isEmpty {
                    row(.iconQuote, "text.quote", "Snippets", value: "\(model.snippets.count)", hint: "Shows your snippets to insert",
                        action: model.toggleSnippets)
                }
                if !model.recent.isEmpty {
                    row(.iconRecent, "clock", "Recent dictations", hint: "Shows your last dictations to insert again", action: model.toggleRecent)
                }
                if model.stage == .inserted, let ins = model.insertion, ins.raw != ins.text, !ins.raw.isEmpty {
                    row(.iconSwap, "arrow.uturn.backward", "Use as spoken", hint: "Replaces the cleaned-up words with the words as you said them") {
                        model.closeMenu()
                        model.useAsSpoken()
                    }
                }
            }
            row(.iconSettings, "gearshape", "Open Verbose", hint: model.hasFullAccess ? "Opens the Verbose app" : "Shows how to turn on dictation",
                action: model.openVerbose)
        }
        .padding(6)
        .frame(width: 228)
        .background(KB.card, in: RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous))
        // Verbose style: the ink outline and hard shadow. Native: a soft system shadow.
        .overlay(RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous).strokeBorder(KB.native ? Color.clear : KB.ink, lineWidth: 1.5))
        .background(RoundedRectangle(cornerRadius: KB.cardRadius, style: .continuous).fill(KB.hard).offset(x: 4, y: 5))
        .shadow(color: KB.native ? Color.black.opacity(0.18) : Color.clear, radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { model.closeMenu() }
    }

    /// One row: a brand icon, the name, and a mono value on the right. `spoken` overrides VoiceOver's label and
    /// value; `adjustable` lets VoiceOver swipe up or down to run the action again.
    private func row(_ art: BrandArt, _ symbol: String, _ title: String, value: String? = nil, spoken: (String, String)? = nil,
                     hint: String, adjustable: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                KBIcon(art: art, symbol: symbol, size: 18, color: KB.ink)
                Text(title).font(.system(size: 14.5)).foregroundStyle(KB.ink).lineLimit(1)
                Spacer(minLength: 6)
                if let value {
                    Text(value).font(KB.mono(12)).foregroundStyle(KB.muted).lineLimit(1).minimumScaleFactor(0.75)
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
                    if !KB.native { GrainOverlay().clipShape(shape) }
                }
            }
            .overlay { if !KB.native { shape.strokeBorder(KB.ink, lineWidth: 1.5) } }
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
                    KBIcon(art: .iconPrivacy, symbol: "lock", size: 22, color: KB.ink)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            }
            Text("\(Text("Dictation needs "))\(Text("Full Access.").italic(!KB.native))")
                .font(KB.serif(21)).foregroundStyle(KB.ink)
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

/// Home with no session, in the kb2 Home's place for the numbers: "Start a session *to dictate.*" in the serif
/// and what Start a session does. The butter Start a session pill and the quieter line sit below it, where Tap to
/// talk does.
private struct StartSessionHeadline: View {
    var returnsByItself: Bool
    var body: some View {
        VStack(spacing: 6) {
            Text("\(Text("Start a session "))\(Text("to dictate.").italic(!KB.native))")
                .font(KB.serif(34)).tracking(KB.native ? 0 : -0.6).foregroundStyle(KB.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.6)
            Text(StartCard.detail(returnsByItself: returnsByItself))
                .font(.system(size: 14)).foregroundStyle(KB.dim)
                .multilineTextAlignment(.center).lineSpacing(1.5)
                .lineLimit(2).minimumScaleFactor(0.8)
                .frame(maxWidth: 320)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// When the keyboard couldn't open Verbose (iOS refused): the three other ways to start a session, in the notice
/// card. Start a session stays below it, to try again.
private struct StartSessionWays: View {
    private static let symbols = ["square.grid.2x2", "button.horizontal.top.press", "arrow.up.forward.app"]

    var body: some View {
        CardShell {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Text("Verbose didn't open. "))\(Text("Try one of these.").italic(!KB.native))")
                    .font(KB.serif(19)).foregroundStyle(KB.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                ForEach(Array(StartCard.ways.enumerated()), id: \.offset) { i, text in
                    way(Self.symbols[i], text)
                }
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
                Text(meta).font(KB.mono(12)).foregroundStyle(KB.muted).lineLimit(1)
                Text(Self.oneLine(text)).font(.system(size: 14.5)).foregroundStyle(KB.ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Insert").font(.system(size: 13, weight: .bold)).foregroundStyle(KB.native ? Ink.nativeAccent : KB.ink)
                .padding(.horizontal, 11).frame(height: 28)
                .background(Capsule().fill(KB.native ? KB.wash : Color.clear))
                .overlay(Capsule().strokeBorder(KB.native ? Color.clear : KB.ink, lineWidth: 1.3))
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
                KBIcon(art: .iconAI, symbol: "wand.and.stars", size: 14, color: KB.ink)
                Text(level).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(KB.ink).lineLimit(1)
                Text("· \(format)").font(.system(size: 13.5, weight: .medium)).foregroundStyle(KB.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if enabled {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(KB.ink)
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(KB.wash, in: RoundedRectangle(cornerRadius: KB.native ? 17 : Radius.button, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: KB.native ? 17 : Radius.button, style: .continuous))
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
    /// The voice level (`clock.level`): watched here, so the level redraws only the bars.
    @ObservedObject var clock: KeyboardClock
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
        let lifted = pow(min(1, max(0, clock.level)), 0.6)
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
            .font(KB.native ? .system(size: size) : KB.serif(size))
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
            let spans = LiveSpansMemo.spans(full)
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

/// The live words' spoken-correction spans for the last text seen: the line redraws for other reasons too (the
/// keyboard's own state), and the rules run again only when the words changed. `liveSpans` runs them on the last
/// few sentences only, so each new word costs the same however long the dictation gets.
@MainActor
private enum LiveSpansMemo {
    private static var text = ""
    private static var spans: [SpokenCorrections.Span] = []

    static func spans(_ full: String) -> [SpokenCorrections.Span] {
        if full != text {
            text = full
            spans = SpokenCorrections.liveSpans(full, limit: 160)
        }
        return spans
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
                .background(KB.wash, in: RoundedRectangle(cornerRadius: KB.native ? 17 : Radius.button, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: KB.native ? 17 : Radius.button, style: .continuous))
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
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.native ? PremiumInk.onAccent : KB.paper).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 30)
                .background(KB.native ? Ink.nativeAccent : KB.ink, in: Capsule())
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

// brand: native begin
/// A brand line icon in Verbose style; its SF Symbol in Native (Recent → clock, Settings → gearshape).
struct KBIcon: View {
    var art: BrandArt
    var symbol: String
    var size: CGFloat
    var color: Color
    var minLineWidth: CGFloat = 1.2

    var body: some View {
        if KB.native {
            Image(systemName: symbol).font(.system(size: size * 0.82, weight: .medium)).foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            KBGlyph(art: art, size: size, color: color, minLineWidth: minLineWidth)
        }
    }
}
// brand: native end
