import SwiftUI
import UIKit

// Verbose Unlock's screens on iPhone (approved mockup "Verbose Unlock on iPhone", October 31, 2026; DESIGN.md §21), on
// the refined kit (§13): the unlock sheet, the screens that present it, Home's card, the Settings row, the recorder's
// 9:00 chip, and the welcome tour's offer. The store and StoreKit are in Unlock.swift; the rules and every line of
// copy are in Verbatim/Model/Entitlement.swift.

// MARK: - Glyphs

/// The unlock's fine-line glyphs, on the icon set's 24-unit grid with its 1.5 stroke. Kept here, outside the generated
/// block in Brand.swift (tools/gen_icons.py rewrites that); arcs are cubic curves, as SVGPathData reads no arcs.
extension BrandArt {
    /// An open padlock: the Settings row before you unlock.
    static let iconUnlock = BrandArt(box: iconGrid, strokes: [
        .rect(5, 11, 14, 9, 2),
        .path("M8 11V8C8 6.13 9.3 4.51 11.12 4.1C12.95 3.69 14.82 4.6 15.62 6.29"),
    ], strokeWidth: 1.5)
    /// A check: the thank-you row once unlocked.
    static let iconUnlocked = BrandArt(box: iconGrid, strokes: [.path("M5 12.5L9.2 16.7L19 7")], strokeWidth: 1.5)
    /// Two arrows in a circle: Restore Purchases.
    static let iconRestore = BrandArt(box: iconGrid, strokes: [
        .path("M4 12C4 8.75 5.96 5.83 8.97 4.6C11.98 3.37 15.43 4.08 17.71 6.39L20 9"), .path("M20 4V9H15"),
        .path("M20 12C20 15.25 18.04 18.17 15.03 19.4C12.02 20.63 8.57 19.92 6.29 17.61L4 15"), .path("M4 20V15H9"),
    ], strokeWidth: 1.5)
}

// MARK: - Who presents the sheet

/// A screen that can present the unlock sheet: the root, Settings, the recorder, the export sheet, and the template
/// editor. iOS shows one sheet per presenter, so the sheet opens on the topmost of them (`UnlockStore.ask`): from
/// Settings over Settings, from the recorder's chip over the recorder, and from anywhere else over the root.
struct UnlockSheetHost: ViewModifier {
    /// The root also takes a request made before any screen appeared.
    var root = false
    @ObservedObject private var unlock = UnlockStore.shared
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { unlock.hostAppeared(token) }
            .onDisappear { unlock.hostGone(token) }
            .sheet(item: Binding(get: { mine(unlock.request) }, set: { r in if r == nil, mine(unlock.request) != nil { unlock.request = nil } })) { r in
                UnlockSheet(request: r)
            }
    }

    private func mine(_ r: UnlockRequest?) -> UnlockRequest? {
        guard let r else { return nil }
        if r.host == token || (root && r.host == nil) { return r }
        return nil
    }
}

extension View {
    /// Lets this screen present the unlock sheet (`UnlockSheetHost`).
    func unlockSheetHost(root: Bool = false) -> some View { modifier(UnlockSheetHost(root: root)) }
}

// MARK: - The sheet

/// The unlock sheet (mockup, "The unlock sheet"): the serif title, a line on what the purchase is, what it adds in a
/// card, then "Try it free for 7 days" and "Unlock for $14.99" before the trial was ever started, or Unlock alone after,
/// the fine print (the trial's length, that it charges nothing and doesn't renew, and what happens after; guideline
/// 3.1.1), and Restore Purchases, Terms, and Privacy. The price is the App Store's, in the person's currency.
struct UnlockSheet: View {
    var request: UnlockRequest
    @ObservedObject private var unlock = UnlockStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// How many unlock sheets are on screen, and which buttons the last one drew, for the self-test.
    static var onScreen = 0
    static var lastOffersTrial: Bool? = nil

    private let items: [(BrandArt, RefinedHue)] = [(.capture, .persimmon), (.iconDownload, .sage), (.iconCaptions, .petal),
                                                   (.iconSummaries, .butter), (.iconExport, .sage)]

    var body: some View {
        let state = unlock.state
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Refined.mute)
                        .frame(width: 30, height: 30).background(Refined.neutral, in: Circle())
                        .frame(width: CGFloat(RefinedRules.minTapTarget), height: CGFloat(RefinedRules.minTapTarget))
                        .contentShape(Circle())
                }
                .buttonStyle(RefinedPress())
                .accessibilityLabel("Close")
                .accessibilityIdentifier("unlock.close")
            }
            .padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(UnlockCopy.sheetTitle).refinedFont(.transcriptTitle).foregroundStyle(Refined.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(UnlockCopy.sheetLede).refinedFont(.body).foregroundStyle(Refined.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                    PaperCard {
                        ForEach(Array(UnlockCopy.items.enumerated()), id: \.offset) { i, item in
                            if i > 0 { PaperDivider(leading: 56) }
                            HStack(spacing: 12) {
                                IconSquare(art: items[i].0, hue: items[i].1)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                                    Text(item.detail).refinedFont(.meta).foregroundStyle(Refined.mute)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 14)
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            buttons(state)
            Text(finePrint(state)).refinedFont(.caption).foregroundStyle(Refined.mute)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity).padding(.top, 8)
            if let p = unlock.problem {
                Text(p).refinedFont(.meta).foregroundStyle(Refined.danger)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity).padding(.top, 6)
                    .accessibilityIdentifier("unlock.problem")
            }
            HStack(spacing: 22) {
                quiet(UnlockCopy.restore) { Task { let line = await unlock.restore(); if unlock.request != nil, !line.isEmpty { unlock.problem = line } } }
                    .disabled(unlock.busy != nil)
                quiet(UnlockCopy.terms) { openURL(Links.terms) }
                quiet(UnlockCopy.privacy) { openURL(Links.privacy) }
            }
            .frame(maxWidth: .infinity).padding(.top, 4)
        }
        .padding(.horizontal, 22).padding(.bottom, 8)
        .background(Refined.paper.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Refined.paper)
        .task { if unlock.prices.isEmpty { await unlock.loadPrices() } }
        .onAppear { Self.onScreen += 1; Self.lastOffersTrial = state.offersTrial }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
        .accessibilityIdentifier("unlock.sheet")
    }

    /// The trial first and Unlock second before the trial was ever started; Unlock alone after.
    @ViewBuilder private func buttons(_ state: EntitlementState) -> some View {
        VStack(spacing: 10) {
            if state.offersTrial {
                Button { Task { await unlock.startTrial() } } label: { big(UnlockCopy.tryFree, busy: unlock.busy == .trial, strong: true) }
                    .buttonStyle(RefinedActionStyle(kind: .strong))
                    .accessibilityIdentifier("unlock.trial")
                Button { Task { await unlock.buyUnlock() } } label: { big(UnlockCopy.unlockButton(price: unlock.price), busy: unlock.busy == .unlock, strong: false) }
                    .buttonStyle(RefinedActionStyle(kind: .quiet, wash: Refined.card))
                    .accessibilityIdentifier("unlock.buy")
            } else if !state.hasEverything || state.isTrial {
                Button { Task { await unlock.buyUnlock() } } label: { big(UnlockCopy.unlockButton(price: unlock.price), busy: unlock.busy == .unlock, strong: true) }
                    .buttonStyle(RefinedActionStyle(kind: .strong))
                    .accessibilityIdentifier("unlock.buy")
            }
        }
        .disabled(unlock.busy != nil)
    }

    private func big(_ title: String, busy: Bool, strong: Bool) -> some View {
        ZStack {
            Text(title).opacity(busy ? 0 : 1)
            if busy { ProgressView().tint(strong ? Refined.paper : Refined.ink) }
        }
        .refinedFont(.rowTitle, weight: .semibold)
        .frame(maxWidth: .infinity).frame(minHeight: 50)
    }

    private func finePrint(_ state: EntitlementState) -> String {
        switch state {
        case .free: return UnlockCopy.trialFinePrint
        case .trial(_, let days): return UnlockCopy.inTrialFinePrint(daysLeft: days)
        case .trialEnded, .unlocked: return UnlockCopy.onceFinePrint
        }
    }

    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .refinedFont(.hint, weight: .medium).foregroundStyle(Refined.accentText)
            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
    }
}

// MARK: - Home's card

/// One card at the top of Home, where What's new shows (mockup): the trial ends tomorrow, the trial ended (once), a
/// free recording saved its first 10 minutes, or shared items wait for Import. Unlock opens the sheet; Not now (or OK)
/// hides the card. No notifications, no countdown anywhere else.
struct UnlockHomeCard: View {
    /// Space above the card, only while it shows.
    var top: CGFloat = 0
    @ObservedObject private var unlock = UnlockStore.shared
    /// The card Home drew last, for the self-test.
    static var shown: UnlockCard? = nil

    var body: some View {
        let card = unlock.homeCard
        Group {
            if let card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(UnlockCopy.cardTitle(card)).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(UnlockCopy.cardBody(card)).refinedFont(.hint).foregroundStyle(Refined.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 20) {
                        Button(UnlockCopy.cardAction(card, price: unlock.price)) { unlock.ask(nil) }
                            .refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText)
                            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                            .accessibilityIdentifier("home.unlockCard.unlock")
                        Button(UnlockCopy.cardDismiss(card)) { unlock.dismiss(card) }
                            .refinedFont(.hint, weight: .medium).foregroundStyle(Refined.mute)
                            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                            .accessibilityHint("Hides this card")
                    }
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                .padding(.top, top)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home.unlockCard")
            }
        }
        .onAppear { Self.shown = card }
        .onChange(of: card) { _, c in Self.shown = c }
    }
}

// MARK: - Settings

/// The row under Settings' search field, above the groups (mockup, "Settings"): the free version ("Try it free for 7
/// days" and the price), the trial and its days left, or once unlocked a quiet thank-you row that opens nothing. The
/// others open the unlock sheet over Settings.
struct UnlockSettingsRow: View {
    var flash: String?
    @ObservedObject private var unlock = UnlockStore.shared

    var body: some View {
        let c = UnlockRowContent.make(unlock.state, price: unlock.price)
        Group {
            if c.thanks {
                face(c)
            } else {
                Button { unlock.ask(nil) } label: { face(c) }
                    .buttonStyle(RefinedPress())
                    .accessibilityHint("Opens Verbose Unlock")
            }
        }
        .accessibilityIdentifier("settings.unlock")
    }

    private func face(_ c: UnlockRowContent) -> some View {
        HStack(spacing: 12) {
            IconSquare(art: c.thanks ? .iconUnlocked : .iconUnlock, hue: c.thanks ? .sage : .persimmon, side: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                Text(c.subtitle).refinedFont(.meta).foregroundStyle(Refined.mute)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let v = c.value { SettingsValue(v) }
            if !c.thanks { SettingsChevron() }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: CGFloat(RefinedRules.minTapTarget), alignment: .leading)
        .settingsSearchTarget("verboseUnlock", flash: flash)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .contentShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The recorder

/// The recorder's chip from 9:00 on a free recording (mockup, "The limit, while recording"): "Saves at 10:00 · Unlock to
/// keep going" on the persimmon tint, centered under the clock. A tap opens the unlock sheet over the recorder;
/// unlocking removes the limit and the chip, and the recording goes on. Nothing interrupts before 9:00.
struct RecordingLimitChip: View {
    @ObservedObject private var unlock = UnlockStore.shared
    /// Whether the chip drew, for the self-test.
    static var visible = false

    var body: some View {
        Group {
            if unlock.capPhase == .warning {
                Button { unlock.ask(.longRecordings) } label: {
                    Text(UnlockCopy.recorderChip).refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText)
                        .lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Refined.persimmonTint, in: Capsule())
                        .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                        .contentShape(Rectangle())
                }
                .buttonStyle(RefinedPress())
                .frame(maxWidth: .infinity)
                .accessibilityHint("Opens Verbose Unlock. Free recordings save at 10 minutes.")
                .accessibilityIdentifier("recorder.limitChip")
                .onAppear { Self.visible = true }
                .onDisappear { Self.visible = false }
            }
        }
    }
}

// MARK: - The welcome tour

/// The welcome tour's last step offers the trial once (Tim's decision, October 31, 2026): "Try everything free for 7
/// days", what it adds, that it's free and doesn't renew, and what happens after, with Start free trial (Apple's
/// purchase sheet at $0.00) and Not now. Either one, or a started trial, ends the offer for good.
struct UnlockTourOffer: View {
    @ObservedObject private var unlock = UnlockStore.shared
    @AppStorage(UnlockStore.tourOfferKey) private var offered = false
    @State private var started = false

    var body: some View {
        if started && unlock.state.isTrial {
            Label { Text(UnlockCopy.trialStartedToast) } icon: { ArtIcon(art: .iconUnlocked, size: 14) }
                .refinedFont(.hint).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
        } else if unlock.state.offersTrial && !offered {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    IconSquare(art: .iconUnlock, hue: .butter)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UnlockCopy.tourTitle).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        Text(UnlockCopy.tourBody).refinedFont(.meta).foregroundStyle(Refined.mute)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 10) {
                    Button {
                        Task {
                            await unlock.startTrial()
                            if unlock.state.isTrial { started = true; offered = true }
                        }
                    } label: {
                        ZStack {
                            Text(UnlockCopy.tourStart).opacity(unlock.busy == .trial ? 0 : 1)
                            if unlock.busy == .trial { ProgressView().tint(Refined.paper) }
                        }
                    }
                    .buttonStyle(RefinedActionStyle(kind: .strong))
                    .disabled(unlock.busy != nil)
                    .accessibilityIdentifier("onboarding.trial")
                    Button(UnlockCopy.notNow) { offered = true }
                        .buttonStyle(RefinedActionStyle())
                        .accessibilityIdentifier("onboarding.trial.notNow")
                }
                .padding(.leading, 44)
                if let p = unlock.problem {
                    Text(p).refinedFont(.meta).foregroundStyle(Refined.danger).fixedSize(horizontal: false, vertical: true).padding(.leading, 44)
                }
            }
            .padding(16)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            .accessibilityIdentifier("onboarding.trialOffer")
        }
    }
}
