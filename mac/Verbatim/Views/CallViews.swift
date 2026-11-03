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
    @ObservedObject private var calendar = CallCalendar.shared

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
                    // The next call from Calendar, when Calls from Calendar is on (App/CallCalendar.swift).
                    if let next = calendar.next() {
                        let when = "\(next.start.formatted(date: .omitted, time: .shortened)) · \(next.service.name) · \(CallSchedule.relative(next.start, now: Date()))"
                        CallMenuRow(title: next.title, detail: when, action: "Record when it starts", strong: true, target: "menu-call-next") {
                            dismiss()
                            coordinator.recordWhenItStarts(next)
                        }
                    }
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
/// persimmon tint, what it's waiting for, and Cancel. Otherwise, with Calls from Calendar on, the next call from 30
/// minutes before it starts until it ends, with Record when it starts and the rest of today's calls; or, once, the
/// first-time card that offers it. It shows only while there's something to show, and it isn't one of Edit Home's
/// sections: like the What's new line, it comes and goes with what's happening.
struct HomeCallCard: View {
    @ObservedObject private var coordinator = MeetingCoordinator.shared
    @ObservedObject private var session = MeetingSession.shared
    @ObservedObject private var calendar = CallCalendar.shared
    /// Home's minute clock, so "in 12 min" moves on.
    var now: Date
    /// The room above the card, only while it shows.
    var top: CGFloat = 16
    @State private var seeAll = false

    var body: some View {
        if !session.isActive {
            if let wait = coordinator.wait {
                waiting(wait).padding(.top, top)
            } else if let next = calendar.next(now: now) {
                nextCall(next, later: calendar.laterToday(now: now)).padding(.top, top)
            } else if calendar.offersCard {
                firstTime.padding(.top, top)
            }
        }
    }

    /// "Next call" (board 1): when, the event's title, its service, people, and length, and Record when it starts; then
    /// "2 more calls today · See all".
    private func nextCall(_ e: CallEvent, later: [CallEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CallCardFace(start: e.start, now: now) {
                Text("Next call").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
                Text(e.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(2)
                Text(e.detail).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
            } actions: {
                Button("Record when it starts") { coordinator.recordWhenItStarts(e) }
                    .buttonStyle(RefinedActionStyle(kind: .strong))
                    .help("Recording starts when \(e.service.name) joins the call: your microphone and the call, as two tracks.")
                    .uiTarget("home-call-record")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Next call, \(e.title), \(e.detail), \(CallSchedule.relative(e.start, now: now))")
            if !later.isEmpty {
                HStack(spacing: 4) {
                    Text(CallSchedule.moreLine(later.count) + " ·").refinedFont(.meta).foregroundStyle(Refined.mute)
                    Button("See all") { seeAll = true }
                        .buttonStyle(.plain)
                        .refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.accentText)
                        .popover(isPresented: $seeAll, arrowEdge: .bottom) { laterList(later) }
                        .uiTarget("home-call-see-all")
                }
                .padding(.leading, 90)
            }
        }
    }

    /// Today's other calls, each with Record when it starts.
    private func laterList(_ later: [CallEvent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Later today").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute).padding(.bottom, 6)
            ForEach(later) { e in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink).lineLimit(1)
                        Text("\(e.start.formatted(date: .omitted, time: .shortened)) · \(e.detail)").refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Button("Record when it starts") { seeAll = false; coordinator.recordWhenItStarts(e) }
                        .buttonStyle(RefinedActionStyle())
                }
                .padding(.vertical, 6)
                if e.id != later.last?.id { PaperDivider(leading: 0, trailing: 0) }
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    /// The first-time card (board 4): what Verbose reads and why, Not now, and Show my calls, which asks macOS for
    /// access. Shown once, until you choose.
    private var firstTime: some View {
        CallCardFace(start: nil, now: now) {
            Text("Calls from your calendar").refinedFont(.meta, weight: .semibold).foregroundStyle(Refined.mute)
            Text("See your next call here and record it in one click").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(CallCopy.calendarPromise).refinedFont(.meta).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Not now") { calendar.markCardDone() }
                .buttonStyle(.plain)
                .refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText)
                .padding(.horizontal, 4)
                .help("Settings › Meetings › Calls from Calendar turns it on later.")
                .uiTarget("home-call-not-now")
            Button("Show my calls") { Task { await calendar.turnOn() } }
                .buttonStyle(RefinedActionStyle(kind: .strong))
                .uiTarget("home-call-show")
        }
        .accessibilityElement(children: .contain)
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

/// The words for calls from Calendar, in one place for Home's card and Settings.
enum CallCopy {
    static let calendarPromise = "Verbose reads events with a Zoom, Meet, Teams, Webex, or FaceTime link on this Mac, and uses their titles and attendees to name recordings. Nothing is uploaded."
    static let calendarDenied = "Calendar access is off. Turn it on in System Settings › Privacy & Security › Calendars."
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
