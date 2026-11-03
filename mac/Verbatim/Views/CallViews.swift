import SwiftUI
import AppKit

// Recording a call before it starts (mockup "Verbose Call Recording", November 3, 2026): the menu bar panel's Calls
// section. App/MeetingCoordinator.swift does the work; nothing here records on its own.

/// The menu bar panel's Calls section (mockup board 5): Record a call, which records a call that's on or waits for
/// one. While a call records, the meeting's own menu bar item takes over and this section steps aside.
struct MenuBarCallsSection: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = MeetingSession.shared

    var body: some View {
        if !session.isActive {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calls").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Refined.mute).padding(.horizontal, 8)
                    .accessibilityAddTraits(.isHeader)
                CallMenuRow(title: "Record a call", detail: "Waits for Zoom, Meet, Teams, or FaceTime",
                            action: "Choose…", strong: false, target: "menu-record-call") {
                    dismiss()
                    MeetingCoordinator.shared.recordCall()
                }
            }
        }
    }
}

/// A row in the menu bar's Calls section: the title and a line under it, then its action.
struct CallMenuRow: View {
    var title: String
    var detail: String
    var action: String
    var strong: Bool
    var target: String
    var run: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Refined.ink).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(Refined.mute).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action, action: run)
                .buttonStyle(RefinedActionStyle(kind: strong ? .strong : .quiet))
                .accessibilityHint(title)
                .uiTarget(target)
        }
        .padding(10)
        .background(Refined.card, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
