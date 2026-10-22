import Foundation
import Security

/// Optional cloud cleanup with your own API key (off by default). When it's on and a key is saved, dictation
/// cleanup at Clean and Polished goes to Anthropic Claude or OpenAI with the same instructions as Apple's model
/// and passes the same guards. Any error, a timeout, or no network falls back to Apple's model, then to the rules.
///
/// - Only the cleaned words go out: the dictation text, the destination and tone lines, and your Dictionary terms.
///   Never the audio, and never the app context (window title, text around the cursor).
/// - The key lives in the Keychain on this device only (`CloudKeychain`), never in UserDefaults, logs, or the repo.
/// - URLSession only, no SDKs. Errors are logged by kind and status code, never with the text or the key.
enum CloudCleanup {
    enum Provider: String, CaseIterable, Identifiable {
        case anthropic, openai
        var id: String { rawValue }
        var title: String { self == .anthropic ? "Anthropic Claude" : "OpenAI" }
        /// Short name for the privacy line.
        var company: String { self == .anthropic ? "Anthropic" : "OpenAI" }
        /// The API's host, for Settings › Privacy › Network activity.
        var host: String { self == .anthropic ? "api.anthropic.com" : "api.openai.com" }
        /// Fast, low-cost defaults (Oct 2026): Claude Haiku 5.5 (platform.claude.com models overview) and
        /// GPT-5.4 mini (developers.openai.com/api/docs/models/gpt-5.4-mini).
        var defaultModel: String { self == .anthropic ? "claude-haiku-5-5" : "gpt-5.4-mini" }
        var keyPlaceholder: String { self == .anthropic ? "sk-ant-…" : "sk-…" }
        var keysURL: URL {
            URL(string: self == .anthropic ? "https://platform.claude.com/settings/keys" : "https://platform.openai.com/api-keys")!
        }
        fileprivate var keychainAccount: String { "cloud-cleanup." + rawValue }
    }

    struct Config: Sendable {
        var provider: Provider
        var model: String
        var key: String
    }

    // MARK: Settings (UserDefaults for the switch, provider, and model; the Keychain for keys)

    static let enabledKey = "cleanup.cloud.enabled"
    static let providerKey = "cleanup.cloud.provider"
    static func modelKey(_ p: Provider) -> String { "cleanup.cloud.model." + p.rawValue }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var provider: Provider {
        get { Provider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }
    static func model(for p: Provider) -> String {
        let m = (UserDefaults.standard.string(forKey: modelKey(p)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? p.defaultModel : m
    }
    static func setModel(_ m: String, for p: Provider) {
        let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == p.defaultModel { UserDefaults.standard.removeObject(forKey: modelKey(p)) }
        else { UserDefaults.standard.set(t, forKey: modelKey(p)) }
    }
    static func hasKey(_ p: Provider) -> Bool { !(CloudKeychain.read(p.keychainAccount) ?? "").isEmpty }
    @discardableResult static func saveKey(_ key: String, for p: Provider) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { CloudKeychain.delete(p.keychainAccount); return true }
        return CloudKeychain.save(k, account: p.keychainAccount)
    }
    static func deleteKey(for p: Provider) { CloudKeychain.delete(p.keychainAccount) }

    /// The setup to use now: on, with a saved key for the chosen provider. Nil otherwise.
    static var current: Config? {
        guard enabled else { return nil }
        let p = provider
        guard let key = CloudKeychain.read(p.keychainAccount), !key.isEmpty else { return nil }
        return Config(provider: p, model: model(for: p), key: key)
    }

    /// "Your words are sent to Anthropic for cleanup. Your audio stays on this device."
    static func privacyNote(_ p: Provider) -> String {
        "Your words are sent to \(p.company) for cleanup. Your audio stays on this device."
    }

    // MARK: Request

    enum Outcome: Sendable {
        case text(String)
        case failed(String)   // a kind and status code, never the text
    }

    /// The longest dictation sent in one request; longer text uses Apple's model in parts, or the rules.
    static let maxCharacters = 12_000

    /// Sends one cleanup. `seconds` bounds the whole request, the retry included.
    static func complete(system: String, prompt: String, config: Config, seconds: Double) async -> Outcome {
        guard seconds > 0.2 else { return .failed("no time left") }
        let started = Date()
        let first = await send(system: system, prompt: prompt, config: config, seconds: seconds, tuned: true)
        // An older or different model may refuse the speed settings (effort, thinking); try once without them, in
        // the time that's left rather than a fresh full limit.
        if case .failed(let why) = first, why == "HTTP 400" {
            let left = seconds - Date().timeIntervalSince(started)
            guard left > 0.3 else { return .failed("HTTP 400, no time left to retry") }
            return await send(system: system, prompt: prompt, config: config, seconds: left, tuned: false)
        }
        return first
    }

    private static func send(system: String, prompt: String, config: Config, seconds: Double, tuned: Bool) async -> Outcome {
        var req: URLRequest
        var body: [String: Any]
        switch config.provider {
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(config.key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": config.model, "max_tokens": 4096, "system": system,
                    "messages": [["role": "user", "content": prompt]]]
            if tuned {
                // Cleanup needs speed, not deliberation: low effort, and no thinking where the model allows it.
                body["output_config"] = ["effort": "low"]
                if config.model.contains("haiku") { body["thinking"] = ["type": "disabled"] }
            }
        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
            body = ["model": config.model,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
            if tuned && config.model.hasPrefix("gpt-5") { body["reasoning_effort"] = "none" }
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = seconds
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed("encoding") }
        req.httpBody = data
        // Local Only refuses it here too, before anything is sent; otherwise the request is logged (host only).
        let event: UUID?
        do { event = try NetworkGate.begin(.cloudCleanup, host: config.provider.host) } catch { return .failed("Local Only is on") }

        let sc = URLSessionConfiguration.ephemeral
        sc.timeoutIntervalForRequest = seconds
        sc.timeoutIntervalForResource = seconds
        sc.waitsForConnectivity = false
        sc.urlCache = nil
        let session = URLSession(configuration: sc)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (reply, response) = try await session.data(for: req)
            NetworkGate.addBytes(event, Int64(data.count + reply.count))
            guard let http = response as? HTTPURLResponse else { return .failed("no response") }
            guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }
            guard let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return .failed("unreadable reply") }
            let text: String?
            switch config.provider {
            case .anthropic:
                let blocks = json["content"] as? [[String: Any]] ?? []
                if (json["stop_reason"] as? String) == "max_tokens" { return .failed("cut off") }
                text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
            case .openai:
                let choice = (json["choices"] as? [[String: Any]])?.first
                if (choice?["finish_reason"] as? String) == "length" { return .failed("cut off") }
                text = (choice?["message"] as? [String: Any])?["content"] as? String
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed("empty reply") }
            return .text(text)
        } catch let e as URLError {
            return .failed(e.code == .timedOut ? "timed out" : "network \(e.code.rawValue)")
        } catch {
            return .failed("request error")
        }
    }
}

/// Generic passwords in this device's Keychain, never synced to iCloud.
enum CloudKeychain {
    private static let service = "co.stumpandroot.verbatim.cloud-cleanup"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                // The keyboard session can clean up while the phone is locked after first unlock.
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
