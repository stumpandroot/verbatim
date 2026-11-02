import SwiftUI

// What's new, the picture version (DESIGN.md §13, "What's new"), shared by the Mac and iPhone apps. After an update to
// a build marked big (ReleaseNotes.json, `ReleaseNotes.popup`), the sheet opens once by itself: the build's title in
// the serif on a persimmon hero (the Record card's color) with a line-art gift, each of this device's changes beside
// its icon in a colored square (persimmon, butter, sage, petal in turn), one line for the other devices' changes,
// Continue, and See every update. Quieter builds keep Home's note. The What's new list (WhatsNewScreen.swift,
// WhatsNewPane.swift) uses the same hero for the newest build and the same rows for every build.

extension BrandArt {
    /// The line icon for a release item's `icon` name (`ReleaseNotes.icons`); "notes" and anything unknown draw the
    /// notes icon.
    static func release(_ name: String) -> BrandArt {
        switch name {
        case "calendar": return .iconCalendar
        case "words": return .iconDictations
        case "swap": return .iconSwap
        case "tasks": return .iconChecklist
        case "plan": return .iconPlanDay
        case "tidy": return .iconTighten
        case "mic": return .iconMic
        case "voice": return .iconVoice
        case "thought": return .iconThought
        case "braindump": return .iconBrainDump
        case "ask": return .iconAsk
        case "ai": return .iconAI
        case "import": return .iconDownload
        case "play": return .iconPlay
        case "share": return .iconShare
        case "export": return .iconExport
        case "copy": return .iconCopy
        case "settings": return .iconSettings
        case "home": return .iconHome
        case "library": return .iconLibrary
        case "tabbar": return .iconTabBar
        case "privacy": return .iconPrivacy
        case "sync": return .iconSync
        case "speakers": return .iconSpeakers
        case "summary": return .iconSummaries
        case "captions": return .iconCaptions
        case "film": return .iconFilm
        case "links": return .iconLinks
        case "dictionary": return .iconDictionary
        case "widgets": return .iconWidgets
        case "tour": return .iconTour
        case "feedback": return .iconFeedback
        case "support": return .iconSupport
        case "mark": return .iconMark
        case "language": return .iconLanguage
        case "accessibility": return .iconAccessibility
        case "appearance": return .iconAppearance
        case "audio": return .iconAudio
        case "project": return .iconProject
        case "quality": return .iconQuality
        case "time": return .iconTimeSaved
        default: return .iconNotes
        }
    }
}

enum WhatsNewLook {
    /// The squares' colors in turn, so a build's changes read as separate things.
    static let hues: [RefinedHue] = [.persimmon, .butter, .sage, .petal]
    static func hue(_ index: Int) -> RefinedHue { hues[((index % hues.count) + hues.count) % hues.count] }

    /// "Your words calendar · Change kind while recording": the other devices' changes on one line, by headline, or
    /// "2 changes" when one has none.
    static func alsoLine(_ items: [ReleaseItem]) -> String {
        let heads = items.compactMap { ReleaseNotes.headline($0).head }
        if heads.count == items.count, !heads.isEmpty { return heads.joined(separator: " · ") }
        return "\(items.count) change\(items.count == 1 ? "" : "s")"
    }
}

/// A gift in line art, drawn in a 200-point square: the hero's corner.
struct WhatsNewGiftArt: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 200
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s)) }
        var path = Path()
        path.addRoundedRect(in: box(44, 84, 120, 96), cornerSize: CGSize(width: 6 * s, height: 6 * s), style: .continuous)
        path.addRoundedRect(in: box(34, 62, 140, 26), cornerSize: CGSize(width: 6 * s, height: 6 * s), style: .continuous)
        path.move(to: p(104, 62)); path.addLine(to: p(104, 180))
        path.move(to: p(104, 62)); path.addCurve(to: p(58, 46), control1: p(94, 40), control2: p(64, 28))
        path.addCurve(to: p(104, 62), control1: p(53, 60), control2: p(80, 64))
        path.move(to: p(104, 62)); path.addCurve(to: p(150, 46), control1: p(114, 40), control2: p(144, 28))
        path.addCurve(to: p(104, 62), control1: p(155, 60), control2: p(128, 64))
        path.move(to: p(180, 30)); path.addLine(to: p(180, 44))
        path.move(to: p(173, 37)); path.addLine(to: p(187, 37))
        path.addEllipse(in: box(37, 27, 6, 6))
        return path
    }
}

/// The persimmon hero, in the Record card's color: a small bold line ("What's new · Build 266") over the title in the serif, the gift in the corner.
/// Compact is the list's size.
struct WhatsNewHero: View {
    var eyebrow: String
    var title: String
    var compact = false
    @CurrentPalette private var palette: AppPalette
    private let mac = RefinedPlatform.mac

    /// Spelled out: the palette's wrapper is private, which would keep the synthesized one to this file.
    init(eyebrow: String, title: String, compact: Bool = false) {
        self.eyebrow = eyebrow; self.title = title; self.compact = compact
    }

    var body: some View {
        let radius = RefinedPlatform.radius(compact ? .card : .record)
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).refinedFont(.meta, weight: .bold)
            Text(title).refinedFont(compact ? .sectionTitle : .transcriptTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .foregroundStyle(Refined.onFill(.persimmon, palette))
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: compact ? 128 : (mac ? 160 : 176), alignment: .bottomLeading)
        .background(alignment: .topTrailing) {
            WhatsNewGiftArt()
                .stroke(Refined.rings(palette), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: compact ? 160 : 190, height: compact ? 160 : 190)
                .offset(x: 22, y: -28)
                .accessibilityHidden(true)
        }
        .refinedSurface(Refined.fill(.persimmon, palette), radius: radius)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One change: its icon in a colored square, the headline in semibold, and the text under it (or the text alone when
/// it has no headline). `detail` shows under the text when the caller opens it.
struct WhatsNewItemRow: View {
    var item: ReleaseItem
    var hue: RefinedHue
    var square: CGFloat? = nil
    var showDetail = false

    var body: some View {
        let h = ReleaseNotes.headline(item)
        HStack(alignment: .top, spacing: 12) {
            IconSquare(art: .release(ReleaseNotes.icon(item)), hue: hue, side: square)
            VStack(alignment: .leading, spacing: 2) {
                if let head = h.head {
                    Text(head).refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(h.text).refinedFont(.hint).foregroundStyle(Refined.dim)
                } else {
                    Text(h.text).refinedFont(.body).foregroundStyle(Refined.ink)
                }
                if showDetail, let detail = item.detail {
                    Text(detail).refinedFont(.hint).foregroundStyle(Refined.mute).padding(.top, 2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 1)
            Spacer(minLength: 0)
        }
    }
}

/// "Also on Mac" over the other devices' changes on one line.
struct WhatsNewAlsoLine: View {
    var title: String
    var items: [ReleaseItem]
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconSquare(art: .iconSync, hue: .neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).refinedFont(.body, weight: .semibold).foregroundStyle(Refined.ink)
                Text(WhatsNewLook.alsoLine(items)).refinedFont(.hint).foregroundStyle(Refined.dim)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 1)
            Spacer(minLength: 0)
        }
        .padding(14)
        .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
        .accessibilityElement(children: .combine)
    }
}

/// The sheet after a bigger update. Continue closes it; See every update opens the full list. Either way the build
/// counts as seen, so neither the sheet nor Home's note comes back for it.
struct WhatsNewSheet: View {
    var note: ReleaseNote
    var app: ReleaseApp
    var seeAll: () -> Void
    var close: () -> Void
    /// For the UI tours: how many sheets are on screen.
    static var onScreen = 0
    private let mac = RefinedPlatform.mac

    init(note: ReleaseNote, app: ReleaseApp, seeAll: @escaping () -> Void, close: @escaping () -> Void) {
        self.note = note; self.app = app; self.seeAll = seeAll; self.close = close
    }

    var body: some View {
        let sum = ReleaseNotes.summary(note.items, for: app)
        let own = sum.sections.flatMap(\.items)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: mac ? 16 : 18) {
                    WhatsNewHero(eyebrow: note.number.map { "What's new · Build \($0)" } ?? "What's new", title: note.title)
                    ForEach(Array(own.enumerated()), id: \.offset) { i, item in
                        WhatsNewItemRow(item: item, hue: WhatsNewLook.hue(i))
                    }
                    if !sum.also.isEmpty {
                        WhatsNewAlsoLine(title: sum.alsoTitle, items: sum.also.flatMap(\.items))
                    }
                }
                .padding(mac ? 20 : 16)
            }
            footer
        }
        .background(Refined.paper.ignoresSafeArea())
        .onAppear { Self.onScreen += 1 }
        .onDisappear { Self.onScreen = max(0, Self.onScreen - 1) }
    }

    @ViewBuilder private var footer: some View {
        if mac {
            HStack {
                Button("See every update", action: seeAll).buttonStyle(RefinedTextActionStyle())
                Spacer()
                Button("Continue", action: close)
                    .buttonStyle(RefinedActionStyle(kind: .strong))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Refined.separator).frame(height: 1) }
        } else {
            VStack(spacing: 2) {
                Button(action: close) {
                    Text("Continue").refinedFont(.body, weight: .semibold).foregroundStyle(Refined.paper)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Refined.ink, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(RefinedPress())
                Button("See every update", action: seeAll).buttonStyle(RefinedTextActionStyle())
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        }
    }
}
