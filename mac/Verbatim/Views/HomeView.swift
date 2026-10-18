import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Home (BRAND_GUIDE §09A): one editorial headline, one capture bar with Record as the primary action,
/// three compact method cards that do real things, and recent work as document rows.
/// The most expressive screen in the app, and still a working surface: recent work is reachable without
/// scrolling past branding in a typical window.
struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead.staggerIn(0)

                Group {
                    if app.recorder.isRecording { RecordPanel() }
                    else if app.capture.isCapturing { CapturePanel() }
                    else { CaptureBar() }
                }
                .padding(.top, 20).staggerIn(1)
                .animation(Motion.settle, value: app.recorder.isRecording)
                .animation(Motion.settle, value: app.capture.isCapturing)
                if app.captureMode == "dictate" && !app.recorder.isRecording && !app.capture.isCapturing {
                    // Dictate's details drop down under the bar; click Dictate again (or ×) to close.
                    HStack(alignment: .top) {
                        DictateControls()
                        Spacer()
                        Button { withAnimation(Motion.settle) { app.captureMode = "voice" } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.mute).frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain).hoverChip(radius: 13).help("Close").accessibilityLabel("Close Dictate")
                    }
                    .padding(14)
                    .cardSurface(radius: 14)
                    .padding(.top, 8)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }

                MethodCards().padding(.top, 30).staggerIn(2)
                RecentWork().padding(.top, 30).staggerIn(3)
            }
            .frame(maxWidth: 1040)
            .padding(.horizontal, 32).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Overline(text: "Verbatim / Ideas in order", color: Ink.dim)
                DottedRule().frame(height: 1)
                Overline(text: Self.today, color: Ink.mute)
            }
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        Text("Words worth keeping.").font(Ink.serif(46)).fixedSize()
                        Text("Words worth keeping.").font(Ink.serif(36)).fixedSize()
                        Text("Words worth\nkeeping.").font(Ink.serif(34)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                    Text("Capture what was said. Make it readable. Find what matters.")
                        .font(.system(size: 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // The process, as a small editorial index (wide windows only).
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(["Capture.", "Refine.", "Understand."], id: \.self) { Overline(text: $0, color: Ink.mute) }
                    }
                    .padding(.leading, 16)
                    .overlay(alignment: .leading) { Rectangle().fill(Ink.hairline).frame(width: 1) }
                    .fixedSize()
                    EmptyView()
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.top, 22)
    }

    private static var today: String {
        Formats.pattern("EEE d MMM").string(from: Date())
    }
}

/// Capture / Refine / Understand: flat color, the kit's diagrams, and a real action each.
struct MethodCards: View {
    @EnvironmentObject var app: AppState
    /// The diagrams move gently, as on iPhone (AnimatedFeatureArt: still with Limit animation or Reduce Motion, paused
    /// off screen or when Verbatim isn't active, 30 fps). Still during the screenshot tour, so captures are repeatable.
    private let animated = ProcessInfo.processInfo.environment["VERBATIM_UITEST"] != "1"
    var body: some View {
        let live = app.store.live
        let latest = live.first { $0.status == .ready && !$0.segments.isEmpty }
        let moments = live.reduce(0) { $0 + $1.notes.filter { $0.at != nil }.count }
        VStack(alignment: .leading, spacing: 14) {
            EditorialSectionHeader(index: "01", label: "Method")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)], alignment: .leading, spacing: 14) {
                BrandFeatureCard(feature: .capture, line: "Record, dictate, or import a file or link.",
                                 meta: live.count == 1 ? "1 transcript" : "\(live.count) transcripts", animated: animated) { app.requestRecord() }
                    .uiTarget("card-capture")
                BrandFeatureCard(feature: .refine, line: "Clean up a transcript. The original stays.",
                                 meta: latest.map { "Latest: \($0.title)" } ?? "Nothing to refine yet", enabled: latest != nil, animated: animated) {
                    guard let t = latest else { return }
                    app.go(.transcript(t.id))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .verbatimShowMode, object: "Document") }
                }
                BrandFeatureCard(feature: .understand, line: "Find what matters: moments, links, and search.",
                                 meta: moments == 1 ? "1 saved moment" : "\(moments) saved moments", animated: animated) { app.go(.moments) }
            }
        }
    }
}

// MARK: - Recent work

/// Recent transcripts as document rows: title, source, duration, state, date.
struct RecentWork: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let items = Array(app.archive.prefix(6))
        VStack(alignment: .leading, spacing: 14) {
            EditorialSectionHeader(index: "02", label: "Recent", title: "Pick up where you left off.") {
                InlineLink(title: "View library") { app.go(.library) }
            }
            if items.isEmpty {
                empty
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                        DocumentRow(transcript: t) { app.go(.transcript(t.id)) }
                            .uiTarget(i == 0 ? "row-0" : "row-\(i)")
                    }
                }
            }
        }
        .animation(Motion.settle, value: items.map(\.id))
    }

    private var empty: some View {
        HStack(spacing: 16) {
            EmptyStateArt(art: app.search.isEmpty ? .capture : .search, tint: app.search.isEmpty ? Ink.persimmonTint : Ink.butterTint)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.search.isEmpty ? "Record something new." : "Nothing found for “\(app.search)”").font(Ink.serif(21)).foregroundStyle(Ink.ink)
                Text(app.search.isEmpty ? "Recordings and imports land here, ready to review. Dictations live in Dictations." : "Search looks at titles and every transcript's text.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim)
            }
            Spacer()
            if app.search.isEmpty {
                Button("Record") { app.requestRecord() }.buttonStyle(.brandPrimaryLarge)
            }
        }
        .padding(20)
        .background(NoteCardBackground(hover: false))
    }
}
