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
                    CleanedLabel(source: by, mono: true)
                    if by == .model { AIGeneratedNote() }
                }
                .frame(maxWidth: 720, alignment: .leading)
            }
            DocumentEditor(text: text, speakers: DocumentText.labelNames(transcript), lints: proofread ? current : [],
                           onEdit: { new in commit(new, history: false) }, onAccept: accept, onIgnore: ignore)
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

    /// Proofread as a soft chip, Clean up and Tone as line mini pills with a chevron, and Accept all, Undo, and Reset
    /// as mini pills at the end (DESIGN.md §11). Sits on the page: no box, no hairline. Every control takes clicks
    /// through a direct gesture or a menu, never a Button under a parent gesture (macOS 26).
    private func toolbar(_ currentLints: [Harper.Lint]) -> some View {
        let canUndo = !transcript.documentHistory.isEmpty
        return HStack(spacing: 8) {
            ProofreadChip(on: proofread, count: proofread && !currentLints.isEmpty ? currentLints.count : nil) { proofread.toggle() }
                .help("Underline spelling and grammar (Harper, offline)")

            Menu {
                ForEach(Polish.Level.allCases) { l in
                    Button { run(level: l, tone: tone) } label: { HStack { Text(l.rawValue); Text("· " + l.note).foregroundStyle(.secondary) } }
                }
            } label: {
                PillLabel(title: level == .none ? "Clean up" : "Clean up · \(level.rawValue)", kind: .line, size: .mini, trailing: .chevron)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Rewrite the corrected lines with Apple's on-device model. Your Original stays as it is.")
            .accessibilityLabel("Clean up").accessibilityValue(level.rawValue)

            Menu {
                ForEach(Polish.Tone.allCases) { t in Button(t.rawValue) { run(level: level == .none ? .light : level, tone: t) } }
            } label: {
                PillLabel(title: tone == .spoken ? "Tone" : "Tone · \(tone.rawValue)", kind: .line, size: .mini, trailing: .chevron)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Tone").accessibilityValue(tone.rawValue)

            if let w = working {
                ProgressView(value: w).progressViewStyle(.linear).frame(width: 90).controlSize(.small).tint(Ink.ink)
                    .accessibilityLabel("Cleaning up")
            }
            Spacer(minLength: 8)
            if proofread, !currentLints.isEmpty {
                PillButton(title: "Accept all", kind: .dark, size: .mini, hint: "Applies every spelling and grammar fix") { acceptAll() }
            }
            PillButton(title: "Undo", kind: .line, size: .mini, enabled: canUndo, hint: "Brings back the Cleaned text before the last change") { undo() }
                .help("Undo the last Clean up, Tone, or fix (⇧⌘Z)")
            if transcript.document != nil {
                PillButton(title: "Reset", kind: .line, size: .mini, hint: "Back to the corrected lines from Original") { reset() }
                    .help("Back to the corrected lines from Original")
            }
        }
        .background {
            // ⇧⌘Z for Undo, once, out of sight (the pill takes clicks through its own gesture).
            Button("") { if canUndo { undo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
                .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
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
        let speakers = DocumentText.labelNames(transcript)
        let id = transcript.id
        working = 0
        Task {
            do {
                let out = try await Polish.rewrite(paras, level: level, tone: tone, speakers: speakers) { p in Task { @MainActor in working = p } }
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

/// Proofread as a soft filter chip: ink when on, with the number of suggestions. Clicks through a direct gesture.
private struct ProofreadChip: View {
    var on: Bool
    var count: Int?
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        FilterChipLabel(title: "Proofread", count: count, selected: on, small: true, hover: hover)
            .onHover { hover = $0 }
            .tapArea(action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(count.map { "Proofread, \($0) suggestions" } ?? "Proofread")
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Editor (NSTextView with lint underlines and a popover per lint)

struct DocumentEditor: NSViewRepresentable {
    var text: String
    /// The speaker names paragraphs can start with (`DocumentText.labelNames`). Only these are styled as labels.
    var speakers: [String] = []
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
            let key = lints.map { "\($0.id):\($0.nsRange.location)" }.joined(separator: ",") + "|" + parent.speakers.joined(separator: ",")
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
            // Speaker labels at paragraph starts: only real speaker names (any "Word:" isn't a label), in mono.
            var loc = 0
            let speakers = parent.speakers
            let labelFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            for p in text.components(separatedBy: "\n\n") {
                if !speakers.isEmpty, let name = DocumentText.split(p, speakers: speakers).speaker {
                    let len = (name as NSString).length + 1
                    attr.addAttributes([.font: labelFont, .foregroundColor: NSColor(Ink.dim)], range: NSRange(location: loc, length: min((p as NSString).length, len)))
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

    /// The editor sits inside the transcript's scroll view. AppKit's scroll-to-selection walks up to that outer
    /// scroll view, so replacing the text (Clean up, Undo, a fix) or a layout pass could scroll the whole screen and
    /// push the header (title and Original / Cleaned / Review) under the toolbar. Only scroll while the person is
    /// typing here.
    private var editingHere: Bool { window?.firstResponder === self }
    override func scrollRangeToVisible(_ range: NSRange) {
        guard editingHere else { return }
        super.scrollRangeToVisible(range)
    }
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        guard editingHere else { return false }
        return super.scrollToVisible(rect)
    }
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
