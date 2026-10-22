import Foundation
import Combine
import Sparkle

/// UserDefaults key for "Get beta builds", shared by `Updater` and its Sparkle delegate.
private let betaUpdatesKey = "updates.beta"

/// Automatic updates (Sparkle 2) for the direct-download Mac app. See mac/Updates/README.md.
///
/// The updater starts only when Info.plist carries an EdDSA public key (`SUPublicEDKey`) and the app isn't running
/// the UI self-test or the bench. Without a key it stays off silently: no checks, no error dialogs.
/// Two channels share one feed: stable items have no channel; every build of `main` is published as "beta".
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// True while the updater runs and no check is in progress (KVO from `SPUUpdater.canCheckForUpdates`).
    @Published private(set) var canCheckForUpdates = false
    /// True once the updater has started.
    @Published private(set) var isRunning = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    /// "Get beta builds": every build of `main`, not only tagged releases.
    @Published var betaUpdates: Bool {
        didSet { UserDefaults.standard.set(betaUpdates, forKey: betaUpdatesKey) }
    }

    let version: String
    let build: String

    private let channels: UpdaterChannels   // kept here: the controller holds its delegate weakly
    private let controller: SPUStandardUpdaterController

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        build = info["CFBundleVersion"] as? String ?? "?"
        // CI builds of main are versioned 0.0.0, so the owner's dev builds follow the beta channel by default.
        UserDefaults.standard.register(defaults: [betaUpdatesKey: version == "0.0.0"])
        betaUpdates = UserDefaults.standard.bool(forKey: betaUpdatesKey)
        let delegate = UpdaterChannels()
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        channels = delegate
        controller = c
        automaticallyChecksForUpdates = c.updater.automaticallyChecksForUpdates
    }

    /// The EdDSA public key from Info.plist; empty until the owner adds it to project.yml.
    private var publicKey: String {
        ((Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts the updater when it's configured. Safe to call more than once.
    func start() {
        guard !isRunning else { return }
        guard !publicKey.isEmpty else {
            // Release builds ship with SUPublicEDKey empty until the EdDSA key is added (mac/Updates/README.md).
            Log.note("updates: OFF. This build has no Sparkle public key (SUPublicEDKey is empty in Info.plist), so it never checks for or installs updates. Add the key printed by Sparkle's generate_keys to project.yml to turn updates on.")
            NSLog("Verbatim: automatic updates are off; SUPublicEDKey is empty in this build.")
            return
        }
        guard !UITest.enabled, !Bench.isRequested else {
            Log.note("updates: off (UI test or bench)"); return
        }
        do {
            // `start()` rather than the controller's `startUpdater()`, which shows an alert when starting fails.
            try controller.updater.start()
        } catch {
            Log.note("updates: couldn't start: \(error.localizedDescription)")
            return
        }
        isRunning = true
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        Log.note("updates: on (beta \(betaUpdates ? "on" : "off"), automatic \(automaticallyChecksForUpdates ? "on" : "off"))")
    }

    /// "Check for Updates…": a user-initiated check with Sparkle's standard UI.
    func checkForUpdates() {
        guard isRunning else { return }
        controller.checkForUpdates(nil)
    }
}

/// Sparkle delegate: opts into the beta channel when "Get beta builds" is on. The protocol is main-actor
/// (NS_SWIFT_UI_ACTOR), so this class is too; Sparkle asks before every check, so a change applies on the next one.
final class UpdaterChannels: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: betaUpdatesKey) ? ["beta"] : []
    }
}
