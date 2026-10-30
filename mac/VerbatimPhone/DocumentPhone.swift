import SwiftUI

/// The Cleaned tab on iPhone: editable paragraphs (no timecodes), Harper's spelling and grammar suggestions, and
/// Clean up and Tone with Apple's on-device model. Same data as the Mac's Cleaned tab, so edits and cleanup sync
/// both ways. Clean up and Tone always start from the corrected lines, never from the cleaned text. On the refined kit
/// (DESIGN.md §13) in both look settings: menu faces for Clean up and Tone, the text on a card, and the kit's actions.
struct PhoneDocument: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    @State private var text = ""
    @State private var lints: [Harper.Lint] = []
    @State private var ignored: Set<String> = []
    @State private var showLints = false
    @State private var working: Double? = nil
    @State private var loaded = false
    /// A Clean up or Tone waiting on "Re-running Clean up replaces your edits" (only asked when you've typed).
    @State private var pendingRun: (level: Polish.Level, tone: Polish.Tone)? = nil
    @State private var confirmReset = false

    private var level: Polish.Level { Polish.Level(rawValue: transcript.documentLevel) ?? .none }
    private var tone: Polish.Tone { Polish.Tone(rawValue: transcript.documentTone) ?? .spoken }
    private var visibleLints: [Harper.Lint] { lints.filter { $0.source == text && !ignored.contains($0.original) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Polish.Level.allCases) { l in
                        Button { run(level: l, tone: tone) } label: { Text("\(l.rawValue) · \(l.note)") }
                    }
                } label: { RefinedMenuLabel(title: Self.cleanUpLabel(level)) }
                .buttonStyle(.plain)
                Menu {
                    ForEach(Polish.Tone.allCases) { t in Button(t.rawValue) { run(level: level == .none ? .light : level, tone: t) } }
                } label: { RefinedMenuLabel(title: "Tone · \(tone.rawValue)") }
                .buttonStyle(.plain)
                Spacer()
                circle("arrow.uturn.backward", label: "Undo") { undo() }
                    .disabled(transcript.documentHistory.isEmpty)
                    .opacity(transcript.documentHistory.isEmpty ? 0.45 : 1)
                circle("arrow.counterclockwise", label: "Reset to the corrected lines") { confirmReset = true }
                    .disabled(transcript.document == nil)
                    .opacity(transcript.document == nil ? 0.45 : 1)
            }
            if let by = transcript.cleanedBy {
                VStack(alignment: .leading, spacing: 4) {
                    CleanedLabel(source: by)
                    if by == .model { AIGeneratedNote() }
                }
            }
            if let w = working {
                HStack(spacing: 10) { ProgressView(value: w).tint(Refined.accentText); Text("Cleaning up \(Int(w * 100))%").refinedFont(.meta).monospacedDigit().foregroundStyle(Refined.mute) }
            }
            if !visibleLints.isEmpty {
                Button { showLints = true } label: {
                    HStack(spacing: 12) {
                        IconSquare(art: .iconApplyDictionary, hue: .petal)
                        Text("\(visibleLints.count) suggestion\(visibleLints.count == 1 ? "" : "s")").refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.faint)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                    .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RefinedPress())
            }
            TextEditor(text: $text)
                .refinedFont(.reading).foregroundStyle(Refined.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 420)
                .padding(10)
                .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
                .onChange(of: text) { _, v in
                    // Compared with the stored text (not this view's copy), so a Clean up or Undo landing here isn't
                    // mistaken for typing.
                    let stored = app.store.transcript(transcript.id)?.documentText ?? transcript.documentText
                    guard loaded, v != stored else { return }
                    EditSessions.shared.typed(transcript.id, before: stored, after: v)
                    app.store.updateDeferred(transcript.id) { $0.typeInCleaned(v) }
                    relint()
                }
            Text("Clean up and Tone start from the corrected lines in Original, which stay as they are. They run on this iPhone with Apple Intelligence (iOS 26).")
                .refinedFont(.meta).foregroundStyle(Refined.mute)
            if let notice = Polish.status.polishNotice {
                Text(notice)
                    .refinedFont(.meta).foregroundStyle(Refined.accentText)
            }
        }
        .onAppear { text = transcript.documentText; loaded = true; relint() }
        .onChange(of: transcript.document) { _, _ in
            // Another device (or a polish) changed the document: show it.
            if transcript.documentText != text { text = transcript.documentText; relint() }
        }
        .confirmationDialog("Replace your edits?", isPresented: Binding(get: { pendingRun != nil }, set: { if !$0 { pendingRun = nil } }), titleVisibility: .visible) {
            Button("Clean up") { if let p = pendingRun { pendingRun = nil; start(level: p.level, tone: p.tone) } }
            Button("Cancel", role: .cancel) { pendingRun = nil }
        } message: {
            Text("Re-running Clean up replaces your edits to the Cleaned text. Undo brings them back.")
        }
        .confirmationDialog("Reset the Cleaned text?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset") { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Cleaned text goes back to the corrected lines from Original. Undo brings it back.")
        }
        .sheet(isPresented: $showLints) {
            NavigationStack {
                List {
                    ForEach(visibleLints) { l in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(l.original).strikethrough(l.fix != nil).foregroundStyle(Refined.mute)
                                if let f = l.fix {
                                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Refined.mute)
                                    Text(f.isEmpty ? "remove" : f).fontWeight(.semibold).foregroundStyle(Refined.ink)
                                }
                            }
                            Text(l.message).refinedFont(.meta).foregroundStyle(Refined.dim)
                            HStack {
                                if l.fix != nil { Button("Accept") { accept(l) }.buttonStyle(RefinedActionStyle(kind: .strong)) }
                                Button("Ignore") { ignored.insert(l.original) }.buttonStyle(RefinedActionStyle(kind: .quiet))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Refined.card)
                }
                .scrollContentBackground(.hidden)
                .background(Refined.paper.ignoresSafeArea())
                .navigationTitle("Suggestions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Accept all") { acceptAll(); showLints = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// "Clean up" while it's off; "Clean up · Light" once a level is set.
    static func cleanUpLabel(_ level: Polish.Level) -> String {
        level == .none ? "Clean up" : "Clean up · \(level.rawValue)"
    }

    /// Undo or Reset: the glyph on the neutral wash in a circle, 44 pt to tap.
    private func circle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Refined.ink)
                .frame(width: 36, height: 36)
                .background(Refined.neutral, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(RefinedPress())
        .accessibilityLabel(label)
    }

    private func relint() {
        let t = text
        let ignore = Set(transcript.speakers.map(\.label) + app.store.dictionary.map(\.preferred))
        Task.detached(priority: .utility) {
            let result = Harper.available ? Harper.lint(t, ignore: ignore) : []
            await MainActor.run { if t == text { lints = result } }
        }
    }

    private func replace(_ l: Harper.Lint, in s: String) -> String {
        guard let fix = l.fix, l.source == s else { return s }
        return (s as NSString).replacingCharacters(in: l.nsRange, with: fix)
    }

    private func accept(_ l: Harper.Lint) {
        let new = replace(l, in: text)
        save(new)
    }

    private func acceptAll() {
        var s = text
        for l in visibleLints.filter({ $0.fix != nil }).sorted(by: { $0.nsRange.location > $1.nsRange.location }) {
            guard let fix = l.fix else { continue }
            s = (s as NSString).replacingCharacters(in: l.nsRange, with: fix)
        }
        save(s)
    }

    /// Harper's fixes: rules, kept in history.
    private func save(_ s: String) {
        app.store.update(transcript.id) { $0.applyRuleFixes(s) }
        text = s; relint()
    }

    private func undo() {
        app.store.update(transcript.id) { $0.undoDocument() }
        text = app.store.transcript(transcript.id)?.documentText ?? text
        relint()
    }

    private func reset() {
        app.store.update(transcript.id) { $0.resetCleaned() }
        text = app.store.transcript(transcript.id)?.documentText ?? text
        relint()
    }

    private func run(level: Polish.Level, tone: Polish.Tone) {
        // Base iPhone 15, Apple Intelligence off, or the model still downloading: say why instead of doing nothing.
        if let notice = Polish.status.polishNotice { app.say(notice); return }
        guard working == nil else { return }
        if transcript.documentEdited, transcript.document != nil { pendingRun = (level, tone); return }
        start(level: level, tone: tone)
    }

    private func start(level: Polish.Level, tone: Polish.Tone) {
        guard working == nil else { return }
        // Always from the corrected lines, never from the cleaned text, so running it twice doesn't compound.
        let paras = DocumentText.paragraphs(transcript.cleanupBase)
        let speakers = DocumentText.labelNames(transcript)
        working = 0
        Task {
            do {
                let out = try await Polish.rewrite(paras, level: level, tone: tone, speakers: speakers) { p in Task { @MainActor in working = p } }
                let joined = out.joined(separator: "\n\n")
                // Every level runs the model, None included, so the result is always marked as Apple Intelligence's.
                app.store.update(transcript.id) { $0.applyCleanup(joined, level: level.rawValue, tone: tone.rawValue, byModel: true) }
                text = joined; relint()
            } catch {
                app.say(error.localizedDescription)
            }
            working = nil
        }
    }
}
