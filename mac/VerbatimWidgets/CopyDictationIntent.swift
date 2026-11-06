#if os(iOS)
import Foundation
import AppIntents
import UIKit
import WidgetKit

/// Copy on the Recent dictations widget (HomeWidgets.swift; iOS 17 interactive widgets): puts one dictation's words on
/// the clipboard without opening Verbose. Compiled into the VerbatimWidgets extension only, so iOS runs `perform` there:
/// the words come from the snapshot the app wrote (`WidgetSnapshot.dictations`), so nothing needs the app or its
/// library. Only a dictation whose words are whole in the snapshot gets the button; a longer one opens in Verbose
/// instead, so Copy never copies part of a dictation.
///
/// After copying it notes which dictation and when in the App Group (`WidgetSnapshot.copiedKey`), and the widget's
/// timeline, which iOS reloads after an interactive widget's intent, shows that row as Copied for two seconds.
struct CopyDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy a dictation"
    static var description = IntentDescription("Copies one of your recent dictations from the Recent dictations widget.")
    static var openAppWhenRun: Bool = false
    /// Not offered in Shortcuts or Spotlight: it only makes sense as the widget's button, with an ID the widget gives.
    static var isDiscoverable: Bool = false
    /// The words are yours: on a locked iPhone (StandBy), Face ID, Touch ID, or the passcode comes first.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Dictation")
    var dictationID: String

    init() {}

    init(id: UUID) { dictationID = id.uuidString }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: dictationID),
              let row = WidgetSnapshotStore.read()?.dictations?.first(where: { $0.id == id }), row.whole else {
            // Gone since the widget drew it (deleted, or pushed out by newer ones): the reload that follows redraws it.
            return .result()
        }
        await MainActor.run { UIPasteboard.general.string = row.text }
        KeyboardBridge.defaults?.set(WidgetSnapshot.copiedMarker(id, at: Date()), forKey: WidgetSnapshot.copiedKey)
        WidgetCenter.shared.reloadTimelines(ofKind: RecentDictationsWidget.kind)
        return .result()
    }
}
#endif
