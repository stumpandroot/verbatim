import Foundation

// A stand-in for the app's Store, so the real ThoughtPages.swift (where a thought's "Apple Watch" origin is decided)
// compiles beside Transcript.swift. The watch checks never read the library.
final class Store {
    var live: [Transcript] = []
    func memo<T>(_ key: String, _ make: () -> T) -> T { make() }
}
