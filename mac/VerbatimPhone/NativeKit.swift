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
        if let k = t.kind, k != .dictation { return k.label }
        return HomeRecentStyle(t).source
    }

    /// "9:00 AM" today and yesterday's "Mon" style for older days, as Mail's inbox does.
    static func time(_ t: Transcript, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(t.createdAt, inSameDayAs: now) { return Formats.style(date: .none, time: .short).string(from: t.createdAt) }
        return HomeRecentStyle.day(t.createdAt, now: now)
    }

    /// Home's line under a recording: "Meeting · Today, 9:00 AM" (the length sits on the right).
    static func homeMeta(_ t: Transcript, now: Date) -> String {
        let when = "\(HomeRecentStyle.day(t.createdAt, now: now)), \(Formats.style(date: .none, time: .short).string(from: t.createdAt))"
        switch t.status {
        case .processing: return "\(PhoneRowState.shortStage(t)) · \(when)"
        case .failed: return "Didn't finish · \(when)"
        case .ready: return "\(kind(t)) · \(when)"
        }
    }

    /// The Library's second line: "Meeting · 38:12 · Anika, Marcus", "Thought · 0:48 · Transcribing".
    static func libraryMeta(_ t: Transcript) -> String {
        var parts = [kind(t)]
        if t.duration > 0 { parts.append(HomeRecentStyle.length(t.duration)) }
        switch t.status {
        case .processing: parts.append(PhoneRowState.shortStage(t))
        case .failed: parts.append("Didn't finish")
        case .ready:
            let names = t.speakers.map(\.name).filter { !$0.isEmpty && !$0.hasPrefix("Speaker ") }
            if names.count >= 2 { parts.append(names.prefix(3).joined(separator: ", ")) }
            else if t.speakers.count >= 2 { parts.append("\(t.speakers.count) speakers") }
        }
        return parts.joined(separator: " · ")
    }

    /// "Today · 9:12 AM", and with `length` (an item with nothing to play) its length too, "Today · 2:03 AM · 32:00".
    static func dateLine(_ t: Transcript, now: Date, length: Bool = false) -> String {
        let when = "\(HomeRecentStyle.day(t.createdAt, now: now)) · \(Formats.style(date: .none, time: .short).string(from: t.createdAt))"
        return length && t.status == .ready && t.duration > 0 ? "\(when) · \(HomeRecentStyle.length(t.duration))" : when
    }

    /// The first cleaned lines (or the transcript's first lines); while there are none, nothing (the meta line says
    /// where it is).
    static func preview(_ t: Transcript) -> String {
        guard t.status == .ready else { return "" }
        if let doc = t.document, !doc.isEmpty { return PremiumRules.preview([String(doc.prefix(400))]) }
        return PremiumRules.preview(t.segments.prefix(6).map(\.text))
    }
}

/// One recording on Home, in Voice Memos' rhythm: the title, two lines of what was said, then the kind and time with
/// the length on the right. A row of an inset grouped list; the list draws the chevron and the separator.
struct NativeRecentRow: View {
    var transcript: Transcript
    var now: Date
    /// The live progress (StageClock) while it transcribes: a tick re-renders the row, not the screen.
    @ObservedObject private var stages = StageClock.shared
    private var t: Transcript { stages.applied(to: transcript) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PhoneRowTitle.title(t, withTime: false)).font(.headline).foregroundStyle(NativeInk.label).lineLimit(2)
            let preview = NativeRows.preview(t)
            if !preview.isEmpty {
                Text(preview).font(.subheadline).foregroundStyle(NativeInk.secondary).lineLimit(2)
            }
            HStack(spacing: 5) {
                if t.status == .processing, t.processingDevice == Device.id { ProgressView().controlSize(.mini) }
                if t.pinned { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
                Text(NativeRows.homeMeta(t, now: now)).lineLimit(1)
                    .foregroundStyle(t.status == .failed ? NativeInk.danger : NativeInk.secondary)
                Spacer(minLength: 8)
                if t.status == .ready, t.duration > 0 {
                    Text(HomeRecentStyle.length(t.duration)).monospacedDigit()
                }
            }
            .font(.footnote).foregroundStyle(NativeInk.secondary)
            .padding(.top, 3)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One recording in the Library, like a message in Mail's inbox: the title and time on the first line, the kind,
/// length, and names on the second, and two lines of what was said.
struct NativeLibraryRow: View {
    var transcript: Transcript
    var now: Date
    @ObservedObject private var stages = StageClock.shared
    private var t: Transcript { stages.applied(to: transcript) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if t.pinned { Image(systemName: "pin.fill").font(.footnote).foregroundStyle(NativeInk.secondary).accessibilityLabel("Pinned") }
                Text(PhoneRowTitle.title(t, withTime: false)).font(.headline).foregroundStyle(NativeInk.label).lineLimit(1)
                Spacer(minLength: 8)
                Text(NativeRows.time(t, now: now)).font(.subheadline).monospacedDigit().foregroundStyle(NativeInk.secondary)
            }
            HStack(spacing: 5) {
                if t.status == .processing, t.processingDevice == Device.id { ProgressView().controlSize(.mini) }
                Text(NativeRows.libraryMeta(t)).lineLimit(1)
                    .foregroundStyle(t.status == .failed ? NativeInk.danger : NativeInk.label)
            }
            .font(.subheadline)
            let preview = NativeRows.preview(t)
            if !preview.isEmpty {
                Text(preview).font(.subheadline).foregroundStyle(NativeInk.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
