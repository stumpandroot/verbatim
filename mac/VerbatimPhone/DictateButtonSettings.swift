import SwiftUI

/// Settings › Keyboard › Dictate button (the notch mockup's section 05): a live preview of the keyboard's top bar,
/// then Size (Standard or Large), Position (Left, Center, or Right), and Style (Filled or Outline). The choices go
/// to the App Group (`DictateButton.Key`), where the keyboard reads them the next time it appears.
struct DictateButtonSettings: View {
    @AppStorage(DictateButton.Key.size, store: KeyboardBridge.defaults) private var size = DictateButton.Size.standard.rawValue
    @AppStorage(DictateButton.Key.position, store: KeyboardBridge.defaults) private var position = DictateButton.Position.right.rawValue
    @AppStorage(DictateButton.Key.style, store: KeyboardBridge.defaults) private var style = DictateButton.Style.filled.rawValue

    private var look: DictateButton { DictateButton(size: size, position: position, style: style) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dictate button").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                DictateButtonPreview(look: look)
                choiceRow("Size", DictateButton.Size.allCases.map { ($0.rawValue, $0.title) }, $size)
                Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 14)
                choiceRow("Position", DictateButton.Position.allCases.map { ($0.rawValue, $0.title) }, $position)
                Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 14)
                choiceRow("Style", DictateButton.Style.allCases.map { ($0.rawValue, $0.title) }, $style)
            }
            .cardSurface(radius: Radius.row)
            Text("Large makes the keyboard 16 pt taller. Position also moves Tap to talk and Done.")
                .font(.system(size: 13)).foregroundStyle(Ink.mute)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func choiceRow(_ title: String, _ options: [(String, String)], _ selection: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 16)).foregroundStyle(Ink.ink)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            PhoneSegmented(options: options, selection: selection)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(minHeight: 50)
    }
}

/// The preview: the keyboard's top bar as Typing draws it (the menu and the dictate button where the position puts
/// them), over two rows of keys. Drawn, not interactive; VoiceOver reads the choices as one line.
struct DictateButtonPreview: View {
    var look: DictateButton

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(look.typingBar.enumerated()), id: \.offset) { _, slot in
                    switch slot {
                    case .menu: menu
                    case .spacer: Spacer(minLength: 6)
                    case .button: PreviewDictateButton(look: look)
                    case .balance: Color.clear.frame(width: 46, height: 46)
                    }
                }
            }
            .frame(height: CGFloat(look.barHeight))
            keyRow(10).padding(.top, 2)
            keyRow(9).padding(.horizontal, 14)
        }
        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(Ink.side)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.row, topTrailingRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(look.size.title), \(look.position.title.lowercased()), \(look.style.title.lowercased()) dictate button")
    }

    private var menu: some View {
        Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .medium)).foregroundStyle(Ink.ink)
            .frame(width: 46, height: 46)
            .background(Circle().fill(Ink.chip))
    }

    private func keyRow(_ n: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<n, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Ink.card)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Ink.ink.opacity(0.25)).offset(y: 1))
            }
        }
    }
}

/// The dictate button as the keyboard draws it: Standard is the 46 pt pill with Start; Large is the 62 pt disc.
/// Filled is butter with grain and a fixed-ink outline (none in dark); Outline is card white with an ink ring.
/// Both keep the hard shadow.
private struct PreviewDictateButton: View {
    var look: DictateButton
    private static let bars: [CGFloat] = [9, 16, 20, 12, 17]
    private static let rim = Ink.make { dark, _ in dark ? PColor.clear : PColor(hex: Ink.inkHex) }

    var body: some View {
        if look.size == .large {
            bars(height: 24, width: 3.5)
                .frame(width: 62, height: 62)
                .modifier(Surface(filled: look.style == .filled, shape: Circle(), shadow: CGSize(width: 3, height: 4), rim: Self.rim))
        } else {
            HStack(spacing: 10) {
                Text("Start").font(.system(size: 17, weight: .bold)).foregroundStyle(foreground)
                bars(height: 20, width: 3)
            }
            .padding(.leading, 20).padding(.trailing, 16).frame(height: 46)
            .modifier(Surface(filled: look.style == .filled, shape: Capsule(), shadow: CGSize(width: 2, height: 3), rim: Self.rim))
        }
    }

    private var foreground: Color { look.style == .filled ? Ink.inkFixed : Ink.ink }

    private func bars(height: CGFloat, width: CGFloat) -> some View {
        HStack(spacing: width * 0.85) {
            ForEach(Self.bars.indices, id: \.self) { i in
                Capsule().fill(foreground).frame(width: width, height: Self.bars[i] * height / 20)
            }
        }
        .frame(height: height)
    }

    private struct Surface<S: InsettableShape>: ViewModifier {
        var filled: Bool
        var shape: S
        var shadow: CGSize
        var rim: Color
        func body(content: Content) -> some View {
            content
                .background { PhonePanelFill(color: filled ? Ink.panelButter : Ink.card, shape: shape, grain: filled) }
                .overlay(shape.strokeBorder(filled ? rim : Ink.ink, lineWidth: 1.5))
                .background(shape.fill(Ink.hard).offset(x: shadow.width, y: shadow.height))
        }
    }
}
