import Foundation
import Security
import Combine
import AppKit

/// Verbose for Mac's license at runtime (MacLicense.swift has the rules): the key and the trial's start in the
/// Keychain on this Mac, activation and 30-day check-ins with Polar's customer portal API (no secret involved), and
/// the entitlement handed to `FeatureGate`, which the public build enforces and beta builds don't.
@MainActor
final class MacLicenseStore: ObservableObject {
    static let shared = MacLicenseStore()

    @Published private(set) var state: EntitlementState = .free
    @Published private(set) var license: MacLicenseRecord? = nil
    @Published private(set) var trialStartedAt: Date? = nil
    /// Why the last activation didn't finish, shown under the key field.
    @Published var problem: MacLicenseProblem? = nil
    @Published private(set) var busy = false
    /// A note after a successful action ("This Mac is deactivated…").
    @Published var note: String? = nil
    /// The last request was refused by Local Only, so the pane says so instead of "Couldn't reach Polar".
    @Published private(set) var localOnlyRefused = false

    private let session: URLSession
    private var timer: Timer?

    init(session: URLSession = .shared) {
        self.session = session
        license = LicenseKeychain.readRecord()
        trialStartedAt = LicenseKeychain.readTrialStart()
        recompute()
    }

    /// At launch: enforce (public build only), then check in if it's due, and again every 6 hours while running.
    func start() {
        recompute()
        Task { await validateIfDue() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.validateIfDue() }
        }
    }

    var enforces: Bool { MacEntitlement.enforces(channel: AppVersion.channel) }

    private func recompute(now: Date = Date()) {
        state = MacEntitlement.state(trialStartedAt: trialStartedAt, license: license, now: now, checksPaused: LocalOnly.isOn)
        if enforces { FeatureGate.enforce(state) }
    }

    // MARK: Actions

    func startTrial() {
        guard trialStartedAt == nil else { return }
        let now = Date()
        trialStartedAt = now
        LicenseKeychain.saveTrialStart(now)
        Log.note("license: trial started")
        recompute()
    }

    func activate(_ input: String) async {
        guard MacLicense.isConfigured else { problem = .notConfigured; return }
        let key = MacLicense.normalized(input)
        guard !key.isEmpty else { problem = .invalid; return }
        busy = true; problem = nil; note = nil
        defer { busy = false }
        let label = MacLicense.label(computerName: Host.current().localizedName ?? "")
        let (status, body) = await post("activate", PolarRequest.activate(key: key, label: label))
        switch MacLicenseParse.activation(status: status, body: body, key: key, now: Date()) {
        case .activated(let r):
            license = r
            LicenseKeychain.saveRecord(r)
            Log.note("license: activated this Mac")
            recompute()
        case .problem(let p):
            problem = p
            Log.note("license: activation failed (\(p))")
        }
    }

    func deactivate() async {
        guard let l = license else { return }
        busy = true; problem = nil
        defer { busy = false }
        let (status, _) = await post("deactivate", PolarRequest.deactivate(key: l.key, activationID: l.activationID))
        // 404: Polar already removed it (in the portal); either way this Mac lets go of it.
        guard status == 204 || status == 200 || status == 404 else { problem = status == nil ? .offline : .other(status ?? 0); return }
        license = nil
        LicenseKeychain.deleteRecord()
        note = MacLicenseCopy.deactivated
        Log.note("license: deactivated this Mac")
        recompute()
    }

    func validateIfDue(now: Date = Date()) async {
        guard MacLicense.isConfigured, let l = license, MacEntitlement.needsValidation(l, now: now) else { recompute(now: now); return }
        let (status, body) = await post("validate", PolarRequest.validate(key: l.key, activationID: l.activationID))
        let updated = MacLicenseParse.validation(status: status, body: body, record: l, now: now)
        license = updated
        if let updated { LicenseKeychain.saveRecord(updated) } else { LicenseKeychain.deleteRecord(); Log.note("license: Polar ended this license") }
        recompute(now: now)
    }

    func openCheckout() {
        if let u = URL(string: MacLicense.checkoutURL), !MacLicense.checkoutURL.isEmpty { NSWorkspace.shared.open(u) }
    }

    func openPortal() {
        if let u = URL(string: MacLicense.portalURL) { NSWorkspace.shared.open(u) }
    }

    // MARK: Network

    /// POSTs JSON to Polar; the status (nil when no answer came) and the body.
    private func post(_ path: String, _ body: [String: Any]) async -> (Int?, Data?) {
        guard let url = URL(string: "\(MacLicense.apiBase)/\(path)"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return (nil, nil) }
        // Settings › Privacy: Local Only refuses it (and the Network activity list shows the try).
        do { try NetworkGate.begin(.licenseCheck, host: NetworkHost.of(url)) } catch { localOnlyRefused = true; return (nil, nil) }
        localOnlyRefused = false
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        do {
            let (d, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode, d)
        } catch {
            return (nil, nil)
        }
    }
}

/// The license record and the trial's start, in this Mac's Keychain (not synced).
enum LicenseKeychain {
    private static let service = "co.stumpandroot.verbatim.license"

    static func readRecord() -> MacLicenseRecord? {
        read("license").flatMap { try? JSONDecoder().decode(MacLicenseRecord.self, from: $0) }
    }
    static func saveRecord(_ r: MacLicenseRecord) { if let d = try? JSONEncoder().encode(r) { save(d, account: "license") } }
    static func deleteRecord() { delete("license") }

    static func readTrialStart() -> Date? {
        read("trial").flatMap { String(data: $0, encoding: .utf8) }.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }
    static func saveTrialStart(_ d: Date) { save(Data(String(d.timeIntervalSince1970).utf8), account: "trial") }

    private static func read(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func save(_ data: Data, account: String) {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
