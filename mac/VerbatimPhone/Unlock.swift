import Foundation
import Combine
import StoreKit
import UIKit

// Verbose Unlock on iPhone (DESIGN.md §21; mac/APP_STORE.md, In-app purchase): the StoreKit 2 side and the store the
// screens observe. The rules (the state, the gate, the 10-minute limit, Home's cards, the Settings row, the copy) are
// pure and live in Verbatim/Model/Entitlement.swift, which mac/tools/test-entitlement.sh checks on Linux. The views
// are in UnlockViews.swift. This is the only file that imports StoreKit.
//
// The entitlement comes only from StoreKit on this iPhone: `Transaction.all` and `Transaction.currentEntitlements` at
// launch, and `Transaction.updates` while Verbose runs (a refund, Ask to Buy, a purchase on another iPhone). The last
// records are cached (`UnlockCache`) so a launch with no network shows the right state at once, then StoreKit is asked
// again. A Mac license never unlocks the iPhone, and nothing unlocks from iCloud sync.

// MARK: - StoreKit 2

/// The real store: verified transactions and prices from StoreKit 2, purchases through Apple's purchase sheet, and
/// Restore Purchases through `AppStore.sync()`. `StoreKit.Transaction` is spelled out because SwiftUI has a
/// `Transaction` of its own.
final class StoreKitPurchases: PurchaseBackend {
    private var listener: Task<Void, Never>? = nil

    deinit { listener?.cancel() }

    func records() async -> [PurchaseRecord] {
        var byID: [UInt64: PurchaseRecord] = [:]
        // Every transaction (refunded ones too, with their revocation date), then the current entitlements, which a
        // fresh install may know before `all` has caught up. One record per transaction.
        for await result in StoreKit.Transaction.all { Self.add(result, to: &byID) }
        for await result in StoreKit.Transaction.currentEntitlements { Self.add(result, to: &byID) }
        return byID.values.sorted { $0.purchaseDate < $1.purchaseDate }
    }

    /// Only verified transactions for the two unlock products count.
    private static func add(_ result: VerificationResult<StoreKit.Transaction>, to records: inout [UInt64: PurchaseRecord]) {
        guard case .verified(let t) = result, UnlockProduct.all.contains(t.productID) else { return }
        records[t.id] = PurchaseRecord(productID: t.productID, purchaseDate: t.purchaseDate, revokedAt: t.revocationDate, transactionID: String(t.id))
    }

    func prices() async -> [String: String] {
        guard let products = try? await Product.products(for: UnlockProduct.all) else { return [:] }
        var out: [String: String] = [:]
        for p in products { out[p.id] = p.displayPrice }
        return out
    }

    func purchase(_ productID: String) async -> PurchaseOutcome {
        do {
            guard let product = try await Product.products(for: [productID]).first else { return .failed(UnlockCopy.offline) }
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let t) = verification else { return .failed(UnlockCopy.failed) }
                await t.finish()
                return .purchased
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .cancelled
            }
        } catch {
            Log.note("unlock: the purchase didn't finish: \(error.localizedDescription)")
            return .failed(UnlockCopy.failed)
        }
    }

    func restore() async -> Bool {
        do { try await AppStore.sync(); return true } catch {
            Log.note("unlock: Restore Purchases didn't finish: \(error.localizedDescription)")
            return false
        }
    }

    func listen(_ changed: @escaping () -> Void) {
        listener?.cancel()
        listener = Task.detached(priority: .utility) {
            // Transactions that arrived while Verbose wasn't running, then the ones that arrive while it is.
            for await result in StoreKit.Transaction.unfinished {
                if case .verified(let t) = result { await t.finish() }
            }
            changed()
            for await result in StoreKit.Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                changed()
            }
        }
    }
}

// MARK: - The store

/// Why the unlock sheet is open: the locked feature tapped (nil from Settings, a Home card, or the welcome tour) and
/// the screen that presents it (`UnlockSheetHost`).
struct UnlockRequest: Identifiable, Equatable {
    let id = UUID()
    var feature: LockedFeature?
    /// The presenting screen's token; nil means the root.
    var host: UUID?
}

/// What the sheet's buttons are waiting on.
enum UnlockBusy: Equatable { case trial, unlock, restore }

/// The entitlement on this iPhone, for the screens: the state, the prices, the sheet, Home's cards, and the 10-minute
/// limit. Created at launch (PhoneHolder), before anything reads `FeatureGate`.
@MainActor
final class UnlockStore: ObservableObject {
    static let shared = UnlockStore()
    /// The welcome tour offered the trial (once).
    nonisolated static let tourOfferKey = "unlock.tour.trialOffered"

    @Published private(set) var state: EntitlementState
    /// Prices by product ID, in the person's currency, once the App Store answers.
    @Published private(set) var prices: [String: String] = [:]
    @Published var request: UnlockRequest? = nil
    @Published private(set) var busy: UnlockBusy? = nil
    /// Why the last purchase didn't finish, shown on the sheet (or the welcome tour's card).
    @Published var problem: String? = nil
    /// Home's cards: what was dismissed, and a capped recording waiting to be explained.
    @Published private(set) var cards = UnlockCardMemory.load()
    /// Files and links waiting in the share inbox while Import is locked.
    @Published private(set) var sharedWaiting = 0
    /// The running recording against the limit: the recorder's chip shows from `.warning`.
    @Published private(set) var capPhase: RecordingCap.Phase = .none

    let backend: PurchaseBackend
    private(set) var records: [PurchaseRecord]
    private weak var app: PhoneState?
    private var bag = Set<AnyCancellable>()
    private var timer: Timer? = nil
    /// The screens that can present the sheet, in the order they appeared; the last one presents.
    private var hosts: [UUID] = []
    /// Whether a recording is running for the limit to watch, and whether it started with everything allowed.
    private var capActive = false
    private var capStartedWithEverything = true
    private var capStopping = false

    var price: String? { prices[UnlockProduct.unlock] }
    var hasEverything: Bool { state.hasEverything }
    /// Home's card now, if any.
    var homeCard: UnlockCard? { UnlockCards.card(state: state, now: Date(), memory: cards, sharedWaiting: sharedWaiting) }

    private init() {
        // The self-test starts unlocked with a stand-in store, so the tours before its own keep working.
        if PhoneUITest.enabled {
            let stub = StubPurchases.unlocked()
            backend = stub
            records = stub.stored
        } else {
            backend = StoreKitPurchases()
            records = UnlockCache.load()
        }
        state = Entitlement.state(records, now: Date())
        // Plan my day (and Make a plan, which it replaced) stays free, Brain dump's automatic run included.
        FeatureGate.freeTemplates = [TemplateLibrary.planMyDayID, TranscriptActions.makeAPlanID]
        FeatureGate.onDenied = { feature in Task { @MainActor in UnlockStore.shared.ask(feature) } }
        FeatureGate.enforce(state)
        Log.note("unlock: starts as \(state.logName) (cached)")
    }

    /// At launch, once PhoneState exists: StoreKit's transactions and updates, the limit on recordings, and a clock
    /// for the trial's days.
    func attach(_ app: PhoneState) {
        self.app = app
        backend.listen { Task { @MainActor in await UnlockStore.shared.refresh() } }
        Task { await refresh() }
        // The limit: a recording starts (or the self-test's stand-in does), then the recorder's clock ticks about 14 times
        // a second while it records, in the background too.
        app.recorder.$isRecording.combineLatest(app.$previewRecording)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] active in MainActor.assumeIsolated { self?.capSession(active) } }
            .store(in: &bag)
        app.recorder.live.$elapsed
            .sink { [weak self] e in MainActor.assumeIsolated { self?.capTick(e) } }
            .store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { UnlockStore.shared.recompute() }
        }
    }

    /// Verbose came forward: the trial's days, and the prices if the App Store hadn't answered.
    func becameActive() {
        recompute()
        if prices.isEmpty { Task { await loadPrices() } }
    }

    // MARK: State

    /// Reads the transactions again (launch, an update, a purchase, Restore Purchases) and caches them.
    func refresh() async {
        let r = await backend.records()
        records = r
        if !PhoneUITest.enabled { UnlockCache.save(r) }
        recompute()
        if prices.isEmpty { await loadPrices() }
    }

    func loadPrices() async {
        let p = await backend.prices()
        if !p.isEmpty { prices = p }
    }

    /// The state at this moment, pushed to the gate. Gaining everything imports what waited in the share inbox.
    func recompute(now: Date = Date()) {
        let s = Entitlement.state(records, now: now)
        FeatureGate.enforce(s)
        guard s != state else { return }
        let gained = s.hasEverything && !state.hasEverything
        Log.note("unlock: \(state.logName) → \(s.logName)")
        state = s
        if gained { sharedWaiting = 0; app?.importInbox() }
    }

    // MARK: The sheet

    /// Opens the unlock sheet on the topmost screen that can present it. `feature` is what was tapped (nil from
    /// Settings, a Home card, or the welcome tour).
    func ask(_ feature: LockedFeature?) {
        // One sheet at a time; a request whose sheet never showed (its screen was covered) gives way to the next.
        guard request == nil || UnlockSheet.onScreen == 0 else { return }
        problem = nil
        request = UnlockRequest(feature: feature, host: hosts.last)
        Log.note("unlock: the sheet opens" + (feature.map { " for \($0.rawValue)" } ?? ""))
    }

    /// True when the trial or Verbose Unlock covers `feature`; otherwise opens the sheet and returns false.
    @discardableResult
    func allow(_ feature: LockedFeature) -> Bool {
        if state.hasEverything { return true }
        ask(feature)
        return false
    }

    func hostAppeared(_ token: UUID) { hosts.removeAll { $0 == token }; hosts.append(token) }
    func hostGone(_ token: UUID) {
        hosts.removeAll { $0 == token }
        // A sheet whose screen closed under it goes too, so the next request can open.
        if let r = request, let h = r.host, h == token { request = nil }
    }

    // MARK: Buying

    func startTrial() async { await buy(UnlockProduct.trial) }
    func buyUnlock() async { await buy(UnlockProduct.unlock) }

    private func buy(_ productID: String) async {
        guard busy == nil else { return }
        busy = productID == UnlockProduct.trial ? .trial : .unlock
        problem = nil
        let outcome = await backend.purchase(productID)
        await refresh()
        busy = nil
        switch outcome {
        case .purchased:
            Log.note("unlock: bought \(productID == UnlockProduct.trial ? "the trial" : "Verbose Unlock")")
            request = nil
            app?.say(productID == UnlockProduct.trial ? UnlockCopy.trialStartedToast : UnlockCopy.unlockedToast)
        case .pending:
            problem = UnlockCopy.pending
        case .failed(let why):
            problem = why
        case .cancelled:
            break
        }
    }

    /// Restore Purchases (the sheet and Settings): the line to show. A restore that brings the trial or Verbose
    /// Unlock back closes the sheet.
    func restore() async -> String {
        guard busy == nil else { return "" }
        busy = .restore
        problem = nil
        let reached = await backend.restore()
        await refresh()
        busy = nil
        switch state {
        case .unlocked: request = nil; return UnlockCopy.restoredUnlock
        case .trial: request = nil; return UnlockCopy.restoredTrial
        case .free, .trialEnded: return reached ? UnlockCopy.nothingToRestore : UnlockCopy.offline
        }
    }

    // MARK: Home's cards and the inbox

    func dismiss(_ card: UnlockCard) {
        cards = UnlockCards.dismissed(card, cards)
        cards.save()
    }

    /// The share inbox's waiting items while Import is locked (PhoneInbox.swift).
    func setSharedWaiting(_ n: Int) { if sharedWaiting != n { sharedWaiting = n } }

    // MARK: The 10-minute limit

    /// A recording started or ended. The limit applies only to one that starts without the trial or Verbose Unlock, so a
    /// recording running when the trial ends keeps going until it's stopped.
    private func capSession(_ active: Bool) {
        capActive = active
        capStopping = false
        if active { capStartedWithEverything = state.hasEverything } else if capPhase != .none { capPhase = .none }
    }

    /// Each tick of the recorder's clock: where the recording is against the limit, and at 10:00 a free recording stops
    /// and saves like any other (`RecordingCap`).
    private func capTick(_ elapsed: TimeInterval) {
        guard let app, capActive else { return }
        let phase = RecordingCap.phase(elapsed: elapsed, startedWithEverything: capStartedWithEverything, hasEverythingNow: state.hasEverything)
        if phase != capPhase { capPhase = phase }
        // Only a real recording stops; the self-test's stand-in shows the chip.
        guard phase == .stop, app.recorder.isRecording, !app.savingRecording, !capStopping else { return }
        capStopping = true
        let choice = app.recordingChoice
        let audioOnly = app.continuing == nil && choice == .kind(.audio)
        let noun = app.continuing != nil || audioOnly ? "recording" : choice.name.lowercased()
        cards = UnlockCards.capped(cards, noun: noun, transcribes: !audioOnly)
        cards.save()
        Log.note("unlock: a free recording reached 10 minutes; it saves and transcribes")
        app.stopRecording()
        app.say(UnlockCopy.cappedToast)
    }

    // MARK: Self-test

    /// The self-test's stand-in transactions (`StubPurchases`), and Home's cards' memory. No-op with the real store.
    func useForSelfTest(_ records: [PurchaseRecord], cards memory: UnlockCardMemory? = nil, sharedWaiting n: Int? = nil) {
        guard let stub = backend as? StubPurchases else { return }
        stub.stored = records
        self.records = records
        if let memory { cards = memory }
        if let n { sharedWaiting = n }
        recompute()
    }

    /// The topmost presenting screen, for the self-test's checks.
    var hostCount: Int { hosts.count }
}

// MARK: - The gate on PhoneState

extension PhoneState {
    /// True when the trial or Verbose Unlock covers `feature`. Otherwise opens the unlock sheet on the topmost screen
    /// (Settings, the recorder, or the root) and returns false. Locked features stay visible; tapping one asks.
    @discardableResult
    func allow(_ feature: LockedFeature) -> Bool { UnlockStore.shared.allow(feature) }

    /// Record as's Import: where from (Photos, files, or a link), once Import is allowed.
    func requestImport() {
        guard allow(.importMedia) else { return }
        showImportChoices = true
    }

    /// Home's What's playing and the Action button's: the sheet with the system broadcast picker, once App audio is
    /// allowed. `startPicker` asks iOS for the picker as soon as the sheet shows.
    func requestWhatsPlaying(startPicker: Bool = false) {
        guard allow(.appAudio) else { return }
        playingSheetStartsPicker = startPicker
        showPlayingSheet = true
    }
}
