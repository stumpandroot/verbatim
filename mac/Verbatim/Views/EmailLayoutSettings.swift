import SwiftUI

/// Settings › Dictation › Style for each kind of app: how email is laid out, with a live before and after of a
/// sample email. The formatting itself is `DictationFormatter` (greeting, sign-off, and paragraphs).
struct EmailLayoutRows: View {
    @AppStorage(DictationFormatter.EmailPrefs.ownLinesKey) private var ownLines = true
    @AppStorage(DictationFormatter.EmailPrefs.paragraphsKey) private var paragraphs = DictationFormatter.Paragraphs.email.rawValue
    @AppStorage(YouProfile.nameKey) private var storedName = ""

    var body: some View {
        Group {
            SettingsToggleRow("dictate.emailLines", isOn: $ownLines)
            SettingsRow("dictate.emailParagraphs", stacked: true) {
                Picker("Paragraphs", selection: $paragraphs) {
                    Text("Short").tag(DictationFormatter.Paragraphs.short.rawValue)
                    Text("Normal").tag(DictationFormatter.Paragraphs.email.rawValue)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                preview
            }
        }
    }

    /// Your first name, so the sample signs off the way you would.
    private var first: String {
        let name = YouProfile.displayName(storedName)
        let f = name.split(separator: " ").first.map(String.init) ?? ""
        return f.isEmpty || name == "You" ? "Alex" : f
    }

    private var sample: String {
        "Hi Sarah, how are you? I wanted to check on the March invoice before it goes to accounting. It looks like the total is off by about $200, probably the extra shoot day. Also, can we move Thursday's call to Friday morning? Let me know what works. Thanks, \(first)"
    }

    private var formatted: String {
        DictationFormatter.format(sample, DictationFormatter.EmailPrefs.options(
            ownLines: ownLines, short: paragraphs == DictationFormatter.Paragraphs.short.rawValue, signer: [first]))
    }

    private var preview: some View {
        HStack(alignment: .top, spacing: 12) {
            pane("You say", sample)
            pane("Verbose writes", formatted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sample email, before and after")
    }

    private func pane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.mute)
            Text(text).font(.system(size: 12)).foregroundStyle(Refined.ink).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.button).fill(Refined.neutral))
    }
}
