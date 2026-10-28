import SwiftUI
import AppKit

// brand: native file
//
// The Native look's kit on the Mac (DESIGN.md §13.2; approved mockup "Verbose Native Redesign", October 27, 2026,
// sections 8 to 11). Apple took brand color out of its own apps' chrome in macOS 27, and Native follows: system
// surfaces (the window background, grouped sections, system separators and fills), SF Pro and SF Symbols, the system
// accent color for everything you click, and system red only for recording. No glows, gradient cards, tinted icon
// circles, custom shadows, or SF Pro Rounded numbers. The file keeps its name from Premium Native, which it replaces.

// MARK: - Colors

extension PremiumInk {
    /// The window: the system's window background (`NativeRole.window`, paper under Native, resolves to it too).
    static let window = Color(nsColor: .windowBackgroundColor)
    /// Content: tables, text views, and grouped sections in light.
    static let card = Color(nsColor: .controlBackgroundColor)
    /// Tinted text (links, "Cleaned", moment times): the system accent color, never persimmon.
    static let accentText = Color.accentColor
    /// Fills for tracks, chips, and fields.
    static let fill = Color.primary.opacity(0.07)
    static let fillStrong = Color.primary.opacity(0.12)
    static let separator = Color(nsColor: .separatorColor)
}

// MARK: - Grouped sections

/// A grouped section as System Settings and the grouped `Form` draw one: an optional bold header with a link on the
/// right (Home's "See all"), then the rows on the section's background with inset separators. No shadow, no outline
/// color, no gradient.
struct NativeSection<Content: View>: View {
    var title: String? = nil
    var link: String? = nil
    var linkHint: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || link != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader) }
                    Spacer(minLength: 8)
                    if let link, let action {
                        Button(link, action: action)
                            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(NativeInk.accent)
                            .accessibilityHint(linkHint ?? "")
                    }
                }
                .padding(.horizontal, 10)
            }
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .nativeGroup()
        }
    }
}

/// The hairline between two rows of a grouped section, inset past the row's symbol.
struct NativeRowSeparator: View {
    var leading: CGFloat = 12
    var body: some View {
        Rectangle().fill(NativeInk.separator).frame(height: 0.5).padding(.leading, leading)
    }
}

/// A row's press and hover: the system's faint wash, flat, with no tilt or lift.
struct NativeRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.08 : (hover ? 0.035 : 0)))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

// MARK: - Summary

/// A transcript's summary as plain text, the way the inspector lists everything else: the overview, the key points,
/// and "Made by Apple Intelligence" in secondary. `onEdit` and `onRegenerate` add a ⋯ menu beside the heading.
struct NativeSummaryText: View {
    var summary: TranscriptSummary
    var byModel: Bool
    var compact = false
    var heading = true
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if heading {
                HStack(spacing: 6) {
                    Text("Summary").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if onEdit != nil || onRegenerate != nil {
                        Menu {
                            if let onEdit { Button("Edit Summary", action: onEdit) }
                            if let onRegenerate { Button("Regenerate", action: onRegenerate) }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(width: 22, height: 18).contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Summary options")
                    }
                }
            }
            if !summary.overview.isEmpty {
                Text(summary.overview).font(.system(size: compact ? 13 : 13.5)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.top, heading ? 6 : 0)
            }
            if !summary.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.keyPoints.prefix(compact ? 3 : 6).enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•").font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(p).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Key points")
            }
            if byModel {
                Text(AIGeneratedNote.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

