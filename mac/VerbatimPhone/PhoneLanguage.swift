import SwiftUI

/// A recording in a language Parakeet v3 handles, with v3 not downloaded (PhoneApp shows it as an alert).
struct ParakeetV3Offer: Equatable {
    var id: UUID
    /// nil: the English-only model couldn't make out the words, but the language is unclear.
    var language: String?

    var title: String {
        if let language { return "Transcribe \(LanguageDetection.name(language)) with Parakeet v3?" }
        return "This recording might not be in English"
    }

    var message: String {
        if let language {
            let name = LanguageDetection.name(language)
            return "This recording sounds like \(name), and the English-only model can't transcribe it. Download Parakeet v3 (about 480 MB) to transcribe it again in \(name)."
        }
        return "The English-only model couldn't make out the words. Download Parakeet v3 (about 480 MB, 25 languages) to check the language and transcribe it again."
    }
}

/// The transcript header's language: what it was transcribed in, and Transcribe again in… another language.
struct TranscriptLanguageMenu: View {
    @EnvironmentObject var app: PhoneState
    var transcript: Transcript
    /// The language picked, waiting for the confirmation (`.some(nil)`: detect automatically).
    @State private var pending: String?? = nil

    private var current: String { transcript.language.map(LanguageDetection.name) ?? "Set language" }

    var body: some View {
        Menu {
            Section("Transcribe again in") {
                Button { pending = .some(nil) } label: { Label("Detect automatically", systemImage: "sparkle.magnifyingglass") }   // brand: system surface (menu)
                ForEach(LanguageDetection.pickableV3, id: \.self) { item($0) }
            }
            Section("With Apple speech recognition") {
                ForEach(LanguageDetection.pickableApple, id: \.self) { item($0) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(current)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.lookDim)
        }
        .accessibilityLabel("Language, \(current)")
        .accessibilityHint("Transcribe again in another language")
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Transcribe again") {
                if let choice = pending { app.transcribeAgain(transcript.id, language: choice) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Verbose replaces this transcript's words, speakers, and Dictionary fixes. Your title, notes, and tags stay.")
        }
    }

    private func item(_ code: String) -> some View {
        Button { pending = .some(code) } label: {
            if code == transcript.language { Label(LanguageDetection.name(code), systemImage: "checkmark") }
            else { Text(LanguageDetection.name(code)) }
        }
    }

    private var confirmTitle: String {
        guard let choice = pending else { return "" }
        return choice.map { "Transcribe again in \(LanguageDetection.name($0))?" } ?? "Transcribe again and detect the language?"
    }
}
