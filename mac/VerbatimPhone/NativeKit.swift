// brand: native file
import SwiftUI
import UIKit

// The iPhone's Native look, redrawn the way Apple draws its own apps (DESIGN.md §13.3; mockup "Verbose Native
// Redesign", October 27, 2026): system lists, cells, and fills, SF Pro with monospaced digits for numbers, system glass
// only where Apple puts it (the tab bar and its accessory, toolbars, menus, and the player bar), and no gradient cards,
// glows, tinted icon circles, or custom shadows. Premium Native's floating record disc retired: Record lives in the
// tab bar's bottom accessory (RecordAccessory.swift).
//
// Performance: nothing here builds a color in `body`, and nothing enters with an animation. This file is Native look
// code (`// brand: native file`).

// MARK: - Styles

enum NativeStyle {
    /// Big numbers: SF Pro bold with monospaced digits, never SF Pro Rounded heavy.
    static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

extension View {
    /// System glass for the player bar and a few small floating controls (DESIGN.md §13.5): Liquid Glass on iOS 26,
    /// a material before it. Reduce Transparency makes both solid.
    @ViewBuilder func nativeGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// An inset grouped cell drawn outside a `List`: the secondary grouped background with the system's corner, no
    /// shadow and no outline.
    func nativeCell(radius: CGFloat = NativeMetrics.groupRadius) -> some View {
        background(NativeInk.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Headers

/// A section header in a Native list: the title in the system's bold title style (as Music and Settings' large
/// sections), with an optional accent link on the right ("See all").
struct NativeListHeader: View {
    var title: String
    var action: String? = nil
    var onAction: () -> Void = {}
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold()).foregroundStyle(NativeInk.label)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let action {
                Button(action, action: onAction).font(.body).foregroundStyle(NativeInk.accent).buttonStyle(.borderless)
            }
        }
        .textCase(nil)
        .padding(.top, 6)
    }
}

// MARK: - Recording rows

/// What every Native recording row says, worked out once: the kind ("Meeting", "Voice note", "YouTube"), the time,
/// the length, the names, and two lines of what was said.
enum NativeRows {
    /// "Meeting", "Thought", "Voice note", "YouTube": the kind when it has one, else what it is.
    static func kind(_ t: Transcript) -> String {
        // Audio only reads "Audio · 1:12 · 2 moments", in the rhythm of the other rows.
        if t.kind == .audio { return "Audio" }
        if let k = t.kind, k != .dictation { return k.label }
        return HomeRecentStyle(t).source
    }

    /// "Today · 9:12 AM", and with `length` (an item with nothing to play) its length too, "Today · 2:03 AM · 32:00".
    static func dateLine(_ t: Transcript, now: Date, length: Bool = false) -> String {
        let when = "\(HomeRecentStyle.day(t.createdAt, now: now)) · \(Formats.style(date: .none, time: .short).string(from: t.createdAt))"
        return length && t.status == .ready && t.duration > 0 ? "\(when) · \(HomeRecentStyle.length(t.duration))" : when
    }
}
