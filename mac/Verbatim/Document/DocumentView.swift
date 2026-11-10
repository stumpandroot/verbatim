import SwiftUI
import AppKit

/// The Cleaned tab: paragraphs, no timecodes, editable, with Harper underlines and Apple-model Clean up and Tone.
/// Clean up and Tone always start from the corrected lines (Transcript.cleanupBase); the Original is never changed.
struct DocumentView: View {
    @Environment(AppState.self) var app
    var transcript: Transcript
    @State private var lints: [Harper.Lint] = []
    @State private var ignored: Set<String> = []
    @State private var working: Double? = nil
    @State private var proofread = true
    @State private var lintTask: Task<Void, Never>? = nil
    /// A Clean up or Tone waiting on "Re-running Clean up replaces your edits" (only asked when you've typed).
    @State private var pendingRun: (level: Polish.Level, tone: Polish.Tone)? = nil
    /// The window's: ⌘Z (Edit › Undo) undoes the last Clean up, Tone, fix, or Reset, and ⇧⌘Z redoes it (MAC-01). Typing in
    /// the editor goes on the same stack (NSTextView's own undo), so ⌘Z walks back through both in order.
    @Environment(\.undoManager) private var undoManager
    /// ⌘F's find bar on this tab (Views/TranscriptFind.swift): it finds in the text below, and the editor marks the
    /// matches (MAC-22 follow-up).
    @ObservedObject private var find = TranscriptFind.shared

    /// Kept until the transcript changes (Store+Memo.swift): a render, one after a keystroke included, doesn't build it
    /// again from every line.
    private var text: String { app.store.documentText(transcript.id) ?? transcript.documentText }
    /// Lints computed for exactly this text. After Clean up, Accept all, Undo, or typing, the old lints are
    /// dropped until Harper re-runs, so the editor never applies stale positions.
    private var currentLints: [Harper.Lint] { Self.matching(lints, text: text) }
    /// The lints made from exactly `text`. One Harper run's lints all hold the same source string, so the text is
    /// compared once for the lot, not once per lint (each comparison can read the whole text).
    nonisolated static func matching(_ all: [Harper.Lint], text: String) -> [Harper.Lint] {
        guard let first = all.first else { return [] }
        if all.allSatisfy({ $0.source == first.source }) { return first.source == text ? all : [] }
        return all.filter { $0.source == text }
    }
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
            DocumentEditor(text: text, speakers: DocumentText.labelNames(transcript), lints: proofread ? current : [],
                           find: find.shows(on: .cleaned) ? findMarks : nil,
                           onEdit: { new in commit(new, history: false) }, onAccept: accept, onIgnore: ignore)
                .frame(maxWidth: 720)
        }
        // The find bar searches the text as it stands, and again as you type.
        .onChange(of: find.shows(on: .cleaned) ? text : nil, initial: true) { _, t in
            if let t { find.setTexts([t]) }
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

    /// The find bar's matches in the text, and the current one.
    private var findMarks: DocumentEditor.FindMarks {
        DocumentEditor.FindMarks(matches: find.matches.map(\.range), current: find.currentMatch?.range)
    }

    // MARK: Toolbar

    /// Proofread as a refined chip, Clean up and Tone as menu faces, and Accept all, Undo, and Reset as refined
    /// actions at the end (DESIGN.md §13). Sits on the page: no box, no hairline. No control
    /// sits under a parent gesture (macOS 26). At the Mac's smallest window with the inspector open, nothing is cut to
    /// "Pı" or "U" (MAC-04): the full row when it fits, then Accept all, Undo, and Reset on a second line, then those
    /// three in a labeled More menu. Every control keeps its natural width.
    private func toolbar(_ currentLints: [Harper.Lint]) -> some View {
        let canUndo = !transcript.documentHistory.isEmpty
        let canAccept = proofread && !currentLints.isEmpty
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                leadingControls(currentLints)
                Spacer(minLength: 8)
                actions(canAccept: canAccept, canUndo: canUndo)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { leadingControls(currentLints) }
                HStack(spacing: 8) { actions(canAccept: canAccept, canUndo: canUndo) }
            }
            HStack(spacing: 8) {
                leadingControls(currentLints)
                Spacer(minLength: 8)
                moreMenu(canAccept: canAccept, canUndo: canUndo)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    /// Proofread, Clean up, Tone, and the progress while one runs.
    @ViewBuilder private func leadingControls(_ currentLints: [Harper.Lint]) -> some View {
        ProofreadChip(on: proofread, count: proofread && !currentLints.isEmpty ? currentLints.count : nil) { proofread.toggle() }
            .fixedSize()
            .help("Underline spelling and grammar (Harper, offline)")

        Menu {
            ForEach(Polish.Level.allCases) { l in
                Button { run(level: l, tone: tone) } label: { HStack { Text(l.rawValue); Text("· " + l.note) } }
            }
        } label: {
            RefinedMenuLabel(title: level == .none ? "Clean up" : "Clean up · \(level.rawValue)")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Rewrite the corrected lines with Apple's on-device model. Your Original stays as it is.")
        .accessibilityLabel("Clean up").accessibilityValue(level.rawValue)

        Menu {
            ForEach(Polish.Tone.allCases) { t in Button(t.rawValue) { run(level: level == .none ? .light : level, tone: t) } }
        } label: {
            RefinedMenuLabel(title: tone == .spoken ? "Tone" : "Tone · \(tone.rawValue)")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Tone").accessibilityValue(tone.rawValue)

        if let w = working {
            ProgressView(value: w).progressViewStyle(.linear).frame(width: 90).controlSize(.small).tint(Refined.accentText)
                .accessibilityLabel("Cleaning up")
        }
    }

    /// Accept all (while there are suggestions), Undo, and Reset (once the text differs from the corrected lines).
    @ViewBuilder private func actions(canAccept: Bool, canUndo: Bool) -> some View {
        if canAccept {
            Button("Accept all") { acceptAll() }
                .buttonStyle(RefinedActionStyle(kind: .strong)).fixedSize()
                .accessibilityHint("Applies every spelling and grammar fix.")
        }
        Button("Undo") { undo() }
            .buttonStyle(RefinedActionStyle(kind: .quiet)).fixedSize()
            .disabled(!canUndo)
            .accessibilityHint("Brings back the Cleaned text before the last change.")
            .help("Undo the last Clean up, Tone, or fix (⌘Z)")
        if transcript.document != nil {
            Button("Reset") { reset() }
                .buttonStyle(RefinedActionStyle(kind: .quiet)).fixedSize()
                .help("Back to the corrected lines from Original")
        }
    }

    /// The narrowest fit: the same three actions in a menu named More.
    private func moreMenu(canAccept: Bool, canUndo: Bool) -> some View {
        Menu {
            if canAccept { Button("Accept all") { acceptAll() } }
            Button("Undo") { undo() }.disabled(!canUndo)
            if transcript.document != nil { Button("Reset") { reset() } }
        } label: {
            RefinedMenuLabel(title: "More")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Accept all, Undo, and Reset")
        .accessibilityLabel("More actions")
        .uiTarget("cleaned-more")
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

    private func commit(_ new: String, history: Bool, name: String = CleanedUndo.fix) {
        guard new != text else { return }
        if history {
            // Harper's fixes: rules, kept in history, and on the window's Undo.
            app.store.update(transcript.id) { $0.applyRuleFixes(new) }
            CleanedUndo.registered(undoManager, id: transcript.id, store: app.store, name: name)
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
        commit(ns as String, history: true, name: CleanedUndo.acceptAll)
        lints = []
    }

    /// The Undo button: the same step as ⌘Z when the window's last undo is one of the Cleaned tab's, so the two never
    /// disagree; otherwise the Cleaned history's last step, with Redo after it.
    private func undo() {
        if let um = undoManager, um.canUndo, CleanedUndo.names.contains(um.undoActionName) { um.undo(); return }
        CleanedUndo.undo(undoManager, id: transcript.id, store: app.store, name: CleanedUndo.fix)
    }

    private func reset() {
        app.store.update(transcript.id) { $0.resetCleaned() }
        CleanedUndo.registered(undoManager, id: transcript.id, store: app.store, name: CleanedUndo.reset)
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
        let undoManager = self.undoManager
        working = 0
        Task {
            do {
                let out = try await Polish.rewrite(paras, level: level, tone: tone, speakers: speakers) { p in Task { @MainActor in working = p } }
                let joined = out.joined(separator: "\n\n")
                // Every level runs the model, None included, so the result is always marked as Apple Intelligence's.
                app.store.update(id) { $0.applyCleanup(joined, level: level.rawValue, tone: tone.rawValue, byModel: true) }
                CleanedUndo.registered(undoManager, id: id, store: app.store, name: tone == .spoken ? CleanedUndo.cleanUp : CleanedUndo.tone)
            } catch {
                app.toast = Toast(error.localizedDescription)
            }
            working = nil
        }
    }
}

/// The Cleaned tab's history on the window's UndoManager (MAC-01): each Clean up, Tone, fix, Accept all, or Reset
/// registers an undo, so Edit › Undo (⌘Z) brings back the text before it and Edit › Redo (⇧⌘Z) puts the change back.
/// The history itself is the transcript's (`documentHistory`, Model/CleanedLayer.swift), so it survives a relaunch
/// and the iPhone's Undo reads the same steps.
enum CleanedUndo {
    static let cleanUp = "Clean Up", tone = "Tone", fix = "Fix", acceptAll = "Accept All", reset = "Reset"
    /// The action names Edit › Undo shows ("Undo Clean Up").
    static let names: Set<String> = [cleanUp, tone, fix, acceptAll, reset]

    /// A change that pushed the history: register its undo.
    @MainActor static func registered(_ um: UndoManager?, id: UUID, store: Store, name: String) {
        guard let um else { return }
        um.registerUndo(withTarget: store) { store in MainActor.assumeIsolated { undo(um, id: id, store: store, name: name) } }
        um.setActionName(name)
    }

    /// Undo: the previous Cleaned text, and a Redo that puts this one back.
    @MainActor static func undo(_ um: UndoManager?, id: UUID, store: Store, name: String) {
        guard let before = store.transcript(id)?.cleanedSnapshot, !(store.transcript(id)?.documentHistory.isEmpty ?? true) else { return }
        store.update(id) { $0.undoDocument() }
        guard let um else { return }
        um.registerUndo(withTarget: store) { store in MainActor.assumeIsolated { redo(um, id: id, store: store, snapshot: before, name: name) } }
        um.setActionName(name)
    }

    /// Redo: the change again, and its undo again.
    @MainActor private static func redo(_ um: UndoManager, id: UUID, store: Store, snapshot: Transcript.CleanedSnapshot, name: String) {
        guard store.transcript(id) != nil else { return }
        store.update(id) { $0.redoDocument(snapshot) }
        registered(um, id: id, store: store, name: name)
    }
}

/// Proofread as a refined chip: the persimmon tint when on, with the number of suggestions.
private struct ProofreadChip: View {
    var on: Bool
    var count: Int?
    var action: () -> Void
    var body: some View {
        RefinedChip(title: count.map { "Proofread · \($0)" } ?? "Proofread", selected: on, action: action)
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
    /// ⌘F's matches, drawn as marks over the text (the layout manager's temporary attributes, so they never touch the
    /// text, its undo, or its lints): butter with ink on it, and the current one underlined and scrolled into view.
    var find: FindMarks? = nil
    var onEdit: (String) -> Void

    struct FindMarks: Equatable {
        var matches: [NSRange]
        var current: NSRange?
    }
    var onAccept: (Harper.Lint) -> Void
    var onIgnore: (Harper.Lint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = LintTextView()
        tv.isEditable = true; tv.isRichText = false; tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false   // Harper underlines instead
        tv.font = NSFont.systemFont(ofSize: 16)
        tv.textColor = NSColor(Refined.ink)
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
        context.coordinator.applyFind(find)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(text: text, lints: lints)
        context.coordinator.applyFind(find)
    }

    /// SwiftUI asks for a size many times per pass, often at the same width: each width's height is measured once per
    /// change to the editor's text (a layout of the whole Cleaned text), then reused until the text changes again.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = nsView.documentView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let w = proposal.width ?? 720
        if tc.containerSize.width != w { tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude) }
        let length = tv.textStorage?.length ?? 0
        if let h = context.coordinator.measuredHeight(width: w, length: length) { return CGSize(width: w, height: h) }
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + 12
        context.coordinator.remember(height: h, width: w, length: length)
        return CGSize(width: w, height: h)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentEditor
        weak var textView: NSTextView?
        private var lastText = ""
        private var lastLintKey = ""
        var lints: [Harper.Lint] = []
        private var editing = false
        private var popover: NSPopover?
        /// The find marks last drawn, and the match last scrolled to; nil after the text is replaced, so they draw again.
        private var drawnFind: FindMarks?
        private var revealed: NSRange?
        /// Bumped whenever the editor's text or its styling changes (`apply`, typing): the heights measured for the
        /// last version, by width, and the text length they were measured at.
        private var textVersion = 0
        private var heights: [CGFloat: CGFloat] = [:]
        private var heightsVersion = -1
        private var heightsLength = -1
        init(_ p: DocumentEditor) { parent = p }

        /// The height measured at `width` for the editor's text as it stands, if there is one.
        func measuredHeight(width: CGFloat, length: Int) -> CGFloat? {
            guard heightsVersion == textVersion, heightsLength == length else { return nil }
            return heights[width]
        }

        func remember(height: CGFloat, width: CGFloat, length: Int) {
            if heightsVersion != textVersion || heightsLength != length {
                heights.removeAll(keepingCapacity: true)
                heightsVersion = textVersion; heightsLength = length
            }
            heights[width] = height
        }

        /// Draws the find bar's marks: every match in butter with ink on it, the current one underlined (never color
        /// alone), as temporary attributes; scrolls to the current match when it changes. Clears them when the bar
        /// closes. Positions are the text's, so nothing draws while the editor's text differs from it (mid-typing).
        func applyFind(_ find: FindMarks?) {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            guard find != drawnFind else { return }
            let length = (tv.string as NSString).length
            let all = NSRange(location: 0, length: length)
            for key in [NSAttributedString.Key.backgroundColor, .foregroundColor, .underlineStyle, .underlineColor] {
                lm.removeTemporaryAttribute(key, forCharacterRange: all)
            }
            guard let find else { drawnFind = nil; revealed = nil; return }
            // Mid-typing the editor runs ahead of the text the matches came from: draw once they agree.
            guard tv.string == parent.text else { drawnFind = nil; return }
            drawnFind = find
            let fill = NSColor(Refined.badge(.butter)), ink = NSColor(Refined.onFill)
            for r in find.matches where NSMaxRange(r) <= length {
                lm.addTemporaryAttributes([.backgroundColor: fill, .foregroundColor: ink], forCharacterRange: r)
            }
            if let c = find.current, NSMaxRange(c) <= length {
                lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: ink], forCharacterRange: c)
                if c != revealed { revealed = c; (tv as? LintTextView)?.reveal(c) }
            } else {
                revealed = nil
            }
        }

        func apply(text: String, lints: [Harper.Lint]) {
            guard let tv = textView else { return }
            let lints = DocumentView.matching(lints, text: text)
            self.lints = lints
            let key = lints.map { "\($0.id):\($0.nsRange.location)" }.joined(separator: ",") + "|" + parent.speakers.joined(separator: ",")
            guard !editing, (text != lastText || key != lastLintKey) else { return }
            lastText = text; lastLintKey = key
            let sel = tv.selectedRanges
            let para = NSMutableParagraphStyle(); para.lineSpacing = 6; para.paragraphSpacing = 0
            let attr = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(Refined.ink), .paragraphStyle: para])
            let ns = text as NSString
            // Blank lines between paragraphs render as a short gap, not a full line.
            let small = NSFont.systemFont(ofSize: 7)
            var k = 1
            while k < ns.length {
                if ns.character(at: k) == 10, ns.character(at: k - 1) == 10 { attr.addAttribute(.font, value: small, range: NSRange(location: k, length: 1)) }
                k += 1
            }
            // Speaker labels at paragraph starts: only real speaker names (any "Word:" isn't a label), in SF Pro
            // semibold ink. Mono is for shortcuts, timecodes, and indexes, never names (DESIGN.md §2; review M-25).
            var loc = 0
            let speakers = parent.speakers
            let labelFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
            for p in text.components(separatedBy: "\n\n") {
                if !speakers.isEmpty, let name = DocumentText.split(p, speakers: speakers).speaker {
                    let len = (name as NSString).length + 1
                    attr.addAttributes([.font: labelFont, .foregroundColor: NSColor(Refined.ink)], range: NSRange(location: loc, length: min((p as NSString).length, len)))
                }
                loc += (p as NSString).length + 2
            }
            for l in lints {
                let r = l.nsRange
                guard r.location >= 0, NSMaxRange(r) <= ns.length else { continue }
                let color = l.isSpelling ? NSColor(Refined.accentText) : NSColor(Refined.sageText)
                attr.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: color,
                                    .link: URL(string: "verbatim-lint://\(l.id)")!, .cursor: NSCursor.pointingHand], range: r)
            }
            tv.textStorage?.setAttributedString(attr)
            textVersion &+= 1
            tv.selectedRanges = sel
            tv.invalidateIntrinsicContentSize()
            drawnFind = nil   // the find marks go with the old text; they draw again on the new one
        }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            editing = true
            textVersion &+= 1
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
    /// The find bar's current match is being brought into view (its field has the focus, not the editor).
    private var revealing = false
    override func scrollRangeToVisible(_ range: NSRange) {
        guard editingHere || revealing else { return }
        super.scrollRangeToVisible(range)
    }
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        guard editingHere || revealing else { return false }
        return super.scrollToVisible(rect)
    }
    /// Scrolls the transcript so `range` shows: the find bar's current match (⌘G is a key, so it doesn't animate).
    func reveal(_ range: NSRange) {
        revealing = true
        defer { revealing = false }
        scrollRangeToVisible(range)
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
            Text("\(lint.kind) · Harper").refinedFont(.caption).foregroundStyle(Refined.mute)
            Text(lint.message).refinedFont(.hint).foregroundStyle(Refined.ink).fixedSize(horizontal: false, vertical: true)
            if let fix = lint.fix {
                HStack(spacing: 6) {
                    Text(lint.original).strikethrough().foregroundStyle(Refined.mute)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Refined.mute)
                    Text(fix.isEmpty ? "(remove)" : fix).fontWeight(.semibold).foregroundStyle(Refined.ink)
                }
                .font(.system(size: 13))
            }
            HStack(spacing: 8) {
                if lint.fix != nil { Button("Accept", action: accept).buttonStyle(RefinedActionStyle(kind: .strong)).keyboardShortcut(.defaultAction) }
                Button("Ignore", action: ignore).buttonStyle(RefinedActionStyle(kind: .quiet))
            }
        }
        .padding(14).frame(width: 260, alignment: .leading).background(Refined.paper)
    }
}
