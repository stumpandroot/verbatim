import SwiftUI

/// Settings › Snippets: say a trigger while dictating and its saved text goes in instead. The same list as the
/// Mac's (synced through iCloud with the Dictionary), and the Verbatim keyboard's Snippets chip inserts them too.
struct SnippetsScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        List {
            Section {
                TextField("Trigger (my address)", text: $trigger)
                    .textInputAutocapitalization(.never)
                TextField("Text it inserts", text: $expansion, axis: .vertical)
                    .lineLimit(1...4)
                Button("Add") {
                    let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                    let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, !e.isEmpty else { return }
                    app.store.snippets.append(Snippet(trigger: t, expansion: e))
                    trigger = ""; expansion = ""
                }
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Add a snippet")
            } footer: {
                Text("Say the trigger on its own to insert just the text, or inside a sentence to swap it in.")
            }
            Section("Snippets") {
                if app.store.snippets.isEmpty {
                    Text("No snippets yet.").foregroundStyle(Ink.mute)
                }
                ForEach(app.store.snippets) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.trigger).font(.system(size: 16, weight: .semibold))
                        Text(s.expansion).font(.system(size: 13)).foregroundStyle(Ink.mute).lineLimit(3)
                    }
                    .accessibilityElement(children: .combine)
                }
                .onDelete { idx in app.store.snippets.remove(atOffsets: idx) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Snippets")
    }
}
