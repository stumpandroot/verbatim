import SwiftUI

/// The Document view on iPhone: editable paragraphs (no timecodes), Harper's spelling and grammar
/// suggestions, and Clean up and Tone with Apple's on-device model. Same data as the Mac's Document view,
/// so edits and polish sync both ways.
struct PhoneDocument: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    @State private var text = ""
    @State private var lints: [Harper.Lint] = []
    @State private var ignored: Set<String> = []
    @State private var showLints = false
    @State private var working: Double? = nil
    @State private var loaded = false

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
                } label: { chip("Clean up · \(level.rawValue)", symbol: "sparkles") }
                Menu {
                    ForEach(Polish.Tone.allCases) { t in Button(t.rawValue) { run(level: level == .none ? .light : level, tone: t) } }
                } label: { chip("Tone · \(tone.rawValue)", symbol: "text.quote") }
                Spacer()
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(transcript.documentHistory.isEmpty).foregroundStyle(transcript.documentHistory.isEmpty ? Ink.faint : Ink.ink)
                    .accessibilityLabel("Undo")
            }
            if transcript.document != nil, level != .none { AIGeneratedNote() }
            if let w = working {
                HStack(spacing: 10) { ProgressView(value: w).tint(Ink.persimmon); Text("Cleaning up \(Int(w * 100))%").font(Ink.mono(12)).foregroundStyle(Ink.mute) }
            }
            if !visibleLints.isEmpty {
                Button { showLints = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.badge.checkmark")
                        Text("\(visibleLints.count) suggestion\(visibleLints.count == 1 ? "" : "s")").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }
                    .padding(12)
                }
                .buttonStyle(TactileButtonStyle())
            }
            TextEditor(text: $text)
                .font(.system(size: 17)).lineSpacing(4)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 420)
                .padding(10)
                .background(Ink.reader, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.hairline))
                .onChange(of: text) { _, v in
                    guard loaded, v != transcript.documentText else { return }
                    EditSessions.shared.typed(transcript.id, before: transcript.documentText, after: v)
                    app.store.updateDeferred(transcript.id) { $0.document = v }
                    relint()
                }
            Text("The original transcript is kept. Clean up and Tone run on this iPhone with Apple Intelligence (iOS 26).")
                .font(.system(size: 12.5)).foregroundStyle(Ink.mute)
            if let notice = Polish.status.polishNotice {
                Text(notice)
                    .font(.system(size: 12.5)).foregroundStyle(Ink.accentText)
            }
        }
        .onAppear { text = transcript.documentText; loaded = true; relint() }
        .onChange(of: transcript.document) { _, _ in
            // Another device (or a polish) changed the document: show it.
            if transcript.documentText != text { text = transcript.documentText; relint() }
        }
        .sheet(isPresented: $showLints) {
            NavigationStack {
                List {
                    ForEach(visibleLints) { l in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(l.original).strikethrough(l.fix != nil).foregroundStyle(Ink.mute)
                                if let f = l.fix { Image(systemName: "arrow.right").font(.system(size: 10)); Text(f.isEmpty ? "remove" : f).fontWeight(.semibold) }
                            }
                            Text(l.message).font(.system(size: 13)).foregroundStyle(Ink.dim)
                            HStack {
                                if l.fix != nil { Button("Accept") { accept(l) }.buttonStyle(.brandPrimary) }
                                Button("Ignore") { ignored.insert(l.original) }.buttonStyle(.brandSecondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .navigationTitle("Suggestions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Accept all") { acceptAll(); showLints = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func chip(_ label: String, symbol: String) -> some View {
        Label(label, systemImage: symbol).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Ink.card, in: Capsule()).overlay(Capsule().strokeBorder(Ink.hairline))
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

    private func save(_ s: String) {
        app.store.update(transcript.id) { t in
            t.documentHistory.append(t.documentText); if t.documentHistory.count > 30 { t.documentHistory.removeFirst() }
            t.document = s
        }
        text = s; relint()
    }

    private func undo() {
        app.store.update(transcript.id) { t in
            guard let last = t.documentHistory.popLast() else { return }
            t.document = last
        }
        text = app.store.transcript(transcript.id)?.documentText ?? text
        relint()
    }

    private func run(level: Polish.Level, tone: Polish.Tone) {
        // Base iPhone 15, Apple Intelligence off, or the model still downloading: say why instead of doing nothing.
        if let notice = Polish.status.polishNotice { app.say(notice); return }
        let paras = DocumentText.paragraphs(text)
        working = 0
        Task {
            do {
                let out = try await Polish.rewrite(paras, level: level, tone: tone) { p in Task { @MainActor in working = p } }
                let joined = out.joined(separator: "\n\n")
                app.store.update(transcript.id) { t in
                    t.documentHistory.append(t.documentText); if t.documentHistory.count > 30 { t.documentHistory.removeFirst() }
                    t.document = joined; t.documentLevel = level.rawValue; t.documentTone = tone.rawValue
                }
                text = joined; relint()
            } catch {
                app.say(error.localizedDescription)
            }
            working = nil
        }
    }
}
