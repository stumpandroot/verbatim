import SwiftUI

// What's new on the Mac: Settings › What's new (also Verbose › What's New… in the app menu, the What's New… buttons in
// About and Support and feedback › Updates, and Home's note after an update). Every build's notes, newest first, from
// the bundled ReleaseNotes.json (Model/ReleaseNotes.swift), grouped under version headers ("Version 1.0 beta"): the
// newest version open, older ones closed until clicked. The refined look (DESIGN.md §13), in both look settings: the
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
                        ForEach(version.notes) { WhatsNewCard(note: $0, detailTarget: $0.id == detailTarget, alsoTarget: $0.id == alsoTarget) }
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
                    .font(.system(size: 22, design: .serif))
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

/// One build: a card with its build line, its title in the serif, and its items.
struct WhatsNewCard: View {
    var note: ReleaseNote
    /// The UI self-test opens this card's first detail, or its "Also on" row (`ReleaseNotes.showForTest`).
    var detailTarget = false
    var alsoTarget = false
    /// Lines whose detail is open, by index within their part ("mac", "also-iphone").
    @State private var detailsOpen: Set<String> = []
    @State private var alsoOpen = false

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                Text(note.heading).font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.mute)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(note.spokenHeading)
                content
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard()
            .onReceive(NotificationCenter.default.publisher(for: ReleaseNotes.showForTest)) { n in
                showForTest(n.object as? String, proxy: proxy)
            }
        }
    }

    private var content: some View {
        let sum = ReleaseNotes.summary(note.items, for: .mac)
        return VStack(alignment: .leading, spacing: 8) {
            Text(note.title)
                .font(.system(size: 20, design: .serif))
                .foregroundStyle(Refined.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(sum.sections.enumerated()), id: \.element.id) { k, section in
                platformLabel(section.title).padding(.top, k == 0 ? 0 : 6)
                lines(section.items, part: section.id)
            }
            if !sum.also.isEmpty {
                alsoRow(title: sum.alsoTitle, count: sum.alsoCount)
                    .padding(.top, sum.sections.isEmpty ? 0 : 4)
                    .id("\(note.id)|also")
                if alsoOpen {
                    ForEach(sum.also) { section in
                        if sum.also.count > 1 { platformLabel(section.title) }
                        lines(section.items, part: "also-" + section.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }

    /// A platform's label: the serif in Verbose style, a plain semibold label in Native. A header for VoiceOver.
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

    private func lines(_ items: [ReleaseItem], part: String) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                line(item, key: "\(part)|\(i)")
            }
        }
    }

    /// One line: a bullet and the text. With a detail, the line is a button with a disclosure triangle that opens the
    /// detail under it, without movement.
    @ViewBuilder
    private func line(_ item: ReleaseItem, key: String) -> some View {
        if let detail = item.detail {
            let open = detailsOpen.contains(key)
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    if open { detailsOpen.remove(key) } else { detailsOpen.insert(key) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Refined.mute).accessibilityHidden(true)
                        Text(item.text).foregroundStyle(Refined.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Refined.mute)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.text)
                .accessibilityHint(open ? "Shows less" : "Shows more")
                .accessibilityAddTraits(.isButton)
                .help(open ? "Show less" : "Show more")
                if open {
                    Text(detail).font(.system(size: 13)).foregroundStyle(Refined.dim)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.leading, 16)
                }
            }
            .id("\(note.id)|\(key)")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Refined.mute).accessibilityHidden(true)
                Text(item.text).foregroundStyle(Refined.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(.system(size: 14))
            .lineSpacing(3)
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
    @Environment(\.look) private var look
    @State private var hover = false
    /// The UI self-test shows the note for a build of its choosing.
    static var previewBuild: Int? = nil

    var body: some View {
        if let note = ReleaseNotes.pending(current: Self.previewBuild ?? ReleaseNotes.currentBuild, lastSeen: lastSeen, notes: notes),
           let number = note.number {
            let native = look == .native
            HStack(spacing: 0) {
                Button {
                    lastSeen = max(lastSeen, number)
                    open()
                } label: {
                    HStack(spacing: 10) {
                        ArtIcon(art: .iconNotes, size: 16, lineWidth: 1.4).foregroundStyle(native ? NativeInk.accent : Ink.ink)
                        (Text("What's new in build \(number)").fontWeight(.semibold) + Text("  ·  " + note.title).foregroundStyle(Ink.dim))
                            .font(.system(size: 13)).foregroundStyle(Ink.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(native ? "Read More" : "Read more").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(native ? NativeInk.accent : Ink.ink)
                            .underline(!native && hover)
                    }
                    .padding(.leading, 14).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .accessibilityLabel("What's new in build \(number): \(note.title)")
                .accessibilityHint("Opens What's new in Settings")
                Button { lastSeen = max(lastSeen, number) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.mute)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide this note")
                .accessibilityLabel("Close")
                .padding(.trailing, 6)
            }
            .modifier(LineSurface())
            .padding(.top, top)
            .transition(.opacity)
        }
    }

    /// Verbose style: card white, the row radius, and the ink outline. Native: a group box.
    private struct LineSurface: ViewModifier {
        @Environment(\.look) private var look
        func body(content: Content) -> some View {
            if look == .native {
                content.nativeGroup(radius: 8)
            } else {
                content
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .inkEdge(outline: true, radius: Radius.row)
            }
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
