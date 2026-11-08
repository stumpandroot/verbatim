import SwiftUI
import UIKit

// MARK: - Radii

extension RefinedPlatform {
    /// An icon square's corner at another side than `IconSquare`'s 30 pt, in the same proportion (IP-24): the kit's
    /// `.square` radius scaled by `side / 30`, so a 22 pt number badge gets about 6 and a 34 pt square about 9.
    static func squareRadius(side: CGFloat) -> CGFloat {
        radius(.square) * side / CGFloat(RefinedRules.squareSize(mac: mac).side)
    }
}

// MARK: - Closing a sheet

/// The one way a read-only sheet closes (IP-28; HIG, Sheets): the system's close button at the trailing edge of its
/// navigation bar, `Button(role: .close)` on iOS 26 and later, and an xmark labeled Close before that. Sheets with
/// edits keep Cancel and Done; sheets without a navigation bar use the kit's round xmark. Put any other action (Copy,
/// Redo) before it, so Close stays at the edge.
struct CloseToolbarItem: ToolbarContent {
    var action: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if #available(iOS 26, *) {
                Button(role: .close, action: action)
                    .accessibilityIdentifier("sheet.close")
            } else {
                Button(action: action) { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("sheet.close")
            }
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

/// An image from the synced stills folder, decoded and scaled down off the main thread once (`ThumbCache`, shared
/// with the Mac). The plain track shows while it loads and when the file isn't there.
struct StillImage: View {
    var file: String
    /// The longest side to decode, in pixels: about three times the widest it's drawn (a full-width still).
    var maxPixel = 1200
    var body: some View {
        ThumbImage(file: file, maxPixel: maxPixel) { Rectangle().fill(Refined.track) }
    }
}
