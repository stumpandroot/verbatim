import SwiftUI
import AppKit

// Recording a call before it starts (mockup "Verbose Call Recording", November 3, 2026): the menu bar panel's Calls
// section. App/MeetingCoordinator.swift does the work; nothing here records on its own.

/// The menu bar panel's Calls section (mockup board 5): while waiting, Waiting for your call with Cancel; otherwise
/// Record a call, which records a call that's on or waits for one. While a call records, the meeting's own menu bar
/// item takes over and this section steps aside.
struct MenuBarCallsSection: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = MeetingSession.shared
    @ObservedObject private var coordinator = MeetingCoordinator.shared

    var body: some View {
        if !session.isActive {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calls").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Refined.mute).padding(.horizontal, 8)
                    .accessibilityAddTraits(.isHeader)
                if let wait = coordinator.wait {
                    CallMenuRow(title: "Waiting for your call", detail: wait.title.map { "\($0) · \(wait.appName)" } ?? wait.startsLine,
                                action: "Cancel", strong: false, target: "menu-cancel-wait") {
                        coordinator.cancelWait()
                    }
                } else {
                    CallMenuRow(title: "Record a call", detail: "Waits for Zoom, Meet, Teams, or FaceTime",
                                action: "Choose…", strong: false, target: "menu-record-call") {
                        dismiss()
                        coordinator.recordCall()
                    }
                }
            }
        }
    }
}

/// Home's call card, under the greeting (mockup boards 1, 2, and 4). While waiting: "Waiting for your call" on the
/// persimmon tint, what it's waiting for, and Cancel. It shows only while there's something to show, and it isn't one
/// of Edit Home's sections: like the What's new line, it comes and goes with what's happening.
struct HomeCallCard: View {
    @ObservedObject private var coordinator = MeetingCoordinator.shared
    @ObservedObject private var session = MeetingSession.shared
    /// Home's minute clock, so "in 12 min" moves on.
    var now: Date
    /// The room above the card, only while it shows.
    var top: CGFloat = 16

    var body: some View {
        if !session.isActive, let wait = coordinator.wait {
            waiting(wait).padding(.top, top)
        }
    }

    private func waiting(_ wait: CallWait) -> some View {
        let notice = wait.copyNotice ? " The chat notice copies when it starts." : ""
        return CallCardFace(start: wait.start, now: now, tinted: true) {
            HStack(spacing: 6) {
                Circle().strokeBorder(Refined.accentText, lineWidth: 2)
                    .overlay(Circle().fill(Refined.accentText).padding(3))
                    .frame(width: 12, height: 12).accessibilityHidden(true)
                Text("Waiting for your call").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.accentText)
            }
            Text(wait.title ?? "Your next call").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(2)
            Text(wait.startsLine + notice).refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Cancel") { coordinator.cancelWait() }
                .buttonStyle(RefinedActionStyle())
                .help("Stop waiting. Nothing records.")
                .uiTarget("home-call-cancel")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for your call. \(wait.title ?? "") \(wait.startsLine)")
        .uiTarget("home-call-waiting")
    }
}

/// The call card's face: the start time and how soon (when there is one) beside a hairline, the words, then the
/// actions, on the card or the persimmon tint.
struct CallCardFace<Words: View, Actions: View>: View {
    var start: Date?
    var now: Date
    var tinted = false
    @ViewBuilder var words: () -> Words
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let start {
                VStack(spacing: 1) {
                    Text(start.formatted(date: .omitted, time: .shortened)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Refined.ink).lineLimit(1).fixedSize()
                    Text(CallSchedule.relative(start, now: now)).refinedFont(.caption).foregroundStyle(Refined.mute).lineLimit(1).fixedSize()
                }
                .frame(minWidth: 62)
                Rectangle().fill(Refined.separator).frame(width: 1).frame(maxHeight: 44).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) { words() }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) { actions() }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(tinted ? Refined.persimmonTint : Refined.card, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
    }
}

/// The menu bar mark while a wait is set up: the bars with a dot at the top right, as a template image the menu bar
/// tints, so it shows from any app that a call is set up (mockup board 2).
enum CallMenuBarMark {
    @MainActor static func armed() -> NSImage {
        if let i = cached { return i }
        let base = BrandArt.markBars.templateImage(size: 16, key: "menubar")
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { r in
            base.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.maxX - 6, y: r.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Verbose, waiting for your call"
        cached = img
        return img
    }
    @MainActor private static var cached: NSImage?
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
