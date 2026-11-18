import SwiftUI
import AppKit

// Quick actions on the Mac (DESIGN.md §6.9; mockup "Verbose quick actions", November 17, 2026, Mac header): up to
// three actions under a transcript's meta line, in your order, and Edit quick actions, which chooses them and holds
// your prompt for an assistant. The list and its rules are `QuickActions` and `AIHandoff` (Export/ExportCore.swift,
// tested by tools/test-export.sh). The iPhone's row is VerbatimPhone/QuickActions.swift.

/// The shown actions and the prompt, kept on this Mac.
@MainActor
final class QuickActionsStore: ObservableObject {
    static let shared = QuickActionsStore()
    @Published var shown: [QuickAction] {
        didSet { UserDefaults.standard.set(QuickActions.encode(shown), forKey: QuickActions.key) }
    }
    @Published var prompt: String {
        didSet { UserDefaults.standard.set(prompt, forKey: QuickActions.promptKey) }
    }

    private init() {
        shown = QuickActions.decode(UserDefaults.standard.string(forKey: QuickActions.key))
        prompt = UserDefaults.standard.string(forKey: QuickActions.promptKey) ?? ""
    }

    /// What Copy for AI copies and Open in sends: your prompt, when there is one, over the transcript and its header.
    func textForAI(_ t: Transcript) -> String { QuickActions.withPrompt(prompt, t.copyForAI) }
}

extension QuickAction {
    var art: BrandArt {
        switch self {
        case .copyForAI: return .iconCopy
        case .sendToAI, .openInClaude, .openInChatGPT: return .iconShare
        case .export: return .iconExport
        case .copyText: return .iconNotes
        case .copyTimestamps: return .iconRecent
        }
    }

    /// The button's tooltip on the Mac.
    var macHelp: String {
        switch self {
        case .copyForAI: return "Copy the text with its title, date, and source for an AI assistant (⌥⇧⌘C)"
        case .copyText: return "Copy the tab you're reading (⇧⌘C)"
        default: return detail
        }
    }
}

// MARK: - Open in an assistant

/// Open in Claude and Open in ChatGPT. Claude's app takes a short transcript in its link, so it arrives in a new chat.
/// Anything longer, and everything for ChatGPT, is copied, then the app opens (or its website, without the app) for
/// you to paste. The transcript never goes into a web address.
@MainActor
enum OpenInAssistant {
    enum Assistant {
        case claude, chatGPT
        var name: String { self == .claude ? "Claude" : "ChatGPT" }
        var web: URL { URL(string: self == .claude ? "https://claude.ai/new" : "https://chatgpt.com/")! }
        /// The Mac app, when it's installed.
        var installedApp: URL? {
            switch self {
            case .claude: return URL(string: "claude://claude.ai/new").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            case .chatGPT: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat")
            }
        }
    }

    static func open(_ a: Assistant, _ t: Transcript, app: AppState) {
        guard t.status == .ready else { return }
        let text = QuickActionsStore.shared.textForAI(t)
        let installed = a.installedApp
        if a == .claude, installed != nil, let link = AIHandoff.claudeLink(text), NSWorkspace.shared.open(link) {
            app.toast = Toast("Opened in Claude")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if let installed {
            NSWorkspace.shared.openApplication(at: installed, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            NSWorkspace.shared.open(a.web)
        }
        app.toast = Toast("Copied. Paste it into \(a.name) with ⌘V.")
    }
}

// MARK: - The row

/// The row under a transcript's meta line: the shown actions as the kit's buttons (the first one strong), then Edit.
/// It wraps onto a second line in a narrow window.
struct QuickActionsRow: View {
    @Environment(AppState.self) var app
    var transcript: Transcript
    /// The tab's text, for Copy text and Copy with timestamps.
    var copyVersion: Exporter.CopyVersion
    @ObservedObject private var store = QuickActionsStore.shared
    @State private var editing = false
    /// This row's place in `rows`.
    @State private var token = UUID()
    /// The rows on screen, by row (a view being left can disappear after the next one appears), for the self-test.
    private static var rows: [UUID: [QuickAction]] = [:]
    static var onScreen: [QuickAction] { rows.count == 1 ? rows.values.first ?? [] : [] }
    static var rowsOnScreen: Int { rows.count }

    var body: some View {
        FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(Array(store.shown.enumerated()), id: \.element) { i, a in
                Button { run(a) } label: {
                    HStack(spacing: 6) {
                        IconGlyph(art: a.art, size: 15, color: i == 0 ? Refined.paper : Refined.ink)
                            .accessibilityHidden(true)
                        Text(a.title)
                    }
                }
                .buttonStyle(RefinedActionStyle(kind: i == 0 ? .strong : .quiet))
                .help(a.macHelp)
                .uiTarget("quick-action-\(a.rawValue)")
            }
            Button { editing = true } label: {
                IconGlyph(art: .iconFeedback, size: 15, color: Refined.ink)
            }
            .buttonStyle(RefinedActionStyle())
            .help("Edit quick actions")
            .accessibilityLabel("Edit quick actions")
            .uiTarget("quick-action-edit")
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                EditQuickActionsView(onDone: { editing = false })
                    .frame(width: 380)
            }
        }
        .onAppear { Self.rows[token] = store.shown }
        .onChange(of: store.shown) { _, now in Self.rows[token] = now }
        .onDisappear { Self.rows[token] = nil }
    }

    private func run(_ a: QuickAction) {
        switch a {
        case .copyForAI: CopyForAI.copy(transcript, app: app)
        case .openInClaude: OpenInAssistant.open(.claude, transcript, app: app)
        case .openInChatGPT: OpenInAssistant.open(.chatGPT, transcript, app: app)
        case .export: app.exportRequest = ExportRequest(ids: [transcript.id])
        case .copyText: ExportMenu.copy(transcript, copyVersion, app: app)
        case .copyTimestamps: ExportMenu.copy(transcript, copyVersion, timestamps: true, app: app)
        // The iPhone's action (QuickActions.catalog): never stored or offered on the Mac.
        case .sendToAI: break
        }
    }
}

// MARK: - Edit quick actions

/// Edit quick actions: Edit Home's list. Check to show (three at most), drag the shown ones to reorder, and write
/// your prompt. Two ways in: the row's Edit button shows it in a popover with Done (`onDone`), and Settings › Watched
/// folders and export › Transcript quick actions shows the same.
struct EditQuickActionsView: View {
    var onDone: (() -> Void)? = nil
    @ObservedObject private var store = QuickActionsStore.shared
    /// Whether it's on screen, for the self-test.
    static var visible = false

    var body: some View {
        let shown = store.shown
        let hidden = QuickActions.hidden(shown)
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick actions").refinedFont(.sectionTitle).foregroundStyle(Refined.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Up to three show under a transcript's title. Check to show. Drag to reorder.")
                .refinedFont(.meta).foregroundStyle(Refined.dim)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(shown) { a in row(a, on: true, canAdd: true) }
                    .onMove { from, to in store.shown = QuickActions.moving(shown, from: from, to: to) }
                ForEach(hidden) { a in row(a, on: false, canAdd: QuickActions.canAdd(shown)) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(shown.count + hidden.count) * 38 + 6)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt for AI").refinedFont(.rowTitle).foregroundStyle(Refined.ink)
                TextField("Summarize this and list the action items.", text: $store.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .accessibilityLabel("Prompt for AI")
                Text("Goes above the transcript in Copy for AI, Open in Claude, and Open in ChatGPT. Leave it empty to send the transcript alone.")
                    .refinedFont(.meta).foregroundStyle(Refined.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onDone {
                HStack(spacing: 10) {
                    Button("Done") { onDone() }
                        .buttonStyle(RefinedActionStyle(kind: .strong))
                        .keyboardShortcut(.defaultAction)
                        .uiTarget("quick-actions-done")
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(20)
        .background(Refined.paper)
        .onAppear { Self.visible = true }
        .onDisappear { Self.visible = false }
    }

    private func row(_ a: QuickAction, on: Bool, canAdd: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.caption.weight(.semibold))
                .foregroundStyle(Refined.faint)
                .opacity(on ? 1 : 0)
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { on },
                                 set: { now in store.shown = now ? QuickActions.adding(a, to: store.shown) : QuickActions.removing(a, from: store.shown) })) {
                Text(a.title).refinedFont(.rowTitle).foregroundStyle(on || canAdd ? Refined.ink : Refined.dim).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .tint(Refined.accentText)
            .disabled(!on && !canAdd)
            .accessibilityHint(on ? "Hides it from the transcript." : (canAdd ? "Shows it under the transcript's title." : "Three are shown. Hide one to add another."))
            Spacer(minLength: 6)
        }
        .frame(height: 30)
        .help(a.detail)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Refined.separator)
        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .moveDisabled(!on)
    }
}
