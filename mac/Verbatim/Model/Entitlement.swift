import Foundation

// Verbose Unlock on iPhone (approved mockup "Verbose Unlock on iPhone", October 31, 2026; DESIGN.md §21;
// mac/APP_STORE.md, In-app purchase): free to download, a 7-day free trial you start with a tap, and one in-app
// purchase that unlocks everything for good. This file is the pure part, with no StoreKit and no SwiftUI, so
// mac/tools/test-entitlement.sh compiles it on Linux: the two products, the entitlement a device's transactions add
// up to, which feature each state allows, the 10-minute recording limit, Home's cards, the Settings row, and every
// line of copy the unlock shows. The iPhone app reads the transactions from StoreKit 2 (VerbatimPhone/Unlock.swift);
// the self-test and the Linux checks use `StubPurchases`.
//
// It compiles into the Mac app too (the Mac target takes all of Verbatim/), where nothing enforces it: `FeatureGate`
// allows everything until the iPhone calls `enforce`. A Mac license never unlocks the iPhone, and iCloud sync carries
// no entitlement: it comes only from StoreKit on the iPhone itself.

// MARK: - Products

/// The two non-consumable in-app purchases in App Store Connect (mac/APP_STORE.md). Family Sharing is off for both.
enum UnlockProduct {
    /// "7-day free trial": a $0 non-consumable, named the way guideline 3.1.1 asks for a non-subscription trial.
    /// Buying it starts the trial; its purchase date is when the trial began.
    static let trial = "co.stumpandroot.verbatim.ios.trial7"
    /// "Verbose Unlock": $14.99 in the US, once.
    static let unlock = "co.stumpandroot.verbatim.ios.unlock"
    static let all: [String] = [trial, unlock]
}

/// One verified StoreKit transaction for an unlock product: what was bought, when, and when Apple took it back (a
/// refund or a revoked purchase), if it did. The iPhone also caches these (`UnlockCache`) so an offline launch knows
/// the last state before StoreKit answers.
struct PurchaseRecord: Codable, Equatable {
    var productID: String
    var purchaseDate: Date
    var revokedAt: Date? = nil
    var transactionID: String = ""

    var revoked: Bool { revokedAt != nil }
}

// MARK: - Entitlement

/// What this iPhone has: the free version before the trial, the trial with its end and days left, the free version
/// after the trial, or Verbose Unlock.
enum EntitlementState: Equatable {
    /// The free version; the trial was never started, so the unlock sheet offers it.
    case free
    /// The free trial, until `ends`. `daysLeft` counts started days (1 on the last day).
    case trial(ends: Date, daysLeft: Int)
    /// The free version after the trial ended. The trial can't start again.
    case trialEnded(ended: Date)
    /// Verbose Unlock was bought (and not refunded).
    case unlocked

    /// Everything Verbose Unlock adds is allowed: the trial or the purchase.
    var hasEverything: Bool {
        switch self {
        case .trial, .unlocked: return true
        case .free, .trialEnded: return false
        }
    }

    /// The unlock sheet, the Settings row, and the welcome tour offer the trial only before it was ever started.
    var offersTrial: Bool { self == .free }

    var isTrial: Bool { if case .trial = self { return true } else { return false } }

    /// A short name for logs and the self-test ("free", "trial 5d", "trial ended", "unlocked").
    var logName: String {
        switch self {
        case .free: return "free"
        case .trial(_, let d): return "trial \(d)d"
        case .trialEnded: return "trial ended"
        case .unlocked: return "unlocked"
        }
    }
}

enum Entitlement {
    static let trialDays = 7
    static let trialLength: TimeInterval = TimeInterval(trialDays) * 86_400

    /// When the trial ends, or nil when it was never started. The trial starts at the earliest trial purchase of any
    /// kind, so reinstalling, restoring, or a refund and a second purchase never restarts it. When every trial
    /// transaction was revoked, it ends at the first revocation if that came sooner.
    static func trialEnd(_ records: [PurchaseRecord]) -> Date? {
        let trials = records.filter { $0.productID == UnlockProduct.trial }
        guard let start = trials.map(\.purchaseDate).min() else { return nil }
        var end = start.addingTimeInterval(trialLength)
        if trials.allSatisfy(\.revoked), let firstRevoked = trials.compactMap(\.revokedAt).min() { end = min(end, firstRevoked) }
        return end
    }

    /// The entitlement the transactions add up to at `now`. A refunded or revoked Verbose Unlock counts for nothing,
    /// so the state falls back to the trial's.
    static func state(_ records: [PurchaseRecord], now: Date) -> EntitlementState {
        if records.contains(where: { $0.productID == UnlockProduct.unlock && !$0.revoked }) { return .unlocked }
        guard let end = trialEnd(records) else { return .free }
        guard now < end else { return .trialEnded(ended: end) }
        return .trial(ends: end, daysLeft: daysLeft(until: end, now: now))
    }

    /// Started days left: 7 right after the trial starts, 1 on its last day. Never 0 while the trial runs.
    static func daysLeft(until end: Date, now: Date) -> Int {
        let left = end.timeIntervalSince(now)
        guard left > 0 else { return 0 }
        return max(1, Int((left / 86_400).rounded(.up)))
    }

    /// Whether a state allows a feature. Every locked feature needs the trial or Verbose Unlock; the free features
    /// (`FreeFeature`) never ask.
    static func allows(_ feature: LockedFeature, in state: EntitlementState) -> Bool { state.hasEverything }
}

/// What Verbose Unlock (or the trial) adds on iPhone. Each stays visible while locked; tapping one opens the unlock
/// sheet. Nothing the person already made locks: existing transcripts, results, and synced items stay readable and
/// shareable as text.
enum LockedFeature: String, CaseIterable {
    /// Recordings past 10 minutes (`RecordingCap`).
    case longRecordings
    /// Import: files, Photos, links, and what the share extension leaves in the inbox.
    case importMedia
    /// App audio: Transcribe what's playing.
    case appAudio
    case liveCaptions
    /// Templates other than Plan my day (`FeatureGate.freeTemplates`), by hand or automatically, and Try on.
    case templates
    case ask
    case recipes
    case cloudCleanup
    /// Every export format beyond plain text (Markdown, Word, SRT, VTT, JSON) and Share original audio.
    case exportFormats
}

/// What stays free, as the Mac's free tier does. Listed for the docs and the checks; nothing gates these.
enum FreeFeature: String, CaseIterable {
    case dictate, keyboard, keyboardSessions, recordingsUpToTenMinutes, watchRecordings, transcripts, speakers, search,
         thoughts, journal, planMyDay, sendToReminders, iCloudSync, copyAndShareText, exportEverythingZip
}

// MARK: - The gate shared code reads

/// The entitlement as code shared with the Mac sees it: Templates, Ask, Recipes, and Cloud cleanup check here before
/// they run. Nothing is enforced until the iPhone calls `enforce` (at launch, from its cached state, then from
/// StoreKit), so the Mac app, which never calls it, allows everything. Readable from any thread.
enum FeatureGate {
    private static let lock = NSLock()
    private static var current: EntitlementState? = nil

    /// Templates that stay free: Plan my day (and Make a plan, which it replaced). The iPhone sets this at launch.
    static var freeTemplates: Set<UUID> = []
    /// Called when a refusal should open the unlock sheet (a run you asked for, not an automatic one). The iPhone
    /// sets it; it may be called from any thread.
    static var onDenied: ((LockedFeature) -> Void)? = nil

    /// Starts enforcing `state`, or updates it.
    static func enforce(_ state: EntitlementState) {
        lock.lock(); current = state; lock.unlock()
    }

    /// Stops enforcing (the self-test puts it back this way only; the app never does).
    static func stopEnforcing() {
        lock.lock(); current = nil; lock.unlock()
    }

    static var isEnforced: Bool { lock.lock(); defer { lock.unlock() }; return current != nil }

    /// True when nothing is enforced, or the state allows everything.
    static var hasEverything: Bool {
        lock.lock(); defer { lock.unlock() }
        return current?.hasEverything ?? true
    }

    /// Whether `feature` is allowed now. With `ask`, a refusal calls `onDenied`, which opens the unlock sheet.
    static func allows(_ feature: LockedFeature, ask: Bool = false) -> Bool {
        if hasEverything { return true }
        if ask { onDenied?(feature) }
        return false
    }

    /// Whether a template may run now: Plan my day always; any other with the trial or Verbose Unlock.
    static func allowsTemplate(_ id: UUID, ask: Bool = false) -> Bool {
        if freeTemplates.contains(id) { return true }
        return allows(.templates, ask: ask)
    }
}

// MARK: - The 10-minute limit

/// A free recording saves at 10 minutes instead of stopping cold (mockup, "The limit, while recording"): at 9:00 the
/// recorder shows a chip ("Saves at 10:00 · Unlock to keep going"), and at 10:00 the recording stops, saves like any
/// other, and transcribes. Unlocking mid-recording removes the limit. A recording that started with the trial or the
/// purchase never has one, so a recording running when the trial ends keeps going until you stop it. The limit counts
/// the recording's own length (paused time doesn't count); a Continue recording counts only the new part.
enum RecordingCap {
    static let limit: TimeInterval = 600
    static let warnAt: TimeInterval = 540

    enum Phase: Equatable { case none, warning, stop }

    /// Where a recording is: `startedWithEverything` is the entitlement when it started, `hasEverythingNow` the
    /// entitlement now.
    static func phase(elapsed: TimeInterval, startedWithEverything: Bool, hasEverythingNow: Bool) -> Phase {
        guard !startedWithEverything, !hasEverythingNow else { return .none }
        if elapsed >= limit { return .stop }
        if elapsed >= warnAt { return .warning }
        return .none
    }
}

// MARK: - Home's cards

/// One card at the top of Home, where What's new shows (mockup). One at a time, in this order of importance.
enum UnlockCard: Equatable {
    /// A free recording stopped at 10 minutes. `noun` is what it was ("meeting"), `transcribes` false for Audio only.
    case savedFirstTen(noun: String, transcribes: Bool)
    /// Files and links shared to Verbose wait in the inbox while Import is locked.
    case sharedWaiting(count: Int)
    /// The trial ended: shown once, until OK or Unlock.
    case trialEnded
    /// The trial ends tomorrow (or, in its last hours, today), until Not now.
    case trialEndsSoon(today: Bool)
}

/// What Home's cards remember on this iPhone (UserDefaults; a convenience only, never the entitlement).
struct UnlockCardMemory: Codable, Equatable {
    var trialEndingDismissed = false
    var trialEndedDismissed = false
    /// A recording stopped at 10 minutes and its card hasn't been closed: what it was, and whether it transcribes.
    var savedTenNoun: String? = nil
    var savedTenTranscribes = true
    /// How many shared items were waiting when Not now was tapped; the card comes back when more arrive.
    var sharedDismissedCount = 0

    static let key = "unlock.cards"

    static func load(_ d: UserDefaults = .standard) -> UnlockCardMemory {
        guard let data = d.data(forKey: key), let m = try? JSONDecoder().decode(UnlockCardMemory.self, from: data) else { return UnlockCardMemory() }
        return m
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

enum UnlockCards {
    /// The card Home shows now, or nil. Nothing shows once everything is unlocked, except while the trial runs (its
    /// ending card).
    static func card(state: EntitlementState, now: Date, memory: UnlockCardMemory, sharedWaiting: Int,
                     calendar: Calendar = .current) -> UnlockCard? {
        if !state.hasEverything, let noun = memory.savedTenNoun {
            return .savedFirstTen(noun: noun, transcribes: memory.savedTenTranscribes)
        }
        if !state.hasEverything, sharedWaiting > 0, sharedWaiting != memory.sharedDismissedCount {
            return .sharedWaiting(count: sharedWaiting)
        }
        switch state {
        case .trialEnded:
            return memory.trialEndedDismissed ? nil : .trialEnded
        case .trial(let ends, _):
            guard !memory.trialEndingDismissed else { return nil }
            if calendar.isDate(ends, inSameDayAs: now) { return .trialEndsSoon(today: true) }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(ends, inSameDayAs: tomorrow) {
                return .trialEndsSoon(today: false)
            }
            return nil
        case .free, .unlocked:
            return nil
        }
    }

    /// The memory after the card's buttons (Unlock, Not now, or OK) close it.
    static func dismissed(_ card: UnlockCard, _ memory: UnlockCardMemory) -> UnlockCardMemory {
        var m = memory
        switch card {
        case .savedFirstTen: m.savedTenNoun = nil
        case .sharedWaiting(let n): m.sharedDismissedCount = n
        case .trialEnded: m.trialEndedDismissed = true
        case .trialEndsSoon: m.trialEndingDismissed = true
        }
        return m
    }

    /// The memory after a recording stopped at 10 minutes.
    static func capped(_ memory: UnlockCardMemory, noun: String, transcribes: Bool) -> UnlockCardMemory {
        var m = memory
        m.savedTenNoun = noun
        m.savedTenTranscribes = transcribes
        return m
    }
}

// MARK: - The Settings row

/// The row under Settings' search field, above the groups: what you have, in words.
struct UnlockRowContent: Equatable {
    var title: String
    var subtitle: String
    /// The price at the trailing edge (nil once unlocked, or before the App Store answers).
    var value: String?
    /// Unlocked: the quiet thank-you row, which opens nothing.
    var thanks: Bool

    /// `beta`: a TestFlight build with everything unlocked (BETA_UNLOCK), which says so instead of thanking you.
    static func make(_ state: EntitlementState, price: String?, beta: Bool = false) -> UnlockRowContent {
        if beta { return UnlockRowContent(title: UnlockCopy.productName, subtitle: UnlockCopy.betaThanks, value: nil, thanks: true) }
        switch state {
        case .free:
            return UnlockRowContent(title: UnlockCopy.tryFree, subtitle: UnlockCopy.rowPitch, value: price, thanks: false)
        case .trial(_, let days):
            return UnlockRowContent(title: UnlockCopy.trialRowTitle(daysLeft: days), subtitle: UnlockCopy.trialRowSubtitle, value: price, thanks: false)
        case .trialEnded:
            return UnlockRowContent(title: UnlockCopy.productName, subtitle: UnlockCopy.rowPitch, value: price, thanks: false)
        case .unlocked:
            return UnlockRowContent(title: UnlockCopy.productName, subtitle: UnlockCopy.thanks, value: nil, thanks: true)
        }
    }
}

// MARK: - Copy

/// Every line the unlock shows, from the approved mockup, in one place so the checks can read them: sentence case,
/// no em dashes or exclamation points, and nothing about buying anywhere but the App Store, the website, or the Mac
/// app's license (guideline 3.1.1, 3.1.3).
enum UnlockCopy {
    static let productName = "Verbose Unlock"

    // The sheet
    static let sheetTitle = "Get all of Verbose."
    static let sheetLede = "One purchase, yours on every iPhone signed in to your Apple Account. No subscription, and nothing renews."
    static let items: [(title: String, detail: String)] = [
        ("Record as long as you need", "Meetings, lectures, and interviews"),
        ("Import files and links", "Voice Memos, videos, and podcasts"),
        ("App audio and live captions", "Transcribe what's playing"),
        ("Templates and Ask", "Meeting notes, recipes, and answers"),
        ("Every export format", "Markdown, Word, captions, and audio"),
    ]
    static let tryFree = "Try it free for 7 days"
    static func unlockButton(price: String?) -> String { price.map { "Unlock for \($0)" } ?? "Unlock Verbose" }
    /// Before the trial starts: its length, that it charges nothing and doesn't renew, and what happens after
    /// (guideline 3.1.1). The list above it says what locks again.
    static let trialFinePrint = "The trial is free and doesn't renew, so nothing is charged. After 7 days, the features above lock again and Verbose goes back to the free version unless you unlock it."
    static let onceFinePrint = "One-time purchase. No subscription."
    static func inTrialFinePrint(daysLeft: Int) -> String {
        "Your free trial has \(daysCount(daysLeft)) left. Unlocking keeps everything, with no subscription."
    }
    static let restore = "Restore Purchases"
    static let terms = "Terms"
    static let privacy = "Privacy"

    // Results
    static let unlockedToast = "Verbose is unlocked. Thank you."
    static let trialStartedToast = "Your free trial is on. Everything is unlocked for 7 days."
    static let pending = "Waiting for approval. Verbose unlocks once it's approved."
    static let failed = "Couldn't complete the purchase. Try again."
    static let offline = "Couldn't reach the App Store. Try again when you're online."
    static let restoredUnlock = "Restored Verbose Unlock."
    static let restoredTrial = "Restored your free trial."
    static let nothingToRestore = "No purchases to restore for this Apple Account."

    // The recorder
    static let recorderChip = "Saves at 10:00 \u{00B7} Unlock to keep going"
    static let cappedToast = "Saved the first 10 minutes"

    // Home's cards
    static func cardTitle(_ c: UnlockCard) -> String {
        switch c {
        case .savedFirstTen: return "Saved the first 10 minutes"
        case .sharedWaiting(let n): return n == 1 ? "1 shared item is waiting" : "\(n) shared items are waiting"
        case .trialEnded: return "Your free trial ended"
        case .trialEndsSoon(let today): return today ? "Your free trial ends today" : "Your free trial ends tomorrow"
        }
    }

    static func cardBody(_ c: UnlockCard) -> String {
        switch c {
        case .savedFirstTen(let noun, let transcribes):
            let what = transcribes ? "Your \(noun) is transcribing." : "Your \(noun) is saved."
            return what + " Free recordings stop at 10 minutes. Unlock Verbose to record as long as you need."
        case .sharedWaiting(let n):
            return "Unlock Verbose to import the files and links you share. " + (n == 1 ? "It waits here" : "They wait here") + " until you do."
        case .trialEnded:
            return "Everything you made stays: recordings, transcripts, imports, and template results. Dictate and recordings up to 10 minutes stay free."
        case .trialEndsSoon:
            return "After that, recordings save at 10 minutes, and imports, app audio, most templates, and exports need Verbose Unlock."
        }
    }

    /// The card's main action: Unlock, with the price on the trial's cards.
    static func cardAction(_ c: UnlockCard, price: String?) -> String {
        switch c {
        case .trialEnded, .trialEndsSoon: return unlockButton(price: price)
        case .savedFirstTen, .sharedWaiting: return "Unlock"
        }
    }

    /// The card's quiet action: OK after the trial ended, Not now otherwise.
    static func cardDismiss(_ c: UnlockCard) -> String { c == .trialEnded ? "OK" : "Not now" }

    // Settings
    static let rowPitch = "Recordings of any length, imports, templates, and every export"
    static func trialRowTitle(daysLeft: Int) -> String { "Free trial \u{00B7} " + (daysLeft <= 1 ? "ends today" : "\(daysCount(daysLeft)) left") }
    static let trialRowSubtitle = "Unlock to keep everything."
    static let thanks = "Thank you. Everything is unlocked."
    /// TestFlight builds (BETA_UNLOCK): the Settings row while everything is unlocked for testing.
    static let betaThanks = "Everything is unlocked while you test the beta."

    // The welcome tour's last step
    static let tourTitle = "Try everything free for 7 days"
    static let tourBody = "Recordings of any length, imports, templates, and every export. It's free, nothing renews, and after 7 days Verbose goes back to the free version."
    static let tourStart = "Start free trial"
    static let notNow = "Not now"

    // Locked features
    static let cloudCleanupLocked = "Cloud cleanup is part of Verbose Unlock."
    static let exportLocked = "Markdown, Word, SRT, VTT, and JSON are part of Verbose Unlock. Plain text is free."

    static func daysCount(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    /// Every fixed line, for the checks.
    static var allLines: [String] {
        var lines = [productName, sheetTitle, sheetLede, tryFree, unlockButton(price: "$14.99"), unlockButton(price: nil), trialFinePrint,
                     onceFinePrint, inTrialFinePrint(daysLeft: 5), restore, terms, privacy, unlockedToast, trialStartedToast, pending, failed,
                     offline, restoredUnlock, restoredTrial, nothingToRestore, recorderChip, cappedToast, rowPitch, trialRowTitle(daysLeft: 5),
                     trialRowSubtitle, thanks, tourTitle, tourBody, tourStart, notNow, cloudCleanupLocked, exportLocked]
        lines += items.flatMap { [$0.title, $0.detail] }
        let cards: [UnlockCard] = [.savedFirstTen(noun: "meeting", transcribes: true), .savedFirstTen(noun: "recording", transcribes: false),
                                   .sharedWaiting(count: 1), .sharedWaiting(count: 3), .trialEnded, .trialEndsSoon(today: false), .trialEndsSoon(today: true)]
        for c in cards { lines += [cardTitle(c), cardBody(c), cardAction(c, price: "$14.99"), cardDismiss(c)] }
        return lines
    }
}

// MARK: - Purchases

/// How a purchase ended.
enum PurchaseOutcome: Equatable {
    case purchased
    case cancelled
    /// Ask to Buy, or another approval: it lands later through StoreKit's updates.
    case pending
    case failed(String)
}

/// StoreKit 2 behind a protocol, so the rules above are testable without it: the real one is `StoreKitPurchases`
/// (VerbatimPhone/Unlock.swift); the self-test and the Linux checks use `StubPurchases`.
protocol PurchaseBackend: AnyObject {
    /// Every verified transaction for the unlock products on this Apple Account, refunded ones included.
    func records() async -> [PurchaseRecord]
    /// Each product's price as the App Store shows it in the person's currency, by product ID. Empty offline.
    func prices() async -> [String: String]
    func purchase(_ productID: String) async -> PurchaseOutcome
    /// Restore Purchases: asks the App Store for the account's transactions again. False when it couldn't.
    func restore() async -> Bool
    /// Calls `changed` when a transaction arrives from outside the app (a refund, Ask to Buy, another device).
    func listen(_ changed: @escaping () -> Void)
}

/// A stand-in store with made-up transactions, for the self-test and the Linux checks. Purchases succeed at once
/// (or as `nextOutcome` says), dated `now`.
final class StubPurchases: PurchaseBackend {
    var stored: [PurchaseRecord]
    var priceList: [String: String]
    var nextOutcome: PurchaseOutcome = .purchased
    var now: () -> Date
    private var changed: (() -> Void)? = nil

    init(_ records: [PurchaseRecord] = [], prices: [String: String] = [UnlockProduct.unlock: "$14.99", UnlockProduct.trial: "Free"],
         now: @escaping () -> Date = Date.init) {
        stored = records; priceList = prices; self.now = now
    }

    /// Unlocked, as the self-test starts, so the tours that came before the unlock keep working.
    static func unlocked(now: Date = Date()) -> StubPurchases {
        StubPurchases([PurchaseRecord(productID: UnlockProduct.unlock, purchaseDate: now.addingTimeInterval(-86_400), transactionID: "stub-unlock")])
    }

    func records() async -> [PurchaseRecord] { stored }
    func prices() async -> [String: String] { priceList }
    func purchase(_ productID: String) async -> PurchaseOutcome {
        let outcome = nextOutcome
        nextOutcome = .purchased
        if outcome == .purchased {
            stored.append(PurchaseRecord(productID: productID, purchaseDate: now(), transactionID: "stub-\(stored.count + 1)"))
        }
        return outcome
    }
    func restore() async -> Bool { true }
    func listen(_ changed: @escaping () -> Void) { self.changed = changed }

    /// A transaction from outside the app (a refund in the self-test): replaces the records and says so.
    func replace(_ records: [PurchaseRecord]) {
        stored = records
        changed?()
    }
}

/// The last records StoreKit gave, so a launch with no network shows the right state at once. StoreKit is asked again
/// every launch and replaces it.
enum UnlockCache {
    static let key = "unlock.cache.records"

    static func load(_ d: UserDefaults = .standard) -> [PurchaseRecord] {
        guard let data = d.data(forKey: key), let r = try? JSONDecoder().decode([PurchaseRecord].self, from: data) else { return [] }
        return r
    }

    static func save(_ records: [PurchaseRecord], _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(records) { d.set(data, forKey: key) }
    }
}
