import AppKit
import SwiftUI

/// One piece of the thought pad: something you dictated (or a paste that had nowhere to land).
struct PadPiece: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var seconds: Double = 0
    var missed = false
    var createdAt = Date()
}

/// The thought pad's contents, kept on this Mac between launches.
@MainActor
final class ThoughtPad: ObservableObject {
    static let shared = ThoughtPad()
    @Published var title: String { didSet { save() } }
    @Published var pieces: [PadPiece] { didSet { save() } }
    private let file = Paths.local.appendingPathComponent(ProcessInfo.processInfo.environment["VERBATIM_UITEST"] == "1" ? "thoughtpad-uitest.json" : "thoughtpad.json")

    private struct Saved: Codable { var title: String; var pieces: [PadPiece] }

    private init() {
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            title = s.title; pieces = s.pieces
        } else { title = ""; pieces = [] }
    }

    func add(_ text: String, seconds: Double = 0, missed: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        pieces.append(PadPiece(text: t, seconds: seconds, missed: missed))
    }

    func clear() { pieces = []; title = "" }

    /// Every piece in order, a blank line between them.
    var joined: String { pieces.map(\.text).joined(separator: "\n\n") }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.local, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Saved(title: title, pieces: pieces)) { try? data.write(to: file, options: .atomic) }
    }
}

/// The floating thought pad window. It never makes Verbatim the active app, so the app you were working in
/// stays in front, and "Send" can paste straight into it.
@MainActor
final class ThoughtPadController {
    static let shared = ThoughtPadController()
    weak var dictation: DictationController?
    private var panel: ThoughtPadPanel?

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        if panel == nil { build() }
        guard let p = panel else { return }
        p.orderFrontRegardless()
        p.makeKey()
    }

    func close() { panel?.orderOut(nil) }

    /// When the pad has keyboard focus, gives it back to `app` (the pad stays on screen), so a paste lands there.
    func yieldKeyboard(to app: NSRunningApplication?) {
        guard let p = panel, p.isKeyWindow else { return }
        p.orderOut(nil)
        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { p.orderFrontRegardless() }   // back on screen, not key
    }

    private func build() {
        let size = CGSize(width: 380, height: 540)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let f = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: f.maxX - size.width - 30, y: f.maxY - size.height - 30)
        let p = ThoughtPadPanel(contentRect: NSRect(origin: origin, size: size),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.minSize = CGSize(width: 340, height: 420)
        p.setFrameAutosaveName("VerbatimThoughtPad")
        guard let dictation else { return }
        p.contentView = NSHostingView(rootView: ThoughtPadView(controller: self, dictation: dictation))
        panel = p
    }

    /// Pastes the pad into the app you were using. The pad steps aside first so the keystrokes reach that app.
    func send(_ text: String) {
        let target = NSWorkspace.shared.frontmostApplication
        close()
        target?.activate()   // the pad may have had keyboard focus; make sure the keystrokes reach this app
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            let ctx = AppContext.capture(readText: false)
            let isUs = target?.bundleIdentifier == Bundle.main.bundleIdentifier
            let out: Paster.Outcome
            if isUs { Paster.copy(text); out = .copiedOnly }
            else { out = await Paster.paste(text, into: target, focusedField: ctx.hasFocusedField) }
            dictation?.bar?.flash(out == .pasted ? "Sent to \(target?.localizedName ?? "your app")" : "Copied. Click a text field and press ⌘V.", seconds: 3)
        }
    }
}

final class ThoughtPadPanel: NSPanel {
    override var canBecomeKey: Bool { true }     // you can edit pieces and the title
    override var canBecomeMain: Bool { false }
}

struct ThoughtPadView: View {
    let controller: ThoughtPadController
    @ObservedObject var dictation: DictationController
    @ObservedObject private var pad = ThoughtPad.shared
    @ObservedObject private var flow = FlowSettings.shared
    @State private var editing: PadPiece.ID? = nil
    @State private var actionID: FlowAction.ID? = nil
    @State private var working = false
    @State private var confirmClear = false
    @State private var frontApp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Diamond().stroke(Ink.ink, lineWidth: 1).frame(width: 7, height: 7)
                    Overline(text: "Thought pad", color: Ink.dim)
                    DottedRule().frame(height: 1)
                    Text(pad.pieces.count == 1 ? "1 piece" : "\(pad.pieces.count) pieces").font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.mute)
                }
                HStack {
                    TextField("Untitled", text: $pad.title).textFieldStyle(.plain).font(Ink.serif(22)).foregroundStyle(Ink.ink)
                    if !pad.pieces.isEmpty {
                        Button(confirmClear ? "Clear all?" : "Clear") {
                            if confirmClear { editing = nil; DispatchQueue.main.async { pad.clear() }; confirmClear = false } else {
                                confirmClear = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmClear = false }
                            }
                        }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: confirmClear ? .semibold : .regular))
                        .foregroundStyle(confirmClear ? Ink.accentText : Ink.mute)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 8)

            if pad.pieces.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing here yet").font(Ink.serif(18)).foregroundStyle(Ink.ink)
                    Text("While the pad is open, \(controller.dictation?.hotkey.shortTitle ?? "hold your hotkey") to add a thought instead of pasting it. Or click the microphone.")
                        .font(.system(size: 13)).foregroundStyle(Ink.mute).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18).padding(.top, 8)
                Spacer()
            } else {
                List {
                    ForEach($pad.pieces) { $piece in
                        PadRow(piece: $piece, editing: $editing) {
                            // Let the editor drop its binding first; removing under a focused field can crash.
                            let id = piece.id
                            editing = nil
                            DispatchQueue.main.async { pad.pieces.removeAll { $0.id == id } }
                        }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                    .onMove { pad.pieces.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                Text("Drag to reorder. Click a piece to edit it.").font(.system(size: 11.5)).foregroundStyle(Ink.mute).padding(.horizontal, 18).padding(.bottom, 6)
            }

            bottomBar
        }
        .background(Ink.paper)
        .onAppear(perform: updateFront)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in updateFront() }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button { dictation.barClicked() } label: {
                Image(systemName: dictation.isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15)).foregroundStyle(Ink.inkFixed)
                    .frame(width: 38, height: 38).background(Ink.persimmon, in: Circle())
            }
            .buttonStyle(.plain).help("Dictate a piece")
            Picker("Action", selection: $actionID) {
                Text("As is").tag(FlowAction.ID?.none)
                ForEach(flow.actions) { a in Text(a.name).tag(FlowAction.ID?.some(a.id)) }
            }
            .labelsHidden().pickerStyle(.menu).frame(maxWidth: 140)   // a long action name truncates; it can't push the buttons
            .help("Run a saved action on the whole pad before sending")
            Spacer(minLength: 4)
            if working { ProgressView().controlSize(.small) }
            Button("Copy") { Task { if let t = await result() { Paster.copy(t); controller.dictation?.bar?.flash("Thought pad copied", seconds: 2) } } }
                .buttonStyle(.brandSecondary).disabled(pad.pieces.isEmpty || working).fixedSize()
            Button(frontApp.isEmpty ? "Send" : "Send to \(frontApp)") { Task { if let t = await result() { controller.send(t) } } }
                .buttonStyle(.brandPrimary).disabled(pad.pieces.isEmpty || working)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Ink.bar)
        .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }

    /// The pad's text, through the chosen action if there is one.
    private func result() async -> String? {
        let text = pad.joined
        guard let id = actionID, let action = flow.actions.first(where: { $0.id == id }) else { return text }
        working = true
        defer { working = false }
        if let out = await FlowCleanup.apply(instruction: action.instruction, to: text, kind: action.kind) { return out }
        controller.dictation?.bar?.flash(FlowCleanup.available ? "Couldn't run “\(action.name)”" : "Actions need Apple Intelligence on macOS 26.", seconds: 3)
        return nil
    }

    private func updateFront() {
        let a = NSWorkspace.shared.frontmostApplication
        let full = a?.bundleIdentifier == Bundle.main.bundleIdentifier ? "" : (a?.localizedName ?? "")
        let name = full.count > 14 ? String(full.prefix(13)) + "…" : full
        if name != frontApp { frontApp = name }
    }
}

private struct PadRow: View {
    @Binding var piece: PadPiece
    @Binding var editing: PadPiece.ID?
    var delete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Ink.faint).padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if editing == piece.id {
                    TextEditor(text: $piece.text).font(.system(size: 13.5)).scrollContentBackground(.hidden)
                        .frame(minHeight: 60).focused($focused)
                        .onAppear { focused = true }
                        .onChange(of: focused) { _, f in if !f, editing == piece.id { editing = nil } }
                } else {
                    Text(piece.text).font(.system(size: 13.5)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = piece.id }
                }
                Text(meta).font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.mute)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Ink.reader, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(editing == piece.id ? Ink.outlineStrong : Ink.hairline))
        .contextMenu {
            Button("Edit") { editing = piece.id }
            Button("Copy") { Paster.copy(piece.text) }
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .accessibilityElement(children: editing == piece.id ? .contain : .combine)
    }

    private var meta: String {
        let len = piece.seconds > 0 ? String(format: "%d:%02d · ", Int(piece.seconds) / 60, Int(piece.seconds) % 60) : ""
        let what = len + (piece.missed ? "from a paste that missed" : "dictated")
        return what.prefix(1).uppercased() + what.dropFirst()
    }
}
