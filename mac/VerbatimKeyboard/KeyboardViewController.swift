import UIKit
import SwiftUI

/// The keyboard's root view. It adopts `UIInputViewAudioFeedback` so key presses can play the system input click
/// (`UIDevice.playInputClick`), which works without Allow Full Access and follows Settings › Sounds › Keyboard Clicks.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// The keyboard extension's principal class (Info.plist NSExtensionPrincipalClass). Hosts the SwiftUI keyboard
/// and gives it the text proxy, the globe key, and the hand-off to the app.
///
/// Typing works without Allow Full Access (App Store guideline 4.4.1); only dictation, snippets, and recent
/// dictations need it, because they go through the App Group. Nothing reads the App Group before `hasFullAccess`
/// is checked (`KeyboardModel.defaults`).
final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(controller: self)
    private var host: UIHostingController<AnyView>?

    override func loadView() {
        let v = KeyboardInputView(frame: .zero, inputViewStyle: .default)
        view = v
        if inputView !== v { inputView = v }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Before the first frame: which view to show, and the field's traits for the letter keys.
        model.hasFullAccess = hasFullAccess
        model.showsGlobe = needsInputModeSwitchKey
        model.typing.showsGlobe = needsInputModeSwitchKey
        model.typing.refreshTraits(reset: true)
        model.chooseSurface()
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
        model.typing.showsGlobe = needsInputModeSwitchKey
        model.typing.refreshTraits(reset: true)
        model.chooseSurface()
        // Read once per appearance: nil in App Store builds and on recent iOS releases.
        model.host = hostBundleID()
        applyAppearance()
        model.resume()
    }

    /// What the text field tells every keyboard, for the format chip's Auto (`KeyboardFormat.infer`).
    func fieldTraits() -> KeyboardFormat.FieldTraits {
        let p = textDocumentProxy
        let contentType: UITextContentType? = p.textContentType ?? nil
        return KeyboardFormat.FieldTraits(keyboardType: p.keyboardType, textContentType: contentType,
                                          returnKeyType: p.returnKeyType, before: p.documentContextBeforeInput)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.pause()
        model.typing.reset()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.showsGlobe = needsInputModeSwitchKey
        model.typing.showsGlobe = needsInputModeSwitchKey
        model.typing.refreshTraits(reset: false)
        applyAppearance()
        model.refreshFormat()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        // The cursor moved: shift follows auto-capitalization for the new place.
        model.typing.refreshTraits(reset: false)
    }

    // MARK: The host app

    /// The bundle ID of the app you're typing in, so Verbatim can switch back to it after starting a session.
    /// Nil when iOS doesn't say; Verbatim then asks you to swipe back yourself.
    ///
    /// App Review risk: there is no public API for this (Apple DTS confirmed it on the Apple Developer Forums,
    /// thread 826851). It reads UIInputViewController's private `_hostBundleID` (and, failing that,
    /// `_hostApplicationBundleIdentifier`) on this controller and its parent. Each is checked with `responds(to:)`
    /// first, so a missing selector returns nil instead of crashing. Developers report nil here since iOS 18, and
    /// nil or the string `<null>` for every known key on iOS 26.4 and later; those are ignored. When this returns
    /// nil, the app reads the host from its back breadcrumb instead (`KeyboardSession.returnToHostApp`), which is
    /// the path modern iOS relies on.
    ///
    /// App Store builds (`APP_STORE`) compile this out and return nil; the format chip's Auto then infers from
    /// the text field instead (`KeyboardFormat.infer`).
    func hostBundleID() -> String? {
        guard Distribution.current.readsHostApp else { return nil }
        #if APP_STORE
        return nil
        #else
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
        #endif
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
    ///
    /// App Store builds (`APP_STORE`) compile this out and return false; the keyboard then shows how to start a
    /// session from Control Center, the Action button, or Verbatim (`KeyboardModel.needsSessionCard`).
    @discardableResult
    func openContainingApp(_ url: URL) -> Bool {
        guard Distribution.current.keyboardOpensVerbatim else { return false }
        #if APP_STORE
        return false
        #else
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
        #endif
    }
}
