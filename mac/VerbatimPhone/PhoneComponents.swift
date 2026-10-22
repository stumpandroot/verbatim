import SwiftUI
import UIKit

// MARK: - Materials

/// The surface for controls that float over content and carry text (the player bar): opaque `Ink.bar` with a
/// hairline, never glass, because text never sits on a blur (DESIGN.md §5.1). Glass stays with the system's own
/// toolbars and tab bar.
struct FloatingGlass<S: Shape>: ViewModifier {
    var shape: S
    var interactive = true
    func body(content: Content) -> some View {
        content.background(Ink.bar, in: shape).overlay(shape.stroke(Ink.hairline))
    }
}
extension View {
    func floatingGlass<S: Shape>(_ shape: S, interactive: Bool = true) -> some View { modifier(FloatingGlass(shape: shape, interactive: interactive)) }
}

/// A raised key: top highlight, contact shadow, compresses when pressed (0.97 over 320 ms). One per screen.
struct RaisedKeyStyle: ButtonStyle {
    var fill: Color = Ink.persimmon
    func makeBody(configuration: Configuration) -> some View { Key(configuration: configuration, fill: fill) }
    private struct Key: View {
        let configuration: ButtonStyleConfiguration
        var fill: Color
        @Environment(\.limitMotion) private var limitMotion
        var body: some View {
            configuration.label
                .background(Circle().fill(fill))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center), lineWidth: 1.5))
                .shadow(color: Ink.inkFixed.opacity(configuration.isPressed ? 0.06 : 0.16), radius: configuration.isPressed ? 2 : 8, y: configuration.isPressed ? 1 : 4)
                .scaleEffect(configuration.isPressed && !limitMotion ? 0.97 : 1)
                .animation(limitMotion ? Motion.fade : Motion.pressSoft, value: configuration.isPressed)
        }
    }
}

/// A sheet-level tactile button: card fill, hairline, compresses on press.
struct TactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Ink.ink)
            .background(configuration.isPressed ? Ink.wash : Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
            .shadow(color: Ink.inkFixed.opacity(configuration.isPressed ? 0 : 0.05), radius: 3, y: 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.06 : 0.14), value: configuration.isPressed)
    }
}

// MARK: - Rows

/// One transcript as an index entry. Swipe and long-press actions come from the list.
struct PhoneRow: View {
    var transcript: Transcript
    var body: some View {
        HStack(spacing: 12) {
            // Colored by source, as on Home (DESIGN.md §1); the kind is a neutral word in the meta line.
            SourceTile(transcript: transcript)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if transcript.pinned { IconGlyph(art: .iconPin, size: 12, color: Ink.mute).accessibilityLabel("Pinned") }
                    Text(transcript.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(sourceName)
                    if transcript.duration > 0 { Text("·"); Text(HomeRecentStyle.length(transcript.duration)).monospacedDigit() }
                    if transcript.speakers.count >= 2 { Text("·"); Text("\(transcript.speakers.count) speakers") }
                    if let k = transcript.kind, k != .dictation { Text("·"); Text(k.label) }
                }
                .font(.system(size: 13)).foregroundStyle(Ink.mute).lineLimit(1)
                stateLine
            }
            Spacer(minLength: 6)
            Text(dateLine).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Ink.mute)
        }
        .padding(12)
        .cardSurface(radius: Radius.row)
        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var sourceName: String {
        switch transcript.source { case .dictation: return "Dictation"; case .voiceMemo: return "Voice note"; default: return transcript.sourceLabel }
    }

    @ViewBuilder private var stateLine: some View {
        if transcript.status == .processing {
            HStack(spacing: 6) {
                if transcript.processingDevice == Device.id { ProgressView().controlSize(.mini) } else { IconGlyph(art: .iconWaitingForMac, size: 15, color: Ink.dim) }
                Text(transcript.stageText).lineLimit(1)
            }
            .font(.system(size: 12.5)).foregroundStyle(Ink.dim)
        } else if transcript.status == .failed {
            HStack(spacing: 6) { IconGlyph(art: .iconAttention, size: 15, color: Ink.danger); Text("Needs retry") }.font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.danger)
        }
    }

    private var dateLine: String {
        let cal = Calendar.current
        if cal.isDateInToday(transcript.createdAt) { return "Today" }
        if cal.isDateInYesterday(transcript.createdAt) { return "Yest." }
        return Formats.pattern("MMM d").string(from: transcript.createdAt)
    }
}

/// A row's source tile: the source's tint and brand icon (voice notes persimmon, files and links sage, app audio
/// petal, dictation butter), as on Home.
struct SourceTile: View {
    var transcript: Transcript
    var body: some View {
        let style = HomeRecentStyle(transcript)
        // Rows stay still: list rows don't animate (design system rule).
        return BrandGlyph(art: style.art, color: style.onTint, minLineWidth: 1.3).padding(10)
            .frame(width: 40, height: 40)
            .background(style.tint, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Meter

struct ElapsedLabel: View {
    @ObservedObject var live: LiveMeter
    var size: CGFloat = 40
    var body: some View {
        Text(live.elapsed.timecode).font(Ink.mono(size, weight: .medium)).foregroundStyle(Ink.ink)
            .contentTransition(.numericText()).accessibilityLabel("Elapsed \(live.elapsed.timecode)")
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

/// An image from the synced stills folder.
struct StillImage: View {
    var file: String
    var body: some View {
        Rectangle().fill(Ink.track).overlay {
            if let img = UIImage(contentsOfFile: Paths.thumbs.appendingPathComponent(file).path) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
    }
}

/// The ink-on-paper segmented control used for modes.
struct ModePicker<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button { withAnimation(Motion.snap) { selection = value } } label: {
                    Text(label).font(.system(size: 13.5, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(selection == value ? Ink.onInteractive : Ink.ink)
                        .background { if selection == value { Capsule().fill(Ink.interactive) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Ink.track, in: Capsule())
    }
}
