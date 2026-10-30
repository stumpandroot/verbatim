import SwiftUI
import UIKit

/// The Original as one selectable text ("Select text"): drag the handles across lines, then Copy. Read-only, no
/// keyboard. Turn it off to get back to the lines (bookmarks, notes, Copy quote).
struct PhoneSelectableText: UIViewRepresentable {
    var text: String

    /// "00:12  text" per line, speaker names where the speaker changes, a blank line between speakers.
    static func joined(_ segments: [Segment], in t: Transcript) -> String {
        let multi = t.speakers.count >= 2
        var out = ""
        for (i, s) in segments.enumerated() {
            let changed = multi && s.speaker != nil && (i == 0 || segments[i - 1].speaker != s.speaker)
            if i > 0 { out += changed ? "\n\n" : "\n" }
            if changed, let name = t.speakerName(s.speaker) { out += name + "\n" }
            out += s.start.timecode + "  " + s.text
        }
        return out
    }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        v.textContainer.lineFragmentPadding = 0
        v.adjustsFontForContentSizeCategory = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: v)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { apply(to: v) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? UIScreen.main.bounds.width - 40
        let size = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: size.height)
    }

    private func apply(to v: UITextView) {
        let para = NSMutableParagraphStyle(); para.lineSpacing = 4
        v.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor(Refined.ink),
            .paragraphStyle: para,
        ])
    }
}
