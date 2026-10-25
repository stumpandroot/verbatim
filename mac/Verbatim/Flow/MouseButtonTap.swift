import AppKit
import CoreGraphics

/// Listens for one mouse side button, the hotkey in Settings › Dictation › Hotkey › A mouse button, with a
/// `CGEventTap` on `otherMouseDown` and `otherMouseUp`. It runs only while a mouse button is the hotkey.
///
/// The tap takes that button's clicks, so a browser doesn't also go back while you dictate. An active tap uses the
/// Accessibility access dictation already has; if macOS refuses one, it falls back to a listen-only tap, which asks
/// for Input Monitoring (once, and only because a mouse button was chosen). Left, right, and middle clicks always
/// pass through untouched. Mouse utilities such as Logi Options+ can remap or swallow side buttons before this sees them.
@MainActor
final class MouseButtonTap {
    private let handler: @MainActor (Int, Bool) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The button being listened for (macOS's number: button 4 is 3), or nil while stopped.
    private(set) var button: Int?
    /// True when macOS allowed only a listen-only tap (the button's clicks also reach the app under the pointer).
    private(set) var listenOnly = false
    /// Read by the tap's callback, which runs on the main run loop.
    fileprivate var watched = -1

    init(handler: @escaping @MainActor (Int, Bool) -> Void) { self.handler = handler }

    func start(button n: Int) {
        if let t = tap, button == n {
            if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        stop()
        let mask = CGEventMask((1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue))
        let me = Unmanaged.passUnretained(self).toOpaque()
        var made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: mouseTapCallback, userInfo: me)
        listenOnly = false
        if made == nil {
            // No active tap: listen only, which needs Input Monitoring. macOS shows its prompt once.
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                     eventsOfInterest: mask, callback: mouseTapCallback, userInfo: me)
            listenOnly = made != nil
        }
        guard let t = made else {
            Log.note("mouse button: no event tap (needs Accessibility, or Input Monitoring)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = src
        button = n
        watched = n
        Log.note("mouse button: listening for \(MouseButtons.title(n))\(listenOnly ? " (listen only)" : "")")
    }

    func stop() {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        button = nil
        watched = -1
    }

    /// macOS turns a tap off when a callback is slow or input is being secured; turn it back on.
    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }
    fileprivate func fire(_ n: Int, down: Bool) { handler(n, down) }
}

/// The tap's callback, on the main run loop. Only the watched button is taken; everything else passes through.
private func mouseTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<MouseButtonTap>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { owner.reenable() }
        return Unmanaged.passUnretained(event)
    case .otherMouseDown, .otherMouseUp:
        let n = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let mine = MainActor.assumeIsolated { owner.watched == n }
        guard mine else { return Unmanaged.passUnretained(event) }
        let down = type == .otherMouseDown
        MainActor.assumeIsolated { owner.fire(n, down: down) }
        return nil   // taken (a listen-only tap ignores this, and the click goes on as well)
    default:
        return Unmanaged.passUnretained(event)
    }
}
