import SwiftUI
import UIKit

/// Pushed onto the Home stack (the Dictate tile) or the Library stack (the Dictations row) to open the Dictations list.
/// With Dictations in the tab bar, the list is that tab's root too.
struct DictationsRoute: Hashable {}

/// Every dictation, newest first, in the website style: "Dictations · 128 kept", a lede, mono day headers, and flat
/// rows (the app's initial on a neutral square, the app and time, the words, the cleanup level when one was set, and
/// "not pasted" in the accent when the words didn't land). Tap a row, or its round button, to copy the words; the
/// button turns into a check for 1.6 seconds. A butter panel at the end (butter means Dictate) explains the keyboard.
struct DictationsListScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var search = ""
    @ScaledMetric(relativeTo: .body) private var ledeSize: CGFloat = 14

    private var items: [Transcript] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return app.store.memo("phone.dictations|\(q)") {
            app.store.live
                .filter { $0.isDictation && (q.isEmpty || $0.title.lowercased().contains(q) || app.store.searchText($0).contains(q)) }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        let items = self.items
        let keptCount = app.store.memo("phone.dictation-count") { app.store.live.filter(\.isDictation).count }
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.createdAt) }
        let order = days.keys.sorted(by: >)
        List {
            VStack(alignment: .leading, spacing: 6) {
                PhoneCompactTitle(title: "Dictations", count: "\(keptCount) kept")
                Text("Everything you dictated with the Verbose keyboard, with the audio.")
                    .font(.system(size: ledeSize)).foregroundStyle(.lookDim).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if search.isEmpty { IconPlate(art: .iconDictations, size: 96) } else { EmptyStateArt(art: .search, tint: Ink.butterTint) }
                    Text(search.isEmpty ? "No dictations yet." : "Nothing matches “\(search)”.").font(.system(size: 15)).foregroundStyle(.lookDim)
                }
                .padding(.top, 16)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(order, id: \.self) { day in
                PhoneDayHeader(text: PhoneDayHeader.label(day))
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                ForEach(days[day] ?? []) { t in
                    PhoneDictationRow(transcript: t)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .contextMenu {
                            Button { open(t.id) } label: { Label("Open transcript", systemImage: "arrow.right") }
                            RowActions(transcript: t)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { app.delete([t.id]) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { app.togglePin(t.id) } label: { Label(t.pinned ? "Unpin" : "Pin", systemImage: "pin") }.tint(Ink.sageText)   // brand: system surface (swipe action)
                        }
                }
            }
            keyboardPanel
                .padding(.top, 16).padding(.bottom, 24)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .phonePage()
        .navigationTitle("Dictations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find a dictation")
    }

    /// Opens the transcript on whichever stack this list is on.
    private func open(_ id: UUID) { app.pushHere(id) }

    /// The keyboard, explained: butter (Dictate) with grain and the lines drawing. Opens the keyboard's settings.
    private var keyboardPanel: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
        return Button {
            SettingsPage.open("keyboard")
            app.tab = .settings
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                PhoneEyebrow(text: "Keyboard", color: Ink.inkFixed)
                (Text("Dictate into ") + Text("any app.").italic())
                    .lookSerif(21).foregroundStyle(.lookOnPanel)
                Text("Hold the globe key to switch to the Verbose keyboard, then tap the mic.")
                    .font(.system(size: 13.5)).foregroundStyle(.lookOnPanel).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 70)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                PhonePanelFill(color: PhoneInk.butter, shape: shape)
                    .overlay(alignment: .topTrailing) {
                        PhonePanelArt(kind: .lines).frame(width: 150, height: 100).offset(x: 20, y: -6)
                    }
                    .clipShape(shape)
            }
            .contentShape(shape)
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the keyboard's settings.")
    }
}

/// One dictation: the app's initial on a neutral square, the app and time in a sans meta line, the words, and the
/// cleanup level when one was set. Tapping anywhere copies the words; the round button turns into a check for 1.6
/// seconds.
struct PhoneDictationRow: View {
    var transcript: Transcript
    @State private var copied = false
    @State private var copies = 0
    @Environment(\.limitMotion) private var limitMotion
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 15.5
    @ScaledMetric(relativeTo: .caption) private var small: CGFloat = 12.5

    var body: some View {
        Button { copy() } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(Self.initial(app)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.lookDim)
                            .frame(width: 18, height: 18)
                            .background(Ink.neutralChip, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                            .accessibilityHidden(true)
                        Text("\(app) · \(Formats.style(date: .none, time: .short).string(from: transcript.createdAt))")
                            .font(.system(size: small)).monospacedDigit().foregroundStyle(.lookMute).lineLimit(1)
                    }
                    Text(HomeDictationText.body(transcript))
                        .font(.system(size: textSize)).foregroundStyle(transcript.status == .failed ? Ink.danger : Ink.ink)
                        .lineSpacing(4).lineLimit(8)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if Self.statusLine(level: level, notPasted: notPasted) != nil { status.font(.system(size: small)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle().fill(copied ? Ink.ink : Color.clear)
                    Circle().strokeBorder(Ink.ink, lineWidth: 1.3)
                    if copied {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.paper)
                            .transition(.opacity)
                    } else {
                        IconGlyph(art: .iconCopy, size: 15, color: Ink.ink).transition(.opacity)
                    }
                }
                .frame(width: 36, height: 36)
                .animation(limitMotion ? Motion.fade : .easeOut(duration: 0.18), value: copied)
                .accessibilityHidden(true)
            }
            .padding(.vertical, 14).padding(.horizontal, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(.lookHairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(trigger: copies) { _, _ in Haptics.feedback(.copied) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(copied ? "Copied" : "")
        .accessibilityHint("Copies the words.")
    }

    private var app: String {
        let a = transcript.flow?.app.trimmingCharacters(in: .whitespaces) ?? ""
        return a.isEmpty ? "Keyboard" : a
    }

    private var level: String? { transcript.flow.flatMap { CleanupLevel(stored: $0.level)?.title } }
    private var notPasted: Bool { transcript.flow.map { !$0.pastedOK } ?? false }

    /// "Clean · not pasted": the cleanup level when one was set, and a warning in the accent when the words didn't
    /// land. Nothing when neither applies; every row here is a dictation, so it never says so.
    @ViewBuilder private var status: some View {
        HStack(spacing: 0) {
            if let level { Text(level).foregroundStyle(.lookMute) }
            if notPasted {
                if level != nil { Text(" · ").foregroundStyle(.lookMute) }
                Text("not pasted").fontWeight(.semibold).foregroundStyle(.lookAccentText)
            }
        }
    }

    /// The status line's words, or nil to leave the line out (`status` draws them).
    static func statusLine(level: String?, notPasted: Bool) -> String? {
        let parts = [level, notPasted ? "not pasted" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func copy() {
        HomeScreen.copyDictation(HomeDictationText.pasted(transcript))
        copies += 1
        copied = true
        let mine = copies
        UIAccessibility.post(notification: .announcement, argument: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copies == mine { copied = false } }
    }

    /// The app's initial for its neutral square ("M" for Messages, "K" for Keyboard). Apps stay neutral: a hue would
    /// say Record, Dictate, Import, or App audio.
    static func initial(_ app: String) -> String {
        app.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "K"
    }
}
