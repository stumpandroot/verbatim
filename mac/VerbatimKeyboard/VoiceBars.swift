import SwiftUI

/// Three bars that rise with the voice level (0…1): the bars mark, alive. Shared by the keyboard's Listening
/// card and the app's hand-off screen. Under Reduce Motion the bars still follow the level, without easing.
struct VoiceBars: View {
    var level: Double
    var color: Color
    var barWidth: CGFloat = 10
    var maxHeight: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let weights: [Double] = [0.65, 1.0, 0.8]

    var body: some View {
        HStack(alignment: .center, spacing: barWidth * 0.6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: height(i))
            }
        }
        .frame(height: maxHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    private func height(_ i: Int) -> CGFloat {
        let l = min(1, max(0, level))
        // A gentle curve so quiet speech still moves the bars.
        let lifted = pow(l, 0.6)
        let minH = barWidth
        return minH + CGFloat(lifted * Self.weights[i]) * (maxHeight - minH)
    }
}
