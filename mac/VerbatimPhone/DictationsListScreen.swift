import SwiftUI

/// Pushed onto the Library stack to open the Dictations list.
struct DictationsRoute: Hashable {}

/// The Library's top card: every press-and-hold dictation, behind one row.
struct DictationsCard: View {
    var dictations: [Transcript]
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.persimmonTint)
                IconGlyph(art: .iconDictations, size: 22, color: Ink.ink)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Dictations").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text("\(dictations.count)").font(Ink.mono(12.5)).foregroundStyle(Ink.mute)
                }
                if let latest = dictations.first {
                    Text(Self.firstWords(latest)).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.mute)
        }
        .padding(12)
        .cardSurface(radius: 14)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictations, \(dictations.count)")
        .accessibilityHint("Opens every dictation")
    }

    static func firstWords(_ t: Transcript) -> String {
        let text = t.segments.map(\.text).joined(separator: " ")
        let words = (text.isEmpty ? t.title : text).split(separator: " ")
        return words.prefix(10).joined(separator: " ") + (words.count > 10 ? "…" : "")
    }
}

/// Every dictation, newest first, searchable. Same rows and actions as the Library.
struct DictationsListScreen: View {
    @EnvironmentObject var app: PhoneState
    @State private var search = ""

    private var items: [Transcript] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return app.store.live
            .filter { $0.isDictation && (q.isEmpty || $0.title.lowercased().contains(q) || app.store.searchText($0).contains(q)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        let items = self.items
        List {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if search.isEmpty { IconPlate(art: .iconDictations, size: 96) } else { EmptyStateArt(art: .search, tint: Ink.butterTint) }
                    Text(search.isEmpty ? "No dictations yet." : "Nothing matches “\(search)”.").font(.system(size: 15)).foregroundStyle(Ink.dim)
                }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(items) { t in
                Button { app.libraryPath.append(t.id) } label: { PhoneRow(transcript: t) }
                    .buttonStyle(SoftPress())
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .contextMenu { RowActions(transcript: t) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { app.delete([t.id]) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { app.togglePin(t.id) } label: { Label(t.pinned ? "Unpin" : "Pin", systemImage: "pin") }.tint(Ink.sageText)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle("Dictations")
        .searchable(text: $search, prompt: "Find a dictation")
    }
}
