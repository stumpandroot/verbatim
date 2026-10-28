import SwiftUI
import UIKit

// MARK: - Materials

/// A sheet-level tactile button: card fill, hairline, compresses on press.
struct TactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.lookInk)
            .background(configuration.isPressed ? Ink.wash : Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(.lookHairline))
            .shadow(color: Ink.inkFixed.opacity(configuration.isPressed ? 0 : 0.05), radius: 3, y: 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.06 : 0.14), value: configuration.isPressed)
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
        ThumbImage(file: file, maxPixel: maxPixel) { Rectangle().fill(Ink.track) }
    }
}
