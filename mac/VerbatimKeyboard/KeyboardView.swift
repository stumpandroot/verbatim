import SwiftUI
import UIKit

/// The keyboard's fixed paper palette (the approved mockup). Light only: the keyboard keeps its paper look in
/// dark host apps.
enum KB {
    static let paper = Color(hex: 0xF5F0E6)
    static let ink = Color(hex: 0x26352E)
    static let persimmon = Color(hex: 0xFA6B47)
    static let card = Color(hex: 0xFFFDF9)
    static let deep = Color(hex: 0xB23F24)
    static let muted = Color(hex: 0x5F6A62)
    static let hairline = Color(hex: 0x26352E).opacity(0.14)

    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

/// Voice-first: no letter keys. A top strip for status, one big card for the action, and a bottom row with
/// globe, space, delete, and return.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    private var busy: Bool { model.stage == .listening || model.stage == .writing || model.stage == .waiting }

    var body: some View {
        VStack(spacing: 8) {
            topStrip.frame(height: 30)
            card.frame(maxHeight: .infinity)
            if let n = model.notice {
                Text(n).font(.system(size: 12)).foregroundStyle(KB.deep)
                    .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            bottomRow.frame(height: 44)
                .opacity(busy ? 0.4 : 1)
                .disabled(busy)
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
        .background(KB.paper)
    }

    // MARK: Top strip

    @ViewBuilder private var topStrip: some View {
        HStack(spacing: 8) {
            switch model.stage {
            case .listening, .waiting, .writing:
                RingsMark(color: KB.persimmon).frame(width: 15, height: 15)
                Text(stripLabel).font(KB.mono(11)).tracking(1.3).foregroundStyle(KB.ink).lineLimit(1)
                    .accessibilityLabel(stripAccessibility)
                Spacer(minLength: 6)
                Chip(title: "Cancel") { model.cancel() }
                    .accessibilityHint("Stops listening and inserts nothing")
            case .inserted:
                BarsMark(color: KB.persimmon).frame(width: 14, height: 14)
                Text("INSERTED · \(model.insertion?.words ?? 0) \((model.insertion?.words ?? 0) == 1 ? "WORD" : "WORDS")")
                    .font(KB.mono(11)).tracking(1.3).foregroundStyle(KB.ink).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Chip(title: "Undo") { model.undo() }
                    .accessibilityHint("Removes the inserted words")
                if let ins = model.insertion, ins.raw != ins.text, !ins.raw.isEmpty {
                    Chip(title: "Use as spoken") { model.useAsSpoken() }
                        .accessibilityHint("Replaces the cleaned-up words with the words as you said them")
                }
            case .idle:
                BarsMark(color: KB.persimmon).frame(width: 14, height: 14)
                Text(model.levelLabel.uppercased()).font(KB.mono(11)).tracking(1.3).foregroundStyle(KB.ink).lineLimit(1)
                    .accessibilityLabel("Cleanup: \(model.levelLabel)")
                Spacer(minLength: 6)
            }
        }
        .padding(.horizontal, 6)
    }

    private var stripLabel: String {
        switch model.stage {
        case .waiting: return "OPENING VERBATIM"
        case .writing: return "WRITING IT DOWN"
        default: return "LISTENING · \(Self.clock(model.elapsed))"
        }
    }

    private var stripAccessibility: String {
        switch model.stage {
        case .waiting: return "Opening Verbatim"
        case .writing: return "Writing it down"
        default: return "Listening, \(Int(model.elapsed)) seconds"
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    // MARK: Card

    @ViewBuilder private var card: some View {
        switch model.stage {
        case .idle, .inserted:
            Button { model.record() } label: {
                HStack(spacing: 16) {
                    KeyboardRecordButton(size: 64)
                    Text(model.stage == .inserted ? "Tap to keep going" : "Tap to dictate")
                        .font(.system(size: 24, design: .serif)).foregroundStyle(KB.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KB.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KB.hairline))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressFade())
            .accessibilityLabel(model.stage == .inserted ? "Keep dictating" : "Dictate")
            .accessibilityHint("Opens Verbatim to listen. Then come back here.")
        case .waiting, .listening, .writing:
            HStack(spacing: 16) {
                VoiceBars(level: model.stage == .listening ? model.level : 0, color: KB.persimmon, barWidth: 10, maxHeight: 44)
                    .frame(width: 50)
                Text(model.stage == .writing ? "Writing it down…" : model.stage == .waiting ? "Opening Verbatim…" : "Listening…")
                    .font(.system(size: 24, design: .serif)).foregroundStyle(KB.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                if model.stage != .writing {
                    Button { model.done() } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(KB.persimmon).frame(width: 10, height: 10)
                            Text("Done").font(.system(size: 16, weight: .semibold)).foregroundStyle(KB.card)
                        }
                        .padding(.horizontal, 18).frame(height: 44)
                        .background(KB.ink, in: Capsule())
                    }
                    .buttonStyle(PressFade())
                    .disabled(model.stage == .waiting)
                    .opacity(model.stage == .waiting ? 0.5 : 1)
                    .accessibilityLabel("Done")
                    .accessibilityHint("Stops listening and inserts your words")
                } else {
                    ProgressView().tint(KB.ink).accessibilityLabel("Writing it down")
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KB.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KB.persimmon.opacity(0.55)))
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobe {
                GlobeKey(controller: model.controllerForGlobe)
                    .frame(width: 48)
                    .background(KB.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(KB.hairline))
                    .accessibilityLabel("Next keyboard")
            }
            Key(label: { Text("space").font(.system(size: 15)).foregroundStyle(KB.muted) }, action: model.space)
                .accessibilityLabel("Space")
            RepeatKey(action: model.deleteOne) {
                Image(systemName: "delete.left").font(.system(size: 18, weight: .regular)).foregroundStyle(KB.ink)
            }
            .frame(width: 56)
            .accessibilityLabel("Delete")
            Key(label: { Image(systemName: "return").font(.system(size: 18, weight: .regular)).foregroundStyle(KB.ink) }, action: model.newline)
                .frame(width: 72)
                .accessibilityLabel("Return")
        }
    }
}

// MARK: - Pieces

/// The app's record button: a persimmon circle with the Capture glyph in ink (same as the Mac's RecordButton).
struct KeyboardRecordButton: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(KB.persimmon)
            BrandGlyph(art: .capture, color: KB.ink, minLineWidth: 1.2).padding(size * 0.2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct Chip: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 28)
                .background(KB.card, in: Capsule())
                .overlay(Capsule().strokeBorder(KB.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(title)
    }
}

private struct Key<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KB.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(KB.hairline))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressFade())
    }
}

/// Delete: once on touch down, then repeats while held.
private struct RepeatKey<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var pressed = false
    @State private var timer: Timer?

    var body: some View {
        label()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pressed ? KB.hairline : KB.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(KB.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { begin() } }
                .onEnded { _ in end() })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .onDisappear { end() }
    }

    private func begin() {
        pressed = true
        action()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
            Task { @MainActor in
                guard pressed else { return }
                timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in Task { @MainActor in action() } }
            }
        }
    }

    private func end() {
        pressed = false
        timer?.invalidate()
        timer = nil
    }
}

private struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The globe key. A UIKit button so it can hand the touch to `handleInputModeList(from:with:)`, which shows the
/// keyboard list on a long press and moves to the next keyboard on a tap (required for every keyboard).
struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let b = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        b.setImage(UIImage(systemName: "globe", withConfiguration: config), for: .normal)
        b.tintColor = UIColor(red: 0x26 / 255.0, green: 0x35 / 255.0, blue: 0x2E / 255.0, alpha: 1)
        b.accessibilityLabel = "Next keyboard"
        if let controller {
            b.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return b
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
