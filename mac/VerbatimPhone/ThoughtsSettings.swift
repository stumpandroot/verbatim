import SwiftUI
import UIKit
import WidgetKit

// Settings › Features › Thoughts (approved mockup "Thoughts", section 08): the Ways in drawing, which plays once each
// time the page opens and stays still with Limit animation or Reduce Motion; the ways in, each with whether it's set
// up where Verbose can tell (widgets and the control) and Set up where it can't (the Action button and Back Tap);
// steps for the Action button and Back Tap, since no app can assign them; Siri's phrase; and Record without opening
// Verbose, Show words in the Dynamic Island, and New page each day at. The settings stay on this iPhone: settings
// don't sync with the Mac, which keeps its own New page each day at.

struct ThoughtsSettingsScreen: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.openURL) private var openURL
    @AppStorage(ThoughtRules.inPlaceKey) private var inPlace = true
    @AppStorage(ThoughtRules.islandWordsKey) private var islandWords = true
    @AppStorage(DayPages.newPageHourKey) private var newPageHour = 0
    @State private var widgets: Int? = nil
    @State private var control: Bool? = nil
    @Environment(\.look) private var look

    /// For the self-test: the page is on screen, and its rows' values once read.
    static var visible = false
    static var values: [String: String] = [:]

    private let actionSteps = [
        "Open the Settings app, then tap Action Button.",
        "Swipe to Controls, then tap Choose a Control.",
        "Search for Verbose, then choose New thought.",
    ]
    private let backTapSteps = [
        "Tap Open Shortcuts, then add a shortcut with Verbose's New thought action.",
        "In the Settings app, go to Accessibility › Touch › Back Tap.",
        "Choose Double Tap or Triple Tap, then choose New thought under Shortcuts.",
    ]

    var body: some View {
        SettingsPageScaffold(title: "Thoughts") {
            VStack(alignment: .leading, spacing: 12) {
                WaysInArt(play: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .padding(.top, 8)
                Text("Start a thought from anywhere. Each one is added, with its time, to today's page.")
                    .font(.system(size: 15)).foregroundStyle(.lookDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)

            SettingsPageGroup(title: "Ways in") {
                wayRow(icon: "square.grid.2x2", art: .iconWidgets, title: "Widgets", subtitle: "Home Screen and Lock Screen",
                       value: widgets.map(ThoughtRules.widgetStatus) ?? "…")
                    .settingsSearchTarget("thoughtsWaysIn", flash: nil)
                SettingsDivider()
                wayRow(icon: "switch.2", art: .iconThought, title: "Control Center", subtitle: "The New thought control",
                       value: controlValue)
                SettingsDivider()
                wayRow(icon: "button.horizontal.top.press", art: .iconActionButton, title: "Action button", subtitle: "Steps below",
                       value: ThoughtRules.undetectable)
                SettingsDivider()
                wayRow(icon: "hand.tap", art: .iconBackTap, title: "Back Tap", subtitle: "Through Shortcuts",
                       value: ThoughtRules.undetectable)
                SettingsDivider()
                wayRow(icon: "waveform", art: .iconSpeak, title: "Siri", subtitle: "\u{201C}\(ThoughtRules.siriPhrase)\u{201D}",
                       value: ThoughtRules.siriStatus)
            }

            StepCard(art: .iconActionButton, icon: "button.horizontal.top.press", title: ("Action", "button"), steps: actionSteps) {
                pill("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
            }
            .padding(.top, 22)
            StepCard(art: .iconBackTap, icon: "hand.tap", title: ("Back", "Tap"), steps: backTapSteps) {
                HStack(spacing: 10) {
                    pill("Open Shortcuts") { if let u = URL(string: "shortcuts://") { openURL(u) } }
                    Text("Then come back here.").font(.system(size: 13)).foregroundStyle(.lookMute)
                }
            }
            .padding(.top, 12)
            SiriCard().padding(.top, 12)

            SettingsPageGroup(title: "Recording", footer: "These stay on this iPhone; your Mac has its own New page each day at. A thought belongs to the day it started.") {
                SettingsToggleRow(title: "Record without opening Verbose",
                                  subtitle: "Shows a Live Activity while you talk.", isOn: $inPlace)
                    .settingsSearchTarget("thoughtsInPlace", flash: nil)
                SettingsDivider()
                SettingsToggleRow(title: "Show words in the Dynamic Island",
                                  subtitle: "Never on the Lock Screen.", isOn: $islandWords)
                    .settingsSearchTarget("thoughtsIslandWords", flash: nil)
                SettingsDivider()
                HStack(spacing: 10) {
                    SettingsLabel(hue: .sage, art: .iconCalendar, title: "New page each day at")
                    Spacer(minLength: 8)
                    Picker("New page each day at", selection: $newPageHour) {
                        ForEach(DayPages.hours, id: \.self) { h in Text(DayPages.hourLabel(h)).tag(h) }
                    }
                    .labelsHidden()
                    .tint(look.isNative ? NativeInk.accent : Ink.accentText)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(minHeight: 50)
                .settingsSearchTarget("thoughtsNewPage", flash: nil)
            }
        }
        .onAppear {
            Self.visible = true
            refresh()
        }
        .onDisappear { Self.visible = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var controlValue: String {
        if #available(iOS 18.0, *) { return control.map { ThoughtRules.controlStatus($0) } ?? "…" }
        return ThoughtRules.controlStatus(nil)
    }

    /// Reads which thought widgets and controls are added (coming back from the Settings or Shortcuts app too).
    private func refresh() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            let n = (try? result.get())?.filter { ThoughtRules.widgetKinds.contains($0.kind) }.count ?? 0
            DispatchQueue.main.async {
                widgets = n
                Self.values["widgets"] = ThoughtRules.widgetStatus(n)
            }
        }
        if #available(iOS 18.0, *) {
            Task { @MainActor in
                let infos = (try? await ControlCenter.shared.currentControls()) ?? []
                control = infos.contains { $0.kind == ThoughtRules.controlKind }
                Self.values["control"] = controlValue
            }
        } else {
            Self.values["control"] = controlValue
        }
        Self.values["siri"] = ThoughtRules.siriStatus
    }

    private func wayRow(icon: String, art: BrandArt, title: String, subtitle: String, value: String) -> some View {
        SettingsRow(hue: .sage, art: art, title: title, subtitle: subtitle) { SettingsValue(value) }
            .accessibilityElement(children: .combine)
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(look.isNative ? Color.white : Ink.paper)
                .padding(.horizontal, 16).frame(height: 36)
                .background(Capsule().fill(look.isNative ? NativeInk.accent : Ink.ink))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A how-to card: the icon, the serif title with its last word in italic (one upright run in Native), numbered
/// steps, and its buttons.
private struct StepCard<Footer: View>: View {
    var art: BrandArt
    var icon: String
    var title: (String, String)
    var steps: [String]
    @ViewBuilder var footer: () -> Footer
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SettingsLabel(hue: .sage, art: art, title: "")
                    .fixedSize()
                SerifTitle(title.0, italic: title.1, size: 20).foregroundStyle(.lookInk)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(i + 1).").lookMono(15, weight: .medium).foregroundStyle(.lookMute)
                    Text(step).font(.system(size: 15.5)).foregroundStyle(.lookInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            footer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.row, fill: look.isNative ? NativeInk.card : Ink.card)
    }
}

/// Siri: the phrase, with no setup.
private struct SiriCard: View {
    @Environment(\.look) private var look
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SettingsLabel(hue: .sage, art: .iconSpeak, title: "").fixedSize()
                Text("Siri").font(look.isNative ? .system(size: 20, weight: .semibold) : Ink.serif(20)).foregroundStyle(.lookInk)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("Say this, with no setup:").font(.system(size: 15)).foregroundStyle(.lookDim)
            Text("\u{201C}\(ThoughtRules.siriPhrase)\u{201D}")
                .font(look.isNative ? .system(size: 19, weight: .semibold) : Ink.serif(21)).foregroundStyle(.lookInk)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.row, fill: look.isNative ? NativeInk.card : Ink.card)
        .accessibilityElement(children: .combine)
    }
}
