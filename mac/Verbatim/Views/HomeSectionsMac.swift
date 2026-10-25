import SwiftUI
import AppKit

// brand: web style
//
// Home's newer sections on the Mac (Edit Home, mockup "premium", section 03): Projects, Moments, and Queue in the
// website style, each Compact (one strip) or Large (the card under its heading); Native draws its own
// (NativeHomeSections.swift). Also the outline and name badge each section wears while Home is being edited, and the
// Search tile's action.

// MARK: - Editing frame

extension View {
    /// While Home is being edited: a dashed outline and a "This week · Large" badge, and the section's own controls
    /// rest (no clicks reach them). Nothing changes identity, so leaving edit mode costs nothing.
    func homeEditFrame(_ item: HomeLayout.Item, editing: Bool) -> some View {
        modifier(HomeEditFrame(item: item, editing: editing))
    }
}

private struct HomeEditFrame: ViewModifier {
    var item: HomeLayout.Item
    var editing: Bool
    @Environment(\.look) private var look

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!editing)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: look == .native ? 26 : Radius.record + 4, style: .continuous)
                        .strokeBorder(look == .native ? Ink.nativeAccent.opacity(0.55) : Ink.ink, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .padding(-6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if editing { badge.offset(x: 14, y: -16).allowsHitTesting(false) }
            }
    }

    @ViewBuilder private var badge: some View {
        let text = "\(item.section.title) · \(item.size.title)"
        if look == .native {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)   // brand: native
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(PremiumInk.card).shadow(color: PremiumInk.shadow, radius: 6, y: 2))   // brand: native
        } else {
            HStack(spacing: 6) {
                ArtIcon(art: .iconNameAndSort, size: 12, lineWidth: 1.4)
                Text(text).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Ink.paper)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Ink.ink))
        }
    }
}

// MARK: - Search tile

enum HomeTileSearch {
    /// Opens the Library and puts the cursor in the toolbar's search field.
    @MainActor static func open(_ app: AppState) {
        app.projectFilter = nil
        app.go(.library)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            for item in w.toolbar?.items ?? [] {
                if let field = (item as? NSSearchToolbarItem)?.searchField ?? (item.view as? NSSearchField) {
                    w.makeFirstResponder(field)
                    return
                }
            }
        }
    }
}

// MARK: - Projects

/// Each project and how many recordings it holds. Compact: a row of pills. Large: the first six as flat rows under
/// "Projects". A click opens the Library on the project.
struct HomeProjectsMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    @Environment(\.look) private var look

    var body: some View {
        let counts = Self.counts(app.store)
        if look == .native {
            NativeHomeProjects(size: size, counts: counts)
        } else if size == .compact {
            compact(counts)
        } else {
            large(counts)
        }
    }

    /// Recordings per project, in one pass over the library.
    static func counts(_ store: Store) -> [UUID: Int] {
        var c: [UUID: Int] = [:]
        for t in store.transcripts where t.deletedAt == nil && !t.isDictation { if let p = t.projectId { c[p, default: 0] += 1 } }
        return c
    }

    private func open(_ p: Project) { app.projectFilter = p.id; app.go(.library) }

    private func compact(_ counts: [UUID: Int]) -> some View {
        Group {
            if app.store.projects.isEmpty {
                Text("Projects group recordings. Make one from the sidebar or a recording's menu.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
                    .inkEdge(outline: true, radius: Radius.record)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(app.store.projects) { p in
                            PillButton(title: "\(p.name)  \((counts[p.id] ?? 0).formatted())", kind: .line, size: .regular, icon: .iconProject,
                                       hint: "Opens the project in your library.") { open(p) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func large(_ counts: [UUID: Int]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "", italic: "Projects", link: "Library", linkHint: "Opens your library.") { app.projectFilter = nil; app.go(.library) }
                .padding(.bottom, 8)
            if app.store.projects.isEmpty {
                EmptyStateCard(art: .iconProject, title: "No projects yet", message: "Projects group recordings. Make one from the sidebar or a recording's menu.")
            }
            ForEach(Array(app.store.projects.prefix(6))) { p in
                FlatRowButton(action: { open(p) }) { _ in
                    HStack(spacing: 12) {
                        IconGlyph(art: .iconProject, size: 18, color: Ink.ink)
                        Text(p.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        StatusText(text: HomeCounts.countLabel(counts[p.id] ?? 0, "recording", "recordings"))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                } accessory: { _ in EmptyView() }
                .accessibilityHint("Opens the project in your library.")
            }
        }
    }
}

// MARK: - Moments

/// The newest saved moment and where it came from. A click opens the transcript at that line.
enum HomeMomentPick {
    static func latest(_ store: Store) -> (t: Transcript, n: Note)? {
        var best: (t: Transcript, n: Note)?
        for t in store.transcripts where t.deletedAt == nil {
            for n in t.notes where n.at != nil && (best == nil || n.createdAt > best!.n.createdAt) { best = (t, n) }
        }
        return best
    }

    /// The note's words, or the passage it points at for a bookmark without words.
    static func text(_ t: Transcript, _ n: Note) -> String {
        if !n.text.isEmpty { return n.isBookmark ? "“\(n.text)”" : n.text }
        let at = n.at ?? 0
        let seg = t.segments.first { $0.id == n.segmentId } ?? t.segments.last { $0.start <= at }
        return seg.map { "“\($0.text.trimmingCharacters(in: .whitespaces))”" } ?? "Bookmark"
    }

    @MainActor static func open(_ app: AppState, _ t: Transcript, _ n: Note) {
        app.focusSegment = n.segmentId ?? t.segments.last { $0.start <= (n.at ?? 0) }?.id
        app.go(.transcript(t.id))
    }
}

/// Large: the moment as a quote on a butter panel under "Saved moments". Compact: one strip with the quote.
struct HomeMomentsMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    @Environment(\.look) private var look
    @State private var down = false

    var body: some View {
        let latest = HomeMomentPick.latest(app.store)
        if look == .native {
            NativeHomeMoments(size: size, latest: latest)
        } else if size == .compact {
            strip(latest)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "Saved", italic: "moments", link: "All", linkLabel: "All moments", linkHint: "Opens Moments.") { app.go(.moments) }
                    .padding(.bottom, 12)
                card(latest)
            }
        }
    }

    private func card(_ latest: (t: Transcript, n: Note)?) -> some View {
        HomeCard(tilt: 1.5, radius: Radius.record, shadow: false, onPress: { down = $0 }, action: {
            if let latest { HomeMomentPick.open(app, latest.t, latest.n) } else { app.go(.moments) }
        }) { hovering in
            VStack(alignment: .leading, spacing: 10) {
                if let latest {
                    HStack(spacing: 8) {
                        IconGlyph(art: latest.n.isBookmark ? .iconPin : .iconNotes, size: 15, color: Ink.inkFixed)
                        Text("\(latest.t.title) · \((latest.n.at ?? 0).timecode)").font(Ink.mono(12)).foregroundStyle(Ink.inkFixed).lineLimit(1)
                    }
                    Text(HomeMomentPick.text(latest.t, latest.n))
                        .font(latest.n.isBookmark ? Ink.serif(22).italic() : .system(size: 15)).foregroundStyle(Ink.inkFixed)
                        .lineSpacing(2).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Bookmark a moment while a transcript plays, and the newest shows here.")
                        .font(.system(size: 14)).foregroundStyle(Ink.inkFixed).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .colorPanel(Ink.panelButter, radius: Radius.record)
            .inkEdge(outline: true, shadow: InkEdge.card(hover: hovering, pressed: down), radius: Radius.record, color: Ink.inkFixed)
        }
        .accessibilityLabel(latest.map { HomeMomentPick.text($0.t, $0.n) } ?? "No moments yet")
        .accessibilityHint(latest == nil ? "Opens Moments." : "Opens the transcript at this moment.")
    }

    private func strip(_ latest: (t: Transcript, n: Note)?) -> some View {
        FlatRowButton(action: { if let latest { HomeMomentPick.open(app, latest.t, latest.n) } else { app.go(.moments) } }) { _ in
            HStack(spacing: 12) {
                IconGlyph(art: .iconMoments, size: 18, color: Ink.ink)
                Text(latest.map { HomeMomentPick.text($0.t, $0.n) } ?? "Bookmark a moment while a transcript plays.")
                    .font(Ink.serif(18)).foregroundStyle(Ink.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let latest {
                    Text("\(latest.t.title) · \((latest.n.at ?? 0).timecode)").font(Ink.mono(12)).foregroundStyle(Ink.mute).lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
            .inkEdge(outline: true, radius: Radius.record)
        } accessory: { _ in EmptyView() }
        .accessibilityHint(latest == nil ? "Opens Moments." : "Opens the transcript at this moment.")
    }
}

// MARK: - Queue

/// What's transcribing (Home draws Queue only while something is). Compact: the first, with how many wait behind it.
/// Large: up to three under "Queue". A click opens the Queue.
struct HomeQueueMac: View {
    @EnvironmentObject var app: AppState
    var size: HomeCardSize
    @Environment(\.look) private var look

    static func working(_ store: Store) -> [Transcript] {
        store.transcripts.filter { $0.deletedAt == nil && $0.status == .processing }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let items = Self.working(app.store)
        if look == .native {
            NativeHomeQueue(size: size, items: items)
        } else if size == .compact {
            if let first = items.first { row(first, more: items.count - 1, boxed: true) }
        } else if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(title: "", italic: "Queue", link: "Queue", linkLabel: "Open the Queue", linkHint: "Opens the Queue.") { app.go(.queue) }
                    .padding(.bottom, 8)
                ForEach(items.prefix(3)) { t in row(t, more: 0, boxed: false) }
            }
        }
    }

    private func row(_ t: Transcript, more: Int, boxed: Bool) -> some View {
        FlatRowButton(action: { app.go(.queue) }) { _ in
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                    Text(more > 0 ? "\(t.stageText) · \(more.formatted()) more" : t.stageText).font(.system(size: 12)).foregroundStyle(Ink.mute).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: boxed ? 60 : 52)
            .background(boxed ? Ink.card : Color.clear, in: RoundedRectangle(cornerRadius: Radius.record, style: .continuous))
            .inkEdge(outline: boxed, radius: Radius.record)
        } accessory: { _ in EmptyView() }
        .accessibilityHint("Opens the Queue.")
    }
}
