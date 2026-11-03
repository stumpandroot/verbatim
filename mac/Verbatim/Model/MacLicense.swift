import Foundation

// Verbose for Mac's license (mockup "Verbose License and Calls", November 3, 2026): Polar sells it as merchant of
// record and emails a license key, which you paste in Settings › License and purchases. Activating sends the key and
// this Mac's name to Polar's customer portal API, which needs no secret (it's meant for desktop apps); one license
// covers up to 3 Macs. The free version and the 7-day trial match the iPhone's (Entitlement.swift): this file turns
// the Mac's trial start and license into the same `PurchaseRecord`s, so `Entitlement.state` and `FeatureGate` work
// unchanged. Pure, with no AppKit or networking, so mac/tools/test-mac-license.sh compiles it on Linux with
// Entitlement.swift. The Keychain and URLSession side is App/MacLicenseStore.swift.

enum MacLicense {
    /// Your Polar organization's ID (a UUID, not a secret). Empty until the Polar product is set up; while it's
    /// empty, License and purchases says licensing isn't ready and nothing is enforced.
    static let organizationID = ""
    static let apiBase = "https://api.polar.sh/v1/customer-portal/license-keys"
    /// Polar's checkout page for Verbose for Mac, set with the organization ID.
    static let checkoutURL = ""
    /// Polar's customer portal, where you see your key and remove a Mac.
    static let portalURL = "https://polar.sh/login"

    static let activationLimit = 3
    /// How often a licensed Mac checks in with Polar.
    static let revalidateEvery: TimeInterval = 30 * 86_400
    /// After a failed check-in, the next try waits this long.
    static let retryAfter: TimeInterval = 86_400
    /// How long a license keeps working without reaching Polar (a refund or revoked key is noticed at the next
    /// check-in that gets through).
    static let offlineGrace: TimeInterval = 60 * 86_400

    static var isConfigured: Bool { !organizationID.isEmpty }

    /// A pasted key without spaces, line breaks, or quotes around it.
    static func normalized(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'\u{201C}\u{201D}")))
    }

    /// The activation's label in Polar's portal: this Mac's name.
    static func label(computerName: String) -> String {
        let n = computerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Mac" : String(n.prefix(60))
    }
}

/// The license this Mac holds: the key (kept in the Keychain), its activation, and the last answer from Polar.
struct MacLicenseRecord: Codable, Equatable {
    var key: String
    var activationID: String
    /// Polar's masked key ("****-7Q2M"), for display.
    var displayKey: String
    /// "granted", "revoked", or "disabled", from Polar's last answer.
    var status: String
    var lastValidated: Date
    /// The last check-in that didn't get through, so the next waits `retryAfter`.
    var lastFailedAttempt: Date? = nil

    var isGranted: Bool { status == "granted" }
    /// The last four characters of the key, for "Key ending in 7Q2M".
    var keyEnding: String { String(displayKey.filter { $0.isLetter || $0.isNumber }.suffix(4)) }
}

enum MacEntitlement {
    /// The transactions the Mac's trial and license add up to, for `Entitlement.state`. A license counts while
    /// Polar granted it and the last check-in is within `offlineGrace`; with Local Only on (`checksPaused`), check-ins
    /// can't happen, so the grace doesn't run out.
    static func records(trialStartedAt: Date?, license: MacLicenseRecord?, now: Date, checksPaused: Bool = false) -> [PurchaseRecord] {
        var out: [PurchaseRecord] = []
        if let t = trialStartedAt { out.append(PurchaseRecord(productID: UnlockProduct.trial, purchaseDate: t, transactionID: "mac-trial")) }
        if let l = license, l.isGranted, checksPaused || now.timeIntervalSince(l.lastValidated) <= MacLicense.offlineGrace {
            out.append(PurchaseRecord(productID: UnlockProduct.unlock, purchaseDate: l.lastValidated, transactionID: "mac-license"))
        }
        return out
    }

    static func state(trialStartedAt: Date?, license: MacLicenseRecord?, now: Date, checksPaused: Bool = false) -> EntitlementState {
        Entitlement.state(records(trialStartedAt: trialStartedAt, license: license, now: now, checksPaused: checksPaused), now: now)
    }

    /// Whether to check in with Polar now: every 30 days, and a day after a check-in that failed.
    static func needsValidation(_ l: MacLicenseRecord, now: Date) -> Bool {
        if let f = l.lastFailedAttempt, now.timeIntervalSince(f) < MacLicense.retryAfter { return false }
        return now.timeIntervalSince(l.lastValidated) >= MacLicense.revalidateEvery
    }

    /// Whether the gate is enforced in this build: only the public release (no channel), and only once licensing
    /// is set up. Beta builds keep everything unlocked, as TestFlight builds do on iPhone.
    static func enforces(channel: String, configured: Bool = MacLicense.isConfigured) -> Bool {
        configured && channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Polar's answers

/// Request bodies for Polar's customer portal license key API.
enum PolarRequest {
    static func activate(key: String, label: String, org: String = MacLicense.organizationID) -> [String: Any] {
        ["key": key, "organization_id": org, "label": label]
    }
    static func validate(key: String, activationID: String, org: String = MacLicense.organizationID) -> [String: Any] {
        ["key": key, "organization_id": org, "activation_id": activationID]
    }
    static func deactivate(key: String, activationID: String, org: String = MacLicense.organizationID) -> [String: Any] {
        ["key": key, "organization_id": org, "activation_id": activationID]
    }
}

struct PolarLicenseKey: Decodable, Equatable {
    var display_key: String?
    var status: String?
    var limit_activations: Int?
}

/// POST …/activate: 200 with the activation and its license key.
struct PolarActivation: Decodable, Equatable {
    var id: String
    var license_key: PolarLicenseKey?
}

/// POST …/validate: 200 with the license key's fields at the top level and the activation.
struct PolarValidation: Decodable, Equatable {
    struct Activation: Decodable, Equatable { var id: String }
    var display_key: String?
    var status: String?
    var activation: Activation?
}

struct PolarError: Decodable, Equatable {
    var error: String?
}

/// What can go wrong talking to Polar, as the person sees it.
enum MacLicenseProblem: Equatable {
    case notConfigured
    case limitReached
    case notFound
    case revoked
    case invalid
    case offline
    case other(Int)

    /// From an HTTP status and body (`nil` status: the request didn't get an answer).
    static func from(status: Int?, body: Data?) -> MacLicenseProblem {
        guard let status else { return .offline }
        let err = body.flatMap { try? JSONDecoder().decode(PolarError.self, from: $0) }?.error
        switch status {
        case 403 where err == nil || err == "NotPermitted": return .limitReached
        case 404: return .notFound
        case 422: return .invalid
        default: return .other(status)
        }
    }
}

enum MacLicenseOutcome: Equatable {
    case activated(MacLicenseRecord)
    case problem(MacLicenseProblem)
}

enum MacLicenseParse {
    /// An activate answer, or the problem it describes.
    static func activation(status: Int?, body: Data?, key: String, now: Date) -> MacLicenseOutcome {
        guard status == 200, let body, let a = try? JSONDecoder().decode(PolarActivation.self, from: body) else {
            return .problem(MacLicenseProblem.from(status: status, body: body))
        }
        let st = a.license_key?.status ?? "granted"
        guard st == "granted" else { return .problem(.revoked) }
        return .activated(MacLicenseRecord(key: key, activationID: a.id, displayKey: a.license_key?.display_key ?? key,
                                           status: st, lastValidated: now))
    }

    /// A check-in: the record with Polar's answer, or with the failed attempt noted. A 404 (the activation was
    /// removed in Polar's portal) or a revoked key ends the license; no answer keeps it, within the grace.
    static func validation(status: Int?, body: Data?, record: MacLicenseRecord, now: Date) -> MacLicenseRecord? {
        var r = record
        if status == 200, let body, let v = try? JSONDecoder().decode(PolarValidation.self, from: body) {
            r.status = v.status ?? "granted"
            if let d = v.display_key { r.displayKey = d }
            r.lastValidated = now
            r.lastFailedAttempt = nil
            return r.isGranted ? r : nil
        }
        if status == 404 { return nil }
        r.lastFailedAttempt = now
        return r
    }
}

// MARK: - Copy

/// Every line License and purchases shows (mockup). No em dashes or exclamation points.
enum MacLicenseCopy {
    static let pane = "License and purchases"
    static let productName = "Verbose for Mac"
    static let pitch = "Verbose for Mac: $49, or $39 at launch. One-time purchase for up to 3 Macs, with free 1.x updates."
    static let tryFree = "Try it free for 7 days"
    static func buy(_ price: String = "$39") -> String { "Buy for \(price)" }
    static let haveKey = "Have a license key?"
    static let keyPlaceholder = "Paste your key"
    static let activate = "Activate"
    static let iPhoneSeparate = "The iPhone app is a separate purchase in the App Store."
    static func trialLeft(_ days: Int) -> String { "Free trial: \(days == 1 ? "1 day" : "\(days) days") left" }
    static func trialBody(ends: String) -> String {
        "Everything is unlocked until \(ends). Nothing is charged. After that, Verbose goes back to the free version and everything you made stays."
    }
    static let trialEnded = "Your free trial ended. Dictate stays free, and recordings of any length are transcribed free for their first 10 minutes."
    static let licensed = "Verbose for Mac is licensed"
    static func licensedBody(ending: String) -> String { "Key ending in \(ending). It works on up to 3 Macs, including this one." }
    static let deactivate = "Deactivate this Mac"
    static let deactivateNote = "Deactivate before you sell or erase a Mac, so the license is free for another."
    static let manage = "Manage in Polar"
    static let deactivated = "This Mac is deactivated. The license is free for another Mac."
    static let offlineNote = "Verbose checks the license with Polar once every 30 days. It couldn't reach Polar, so it'll try again tomorrow. Everything keeps working offline."
    static let notReady = "Licensing isn't set up in this build yet. Everything is unlocked."

    static func problem(_ p: MacLicenseProblem) -> String {
        switch p {
        case .notConfigured: return notReady
        case .limitReached: return "This license is active on 3 Macs. Deactivate one in Settings on that Mac, or in your Polar account, then try again."
        case .notFound: return "Polar doesn't know this key. Check that you pasted all of it, from the email Polar sent."
        case .revoked: return "This license was refunded or turned off in Polar, so it can't be used."
        case .invalid: return "That doesn't look like a license key. Paste the whole key from Polar's email."
        case .offline: return "Couldn't reach Polar. Check your connection and try again."
        case .other(let code): return "Polar couldn't activate the key (error \(code)). Try again in a few minutes."
        }
    }

    static var allLines: [String] {
        [pane, productName, pitch, tryFree, buy(), haveKey, keyPlaceholder, activate, iPhoneSeparate, trialLeft(5), trialLeft(1),
         trialBody(ends: "Sunday, November 8"), trialEnded, licensed, licensedBody(ending: "7Q2M"), deactivate, deactivateNote, manage,
         deactivated, offlineNote, notReady]
        + [MacLicenseProblem.notConfigured, .limitReached, .notFound, .revoked, .invalid, .offline, .other(500)].map(problem)
    }
}
