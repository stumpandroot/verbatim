import SwiftUI

/// Home: the headline, a raised Record key with Import and Link beside it, the three method cards, and
/// recent work. Whatever you record here shows up on your Mac.
struct HomeScreen: View {
    @EnvironmentObject var app: PhoneState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Overline(text: "Verbatim", color: Ink.dim)
                    DottedRule().frame(height: 1)
                    SyncBadge()
                }
                .padding(.top, 8)
                Text("Words worth keeping.").font(Ink.serif(36)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                    .accessibilityAddTraits(.isHeader)
                Text("Capture what was said. Make it readable. Find what matters.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim).padding(.top, 6)

                capture.padding(.top, 22)

                VStack(alignment: .leading, spacing: 12) {
                    EditorialSectionHeader(index: "01", label: "Method")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) { cards }.padding(.horizontal, 20)
                    }
                    .padding(.horizontal, -20)
                }
                .padding(.top, 28)

                VStack(alignment: .leading, spacing: 12) {
                    EditorialSectionHeader(index: "02", label: "Recent", title: "Pick up where you left off.")
                    let items = Array(app.store.live.prefix(6))
                    if items.isEmpty {
                        HStack(spacing: 14) {
                            EmptyStateArt(art: .capture, tint: Ink.persimmonTint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Record something new.").font(Ink.serif(20)).foregroundStyle(Ink.ink)
                                Text("Recordings and imports land here, and on your Mac.").font(.system(size: 14)).foregroundStyle(Ink.dim)
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.hairline))
                    } else {
                        ForEach(items) { t in
                            Button { app.open(t.id) } label: { PhoneRow(transcript: t) }.buttonStyle(.plain)
                                .contextMenu { RowActions(transcript: t) }
                        }
                        Button { app.tab = .library } label: { HStack { Text("View library"); Image(systemName: "arrow.right") }.font(.system(size: 15, weight: .medium)) }
                            .foregroundStyle(Ink.ink).padding(.top, 4)
                    }
                }
                .padding(.top, 28)
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .background(Ink.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var capture: some View {
        HStack(spacing: 14) {
            VStack(spacing: 8) {
                Button { app.requestRecord() } label: {
                    Circle().fill(Ink.readerFixed).frame(width: 24, height: 24).frame(width: 84, height: 84)
                }
                .buttonStyle(RaisedKeyStyle())
                .accessibilityLabel("Record")
                Text("Record").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
            }
            VStack(spacing: 10) {
                Button { app.showImporter = true } label: {
                    HStack(spacing: 10) {
                        BrandGlyph(art: .document, color: Ink.ink).frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Import").font(.system(size: 15, weight: .semibold))
                            Text("Audio or video files").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                }
                .buttonStyle(TactileButtonStyle())
                Button { app.showLinkSheet = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "link").font(.system(size: 17, weight: .light)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Link").font(.system(size: 15, weight: .semibold))
                            Text("Your Mac fetches it").font(.system(size: 12.5)).foregroundStyle(Ink.mute)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                }
                .buttonStyle(TactileButtonStyle())
            }
        }
        .padding(14)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Ink.hairline))
    }

    @ViewBuilder private var cards: some View {
        let live = app.store.live
        let latest = live.first { $0.status == .ready && !$0.segments.isEmpty }
        let moments = live.reduce(0) { $0 + $1.notes.filter { $0.at != nil }.count }
        BrandFeatureCard(feature: .capture, line: "Record or import a file.", meta: live.count == 1 ? "1 transcript" : "\(live.count) transcripts") { app.requestRecord() }
            .frame(width: 236)
        BrandFeatureCard(feature: .refine, line: "Clean up a transcript. The original stays.", meta: latest.map { "Latest: \($0.title)" } ?? "Nothing to refine yet", enabled: latest != nil) {
            if let t = latest { app.focusSegment = nil; app.homePath.append(DocumentRoute(id: t.id)) }
        }
        .frame(width: 236)
        BrandFeatureCard(feature: .understand, line: "Find what matters: moments and search.", meta: moments == 1 ? "1 saved moment" : "\(moments) saved moments") { app.tab = .moments }
            .frame(width: 236)
    }
}

/// Opens a transcript straight into its Document view.
struct DocumentRoute: Hashable { let id: UUID }

/// "Synced", "iCloud off": the state of sync, in one small label.
struct SyncBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Cloud.enabled ? "icloud" : "icloud.slash").font(.system(size: 11))
            Text(Cloud.enabled ? "iCloud" : "On this iPhone").font(Ink.mono(10.5, weight: .medium)).textCase(.uppercase)
        }
        .foregroundStyle(Ink.mute)
        .accessibilityLabel(Cloud.enabled ? "Syncing with iCloud" : "iCloud is off; saved on this iPhone")
    }
}

/// Long-press actions shared by every list.
struct RowActions: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    var body: some View {
        Button { app.togglePin(transcript.id) } label: { Label(transcript.pinned ? "Unpin" : "Pin", systemImage: transcript.pinned ? "pin.slash" : "pin") }
        if !app.store.projects.isEmpty {
            Menu {
                Button("No project") { app.move(transcript.id, to: nil) }
                ForEach(app.store.projects) { p in Button(p.name) { app.move(transcript.id, to: p.id) } }
            } label: { Label("Move to project", systemImage: "folder") }
        }
        if transcript.status == .ready { Button { app.copyText(transcript) } label: { Label("Copy text", systemImage: "doc.on.doc") } }
        if transcript.status == .failed { Button { app.retry(transcript) } label: { Label("Retry", systemImage: "arrow.clockwise") } }
        if transcript.status == .processing, transcript.processingDevice == Device.id { Button { app.cancel(transcript.id) } label: { Label("Cancel transcription", systemImage: "xmark") } }
        Divider()
        Button(role: .destructive) { app.delete([transcript.id]) } label: { Label("Delete", systemImage: "trash") }
    }
}

// MARK: - Recording

struct RecordScreen: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Discard", role: .destructive) { app.discardRecording() }.foregroundStyle(Ink.danger)
                Spacer()
                Overline(text: app.recorder.isPaused ? "Paused" : "Recording", color: app.recorder.isPaused ? Ink.mute : Ink.accentText)
            }
            .padding(.horizontal, 20).padding(.top, 12)
            Spacer()
            SignalRings(active: !app.recorder.isPaused).frame(width: 180, height: 180)
            ElapsedLabel(live: app.recorder.live).padding(.top, 28)
            PhoneMeter(live: app.recorder.live).padding(.top, 18)
            Spacer()
            HStack(spacing: 14) {
                Button(app.recorder.isPaused ? "Resume" : "Pause") { app.recorder.togglePause() }
                    .buttonStyle(.brandSecondaryLarge).frame(maxWidth: .infinity)
                Button("Stop and transcribe") { app.stopRecording() }
                    .buttonStyle(.brandPrimaryLarge).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
            Text("Recording keeps going with the screen locked.").font(.system(size: 12.5)).foregroundStyle(Ink.mute).padding(.bottom, 12)
        }
        .background(Ink.paper.ignoresSafeArea())
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }
}

struct LinkSheet: View {
    @EnvironmentObject var app: PhoneState
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste a YouTube, Vimeo, or podcast link. Your Mac fetches the audio and transcribes it; the transcript appears here when it's done.")
                    .font(.system(size: 15)).foregroundStyle(Ink.dim)
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(Ink.mute)
                    TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused)
                }
                .padding(12)
                .background(Ink.reader, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.hairline))
                .shadow(color: Ink.inkFixed.opacity(0.06), radius: 1, y: 1)
                PasteButton(payloadType: String.self) { strings in link = strings.first ?? link }
                    .buttonBorderShape(.capsule).labelStyle(.titleAndIcon)
                if !Cloud.enabled {
                    Label("iCloud is off, so your Mac won't see this until you turn it on.", systemImage: "icloud.slash").font(.system(size: 13)).foregroundStyle(Ink.mute)
                }
                Spacer()
            }
            .padding(20)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("Add a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send to Mac") { app.addLink(link); dismiss() }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
