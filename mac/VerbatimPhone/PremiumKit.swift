// brand: native file
import SwiftUI
import UIKit

// The iPhone's Native look, Premium (DESIGN.md §13, mockup "premium", section 01): an airy list on a warm off-white
// (black in dark) with a soft persimmon glow at the top, gradient cards in the four warm brand colors, big SF Pro
// Rounded numbers, Voicenotes-style recording items, and one floating persimmon record button. Same tabs and
// features as before; only the feel changes.
//
// Performance: every color and gradient here is built once (static), never in `body`, and nothing enters with an
// animation. This file is Native look code (`// brand: native file`).

// MARK: - Styles

enum PremiumStyle {
    /// Gradient cards run a little off vertical (the mockup's 160°), light at the top.
    private static let start = UnitPoint(x: 0.35, y: 0), end = UnitPoint(x: 0.65, y: 1)
    static let persimmon = LinearGradient(colors: PremiumInk.stops(PremiumInk.persimmonLight, PremiumInk.persimmonDark), startPoint: start, endPoint: end)
    /// The persimmon's deeper half, for cards with small text near the top (the transcript's Summary): white
    /// measures 4.5:1 or better everywhere on it.
    static let persimmonDeep = LinearGradient(colors: Array(PremiumInk.stops(PremiumInk.persimmonLight, PremiumInk.persimmonDark).dropFirst()), startPoint: start, endPoint: end)
    static let ink = LinearGradient(colors: PremiumInk.stops(PremiumInk.inkLight, PremiumInk.inkDark), startPoint: start, endPoint: end)
    static let sage = LinearGradient(colors: PremiumInk.stops(PremiumInk.sageLight, PremiumInk.sageDark), startPoint: start, endPoint: end)
    static let rose = LinearGradient(colors: PremiumInk.stops(PremiumInk.roseLight, PremiumInk.roseDark), startPoint: start, endPoint: end)
    /// The cards' highlight: white at 10%, gone by a third of the way down, so small text below keeps 4.5:1
    /// (PremiumRules.highlight; mac/tools/test-premium-phone.sh).
    static let highlight = LinearGradient(colors: [Color.white.opacity(PremiumRules.highlight), Color.white.opacity(0)],
                                          startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.33))
    /// The record disc: a highlight up and to the left, brand persimmon, a deeper edge. No text sits on it.
    static let disc = RadialGradient(colors: PremiumInk.discColors, center: UnitPoint(x: 0.34, y: 0.28), startRadius: 0, endRadius: 44)
    /// The soft persimmon glow at the top of every screen.
    static let glow = RadialGradient(colors: [PremiumInk.glow, PremiumInk.glow.opacity(0)], center: UnitPoint(x: 0.18, y: 0), startRadius: 0, endRadius: 420)
    /// The recorder's stronger glow, centered behind the clock.
    static let recorderGlow = RadialGradient(colors: [Ink.persimmonFixed.opacity(0.30), Ink.persimmonFixed.opacity(0)], center: UnitPoint(x: 0.5, y: 0.34), startRadius: 0, endRadius: 360)

    /// Soft cards' shadow in light; dark draws a faint hairline instead.
    static let cardShadow = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .clear : UIColor.black.withAlphaComponent(0.08) })
    static let cardEdge = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.06) : .clear })
    /// The record button's ring: near-white in light, a faint white in dark.
    static let ring = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.14) : UIColor.white.withAlphaComponent(0.75) })
    static let discShadow = Ink.persimmonFixed.opacity(0.45)

    /// Big numbers: SF Pro Rounded, heavy, with even digits.
    static func number(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// The four card colors. Persimmon is the default; ink green is You's week; sage and rose are its stat cards.
enum PremiumGradient {
    case persimmon, ink, sage, rose
    var fill: LinearGradient {
        switch self {
        case .persimmon: return PremiumStyle.persimmon
        case .ink: return PremiumStyle.ink
        case .sage: return PremiumStyle.sage
        case .rose: return PremiumStyle.rose
        }
    }
}

// MARK: - Surfaces

extension View {
    /// A gradient card: the fill, its top highlight, white text, and rounded corners (26 pt).
    func premiumCard(_ g: PremiumGradient, radius: CGFloat = 26) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return foregroundStyle(Color.white)
            .background { shape.fill(g.fill).overlay(shape.fill(PremiumStyle.highlight)) }
            .clipShape(shape)
            .contentShape(shape)
    }

    /// System glass for a small control (Native puts text on glass in standard places, DESIGN.md §13.5): Liquid
    /// Glass on iOS 26, a material before it.
    @ViewBuilder func premiumGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// A soft white card (gray in dark) with a light shadow.
    func premiumSoftCard(radius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(PremiumInk.card, in: shape)
            .overlay(shape.strokeBorder(PremiumStyle.cardEdge, lineWidth: 0.5))
            .shadow(color: PremiumStyle.cardShadow, radius: 11, y: 6)
    }
}

/// The page under every Native screen: the warm off-white (black in dark) and the glow at the top. One static
/// gradient, drawn behind the content, never animated.
struct PremiumPageBackground: View {
    var recorder = false
    var body: some View {
        ZStack(alignment: .top) {
            PremiumInk.paper
            (recorder ? PremiumStyle.recorderGlow : PremiumStyle.glow)
                .frame(height: recorder ? 620 : 420)
                .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Headers

/// "Recent recordings" with Library on the right, in the mockup's 22 pt bold.
struct PremiumSectionHeader: View {
    var title: String
    var action: String? = nil
    var onAction: () -> Void = {}
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold()).foregroundStyle(NativeInk.label)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let action {
                Button(action, action: onAction).font(.system(size: 16)).foregroundStyle(NativeInk.accent).buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Recording items

/// One recording, Voicenotes-style (Home's Recent recordings and the Library): the date line, the title in bold on
/// up to two lines, a two-line preview of the first cleaned lines (or the kind and state while there's no text), then
/// a play pill with the length, the state, and ⋯ with Add to project, Copy text, Share, and Delete. A hairline under
/// it; no card. Tap the text to open the transcript; the play pill opens it playing.
struct PremiumRecordingItem: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var now: Date
    var showsDivider = true
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 18
    @ScaledMetric(relativeTo: .subheadline) private var previewSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var dateSize: CGFloat = 14

    /// The live progress (StageClock) while it transcribes: a tick re-renders the item, not the screen.
    @ObservedObject private var stages = StageClock.shared
    private var t: Transcript { stages.applied(to: transcript) }
    private var canPlay: Bool { t.status == .ready && t.audioFileName != nil && t.duration > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { app.open(t.id) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        if t.pinned {
                            Image(systemName: "pin.fill").font(.system(size: dateSize - 3)).accessibilityLabel("Pinned")
                        }
                        Text(Self.dateLine(t, now: now)).monospacedDigit()
                    }
                    .font(.system(size: dateSize)).foregroundStyle(NativeInk.secondary)
                    Text(PhoneRowTitle.title(t, withTime: false)).font(.system(size: titleSize, weight: .semibold)).foregroundStyle(NativeInk.label)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .padding(.top, 3)
                    let preview = Self.preview(t)
                    if !preview.isEmpty {
                        Text(preview).font(.system(size: previewSize)).foregroundStyle(NativeInk.secondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PhoneCardPress())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the transcript.")
            HStack(spacing: 10) {
                if canPlay {
                    Button { app.autoplay = t.id; app.open(t.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 13))
                            Text(HomeRecentStyle.length(t.duration)).monospacedDigit()
                        }
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(NativeInk.label)
                        .padding(.leading, 13).padding(.trailing, 16).frame(minHeight: 38)
                        .background(PremiumInk.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(NativeInk.separator, lineWidth: 0.5))
                        .shadow(color: PremiumStyle.cardShadow, radius: 5, y: 3)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PhoneCardPress())
                    .accessibilityLabel("Play, \(HomeRecentStyle.length(t.duration))")
                    .accessibilityHint("Opens the transcript and plays it.")
                } else if t.duration > 0, t.status == .ready {
                    Text(HomeRecentStyle.length(t.duration)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(NativeInk.secondary)
                }
                state
                Spacer(minLength: 6)
                PremiumMoreMenu(transcript: t)
            }
            .padding(.top, 11)
        }
        .padding(.top, 16).padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(NativeInk.separator).frame(height: NativeMetrics.hairline).accessibilityHidden(true) }
        }
        .contextMenu { RowActions(transcript: t) }
    }

    @ViewBuilder private var state: some View {
        switch t.status {
        case .processing:
            HStack(spacing: 5) {
                if t.processingDevice == Device.id { ProgressView().controlSize(.mini) }
                Text(PhoneRowState.shortStage(t)).lineLimit(1)
            }
            .font(.system(size: 13)).foregroundStyle(NativeInk.secondary)
        case .failed:
            Text("Didn't finish").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeInk.danger)
        case .ready:
            if PhoneRowState.cleaned(t) {
                Text("Cleaned").font(.system(size: 13)).foregroundStyle(NativeInk.accent)
            }
        }
    }

    /// "Today · 9:12 AM", "Oct 22 · 8:05 AM".
    static func dateLine(_ t: Transcript, now: Date) -> String {
        "\(HomeRecentStyle.day(t.createdAt, now: now)) · \(Formats.style(date: .none, time: .short).string(from: t.createdAt))"
    }

    /// The first cleaned lines (or the transcript's first lines); while there are none, the kind and where it is.
    static func preview(_ t: Transcript) -> String {
        let style = HomeRecentStyle(t)
        switch t.status {
        case .processing: return "\(style.chip) · \(t.stageText)"
        case .failed: return "\(style.chip) · Didn't finish. Retry from the More menu."
        case .ready:
            if let doc = t.document, !doc.isEmpty { return PremiumRules.preview([String(doc.prefix(400))]) }
            let text = PremiumRules.preview(t.segments.prefix(6).map(\.text))
            return text.isEmpty ? style.chip : text
        }
    }
}

/// ⋯ on a recording item: Add to project, Copy text, Share, and Delete.
struct PremiumMoreMenu: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var body: some View {
        Menu {
            Menu {
                ForEach(app.store.projects) { p in
                    if transcript.projectId == p.id {
                        Button { } label: { Label(p.name, systemImage: "checkmark") }.disabled(true)
                    } else {
                        Button(p.name) { app.addToProject([transcript.id], p.id) }
                    }
                }
                if !app.store.projects.isEmpty { Divider() }
                Button { app.newProjectFor = transcript.id } label: { Label("New project…", systemImage: "folder.badge.plus") }
            } label: { Label("Add to project", systemImage: "folder.badge.plus") }
            if transcript.status == .ready {
                Button { app.copyText(transcript) } label: { Label("Copy text", systemImage: "doc.on.doc") }
                Button { app.exportRequest = PhoneExportRequest(ids: [transcript.id]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            }
            if transcript.status == .failed {
                Button { app.retry(transcript) } label: { Label("Retry", systemImage: "arrow.clockwise") }
            }
            Divider()
            Button(role: .destructive) { app.delete([transcript.id]) } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(NativeInk.label)
                .frame(width: 40, height: 38).contentShape(Rectangle())
        }
        .accessibilityLabel("More for \(transcript.title)")
    }
}

// MARK: - The record button

/// The floating record button on Home and Library: the brand persimmon disc in a ring, just above the tab bar's
/// trailing end. A tap starts a voice note; a long press offers Dictate, Live captions, and Import. Hidden while a
/// recording runs (the bar above the tab bar carries it then).
struct PremiumRecordButton: View {
    @EnvironmentObject var app: PhoneState
    /// Where Dictate pushes the dictations list.
    var tab: PhoneState.Tab
    /// The tabs showing the button, for the self-test.
    static var onScreen = Set<PhoneState.Tab>()

    var body: some View {
        Menu {
            // Record as a kind you pick: AutoLabel leaves it, and Run automatically uses it (Templates.swift).
            Section {
                ForEach(RecordingKind.recordChoices) { k in
                    Button { app.requestRecord(kind: k) } label: { Label(k.recordTitle, systemImage: k.nativeSymbol) }
                }
            }
            Button { dictate() } label: { Label("Dictate", systemImage: "text.bubble") }
            Button { app.requestCaptions() } label: { Label("Live captions", systemImage: "captions.bubble") }
            Menu {
                Button { app.showPhotoPicker = true } label: { Label("Choose from Photos", systemImage: "photo") }
                Button { app.showImporter = true } label: { Label("Choose files…", systemImage: "folder") }
                Button { app.showLinkSheet = true } label: { Label("Paste a link", systemImage: "link") }
            } label: { Label("Import", systemImage: "square.and.arrow.down") }
        } label: {
            Circle().fill(PremiumStyle.disc)
                .frame(width: 64, height: 64)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1).padding(1).blendMode(.overlay))
                .padding(5)
                .background(PremiumStyle.ring, in: Circle())
                .shadow(color: PremiumStyle.discShadow, radius: 12, y: 8)
                .contentShape(Circle())
        } primaryAction: {
            app.requestRecord()
        }
        .accessibilityLabel("Record")
        .accessibilityHint("Starts a voice note. Touch and hold to record a meeting or another kind, or for Dictate, Live captions, and Import.")
        .accessibilityAction(named: "Record a meeting") { app.requestRecord(kind: .meeting) }
        .accessibilityIdentifier("premium.record")
        .accessibilityAction(named: "Dictate") { dictate() }
        .accessibilityAction(named: "Live captions") { app.requestCaptions() }
        .accessibilityAction(named: "Import") { app.showImporter = true }
        .onAppear { Self.onScreen.insert(tab) }
        .onDisappear { Self.onScreen.remove(tab) }
    }

    private func dictate() {
        if tab == .library { app.libraryPath.append(DictationsRoute()) } else { app.homePath.append(DictationsRoute()) }
    }
}

extension View {
    /// The floating record button over a root screen (Home, Library), unless a recording is running.
    func premiumRecordButton(_ tab: PhoneState.Tab) -> some View { modifier(PremiumRecordButtonLayer(tab: tab)) }
}

private struct PremiumRecordButtonLayer: ViewModifier {
    @EnvironmentObject var app: PhoneState
    var tab: PhoneState.Tab
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if !app.recordingActive {
                PremiumRecordButton(tab: tab).padding(.trailing, 18).padding(.bottom, 12)
            }
        }
    }
}

// MARK: - Small pieces

/// A capsule tag (the Note kind, a topic): gray, or the soft accent with the accent's text.
struct PremiumTag: View {
    var text: String
    var symbol: String? = nil
    var accent = false
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13)) }
            Text(text)
        }
        .font(.system(size: 15, weight: accent ? .semibold : .regular))
        .foregroundStyle(accent ? NativeInk.accent : NativeInk.label)
        .padding(.horizontal, 12).frame(minHeight: 30)
        .background(accent ? PremiumInk.accentSoft : NativeInk.fill, in: Capsule())
    }
}
