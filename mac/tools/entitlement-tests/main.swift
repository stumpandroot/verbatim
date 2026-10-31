import Foundation

// Verbose Unlock on iPhone (Verbatim/Model/Entitlement.swift): the entitlement from transactions, the gate, the
// 10-minute limit, Home's cards, the Settings row, the copy, the stand-in store, and the iPhone sources' wiring.
// Not part of any app target; run mac/tools/test-entitlement.sh.
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") }
    else { failed += 1; print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : "\n    " + d }()) }
}

let day: TimeInterval = 86_400
let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // the trial's start in these cases
func trial(_ at: Date, revoked: Date? = nil) -> PurchaseRecord { PurchaseRecord(productID: UnlockProduct.trial, purchaseDate: at, revokedAt: revoked, transactionID: "t") }
func unlock(_ at: Date, revoked: Date? = nil) -> PurchaseRecord { PurchaseRecord(productID: UnlockProduct.unlock, purchaseDate: at, revokedAt: revoked, transactionID: "u") }

// MARK: Products

check("the products' IDs", UnlockProduct.trial == "co.stumpandroot.verbatim.ios.trial7" && UnlockProduct.unlock == "co.stumpandroot.verbatim.ios.unlock"
      && UnlockProduct.all == [UnlockProduct.trial, UnlockProduct.unlock])

// MARK: Entitlement

check("no transactions: the free version, and the trial is offered", Entitlement.state([], now: t0) == .free && EntitlementState.free.offersTrial
      && !EntitlementState.free.hasEverything)
check("the trial lasts 7 days", Entitlement.trialDays == 7 && Entitlement.trialLength == 7 * day)
check("right after starting: the trial, 7 days left", Entitlement.state([trial(t0)], now: t0) == .trial(ends: t0.addingTimeInterval(7 * day), daysLeft: 7))
check("halfway through day 3: 5 days left", Entitlement.state([trial(t0)], now: t0.addingTimeInterval(2.5 * day)) == .trial(ends: t0.addingTimeInterval(7 * day), daysLeft: 5))
check("the last day says 1, never 0", Entitlement.state([trial(t0)], now: t0.addingTimeInterval(7 * day - 60)) == .trial(ends: t0.addingTimeInterval(7 * day), daysLeft: 1))
check("at 7 days exactly the trial has ended", Entitlement.state([trial(t0)], now: t0.addingTimeInterval(7 * day)) == .trialEnded(ended: t0.addingTimeInterval(7 * day)))
check("after the trial: the free version, the trial isn't offered again", {
    let s = Entitlement.state([trial(t0)], now: t0.addingTimeInterval(30 * day))
    return s == .trialEnded(ended: t0.addingTimeInterval(7 * day)) && !s.offersTrial && !s.hasEverything
}())
check("the trial runs from the earliest trial purchase (a reinstall or a second purchase never restarts it)",
      Entitlement.state([trial(t0.addingTimeInterval(5 * day)), trial(t0)], now: t0.addingTimeInterval(8 * day)) == .trialEnded(ended: t0.addingTimeInterval(7 * day)))
check("a revoked trial ends when it was revoked", Entitlement.state([trial(t0, revoked: t0.addingTimeInterval(day))], now: t0.addingTimeInterval(2 * day))
      == .trialEnded(ended: t0.addingTimeInterval(day)))
check("a refund and a second trial purchase still count from the first", Entitlement.state([trial(t0, revoked: t0.addingTimeInterval(day)), trial(t0.addingTimeInterval(3 * day))],
                                                                                            now: t0.addingTimeInterval(8 * day)) == .trialEnded(ended: t0.addingTimeInterval(7 * day)))
check("Verbose Unlock: unlocked, whatever the trial", Entitlement.state([unlock(t0)], now: t0) == .unlocked
      && Entitlement.state([trial(t0), unlock(t0.addingTimeInterval(day))], now: t0.addingTimeInterval(20 * day)) == .unlocked && EntitlementState.unlocked.hasEverything)
check("a refunded Verbose Unlock reverts to the trial's state", Entitlement.state([trial(t0), unlock(t0.addingTimeInterval(day), revoked: t0.addingTimeInterval(2 * day))],
                                                                                    now: t0.addingTimeInterval(3 * day)) == .trial(ends: t0.addingTimeInterval(7 * day), daysLeft: 4)
      && Entitlement.state([unlock(t0, revoked: t0.addingTimeInterval(day))], now: t0.addingTimeInterval(2 * day)) == .free)
check("other products don't count", Entitlement.state([PurchaseRecord(productID: "co.stumpandroot.other", purchaseDate: t0)], now: t0) == .free)
check("every locked feature follows the state", LockedFeature.allCases.allSatisfy { f in
    Entitlement.allows(f, in: .unlocked) && Entitlement.allows(f, in: .trial(ends: t0, daysLeft: 3)) && !Entitlement.allows(f, in: .free) && !Entitlement.allows(f, in: .trialEnded(ended: t0))
})
check("the locked features are the approved list", LockedFeature.allCases.map(\.rawValue) == ["longRecordings", "importMedia", "appAudio", "liveCaptions",
                                                                                              "templates", "ask", "recipes", "cloudCleanup", "exportFormats"])
check("Plan my day and Send to Reminders stay free", FreeFeature.allCases.contains(.planMyDay) && FreeFeature.allCases.contains(.sendToReminders))

// MARK: The gate

let plan = UUID(), meetingNotes = UUID()
FeatureGate.stopEnforcing()
check("before enforce (the Mac): everything is allowed", !FeatureGate.isEnforced && FeatureGate.hasEverything && FeatureGate.allows(.templates) && FeatureGate.allowsTemplate(meetingNotes))
var denied: [LockedFeature] = []
FeatureGate.onDenied = { denied.append($0) }
FeatureGate.freeTemplates = [plan]
FeatureGate.enforce(.trialEnded(ended: t0))
check("locked: a feature is refused", !FeatureGate.allows(.importMedia) && !FeatureGate.allows(.cloudCleanup) && denied.isEmpty)
check("locked: a refusal you asked for opens the sheet; an automatic one doesn't", !FeatureGate.allows(.ask, ask: true) && denied == [.ask])
check("locked: Plan my day still runs, other templates don't", FeatureGate.allowsTemplate(plan, ask: true) && !FeatureGate.allowsTemplate(meetingNotes, ask: true) && denied == [.ask, .templates])
FeatureGate.enforce(.trial(ends: t0, daysLeft: 2))
check("the trial allows everything", FeatureGate.hasEverything && FeatureGate.allowsTemplate(meetingNotes) && FeatureGate.allows(.exportFormats))
FeatureGate.enforce(.unlocked)
check("unlocked allows everything", FeatureGate.allows(.liveCaptions, ask: true) && denied.count == 2)
FeatureGate.stopEnforcing()
FeatureGate.onDenied = nil

// MARK: The 10-minute limit

check("the limit is 10 minutes, the chip at 9", RecordingCap.limit == 600 && RecordingCap.warnAt == 540)
check("free: nothing before 9:00", RecordingCap.phase(elapsed: 539, startedWithEverything: false, hasEverythingNow: false) == .none)
check("free: the chip from 9:00", RecordingCap.phase(elapsed: 540, startedWithEverything: false, hasEverythingNow: false) == .warning
      && RecordingCap.phase(elapsed: 599.9, startedWithEverything: false, hasEverythingNow: false) == .warning)
check("free: stops at 10:00", RecordingCap.phase(elapsed: 600, startedWithEverything: false, hasEverythingNow: false) == .stop
      && RecordingCap.phase(elapsed: 900, startedWithEverything: false, hasEverythingNow: false) == .stop)
check("unlocking mid-recording removes the limit", RecordingCap.phase(elapsed: 580, startedWithEverything: false, hasEverythingNow: true) == .none
      && RecordingCap.phase(elapsed: 700, startedWithEverything: false, hasEverythingNow: true) == .none)
check("a recording started in the trial keeps going after it ends", RecordingCap.phase(elapsed: 3600, startedWithEverything: true, hasEverythingNow: false) == .none)

// MARK: Home's cards

let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }()
let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
let endsTomorrow = EntitlementState.trial(ends: cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9))!, daysLeft: 1)
let endsToday = EntitlementState.trial(ends: cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 20))!, daysLeft: 1)
let endsLater = EntitlementState.trial(ends: cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9))!, daysLeft: 3)
var mem = UnlockCardMemory()
check("no card for the free version or Verbose Unlock", UnlockCards.card(state: .free, now: noon, memory: mem, sharedWaiting: 0, calendar: cal) == nil
      && UnlockCards.card(state: .unlocked, now: noon, memory: mem, sharedWaiting: 0, calendar: cal) == nil)
check("no card early in the trial", UnlockCards.card(state: endsLater, now: noon, memory: mem, sharedWaiting: 0, calendar: cal) == nil)
check("the day before it ends: ends tomorrow", UnlockCards.card(state: endsTomorrow, now: noon, memory: mem, sharedWaiting: 0, calendar: cal) == .trialEndsSoon(today: false))
check("its last hours: ends today", UnlockCards.card(state: endsToday, now: noon, memory: mem, sharedWaiting: 0, calendar: cal) == .trialEndsSoon(today: true))
mem = UnlockCards.dismissed(.trialEndsSoon(today: false), mem)
check("Not now hides the ending card for the rest of the trial", UnlockCards.card(state: endsTomorrow, now: noon, memory: mem, sharedWaiting: 0, calendar: cal) == nil
      && UnlockCards.card(state: endsToday, now: noon, memory: mem, sharedWaiting: 0, calendar: cal) == nil)
check("after the trial: the ended card", UnlockCards.card(state: .trialEnded(ended: noon), now: noon, memory: mem, sharedWaiting: 0, calendar: cal) == .trialEnded)
mem = UnlockCards.dismissed(.trialEnded, mem)
check("the ended card shows once", UnlockCards.card(state: .trialEnded(ended: noon), now: noon.addingTimeInterval(day), memory: mem, sharedWaiting: 0, calendar: cal) == nil)
mem = UnlockCards.capped(mem, noun: "meeting", transcribes: true)
check("a capped recording's card leads, while locked", UnlockCards.card(state: .trialEnded(ended: noon), now: noon, memory: mem, sharedWaiting: 2, calendar: cal) == .savedFirstTen(noun: "meeting", transcribes: true))
check("unlocking hides the capped card", UnlockCards.card(state: .unlocked, now: noon, memory: mem, sharedWaiting: 2, calendar: cal) == nil)
mem = UnlockCards.dismissed(.savedFirstTen(noun: "meeting", transcribes: true), mem)
check("then shared items waiting", UnlockCards.card(state: .free, now: noon, memory: mem, sharedWaiting: 2, calendar: cal) == .sharedWaiting(count: 2))
mem = UnlockCards.dismissed(.sharedWaiting(count: 2), mem)
check("Not now hides it until more arrive", UnlockCards.card(state: .free, now: noon, memory: mem, sharedWaiting: 2, calendar: cal) == nil
      && UnlockCards.card(state: .free, now: noon, memory: mem, sharedWaiting: 3, calendar: cal) == .sharedWaiting(count: 3))
let suite = "entitlement-tests-\(UUID().uuidString)"
if let d = UserDefaults(suiteName: suite) {
    mem.save(d)
    check("the cards' memory round-trips through UserDefaults", UnlockCardMemory.load(d) == mem && UnlockCardMemory.load(UserDefaults(suiteName: suite + "-empty")!) == UnlockCardMemory())
    UnlockCache.save([trial(t0), unlock(t0)], d)
    check("the cache round-trips the records", UnlockCache.load(d) == [trial(t0), unlock(t0)])
    d.removePersistentDomain(forName: suite)
}

// MARK: The Settings row

check("free: Try it free for 7 days, with the price", UnlockRowContent.make(.free, price: "$14.99") == UnlockRowContent(title: "Try it free for 7 days", subtitle: UnlockCopy.rowPitch, value: "$14.99", thanks: false))
check("the trial: days left", UnlockRowContent.make(.trial(ends: t0, daysLeft: 5), price: "$14.99").title == "Free trial \u{00B7} 5 days left"
      && UnlockRowContent.make(.trial(ends: t0, daysLeft: 2), price: nil).title == "Free trial \u{00B7} 2 days left"
      && UnlockRowContent.make(.trial(ends: t0, daysLeft: 1), price: nil).title == "Free trial \u{00B7} ends today")
check("after the trial: Verbose Unlock with the price", UnlockRowContent.make(.trialEnded(ended: t0), price: "€15,99").title == "Verbose Unlock"
      && UnlockRowContent.make(.trialEnded(ended: t0), price: "€15,99").value == "€15,99")
check("unlocked: the quiet thank-you row", UnlockRowContent.make(.unlocked, price: "$14.99") == UnlockRowContent(title: "Verbose Unlock", subtitle: "Thank you. Everything is unlocked.", value: nil, thanks: true))

// MARK: Copy

let lines = UnlockCopy.allLines
check("copy: no em dash or exclamation point", lines.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("!") }, "\(lines.filter { $0.contains("\u{2014}") || $0.contains("!") })")
let banned = ["website", "getverbose", "polar", "license", "mac", "testflight", "beta", "subscribe now", "web"]
check("copy: nothing about buying outside the App Store, the website, or the Mac", lines.allSatisfy { l in !banned.contains { l.lowercased().contains($0) } },
      "\(lines.filter { l in banned.contains { l.lowercased().contains($0) } })")
check("copy: the trial's fine print states its length, no charge or renewal, and what happens after",
      UnlockCopy.trialFinePrint.contains("7 days") && UnlockCopy.trialFinePrint.contains("free") && UnlockCopy.trialFinePrint.contains("doesn't renew")
      && UnlockCopy.trialFinePrint.contains("free version") && UnlockCopy.trialFinePrint.contains("nothing is charged") && UnlockCopy.trialFinePrint.contains("lock again"))
check("copy: the approved lines", UnlockCopy.sheetTitle == "Get all of Verbose." && UnlockCopy.tryFree == "Try it free for 7 days"
      && UnlockCopy.unlockButton(price: "$14.99") == "Unlock for $14.99" && UnlockCopy.recorderChip == "Saves at 10:00 \u{00B7} Unlock to keep going"
      && UnlockCopy.cardTitle(.trialEndsSoon(today: false)) == "Your free trial ends tomorrow" && UnlockCopy.cardTitle(.trialEnded) == "Your free trial ended"
      && UnlockCopy.cardTitle(.savedFirstTen(noun: "meeting", transcribes: true)) == "Saved the first 10 minutes"
      && UnlockCopy.cardBody(.savedFirstTen(noun: "meeting", transcribes: true)).hasPrefix("Your meeting is transcribing.")
      && UnlockCopy.cardDismiss(.trialEnded) == "OK" && UnlockCopy.cardDismiss(.trialEndsSoon(today: false)) == "Not now"
      && UnlockCopy.cardAction(.trialEndsSoon(today: false), price: "$14.99") == "Unlock for $14.99" && UnlockCopy.cardAction(.savedFirstTen(noun: "x", transcribes: true), price: "$14.99") == "Unlock")
check("copy: the sheet lists five things", UnlockCopy.items.count == 5)
check("copy: singular and plural", UnlockCopy.cardTitle(.sharedWaiting(count: 1)) == "1 shared item is waiting" && UnlockCopy.inTrialFinePrint(daysLeft: 1).contains("1 day left"))

// MARK: The stand-in store

final class Box { var n = 0 }
let box = Box()
let stub = StubPurchases([], now: { t0 })
stub.listen { box.n += 1 }
let sem = DispatchSemaphore(value: 0)
Task {
    let before = await stub.records()
    let bought = await stub.purchase(UnlockProduct.trial)
    let after = Entitlement.state(await stub.records(), now: t0.addingTimeInterval(day))
    stub.nextOutcome = .cancelled
    let cancelled = await stub.purchase(UnlockProduct.unlock)
    let still = Entitlement.state(await stub.records(), now: t0.addingTimeInterval(day))
    check("stub: starts empty, a trial purchase starts the trial", before.isEmpty && bought == .purchased && after == .trial(ends: t0.addingTimeInterval(7 * day), daysLeft: 6))
    check("stub: a cancelled purchase changes nothing", cancelled == .cancelled && still == after)
    stub.replace([])
    check("stub: an outside change calls back", box.n == 1)
    let unlocked = StubPurchases.unlocked(now: t0)
    let unlockedState = Entitlement.state(await unlocked.records(), now: t0)
    let unlockedPrice = (await unlocked.prices())[UnlockProduct.unlock]
    check("stub: the self-test starts unlocked", unlockedState == .unlocked && unlockedPrice == "$14.99")
    sem.signal()
}
sem.wait()

// MARK: The iPhone's wiring (sources)

let mac = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func read(_ path: String) -> String { (try? String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8)) ?? "" }
func phoneSources() -> [(String, String)] {
    let root = mac.appendingPathComponent("VerbatimPhone")
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var out: [(String, String)] = []
    for case let u as URL in e where u.pathExtension == "swift" { out.append((u.lastPathComponent, (try? String(contentsOf: u, encoding: .utf8)) ?? "")) }
    return out
}
let phone = phoneSources()
let all = phone.map(\.1).joined(separator: "\n")
let unlockFile = read("VerbatimPhone/Unlock.swift")
check("sources: StoreKit 2 reads the transactions, updates, and prices", unlockFile.contains("Transaction.all") && unlockFile.contains("Transaction.updates")
      && unlockFile.contains("Transaction.currentEntitlements") && unlockFile.contains("Product.products(for:") && unlockFile.contains("displayPrice")
      && unlockFile.contains("AppStore.sync()") && unlockFile.contains(".finish()"))
check("sources: the self-test starts unlocked with the stand-in store", unlockFile.contains("StubPurchases.unlocked"))
check("sources: StoreKit only in the purchase file", phone.filter { $0.1.contains("import StoreKit") }.map(\.0) == ["Unlock.swift"])
check("sources: Import, What's playing, and Live captions ask first", all.contains("allow(.importMedia)") && all.contains("allow(.appAudio)") && all.contains("allow(.liveCaptions)"))
check("sources: the share inbox holds items while Import is locked", read("VerbatimPhone/PhoneInbox.swift").contains("FeatureGate.allows(.importMedia)"))
check("sources: exports beyond plain text ask first", read("VerbatimPhone/PhoneExportSheet.swift").contains(".exportFormats"))
check("sources: Cloud cleanup returns nothing while locked on iPhone", read("Verbatim/Flow/CloudCleanup.swift").contains("FeatureGate.allows(.cloudCleanup)"))
check("sources: templates, Ask, and Recipes check the gate", read("Verbatim/Transcription/TemplateRunner.swift").contains("FeatureGate.allowsTemplate")
      && read("Verbatim/Transcription/AskEngine.swift").contains("FeatureGate.allows(.ask") && read("Verbatim/Transcription/AskEngine.swift").contains("FeatureGate.allows(.recipes"))
check("sources: the recorder shows the chip and the limit stops it", read("VerbatimPhone/RecorderSheet.swift").contains("RecordingLimitChip") && unlockFile.contains("RecordingCap.phase"))
check("sources: Settings has the row and Restore Purchases", read("VerbatimPhone/SettingsScreen.swift").contains("UnlockSettingsRow") && read("VerbatimPhone/SettingsScreen.swift").contains("restorePurchases"))
check("sources: the welcome tour offers the trial", read("VerbatimPhone/PhoneOnboarding.swift").contains("UnlockTourOffer"))
check("sources: Home shows the unlock cards", read("VerbatimPhone/HomeScreen.swift").contains("UnlockHomeCard"))
let unlockViews = read("VerbatimPhone/UnlockViews.swift")
check("sources: the sheet links Terms and Privacy", unlockViews.contains("Links.terms") && unlockViews.contains("Links.privacy"))
let outside = ["Links.base", "Links.refunds", "polar", "getverbose.app/pricing", "/buy"]
check("sources: the unlock links nowhere else", outside.allSatisfy { !(unlockFile + unlockViews).lowercased().contains($0.lowercased()) })
let storekit = read("VerbatimPhone/Verbose.storekit")
check("the StoreKit configuration file has both products, non-consumable, no Family Sharing", storekit.contains(UnlockProduct.trial) && storekit.contains(UnlockProduct.unlock)
      && storekit.contains("\"NonConsumable\"") && !storekit.contains("\"familyShareable\" : true") && storekit.contains("\"14.99\""))
check("project.yml points the iPhone scheme at the StoreKit file", read("project.yml").contains("storeKitConfiguration: VerbatimPhone/Verbose.storekit"))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
