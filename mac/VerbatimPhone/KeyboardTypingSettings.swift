import SwiftUI
import UIKit

// Settings › Dictation and keyboard › Keyboard › Typing (approved mockup "Corrections, suggestions, and accents",
// section 3): Autocorrect, Suggestions, and Languages, read by the keyboard from the App Group (`TypingHelp`). Both
// switches are on by default. The keyboard also follows each app's field settings, so a field that turns off
// autocorrection gets none.

/// The languages the keyboard types in: the keyboards you added in the Settings app that Apple's on-device spell checker
/// supports and a Latin layout can type. The app writes the list to the App Group at launch, each time it becomes active,
/// and when Settings › Keyboard opens, because only the app can read the keyboards list reliably.
enum KeyboardLanguagesMirror {
    /// The keyboards' languages as iOS lists them ("en-US", "es-MX", "emoji"). The Verbose keyboard is one of them and
    /// counts as English (its Info.plist's primary language).
    static var keyboards: [String] { UITextInputMode.activeInputModes.compactMap(\.primaryLanguage) }
    static var available: [String] { UITextChecker.availableLanguages }

    static var supported: [String] { TypingLanguages.keyboardLanguages(keyboards, available: available) }
    static var unsupported: [String] { TypingLanguages.unsupported(keyboards, available: available) }

    static func update() { TypingHelp.writeLanguages(supported, to: KeyboardBridge.defaults) }

    /// "English", "Spanish"; with two of one language, its region too.
    static func names(_ list: [String]) -> [String] {
        list.map { id in
            let code = TypingLanguages.code(id)
            let twice = list.filter { TypingLanguages.code($0) == code }.count > 1
            return (twice ? Locale.current.localizedString(forIdentifier: id) : Locale.current.localizedString(forLanguageCode: code)) ?? id
        }
    }

    /// The Languages row's value and line: "English, Spanish".
    static var summary: String {
        let n = names(supported)
        return n.isEmpty ? "English" : n.joined(separator: ", ")
    }
}

/// The Typing card on Settings › Keyboard: two switches and the Languages row.
struct KeyboardTypingHelpCard: View {
    @AppStorage(TypingHelp.Key.autocorrect, store: KeyboardBridge.defaults) private var autocorrect = true
    @AppStorage(TypingHelp.Key.suggestions, store: KeyboardBridge.defaults) private var suggestions = true
    @State private var summary = KeyboardLanguagesMirror.summary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsPageLabel(text: "Typing")
            VStack(spacing: 0) {
                SettingsToggleRow(title: "Autocorrect",
                                  subtitle: "Fixes a misspelled word when you type a space. Delete puts it back.", isOn: $autocorrect)
                SettingsDivider()
                SettingsToggleRow(title: "Suggestions", subtitle: "Three words above the keys while you type.", isOn: $suggestions)
                SettingsDivider()
                NavigationLink {
                    KeyboardLanguagesScreen()
                } label: {
                    HStack(spacing: 10) {
                        SettingsRowText(title: "Languages", subtitle: "Follows the keyboards in the Settings app: \(summary)", subtitleLines: nil)
                        Spacer(minLength: 8)
                        SettingsChevron()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(SettingsRowPress())
            }
            .cardSurface(radius: RefinedPlatform.radius(.card))
        }
        .onAppear {
            KeyboardLanguagesMirror.update()
            summary = KeyboardLanguagesMirror.summary
        }
    }
}

/// Settings › Keyboard › Languages: the languages the Verbose keyboard types in, each with its letter layout, and the
/// keyboards it can't type yet.
struct KeyboardLanguagesScreen: View {
    @State private var supported = KeyboardLanguagesMirror.supported
    @State private var unsupported = KeyboardLanguagesMirror.unsupported

    var body: some View {
        SettingsPageScaffold(title: "Languages", inline: true) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Corrections, suggestions, and long-press letters work in every language Apple's spell checker supports on this iPhone. The Verbose keyboard follows the keyboards you added in the Settings app.")
                    .scaledFont(16).foregroundStyle(Refined.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                VStack(spacing: 0) {
                    let names = KeyboardLanguagesMirror.names(supported)
                    ForEach(Array(supported.enumerated()), id: \.offset) { i, id in
                        if i > 0 { SettingsDivider() }
                        HStack(spacing: 10) {
                            SettingsRowText(title: names[i], subtitle: TypingLanguages.layout(for: id).title)
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    if supported.isEmpty {
                        SettingsRowText(title: "English", subtitle: KeyLayout.qwerty.title)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                }
                .cardSurface(radius: RefinedPlatform.radius(.card))

                Text("With more than one language, the keyboard uses the language an app asks for, or the one you last chose in its menu. To switch, tap the menu button in the keyboard, and then tap Language.")
                    .scaledFont(15).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)

                if !unsupported.isEmpty {
                    let names = KeyboardLanguagesMirror.names(unsupported)
                    Text("The Verbose keyboard has no layout for \(names.joined(separator: ", ")). To type in it, use the globe key to switch to that keyboard. Dictation works in any language your transcription model supports.")
                        .scaledFont(15).foregroundStyle(Refined.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("To add a language, open the Settings app and go to General › Keyboard › Keyboards.")
                    .scaledFont(15).foregroundStyle(Refined.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            KeyboardLanguagesMirror.update()
            supported = KeyboardLanguagesMirror.supported
            unsupported = KeyboardLanguagesMirror.unsupported
        }
    }
}
