import Foundation

// Minimal copies of the app's Segment, WordSpan, and Speaker (Model/Transcript.swift), with only the fields
// MultitrackMath uses, so the pure functions compile without the rest of the app.
struct WordSpan: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct Segment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var words: [WordSpan]? = nil
    var speaker: String? = nil
}

struct Speaker: Codable, Identifiable, Equatable {
    var id: String
    var name: String
}
