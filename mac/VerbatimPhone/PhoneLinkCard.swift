import SwiftUI
import UIKit

/// The "link added" card on iPhone, laid over the whole TabView so its tile can fly from the screen into the
/// Library tab, plus the Library tab's count badge (persimmon, like the Mac's Queue badge).
///
/// The system tab bar doesn't publish its items' frames to SwiftUI, so `TabBarLocator` reads the Library item's
/// frame from UIKit (the tab bar's buttons, in window coordinates), falling back to an equal share of the tab
/// bar's width. The overlay ignores the safe area, so window coordinates are its own.
struct PhoneLinkCardLayer: View {
    @EnvironmentObject var app: PhoneState
    @State private var libraryItem: CGRect? = nil

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            let item = libraryItem.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            ZStack(alignment: .topLeading) {
                if let imp = app.linkCardImport {
                    let id = imp.id
                    LinkCardOverlay(imp: imp, metrics: .phone,
                                    target: item.map { CGPoint(x: $0.midX, y: $0.minY + min(18, $0.height / 2)) },
                                    onCancel: { app.cancelLinkCard(id) },
                                    onRetry: { app.retryLinkCard(id) },
                                    onLanded: { app.linkCardLanded(id) },
                                    onClosed: { app.closeLinkCard(id) })
                        .id(id)
                        .onAppear(perform: locate)
                }
                if let item {
                    let count = app.libraryBadgeCount
                    CountPill(text: "\(count)", pops: app.libraryBadgePops)
                        .opacity(count == 0 ? 0 : 1)
                        .animation(Motion.fade, value: count == 0)
                        // Where the system puts a tab badge: above the icon's top-right corner.
                        .position(x: item.midX + 14, y: item.minY + 9)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .onChange(of: g.size) { _, _ in DispatchQueue.main.async(execute: locate) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(app.linkCardImport != nil)
        .sensoryFeedback(.success, trigger: app.libraryBadgePops)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: locate) }
        .onChange(of: app.libraryBadgeCount) { _, _ in locate() }
        .onChange(of: app.tab) { _, _ in DispatchQueue.main.async(execute: locate) }
        .onReceive(app.tabBarStore.$bar) { _ in DispatchQueue.main.async(execute: locate) }
    }

    /// The Library item, or Home's when Library isn't in the bar (a link lands there then).
    private func locate() {
        let bar = app.tabBar
        let f = TabBarLocator.itemFrame(index: bar.position(.library) ?? 0, of: bar.tabs.count)
        if f != libraryItem { libraryItem = f }
    }
}

/// Finds a tab bar item's frame in window coordinates.
@MainActor
enum TabBarLocator {
    static func itemFrame(index: Int, of count: Int) -> CGRect? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              let bar = find(in: window), !bar.isHidden, bar.alpha > 0.01 else { return nil }
        let barFrame = bar.convert(bar.bounds, to: window)
        guard barFrame.width > 0, barFrame.minY < window.bounds.maxY else { return nil }
        // The item buttons, when the tab bar's hierarchy shows exactly one per tab.
        var buttons: [CGRect] = []
        collect(bar, into: &buttons, window: window)
        let distinct = buttons.reduce(into: [CGRect]()) { acc, r in
            if !acc.contains(where: { abs($0.midX - r.midX) < 4 }) { acc.append(r) }
        }.sorted { $0.minX < $1.minX }
        if distinct.count == count { return distinct[index] }
        let w = barFrame.width / CGFloat(count)
        return CGRect(x: barFrame.minX + w * CGFloat(index), y: barFrame.minY, width: w, height: min(barFrame.height, 49))
    }

    private static func find(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for v in view.subviews { if let bar = find(in: v) { return bar } }
        return nil
    }

    private static func collect(_ view: UIView, into out: inout [CGRect], window: UIWindow) {
        for v in view.subviews where !v.isHidden && v.alpha > 0.01 {
            let name = String(describing: type(of: v))
            if (name.contains("TabBarButton") || name.hasSuffix("TabButton")) && v.bounds.width > 20 {
                out.append(v.convert(v.bounds, to: window))
            } else {
                collect(v, into: &out, window: window)
            }
        }
    }
}
