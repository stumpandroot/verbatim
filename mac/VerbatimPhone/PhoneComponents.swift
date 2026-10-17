import SwiftUI
import UIKit

// MARK: - Materials

/// Glass for controls that float over content (iOS 26 Liquid Glass), with an opaque fallback under Reduce
/// Transparency and a material fallback on iOS 17–18. See 01-design-system.md, "Materials ladder".
struct FloatingGlass<S: Shape>: ViewModifier {
    var shape: S
    var interactive = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Ink.bar, in: shape).overlay(shape.stroke(Ink.hairline))
        } else if #available(iOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).overlay(shape.stroke(Ink.hairline))
        }
    }
}
extension View {
    func floatingGlass<S: Shape>(_ shape: S, interactive: Bool = true) -> some View { modifier(FloatingGlass(shape: shape, interactive: interactive)) }
}

/// A raised key: top highlight, contact shadow, compresses when pressed. One per screen.
struct RaisedKeyStyle: ButtonStyle {
    var fill: Color = Ink.persimmon
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center), lineWidth: 1.5))
            .shadow(color: Ink.inkFixed.opacity(configuration.isPressed ? 0.06 : 0.16), radius: configuration.isPressed ? 2 : 8, y: configuration.isPressed ? 1 : 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.06 : 0.14), value: configuration.isPressed)
    }
}

/// A sheet-level tactile button: card fill, hairline, compresses on press.
struct TactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Ink.ink)
            .background(configuration.isPressed ? Ink.wash : Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.hairline))
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
            SourceTile(source: transcript.source)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if transcript.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.mute).accessibilityLabel("Pinned") }
                    Text(transcript.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(sourceName)
                    if transcript.duration > 0 { Text("·"); Text(transcript.duration.timecode).font(Ink.mono(12.5)) }
                    if transcript.speakers.count >= 2 { Text("·"); Text("\(transcript.speakers.count) speakers") }
                }
                .font(.system(size: 13)).foregroundStyle(Ink.mute).lineLimit(1)
                stateLine
            }
            Spacer(minLength: 6)
            Text(dateLine).font(Ink.mono(12)).foregroundStyle(Ink.mute)
        }
        .padding(12)
        .cardSurface(radius: 14)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var sourceName: String {
        switch transcript.source { case .dictation: return "Dictation"; case .voiceMemo: return "Voice note"; default: return transcript.sourceLabel }
    }

    @ViewBuilder private var stateLine: some View {
        if transcript.status == .processing {
            HStack(spacing: 6) {
                if transcript.processingDevice == Device.id { ProgressView().controlSize(.mini) } else { Image(systemName: "laptopcomputer").font(.system(size: 11)) }
                Text(transcript.stageText).lineLimit(1)
            }
            .font(.system(size: 12.5)).foregroundStyle(Ink.dim)
        } else if transcript.status == .failed {
            Label("Needs retry", systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(Ink.danger)
        }
    }

    private var dateLine: String {
        let cal = Calendar.current
        if cal.isDateInToday(transcript.createdAt) { return "Today" }
        if cal.isDateInYesterday(transcript.createdAt) { return "Yest." }
        return Formats.pattern("MMM d").string(from: transcript.createdAt)
    }
}

struct SourceTile: View {
    var source: SourceKind
    var body: some View {
        let (art, tint): (BrandArt?, Color) = {
            switch source {
            case .voiceMemo, .dictation: return (.capture, Ink.persimmonTint)
            case .link: return (.play, Ink.sageTint)
            case .app: return (nil, Ink.petalTint)
            case .file: return (.document, Ink.butterTint)
            }
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint)
            if let art { BrandGlyph(art: art, color: Ink.ink, minLineWidth: 1.3).padding(8) }
            else { Image(systemName: source.symbol).font(.system(size: 15)).foregroundStyle(Ink.ink) }
        }
        .frame(width: 40, height: 40)
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
