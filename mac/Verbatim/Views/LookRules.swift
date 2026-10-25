import Foundation

// Pure rules behind the Native look on the Mac (Foundation only, so mac/tools/test-native.sh runs them on Linux):
// which system color stands in for a Verbose token, which SF Symbol each sidebar item and Settings pane shows, the
// title case macOS buttons use, and the welcome tour's steps.

/// The system role that replaces a Verbose token under Native.
enum NativeRole: Equatable {
    /// The window's background (`windowBackgroundColor`).
    case window
    /// Text views, tables, and cards (`controlBackgroundColor`).
    case content
    /// Primary text (`labelColor`).
    case label
    /// Secondary text (`secondaryLabelColor`).
    case secondaryLabel
    /// Decorative text (`tertiaryLabelColor`).
    case tertiaryLabel
    /// Tinted text: the Native accent (`Ink.nativeAccent`).
    case accentText
    /// A selected or hovered row (`unemphasizedSelectedContentBackgroundColor`).
    case selection
    /// Chips, tracks, and placeholders (`quaternaryLabelColor`).
    case fill
}

enum NativeRoles {
    /// The role for a token, found by the token's light value in Tokens.swift (`Ink.dyn` and `Ink.dynC` pass it).
    /// Brand fills (persimmon, petal, butter, sage, and their tints) have no role: they keep their color in both looks.
    static func role(light: UInt32) -> NativeRole? {
        switch light {
        case 0xF5F0E6, 0xF1EBDF: return .window                    // paper; bar and notes
        case 0xFFFDF9, 0xFBF8F1, 0xFAF6EE: return .content         // reader and card; card hover; raised
        case 0xEFE9DD: return .selection                           // side and wash
        case 0x26352E: return .label                               // ink (and the ink-filled controls)
        case 0x545E56, 0x606962: return .secondaryLabel            // dim, mute
        case 0x8E938A: return .tertiaryLabel                       // faint
        case 0xB23F24: return .accentText                          // accent text (danger shares it)
        case 0xE6DFD1, 0xDAD4C7, 0xE8E2D6, 0xEEE7DA: return .fill  // chip, chip hover, track, placeholder
        default: return nil
        }
    }
}

/// SF Symbols for the Native look. Only files marked `// brand: native` name SF Symbols outside the DESIGN.md §3
/// allowlist; these tables keep the names in one place.
enum NativeSymbols {
    /// A sidebar item, by `SidebarItemID` raw value.
    static func sidebar(_ raw: String) -> String {
        switch raw {
        case "home": return "house"
        case "library": return "books.vertical"
        case "links": return "link"
        case "moments": return "bookmark"
        case "queue": return "tray"
        case "dictations": return "text.bubble"
        case "you": return "person.crop.circle"
        case "dictionary": return "character.book.closed"
        default: return "circle"
        }
    }

    /// A Settings pane, by `SettingsTab` raw value.
    static func settings(_ raw: String) -> String {
        switch raw {
        case "general": return "gearshape"
        case "dictate": return "mic"
        case "floatingButton": return "smallcircle.filled.circle"
        case "actions": return "bolt"
        case "privacy": return "hand.raised"
        case "transcription": return "globe"
        case "speakers": return "person.2"
        case "captions": return "captions.bubble"
        case "meetings": return "video"
        case "watched": return "folder"
        case "export": return "square.and.arrow.up"
        case "storage": return "icloud"
        case "about": return "info.circle"
        default: return "gearshape"
        }
    }

    /// A transcript's kind (`RecordingKind` raw value), or nil for one without a kind; `link`, `file`, and `dictation`
    /// say where it came from when the kind doesn't.
    static func kind(_ raw: String?, link: Bool = false, file: Bool = false, dictation: Bool = false, speakers: Int = 1) -> String {
        switch raw {
        case "meeting"?: return "person.2"
        case "journal"?: return "book"
        case "note"?: return "note.text"
        case "idea"?: return "lightbulb"
        case "dictation"?: return "text.bubble"
        case "podcast"?: return link ? "link" : "mic"
        case "interview"?: return "quote.bubble"
        case "video"?: return "play.rectangle"
        case "talk"?: return "person.wave.2"
        default:
            if dictation { return "text.bubble" }
            if link { return "link" }
            if file { return "doc" }
            return speakers >= 2 ? "person.2" : "waveform"
        }
    }
}

/// Text rules for Native: macOS buttons use title case ("Clean Up", "Don't Ask for This App").
enum NativeText {
    /// Words that stay lowercase inside a title (Apple's style: articles, coordinating conjunctions, and prepositions
    /// of four or fewer letters), unless first or last.
    static let minorWords: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "as", "at", "by", "in",
                                          "of", "off", "on", "per", "to", "via", "from", "into", "onto", "with", "over"]

    /// "Start recording" → "Start Recording"; "Don't ask for this app" → "Don't Ask for This App". Words that already
    /// have a capital ("AI", "iCloud", "MP4") stay as written; the first and last words are always capitalized.
    static func titleCase(_ s: String) -> String {
        let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let lastIndex = words.lastIndex { !$0.isEmpty } ?? 0
        return words.enumerated().map { i, w in
            guard let first = w.firstIndex(where: { $0.isLetter }) else { return w }
            if w.contains(where: { $0.isUppercase }) { return w }
            let core = w.lowercased().filter { $0.isLetter || $0 == "'" || $0 == "’" }
            if i != 0 && i != lastIndex && minorWords.contains(core) { return w }
            return w.replacingCharacters(in: first...first, with: w[first].uppercased())
        }
        .joined(separator: " ")
    }
}

/// The Mac welcome tour's steps, in order. "Pick a look" comes right after the welcome, before the permissions.
enum OnboardingStep: Int, CaseIterable {
    case welcome, look, permissions, tryIt, placement, quality

    /// The header's label for the step.
    var label: String {
        switch self {
        case .welcome: return "Welcome to Verbose"
        case .look: return "Pick a look"
        case .permissions: return "Permissions"
        case .tryIt: return "Try it"
        case .placement: return "The Ribbon"
        case .quality: return "Last step"
        }
    }

    static var count: Int { allCases.count }

    /// "Step 2 of 6", the Native header.
    var counter: String { "Step \(rawValue + 1) of \(Self.count)" }

    /// The step for an index, clamped to the tour (the self-test opens the tour on a given step).
    static func at(_ index: Int) -> OnboardingStep { OnboardingStep(rawValue: max(0, min(count - 1, index))) ?? .welcome }
}
