import SwiftUI

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    init(_ message: String, action: String? = nil, onAction: (() -> Void)? = nil) {
        self.message = message; self.action = action; self.onAction = onAction
    }
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// The toast at the window's foot: it slides up and fades in, and fades out (as the iPhone's does from the top). The
/// container stays, so whoever sets `app.toast`, with or without an animation, the toast animates; Limit animation
/// fades it both ways.
struct ToastView: View {
    @Environment(AppState.self) var app
    @Environment(\.limitMotion) private var limitMotion
    var body: some View {
        ZStack { toast }
            .animation(limitMotion ? Motion.fade : Motion.settle, value: app.toast)
    }

    private var transition: AnyTransition {
        limitMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
    }

    @ViewBuilder private var toast: some View {
        if let t = app.toast {
            HStack(spacing: 14) {
                Text(t.message).font(.system(size: 13)).lineLimit(2)
                if let a = t.action {
                    // A small outlined action in paper on the toast's ink (the refined kit, DESIGN.md §13).
                    Button { t.onAction?(); app.toast = nil } label: {
                        Text(a).font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.paper)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 12).frame(height: 28)
                            .overlay(Capsule().strokeBorder(Refined.paper, lineWidth: 1.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Refined.ink, in: RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous))
            .foregroundStyle(Refined.paper)
            .frame(maxWidth: 520)
            .padding(.bottom, 24)
            .transition(transition)
            .task(id: t.id) {
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                if app.toast == t { app.toast = nil }
            }
        }
    }
}
