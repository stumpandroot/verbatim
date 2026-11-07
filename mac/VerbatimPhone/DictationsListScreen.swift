import SwiftUI
import UIKit

/// Pushed onto the Home stack (the Dictate tile) or the Library stack (the Dictations row) to open the Dictations list.
/// With Dictations in the tab bar, the list is that tab's root too.
struct DictationsRoute: Hashable {}

/// Every dictation, newest first, on the refined kit (DESIGN.md §13): the large serif title with
/// "128 kept", a lede, serif day titles, and each day's dictations in a card (the app's initial on a neutral square, the
/// app and time, the words, the cleanup level when one was set, and "not pasted" in the accent when the words didn't
/// land). Tap a row, or its round button, to copy the words; the button turns into a check for 1.6 seconds. A butter
/// card at the end (butter means Dictate) explains the keyboard.
struct DictationsListScreen: View {
    @Environment(PhoneState.self) var app
    @State private var search = ""
    /// The Dictations tab's first screen: the title pins (PinnedTitle.swift). Pushed, it keeps Apple's bar.
    var tabRoot = false

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
                if !tabRoot {
                    LargeSerifTitle(title: "Dictations", count: "\(keptCount) kept")
                        .accessibilityElement(children: .combine)
                }
                Text("Everything you dictated with the Verbose keyboard, with the audio.")
                    .refinedFont(.body).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)
                // On the page, as in Library: a pinned title has no bar to hold a search drawer.
                SystemSearchField(text: $search, prompt: "Find a dictation")
                    .frame(minHeight: 38)
                    .padding(.top, 8)
            }
            .padding(.top, tabRoot ? 4 : 8)
            .modifier(DictationPageRow())
            if items.isEmpty {
                RefinedEmptyState(art: .iconDictations, hue: .butter,
                                  title: search.isEmpty ? "No dictations yet" : "No matches",
                                  message: search.isEmpty ? "Switch to the Verbose keyboard in any app and tap the mic. What you say lands here too."
                                                          : "Nothing matches \u{201C}\(search)\u{201D}.")
                    .padding(.top, 16)
                    .modifier(DictationPageRow())
            }
            ForEach(order, id: \.self) { day in
                SectionTitle(DayLabel.title(day))
                    .padding(.top, 22).padding(.bottom, 8)
                    .modifier(DictationPageRow())
                let list = days[day] ?? []
                ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                    PhoneDictationRow(transcript: t)
                        .overlay(alignment: .top) { if i > 0 { PaperDivider(leading: 44) } }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(PaperRowBackground(first: i == 0, last: i == list.count - 1))
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button { open(t.id) } label: { Label("Open transcript", systemImage: "arrow.right") }   // brand: system surface (menu)
                            RowActions(transcript: t)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { app.delete([t.id]) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { app.togglePin(t.id) } label: { Label(t.pinned ? "Unpin" : "Pin", systemImage: t.pinned ? "pin.slash" : "pin") }   // brand: system surface (swipe action)
                                .tint(Refined.accentFillFixed)   // white on it in dark too (IP-03)
                        }
                }
            }
            keyboardCard
                .padding(.top, 22).padding(.bottom, 24)
                .modifier(DictationPageRow())
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("Dictations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        .pinnedTitle(tabRoot) { TitleRow(title: "Dictations", count: "\(keptCount) kept") { EmptyView() } }
    }

    /// Opens the transcript on whichever stack this list is on.
    private func open(_ id: UUID) { app.pushHere(id) }

    /// The keyboard, explained: a butter card (Dictate) with the keyboard's icon square. Opens the keyboard's settings.
    private var keyboardCard: some View {
        Button {
            app.openSettings(page: "keyboard")
        } label: {
            HStack(alignment: .top, spacing: 14) {
                IconSquare(art: .iconDictations, hue: .butter)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dictate into any app").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text("Hold the globe key to switch to the Verbose keyboard, then tap the mic.")
                        .refinedFont(.hint).foregroundStyle(Refined.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.faint)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(RefinedPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the keyboard's settings.")
    }
}

/// A row of the page outside the cards: the page's margins, no background, no separator.
private struct DictationPageRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// One dictation, a row in its day's card: the app's initial on a neutral square, the app and time in the meta style,
/// the words, and the cleanup level when one was set. As on Home's Recent dictations (IP-07), a tap on the words
/// opens the dictation and only the round button copies (it turns into a check for 1.6 seconds); Copy is in the menu
/// too.
struct PhoneDictationRow: View {
    @Environment(PhoneState.self) var state
    var transcript: Transcript
    @State private var copied = false
    @State private var copies = 0
    @Environment(\.limitMotion) private var limitMotion

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button { state.pushHere(transcript.id) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(Self.initial(app)).scaledFont(13, weight: .semibold).foregroundStyle(Refined.ink)
                        .frame(width: 22, height: 22)
                        .background(Refined.neutralSquare, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(app) · \(Formats.style(date: .none, time: .short).string(from: transcript.createdAt))")
                            .refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute).rowLines()
                        if transcript.status == .failed {
                            // A failure in danger with its glyph, never the accent (IP-10).
                            RefinedFailure(text: HomeDictationText.body(transcript), role: .body, lines: 8)
                        } else {
                            Text(HomeDictationText.body(transcript))
                                .refinedFont(.body).foregroundStyle(Refined.ink)
                                .lineLimit(8)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if Self.statusLine(level: level, notPasted: notPasted) != nil { status.refinedFont(.meta) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10).padding(.leading, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(RefinedRowPress())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the dictation.")
            .accessibilityAddTraits(.isButton)
            copyButton.padding(.top, 6)
        }
        .padding(.trailing, 6)
    }

    /// The round copy button (36 pt in a 44 pt target), the same as Home's.
    private var copyButton: some View {
        Button { copy() } label: {
            ZStack {
                Circle().fill(copied ? Refined.persimmonTint : Refined.neutral)
                if copied {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Refined.accentText)
                        .transition(.opacity)
                } else {
                    IconGlyph(art: .iconCopy, size: 15, color: Refined.ink).transition(.opacity)
                }
            }
            .frame(width: 36, height: 36)
            .frame(width: CGFloat(RefinedRules.minTapTarget), height: CGFloat(RefinedRules.minTapTarget))
            .contentShape(Rectangle())
            .animation(limitMotion ? Motion.fade : Motion.touch, value: copied)
        }
        .buttonStyle(RefinedPress())
        .sensoryFeedback(trigger: copies) { _, _ in Haptics.feedback(.copied) }
        .accessibilityLabel("Copy")
        .accessibilityValue(copied ? "Copied" : "")
        .accessibilityHint("Copies the words.")
        .accessibilityIdentifier("dictations.copy")
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
            if let level { Text(level).foregroundStyle(Refined.mute) }
            if notPasted {
                if level != nil { Text(" · ").foregroundStyle(Refined.mute) }
                Text("not pasted").fontWeight(.semibold).foregroundStyle(Refined.accentText)
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
