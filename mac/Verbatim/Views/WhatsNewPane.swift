import SwiftUI

// What's new on the Mac: Settings › What's new (also Verbose › What's New… in the app menu, the What's New… buttons in
// About and Support and feedback › Updates, and Home's note after an update). Every build's notes, newest first, from
// the bundled ReleaseNotes.json (Model/ReleaseNotes.swift), grouped under version headers ("Version 1.0 beta"): the
// newest version open, older ones closed until clicked. The refined look (DESIGN.md §13): the
// pane's square and serif title, then a card per build with its build line ("Build 203 · Oct 25") in `mute`, its
// title in the serif, and its items under platform labels. The Mac's items lead, the iPhone and Apple Watch ones fold
// under one "Also on iPhone and Apple Watch" row, and a line with a detail opens it in place, without movement
// (`ReleaseNotes.summary`).

struct WhatsNewSettingsPane: View {
    var notes: [ReleaseNote] = ReleaseNotes.bundled
    /// Versions clicked open or closed; the newest starts open and the rest closed.
    @State private var toggled: Set<String> = []
    /// What the UI self-test's last `ReleaseNotes.showForTest` opened: a line's detail, and the "Also on" row.
    static var shownForTest = (detail: false, also: false)

    var body: some View {
        let versions = ReleaseNotes.byVersion(notes)
        let shown = versions.first?.notes ?? []
        // The self-test opens the first line with a detail and the first "Also on" row in the newest version.
        let detailTarget = shown.first { n in ReleaseNotes.summary(n.items, for: .mac).sections.contains { $0.items.contains { $0.detail != nil } } }?.id
        let alsoTarget = shown.first { !ReleaseNotes.summary($0.items, for: .mac).also.isEmpty }?.id
        SettingsPane(tab: .whatsNew) {
            VStack(alignment: .leading, spacing: 22) {
                if notes.isEmpty {
                    Text("The release notes aren't in this build.").font(.system(size: 13)).foregroundStyle(Refined.mute)
                }
                ForEach(Array(versions.enumerated()), id: \.element.id) { i, version in
                    let open = (i == 0) != toggled.contains(version.id)
                    WhatsNewVersionHeader(version: version, open: open) {
                        if toggled.contains(version.id) { toggled.remove(version.id) } else { toggled.insert(version.id) }
                    }
                    if open {
                        ForEach(version.notes) { WhatsNewCard(note: $0, newest: i == 0 && $0.id == version.notes.first?.id, detailTarget: $0.id == detailTarget, alsoTarget: $0.id == alsoTarget) }
                    }
                }
            }
            .settingsAnchor("whatsNew.builds")
        }
        // Opening What's new counts as seeing this build's note on Home.
        .onAppear { ReleaseNotes.markSeen() }
    }
}

/// A version's header: a chevron, "Version 1.0 beta", and how many builds. Clicking it shows or hides the builds.
struct WhatsNewVersionHeader: View {
    var version: ReleaseVersion
    var open: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Refined.mute)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                Text(version.heading)
                    .font(Refined.serif(22))
                    .foregroundStyle(Refined.ink)
                Text("\(version.notes.count) build\(version.notes.count == 1 ? "" : "s")")
                    .font(.system(size: 12.5)).foregroundStyle(Refined.mute)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(version.spokenHeading)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityAddTraits([.isButton, .isHeader])
        .help(open ? "Hide this version's builds" : "Show this version's builds")
    }
}

/// One build: a card with its build line, its title in the serif, and its items, each beside its icon in a colored
/// square (WhatsNewSheet.swift). The newest build's card leads with the persimmon hero instead of the build line.
struct WhatsNewCard: View {
    var note: ReleaseNote
    var newest = false
    /// The UI self-test opens this card's first detail, or its "Also on" row (`ReleaseNotes.showForTest`).
    var detailTarget = false
    var alsoTarget = false
    /// Lines whose detail is open, by index within their part ("mac", "also-iphone").
    @State private var detailsOpen: Set<String> = []
    @State private var alsoOpen = false

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if newest {
                    VStack(alignment: .leading, spacing: 0) {
                        WhatsNewHero(eyebrow: note.heading, title: note.title, compact: true)
                            .accessibilityLabel(note.spokenHeading + ", " + note.title)
                        content(title: false)
                            .padding(.horizontal, 20).padding(.vertical, 16)
                    }
                    .settingsCard()
                    .clipShape(RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(note.heading).font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.mute)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(note.spokenHeading)
                        content(title: true)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .settingsCard()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ReleaseNotes.showForTest)) { n in
                showForTest(n.object as? String, proxy: proxy)
            }
        }
    }

    private func content(title: Bool) -> some View {
        let sum = ReleaseNotes.summary(note.items, for: .mac)
        let starts = sum.sections.indices.map { k in sum.sections[..<k].reduce(0) { $0 + $1.items.count } }
        let ownCount = sum.sections.reduce(0) { $0 + $1.items.count }
        return VStack(alignment: .leading, spacing: newest ? 12 : 9) {
            if title {
                Text(note.title)
                    .font(Refined.serif(20))
                    .foregroundStyle(Refined.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(sum.sections.enumerated()), id: \.element.id) { k, section in
                if sum.sections.count > 1 { platformLabel(section.title).padding(.top, k == 0 ? 0 : 6) }
                lines(section.items, part: section.id, start: starts[k])
            }
            if !sum.also.isEmpty {
                alsoRow(title: sum.alsoTitle, count: sum.alsoCount)
                    .padding(.top, sum.sections.isEmpty ? 0 : 4)
                    .id("\(note.id)|also")
                if alsoOpen {
                    ForEach(sum.also) { section in
                        if sum.also.count > 1 { platformLabel(section.title) }
                        lines(section.items, part: "also-" + section.id, start: ownCount)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }

    /// A platform's label, semibold. A header for VoiceOver.
    private func platformLabel(_ title: String) -> some View {
        return Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Refined.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    /// "Also on iPhone and Apple Watch" and how many items fold under it: click to show or hide them.
    private func alsoRow(title: String, count: Int) -> some View {
        return Button { alsoOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(alsoOpen ? 90 : 0))
                    .frame(width: 10)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(count)").font(.system(size: 13)).monospacedDigit()
                Spacer(minLength: 0)
            }
            .foregroundStyle(Refined.dim)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) item\(count == 1 ? "" : "s")")
        .accessibilityValue(alsoOpen ? "Expanded" : "Collapsed")
        .accessibilityHint(alsoOpen ? "Shows less" : "Shows more")
        .accessibilityAddTraits(.isButton)
        .help(alsoOpen ? "Hide these changes" : "Show the changes for your other devices")
    }

    private func lines(_ items: [ReleaseItem], part: String, start: Int) -> some View {
        return VStack(alignment: .leading, spacing: newest ? 12 : 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                line(item, key: "\(part)|\(i)", hue: WhatsNewLook.hue(start + i))
            }
        }
    }

    /// One change: its icon, headline, and text (`WhatsNewItemRow`, smaller in older builds). With a detail, the row
    /// is a button with a disclosure chevron that opens the detail under the text, without movement.
    @ViewBuilder
    private func line(_ item: ReleaseItem, key: String, hue: RefinedHue) -> some View {
        let square: CGFloat? = newest ? nil : 26
        let h = ReleaseNotes.headline(item)
        let spoken = (h.head.map { $0 + ". " } ?? "") + h.text
        if let detail = item.detail {
            let open = detailsOpen.contains(key)
            Button {
                if open { detailsOpen.remove(key) } else { detailsOpen.insert(key) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    WhatsNewItemRow(item: item, hue: hue, square: square, showDetail: open)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Refined.mute)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .padding(.top, newest ? 9 : 6)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(open ? spoken + " " + detail : spoken)
            .accessibilityHint(open ? "Shows less" : "Shows more")
            .accessibilityAddTraits(.isButton)
            .help(open ? "Show less" : "Show more")
            .id("\(note.id)|\(key)")
        } else {
            WhatsNewItemRow(item: item, hue: hue, square: square)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    /// The UI self-test's screenshots: "detail" opens this card's first line with a detail, "also" its "Also on" row,
    /// when the pane chose this card for it, and scrolls to it.
    private func showForTest(_ what: String?, proxy: ScrollViewProxy) {
        let sum = ReleaseNotes.summary(note.items, for: .mac)
        if what == "detail", detailTarget,
           let section = sum.sections.first(where: { $0.items.contains { $0.detail != nil } }),
           let i = section.items.firstIndex(where: { $0.detail != nil }) {
            let key = "\(section.id)|\(i)"
            detailsOpen.insert(key)
            WhatsNewSettingsPane.shownForTest.detail = true
            DispatchQueue.main.async { proxy.scrollTo("\(note.id)|\(key)", anchor: .center) }
        } else if what == "also", alsoTarget, !sum.also.isEmpty {
            alsoOpen = true
            WhatsNewSettingsPane.shownForTest.also = true
            DispatchQueue.main.async { proxy.scrollTo("\(note.id)|also", anchor: .top) }
        }
    }
}

/// Home's one-time note after an update: "What's new in build 205 · Version notes". Click it to open What's new; the
/// close button hides it. Either way it doesn't come back until a newer build with notes. Never a modal or a sheet.
struct WhatsNewHomeLine: View {
    /// Space above the line, only while it shows.
    var top: CGFloat = 0
    var notes: [ReleaseNote] = ReleaseNotes.bundled
    var open: () -> Void
    @AppStorage(ReleaseNotes.lastSeenKey) private var lastSeen = 0
    @Environment(\.limitMotion) private var limitMotion
    /// The UI self-test shows the note for a build of its choosing.
    static var previewBuild: Int? = nil
    /// The UI self-test asks Home to check for the What's new sheet again, or, with false, closes it as Continue does.
    static let popupForTest = Notification.Name("whatsNew.popupForTest")

    var body: some View {
        if let note = ReleaseNotes.pending(current: Self.previewBuild ?? ReleaseNotes.currentBuild, lastSeen: lastSeen, notes: notes),
           let number = note.number {
            HStack(spacing: 0) {
                Button {
                    lastSeen = max(lastSeen, number)
                    open()
                } label: {
                    HStack(spacing: 10) {
                        ArtIcon(art: .iconNotes, size: 16, lineWidth: 1.4).foregroundStyle(Refined.ink)
                        (Text("What's new in build \(number)").fontWeight(.semibold) + Text("  ·  " + note.title).foregroundStyle(Refined.dim))
                            .font(.system(size: 13)).foregroundStyle(Refined.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text("Read more").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Refined.accentText)
                    }
                    .padding(.leading, 14).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What's new in build \(number): \(note.title)")
                .accessibilityHint("Opens What's new in Settings")
                // The line fades and slides 6 pt as it goes, and Home closes the space smoothly (DESIGN.md §7).
                Button { withAnimation(Motion.cardAnimation(limited: limitMotion)) { lastSeen = max(lastSeen, number) } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Refined.mute)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide this note")
                .accessibilityLabel("Close")
                .padding(.trailing, 6)
            }
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            .padding(.top, top)
            .transition(Motion.cardTransition(limited: limitMotion))
        }
    }
}

/// "What's New…" in the app menu, under About: opens Settings › What's new.
struct WhatsNewMenuButton: View {
    var open: () -> Void
    var body: some View {
        Button("What's New…", action: open)
    }
}
