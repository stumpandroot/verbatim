import UIKit
import SwiftUI

/// The keyboard extension's principal class (Info.plist NSExtensionPrincipalClass). Hosts the SwiftUI keyboard
/// and gives it the text proxy, the globe key, and the hand-off to the app.
final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(controller: self)
    private var host: UIHostingController<AnyView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = KeyboardView(model: model)
        let host = UIHostingController(rootView: AnyView(root))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 272)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        host.didMove(toParent: self)
        self.host = host
        applyAppearance()
        // The host's light or dark mode can change while the keyboard is up.
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: KeyboardViewController, _: UITraitCollection) in
            vc.applyAppearance()
        }
    }

    /// Paper in light, ink in dark, following the field you're typing in: its `keyboardAppearance` when it asks for
    /// one, otherwise the host app's light or dark mode. Set on the SwiftUI host only, so this controller's own
    /// trait collection keeps reporting the host's mode.
    private func applyAppearance() {
        let style: UIUserInterfaceStyle
        switch textDocumentProxy.keyboardAppearance {
        case .some(.dark): style = .dark
        case .some(.light): style = .light
        default: style = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        if host?.overrideUserInterfaceStyle != style { host?.overrideUserInterfaceStyle = style }
        view.backgroundColor = KB.uiPaper.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.showsGlobe = needsInputModeSwitchKey
        model.hasFullAccess = hasFullAccess
        applyAppearance()
        model.resume()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.pause()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.showsGlobe = needsInputModeSwitchKey
        applyAppearance()
    }

    // MARK: The host app

    /// The bundle ID of the app you're typing in, so Verbatim can switch back to it after starting a session.
    /// Nil when iOS doesn't say; Verbatim then asks you to swipe back yourself.
    ///
    /// App Review risk: there is no public API for this. It reads UIInputViewController's private `_hostBundleID`
    /// (and, failing that, a parent's `_hostApplicationBundleIdentifier`). Both are checked with `responds(to:)`
    /// first, so a missing selector returns nil instead of crashing. Some iOS versions return nil or a system
    /// process's ID here; those are ignored.
    func hostBundleID() -> String? {
        let candidates: [(NSObject?, String)] = [
            (self as NSObject?, "_hostBundleID"),
            (parent as NSObject?, "_hostBundleID"),
            (self as NSObject?, "_hostApplicationBundleIdentifier"),
            (parent as NSObject?, "_hostApplicationBundleIdentifier"),
        ]
        for (object, name) in candidates {
            let sel = NSSelectorFromString(name)
            guard let object, object.responds(to: sel),
                  let value = object.perform(sel)?.takeUnretainedValue() as? String else { continue }
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Not a real host: empty, or a system UI process rather than the app you're in.
            guard !id.isEmpty, id != "<null>", !id.hasPrefix("com.apple.InputUI"), id != Bundle.main.bundleIdentifier else { continue }
            return id
        }
        return nil
    }

    // MARK: Opening the app

    /// Opens the Verbatim app. Returns false when no opener was found.
    ///
    /// Keyboard extensions can't call `UIApplication.shared.open` (it's unavailable to app extensions), and
    /// `extensionContext.open` works only for Today widgets and iMessage apps. The common workaround, used here,
    /// walks the responder chain to the extension process's `UIApplication` object and sends it
    /// `openURL:options:completionHandler:` by selector.
    ///
    /// App Review risk: this is undocumented. Apple has approved many keyboards that open their container app
    /// this way (voice and AI keyboards do it to start recording), but a reviewer can reject it under guideline
    /// 2.5.1 (public APIs only), and an iOS release can break it without notice (iOS 18 stopped honoring the old
    /// one-argument `openURL:`). Everything that depends on it goes through this one function, so it can be
    /// swapped for a documented route, such as asking you to open Verbatim yourself, without touching the rest.
    @discardableResult
    func openContainingApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if r !== self, r.responds(to: selector), NSStringFromClass(type(of: r)).contains("Application") {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let imp = r.method(for: selector)
                let open = unsafeBitCast(imp, to: OpenURL.self)
                open(r, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}
