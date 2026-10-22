import SwiftUI
import AppKit

/// The Cleaned tab: paragraphs, no timecodes, editable, with Harper underlines and Apple-model Clean up and Tone.
/// Clean up and Tone always start from the corrected lines (Transcript.cleanupBase); the Original is never changed.
struct DocumentView: View {
    @EnvironmentObject var app: AppState
    var transcript: Transcript
    @State private var lints: [Harper.Lint] = []
    @State private var ignored: Set<String> = []
    @State private var working: Double? = nil
    @State private var proofread = true
    @State private var lintTask: Task<Void, Never>? = nil
    /// A Clean up or Tone waiting on "Re-running Clean up replaces your edits" (only asked when you've typed).
    @State private var pendingRun: (level: Polish.Level, tone: Polish.Tone)? = nil

    private var text: String { transcript.documentText }
    /// Lints computed for exactly this text. After Clean up, Accept all, Undo, or typing, the old lints are
    /// dropped until Harper re-runs, so the editor never applies stale positions.
    private var currentLints: [Harper.Lint] { Self.matching(lints, text: text) }
    private static func matching(_ all: [Harper.Lint], text: String) -> [Harper.Lint] { all.filter { $0.source == text } }
    private var level: Polish.Level { Polish.Level(rawValue: transcript.documentLevel) ?? .none }
    private var tone: Polish.Tone { Polish.Tone(rawValue: transcript.documentTone) ?? .spoken }

    var body: some View {
        // The document text (built from every segment when there's no edited copy) and its lints, once per render.
        let text = self.text
        let current = Self.matching(lints, text: text)
        VStack(alignment: .leading, spacing: 14) {
            toolbar(current)
            if let by = transcript.cleanedBy {
                VStack(alignment: .leading, spacing: 4) {
                    CleanedLabel(source: by)
                    if by == .model { AIGeneratedNote() }
                }
                .frame(maxWidth: 720, alignment: .leading)
            }
            DocumentEditor(text: text, lints: proofread ? current : [], onEdit: { new in commit(new, history: false) }, onAccept: accept, onIgnore: ignore)
                .frame(maxWidth: 720)
        }
        .onAppear(perform: relint)
        .onChange(of: transcript.document) { _, _ in relint() }
        .onChange(of: proofread) { _, on in if on { relint() } }
        .confirmationDialog("Replace your edits?", isPresented: Binding(get: { pendingRun != nil }, set: { if !$0 { pendingRun = nil } })) {
            Button("Clean up") { if let p = pendingRun { pendingRun = nil; start(level: p.level, tone: p.tone) } }
            Button("Cancel", role: .cancel) { pendingRun = nil }
        } message: {
            Text("Re-running Clean up replaces your edits to the Cleaned text. Undo brings them back.")
        }
    }

    // MARK: Toolbar

    private func toolbar(_ currentLints: [Harper.Lint]) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: $proofread) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text("Proofread")
                    if proofread && !currentLints.isEmpty { Text("\(currentLints.count)").foregroundStyle(Ink.mute) }
                }
            }
            .toggleStyle(ToolChip())
            .help("Underline spelling and grammar (Harper, offline)")

            Menu {
                ForEach(Polish.Level.allCases) { l in
                    Button { run(level: l, tone: tone) } label: { HStack { Text(l.rawValue); Text("· " + l.note).foregroundStyle(.secondary) } }
                }
            } label: { Text(level == .none ? "Clean up" : "Clean up · \(level.rawValue)") }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .help("Rewrite the corrected lines with Apple's on-device model. Your Original stays as it is.")

            Menu {
                ForEach(Polish.Tone.allCases) { t in Button(t.rawValue) { run(level: level == .none ? .light : level, tone: t) } }
            } label: { Text(tone == .spoken ? "Tone" : "Tone · \(tone.rawValue)") }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()

            if let w = working {
                ProgressView(value: w).progressViewStyle(.linear).frame(width: 90).controlSize(.small)
            }
            Spacer(minLength: 8)
            if proofread, !currentLints.isEmpty {
                Button("Accept all") { acceptAll() }.buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.iris)
            }
            Button("Undo") { undo() }.buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(transcript.documentHistory.isEmpty ? Ink.mute : Ink.iris).disabled(transcript.documentHistory.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            if transcript.document != nil {
                Button("Reset") { reset() }.buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.mute)
                    .help("Back to the corrected lines from Original")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        // Opaque: text never sits on a blur (DESIGN.md §5.1).
        .background(Ink.bar, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Ink.hairline))
        .frame(maxWidth: 720)
    }

    // MARK: Actions

    private func relint() {
        lintTask?.cancel()
        let t = text
        let ignore = Set(transcript.speakers.map(\.label)).union(app.store.dictionary.map(\.preferred)).union(ignored)
        lintTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 450_000_000)   // settle after typing
            guard !Task.isCancelled else { return }
            let result = Harper.lint(t, ignore: ignore)
            await MainActor.run { if !Task.isCancelled { lints = result } }
        }
    }

    private func commit(_ new: String, history: Bool) {
        guard new != text else { return }
        if history {
            // Harper's fixes: rules, kept in history.
            app.store.update(transcript.id) { $0.applyRuleFixes(new) }
        } else {
            // Typing: the fixes in it can become Dictionary suggestions (EditSessions).
            EditSessions.shared.typed(transcript.id, before: text, after: new)
            app.store.updateDeferred(transcript.id) { $0.typeInCleaned(new) }
        }
    }

    private func accept(_ lint: Harper.Lint) {
        guard let fix = lint.fix, lint.source == text else { return }
        let ns = text as NSString
        guard NSMaxRange(lint.nsRange) <= ns.length else { return }
        commit(ns.replacingCharacters(in: lint.nsRange, with: fix), history: true)
    }

    private func ignore(_ lint: Harper.Lint) {
        if lint.isSpelling { ignored.insert(lint.original.lowercased()) }
        lints.removeAll { $0.id == lint.id }
    }

    private func acceptAll() {
        let base = text
        var ns = base as NSString
        var lastStart = Int.max
        // Back to front so earlier ranges stay valid; skip overlaps.
        for l in currentLints.sorted(by: { $0.nsRange.location > $1.nsRange.location }) {
            guard let fix = l.fix, NSMaxRange(l.nsRange) <= lastStart, NSMaxRange(l.nsRange) <= ns.length else { continue }
            ns = ns.replacingCharacters(in: l.nsRange, with: fix) as NSString
            lastStart = l.nsRange.location
        }
        commit(ns as String, history: true)
        lints = []
        Sounds.done()
    }

    private func undo() {
        app.store.update(transcript.id) { $0.undoDocument() }
    }

    private func reset() {
        app.store.update(transcript.id) { $0.resetCleaned() }
    }

    private func run(level: Polish.Level, tone: Polish.Tone) {
        guard working == nil else { return }   // one polish at a time
        if transcript.documentEdited, transcript.document != nil { pendingRun = (level, tone); return }
        start(level: level, tone: tone)
    }

    private func start(level: Polish.Level, tone: Polish.Tone) {
        guard working == nil else { return }
        switch Polish.status {
        case .ready: break
        case .needsMacOS26: app.toast = Toast("Clean up and Tone use Apple's on-device model, which needs macOS 26."); return
        case .appleIntelligenceOff: app.toast = Toast("Turn on Apple Intelligence in System Settings to use Clean up and Tone."); return
        case .unavailable(let r): app.toast = Toast("Apple's model isn't available: \(r)"); return
        }
        let base = transcript.cleanupBase   // always from the corrected lines, never from an earlier cleanup
        let paras = DocumentText.paragraphs(base)
        let id = transcript.id
        working = 0
        Task {
            do {
                let out = try await Polish.rewrite(paras, level: level, tone: tone) { p in Task { @MainActor in working = p } }
                let joined = out.joined(separator: "\n\n")
                // Every level runs the model, None included, so the result is always marked as Apple Intelligence's.
                app.store.update(id) { $0.applyCleanup(joined, level: level.rawValue, tone: tone.rawValue, byModel: true) }
                Sounds.done()
            } catch {
                app.toast = Toast(error.localizedDescription)
            }
            working = nil
        }
    }
}

/// Chip-style toggle for the document toolbar.
struct ToolChip: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label.font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(configuration.isOn ? Ink.irisDeep : Ink.ink)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(configuration.isOn ? Ink.wash : .clear, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor (NSTextView with lint underlines and a popover per lint)

struct DocumentEditor: NSViewRepresentable {
    var text: String
    var lints: [Harper.Lint]
    var onEdit: (String) -> Void
    var onAccept: (Harper.Lint) -> Void
    var onIgnore: (Harper.Lint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = LintTextView()
        tv.isEditable = true; tv.isRichText = false; tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false   // Harper underlines instead
        tv.font = NSFont.systemFont(ofSize: 16)
        tv.textColor = NSColor(Ink.ink)
        tv.backgroundColor = .clear; tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.linkTextAttributes = [:]
        let sv = NSScrollView()
        sv.documentView = tv; sv.hasVerticalScroller = false; sv.drawsBackground = false
        tv.autoresizingMask = [.width]; tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        context.coordinator.textView = tv
        context.coordinator.apply(text: text, lints: lints)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(text: text, lints: lints)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = nsView.documentView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let w = proposal.width ?? 720
        tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return CGSize(width: w, height: lm.usedRect(for: tc).height + 12)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentEditor
        weak var textView: NSTextView?
        private var lastText = ""
        private var lastLintKey = ""
        var lints: [Harper.Lint] = []
        private var editing = false
        private var popover: NSPopover?
        init(_ p: DocumentEditor) { parent = p }

        func apply(text: String, lints: [Harper.Lint]) {
            guard let tv = textView else { return }
            self.lints = lints
            let lints = lints.filter { $0.source == text }
            self.lints = lints
            let key = lints.map { "\($0.id):\($0.nsRange.location)" }.joined(separator: ",")
            guard !editing, (text != lastText || key != lastLintKey) else { return }
            lastText = text; lastLintKey = key
            let sel = tv.selectedRanges
            let para = NSMutableParagraphStyle(); para.lineSpacing = 6; para.paragraphSpacing = 0
            let attr = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(Ink.ink), .paragraphStyle: para])
            let ns = text as NSString
            // Blank lines between paragraphs render as a short gap, not a full line.
            let small = NSFont.systemFont(ofSize: 7)
            var k = 1
            while k < ns.length {
                if ns.character(at: k) == 10, ns.character(at: k - 1) == 10 { attr.addAttribute(.font, value: small, range: NSRange(location: k, length: 1)) }
                k += 1
            }
            // Speaker labels at paragraph starts
            var loc = 0
            for p in text.components(separatedBy: "\n\n") {
                if let colon = p.range(of: ": "), p.distance(from: p.startIndex, to: colon.lowerBound) <= 48 {
                    let len = p.distance(from: p.startIndex, to: colon.lowerBound)
                    attr.addAttributes([.font: NSFont.systemFont(ofSize: 14.5, weight: .semibold), .foregroundColor: NSColor(Ink.iris)], range: NSRange(location: loc, length: min((p as NSString).length, len + 1)))
                }
                loc += (p as NSString).length + 2
            }
            for l in lints {
                let r = l.nsRange
                guard r.location >= 0, NSMaxRange(r) <= ns.length else { continue }
                let color = l.isSpelling ? NSColor(Ink.danger) : NSColor(Ink.iris)
                attr.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: color,
                                    .link: URL(string: "verbatim-lint://\(l.id)")!, .cursor: NSCursor.pointingHand], range: r)
            }
            tv.textStorage?.setAttributedString(attr)
            tv.selectedRanges = sel
            tv.invalidateIntrinsicContentSize()
        }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            editing = true
            lastText = tv.string
            parent.onEdit(tv.string)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.editing = false }
        }

        func textView(_ tv: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "verbatim-lint", let id = Int(url.host ?? ""), let l = lints.first(where: { $0.id == id }) else { return false }
            show(l, in: tv, at: index)
            return true
        }

        private func show(_ l: Harper.Lint, in tv: NSTextView, at index: Int) {
            popover?.close()
            let r = l.nsRange
            guard l.source == tv.string, NSMaxRange(r) <= (tv.string as NSString).length, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            var rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
            rect.origin.x += tv.textContainerOrigin.x; rect.origin.y += tv.textContainerOrigin.y
            let p = NSPopover()
            p.behavior = .transient
            p.contentViewController = NSHostingController(rootView: LintPopover(lint: l, accept: { [weak self] in p.close(); self?.parent.onAccept(l) }, ignore: { [weak self] in p.close(); self?.parent.onIgnore(l) }))
            p.show(relativeTo: rect, of: tv, preferredEdge: .maxY)
            popover = p
        }
    }
}

final class LintTextView: NSTextView {
    weak var coordinator: DocumentEditor.Coordinator?
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: lm.usedRect(for: tc).height + textContainerInset.height * 2)
    }
}

struct LintPopover: View {
    var lint: Harper.Lint
    var accept: () -> Void
    var ignore: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(lint.kind) · Harper").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(lint.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if let fix = lint.fix {
                HStack(spacing: 6) {
                    Text(lint.original).strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    Text(fix.isEmpty ? "(remove)" : fix).fontWeight(.semibold)
                }
                .font(.system(size: 13))
            }
            HStack(spacing: 8) {
                if lint.fix != nil { Button("Accept", action: accept).buttonStyle(.brandPrimary).keyboardShortcut(.defaultAction) }
                Button("Ignore", action: ignore).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(width: 260, alignment: .leading)
    }
}
