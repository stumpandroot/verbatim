import SwiftUI

// Home's sections that both looks share on iPhone (Edit Home, mockup "premium", section 03): Last dictation, Projects,
// Moments, and Queue, each Compact (one slim row or strip) or Large (the full card); the shortcut tiles' actions; and
// the Edit Home button at the end of Home. Record, the tiles, This week, and Recent recordings are drawn by each
// look's Home (HomeScreen.swift, PremiumHome.swift). Every view reads `\.look` and draws the look's clothes; the
// Native branches are stock Apple and marked for the brand check.

// MARK: - Spacing

enum HomeSpacing {
    /// Sections with a heading of their own get more room above them.
    static func headed(_ item: HomeLayout.Item) -> Bool {
        switch item.section {
        case .recent, .lastDictation, .projects, .moments, .queue: return item.size == .large
        default: return false
        }
    }

    /// The gap above a section, as each look's Home spaced it before Edit Home (Verbose: Record 18, tiles 10 under
    /// Record, This week 12, Recent recordings 24; Native: the first 18, 12 between cards, Recent recordings 28).
    static func top(_ item: HomeLayout.Item, after previous: HomeLayout.Item?, native: Bool) -> CGFloat {
        guard let previous else { return 18 }
        if headed(item) { return native ? 28 : 24 }
        if !native, previous.section == .record, item.section == .tiles { return 10 }
        return 12
    }

    /// The sections Home draws: the layout's shown ones, without Queue while nothing is transcribing.
    static func drawn(_ layout: HomeLayout, working: Bool) -> [HomeLayout.Item] {
        layout.shown.filter { $0.section != .queue || working }
    }
}

// MARK: - Tiles

enum HomeTileAction {
    /// What a tile does on iPhone. Import is a menu (HomeTileButton); the Mac's tiles aren't offered here.
    @MainActor static func run(_ tile: HomeTile, _ app: PhoneState) {
        switch tile {
        case .dictate: app.homePath.append(DictationsRoute())
        case .importMedia: app.showImporter = true
        case .whatsPlaying: app.showPlayingSheet = true
        case .captions: app.requestCaptions()
        case .pasteLink: app.showLinkSheet = true
        case .search, .projects: app.tab = .library
        case .moments: app.tab = .moments
        case .queue:
            app.libraryFilterRequest = "working"
            app.tab = .library
        case .dictations:
            app.libraryPath = NavigationPath()
            app.libraryPath.append(DictationsRoute())
            app.tab = .library
        case .dictionary: app.homePath.append(HomeDictionaryRoute())
        case .appAudio, .thoughtPad: break
        }
    }

    static func hint(_ tile: HomeTile) -> String {
        switch tile {
        case .dictate: return "Opens your dictations and how to use the Verbose keyboard."
        case .importMedia: return "Choose a video from Photos, audio or video files, or paste a link to transcribe."
        case .whatsPlaying: return "Transcribes sound from TikTok or any app."
        case .captions: return "Shows what's said in the room as captions."
        case .pasteLink: return "Transcribes a YouTube, Vimeo, or podcast link."
        case .search: return "Opens your library, where you can search every transcript."
        case .moments: return "Opens your saved moments."
        case .queue: return "Shows what's still transcribing."
        case .dictations: return "Opens every dictation."
        case .dictionary: return "Opens your dictionary."
        case .projects: return "Opens your library, with a chip for each project."
        case .appAudio, .thoughtPad: return ""
        }
    }
}

/// Pushes the dictionary from Home's Dictionary tile.
struct HomeDictionaryRoute: Hashable {}

/// A tile's button: Import opens its menu (Photos, files, or a link); every other tile runs its action.
struct HomeTileButton<Face: View>: View {
    @EnvironmentObject var app: PhoneState
    var tile: HomeTile
    @ViewBuilder var label: () -> Face

    var body: some View {
        Group {
            if tile == .importMedia {
                Menu {
                    Button("Choose from Photos") { app.showPhotoPicker = true }
                    Button("Choose files…") { app.showImporter = true }
                    Button("Paste a link") { app.showLinkSheet = true }
                } label: { label() }
                .menuStyle(.button)
                .buttonStyle(PhoneCardPress())
                .accessibilityAction(named: "Paste a link") { app.showLinkSheet = true }
            } else {
                Button { HomeTileAction.run(tile, app) } label: { label() }
                    .buttonStyle(PhoneCardPress())
            }
        }
        .accessibilityHint(HomeTileAction.hint(tile))
        .homeTileProbe(tile)
    }
}

// MARK: - Headings

/// A section's heading: Verbose style's serif with an italic word ("Last *dictation*"), Native's bold title; an
/// optional link on the right.
struct HomeSectionHeading: View {
    var title: String
    var italic: String? = nil
    var link: String? = nil
    var onLink: () -> Void = {}
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 22
    @Environment(\.look) private var look

    var body: some View {
        if look.isNative {
            PremiumSectionHeader(title: nativeTitle, action: link, onAction: onLink)
        } else {
            HStack(alignment: .firstTextBaseline) {
                (Text(title.isEmpty ? "" : title + " ") + Text(italic ?? "").italic())
                    .lookSerif(size).foregroundStyle(.lookInk)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let link {
                    Button(link, action: onLink)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.lookAccentText)
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

extension HomeSectionHeading {
    /// One upright title in Native: "Last dictation", "Projects".
    fileprivate var nativeTitle: String {
        guard let italic else { return title }
        if title.isEmpty { return italic.prefix(1).uppercased() + String(italic.dropFirst()) }
        return title + " " + italic
    }
}

/// A slim card for a Compact section: Verbose style's paper with an ink outline, Native's soft card.
private struct HomeStrip: ViewModifier {
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        if look.isNative {
            content.padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .premiumSoftCard(radius: 20)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            content.padding(.horizontal, 14).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .phoneOutlined(radius: Radius.record)
                .contentShape(RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
        }
    }
}

extension View {
    fileprivate func homeStrip() -> some View { modifier(HomeStrip()) }
}

// MARK: - Last dictation

/// The newest dictation with a Copy button. Compact: one row with where it went and its length. Large: the words too,
/// on a butter panel (Verbose style) or a soft card (Native). A tap anywhere copies; the button turns into "Copied".
struct HomeLastDictationSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    var now: Date
    @Environment(\.look) private var look
    @Environment(\.limitMotion) private var limitMotion
    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        let last = app.store.live.filter(\.isDictation).max { $0.createdAt < $1.createdAt }
        Group {
            if size == .compact { compact(last) } else { large(last) }
        }
        .accessibilityIdentifier("home.lastDictation")
    }

    private func head(_ t: Transcript) -> String {
        let words = HomeCounts.countLabel(HomeCounts.words(t), "word", "words")
        let when = Calendar.current.isDate(t.createdAt, inSameDayAs: now)
            ? Formats.style(date: .none, time: .short).string(from: t.createdAt) : HomeRecentStyle.day(t.createdAt, now: now)
        if let place = t.flow?.app, !place.isEmpty { return "\(words) in \(place) · \(when)" }
        return "\(words) · \(when)"
    }

    private func compact(_ last: Transcript?) -> some View {
        Button { if let last { copy(last) } else { app.homePath.append(DictationsRoute()) } } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last dictation").lookSerif(look.isNative ? 17 : 19, weight: look.isNative ? .semibold : .regular).foregroundStyle(.lookInk)
                    Text(last.map(head) ?? "Dictate in any app with the Verbose keyboard.")
                        .font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                if last != nil { copyPill }
            }
            .homeStrip()
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(last.map { "Last dictation: \(HomeDictationText.body($0))" } ?? "Last dictation: none yet")
        .accessibilityValue(copied ? "Copied" : last.map(head) ?? "")
        .accessibilityHint(last == nil ? "Opens your dictations." : "Copies the dictation.")
    }

    private func large(_ last: Transcript?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeading(title: "Last", italic: "dictation", link: "All") { app.homePath.append(DictationsRoute()) }
            Button { if let last { copy(last) } else { app.homePath.append(DictationsRoute()) } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    if let last {
                        Text(head(last)).lookMono(12).foregroundStyle(look.isNative ? AnyShapeStyle(NativeInk.secondary) : AnyShapeStyle(Ink.inkFixed)).lineLimit(1)
                        Text(HomeDictationText.body(last)).font(.system(size: 16)).lineSpacing(3)
                            .foregroundStyle(look.isNative ? AnyShapeStyle(NativeInk.label) : AnyShapeStyle(Ink.inkFixed))
                            .lineLimit(3).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack { Spacer(minLength: 0); copyPill }
                    } else {
                        Text("Dictate in any app with the Verbose keyboard. What you say shows up here.")
                            .font(.system(size: 15)).foregroundStyle(look.isNative ? AnyShapeStyle(NativeInk.secondary) : AnyShapeStyle(Ink.inkFixed))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { panel }
                .contentShape(RoundedRectangle(cornerRadius: look.isNative ? 22 : Radius.record, style: .continuous))
            }
            .buttonStyle(PhoneCardPress())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(last.map { HomeDictationText.body($0) } ?? "No dictations yet")
            .accessibilityValue(copied ? "Copied" : last.map(head) ?? "")
            .accessibilityHint(last == nil ? "Opens your dictations." : "Copies the dictation.")
        }
    }

    @ViewBuilder private var panel: some View {
        if look.isNative {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(PremiumInk.card)
                .shadow(color: PremiumStyle.cardShadow, radius: 11, y: 6)
        } else {
            let shape = RoundedRectangle(cornerRadius: Radius.record, style: .continuous)
            PhonePanelFill(color: PhoneInk.butter, shape: shape).overlay(shape.strokeBorder(Ink.inkFixed, lineWidth: 1.5))
        }
    }

    /// "Copy", then "Copied" for 1.6 s.
    private var copyPill: some View {
        Text(copied ? "Copied" : "Copy")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(look.isNative ? NativeInk.accent : Ink.inkFixed)
            .padding(.horizontal, 14).frame(minHeight: 32)
            .background {
                if look.isNative { Capsule().fill(PremiumInk.accentSoft) }
                else { Capsule().fill(Ink.readerFixed.opacity(0.7)).overlay(Capsule().strokeBorder(Ink.inkFixed, lineWidth: 1.2)) }
            }
            .contentTransition(.opacity)
            .accessibilityHidden(true)
    }

    private func copy(_ t: Transcript) {
        HomeScreen.copyDictation(HomeDictationText.pasted(t))
        copies += 1
        let token = copies
        withAnimation(limitMotion ? Motion.fade : HomeMotion.morph) { copied = true }
        HomeAnnounce.say("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard copies == token else { return }
            withAnimation(limitMotion ? Motion.fade : HomeMotion.morph) { copied = false }
        }
    }
}

// MARK: - Projects

/// Each project with how many recordings it holds. Compact: a row of chips. Large: a card with a row per project
/// (the first five). A tap opens the Library on that project.
struct HomeProjectsSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    @Environment(\.look) private var look

    var body: some View {
        var counts: [UUID: Int] = [:]
        for t in app.store.live where !t.isDictation { if let p = t.projectId { counts[p, default: 0] += 1 } }
        let projects = app.store.projects
        return Group {
            if size == .compact { compact(projects, counts) } else { large(projects, counts) }
        }
    }

    private func open(_ p: Project) {
        app.libraryFilterRequest = "project:\(p.id.uuidString)"
        app.tab = .library
    }

    private func compact(_ projects: [Project], _ counts: [UUID: Int]) -> some View {
        Group {
            if projects.isEmpty {
                Button { app.tab = .library } label: {
                    Text("Projects group recordings. Make one in the Library.").font(.system(size: 14)).foregroundStyle(.lookDim).homeStrip()
                }
                .buttonStyle(PhoneCardPress())
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(projects) { p in
                            Button { open(p) } label: { chip(p.name, counts[p.id] ?? 0) }
                                .buttonStyle(PhoneCardPress())
                                .accessibilityLabel("\(p.name), \(HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings"))")
                                .accessibilityHint("Opens the project in your library.")
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    private func chip(_ name: String, _ n: Int) -> some View {
        HStack(spacing: 7) {
            if !look.isNative { IconGlyph(art: .iconProject, size: 15, color: Ink.ink) }
            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
            Text(n.formatted()).lookMono(12).foregroundStyle(.lookMute)
        }
        .padding(.horizontal, 14).frame(minHeight: 40)
        .background {
            if look.isNative { Capsule().fill(PremiumInk.card).shadow(color: PremiumStyle.cardShadow, radius: 6, y: 3) }
            else { Capsule().fill(Ink.card).overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 1.5)) }
        }
    }

    private func large(_ projects: [Project], _ counts: [UUID: Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HomeSectionHeading(title: "", italic: "Projects", link: "Library") { app.tab = .library }
            VStack(spacing: 0) {
                if projects.isEmpty {
                    Text("Projects group recordings. Make one in the Library.").font(.system(size: 15)).foregroundStyle(.lookDim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                ForEach(Array(projects.prefix(5).enumerated()), id: \.element.id) { i, p in
                    Button { open(p) } label: {
                        HStack(spacing: 12) {
                            if !look.isNative { IconGlyph(art: .iconProject, size: 18, color: Ink.ink) }
                            Text(p.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings")).font(.system(size: 14)).foregroundStyle(.lookMute)
                        }
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PhoneCardPress())
                    .accessibilityHint("Opens the project in your library.")
                    if i < min(projects.count, 5) - 1 { Rectangle().fill(.lookHairline).frame(height: look.isNative ? 0.5 : 1) }
                }
            }
            .homeStrip()
        }
    }
}

// MARK: - Moments

/// The newest saved moment. Large: the moment card from Moments. Compact: one line of it with its recording and time.
/// A tap opens the transcript at that line.
struct HomeMomentsSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    @Environment(\.look) private var look

    var body: some View {
        var latest: (t: Transcript, n: Note)?
        for t in app.store.live {
            for n in t.notes where n.at != nil && (latest == nil || n.createdAt > latest!.n.createdAt) { latest = (t, n) }
        }
        return Group {
            if size == .compact { compact(latest) } else { large(latest) }
        }
    }

    private func open(_ t: Transcript, _ n: Note) {
        app.open(t.id, segment: n.segmentId ?? t.segments.last { $0.start <= (n.at ?? 0) }?.id)
    }

    private func compact(_ latest: (t: Transcript, n: Note)?) -> some View {
        Button { if let latest { open(latest.t, latest.n) } else { app.tab = .moments } } label: {
            HStack(spacing: 12) {
                if !look.isNative { IconGlyph(art: .iconMoments, size: 20, color: Ink.ink) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(latest.map { $0.n.isBookmark ? "“\($0.n.text)”" : $0.n.text } ?? "Bookmark a moment while a transcript plays.")
                        .lookSerif(look.isNative ? 16 : 18, weight: look.isNative ? .semibold : .regular)
                        .italic(!look.isNative && latest?.n.isBookmark == true)
                        .foregroundStyle(.lookInk).lineLimit(1)
                    if let latest {
                        Text("\(latest.t.title) · \((latest.n.at ?? 0).timecode)").font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .homeStrip()
        }
        .buttonStyle(PhoneCardPress())
        .accessibilityHint(latest == nil ? "Opens Moments." : "Opens the transcript at this moment.")
    }

    private func large(_ latest: (t: Transcript, n: Note)?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeading(title: "Saved", italic: "moments", link: "All") { app.tab = .moments }
            if let latest {
                Button { open(latest.t, latest.n) } label: { PhoneMomentCard(transcript: latest.t, note: latest.n) }
                    .buttonStyle(PhoneCardPress())
                    .accessibilityHint("Opens the transcript at this moment.")
            } else {
                Text("Bookmark a moment while a transcript plays, or touch and hold a line.")
                    .font(.system(size: 15)).foregroundStyle(.lookDim).homeStrip()
            }
        }
    }
}

// MARK: - Queue

/// What's transcribing (Home draws Queue only while something is). Compact: the first one, and how many more.
/// Large: up to three, each with where it is. A tap opens the transcript.
struct HomeQueueSection: View {
    @EnvironmentObject var app: PhoneState
    var size: HomeCardSize
    @Environment(\.look) private var look

    static func working(_ app: PhoneState) -> [Transcript] {
        app.store.live.filter { $0.status == .processing }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let items = Self.working(app)
        return Group {
            if size == .compact, let first = items.first {
                Button { app.open(first.id) } label: {
                    row(first, more: items.count - 1).homeStrip()
                }
                .buttonStyle(PhoneCardPress())
                .accessibilityHint("Opens the transcript.")
            } else if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HomeSectionHeading(title: "", italic: "Queue", link: items.count > 3 ? "All" : nil) {
                        app.libraryFilterRequest = "working"; app.tab = .library
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { i, t in
                            Button { app.open(t.id) } label: { row(t, more: 0).frame(minHeight: 48).contentShape(Rectangle()) }
                                .buttonStyle(PhoneCardPress())
                                .accessibilityHint("Opens the transcript.")
                            if i < min(items.count, 3) - 1 { Rectangle().fill(.lookHairline).frame(height: look.isNative ? 0.5 : 1) }
                        }
                    }
                    .homeStrip()
                }
            }
        }
    }

    private func row(_ t: Transcript, more: Int) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(look.isNative ? NativeInk.accent : Ink.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.lookInk).lineLimit(1)
                Text(more > 0 ? "\(t.stageText) · \(more.formatted()) more" : t.stageText).font(.system(size: 13)).foregroundStyle(.lookDim).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Edit Home button

/// The last thing on Home: opens Edit Home. Verbose style: an outlined capsule; Native: a gray capsule with the grid.
struct EditHomeButton: View {
    var action: () -> Void
    @Environment(\.look) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if look.isNative {
                    Image(systemName: "square.grid.2x2").font(.system(size: 15, weight: .medium))   // brand: native
                } else {
                    Image(systemName: "line.3.horizontal").font(.system(size: 14, weight: .semibold))
                }
                Text("Edit Home").font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.lookInk)
            .padding(.horizontal, 20).frame(minHeight: 44)
            .background {
                if look.isNative { Capsule().fill(NativeInk.fill) }
                else { Capsule().strokeBorder(Ink.ink, lineWidth: 1.5) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PhoneCardPress())
        .frame(maxWidth: .infinity)
        .accessibilityHint("Show, hide, reorder, and resize Home's sections, and choose its four tiles.")
        .accessibilityIdentifier("home.edit")
    }
}
