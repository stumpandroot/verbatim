import SwiftUI

// Pieces of the templates screens shared by the Mac and the iPhone (Model/Templates.swift): each template's icon,
// and a result's sections drawn as headings, paragraphs, bullets, and checklist lines.

extension TranscriptTemplate {
    /// The template's line icon.
    var art: BrandArt {
        switch glyph {
        case TemplateGlyph.plan: return .iconQueue
        case TemplateGlyph.journal, TemplateGlyph.sermon: return .iconNotes
        case TemplateGlyph.draft: return .iconCopy
        case TemplateGlyph.study, TemplateGlyph.lecture: return .iconLibrary
        case TemplateGlyph.keyPoints, TemplateGlyph.interview: return .iconQuote
        case TemplateGlyph.meeting: return .iconSpeakers
        case TemplateGlyph.oneOnOne: return .iconOneOnOne
        case TemplateGlyph.client: return .iconProject
        case TemplateGlyph.brainstorm: return .iconThought
        case TemplateGlyph.reflection: return .iconCalendar
        default: return .iconSummaries
        }
    }
}

/// "Meeting *notes*": a name split before its last word, for titles that set it apart.
enum TemplateTitle {
    static func split(_ name: String) -> (String, String?) {
        let words = name.split(separator: " ")
        guard words.count > 1 else { return (name, nil) }
        return (words.dropLast().joined(separator: " "), String(words.last!))
    }
}

/// A result's text as sections: headings in the display face, then paragraphs, bullets, and checklist lines.
struct TemplateResultBody: View {
    var text: String
    var heading: Font
    var textFont: Font
    var ink: AnyShapeStyle
    var dim: AnyShapeStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(TemplateResultText.blocks(text).enumerated()), id: \.offset) { i, b in
                switch b {
                case .heading(let h):
                    Text(h).font(heading).foregroundStyle(ink)
                        .padding(.top, i == 0 ? 0 : 8)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let p):
                    Text(p).font(textFont).foregroundStyle(ink).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(textFont).foregroundStyle(dim).accessibilityHidden(true)
                        Text(s).font(textFont).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                    }
                case .check(let s, let done):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(dim, lineWidth: 1.3)
                            .frame(width: 12, height: 12)
                            .overlay { if done { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(ink) } }
                            .accessibilityHidden(true)
                        Text(s).font(textFont).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel((done ? "Done: " : "To do: ") + s)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
