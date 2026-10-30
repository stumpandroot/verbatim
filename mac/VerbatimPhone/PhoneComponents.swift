import SwiftUI
import UIKit

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
