import SwiftUI

/// What's new (the version at the foot of Settings, search, and Home's note): every build's
/// notes, newest first, from the bundled ReleaseNotes.json (Verbatim/Model/ReleaseNotes.swift), grouped under version
/// headers ("Version 1.0 beta"): the newest version open, older ones closed until tapped. On the refined kit (DESIGN.md
/// §13) in both look settings: the large serif title, then one card per build with the build and date in the meta
/// style ("Build 203 · Oct 25"), its title in the section serif, and its items under semibold platform labels. The
/// items for this iPhone lead (iPhone, then Apple Watch), the Mac's fold under one "Also on Mac" row, and a line with a detail opens it in place, without
/// movement (`ReleaseNotes.summary`).
struct WhatsNewScreen: View {
    var notes: [ReleaseNote] = ReleaseNotes.bundled
    /// Versions tapped open or closed; the newest starts open and the rest closed.
    @State private var toggled: Set<String> = []
    /// Builds whose "Also on Mac" items are open.
    @State private var alsoOpened: Set<String> = []
    /// Lines whose detail is open, by `lineKey`.
    @State private var detailsOpen: Set<String> = []
    @ScaledMetric(relativeTo: .body) private var itemSize: CGFloat = 15
    @AppStorage(ReleaseNotes.lastSeenKey) private var lastSeen = 0
    /// How many What's new screens are on screen, for the UI tour's checks. A count rather than a flag, so a screen
    /// that appears before the one it replaces has gone can't leave it stuck.
    static var onScreen = 0
    static var visible: Bool { onScreen > 0 }
    /// What the UI tour's last `ReleaseNotes.showForTest` opened: a line's detail, and the "Also on" row.
    static var shownForTest = (detail: false, also: false)

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                LargeSerifTitle(title: "What's new")
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                if notes.isEmpty {
                    Text("The release notes aren't in this build.")
                        .refinedFont(.body).foregroundStyle(Refined.mute)
                        .padding(.top, 18)
                }
                ForEach(Array(ReleaseNotes.byVersion(notes).enumerated()), id: \.element.id) { i, version in
                    let open = (i == 0) != toggled.contains(version.id)
                    versionHeader(version, open: open)
                        .padding(.top, i == 0 ? 14 : 22)
                    if open {
                        ForEach(Array(version.notes.enumerated()), id: \.element.id) { j, note in
                            card(note)
                                .padding(.top, j == 0 ? 8 : 14)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseNotes.showForTest)) { n in
            showForTest(n.object as? String, proxy: proxy)
        }
        }
        .background(Refined.paper.ignoresSafeArea())
        .navigationTitle("What's new")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The serif title sits on the paper.
            ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
        }
        .onAppear {
            Self.onScreen += 1
            // Opening What's new counts as seeing this build's note.
            if let current = ReleaseNotes.currentBuild, current > lastSeen { lastSeen = current }
        }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
    }

    /// A version's header: a chevron, "Version 1.0 beta", and how many builds. Tapping it shows or hides the builds.
    private func versionHeader(_ version: ReleaseVersion, open: Bool) -> some View {
        Button {
            if toggled.contains(version.id) { toggled.remove(version.id) } else { toggled.insert(version.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Refined.mute)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14)
                Text(version.heading).refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                Text("\(version.notes.count) build\(version.notes.count == 1 ? "" : "s")")
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(version.spokenHeading)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityAddTraits([.isButton, .isHeader])
    }

    /// A build's card: the build and date, the title in the section serif, and the items.
    private func card(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.heading).refinedFont(.meta).foregroundStyle(Refined.mute)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(note.spokenHeading)
            Text(note.title).refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            items(note)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
    }

    /// The items for this iPhone first (iPhone, then Apple Watch, each under its label), and the Mac's folded under
    /// "Also on Mac", closed until tapped. Nothing here animates: a detail or the fold opens in place.
    private func items(_ note: ReleaseNote) -> some View {
        let sum = ReleaseNotes.summary(note.items, for: .phone)
        let alsoOpen = alsoOpened.contains(note.id)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(sum.sections.enumerated()), id: \.element.id) { k, section in
                platformLabel(section.title).padding(.top, k == 0 ? 2 : 8)
                lines(section.items, note: note, part: section.id)
            }
            if !sum.also.isEmpty {
                alsoRow(note, title: sum.alsoTitle, count: sum.alsoCount, open: alsoOpen)
                    .padding(.top, sum.sections.isEmpty ? 0 : 4)
                    .id(Self.alsoKey(note))
                if alsoOpen {
                    ForEach(sum.also) { section in
                        if sum.also.count > 1 { platformLabel(section.title) }
                        lines(section.items, note: note, part: "also-" + section.id)
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
    }

    /// A platform's label, in semibold ink. A header for VoiceOver.
    private func platformLabel(_ title: String) -> some View {
        Text(title).refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.ink)
            .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }

    /// "Also on Mac" and how many items fold under it: tap to show or hide them.
    private func alsoRow(_ note: ReleaseNote, title: String, count: Int, open: Bool) -> some View {
        Button {
            if open { alsoOpened.remove(note.id) } else { alsoOpened.insert(note.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title).font(.system(size: itemSize - 1, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(count)").font(.system(size: itemSize - 1)).monospacedDigit()
                Spacer(minLength: 0)
            }
            .foregroundStyle(Refined.accentText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) item\(count == 1 ? "" : "s")")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityHint(open ? "Shows less" : "Shows more")
        .accessibilityAddTraits(.isButton)
    }

    private func lines(_ items: [ReleaseItem], note: ReleaseNote, part: String) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
            line(item, key: Self.lineKey(note, part: part, index: i))
        }
    }

    /// One line: a bullet and the text. With a detail, the line is a button with a disclosure chevron that opens the
    /// detail under it, without movement.
    @ViewBuilder
    private func line(_ item: ReleaseItem, key: String) -> some View {
        if let detail = item.detail {
            let open = detailsOpen.contains(key)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    if open { detailsOpen.remove(key) } else { detailsOpen.insert(key) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Refined.mute).accessibilityHidden(true)
                        Text(item.text).foregroundStyle(Refined.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: max(11, itemSize - 4), weight: .semibold))
                            .foregroundStyle(Refined.accentText)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: itemSize))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.text)
                .accessibilityHint(open ? "Shows less" : "Shows more")
                .accessibilityAddTraits(.isButton)
                if open {
                    Text(detail).font(.system(size: itemSize - 1)).foregroundStyle(Refined.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 16)
                }
            }
            .id(key)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Refined.mute).accessibilityHidden(true)
                Text(item.text).foregroundStyle(Refined.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: itemSize))
        }
    }

    static func lineKey(_ note: ReleaseNote, part: String, index: Int) -> String { "\(note.id)|\(part)|\(index)" }
    static func alsoKey(_ note: ReleaseNote) -> String { "\(note.id)|also" }

    /// The UI tour's screenshots: "detail" opens the first line with a detail in the newest version's builds, "also"
    /// the first "Also on Mac" row, and either scrolls to it.
    private func showForTest(_ what: String?, proxy: ScrollViewProxy) {
        let shown = ReleaseNotes.byVersion(notes).first?.notes ?? []
        if what == "detail" {
            for note in shown {
                let sum = ReleaseNotes.summary(note.items, for: .phone)
                if let section = sum.sections.first(where: { $0.items.contains { $0.detail != nil } }),
                   let i = section.items.firstIndex(where: { $0.detail != nil }) {
                    let key = Self.lineKey(note, part: section.id, index: i)
                    detailsOpen.insert(key)
                    Self.shownForTest.detail = true
                    DispatchQueue.main.async { proxy.scrollTo(key, anchor: .center) }
                    return
                }
            }
        } else if what == "also", let note = shown.first(where: { !ReleaseNotes.summary($0.items, for: .phone).also.isEmpty }) {
            alsoOpened.insert(note.id)
            Self.shownForTest.also = true
            DispatchQueue.main.async { proxy.scrollTo(Self.alsoKey(note), anchor: .top) }
        }
    }
}

/// Home's one-time note after an update: "What's new in build 205" and the build's title. Tapping it opens What's new;
/// the close button hides it. Either way it doesn't come back until a newer build with notes. Never a modal.
struct WhatsNewBanner: View {
    /// Space above the note, only while it shows.
    var top: CGFloat = 0
    var notes: [ReleaseNote] = ReleaseNotes.bundled
    var open: () -> Void
    @AppStorage(ReleaseNotes.lastSeenKey) private var lastSeen = 0
    /// The UI tour shows the note for a build of its choosing (the simulator's build has no entry).
    static var previewBuild: Int? = nil

    var body: some View {
        if let note = ReleaseNotes.pending(current: Self.previewBuild ?? ReleaseNotes.currentBuild, lastSeen: lastSeen, notes: notes),
           let number = note.number {
            HStack(spacing: 0) {
                Button {
                    lastSeen = max(lastSeen, number)
                    open()
                } label: {
                    HStack(spacing: 12) {
                        IconSquare(art: .iconNotes, hue: .butter)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("What's new in build \(number)")
                                .refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                            Text(note.title).refinedFont(.meta).foregroundStyle(Refined.mute).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 14).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens What's new")
                Button { lastSeen = max(lastSeen, number) } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Refined.mute)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityHint("Hides this note")
                .padding(.trailing, 4)
            }
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            .padding(.top, top)
            .transition(.opacity)
        }
    }
}
